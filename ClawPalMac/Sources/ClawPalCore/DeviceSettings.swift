import Foundation

public enum DisplayApp: Int, CaseIterable, Identifiable, Codable {
    case monitor = 0
    case clock = 1
    case music = 2
    case timer = 3
    case codex = 4
    case home = 5
    case weather = 6
    case claude = 7
    case shortcuts = 8

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .monitor: return "PC Monitor"
        case .clock: return "Clock"
        case .music: return "Music"
        case .timer: return "Timer"
        case .codex: return "Amp"
        case .home: return "Home"
        case .weather: return "Weather"
        case .claude: return "Claude Code"
        case .shortcuts: return "Shortcuts"
        }
    }

    public var healthName: String {
        switch self {
        case .monitor: return "pc_monitor"
        case .clock: return "clock"
        case .music: return "music"
        case .timer: return "timer"
        case .codex: return "codex"
        case .home: return "home"
        case .weather: return "weather"
        case .claude: return "claude"
        case .shortcuts: return "shortcuts"
        }
    }

    public var symbol: String {
        switch self {
        case .monitor: return "cpu"
        case .clock: return "clock"
        case .music: return "music.note"
        case .timer: return "timer"
        case .codex: return "bolt.horizontal.circle"
        case .home: return "house"
        case .weather: return "cloud.sun"
        case .claude: return "sparkles"
        case .shortcuts: return "square.grid.2x2"
        }
    }

    /// Apps that can be toggled on/off (Home = 5 is always enabled).
    public static var configurable: [DisplayApp] {
        [.monitor, .clock, .music, .timer, .codex, .claude, .weather, .shortcuts]
    }

    public static func fromHealthName(_ name: String) -> DisplayApp? {
        allCases.first { $0.healthName == name }
    }
}

public struct DeviceSettings: Codable, Equatable {
    public static let currentSchema = 8
    public static let themes = ["crab", "studio", "crabv2", "crastudio"]
    public static let accents = ["champagne", "sage", "ice", "silver", "rose", "lavender", "copper", "teal"]

    public var schema: Int = currentSchema
    public var language: String = "en"
    public var enabledApps: Int = 511
    public var homeOrder: [Int] = [0, 4, 7, 2, 1]
    public var use24h: Bool = true
    public var weatherEnabled: Bool = true
    public var weatherFahrenheit: Bool = false
    public var theme: String = "crab"
    public var accent: String = "champagne"
    public var city: String = "London"
    public var timezone: String = "GMT0BST,M3.5.0/1,M10.5.0"
    public var latitude: Double = 51.5074
    public var longitude: Double = -0.1278
    public var dimBehavior: Int = 1
    public var dimAfterSeconds: Int = 60
    public var dimBrightness: Int = 40
    public var nightEnabled: Bool = true
    public var nightStart: Int = 1
    public var nightEnd: Int = 10
    public var offlineApp: Int = 1

    enum CodingKeys: String, CodingKey {
        case schema, language, theme, accent, city, timezone, latitude, longitude
        case enabledApps = "enabled_apps"
        case homeOrder = "home_order"
        case use24h = "use_24h"
        case weatherEnabled = "weather_enabled"
        case weatherFahrenheit = "weather_fahrenheit"
        case dimBehavior = "dim_behavior"
        case dimAfterSeconds = "dim_after_seconds"
        case dimBrightness = "dim_brightness"
        case nightEnabled = "night_enabled"
        case nightStart = "night_start"
        case nightEnd = "night_end"
        case offlineApp = "offline_app"
    }

    public init() {}

    public func isEnabled(_ app: DisplayApp) -> Bool {
        (enabledApps & (1 << app.rawValue)) != 0
    }

    public mutating func setEnabled(_ app: DisplayApp, _ enabled: Bool) {
        guard app != .home else { return }
        if enabled {
            enabledApps |= (1 << app.rawValue)
        } else {
            enabledApps &= ~(1 << app.rawValue)
            homeOrder.removeAll { $0 == app.rawValue }
            if offlineApp == app.rawValue {
                offlineApp = isEnabled(.clock) ? DisplayApp.clock.rawValue : DisplayApp.home.rawValue
            }
        }
    }

