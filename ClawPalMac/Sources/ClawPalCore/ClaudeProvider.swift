import AppKit
import Darwin
import Foundation

public struct ClaudeSessionRecord: Codable, Equatable {
    public var id: String
    public var title: String
    public var project: String
    public var state: String
    public var seen: Double
    public var activityAt: Double
    public var processId: Int
    public var processStarted: Double
    public var ended: Bool
    public var primary: ProviderWindow
    public var secondary: ProviderWindow
    public var usageAt: Double

    enum CodingKeys: String, CodingKey {
        case id, title, project, state, seen, ended, primary, secondary
        case activityAt = "activity_at"
        case processId = "process_id"
        case processStarted = "process_started"
        case usageAt = "usage_at"
    }

    public init(id: String, title: String, project: String, state: String, seen: Double, activityAt: Double, processId: Int, processStarted: Double, ended: Bool, primary: ProviderWindow, secondary: ProviderWindow, usageAt: Double) {
        self.id = id
        self.title = title
        self.project = project
        self.state = state
        self.seen = seen
        self.activityAt = activityAt
        self.processId = processId
        self.processStarted = processStarted
        self.ended = ended
        self.primary = primary
        self.secondary = secondary
        self.usageAt = usageAt
    }
}

public struct ClaudeTranscriptMetadata: Equatable {
    public let title: String
    public let project: String

    public init(title: String, project: String) {
        self.title = title
        self.project = project
    }
}

/// Reads ~/.clawpal-mac/claude/*.session.json written by Claude Code hooks and status-line wrapper,
/// and enriches/backfills titles and recent sessions from ~/.claude/projects/ and Claude Desktop's
/// local claude-code-sessions directory.
public final class ClaudeProvider {
    public let stateDir: URL
    public let claudeDir: URL
    public let desktopSessionsDir: URL

    private struct CachedTranscript {
        let mtime: TimeInterval
        let meta: ClaudeTranscriptMetadata
    }

    private let cacheLock = NSLock()
    private var transcriptCache: [String: CachedTranscript] = [:]
    private var cachedHistoryScanAt: TimeInterval = 0
    private var cachedHistorySessions: [ClaudeSessionRecord] = []
    private var cachedTitlesBySessionId: [String: ClaudeTranscriptMetadata] = [:]

