import AppKit
import Foundation
import ServiceManagement

/// Volume slider helper: routes NSSlider action back to a closure

private final class SliderTarget: NSObject {
    let onChange: (Int) -> Void
    weak var sliderView: VolumeSliderView?

    init(onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        let vol = Int(sender.doubleValue.rounded())
        sliderView?.updateVolume(vol)
        onChange(vol)
    }
}

/// Custom view that matches the macOS Control Center volume slider style

private final class VolumeSliderView: NSView {
    static let totalWidth: CGFloat = 264
    static let totalHeight: CGFloat = 46

    // Point size passed to NSImageSymbolConfiguration so both icons render at the
    // same optical height regardless of their different natural aspect ratios.
    private static let iconPointSize: CGFloat = 13

    // speaker.wave.3.fill is naturally wider than speaker.fill (3 arcs extend right),
    // so it gets a wider frame while keeping the same rendered height.
    private static let softIconFrameWidth: CGFloat  = 16
    private static let loudIconFrameWidth: CGFloat  = 22

    private let volumeLabel: NSTextField
    private let slider: NSSlider

    /// Updates both the slider knob position and the numeric label.
    func updateVolume(_ volume: Int) {
        slider.doubleValue = Double(volume)
        volumeLabel.stringValue = "\(volume)"
    }

    init(name: String, volume: Int, target: SliderTarget) {
        let w  = VolumeSliderView.totalWidth
        let h  = VolumeSliderView.totalHeight
        let softW = VolumeSliderView.softIconFrameWidth
        let loudW = VolumeSliderView.loudIconFrameWidth
        let iconH = VolumeSliderView.iconPointSize + 3  // frame height with a touch of breathing room

        // Slider row geometry
        let leftMargin: CGFloat    = 16
        let nameLabelMargin: CGFloat = 16  // name label uses its own right margin, independent of the slider row
        let iconSliderGap: CGFloat = 4
        let sliderIconGap: CGFloat = 4
        let iconNumGap: CGFloat    = 3
        let numWidth: CGFloat      = 24
        let rightMargin: CGFloat   = 8

        // Positions derived from width constants so nothing is hard-coded
        let sliderX     = leftMargin + softW + iconSliderGap
        let loudIconX   = w - rightMargin - numWidth - iconNumGap - loudW
        let numX        = w - rightMargin - numWidth
        let sliderWidth = loudIconX - sliderIconGap - sliderX

        // Volume number — slider row, immediately right of the loud icon.
        // Right-aligned so the last digit is always flush with (numX + numWidth),
        // keeping the visual gap to the row edge equal to rightMargin.
        // y and height are filled in after super.init once iconY/iconH are computed.
        let volLabel = NSTextField(labelWithString: "\(volume)")
        volLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        volLabel.textColor = .secondaryLabelColor
        volLabel.alignment = .right
        self.volumeLabel = volLabel

        let s = NSSlider()
        s.sliderType = .linear
        s.minValue = 0
        s.maxValue = 100
        s.doubleValue = Double(volume)
        s.isContinuous = true
        s.target = target
        s.action = #selector(SliderTarget.sliderChanged(_:))
        s.frame = NSRect(x: sliderX, y: 4, width: sliderWidth, height: 20)
        self.slider = s

        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Name label — top row
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: leftMargin, y: h - 20, width: w - leftMargin - nameLabelMargin, height: 16)
        addSubview(nameLabel)

        // Shared symbol configuration — same point size enforces equal optical height
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: VolumeSliderView.iconPointSize, weight: .regular)
        let iconY = 4 + (20 - iconH) / 2

        // Pin the number label to the exact same Y and height as the icons
        volLabel.frame = NSRect(x: numX, y: iconY, width: numWidth, height: iconH)

        addSubview(Self.makeIcon(symbolName: "speaker.fill", description: "Quiet", config: symbolConfig,
                                 frame: NSRect(x: leftMargin, y: iconY, width: softW, height: iconH)))
        addSubview(Self.makeIcon(symbolName: "speaker.wave.3.fill", description: "Loud", config: symbolConfig,
                                 frame: NSRect(x: loudIconX, y: iconY, width: loudW, height: iconH)))

        addSubview(s)
        addSubview(volLabel)

        target.sliderView = self
    }

    private static func makeIcon(symbolName: String, description: String,
                                 config: NSImage.SymbolConfiguration, frame: NSRect) -> NSImageView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        icon.symbolConfiguration = config
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = frame
        return icon
    }

    required init?(coder: NSCoder) { nil }
}

