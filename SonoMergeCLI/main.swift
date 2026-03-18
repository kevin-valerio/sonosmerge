import Foundation

struct DiscoverResponse: Codable {
    let rooms: [Room]
}

private func makeParser() -> ArgumentParser {
    ArgumentParser()
}

private struct ArgumentParser {
    let arguments: [String]

    init(arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        self.arguments = arguments
    }

    func parse() throws -> Command {
        guard let command = arguments.first else {
            throw BroadcastError.message(usageText)
        }

        switch command {
        case "discover":
            return .discover

        case "broadcast":
            return try parseBroadcast(Array(arguments.dropFirst()))

        default:
            throw BroadcastError.message(usageText)
        }
    }

    private func parseBroadcast(_ arguments: [String]) throws -> Command {
        var roomNames: [String] = []
        var preferredAirPlayTarget: String?
        var wantsJSON = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--rooms":
                index += 1
                while index < arguments.count, !arguments[index].hasPrefix("--") {
                    roomNames.append(arguments[index])
                    index += 1
                }
                continue

            case "--primary-room":
                index += 1
                guard index < arguments.count else {
                    throw BroadcastError.message("Missing value for --primary-room.")
                }
                preferredAirPlayTarget = arguments[index]

            case "--json":
                wantsJSON = true

            default:
                throw BroadcastError.message("Unknown argument: \(argument)\n\n\(usageText)")
            }

            index += 1
        }

        if roomNames.isEmpty {
            throw BroadcastError.message("Use --rooms with at least one room name.\n\n\(usageText)")
        }

        return .broadcast(
            roomNames: roomNames,
            preferredAirPlayTarget: preferredAirPlayTarget,
            wantsJSON: wantsJSON
        )
    }

    private var usageText: String {
        """
        Usage:
          sonos_broadcast discover
          sonos_broadcast broadcast --rooms "Salon TV" "Cuisine" [--primary-room "Salon TV"] [--json]
        """
    }
}

private enum Command {
    case discover
    case broadcast(roomNames: [String], preferredAirPlayTarget: String?, wantsJSON: Bool)
}

private func main() -> Int32 {
    do {
        switch try makeParser().parse() {
        case .discover:
            let rooms = try SonoMergeCore.discoverRooms()
            let data = try JSONEncoder.prettyPrinted.encode(DiscoverResponse(rooms: rooms))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0

        case .broadcast(let roomNames, let preferredAirPlayTarget, let wantsJSON):
            let result = try SonoMergeCore.broadcast(
                roomNames: roomNames,
                preferredAirPlayTarget: preferredAirPlayTarget
            )
            if wantsJSON {
                let data = try JSONEncoder.prettyPrinted.encode(result)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                let joinedRoomsText = result.joinedRooms.isEmpty ? "none" : result.joinedRooms.joined(separator: ", ")
                print("Mac output switched to \(result.airplayTarget), and these rooms joined that Sonos room: \(joinedRoomsText).")
            }
            return 0
        }
    } catch let error as BroadcastError {
        FileHandle.standardError.write(Data("\(error.text)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        return 1
    }
}

extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

exit(main())