    public init(
        stateDir: URL = ClawPalPaths.claudeDir,
        claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true),
        desktopSessionsDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    ) {
        self.stateDir = stateDir
        self.claudeDir = claudeDir
        self.desktopSessionsDir = desktopSessionsDir
    }

    public var isHooksInstalled: Bool {
        let settings = claudeDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settings),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = obj["statusLine"] as? [String: Any],
              let cmd = statusLine["command"] as? String else {
            return false
        }
        return cmd.contains("--claude-statusline")
    }

    public var isActive: Bool {
        if isHooksInstalled { return true }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil)) ?? []
        if files.contains(where: { $0.lastPathComponent.hasSuffix(".session.json") }) {
            return true
        }
        return fm.fileExists(atPath: claudeDir.appendingPathComponent("projects").path)
            || fm.fileExists(atPath: desktopSessionsDir.path)
    }

    public func invalidateHistoryCache() {
        cacheLock.lock()
        cachedHistoryScanAt = 0
        cacheLock.unlock()
    }

    public func readSessions(now: TimeInterval = Date().timeIntervalSince1970) -> [ClaudeSessionRecord] {
        let fm = FileManager.default
        let (historySessions, titleIndex) = loadHistoryIfNeeded(now: now)

        var rows: [ClaudeSessionRecord] = []
        var seenIds: Set<String> = []

        if let urls = try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
            let sessionFiles = urls
                .filter { $0.lastPathComponent.hasSuffix(".session.json") }
                .sorted {
                    let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return d0 > d1
                }
                .prefix(64)

            for file in sessionFiles {
                guard let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      (vals.fileSize ?? 0) <= 16_384 else { continue }
                if let mtime = vals.contentModificationDate, now - mtime.timeIntervalSince1970 > 7 * 86_400 {
                    try? fm.removeItem(at: file)
                    continue
                }
                if let data = try? Data(contentsOf: file),
                   var rec = try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data) {
                    if let meta = titleIndex[rec.id] {
                        if rec.title.isEmpty && !meta.title.isEmpty {
                            rec.title = meta.title
                        }
                        if rec.project.isEmpty && !meta.project.isEmpty {
                            rec.project = meta.project
                        }
                    }
                    seenIds.insert(rec.id)
                    rows.append(rec)
                }
            }
        }

        // Merge recent CLI transcripts & Claude Desktop Code sessions not already covered by hook files.
        for hist in historySessions {
            if seenIds.contains(hist.id) { continue }
            seenIds.insert(hist.id)
            rows.append(hist)
        }

        return rows
    }

    private func loadHistoryIfNeeded(now: TimeInterval) -> ([ClaudeSessionRecord], [String: ClaudeTranscriptMetadata]) {
        cacheLock.lock()
        let fresh = (now - cachedHistoryScanAt) < 15.0 && cachedHistoryScanAt > 0
        if fresh {
            let s = cachedHistorySessions
            let t = cachedTitlesBySessionId
            cacheLock.unlock()
            return (s, t)
        }
        cacheLock.unlock()

        let maxAge: TimeInterval = 7 * 86_400
        var sessions: [ClaudeSessionRecord] = []
        var titles: [String: ClaudeTranscriptMetadata] = [:]
        var knownIds: Set<String> = []

        // 1. Scan ~/.claude/projects/*/*.jsonl (Claude Code CLI & Desktop Code transcripts)
        let projectsDir = claudeDir.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        if let projectDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            var candidates: [(url: URL, mtime: TimeInterval, folderName: String)] = []
            for dir in projectDirs {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else {
                    continue
                }
                let folderName = dir.lastPathComponent
                for file in files where file.pathExtension == "jsonl" {
                    guard let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                          vals.isRegularFile == true,
                          let mtimeDate = vals.contentModificationDate else { continue }
                    let mtime = mtimeDate.timeIntervalSince1970
                    if now - mtime <= maxAge {
                        candidates.append((file, mtime, folderName))
                    }
                }
            }
            candidates.sort { $0.mtime > $1.mtime }

            for entry in candidates.prefix(24) {
                let sid = entry.url.deletingPathExtension().lastPathComponent
                let meta = cachedTranscriptMetadata(url: entry.url, mtime: entry.mtime, fallbackFolder: entry.folderName)
                titles[sid] = meta
                guard !knownIds.contains(sid) else { continue }
                knownIds.insert(sid)
                let state = (now - entry.mtime) <= 86_400 ? "completed" : "recent"
                sessions.append(ClaudeSessionRecord(
                    id: sid,
                    title: meta.title,
                    project: meta.project,
                    state: state,
                    seen: entry.mtime,
                    activityAt: entry.mtime,
                    processId: 0,
                    processStarted: 0,
                    ended: true,
                    primary: .empty,
                    secondary: .empty,
                    usageAt: 0
                ))
            }
        }

        // 2. Scan ~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json
        if let enumerator = fm.enumerator(
            at: desktopSessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in enumerator {
                let name = file.lastPathComponent
                guard name.hasPrefix("local_") && name.hasSuffix(".json") else { continue }
                guard let vals = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      vals.isRegularFile == true,
                      (vals.fileSize ?? 0) <= 512_000 else { continue }
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if (obj["isArchived"] as? Bool) == true { continue }

                let rawTitle = (obj["title"] as? String) ?? ""
                let cwd = (obj["cwd"] as? String) ?? (obj["originCwd"] as? String) ?? ""
                let project = Self.leafProjectName(fromPath: cwd)
                let title = clawpalLimitText(rawTitle, maxUtf8Bytes: 63)

                let cliId = (obj["cliSessionId"] as? String) ?? ""
                let sessId = (obj["sessionId"] as? String) ?? file.deletingPathExtension().lastPathComponent
                let canonicalId = cliId.isEmpty ? sessId : cliId

                let meta = ClaudeTranscriptMetadata(title: title, project: project)
                if !title.isEmpty {
                    if !cliId.isEmpty { titles[cliId] = meta }
                    titles[sessId] = meta
                }

                let lastMs = (obj["lastActivityAt"] as? NSNumber)?.doubleValue
                    ?? (obj["lastFocusedAt"] as? NSNumber)?.doubleValue
                    ?? ((vals.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000.0)
                let activityAt = lastMs > 10_000_000_000 ? lastMs / 1000.0 : lastMs
                guard activityAt > 0, (now - activityAt) <= maxAge else { continue }

                if knownIds.contains(canonicalId) {
                    // Enrich existing transcript entry if Desktop has a nicer auto-title
                    if !title.isEmpty, let idx = sessions.firstIndex(where: { $0.id == canonicalId }) {
                        sessions[idx].title = title
                        if sessions[idx].project.isEmpty && !project.isEmpty {
                            sessions[idx].project = project
                        }
                    }
                    continue
                }
                knownIds.insert(canonicalId)
                let state = (now - activityAt) <= 86_400 ? "completed" : "recent"
                sessions.append(ClaudeSessionRecord(
                    id: canonicalId,
                    title: title,
                    project: project,
                    state: state,
                    seen: activityAt,
                    activityAt: activityAt,
                    processId: 0,
                    processStarted: 0,
                    ended: true,
                    primary: .empty,
                    secondary: .empty,
                    usageAt: 0
                ))
            }
        }

        sessions.sort { $0.activityAt > $1.activityAt }

        cacheLock.lock()
        cachedHistoryScanAt = now
        cachedHistorySessions = sessions
        cachedTitlesBySessionId = titles
        cacheLock.unlock()

        return (sessions, titles)
    }

    private func cachedTranscriptMetadata(url: URL, mtime: TimeInterval, fallbackFolder: String) -> ClaudeTranscriptMetadata {
        let key = url.path
        cacheLock.lock()
        if let hit = transcriptCache[key], abs(hit.mtime - mtime) < 0.01 {
            cacheLock.unlock()
            return hit.meta
        }
        cacheLock.unlock()

        // Read up to 256 KB from the start and 64 KB from the tail (custom-title / summary often appear near end).
        let meta = Self.readTranscriptMetadataFromFile(url: url, fallbackFolder: fallbackFolder)
        cacheLock.lock()
        transcriptCache[key] = CachedTranscript(mtime: mtime, meta: meta)
        if transcriptCache.count > 128 {
            transcriptCache.removeAll()
        }
        cacheLock.unlock()
        return meta
    }

    private static func readTranscriptMetadataFromFile(url: URL, fallbackFolder: String) -> ClaudeTranscriptMetadata {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return ClaudeTranscriptMetadata(title: "", project: fallbackProjectFromFolder(fallbackFolder))
        }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: 0)
        let headLen = Int(min(fileSize, 262_144))
        var combined = (try? fh.read(upToCount: headLen)) ?? Data()
        if fileSize > 262_144 {
            let tailOffset = fileSize > 65_536 ? fileSize - 65_536 : 0
            try? fh.seek(toOffset: tailOffset)
            if let tail = try? fh.readToEnd() {
                combined.append(0x0A)
                combined.append(tail)
            }
        }
        var parsed = parseTranscriptMetadata(from: combined)
        if parsed.project.isEmpty {
            parsed = ClaudeTranscriptMetadata(title: parsed.title, project: fallbackProjectFromFolder(fallbackFolder))
        }
        return parsed
    }

    /// Extract a clean display title and project name from Claude Code JSONL transcript bytes.
    /// Priority: `custom-title` > `summary` > first non-meta user prompt text.
    public static func parseTranscriptMetadata(from data: Data) -> ClaudeTranscriptMetadata {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return ClaudeTranscriptMetadata(title: "", project: "")
        }
        var customTitle = ""
        var summary = ""
        var firstUser = ""
        var cwd = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.first == "{", line.last == "}",
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            if cwd.isEmpty, let c = obj["cwd"] as? String, !c.isEmpty {
                cwd = c
            }
            let kind = (obj["type"] as? String) ?? ""
            if kind == "custom-title", let t = obj["customTitle"] as? String, !t.isEmpty {
                customTitle = t
            } else if kind == "summary", let s = obj["summary"] as? String, !s.isEmpty {
                summary = s
            } else if firstUser.isEmpty, kind == "user", (obj["isMeta"] as? Bool) != true {
                if let msg = obj["message"] as? [String: Any] {
                    if let content = msg["content"] as? String {
                        let cleaned = sanitizePromptTitle(content)
                        if !cleaned.isEmpty { firstUser = cleaned }
                    } else if let parts = msg["content"] as? [[String: Any]] {
                        for part in parts where (part["type"] as? String) == "text" {
                            if let txt = part["text"] as? String {
                                let cleaned = sanitizePromptTitle(txt)
                                if !cleaned.isEmpty {
                                    firstUser = cleaned
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }

        let chosen = !customTitle.isEmpty ? customTitle : (!summary.isEmpty ? summary : firstUser)
        return ClaudeTranscriptMetadata(
            title: clawpalLimitText(chosen, maxUtf8Bytes: 63),
            project: leafProjectName(fromPath: cwd)
        )
    }

    private static func sanitizePromptTitle(_ raw: String) -> String {
        var s = raw
        // Strip leading XML/command wrappers such as <pasted_content id="..."> or <ide_opened_file>...</ide_opened_file>
        let blockTags = ["ide_opened_file", "ide_selection", "system-reminder", "command-name", "command-message", "local-command-stdout"]
        for tag in blockTags {
            while let start = s.range(of: "<\(tag)"),
                  let end = s.range(of: "</\(tag)>", range: start.lowerBound..<s.endIndex) {
                s.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        // Remove standalone tags like <pasted_content id="87a7"> and </pasted_content>
        while let open = s.range(of: "<"),
              let close = s.range(of: ">", range: open.upperBound..<s.endIndex) {
            let inner = s[open.upperBound..<close.lowerBound]
            if inner.count <= 80 && !inner.contains("\n") && (inner.first?.isLetter == true || inner.first == "/") {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                break
            }
        }
        let collapsed = s
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'`"))
        if collapsed.isEmpty || collapsed.hasPrefix("/") {
            return ""
        }
        return collapsed
    }

    private static func leafProjectName(fromPath path: String) -> String {
        let trimmed = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        let leaf = trimmed.split(separator: "/").last.map(String.init) ?? ""
        return clawpalLimitText(leaf, maxUtf8Bytes: 31)
    }

    private static func fallbackProjectFromFolder(_ folder: String) -> String {
        // Folder looks like "-Users-alex-projects-sample-api"
        let parts = folder.split(separator: "-").map(String.init)
        guard let last = parts.last, !last.isEmpty else { return "" }
        return clawpalLimitText(last, maxUtf8Bytes: 31)
    }

    public static func isProcessAlive(_ session: ClaudeSessionRecord, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard session.processId > 0 else { return !session.ended && (now - session.seen) < 90 }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let res = proc_pidinfo(Int32(session.processId), PROC_PIDTBSDINFO, 0, &info, size)
        guard res == size else { return false }
        if info.pbi_status == 5 { return false } // SZOMB
        let started = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000.0
        return abs(started - session.processStarted) < 2.0
    }

    public static func buildSnapshot(
        sessions source: [ClaudeSessionRecord],
        now: TimeInterval,
        alive: (ClaudeSessionRecord) -> Bool = { isProcessAlive($0) }
    ) -> ProviderStats {
        let recent = source
            .filter { $0.seen <= now + 60 && $0.seen > now - 7 * 86_400 }
            .sorted { $0.seen > $1.seen }
            .prefix(32)
        let list = Array(recent)

        var aliveMap: [String: Bool] = [:]
        for s in list { aliveMap[s.id] = !s.ended && alive(s) }
        let live = list.filter { aliveMap[$0.id] == true }
        let running = !live.isEmpty

        let usage = live.first ?? list.first
        var primary = usage?.primary ?? .empty
        var secondary = usage?.secondary ?? .empty
        if !primary.available || primary.resetsAt <= Int(now) { primary = .empty }
        if !secondary.available || secondary.resetsAt <= Int(now) { secondary = .empty }

        let available = primary.available || secondary.available
        let age: Int = {
            guard let u = usage, u.usageAt > 0 else { return 0 }
            return Int(min(max(now - u.usageAt, 0), 31_536_000))
        }()

        let ordered = list.sorted { a, b in
            let la = aliveMap[a.id] == true
            let lb = aliveMap[b.id] == true
            if la != lb { return la }
            return a.activityAt > b.activityAt
        }

        let validStates: Set<String> = ["working", "completed", "interrupted", "recent", "unknown", "waiting"]
        let items: [ProviderTaskItem] = ordered.map { s in
            let a = s.activityAt > 0 ? Int(min(max(now - s.activityAt, 0), 31_536_000)) : 31_536_000
            var st = s.state
            let isLive = aliveMap[s.id] == true
            if (st == "working" && a > 120) || (st == "waiting" && a > 1800) || ((st == "working" || st == "waiting") && !isLive) {
                st = "unknown"
            }
            if !validStates.contains(st) { st = "unknown" }
            return ProviderTaskItem(
                title: clawpalLimitText(s.title, maxUtf8Bytes: 63),
                project: clawpalLimitText(s.project, maxUtf8Bytes: 31),
                state: st,
                ageS: a
            )
        }

        let working = items.filter { $0.state == "working" }.count
        return ProviderStats(
            running: running,
            available: available,
            stale: available && (!running || age > 120),
            status: available ? "ready" : (running ? "no_limits" : "closed"),
            plan: "",
            ageS: age,
            primary: primary,
            secondary: secondary,
            activity: ProviderActivity(
                available: !list.isEmpty,
                stale: !running,
                status: running ? "local" : (list.isEmpty ? "closed" : "local"),
                ageS: 0,
                workingCount: min(working, 1000),
                totalCount: min(list.count, 1000),
                items: Array(items.prefix(3))
            )
        )
    }

    public func snapshot(now: TimeInterval = Date().timeIntervalSince1970) -> ProviderStats? {
        guard isActive else { return nil }
        return Self.buildSnapshot(sessions: readSessions(now: now), now: now)
    }

    /// Bring forward the macOS app hosting a waiting Claude Code session (Show on PC, app 7).
    public func focusWaiting() -> (Bool, String) {
        let now = Date().timeIntervalSince1970
        let waiting = readSessions(now: now)
            .filter { $0.state == "waiting" && !$0.ended && Self.isProcessAlive($0, now: now) && (now - $0.activityAt) <= 1800 }
            .sorted { $0.activityAt > $1.activityAt }

        for session in waiting {
            if let appUrl = Self.hostAppBundleURL(pid: Int32(session.processId)) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: appUrl, configuration: cfg)
                return (true, "")
            }
        }
        return (false, "unavailable")
    }

    private static func hostAppBundleURL(pid: Int32) -> URL? {
        var current = pid
        for _ in 0..<12 where current > 1 {
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let len = proc_pidpath(current, &pathBuf, UInt32(pathBuf.count))
            if len > 0 {
                let path = String(cString: pathBuf)
                if let range = path.range(of: ".app/Contents/MacOS/") {
                    let bundlePath = String(path[..<range.lowerBound]) + ".app"
                    return URL(fileURLWithPath: bundlePath)
                }
            }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            let parent = Int32(info.pbi_ppid)
            if parent == current { break }
            current = parent
        }
        return nil
    }
}