/// App delegate

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

    private var roomVolumes: [String: Int] = [:]
    /// Computed as the average of all individual room volumes — used as the proportional scaling base.
    private var everywhereGroupVolume: Int?
    private var volumesLoaded = false
    /// Retained while menu is open; cleared on each rebuild.
    private var sliderTargets: [SliderTarget] = []
    /// Live view references so the Everywhere slider can drive individual room views in real time.
    private var roomSliderViews: [String: VolumeSliderView] = [:]
    /// Live reference to the Everywhere slider view so individual rooms can drive it back.
    private var everywhereSliderView: VolumeSliderView?
    /// Debounce timers so rapid slider drags don't flood Sonos with SOAP calls.
    private var pendingVolumeWork: [String: DispatchWorkItem] = [:]

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
        sliderTargets.removeAll()
        roomSliderViews.removeAll()
        everywhereSliderView = nil
        pendingVolumeWork.values.forEach { $0.cancel() }
        pendingVolumeWork.removeAll()
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

        let volumeHeader = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")
        volumeHeader.isEnabled = false
        menu.addItem(volumeHeader)

        if currentRooms.isEmpty || !volumesLoaded {
            let item = NSMenuItem(title: isRefreshingRooms ? "Loading..." : "No rooms found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            // Everywhere group slider — scales all individual rooms proportionally on drag
            let everywhereRooms = selectedRoomsForBroadcast()
            if !everywhereRooms.isEmpty {
                let groupVol = everywhereGroupVolume ?? 50
                let (groupItem, groupView) = makeVolumeSliderItem(name: "Everywhere", volume: groupVol) { [weak self] newGroupVol in
                    guard let self else { return }
                    let oldGroupVol = self.everywhereGroupVolume ?? newGroupVol
                    self.everywhereGroupVolume = newGroupVol

                    for room in self.currentRooms {
                        let oldVol = Double(self.roomVolumes[room.name] ?? 50)
                        let newRoomVol: Int
                        if oldGroupVol > 0 {
                            newRoomVol = min(100, max(0, Int((oldVol * Double(newGroupVol) / Double(oldGroupVol)).rounded())))
                        } else {
                            newRoomVol = newGroupVol
                        }
                        self.roomVolumes[room.name] = newRoomVol
                        self.roomSliderViews[room.name]?.updateVolume(newRoomVol)
                        self.scheduleSetVolume(roomName: room.name, host: room.host, volume: newRoomVol)
                    }
                }
                menu.addItem(groupItem)
                everywhereSliderView = groupView
                menu.addItem(.separator())
            }

            // Individual room sliders — update Everywhere to the new average on drag
            for room in currentRooms {
                let vol = roomVolumes[room.name] ?? 50
                let roomHost = room.host
                let roomName = room.name
                let (item, view) = makeVolumeSliderItem(name: room.name, volume: vol) { [weak self] newVol in
                    guard let self else { return }
                    self.roomVolumes[roomName] = newVol

                    // Recompute group volume as the average of all room volumes
                    if let avg = self.computeAverageVolume() {
                        self.everywhereGroupVolume = avg
                        self.everywhereSliderView?.updateVolume(avg)
                    }

                    self.scheduleSetVolume(roomName: roomName, host: roomHost, volume: newVol)
                }
                menu.addItem(item)
                roomSliderViews[room.name] = view
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

    /// Debounces SOAP calls per room so rapid slider drags send only the final value.
    private func scheduleSetVolume(roomName: String, host: String, volume: Int) {
        pendingVolumeWork[roomName]?.cancel()
        let work = DispatchWorkItem {
            try? SonoMergeCore.setVolume(host: host, volume: volume)
        }
        pendingVolumeWork[roomName] = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func makeVolumeSliderItem(
        name: String,
        volume: Int,
        onChange: @escaping (Int) -> Void
    ) -> (NSMenuItem, VolumeSliderView) {
        let item = NSMenuItem()
        let target = SliderTarget(onChange: onChange)
        sliderTargets.append(target)
        let view = VolumeSliderView(name: name, volume: volume, target: target)
        item.view = view
        return (item, view)
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
            fetchVolumes()
            rebuildMenu()

        case .failure(let error):
            statusMessage = "Could not refresh rooms: \(error.text)"
            rebuildMenu()
        }
    }

    private func fetchVolumes() {
        let roomsSnapshot = currentRooms

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            var volumes: [String: Int] = [:]
            for room in roomsSnapshot {
                if let vol = try? SonoMergeCore.getVolume(host: room.host) {
                    volumes[room.name] = vol
                }
            }

            DispatchQueue.main.async {
                self.roomVolumes = volumes
                // Derive group volume as the average of individual rooms so proportional
                // math stays consistent (Sonos GetGroupVolume returns the coordinator's
                // volume, which may differ from the average).
                self.everywhereGroupVolume = self.computeAverageVolume()
                self.volumesLoaded = true
                self.rebuildMenu()
            }
        }
    }

    /// Returns the average of all fetched room volumes, or nil if none are known yet.
    private func computeAverageVolume() -> Int? {
        let vols = currentRooms.compactMap { roomVolumes[$0.name] }
        guard !vols.isEmpty else { return nil }
        return Int((Double(vols.reduce(0, +)) / Double(vols.count)).rounded())
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
