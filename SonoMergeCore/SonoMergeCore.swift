import Foundation

struct Room: Codable, Equatable {
    let name: String
    let uuid: String
    let coordinatorUUID: String
    let groupID: String
    let host: String
    let airplayEnabled: Bool
}

struct BroadcastResult: Codable, Equatable {
    let selectedRooms: [String]
    let airplayTarget: String
    let joinedRooms: [String]
    let message: String
}

enum BroadcastError: Error {
    case message(String)

    var text: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

private struct CommandResult {
    let output: String
    let terminationStatus: Int32
    let timedOut: Bool
}

enum SonoMergeCore {
    static let soundMenuIdentifier = "com.apple.menuextra.sound"

    static func discoverRooms() throws -> [Room] {
        let sonosHosts = try discoverSonosHosts()
        var lastError: BroadcastError?

        for host in sonosHosts {
            do {
                return try roomsFromTopology(host: host)
            } catch let error as BroadcastError {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }

        throw BroadcastError.message("Could not read the Sonos room topology from any discovered host.")
    }

    static func broadcast(roomNames: [String], preferredAirPlayTarget: String? = nil) throws -> BroadcastResult {
        if roomNames.isEmpty {
            throw BroadcastError.message("Pick at least one room to broadcast.")
        }

        let discoveredRooms = try discoverRooms()
        let roomsByName = Dictionary(uniqueKeysWithValues: discoveredRooms.map { ($0.name, $0) })
        let missingRooms = roomNames.filter { roomsByName[$0] == nil }

        if !missingRooms.isEmpty {
            let availableNames = discoveredRooms.map(\.name).joined(separator: ", ")
            throw BroadcastError.message(
                "Could not find the selected Sonos rooms: \(missingRooms.joined(separator: ", ")). Available rooms: \(availableNames)"
            )
        }

        let selectedRooms = roomNames.compactMap { roomsByName[$0] }
        let airplayTarget = try selectAirPlayTarget(
            from: selectedRooms,
            preferredAirPlayTarget: preferredAirPlayTarget
        )

        let macOutputMessage = try setMacOutput(roomName: airplayTarget.name)

        var joinedRoomNames: [String] = []
        for room in selectedRooms {
            if room.name == airplayTarget.name {
                continue
            }
            if room.coordinatorUUID == airplayTarget.coordinatorUUID {
                continue
            }
            try joinRoomToCoordinator(joinerRoom: room, coordinatorUUID: airplayTarget.coordinatorUUID)
            joinedRoomNames.append(room.name)
        }

        return BroadcastResult(
            selectedRooms: roomNames,
            airplayTarget: airplayTarget.name,
            joinedRooms: joinedRoomNames,
            message: macOutputMessage
        )
    }

    private static func discoverSonosHosts(timeoutSeconds: TimeInterval = 4.0) throws -> [String] {
        let result = try runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/dns-sd"),
            arguments: ["-Z", "_sonos._tcp", "local."],
            timeoutSeconds: timeoutSeconds,
            allowPartialOutputOnTimeout: true
        )

        if result.output.isEmpty {
            throw BroadcastError.message("Sonos discovery returned no data. Make sure your speakers are on the same local network.")
        }

        let pattern = #"location=(http://[^"\s]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(
            in: result.output,
            range: NSRange(result.output.startIndex..., in: result.output)
        )

