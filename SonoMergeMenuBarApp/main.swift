import AppKit

enum BroadcastFailure: Error {
    case message(String)

    var text: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaultRooms = ["Salon TV", "Cuisine"]

    private var statusItem: NSStatusItem?
    private var broadcastItem: NSMenuItem?
    private var statusMessageItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "SonoMerge")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SonoMerge"
        }

        let menu = NSMenu()

        let broadcastItem = NSMenuItem(
            title: "Broadcast music everywhere",
            action: #selector(broadcastEverywhere),
            keyEquivalent: ""
        )
        broadcastItem.target = self
        menu.addItem(broadcastItem)
        self.broadcastItem = broadcastItem

        let statusMessageItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusMessageItem.isEnabled = false
        menu.addItem(statusMessageItem)
        self.statusMessageItem = statusMessageItem

        menu.addItem(.separator())

        let infoItem = NSMenuItem(
            title: "Default rooms: \(defaultRooms.joined(separator: ", "))",
            action: nil,
            keyEquivalent: ""
        )
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SonoMerge", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    @objc private func broadcastEverywhere() {
        guard let broadcastItem else { return }

        broadcastItem.isEnabled = false
        broadcastItem.title = "Broadcasting..."
        statusMessageItem?.title = "Broadcast in progress..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.runBroadcastProcess()
            DispatchQueue.main.async {
                self?.finishBroadcast(result)
            }
        }
    }

    private func runBroadcastProcess() -> Result<String, BroadcastFailure> {
        guard let scriptURL = Bundle.main.url(forResource: "sonos_broadcast", withExtension: "py") else {
            return .failure(.message("Bundled sonos_broadcast.py was not found."))
        }

        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path, "broadcast", "--rooms"] + defaultRooms
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return .failure(.message("Could not start the broadcast process: \(error.localizedDescription)"))
        }

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 0 {
            let successText = outputText.isEmpty ? "Broadcast completed." : outputText
            return .success(successText)
        }

        let failureText = outputText.isEmpty ? "The broadcast process failed." : outputText
        return .failure(.message(failureText))
    }

    private func finishBroadcast(_ result: Result<String, BroadcastFailure>?) {
        broadcastItem?.isEnabled = true
        broadcastItem?.title = "Broadcast music everywhere"

        guard let result else {
            statusMessageItem?.title = "Broadcast failed."
            return
        }

        switch result {
        case .success(let message):
            statusMessageItem?.title = message

        case .failure(let error):
            statusMessageItem?.title = "Broadcast failed."

            let alert = NSAlert()
            alert.messageText = "SonoMerge could not start the broadcast."
            alert.informativeText = error.text
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
