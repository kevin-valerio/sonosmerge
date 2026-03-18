import AppKit
import Foundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaultRooms = ["Salon TV", "Cuisine"]
    private let selectedRoomsDefaultsKey = "EverywhereRoomNames"
    private let primaryRoomDefaultsKey = "PrimaryAirPlayRoomName"

    private let menu = NSMenu()
    private var statusItem: NSStatusItem?

    private var currentRooms: [Room] = []
    private var selectedRoomNames: [String]
    private var preferredPrimaryRoomName: String?
    private var statusMessage = "Ready"
    private var isBroadcasting = false
    private var isRefreshingRooms = false

    override init() {
        selectedRoomNames = UserDefaults.standard.stringArray(forKey: selectedRoomsDefaultsKey) ?? defaultRooms
        preferredPrimaryRoomName = UserDefaults.standard.string(forKey: primaryRoomDefaultsKey) ?? defaultRooms.first
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image: NSImage?
            if let iconURL = Bundle.main.url(forResource: "menubar-icon", withExtension: "svg") {
                image = NSImage(contentsOf: iconURL)
            } else {
                image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "SonoMerge")
            }
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

        let selectedRooms = selectedRoomsForBroadcast()
        if selectedRooms.isEmpty {
            showFailure("Pick at least one room in the Everywhere rooms list first.")
            return
        }

        let primaryRoomName = currentPrimaryRoomName(selectedRooms: selectedRooms)
        guard primaryRoomName != nil else {
            showFailure("Pick a primary AirPlay room before starting the broadcast.")
            return
        }

        isBroadcasting = true
        statusMessage = "Broadcast in progress..."
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result: Result<BroadcastResult, BroadcastError>
            do {
                result = .success(try SonoMergeCore.broadcast(
                    roomNames: selectedRooms.map(\.name),
                    preferredAirPlayTarget: primaryRoomName
                ))
            } catch let error as BroadcastError {
                result = .failure(error)
            } catch {
                result = .failure(.message(error.localizedDescription))
            }

            DispatchQueue.main.async {
                self.finishBroadcast(result)
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

        normalizePrimaryRoomSelection()
        persistSelection()
        rebuildMenu()
    }

    @objc private func selectPrimaryRoom(_ sender: NSMenuItem) {
        guard let roomName = sender.representedObject as? String else {
            return
        }

        preferredPrimaryRoomName = roomName
        persistSelection()
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleStartAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                statusMessage = "Start at login disabled."
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    statusMessage = "Start at login needs approval in System Settings."
                } else {
                    statusMessage = "Start at login enabled."
                }
            }

            rebuildMenu()
        } catch {
            showFailure("Could not update start at login: \(error.localizedDescription)")
        }
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
            for room in currentRooms {
                let roomItem = NSMenuItem(title: room.name, action: #selector(toggleRoomSelection(_:)), keyEquivalent: "")
                roomItem.target = self
                roomItem.representedObject = room.name
                roomItem.state = selectedRoomNames.contains(room.name) ? .on : .off
                menu.addItem(roomItem)
            }
        }

        menu.addItem(.separator())

        let primaryHeader = NSMenuItem(title: "Primary AirPlay room", action: nil, keyEquivalent: "")
        primaryHeader.isEnabled = false
        menu.addItem(primaryHeader)

        let selectedRooms = selectedRoomsForBroadcast()
        let primaryCandidates = selectedRooms.filter(\.airplayEnabled)

        if primaryCandidates.isEmpty {
            let hintItem = NSMenuItem(title: "Select at least one AirPlay room above", action: nil, keyEquivalent: "")
            hintItem.isEnabled = false
            menu.addItem(hintItem)
        } else {
            let primaryRoomName = currentPrimaryRoomName(selectedRooms: selectedRooms)
            for room in primaryCandidates {
                let roomItem = NSMenuItem(title: room.name, action: #selector(selectPrimaryRoom(_:)), keyEquivalent: "")
                roomItem.target = self
                roomItem.representedObject = room.name
                roomItem.state = room.name == primaryRoomName ? .on : .off
                menu.addItem(roomItem)
            }
        }

        menu.addItem(.separator())

        let startAtLoginEnabled = SMAppService.mainApp.status == .enabled
        let startAtLoginItem = NSMenuItem(title: "Start at login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        startAtLoginItem.target = self
        startAtLoginItem.state = startAtLoginEnabled ? .on : .off
        menu.addItem(startAtLoginItem)

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
            guard let self else { return }

            let result: Result<[Room], BroadcastError>
            do {
                result = .success(try SonoMergeCore.discoverRooms())
            } catch let error as BroadcastError {
                result = .failure(error)
            } catch {
                result = .failure(.message(error.localizedDescription))
            }

            DispatchQueue.main.async {
                self.finishRefreshingRooms(result)
            }
        }
    }

    private func finishRefreshingRooms(_ result: Result<[Room], BroadcastError>) {
        isRefreshingRooms = false

        switch result {
        case .success(let rooms):
            currentRooms = rooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            normalizePrimaryRoomSelection()
            statusMessage = "Ready"
            rebuildMenu()

        case .failure(let error):
            statusMessage = "Could not refresh rooms: \(error.text)"
            rebuildMenu()
        }
    }

    private func selectedRoomsForBroadcast() -> [Room] {
        let selectedRoomSet = Set(selectedRoomNames)
        return currentRooms.filter { selectedRoomSet.contains($0.name) }
    }

    private func currentPrimaryRoomName(selectedRooms: [Room]) -> String? {
        let primaryCandidates = selectedRooms.filter(\.airplayEnabled)

        if let preferredPrimaryRoomName,
           primaryCandidates.contains(where: { $0.name == preferredPrimaryRoomName }) {
            return preferredPrimaryRoomName
        }

        return primaryCandidates.first?.name
    }

    private func normalizePrimaryRoomSelection() {
        let selectedRooms = selectedRoomsForBroadcast()
        let newPrimaryRoomName = currentPrimaryRoomName(selectedRooms: selectedRooms)
        preferredPrimaryRoomName = newPrimaryRoomName
        persistSelection()
    }

    private func persistSelection() {
        UserDefaults.standard.set(selectedRoomNames, forKey: selectedRoomsDefaultsKey)
        UserDefaults.standard.set(preferredPrimaryRoomName, forKey: primaryRoomDefaultsKey)
    }

    private func finishBroadcast(_ result: Result<BroadcastResult, BroadcastError>) {
        isBroadcasting = false

        switch result {
        case .success(let result):
            statusMessage = result.message
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
