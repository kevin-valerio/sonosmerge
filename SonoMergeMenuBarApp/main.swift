import AppKit
import Foundation

enum BroadcastFailure: Error {
    case message(String)

    var text: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

struct DiscoverResponse: Decodable {
    let rooms: [DiscoveredRoom]
}

struct DiscoveredRoom: Decodable {
    let name: String
    let airplayEnabled: Bool
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaultRooms = ["Salon TV", "Cuisine"]
    private let selectedRoomsDefaultsKey = "EverywhereRoomNames"

    private let menu = NSMenu()
    private var statusItem: NSStatusItem?

    private var currentRooms: [DiscoveredRoom] = []
    private var selectedRoomNames: [String]
    private var statusMessage = "Ready"
    private var isBroadcasting = false
    private var isRefreshingRooms = false

    override init() {
        selectedRoomNames = UserDefaults.standard.stringArray(forKey: selectedRoomsDefaultsKey) ?? defaultRooms
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "SonoMerge")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SonoMerge"
        }

        menu.delegate = self
        statusItem.menu = menu
        self.statusItem = statusItem

        rebuildMenu()
        refreshRooms()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshRooms()
    }

    @objc private func broadcastEverywhere() {
        if isBroadcasting {
            return
        }

        let selectedRooms = selectedRoomNamesForBroadcast()
        if selectedRooms.isEmpty {
            showFailure("Pick at least one room in the Everywhere list first.")
            return
        }

        isBroadcasting = true
        statusMessage = "Broadcast in progress..."
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.runBroadcastProcess(selectedRooms: selectedRooms)
            DispatchQueue.main.async {
                self?.finishBroadcast(result)
            }
        }
    }

    @objc private func toggleRoomSelection(_ sender: NSMenuItem) {
        guard let roomName = sender.representedObject as? String else {
            return
        }

        if let index = selectedRoomNames.firstIndex(of: roomName) {
            selectedRoomNames.remove(at: index)
        } else {
            selectedRoomNames.append(roomName)
        }

        persistSelectedRooms()
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let broadcastTitle = isBroadcasting ? "Broadcasting..." : "Broadcast music everywhere"
        let broadcastItem = NSMenuItem(title: broadcastTitle, action: #selector(broadcastEverywhere), keyEquivalent: "")
        broadcastItem.target = self
        broadcastItem.isEnabled = !isBroadcasting
        menu.addItem(broadcastItem)

        let statusItem = NSMenuItem(title: statusMessage, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        let roomsHeader = NSMenuItem(title: "Everywhere rooms", action: nil, keyEquivalent: "")
        roomsHeader.isEnabled = false
        menu.addItem(roomsHeader)

        if currentRooms.isEmpty {
            let title = isRefreshingRooms ? "Loading rooms..." : "No Sonos rooms found"
            let loadingItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            menu.addItem(loadingItem)
        } else {
            for room in currentRooms.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                let roomItem = NSMenuItem(title: room.name, action: #selector(toggleRoomSelection(_:)), keyEquivalent: "")
                roomItem.target = self
                roomItem.representedObject = room.name
                roomItem.state = selectedRoomNames.contains(room.name) ? .on : .off
                menu.addItem(roomItem)
            }
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SonoMerge", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func refreshRooms() {
        if isRefreshingRooms {
            return
        }

        isRefreshingRooms = true
        rebuildMenu()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = self?.discoverRoomsProcess()
            DispatchQueue.main.async {
                self?.finishRefreshingRooms(result)
            }
        }
    }

    private func finishRefreshingRooms(_ result: Result<[DiscoveredRoom], BroadcastFailure>?) {
        isRefreshingRooms = false

        guard let result else {
            statusMessage = "Could not refresh rooms."
            rebuildMenu()
            return
        }

        switch result {
        case .success(let rooms):
            currentRooms = rooms
            statusMessage = "Ready"
            rebuildMenu()

        case .failure(let error):
            statusMessage = "Could not refresh rooms: \(error.text)"
            rebuildMenu()
        }
    }

    private func discoverRoomsProcess() -> Result<[DiscoveredRoom], BroadcastFailure> {
        let result = runBundledScript(arguments: ["discover"])
        switch result {
        case .success(let output):
            guard let data = output.data(using: .utf8) else {
                return .failure(.message("SonoMerge could not decode the room list output."))
            }

            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let response = try decoder.decode(DiscoverResponse.self, from: data)
                return .success(response.rooms)
            } catch {
                return .failure(.message("SonoMerge could not parse the room list: \(error.localizedDescription)"))
            }

        case .failure(let error):
            return .failure(error)
        }
    }

    private func runBroadcastProcess(selectedRooms: [String]) -> Result<String, BroadcastFailure> {
        runBundledScript(arguments: ["broadcast", "--rooms"] + selectedRooms)
    }

    private func runBundledScript(arguments: [String]) -> Result<String, BroadcastFailure> {
        guard let scriptURL = Bundle.main.url(forResource: "sonos_broadcast", withExtension: "py") else {
            return .failure(.message("Bundled sonos_broadcast.py was not found."))
        }

        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path] + arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return .failure(.message("Could not start the bundled broadcast script: \(error.localizedDescription)"))
        }

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 0 {
            let successText = outputText.isEmpty ? "Broadcast completed." : outputText
            return .success(successText)
        }

        let failureText = outputText.isEmpty ? "The bundled broadcast script failed." : outputText
        return .failure(.message(failureText))
    }

    private func selectedRoomNamesForBroadcast() -> [String] {
        if currentRooms.isEmpty {
            return selectedRoomNames
        }

        let availableRoomNames = Set(currentRooms.map(\.name))
        return selectedRoomNames.filter { availableRoomNames.contains($0) }
    }

    private func persistSelectedRooms() {
        UserDefaults.standard.set(selectedRoomNames, forKey: selectedRoomsDefaultsKey)
    }

    private func finishBroadcast(_ result: Result<String, BroadcastFailure>?) {
        isBroadcasting = false

        guard let result else {
            statusMessage = "Broadcast failed."
            rebuildMenu()
            return
        }

        switch result {
        case .success(let message):
            statusMessage = message
            rebuildMenu()

        case .failure(let error):
            statusMessage = "Broadcast failed."
            rebuildMenu()
            showFailure(error.text)
        }
    }

    private func showFailure(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "SonoMerge"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@main
struct SonoMergeMenuBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
