import CoreAudio
import Foundation

public enum AudioRouteMode: String, Codable, CaseIterable, Identifiable {
    case `default` = "default"
    case airplay = "airplay"
    case coreaudio = "coreaudio"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .default: return "Current output (don't change)"
        case .airplay: return "Apple Music AirPlay speaker (keeps Mac audio separate)"
        case .coreaudio: return "Mac output device (e.g. Bluetooth Echo)"
        }
    }
}

public struct JukeboxAudioRoute: Codable, Equatable {
    public var mode: AudioRouteMode = .default
    public var deviceName: String = ""

    enum CodingKeys: String, CodingKey {
        case mode
        case deviceName = "device_name"
    }

    public init(mode: AudioRouteMode = .default, deviceName: String = "") {
        self.mode = mode
        self.deviceName = deviceName
    }
}

public struct AirPlayDeviceInfo: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let kind: String
    public let available: Bool
    public let selected: Bool
}

public struct CoreAudioOutputDevice: Identifiable, Equatable {
    public var id: AudioDeviceID { deviceID }
    public let deviceID: AudioDeviceID
    public let name: String
    public let isBluetooth: Bool
}

public enum AudioRouting {
    public static var settingsURL: URL {
        ClawPalPaths.home.appendingPathComponent("nfc_audio_route.json")
    }

    public static func loadRoute(from url: URL = settingsURL) -> JukeboxAudioRoute {
        guard let data = try? Data(contentsOf: url),
              let route = try? JSONDecoder().decode(JukeboxAudioRoute.self, from: data) else {
            return JukeboxAudioRoute()
        }
        return route
    }

    public static func saveRoute(_ route: JukeboxAudioRoute, to url: URL = settingsURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(route)
        try data.write(to: url, options: .atomic)
    }

    /// Lists Music.app's AirPlay devices (e.g. "Mac Studio", "Living Room", etc.).
    public static func listAirPlayDevices() -> [AirPlayDeviceInfo] {
        let sep = "\u{1f}"
        let script = """
        tell application "Music"
          set out to ""
          repeat with d in every AirPlay device
            set out to out & (name of d) & "\(sep)" & (kind of d as text) & "\(sep)" & (available of d) & "\(sep)" & (selected of d) & linefeed
          end repeat
          return out
        end tell
        """
        guard let raw = MediaController.runOsascript(script, timeout: 6) else { return [] }
        var result: [AirPlayDeviceInfo] = []
        for line in raw.components(separatedBy: .newlines) where !line.isEmpty {
            let parts = line.components(separatedBy: sep)
            guard parts.count >= 4 else { continue }
            result.append(AirPlayDeviceInfo(
                name: parts[0],
                kind: parts[1],
                available: parts[2] == "true",
                selected: parts[3] == "true"
            ))
        }
        return result
    }

    /// Lists all macOS CoreAudio output devices (including Bluetooth-paired Amazon Echo speakers).
    public static func listCoreAudioOutputs() -> [CoreAudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }

        var outputs: [CoreAudioOutputDevice] = []
        for devId in ids {
            guard outputChannelCount(devId) > 0, let name = deviceName(devId) else { continue }
            let transport = deviceTransport(devId)
            let isBT = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            outputs.append(CoreAudioOutputDevice(deviceID: devId, name: name, isBluetooth: isBT))
        }
        return outputs.sorted { a, b in
            if a.isBluetooth != b.isBluetooth { return a.isBluetooth }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Applies the selected jukebox output route before starting playback.
    public static func applyRoute(_ route: JukeboxAudioRoute) -> (Bool, String) {
        switch route.mode {
        case .default:
            return (true, "")
        case .airplay:
            guard !route.deviceName.isEmpty else { return (false, "no AirPlay speaker selected") }
            let esc = route.deviceName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "Music"
              set targetDev to first AirPlay device whose name is "\(esc)"
              set current AirPlay devices to {targetDev}
            end tell
            """
            return MediaController.runOsascript(script, timeout: 6) != nil
                ? (true, "routed Music to AirPlay '\(route.deviceName)'")
                : (false, "could not route Music to AirPlay '\(route.deviceName)'")
        case .coreaudio:
            guard !route.deviceName.isEmpty else { return (false, "no Mac output speaker selected") }
            let outputs = listCoreAudioOutputs()
            guard let target = outputs.first(where: { $0.name == route.deviceName }) else {
                return (false, "output device '\(route.deviceName)' not connected")
            }
            var devId = target.deviceID
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &devId
            )
            guard status == noErr else { return (false, "CoreAudio switch failed (\(status))") }
            // Ensure Music.app plays through Computer (the newly selected CoreAudio output) if open.
            let selectComputer = """
            tell application "Music"
              try
                set comp to first AirPlay device whose kind is computer
                set current AirPlay devices to {comp}
              end try
            end tell
            """
            _ = MediaController.runOsascript(selectComputer, timeout: 4)
            return (true, "switched Mac output to '\(route.deviceName)'")
        }
    }

    private static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? (cfName as String) : nil
    }

    private static func deviceTransport(_ deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport)
        return transport
    }
}
