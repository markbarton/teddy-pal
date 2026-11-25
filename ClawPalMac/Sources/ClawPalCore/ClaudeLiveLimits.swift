import CryptoKit
import Foundation
import Security

public struct ClaudeQuotaSnapshot: Equatable {
    public let capturedAt: TimeInterval
    public let primary: ProviderWindow
    public let secondary: ProviderWindow
    public let plan: String
    public let isDesktopFallback: Bool

    public init(
        capturedAt: TimeInterval,
        primary: ProviderWindow,
        secondary: ProviderWindow,
        plan: String = "",
        isDesktopFallback: Bool = false
    ) {
        self.capturedAt = capturedAt
        self.primary = primary
        self.secondary = secondary
        self.plan = plan
        self.isDesktopFallback = isDesktopFallback
    }
}

/// Port of upstream ClawPal `ClaudeLiveLimits.cs` for macOS, plus read-only fallback to
/// Claude Desktop's `~/Library/Application Support/Claude/plan-usage-history.json` when
/// Claude Code's short-lived Keychain OAuth token has expired between CLI sessions.
/// Never logs, saves, refreshes, or transmits any OAuth token.
public final class ClaudeLiveLimits {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let maxResponseBytes = 65_536
    public static let desktopUsageHistoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")

    private struct Credential {
        let token: String
        let expiresAtMs: Double
        let plan: String
        let fingerprint: String
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let session: URLSession
    private let lock = NSLock()
    private var quota: ClaudeQuotaSnapshot?
    private var nextAttempt: TimeInterval = 0
    private var rejectedFingerprint: String?
    private var status: String = "connecting"
    private var detailStatus: String = "Checking Claude limits…"
    private var failures: Int = 0

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    public func reset() {
        lock.lock()
        quota = nil
        nextAttempt = 0
        rejectedFingerprint = nil
        status = "connecting"
        detailStatus = "Checking Claude limits…"
        failures = 0
        lock.unlock()
    }

    public func currentQuota() -> (ClaudeQuotaSnapshot?, String) {
        lock.lock(); defer { lock.unlock() }
        return (quota, status)
    }

    public func currentDetailStatus() -> String {
        lock.lock(); defer { lock.unlock() }
        return detailStatus
    }

    public func forceRefresh(isRunning: Bool, now: TimeInterval = Date().timeIntervalSince1970) async {
        lock.withLock {
            nextAttempt = 0
            rejectedFingerprint = nil
        }
        await refreshIfNeeded(isRunning: isRunning, now: now)
    }

    public func refreshIfNeeded(isRunning: Bool, now: TimeInterval = Date().timeIntervalSince1970) async {
        let (due, rejected): (Bool, String?) = lock.withLock { (now >= nextAttempt, rejectedFingerprint) }
        guard due else { return }

        let cred = Self.readKeychainCredential()
        let plan = cred?.plan ?? ""

        guard let cred else {
            applyDesktopFallbackOrStatus(
                plan: plan,
                fallbackStatus: "signed_out",
                fallbackDetail: "Not signed in to Claude Code",
                desktopDetail: "Via Claude Desktop (sign in to Claude Code for live reset timers)",
                now: now,
                retryDelay: 30
            )
            return
        }

        if cred.expiresAtMs > 0 && cred.expiresAtMs <= (now + 15) * 1000.0 {
            applyDesktopFallbackOrStatus(
                plan: plan,
                fallbackStatus: "signed_out",
                fallbackDetail: "Claude Code OAuth token expired — open claude to refresh",
                desktopDetail: "Via Claude Desktop (open claude to refresh live reset timers)",
                now: now,
                retryDelay: 30
            )
            return
        }

        if rejected == cred.fingerprint {
            applyDesktopFallbackOrStatus(
                plan: plan,
                fallbackStatus: "signed_out",
                fallbackDetail: "Claude Code OAuth token expired — open claude to refresh",
                desktopDetail: "Via Claude Desktop (open claude to refresh live reset timers)",
                now: now,
                retryDelay: 30
            )
            return
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("ClawPal/0.13.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                recordFailure(now: now, limited: false, retryAfter: nil, plan: plan)
                return
            }
            if (200...299).contains(http.statusCode), data.count <= Self.maxResponseBytes {
                if let parsed = Self.parseUsageResponse(data, plan: cred.plan, now: now) {
                    lock.withLock {
                        quota = parsed
                        status = (parsed.primary.available || parsed.secondary.available) ? "live" : "no_limits"
                        detailStatus = (parsed.primary.available || parsed.secondary.available)
                            ? "Live · Claude Code"
                            : "No usage windows reported"
                        failures = 0
                        rejectedFingerprint = nil
                        nextAttempt = now + (isRunning ? 60 : 300)
                    }
                } else {
                    recordFailure(now: now, limited: false, retryAfter: nil, plan: plan)
                }
            } else if http.statusCode == 401 || http.statusCode == 403 {
                lock.withLock {
                    rejectedFingerprint = cred.fingerprint
                }
                applyDesktopFallbackOrStatus(
                    plan: plan,
                    fallbackStatus: "signed_out",
                    fallbackDetail: "Claude Code OAuth token expired — open claude to refresh",
                    desktopDetail: "Via Claude Desktop (open claude to refresh live reset timers)",
                    now: now,
                    retryDelay: 30
                )
            } else {
                let retryHeader = http.value(forHTTPHeaderField: "Retry-After")
                recordFailure(now: now, limited: http.statusCode == 429, retryAfter: retryHeader, plan: plan)
            }
        } catch {
            recordFailure(now: now, limited: false, retryAfter: nil, plan: plan)
        }
    }