    public mutating func toggleHomeSlot(_ app: DisplayApp) {
        guard app != .home, isEnabled(app) else { return }
        if let idx = homeOrder.firstIndex(of: app.rawValue) {
            homeOrder.remove(at: idx)
        } else if homeOrder.count < 5 {
            homeOrder.append(app.rawValue)
        }
    }
}

public struct DeviceHealth: Decodable, Equatable {
    public struct NfcHealth: Decodable, Equatable {
        public let detected: Bool
        public let version: Int
        public let lastUid: String

        enum CodingKeys: String, CodingKey {
            case detected, version
            case lastUid = "last_uid"
        }
    }

    public struct UiHealth: Decodable, Equatable {
        public let app: String
        public let dimmed: Bool?
        public let screenOff: Bool?
        public let needsYou: Bool?

        enum CodingKeys: String, CodingKey {
            case app, dimmed
            case screenOff = "screen_off"
            case needsYou = "needs_you"
        }
    }

    public let version: String
    public let nfc: NfcHealth?
    public let ui: UiHealth?
}

public enum DeviceSettingsClient {
    public static func fetchSettings(deviceId: String, token: String, host: String?) async throws -> DeviceSettings {
        guard let ep = await Task.detached(operation: { ClawPalDiscovery.discover(deviceId: deviceId, token: token, lastHost: host, tries: 2) }).value else {
            throw ClawPalError.displayNotFound
        }
        let (status, data) = try await ClawPalHTTP.signedGet(endpoint: ep, token: token, path: "/settings")
        guard status == 200 else {
            throw ClawPalError.httpError(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(DeviceSettings.self, from: data)
    }

    public static func saveSettings(_ settings: DeviceSettings, deviceId: String, token: String, host: String?) async throws -> Bool {
        guard let ep = await Task.detached(operation: { ClawPalDiscovery.discover(deviceId: deviceId, token: token, lastHost: host, tries: 2) }).value else {
            throw ClawPalError.displayNotFound
        }
        let body = try JSONEncoder().encode(settings)
        let (status, data) = try await ClawPalHTTP.signedPost(
            endpoint: ep,
            token: token,
            path: "/settings",
            body: body,
            contentType: "application/json"
        )
        guard status == 200 else {
            throw ClawPalError.httpError(status, String(data: data, encoding: .utf8) ?? "")
        }
        struct Reply: Decodable { let saved: Bool; let restarting: Bool? }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.saved else { throw ClawPalError.invalidResponse("Display did not confirm saving settings") }
        return reply.restarting ?? false
    }

    public static func fetchHealth(deviceId: String, token: String, host: String?) async throws -> DeviceHealth {
        guard let ep = await Task.detached(operation: { ClawPalDiscovery.discover(deviceId: deviceId, token: token, lastHost: host, tries: 2) }).value else {
            throw ClawPalError.displayNotFound
        }
        let (status, data) = try await ClawPalHTTP.signedGet(endpoint: ep, token: token, path: "/health")
        guard status == 200 else {
            throw ClawPalError.httpError(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(DeviceHealth.self, from: data)
    }

    /// Requests the display to switch directly to an app screen (`POST /app` on our custom firmware).
    public static func selectApp(_ app: DisplayApp, deviceId: String, token: String, host: String?) async throws {
        guard let ep = await Task.detached(operation: { ClawPalDiscovery.discover(deviceId: deviceId, token: token, lastHost: host, tries: 2) }).value else {
            throw ClawPalError.displayNotFound
        }
        let body = try JSONSerialization.data(withJSONObject: ["app": app.rawValue])
        let (status, data) = try await ClawPalHTTP.signedPost(
            endpoint: ep,
            token: token,
            path: "/app",
            body: body,
            contentType: "application/json"
        )
        guard status == 200 else {
            throw ClawPalError.httpError(status, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
