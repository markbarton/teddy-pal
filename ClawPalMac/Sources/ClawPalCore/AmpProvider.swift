import AppKit
import Foundation

// MARK: - Rich Amp Models (for ClawPalMac UI + Display Telemetry)

public struct AmpUsageSummary: Equatable {
    public var tier: String
    public var agentRemainingDollars: Double
    public var agentTotalDollars: Double
    public var agentPercent: Double
    public var orbRemainingHours: Double?
    public var orbTotalHours: Double?
    public var orbPercent: Double?
    public var periodStart: String
    public var periodEnd: String
    public var resetsAt: Int
    public var windowMinutes: Int
    public var resetsInDays: Int?
    public var individualCreditsDollars: Double?
    public var fetchedAt: TimeInterval

    public init(
        tier: String,
        agentRemainingDollars: Double,
        agentTotalDollars: Double,
        agentPercent: Double,
        orbRemainingHours: Double? = nil,
        orbTotalHours: Double? = nil,
        orbPercent: Double? = nil,
        periodStart: String = "",
        periodEnd: String = "",
        resetsAt: Int = 0,
        windowMinutes: Int = 43_200,
        resetsInDays: Int? = nil,
        individualCreditsDollars: Double? = nil,
        fetchedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.tier = tier
        self.agentRemainingDollars = agentRemainingDollars
        self.agentTotalDollars = agentTotalDollars
        self.agentPercent = agentPercent
        self.orbRemainingHours = orbRemainingHours
        self.orbTotalHours = orbTotalHours
        self.orbPercent = orbPercent
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
        self.resetsInDays = resetsInDays
        self.individualCreditsDollars = individualCreditsDollars
        self.fetchedAt = fetchedAt
    }
}

public struct AmpThreadDetail: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var url: String
    public var updatedAt: TimeInterval
    public var updatedIso: String
    public var messageCount: Int
    public var pinned: Bool
    public var project: String
    public var repoUrl: String
    public var waitingOnInput: Bool
    public var statusMessage: String
    public var statusUpdatedAt: TimeInterval?
    public var agentState: String
    public var model: String
    public var lastSnippet: String

    public var isWorking: Bool {
        let s = agentState.lowercased()
        return s == "working" || s == "running" || s == "streaming"
    }

    public var displayState: String {
        if isWorking { return "working" }
        if waitingOnInput { return "waiting" }
        return "recent"
    }

    public var attentionTimestamp: TimeInterval {
        statusUpdatedAt ?? updatedAt
    }

    public init(
        id: String,
        title: String,
        url: String,
        updatedAt: TimeInterval,
        updatedIso: String,
        messageCount: Int,
        pinned: Bool = false,
        project: String = "",
        repoUrl: String = "",
        waitingOnInput: Bool = false,
        statusMessage: String = "",
        statusUpdatedAt: TimeInterval? = nil,
        agentState: String = "idle",
        model: String = "",
        lastSnippet: String = ""
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.updatedAt = updatedAt
        self.updatedIso = updatedIso
        self.messageCount = messageCount
        self.pinned = pinned
        self.project = project
        self.repoUrl = repoUrl
        self.waitingOnInput = waitingOnInput
        self.statusMessage = statusMessage
        self.statusUpdatedAt = statusUpdatedAt
        self.agentState = agentState
        self.model = model
        self.lastSnippet = lastSnippet
    }
}

/// Reads Amp account usage (`amp usage`) and Need-You / active thread details
/// (`amp threads list --json` + cached `amp threads export`) and maps them to
/// ClawPal's Amp page and macOS Dashboard.
public final class AmpProvider {
    private static let recentWindowSeconds: TimeInterval = 24 * 3600
    private static let usageIntervalSeconds: TimeInterval = 300
    private static let threadLimit = 30
    private static let maxCachedThreads = 60
    private static let cliPlaces = [
        "~/.local/bin/amp",
        "~/.amp/bin/amp",
        "/opt/homebrew/bin/amp",
        "/usr/local/bin/amp",
    ]

    public let executable: String?
    private let cachePath: URL
    private let lock = NSLock()

    private var threadCache: [String: AmpThreadDetail] = [:]
    private var orderedThreads: [AmpThreadDetail] = []
    private var lastSentItems: [AmpThreadDetail] = []
    private var usageSummary: AmpUsageSummary?
    private var fetchedAt: TimeInterval = 0
    private var usageFetchedAt: TimeInterval = 0
    private var status = "local"
    private var usageStatus = "no_limits"
    private var backoffUntil: TimeInterval = 0