    private func applyDesktopFallbackOrStatus(
        plan: String,
        fallbackStatus: String,
        fallbackDetail: String,
        desktopDetail: String,
        now: TimeInterval,
        retryDelay: TimeInterval
    ) {
        if let desktop = Self.readDesktopUsageHistory(plan: plan, now: now) {
            lock.withLock {
                quota = desktop
                status = "live"
                detailStatus = desktopDetail
                nextAttempt = now + retryDelay
            }
        } else {
            lock.withLock {
                status = fallbackStatus
                detailStatus = fallbackDetail
                nextAttempt = now + retryDelay
            }
        }
    }

    private func recordFailure(now: TimeInterval, limited: Bool, retryAfter: String?, plan: String) {
        let desktop = Self.readDesktopUsageHistory(plan: plan, now: now)
        lock.lock()
        failures += 1
        let f = failures
        if let desktop, quota == nil {
            quota = desktop
            status = "live"
            detailStatus = limited
                ? "Via Claude Desktop (API rate limited)"
                : "Via Claude Desktop (API unavailable)"
        } else {
            status = limited ? "rate_limited" : "error"
            detailStatus = limited ? "Anthropic usage API rate limited" : "Could not reach Anthropic usage API"
        }
        var delay: TimeInterval = limited ? 300 : min(300, 30 * pow(2.0, Double(min(f - 1, 4))))
        if let retryAfter, let secs = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)), secs > 0 {
            delay = secs
        }
        nextAttempt = now + delay
        lock.unlock()
    }

    public static func readDesktopUsageHistory(
        from url: URL = desktopUsageHistoryURL,
        plan: String = "",
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = 48 * 3600
    ) -> ClaudeQuotaSnapshot? {
        guard let data = try? Data(contentsOf: url), data.count <= 2_097_152 else { return nil }
        return parseDesktopUsageHistory(data, plan: plan, now: now, maxAge: maxAge)
    }

    /// Parses Claude Desktop's `plan-usage-history.json` (`{"version":2,"samples":[{"t":ms,"u":{"fh":..,"sd":..}}]}`).
    /// When `fh` is omitted by Claude Desktop, 5-hour utilization is 0% (100% remaining).
    public static func parseDesktopUsageHistory(
        _ data: Data,
        plan: String = "",
        now: TimeInterval,
        maxAge: TimeInterval = 48 * 3600
    ) -> ClaudeQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]],
              !samples.isEmpty else {
            return nil
        }
        // Pick the newest valid sample by timestamp.
        var latestSample: (ts: TimeInterval, fh: Double?, sd: Double?)?
        for sample in samples {
            guard let tNum = sample["t"] as? NSNumber,
                  CFGetTypeID(tNum) != CFBooleanGetTypeID(),
                  let u = sample["u"] as? [String: Any] else { continue }
            let rawT = tNum.doubleValue
            let ts = rawT > 10_000_000_000 ? rawT / 1000.0 : rawT
            guard ts.isFinite, ts <= now + 300, (now - ts) <= maxAge else { continue }
            let fh = (u["fh"] as? NSNumber).flatMap { CFGetTypeID($0) != CFBooleanGetTypeID() ? $0.doubleValue : nil }
            let sd = (u["sd"] as? NSNumber).flatMap { CFGetTypeID($0) != CFBooleanGetTypeID() ? $0.doubleValue : nil }
            guard fh != nil || sd != nil else { continue }
            if latestSample == nil || ts > latestSample!.ts {
                latestSample = (ts, fh, sd)
            }
        }
        guard let latest = latestSample else { return nil }

        let fhUsed = min(max(latest.fh ?? 0.0, 0.0), 100.0)
        let fhRem = (min(max(100.0 - fhUsed, 0.0), 100.0) * 10.0).rounded() / 10.0
        let primary = ProviderWindow(
            available: true,
            remainingPercent: fhRem,
            windowMinutes: 300,
            resetText: "",
            resetsAt: 0
        )

        let secondary: ProviderWindow
        if let sdVal = latest.sd, sdVal.isFinite {
            let sdUsed = min(max(sdVal, 0.0), 100.0)
            let sdRem = (min(max(100.0 - sdUsed, 0.0), 100.0) * 10.0).rounded() / 10.0
            secondary = ProviderWindow(
                available: true,
                remainingPercent: sdRem,
                windowMinutes: 10_080,
                resetText: "",
                resetsAt: 0
            )
        } else {
            secondary = .empty
        }

        return ClaudeQuotaSnapshot(
            capturedAt: latest.ts,
            primary: primary,
            secondary: secondary,
            plan: clawpalLimitText(plan, maxUtf8Bytes: 31),
            isDesktopFallback: true
        )
    }

    public static func parseUsageResponse(_ data: Data, plan: String = "", now: TimeInterval) -> ClaudeQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["five_hour"] != nil || root["seven_day"] != nil else {
            return nil
        }
        let primary = parseWindow(root, key: "five_hour", minutes: 300, now: now)
        let secondary = parseWindow(root, key: "seven_day", minutes: 10_080, now: now)
        return ClaudeQuotaSnapshot(
            capturedAt: now,
            primary: primary,
            secondary: secondary,
            plan: clawpalLimitText(plan, maxUtf8Bytes: 31),
            isDesktopFallback: false
        )
    }

    private static func parseWindow(_ root: [String: Any], key: String, minutes: Int, now: TimeInterval) -> ProviderWindow {
        guard let w = root[key] as? [String: Any],
              let num = w["utilization"] as? NSNumber,
              CFGetTypeID(num) != CFBooleanGetTypeID() else {
            return .empty
        }
        let used = num.doubleValue
        guard used.isFinite, used >= 0 else { return .empty }

        var resetsAt = 0
        if let resetStr = w["resets_at"] as? String {
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            guard let dt = f1.date(from: resetStr) ?? f2.date(from: resetStr) else { return .empty }
            let sec = Int(dt.timeIntervalSince1970)
            guard Double(sec) > now, sec <= Int(UInt32.max) else { return .empty }
            resetsAt = sec
        } else if let resetNum = w["resets_at"] as? NSNumber, CFGetTypeID(resetNum) != CFBooleanGetTypeID() {
            let sec = resetNum.intValue
            guard Double(sec) > now, sec <= Int(UInt32.max) else { return .empty }
            resetsAt = sec
        }

        let remaining = (min(max(100.0 - used, 0.0), 100.0) * 10.0).rounded() / 10.0
        return ProviderWindow(available: true, remainingPercent: remaining, windowMinutes: minutes, resetText: "", resetsAt: resetsAt)
    }

    /// Port of upstream `ClaudeLiveLimits.Merge`, extended for Claude Desktop usage fallback.
    public static func merge(local: ProviderStats, quota: ClaudeQuotaSnapshot?, status: String, now: TimeInterval) -> ProviderStats {
        guard let quota else {
            if local.available { return local }
            var copy = local
            copy.available = false
            copy.stale = false
            copy.primary = .empty
            copy.secondary = .empty
            copy.ageS = 0
            copy.status = status
            return copy
        }
        let age = Int(min(max(now - quota.capturedAt, 0), 31_536_000))
        if local.available && !local.stale && local.ageS < age {
            return local
        }
        let maxAge = quota.isDesktopFallback ? 48 * 3600 : 1800
        let timely = quota.capturedAt <= now + 300 && age <= maxAge
        func valid(_ w: ProviderWindow) -> ProviderWindow {
            timely && w.available && (w.resetsAt == 0 || w.resetsAt > Int(now)) ? w : .empty
        }
        let p = valid(quota.primary)
        let s = valid(quota.secondary)
        let avail = p.available || s.available
        let stale: Bool
        if quota.isDesktopFallback {
            stale = avail && age > 12 * 3600
        } else {
            stale = avail && (status != "live" || age > 120)
        }
        var out = local
        out.available = avail
        out.primary = p
        out.secondary = s
        out.ageS = avail ? age : 0
        out.stale = stale
        out.status = avail ? (stale ? "cached" : "live") : (status == "live" ? "no_limits" : status)
        if !quota.plan.isEmpty { out.plan = quota.plan }
        return out
    }

    private static func readKeychainCredential() -> Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var rawData: Data?
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            rawData = data
        } else {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    rawData = pipe.fileHandleForReading.readDataToEndOfFile()
                }
            }
        }
        guard let rawData,
              let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        let exp = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        let rawSub = (oauth["subscriptionType"] as? String) ?? ""
        let plan = rawSub.isEmpty ? "" : rawSub.prefix(1).uppercased() + rawSub.dropFirst()
        let fp = SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return Credential(token: token, expiresAtMs: exp, plan: plan, fingerprint: fp)
    }
}