        let hosts = Set(matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: result.output) else {
                return nil
            }
            let location = String(result.output[range])
            return URL(string: location)?.host
        })

        if hosts.isEmpty {
            if result.timedOut {
                throw BroadcastError.message("Timed out while trying to discover Sonos rooms on the local network.")
            }
            throw BroadcastError.message("Could not discover any Sonos rooms on the local network.")
        }

        return hosts.sorted()
    }

    private static func roomsFromTopology(host: String) throws -> [Room] {
        let zoneGroupStateXML = try fetchZoneGroupState(host: host)
        let zoneGroupDocument = try parseXMLDocument(zoneGroupStateXML)
        let groupNodes = try zoneGroupDocument.nodes(forXPath: "//*[local-name()='ZoneGroup']")

        var roomsByName: [String: Room] = [:]

        for case let groupElement as XMLElement in groupNodes {
            let coordinatorUUID = groupElement.attribute(forName: "Coordinator")?.stringValue ?? ""
            let groupID = groupElement.attribute(forName: "ID")?.stringValue ?? ""

            for child in groupElement.children ?? [] {
                guard
                    let member = child as? XMLElement,
                    member.name == "ZoneGroupMember"
                else {
                    continue
                }

                if member.attribute(forName: "Invisible")?.stringValue == "1" {
                    continue
                }

                guard
                    let name = member.attribute(forName: "ZoneName")?.stringValue,
                    let uuid = member.attribute(forName: "UUID")?.stringValue,
                    let location = member.attribute(forName: "Location")?.stringValue,
                    let parsedLocation = URL(string: location),
                    let roomHost = parsedLocation.host
                else {
                    continue
                }

                roomsByName[name] = Room(
                    name: name,
                    uuid: uuid,
                    coordinatorUUID: coordinatorUUID,
                    groupID: groupID,
                    host: roomHost,
                    airplayEnabled: member.attribute(forName: "AirPlayEnabled")?.stringValue == "1"
                )
            }
        }

        let rooms = roomsByName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if rooms.isEmpty {
            throw BroadcastError.message("Discovered Sonos devices, but no visible rooms were found.")
        }

        return rooms
    }

    private static func fetchZoneGroupState(host: String) throws -> String {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1" />
          </s:Body>
        </s:Envelope>
        """

        let data = try soapRequest(
            host: host,
            path: "/ZoneGroupTopology/Control",
            action: "urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState",
            body: body
        )

        let responseDocument = try parseXMLDocument(data)
        let nodes = try responseDocument.nodes(forXPath: "//*[local-name()='ZoneGroupState']")
        guard
            let zoneGroupState = (nodes.first as? XMLElement)?.stringValue,
            !zoneGroupState.isEmpty
        else {
            throw BroadcastError.message("Could not read Sonos ZoneGroupState from host \(host).")
        }

        return zoneGroupState
    }

    private static func selectAirPlayTarget(from selectedRooms: [Room], preferredAirPlayTarget: String?) throws -> Room {
        if let preferredAirPlayTarget {
            if let preferredRoom = selectedRooms.first(where: { $0.name == preferredAirPlayTarget && $0.airplayEnabled }) {
                return preferredRoom
            }
        }

        if let firstAirPlayRoom = selectedRooms.first(where: \.airplayEnabled) {
            return firstAirPlayRoom
        }

        throw BroadcastError.message("None of the selected rooms can be used as the Mac AirPlay target.")
    }

    private static func setMacOutput(roomName: String) throws -> String {
        let appleScript = """
        property targetDeviceName : ""
        property targetIdentifier : ""
        property soundMenuIdentifier : "\(soundMenuIdentifier)"

        on run argv
            set targetDeviceName to item 1 of argv
            set targetIdentifier to "sound-device-" & targetDeviceName

            tell application "System Events"
                tell process "ControlCenter"
                    set controlCenterProcess to it
                    set soundMenuItem to missing value
                    repeat with menuItemRef in every menu bar item of menu bar 1
                        try
                            if value of attribute "AXIdentifier" of menuItemRef is soundMenuIdentifier then
                                set soundMenuItem to menuItemRef
                                exit repeat
                            end if
                        end try
                    end repeat
                    if soundMenuItem is missing value then error "Could not find the Sound menu bar item in the menu bar."

                    if my soundPanelIsOpen(controlCenterProcess) is false then
                        click soundMenuItem
                    end if

                    repeat 20 times
                        if my soundPanelIsOpen(controlCenterProcess) then exit repeat
                        delay 0.1
                    end repeat

                    if my soundPanelIsOpen(controlCenterProcess) is false then error "Could not open the Sound output panel."

                    set availableIdentifiers to my availableOutputIdentifiers(controlCenterProcess)
                    repeat 100 times
                        if my listContains(availableIdentifiers, targetIdentifier) then exit repeat
                        delay 0.1
                        set availableIdentifiers to my availableOutputIdentifiers(controlCenterProcess)
                    end repeat

                    if my listContains(availableIdentifiers, targetIdentifier) is false then
                        error "Could not find " & targetIdentifier & ". Available outputs: " & my joinList(availableIdentifiers, ", ")
                    end if

                    repeat with checkboxRef in checkboxes of scroll area 1 of group 1 of window 1
                        try
                            set checkboxIdentifier to value of attribute "AXIdentifier" of checkboxRef
                            if checkboxIdentifier is targetIdentifier then
                                if (value of checkboxRef) is not 1 then click checkboxRef
                                exit repeat
                            end if
                        end try
                    end repeat

                    repeat 100 times
                        if my targetSelected(controlCenterProcess, targetIdentifier) then exit repeat
                        delay 0.1
                    end repeat

                    if my targetSelected(controlCenterProcess, targetIdentifier) is false then
                        error "Timed out while waiting for " & targetDeviceName & " to switch on."
                    end if

                    repeat with checkboxRef in checkboxes of scroll area 1 of group 1 of window 1
                        try
                            set checkboxIdentifier to value of attribute "AXIdentifier" of checkboxRef
                            if checkboxIdentifier starts with "sound-device-" then
                                if checkboxIdentifier is not targetIdentifier then
                                    if (value of checkboxRef) is 1 then click checkboxRef
                                end if
                            end if
                        end try
                    end repeat

                    delay 0.2
                    if my soundPanelIsOpen(controlCenterProcess) then click soundMenuItem
                end tell
            end tell

            return "Mac output switched to: " & targetDeviceName
        end run

        on listContains(itemList, expectedItem)
            repeat with itemValue in itemList
                if (contents of itemValue) is expectedItem then return true
            end repeat
            return false
        end listContains

        on joinList(itemList, separatorText)
            set joinedText to ""
            repeat with itemValue in itemList
                if joinedText is not "" then set joinedText to joinedText & separatorText
                set joinedText to joinedText & (contents of itemValue)
            end repeat
            return joinedText
        end joinList

        on soundPanelIsOpen(controlCenterProcess)
            tell application "System Events"
                tell controlCenterProcess
                    if (count of windows) is 0 then return false
                    try
                        set deviceCheckboxes to checkboxes of scroll area 1 of group 1 of window 1
                        repeat with checkboxRef in deviceCheckboxes
                            try
                                set checkboxIdentifier to value of attribute "AXIdentifier" of checkboxRef
                                if checkboxIdentifier starts with "sound-device-" then return true
                            end try
                        end repeat
                    end try
                end tell
            end tell
            return false
        end soundPanelIsOpen

        on targetSelected(controlCenterProcess, checkedIdentifier)
            tell application "System Events"
                tell controlCenterProcess
                    if (count of windows) is 0 then return false
                    try
                        set deviceCheckboxes to checkboxes of scroll area 1 of group 1 of window 1
                        repeat with checkboxRef in deviceCheckboxes
                            try
                                set checkboxIdentifier to value of attribute "AXIdentifier" of checkboxRef
                                if checkboxIdentifier is checkedIdentifier then
                                    return (value of checkboxRef) is 1
                                end if
                            end try
                        end repeat
                    end try
                end tell
            end tell
            return false
        end targetSelected

        on availableOutputIdentifiers(controlCenterProcess)
            tell application "System Events"
                tell controlCenterProcess
                    set availableIdentifiers to {}
                    if (count of windows) is 0 then return availableIdentifiers
                    try
                        repeat with checkboxRef in checkboxes of scroll area 1 of group 1 of window 1
                            try
                                set end of availableIdentifiers to (value of attribute "AXIdentifier" of checkboxRef)
                            end try
                        end repeat
                    end try
                    return availableIdentifiers
                end tell
            end tell
        end availableOutputIdentifiers
        """

        let result = try runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-", roomName],
            standardInput: Data(appleScript.utf8),
            timeoutSeconds: 25
        )

        guard result.terminationStatus == 0 else {
            let message = result.output.isEmpty ? "Unknown AppleScript error." : result.output
            throw BroadcastError.message(message)
        }

        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func joinRoomToCoordinator(joinerRoom: Room, coordinatorUUID: String) throws {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <CurrentURI>x-rincon:\(coordinatorUUID)</CurrentURI>
              <CurrentURIMetaData></CurrentURIMetaData>
            </u:SetAVTransportURI>
          </s:Body>
        </s:Envelope>
        """

        _ = try soapRequest(
            host: joinerRoom.host,
            path: "/MediaRenderer/AVTransport/Control",
            action: "urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI",
            body: body
        )
    }

    private static func soapRequest(host: String, path: String, action: String, body: String) throws -> Data {
        guard let url = URL(string: "http://\(host):1400\(path)") else {
            throw BroadcastError.message("Could not build a request URL for Sonos host \(host).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(action)\"", forHTTPHeaderField: "SOAPACTION")

        let semaphore = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)

        var responseData: Data?
        var responseError: Error?
        var statusCode: Int?

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            statusCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }

        task.resume()

        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            task.cancel()
            throw BroadcastError.message("Timed out while trying to reach Sonos host \(host).")
        }

        if let responseError {
            throw BroadcastError.message("Could not reach Sonos host \(host): \(responseError.localizedDescription)")
        }

        guard let statusCode, (200..<300).contains(statusCode) else {
            let bodyText = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw BroadcastError.message("Sonos host \(host) returned HTTP \(statusCode ?? -1). \(bodyText)")
        }

        guard let responseData else {
            throw BroadcastError.message("Sonos host \(host) returned no response body.")
        }

        return responseData
    }

    private static func parseXMLDocument(_ data: Data) throws -> XMLDocument {
        do {
            return try XMLDocument(data: data, options: [])
        } catch {
            throw BroadcastError.message("Could not parse the Sonos XML response: \(error.localizedDescription)")
        }
    }

    private static func parseXMLDocument(_ xmlString: String) throws -> XMLDocument {
        guard let data = xmlString.data(using: .utf8) else {
            throw BroadcastError.message("Could not decode the Sonos XML string.")
        }
        return try parseXMLDocument(data)
    }

    private static func runCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        timeoutSeconds: TimeInterval,
        allowPartialOutputOnTimeout: Bool = false
    ) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        if standardInput != nil {
            process.standardInput = inputPipe
        }

        do {
            try process.run()
        } catch {
            throw BroadcastError.message("Could not run \(executableURL.lastPathComponent): \(error.localizedDescription)")
        }

        if let standardInput {
            inputPipe.fileHandleForWriting.write(standardInput)
            inputPipe.fileHandleForWriting.closeFile()
        }

        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            waitGroup.leave()
        }

        let timedOut = waitGroup.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            process.terminate()
            _ = waitGroup.wait(timeout: .now() + 1)
            if process.isRunning {
                process.interrupt()
            }
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if timedOut && !allowPartialOutputOnTimeout {
            throw BroadcastError.message("\(executableURL.lastPathComponent) timed out after \(Int(timeoutSeconds)) seconds.")
        }

        if !timedOut && process.terminationStatus != 0 {
            let message = output.isEmpty ? "\(executableURL.lastPathComponent) failed with exit code \(process.terminationStatus)." : output
            throw BroadcastError.message(message)
        }

        return CommandResult(
            output: output,
            terminationStatus: process.terminationStatus,
            timedOut: timedOut
        )
    }
}
