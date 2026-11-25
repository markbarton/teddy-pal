import Foundation

/// Safe display text matching firmware `valid_display_utf8` and buffer byte limits (`length < bufferSize`).
public func clawpalDisplayText(_ value: String?, maxBufferBytes: Int) -> String {
    guard let value, !value.isEmpty, maxBufferBytes > 1 else { return "" }
    var out = ""
    var usedBytes = 0
    let maxBytes = maxBufferBytes - 1
    for scalar in value.unicodeScalars {
        let v = scalar.value
        if v < 32 || (v >= 0x7F && v <= 0x9F) || v == 0x2028 || v == 0x2029 || (v >= 0xD800 && v <= 0xDFFF) {
            continue
        }
        let s = String(scalar)
        let n = s.utf8.count
        if usedBytes + n > maxBytes { break }
        out.append(s)
        usedBytes += n
    }
    return out
}

public func clawpalLimitText(_ value: String?, maxUtf8Bytes: Int) -> String {
    guard let value, !value.isEmpty, maxUtf8Bytes > 0 else { return "" }
    var out = ""
    var usedBytes = 0
    for scalar in value.unicodeScalars {
        let v = scalar.value
        let ch: String
        if v < 32 || (v >= 0x7F && v <= 0x9F) || v == 0x2028 || v == 0x2029 || (v >= 0xD800 && v <= 0xDFFF) {
            ch = " "
        } else {
            ch = String(scalar)
        }
        let n = ch.utf8.count
        if usedBytes + n > maxUtf8Bytes { break }
        out.append(ch)
        usedBytes += n
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Telemetry Frame (pc.stats v1)

public struct CpuStats: Codable, Equatable {
    public var usage: Double?
    public var temperature: Double?
    public var name: String
}

public struct GpuStats: Codable, Equatable {
    public var usage: Double?
    public var temperature: Double?
    public var vramUsedMb: Double?
    public var vramTotalMb: Double?
    public var name: String

    enum CodingKeys: String, CodingKey {
        case usage, temperature, name
        case vramUsedMb = "vram_used_mb"
        case vramTotalMb = "vram_total_mb"
    }
}

public struct MemoryStats: Codable, Equatable {
    public var usedMb: Int
    public var totalMb: Int
    public var usage: Double

    enum CodingKeys: String, CodingKey {
        case usedMb = "used_mb"
        case totalMb = "total_mb"
        case usage
    }
}

public struct NetworkStats: Codable, Equatable {
    public var rxBps: Int64
    public var txBps: Int64

    enum CodingKeys: String, CodingKey {
        case rxBps = "rx_bps"
        case txBps = "tx_bps"
    }
}

public struct MusicStats: Codable, Equatable {
    public var running: Bool = false
    public var available: Bool = false
    public var playing: Bool = false
    public var title: String = ""
    public var artist: String = ""
    public var album: String = ""
    public var positionS: Int = 0
    public var durationS: Int = 0
    public var canPlayPause: Bool = false
    public var canNext: Bool = false
    public var canPrevious: Bool = false
    public var canShuffle: Bool = false
    public var shuffle: Bool = false
    public var canRepeat: Bool = false
    public var repeatMode: Int = 0
    public var canSeek: Bool = false
    public var canVolume: Bool = false
    public var volume: Int = 0
    public var muted: Bool = false
    public var source: String = ""
    public var artColor: Int = 0
    public var artId: Int = 0
    public var controlId: Int?
    public var controlOk: Bool?
    public var controlError: String?

    enum CodingKeys: String, CodingKey {
        case running, available, playing, title, artist, album, shuffle, volume, muted, source
        case positionS = "position_s"
        case durationS = "duration_s"
        case canPlayPause = "can_play_pause"
        case canNext = "can_next"
        case canPrevious = "can_previous"
        case canShuffle = "can_shuffle"
        case canRepeat = "can_repeat"
        case repeatMode = "repeat"
        case canSeek = "can_seek"
        case canVolume = "can_volume"
        case artColor = "art_color"
        case artId = "art_id"
        case controlId = "control_id"
        case controlOk = "control_ok"
        case controlError = "control_error"
    }

    public init() {}
}

public struct ProviderWindow: Codable, Equatable {
    public var available: Bool = false
    public var remainingPercent: Double = 0
    public var windowMinutes: Int = 0
    public var resetText: String = ""
    public var resetsAt: Int = 0

    enum CodingKeys: String, CodingKey {
        case available
        case remainingPercent = "remaining_percent"
        case windowMinutes = "window_minutes"
        case resetText = "reset_text"
        case resetsAt = "resets_at"
    }

    public init(available: Bool = false, remainingPercent: Double = 0, windowMinutes: Int = 0, resetText: String = "", resetsAt: Int = 0) {
        self.available = available
        self.remainingPercent = remainingPercent
        self.windowMinutes = windowMinutes
        self.resetText = resetText
        self.resetsAt = resetsAt
    }

    public static let empty = ProviderWindow()
}

public struct ProviderTaskItem: Codable, Equatable, Identifiable {
    public var id: String { "\(project)|\(title)|\(state)|\(ageS)" }
    public var title: String
    public var project: String
    public var detail: String?
    public var state: String
    public var ageS: Int

    enum CodingKeys: String, CodingKey {
        case title, project, detail, state
        case ageS = "age_s"
    }

    public init(title: String, project: String, state: String, ageS: Int, detail: String? = nil) {
        self.title = title
        self.project = project
        self.detail = detail
        self.state = state
        self.ageS = ageS
    }
}

public struct ProviderActivity: Codable, Equatable {
    public var available: Bool
    public var stale: Bool
    public var status: String
    public var ageS: Int
    public var workingCount: Int
    public var totalCount: Int
    public var items: [ProviderTaskItem]

    enum CodingKeys: String, CodingKey {
        case available, stale, status, items
        case ageS = "age_s"
        case workingCount = "working_count"
        case totalCount = "total_count"
    }

    public init(available: Bool, stale: Bool, status: String, ageS: Int, workingCount: Int, totalCount: Int, items: [ProviderTaskItem]) {
        self.available = available
        self.stale = stale
        self.status = status
        self.ageS = ageS
        self.workingCount = workingCount
        self.totalCount = totalCount
        self.items = items
    }
}

public struct ProviderStats: Codable, Equatable {
    public var running: Bool
    public var available: Bool
    public var stale: Bool
    public var status: String
    public var plan: String
    public var ageS: Int
    public var primary: ProviderWindow?
    public var secondary: ProviderWindow?
    public var activity: ProviderActivity?

    enum CodingKeys: String, CodingKey {
        case running, available, stale, status, plan, primary, secondary, activity
        case ageS = "age_s"
    }

    public init(running: Bool, available: Bool, stale: Bool, status: String, plan: String, ageS: Int, primary: ProviderWindow? = nil, secondary: ProviderWindow? = nil, activity: ProviderActivity? = nil) {
        self.running = running
        self.available = available
        self.stale = stale
        self.status = status
        self.plan = plan
        self.ageS = ageS
        self.primary = primary
        self.secondary = secondary
        self.activity = activity
    }
}

public struct TelemetryFrame: Codable {
    public var type: String = "pc.stats"
    public var v: Int = 1
    public var seq: Int
    public var timestamp: Int64
    public var hostname: String
    public var uptimeS: Int
    public var cpu: CpuStats
    public var gpu: GpuStats
    public var memory: MemoryStats
    public var network: NetworkStats
    public var music: MusicStats
    public var codex: ProviderStats?
    public var claude: ProviderStats?
    public var autoOpenApps: Bool = false

    enum CodingKeys: String, CodingKey {
        case type, v, seq, timestamp, hostname, cpu, gpu, memory, network, music, codex, claude
        case uptimeS = "uptime_s"
        case autoOpenApps = "auto_open_apps"
    }
}