    public init(executable: String? = nil, cachePath: URL? = nil) {
        self.executable = executable ?? Self.findAmpCli()
        self.cachePath = cachePath ?? ClawPalPaths.home.appendingPathComponent("amp_thread_cache.json")
        self.threadCache = Self.loadCache(from: self.cachePath)
    }

    public static func findAmpCli() -> String? {
        let fm = FileManager.default
        for place in cliPlaces {
            let path = NSString(string: place).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public static func treeProject(_ tree: String?) -> String {
        var leaf = (tree ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        if leaf.hasSuffix(".git") {
            leaf = String(leaf.dropLast(4))
        }
        let generic: Set<String> = ["", "workspace", "repo", "user", "home"]
        return generic.contains(leaf.lowercased()) ? "" : leaf
    }

    // MARK: - Parsers (public for unit testing)

    public static func parseUsageOutput(_ text: String, now: TimeInterval = Date().timeIntervalSince1970) -> AmpUsageSummary? {
        let clean = text.replacingOccurrences(of: "**", with: "")

        func firstMatch(_ pattern: String, in str: String) -> [String]? {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(str.startIndex..., in: str)
            guard let m = rx.firstMatch(in: str, range: range) else { return nil }
            return (1..<m.numberOfRanges).map { idx in
                let r = m.range(at: idx)
                guard r.location != NSNotFound, let sr = Range(r, in: str) else { return "" }
                return String(str[sr])
            }
        }

        func parseDouble(_ s: String) -> Double? {
            Double(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
        }

        let tier = firstMatch(#"Amp\s+([A-Za-z0-9 _-]+?)\s+Tier:"#, in: clean)?.first?.trimmingCharacters(in: .whitespaces) ?? "Amp"

        guard let agentMatch = firstMatch(#"agent usage \$([0-9.,]+) of \$([0-9.,]+) remaining(?:\s*\(([0-9.]+)%\))?"#, in: clean),
              let agentRem = parseDouble(agentMatch[0]),
              let agentTot = parseDouble(agentMatch[1]) else {
            return nil
        }

        let agentPct: Double
        if agentTot > 0 {
            agentPct = min(max((agentRem / agentTot) * 100.0, 0), 100)
        } else if let p = parseDouble(agentMatch[2]) {
            agentPct = min(max(p, 0), 100)
        } else {
            agentPct = 0
        }

        var orbRem: Double?
        var orbTot: Double?
        var orbPct: Double?
        if let orbMatch = firstMatch(#"orb usage ([0-9.,]+)h of ([0-9.,]+)h\b[^(]*(?:\(([0-9.]+)%\))?"#, in: clean),
           let rem = parseDouble(orbMatch[0]),
           let tot = parseDouble(orbMatch[1]) {
            orbRem = rem
            orbTot = tot
            if tot > 0 {
                orbPct = min(max((rem / tot) * 100.0, 0), 100)
            } else if let p = parseDouble(orbMatch[2]) {
                orbPct = min(max(p, 0), 100)
            }
        }

        var periodStart = ""
        var periodEnd = ""
        var resetsAt = 0
        var windowMinutes = 43_200
        if let perMatch = firstMatch(#"period (\d{4}-\d{2}-\d{2}) to (\d{4}-\d{2}-\d{2})"#, in: clean) {
            periodStart = perMatch[0]
            periodEnd = perMatch[1]
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "yyyy-MM-dd"
            if let startDate = df.date(from: periodStart), let endDate = df.date(from: periodEnd) {
                resetsAt = Int(endDate.timeIntervalSince1970)
                let mins = Int(endDate.timeIntervalSince(startDate) / 60.0)
                if mins > 0 && mins <= 525_600 {
                    windowMinutes = mins
                }
            }
        }

        let resetsInDays = firstMatch(#"renewal in (\d+) days?"#, in: clean).flatMap { Int($0[0]) }
        let indiv = firstMatch(#"Individual credits:\s*\$([0-9.,]+) remaining"#, in: clean).flatMap { parseDouble($0[0]) }

        return AmpUsageSummary(
            tier: tier,
            agentRemainingDollars: agentRem,
            agentTotalDollars: agentTot,
            agentPercent: agentPct,
            orbRemainingHours: orbRem,
            orbTotalHours: orbTot,
            orbPercent: orbPct,
            periodStart: periodStart,
            periodEnd: periodEnd,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes,
            resetsInDays: resetsInDays,
            individualCreditsDollars: indiv,
            fetchedAt: now
        )
    }

    public static func parseExportedThread(
        _ data: Data,
        fallbackId: String,
        fallbackTitle: String,
        fallbackUpdatedIso: String,
        fallbackUpdatedAt: TimeInterval,
        fallbackTree: String?,
        fallbackMessageCount: Int
    ) -> AmpThreadDetail? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let id = (root["id"] as? String) ?? fallbackId
        let title = ((root["title"] as? String) ?? fallbackTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let pinned = (root["pinned"] as? Bool) ?? false
        let updatedIso = (root["updatedAt"] as? String) ?? fallbackUpdatedIso
        let updatedAt = parseIsoDate(updatedIso) ?? fallbackUpdatedAt

        var repoUrl = ""
        var project = ""
        if let env = root["env"] as? [String: Any],
           let initial = env["initial"] as? [String: Any],
           let trees = initial["trees"] as? [[String: Any]] {
            for tree in trees {
                if let repo = tree["repository"] as? [String: Any], let rurl = repo["url"] as? String, !rurl.isEmpty {
                    repoUrl = rurl
                    let p = treeProject(rurl)
                    if !p.isEmpty { project = p; break }
                }
                if project.isEmpty, let uri = tree["uri"] as? String {
                    let p = treeProject(uri)
                    if !p.isEmpty { project = p }
                }
            }
        }
        if project.isEmpty {
            project = treeProject(fallbackTree)
        }

        let meta = root["meta"] as? [String: Any] ?? [:]
        let statusObj = meta["statusMessage"] as? [String: Any] ?? [:]
        let waitingOnInput = (statusObj["waitingOnInput"] as? Bool) ?? false
        let statusText = ((statusObj["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let statusUpdatedAt = parseIsoDate(statusObj["updatedAt"] as? String)

        let agentObj = meta["lastKnownAgentState"] as? [String: Any] ?? [:]
        let agentState = ((agentObj["state"] as? String) ?? "idle").lowercased()

        let rawModel: String = {
            if let tm = meta["threadModel"] as? [String: Any], let m = tm["model"] as? String, !m.isEmpty {
                return m
            }
            if let am = meta["agentMode"] as? String, !am.isEmpty {
                return am
            }
            if let am = root["agentMode"] as? String, !am.isEmpty {
                return am
            }
            return ""
        }()
        let shortModel = rawModel.split(separator: "/").last.map(String.init) ?? rawModel

        let messages = root["messages"] as? [[String: Any]] ?? []
        let msgCount = max(fallbackMessageCount, messages.count)
        let snippet = extractLastAssistantSnippet(messages: messages)

        return AmpThreadDetail(
            id: id,
            title: title.isEmpty ? "Untitled thread" : title,
            url: "https://ampcode.com/threads/\(id)",
            updatedAt: updatedAt,
            updatedIso: fallbackUpdatedIso,
            messageCount: msgCount,
            pinned: pinned,
            project: project,
            repoUrl: repoUrl,
            waitingOnInput: waitingOnInput,
            statusMessage: statusText,
            statusUpdatedAt: statusUpdatedAt,
            agentState: agentState,
            model: shortModel,
            lastSnippet: snippet
        )
    }

    private static func extractLastAssistantSnippet(messages: [[String: Any]]) -> String {
        for msg in messages.reversed() {
            guard (msg["role"] as? String) == "assistant",
                  let blocks = msg["content"] as? [[String: Any]] else { continue }
            for block in blocks.reversed() {
                guard (block["type"] as? String) == "text",
                      let text = block["text"] as? String else { continue }
                let collapsed = text
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !collapsed.isEmpty {
                    return collapsed.count > 240 ? String(collapsed.prefix(239)) + "…" : collapsed
                }
            }
        }
        return ""
    }

    private static func parseIsoDate(_ s: String?) -> TimeInterval? {
        guard let s, !s.isEmpty else { return nil }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: s) { return d.timeIntervalSince1970 }
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        return isoPlain.date(from: s)?.timeIntervalSince1970
    }

    // MARK: - Polling

    private struct CliThread: Decodable {
        let id: String?
        let title: String?
        let updated: String?
        let updatedAt: String?
        let tree: String?
        let archived: Bool?
        let messageCount: Int?
    }

    public func poll(forceUsage: Bool = false) {
        guard let exe = executable else { return }
        let now = Date().timeIntervalSince1970
        if !forceUsage && now < backoffUntil { return }

        // 1. Poll Amp account usage every 5 minutes (or on manual refresh)
        lock.lock()
        let shouldPollUsage = forceUsage || usageFetchedAt == 0 || (now - usageFetchedAt >= Self.usageIntervalSeconds)
        lock.unlock()
        if shouldPollUsage {
            pollUsage(exe: exe, now: now)
        }

        // 2. Poll unarchived threads list
        guard let listData = runAmp(exe: exe, args: ["threads", "list", "--json", "--limit", String(Self.threadLimit)], timeout: 15) else {
            backoffUntil = now + 90
            lock.lock(); status = "error"; lock.unlock()
            return
        }

        let decoded: [CliThread]
        if let arr = try? JSONDecoder().decode([CliThread].self, from: listData) {
            decoded = arr
        } else {
            struct Wrapper: Decodable { let threads: [CliThread] }
            guard let w = try? JSONDecoder().decode(Wrapper.self, from: listData) else {
                backoffUntil = now + 90
                lock.lock(); status = "error"; lock.unlock()
                return
            }
            decoded = w.threads
        }

        let activeCli = decoded.filter { $0.id != nil && $0.archived != true }

        // 3. Export only unseen or updated threads (parallel, capped at 6 workers)
        lock.lock()
        var cacheCopy = threadCache
        lock.unlock()

        var toExport: [CliThread] = []
        for t in activeCli {
            guard let tid = t.id else { continue }
            let updIso = t.updated ?? t.updatedAt ?? ""
            let msgCount = t.messageCount ?? 0
            if let cached = cacheCopy[tid], cached.updatedIso == updIso, cached.messageCount == msgCount {
                continue
            }
            toExport.append(t)
        }

        if !toExport.isEmpty {
            let exportedLock = NSLock()
            var exported: [String: AmpThreadDetail] = [:]
            let sem = DispatchSemaphore(value: 6)
            let group = DispatchGroup()
            let queue = DispatchQueue.global(qos: .utility)

            for t in toExport {
                guard let tid = t.id else { continue }
                group.enter()
                queue.async {
                    sem.wait()
                    defer { sem.signal(); group.leave() }
                    let updIso = t.updated ?? t.updatedAt ?? ""
                    let updAt = Self.parseIsoDate(updIso) ?? now
                    let title = t.title ?? "Untitled thread"
                    let msgCount = t.messageCount ?? 0
                    if let raw = self.runAmp(exe: exe, args: ["threads", "export", tid], timeout: 20),
                       let detail = Self.parseExportedThread(
                           raw,
                           fallbackId: tid,
                           fallbackTitle: title,
                           fallbackUpdatedIso: updIso,
                           fallbackUpdatedAt: updAt,
                           fallbackTree: t.tree,
                           fallbackMessageCount: msgCount
                       ) {
                        exportedLock.lock()
                        exported[tid] = detail
                        exportedLock.unlock()
                    }
                }
            }
            group.wait()

            for (k, v) in exported {
                cacheCopy[k] = v
            }
            if cacheCopy.count > Self.maxCachedThreads {
                let keepIds = Set(
                    cacheCopy.values
                        .sorted { $0.updatedAt > $1.updatedAt }
                        .prefix(Self.maxCachedThreads)
                        .map(\.id)
                )
                cacheCopy = cacheCopy.filter { keepIds.contains($0.key) }
            }
            Self.saveCache(cacheCopy, to: cachePath)
        }

        // Build ordered list matching active unarchived threads
        var merged: [AmpThreadDetail] = []
        for t in activeCli {
            guard let tid = t.id else { continue }
            if let detail = cacheCopy[tid] {
                merged.append(detail)
            } else {
                let updIso = t.updated ?? t.updatedAt ?? ""
                merged.append(AmpThreadDetail(
                    id: tid,
                    title: t.title ?? "Untitled thread",
                    url: "https://ampcode.com/threads/\(tid)",
                    updatedAt: Self.parseIsoDate(updIso) ?? now,
                    updatedIso: updIso,
                    messageCount: t.messageCount ?? 0,
                    project: Self.treeProject(t.tree)
                ))
            }
        }
        merged.sort { $0.updatedAt > $1.updatedAt }

        lock.lock()
        threadCache = cacheCopy
        orderedThreads = merged
        fetchedAt = now
        status = "local"
        backoffUntil = 0
        lock.unlock()
    }

    private func pollUsage(exe: String, now: TimeInterval) {
        guard let data = runAmp(exe: exe, args: ["usage"], timeout: 15),
              let text = String(data: data, encoding: .utf8) else {
            lock.lock()
            usageFetchedAt = now
            if usageSummary == nil { usageStatus = "error" }
            lock.unlock()
            return
        }
        if let parsed = Self.parseUsageOutput(text, now: now) {
            lock.lock()
            usageSummary = parsed
            usageFetchedAt = now
            usageStatus = "ready"
            lock.unlock()
        } else {
            lock.lock()
            usageFetchedAt = now
            if usageSummary == nil { usageStatus = "no_limits" }
            lock.unlock()
        }
    }

    private func runAmp(exe: String, args: [String], timeout: TimeInterval) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        let dir = (exe as NSString).deletingLastPathComponent
        env["PATH"] = [dir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            return nil
        }

        var collected = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            collected = out.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        _ = readGroup.wait(timeout: .now() + 2)
        return proc.terminationStatus == 0 ? collected : nil
    }

    // MARK: - Rich Snapshots for SwiftUI & Telemetry

    public func currentDetails() -> (usage: AmpUsageSummary?, threads: [AmpThreadDetail], waiting: [AmpThreadDetail]) {
        lock.lock()
        let u = usageSummary
        let all = orderedThreads
        lock.unlock()
        let waiting = all
            .filter(\.waitingOnInput)
            .sorted { $0.attentionTimestamp > $1.attentionTimestamp }
        return (u, all, waiting)
    }

    public static func selectDisplayThreads(from threads: [AmpThreadDetail], now: TimeInterval) -> [AmpThreadDetail] {
        let working = threads.filter(\.isWorking).sorted { $0.updatedAt > $1.updatedAt }
        let waiting = threads.filter { !$0.isWorking && $0.waitingOnInput }.sorted { $0.attentionTimestamp > $1.attentionTimestamp }
        let urgent = Array((working + waiting).prefix(8))
        if urgent.count >= 3 {
            return urgent
        }
        let recent = threads.filter { !$0.isWorking && !$0.waitingOnInput && (now - $0.updatedAt <= recentWindowSeconds) }
            .sorted { $0.updatedAt > $1.updatedAt }
        return Array((urgent + recent).prefix(3))
    }

    public static func buildProviderStats(
        usage: AmpUsageSummary?,
        usageStatus: String,
        threads: [AmpThreadDetail],
        fetchedAt: TimeInterval,
        status: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> ProviderStats {
        var hasData = fetchedAt > 0
        let activityStale = hasData && (status == "error" || now - fetchedAt > 180)
        if hasData && now - fetchedAt > 1800 {
            hasData = false
        }
        let actAge = hasData ? Int(min(max(now - fetchedAt, 0), 31_535_999)) : 0

        let working = threads.filter(\.isWorking)
        let waiting = threads.filter { !$0.isWorking && $0.waitingOnInput }
        let recent = threads.filter { !$0.isWorking && !$0.waitingOnInput && (now - $0.updatedAt <= recentWindowSeconds) }

        // Display accepts up to 8 rows: prioritize working -> waiting (Need You) -> recent 24h
        let topItems = selectDisplayThreads(from: threads, now: now)
        let items: [ProviderTaskItem] = hasData ? topItems.map { t in
            let refTime = t.waitingOnInput ? t.attentionTimestamp : t.updatedAt
            let age = Int(min(max(now - refTime, 0), 31_535_999))
            let projectText = t.project.isEmpty ? "Amp" : t.project
            let detailText = (t.waitingOnInput && !t.statusMessage.isEmpty) ? clawpalLimitText(t.statusMessage, maxUtf8Bytes: 79) : nil
            return ProviderTaskItem(
                title: clawpalLimitText(t.title, maxUtf8Bytes: 63),
                project: clawpalLimitText(projectText, maxUtf8Bytes: 31),
                state: t.displayState,
                ageS: age,
                detail: detailText
            )
        } : []

        let totalActive = max(working.count + waiting.count, working.count + waiting.count + recent.count)

        let usageAvailable = usage != nil
        let usageAge = usage.map { Int(min(max(now - $0.fetchedAt, 0), 31_535_999)) } ?? 0
        let usageStale = usageAvailable && (now - (usage?.fetchedAt ?? 0) > 900)

        var primary: ProviderWindow?
        var secondary: ProviderWindow?
        if let u = usage {
            let agentResetText = String(format: "$%.2f / $%.2f", u.agentRemainingDollars, u.agentTotalDollars)
            primary = ProviderWindow(
                available: true,
                remainingPercent: u.agentPercent,
                windowMinutes: u.windowMinutes,
                resetText: clawpalLimitText(agentResetText, maxUtf8Bytes: 47),
                resetsAt: u.resetsAt
            )
            if let orbPct = u.orbPercent, let orbRem = u.orbRemainingHours, let orbTot = u.orbTotalHours {
                let orbResetText = String(format: "%.0fh / %.0fh orb", orbRem, orbTot)
                secondary = ProviderWindow(
                    available: true,
                    remainingPercent: orbPct,
                    windowMinutes: u.windowMinutes,
                    resetText: clawpalLimitText(orbResetText, maxUtf8Bytes: 47),
                    resetsAt: u.resetsAt
                )
            }
        }

        return ProviderStats(
            running: true,
            available: usageAvailable,
            stale: usageStale,
            status: usageAvailable ? "ready" : usageStatus,
            plan: clawpalLimitText(usage?.tier ?? "Amp", maxUtf8Bytes: 31),
            ageS: usageAge,
            primary: primary,
            secondary: secondary,
            activity: ProviderActivity(
                available: hasData,
                stale: activityStale,
                status: hasData ? "local" : (status == "error" ? "error" : "unavailable"),
                ageS: actAge,
                workingCount: hasData ? min(working.count, 1000) : 0,
                totalCount: hasData ? min(totalActive, 1000) : 0,
                items: items
            )
        )
    }

    public func snapshot(now: TimeInterval = Date().timeIntervalSince1970) -> ProviderStats? {
        guard executable != nil else { return nil }
        lock.lock()
        let u = usageSummary
        let uStat = usageStatus
        let threads = orderedThreads
        let fetched = fetchedAt
        let st = status
        lastSentItems = Self.selectDisplayThreads(from: threads, now: now)
        lock.unlock()
        return Self.buildProviderStats(
            usage: u,
            usageStatus: uStat,
            threads: threads,
            fetchedAt: fetched,
            status: st,
            now: now
        )
    }

    // MARK: - Open / Focus Thread in Amp Desktop

    public func focusItem(at index: Int) -> (ok: Bool, error: String, title: String?) {
        lock.lock()
        let sent = lastSentItems
        lock.unlock()
        if index >= 0 && index < sent.count {
            let target = sent[index]
            let res = Self.openThread(id: target.id)
            return (res.0, res.1, target.title)
        }
        let fallback = focusWaiting()
        return (fallback.0, fallback.1, nil)
    }

    public func focusWaiting() -> (Bool, String) {
        let (_, _, waiting) = currentDetails()
        if let first = waiting.first {
            return Self.openThread(id: first.id)
        }
        return Self.activateAmpApp()
    }

    @discardableResult
    public static func openThread(id: String) -> (Bool, String) {
        guard let url = URL(string: "https://ampcode.com/threads/\(id)") else {
            return (false, "bad_url")
        }
        let ampApp = URL(fileURLWithPath: "/Applications/Amp.app")
        if FileManager.default.fileExists(atPath: ampApp.path) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", ampApp.path, url.absoluteString]
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    return (true, "")
                }
            } catch {
                // fall through to default browser
            }
        }
        NSWorkspace.shared.open(url)
        return (true, "")
    }

    public static func activateAmpApp() -> (Bool, String) {
        let ampApp = URL(fileURLWithPath: "/Applications/Amp.app")
        guard FileManager.default.fileExists(atPath: ampApp.path) else {
            return (false, "not_installed")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", ampApp.path]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0 ? (true, "") : (false, "open_failed")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Disk Cache

    private static func loadCache(from url: URL) -> [String: AmpThreadDetail] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: AmpThreadDetail].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveCache(_ cache: [String: AmpThreadDetail], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Non-fatal
        }
    }
}
