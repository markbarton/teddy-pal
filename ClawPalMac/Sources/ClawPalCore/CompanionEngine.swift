import Combine
import Foundation

public struct LogLine: Identifiable, Equatable {
    public let id = UUID()
    public let time: String
    public let message: String
}

public enum ConnectionStatus: Equatable {
    case stopped
    case searching
    case connected(String)
    case error(String)

    public var label: String {
        switch self {
        case .stopped: return "Paused"
        case .searching: return "Searching…"
        case .connected(let ip): return "Connected · \(ip)"
        case .error(let msg): return msg
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

@MainActor
public final class CompanionEngine: ObservableObject {
    @Published public var status: ConnectionStatus = .stopped
    @Published public var isPaused: Bool = false
    @Published public var deviceId: String = ""
    @Published public var connectedHost: String?
    @Published public var firmwareVersion: String = ""
    @Published public var activeApp: DisplayApp?
    @Published public var nfcDetected: Bool = false
    @Published public var nfcVersion: Int = 0
    @Published public var lastNfcUid: String = ""
    @Published public var nfcCards: [NfcAlbumEntry] = []
    @Published public var jukeboxRoute: JukeboxAudioRoute = AudioRouting.loadRoute()
    @Published public var airPlayDevices: [AirPlayDeviceInfo] = []
    @Published public var coreAudioOutputs: [CoreAudioOutputDevice] = []
    @Published public var routeStatus: String = ""
    @Published public var accessibilityTrusted: Bool = NfcAlbumManager.isAccessibilityTrusted

    @Published public var deviceSettings: DeviceSettings = DeviceSettings()
    @Published public var settingsLoaded: Bool = false
    @Published public var settingsStatus: String = ""
    @Published public var isSavingSettings: Bool = false
    @Published public var screenSwitchNote: String = ""

    @Published public var cpuUsage: Double = 0
    @Published public var memoryUsage: Double = 0
    @Published public var memoryText: String = ""
    @Published public var music: MusicStats = MusicStats()
    @Published public var coverImageData: Data?
    @Published public var ampStats: ProviderStats?
    @Published public var ampUsage: AmpUsageSummary?
    @Published public var ampThreads: [AmpThreadDetail] = []
    @Published public var ampWaitingThreads: [AmpThreadDetail] = []
    @Published public var isRefreshingAmp: Bool = false
    @Published public var claudeStats: ProviderStats?
    @Published public var claudeStatusDetail: String = ""
    @Published public var isRefreshingClaude: Bool = false
    @Published public var claudeLiveLimitsEnabled: Bool = UserDefaults.standard.object(forKey: "claudeLiveLimitsEnabled") as? Bool ?? true
    @Published public var logs: [LogLine] = []

    private let statsCollector = SystemStatsCollector()
    private let mediaController = MediaController()
    private let ampProvider = AmpProvider()
    private let claudeProvider = ClaudeProvider()
    private let claudeLiveLimits = ClaudeLiveLimits()
    public let nfcManager = NfcAlbumManager()

    private var config: PairingConfig?
    private var token: String = ""
    private var mainLoopTask: Task<Void, Never>?
    private var mediaPollTask: Task<Void, Never>?
    private var ampPollTask: Task<Void, Never>?
    private var claudeLiveTask: Task<Void, Never>?
    private var seq: Int = 0

    private let wsSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        return URLSession(configuration: cfg)
    }()

    public init() {
        reloadNfcCards()
        if let tap = nfcManager.readLastTap() {
            lastNfcUid = tap.uid
        }
        refreshAudioDevices()
    }

    public func refreshAccessibilityStatus() {
        accessibilityTrusted = NfcAlbumManager.isAccessibilityTrusted
    }

    public func requestAccessibilityPermission() {
        accessibilityTrusted = NfcAlbumManager.promptAccessibilityPermission()
    }

    public func refreshAudioDevices() {
        Task.detached { [weak self] in
            let core = AudioRouting.listCoreAudioOutputs()
            let airplay = AudioRouting.listAirPlayDevices()
            await MainActor.run { [weak self] in
                self?.coreAudioOutputs = core
                self?.airPlayDevices = airplay
            }
        }
    }

    public func saveJukeboxRoute(_ route: JukeboxAudioRoute) {
        jukeboxRoute = route
        do {
            try AudioRouting.saveRoute(route)
            routeStatus = route.mode == .default ? "Using current Mac output" : "Saved: \(route.deviceName)"
            appendLog("Jukebox speaker set -> \(route.mode.rawValue): \(route.deviceName.isEmpty ? "default" : route.deviceName)")
        } catch {
            routeStatus = error.localizedDescription
        }
    }

    public func applyJukeboxRouteNow() {
        let route = jukeboxRoute
        routeStatus = "Switching speaker…"
        Task.detached { [weak self] in
            let (ok, msg) = AudioRouting.applyRoute(route)
            await MainActor.run { [weak self] in
                self?.routeStatus = msg.isEmpty ? (ok ? "Applied" : "Failed") : msg
                self?.appendLog("Speaker switch: \(msg.isEmpty ? (ok ? "ok" : "failed") : msg)")
            }
        }
    }

    public func start() {
        guard mainLoopTask == nil else { return }
        isPaused = false
        do {
            let cfg = try PairingConfig.load()
            let tok = try ClawPalKeychain.loadToken(device: cfg.device)
            self.config = cfg
            self.token = tok
            self.deviceId = cfg.effectiveDeviceId
            self.connectedHost = cfg.lastIp
            appendLog("Loaded pairing for \(cfg.effectiveDeviceId) (last IP \(cfg.lastIp ?? "none"))")
            appendLog(ampProvider.executable != nil ? "Amp threads: on (\(ampProvider.executable!))" : "Amp threads: off (no amp CLI found)")
            appendLog(claudeProvider.isActive ? "Claude Code: on (hooks installed)" : "Claude Code: off")
        } catch {
            status = .error(error.localizedDescription)
            appendLog("Startup error: \(error.localizedDescription)")
            return
        }

        let media = self.mediaController
        mediaPollTask = Task.detached {
            while !Task.isCancelled {
                media.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let amp = self.ampProvider
        ampPollTask = Task.detached { [weak self] in
            var seenWaiting: Set<String> = []
            var initialized = false
            while !Task.isCancelled {
                amp.poll()
                let details = amp.currentDetails()
                let snap = amp.snapshot()
                let currentIds = Set(details.waiting.map(\.id))
                let newlyWaiting = initialized ? details.waiting.filter { !seenWaiting.contains($0.id) } : []
                seenWaiting = currentIds
                initialized = true
                await MainActor.run { [weak self] in
                    self?.ampUsage = details.usage
                    self?.ampThreads = details.threads
                    self?.ampWaitingThreads = details.waiting
                    self?.ampStats = snap
                    for t in newlyWaiting {
                        let msg = t.statusMessage.isEmpty ? "" : " — \(t.statusMessage)"
                        self?.appendLog("Amp needs you: \(t.title)\(msg)")
                    }
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        startClaudeLiveTask()
        mainLoopTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    public func setClaudeLiveLimitsEnabled(_ enabled: Bool) {
        claudeLiveLimitsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "claudeLiveLimitsEnabled")
        if enabled {
            startClaudeLiveTask()
            appendLog("Claude live limits: on")
        } else {
            claudeLiveTask?.cancel()
            claudeLiveTask = nil
            claudeLiveLimits.reset()
            appendLog("Claude live limits: off")
        }
    }

    private func startClaudeLiveTask() {
        claudeLiveTask?.cancel()
        guard claudeLiveLimitsEnabled else { return }
        let live = self.claudeLiveLimits
        let provider = self.claudeProvider
        claudeLiveTask = Task.detached {
            while !Task.isCancelled {
                let running = provider.snapshot()?.running ?? false
                await live.refreshIfNeeded(isRunning: running)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    public func stop() {
        isPaused = true
        mainLoopTask?.cancel()
        mainLoopTask = nil
        mediaPollTask?.cancel()
        mediaPollTask = nil
        ampPollTask?.cancel()
        ampPollTask = nil
        claudeLiveTask?.cancel()
        claudeLiveTask = nil
        status = .stopped
        appendLog("Companion paused")
    }

    public func togglePause() {
        if isPaused || mainLoopTask == nil { start() } else { stop() }
    }

    public func reloadNfcCards() {
        nfcCards = nfcManager.loadAll()
    }

    public func addNfcCard(uid: String, target: String, label: String, forceAppleMusicName: Bool = false) -> String? {
        guard let entry = NfcAlbumManager.makeEntry(uid: uid, target: target, label: label, forceAppleMusicName: forceAppleMusicName) else {
            return "Invalid card UID or target"
        }
        do {
            try nfcManager.save(entry)
            reloadNfcCards()
            appendLog("Mapped NFC \(entry.uid) -> [\(entry.service)] \(entry.label)")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func removeNfcCard(uid: String) {
        do {
            try nfcManager.remove(uid: uid)
            reloadNfcCards()
            appendLog("Removed NFC card \(uid)")
        } catch {
            appendLog("Remove NFC card failed: \(error.localizedDescription)")
        }
    }

    public func testPlayNfcCard(_ entry: NfcAlbumEntry) {
        if status.isConnected {
            selectDisplayApp(.music)
        }
        let manager = self.nfcManager
        let media = self.mediaController
        Task.detached { [weak self] in
            let (ok, note) = manager.play(entry)
            if ok { media.poll() }
            await MainActor.run { [weak self] in
                self?.appendLog("Test play \(entry.label): \(ok ? (note.isEmpty ? "ok" : note) : note)")
            }
        }
    }

    public func mediaAction(_ action: String, value: Int? = nil) {
        let media = self.mediaController
        Task.detached {
            _ = media.execute(action: action, value: value)
        }
    }

    public func refreshAmpNow() {
        guard !isRefreshingAmp else { return }
        isRefreshingAmp = true
        let amp = self.ampProvider
        Task.detached { [weak self] in
            amp.poll(forceUsage: true)
            let details = amp.currentDetails()
            let snap = amp.snapshot()
            await MainActor.run { [weak self] in
                self?.ampUsage = details.usage
                self?.ampThreads = details.threads
                self?.ampWaitingThreads = details.waiting
                self?.ampStats = snap
                self?.isRefreshingAmp = false
                if let u = details.usage {
                    self?.appendLog(String(format: "Amp refreshed: %d need you, $%.2f/$%.2f", details.waiting.count, u.agentRemainingDollars, u.agentTotalDollars))
                } else {
                    self?.appendLog("Amp refreshed: \(details.waiting.count) need you")
                }
            }
        }
    }

    public func openAmpThread(_ id: String) {
        Task.detached {
            AmpProvider.openThread(id: id)
        }
    }

    public func refreshClaudeNow() {
        guard !isRefreshingClaude else { return }
        isRefreshingClaude = true
        let live = self.claudeLiveLimits
        let provider = self.claudeProvider
        let liveEnabled = self.claudeLiveLimitsEnabled
        Task.detached { [weak self] in
            provider.invalidateHistoryCache()
            let local = provider.snapshot()
            if liveEnabled {
                await live.forceRefresh(isRunning: local?.running ?? false)
            }
            let (quota, liveStatus) = live.currentQuota()
            let detail = liveEnabled ? live.currentDetailStatus() : "Live limits off"
            let now = Date().timeIntervalSince1970
            let merged: ProviderStats?
            if liveEnabled {
                let base = local ?? ProviderStats(
                    running: false, available: false, stale: false, status: "closed", plan: "", ageS: 0,
                    primary: .empty, secondary: .empty,
                    activity: ProviderActivity(available: false, stale: true, status: "closed", ageS: 0, workingCount: 0, totalCount: 0, items: [])
                )
                merged = ClaudeLiveLimits.merge(local: base, quota: quota, status: liveStatus, now: now)
            } else {
                merged = local
            }
            await MainActor.run { [weak self] in
                self?.claudeStats = merged
                self?.claudeStatusDetail = detail
                self?.isRefreshingClaude = false
                self?.appendLog("Claude refreshed: \(detail)")
            }
        }
    }

    public func refreshDisplaySettings() {
        guard !deviceId.isEmpty, !token.isEmpty else { return }
        let dev = deviceId, tok = token, host = connectedHost
        Task {
            do {
                let s = try await DeviceSettingsClient.fetchSettings(deviceId: dev, token: tok, host: host)
                self.deviceSettings = s
                self.settingsLoaded = true
                self.settingsStatus = "Loaded from display"
            } catch {
                self.settingsStatus = error.localizedDescription
            }
        }
    }

    public func saveDisplaySettings() {
        guard !deviceId.isEmpty, !token.isEmpty else { return }
        let dev = deviceId, tok = token, host = connectedHost, s = deviceSettings
        isSavingSettings = true
        settingsStatus = "Saving to display…"
        Task {
            defer { self.isSavingSettings = false }
            do {
                let restarting = try await DeviceSettingsClient.saveSettings(s, deviceId: dev, token: tok, host: host)
                self.settingsStatus = restarting ? "Saved (display restarting for new look)" : "Saved to display"
                self.appendLog("Display settings saved" + (restarting ? " (restarting)" : ""))
            } catch {
                self.settingsStatus = error.localizedDescription
                self.appendLog("Save settings failed: \(error.localizedDescription)")
            }
        }
    }

    public func selectDisplayApp(_ app: DisplayApp) {
        guard !deviceId.isEmpty, !token.isEmpty else { return }
        let dev = deviceId, tok = token, host = connectedHost
        screenSwitchNote = ""
        Task {
            do {
                try await DeviceSettingsClient.selectApp(app, deviceId: dev, token: tok, host: host)
                self.activeApp = app
                self.appendLog("Switched display screen -> \(app.label)")
            } catch let ClawPalError.httpError(code, _) where code == 404 || code == 405 {
                self.screenSwitchNote = "Live screen switching requires adding POST /app to the firmware fork (we can flash that next)."
            } catch {
                self.screenSwitchNote = error.localizedDescription
            }
        }
    }

    public func refreshHealth() {
        guard !deviceId.isEmpty, !token.isEmpty else { return }
        let dev = deviceId, tok = token, host = connectedHost
        Task {
            do {
                let health = try await DeviceSettingsClient.fetchHealth(deviceId: dev, token: tok, host: host)
                self.firmwareVersion = health.version
                if let ui = health.ui {
                    self.activeApp = DisplayApp.fromHealthName(ui.app)
                }
                if let nfc = health.nfc {
                    self.nfcDetected = nfc.detected
                    self.nfcVersion = nfc.version
                    if !nfc.lastUid.isEmpty { self.lastNfcUid = nfc.lastUid }
                }
            } catch {
                // Non-fatal
            }
        }
    }

    // MARK: - WebSocket Session Loop

    private func runConnectionLoop() async {
        var retrySeconds: UInt64 = 1
        while !Task.isCancelled {
            status = .searching
            do {
                try await runSingleSession()
                retrySeconds = 1
            } catch is CancellationError {
                break
            } catch {
                appendLog("Connection: \(error.localizedDescription)")
                status = .searching
            }
            try? await Task.sleep(for: .seconds(retrySeconds))
            retrySeconds = min(retrySeconds * 2, 10)
        }
    }

    private func runSingleSession() async throws {
        guard !deviceId.isEmpty, !token.isEmpty else { throw ClawPalError.displayNotFound }
        let dev = deviceId, tok = token, lastHost = connectedHost

        guard let endpoint = await Task.detached(operation: {
            ClawPalDiscovery.discover(deviceId: dev, token: tok, lastHost: lastHost, tries: 3)
        }).value else {
            throw ClawPalError.displayNotFound
        }

        guard let wsURL = URL(string: "ws://\(endpoint.host):\(ClawPalEndpoint.monitorPort)/monitor") else {
            throw ClawPalError.invalidResponse("Bad WebSocket URL")
        }
        var request = URLRequest(url: wsURL)
        request.setValue(endpoint.sign(method: "GET", path: "/monitor", token: tok), forHTTPHeaderField: "Authorization")

        let ws = wsSession.webSocketTask(with: request)
        ws.maximumMessageSize = 4096
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        connectedHost = endpoint.host
        if var cfg = config, cfg.lastIp != endpoint.host {
            cfg.lastIp = endpoint.host
            config = cfg
            try? cfg.save()
        }
        status = .connected(endpoint.host)
        appendLog("Connected to ClawPal at \(endpoint.host)")

        refreshHealth()
        if !settingsLoaded { refreshDisplaySettings() }

        let state = SessionState()
        let receiver = Task { [weak self] in
            await self?.receiveLoop(ws: ws, state: state)
        }
        defer { receiver.cancel() }

        var artSentId = 0
        var artSupported = true
        var artRetryAt = Date.distantPast
        var artTask: Task<Int, Never>?
        defer { artTask?.cancel() }

        let encoder = JSONEncoder()
        var healthTick = 0

        while !Task.isCancelled {
            if state.receiverFailed {
                throw state.receiverError ?? ClawPalError.invalidResponse("Display closed connection")
            }

            seq += 1
            let sys = statsCollector.sample()
            let musicSnap = mediaController.snapshot(control: state.controlResult)
            let ampSnap = ampProvider.snapshot()
            let claudeSnap: ProviderStats? = {
                let local = claudeProvider.snapshot()
                guard claudeLiveLimitsEnabled else { return local }
                let base = local ?? ProviderStats(
                    running: false, available: false, stale: false, status: "closed", plan: "", ageS: 0,
                    primary: .empty, secondary: .empty,
                    activity: ProviderActivity(available: false, stale: true, status: "closed", ageS: 0, workingCount: 0, totalCount: 0, items: [])
                )
                let (quota, liveStatus) = claudeLiveLimits.currentQuota()
                return ClaudeLiveLimits.merge(local: base, quota: quota, status: liveStatus, now: Date().timeIntervalSince1970)
            }()

            cpuUsage = sys.cpu.usage ?? 0
            memoryUsage = sys.memory.usage
            memoryText = String(format: "%.1f / %.0f GB", Double(sys.memory.usedMb) / 1024.0, Double(sys.memory.totalMb) / 1024.0)
            music = musicSnap
            coverImageData = mediaController.cover?.previewImageData
            ampStats = ampSnap
            claudeStats = claudeSnap
            claudeStatusDetail = claudeLiveLimitsEnabled ? claudeLiveLimits.currentDetailStatus() : "Live limits off"

            var frame = TelemetryFrame(
                seq: seq,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                hostname: sys.hostname,
                uptimeS: sys.uptimeS,
                cpu: sys.cpu,
                gpu: sys.gpu,
                memory: sys.memory,
                network: sys.network,
                music: musicSnap,
                codex: ampSnap,
                claude: claudeSnap
            )
            let limit = 8192
            var payloadData = try encoder.encode(frame)
            if payloadData.count > limit {
                frame.music.title = String(frame.music.title.prefix(40))
                payloadData = try encoder.encode(frame)
            }
            guard let payloadStr = String(data: payloadData, encoding: .utf8) else {
                throw ClawPalError.invalidResponse("UTF-8 encoding failed")
            }

            try await ws.send(.string(payloadStr))

            // Non-blocking background album cover upload
            if let existing = artTask, existing.isCancelled {
                artTask = nil
            }
            if let cov = mediaController.cover,
               artTask == nil, artSupported,
               musicSnap.artId == cov.id, cov.id != artSentId,
               Date() >= artRetryAt {
                artSentId = cov.id
                let host = endpoint.host
                artTask = Task.detached { [weak self] in
                    let code = await Self.uploadCover(deviceId: dev, host: host, token: tok, cover: cov)
                    await MainActor.run { [weak self] in
                        if code == 200 { self?.appendLog("Album cover uploaded -> 200") }
                        else { self?.appendLog("Album cover upload -> \(code)") }
                    }
                    return code
                }
            }
            if let currentTask = artTask {
                // Poll completion without blocking 1 Hz cadence
                if let result = await pollTaskIfDone(currentTask) {
                    artTask = nil
                    if result == 404 || result == 405 { artSupported = false }
                    else if result != 200 { artSentId = 0; artRetryAt = Date().addingTimeInterval(30) }
                }
            }

            healthTick += 1
            if healthTick % 60 == 0 {
                refreshHealth()
            }

            try await Task.sleep(for: .seconds(1))

            if Date().timeIntervalSince(state.lastAck) > 10 {
                throw ClawPalError.invalidResponse("Display stopped acknowledging")
            }
        }
    }

    private func pollTaskIfDone(_ task: Task<Int, Never>) async -> Int? {
        // Quick non-blocking race with 1ms sleep
        await withTaskGroup(of: Int?.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: .milliseconds(5)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func receiveLoop(ws: URLSessionWebSocketTask, state: SessionState) async {
        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                guard case .string(let text) = message,
                      let data = text.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = obj["type"] as? String else { continue }

                state.lastAck = Date()

                if type == "buddy.ack" {
                    continue
                }
                if type == "buddy.nfc", (obj["v"] as? Int) == 1, let rawUid = obj["uid"] as? String {
                    let manager = self.nfcManager
                    let media = self.mediaController
                    if let norm = NfcAlbumManager.normalizeUid(rawUid),
                       self.nfcCards.contains(where: { $0.uid == norm }) {
                        self.selectDisplayApp(.music)
                    }
                    Task.detached { [weak self] in
                        let res = manager.handleTap(rawUid: rawUid)
                        if res.played { media.poll() }
                        await MainActor.run { [weak self] in
                            if let uid = res.uid {
                                self?.lastNfcUid = uid
                                if res.played {
                                    self?.selectDisplayApp(.music)
                                    self?.appendLog("NFC \(uid) -> playing \(res.label)" + (res.note.isEmpty ? "" : " (\(res.note))"))
                                } else {
                                    self?.appendLog("NFC \(uid) tapped (\(res.note))")
                                }
                            }
                        }
                    }
                    continue
                }
                if type == "buddy.control", (obj["v"] as? Int) == 1,
                   let controlId = obj["id"] as? Int,
                   let action = obj["action"] as? String {
                    guard controlId > state.lastControlId else { continue }
                    state.lastControlId = controlId
                    let value = obj["value"] as? Int
                    let claude = self.claudeProvider
                    let amp = self.ampProvider
                    let media = self.mediaController
                    Task.detached { [weak self] in
                        let outcome: (Bool, String)
                        var note: String?
                        if action == "focus" {
                            if value == 7 {
                                outcome = claude.focusWaiting()
                            } else if value == 6 {
                                outcome = amp.focusWaiting()
                            } else if let v = value, v >= 100 && v < 108 {
                                let res = amp.focusItem(at: v - 100)
                                outcome = (res.ok, res.error)
                                note = res.title
                            } else {
                                outcome = (false, "unavailable")
                            }
                        } else {
                            outcome = media.execute(action: action, value: value)
                        }
                        let openedTitle = note
                        await MainActor.run { [weak self] in
                            state.controlResult = (controlId, outcome.0, outcome.1)
                            if let title = openedTitle, outcome.0 {
                                self?.appendLog("Display -> Opening Amp thread: \(title)")
                            } else {
                                self?.appendLog("Display control: \(action) -> \(outcome.0 ? "ok" : outcome.1)")
                            }
                        }
                    }
                }
            } catch {
                state.receiverError = error
                state.receiverFailed = true
                return
            }
        }
    }

    private static func uploadCover(deviceId: String, host: String, token: String, cover: AlbumCover) async -> Int {
        guard let ep = ClawPalDiscovery.discover(deviceId: deviceId, token: token, lastHost: host, tries: 2) else {
            return 0
        }
        do {
            let (status, _) = try await ClawPalHTTP.signedPost(
                endpoint: ep,
                token: token,
                path: "/art",
                body: cover.pixels,
                contentType: "application/octet-stream",
                extraHeaders: [
                    "X-ClawPal-Art-Id": String(cover.id),
                    "X-ClawPal-Art-Size": String(CoverConverter.coverSize),
                ]
            )
            return status
        } catch {
            return 0
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public func appendLog(_ message: String) {
        let line = LogLine(time: Self.timeFmt.string(from: Date()), message: message)
        logs.append(line)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }
}

@MainActor
private final class SessionState {
    var lastAck = Date()
    var lastControlId = 0
    var controlResult: (id: Int, ok: Bool, error: String) = (0, false, "")
    var receiverFailed = false
    var receiverError: Error?
}
