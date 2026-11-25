import ClawPalCore
import Foundation

private var passed = 0

private func check(_ cond: @autoclosure () -> Bool, _ label: String) {
    if !cond() {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
    }
    passed += 1
    print("PASS: \(label)")
}

@main
struct ClawPalChecks {
    static func main() throws {
        // 1. Auth & LAN checks
        let token = String(repeating: "a", count: 64)
        let proof = ClawPalAuth.helloProof(
            token: token,
            nonce: "0123456789abcdef0123456789abcdef",
            deviceId: "a1b2c3d4e5f6",
            port: 42171,
            challenge: "fedcba9876543210fedcba9876543210"
        )
        check(proof.count == 64, "helloProof produces 64 hex chars")
        check(ClawPalAuth.constantTimeEqual(proof, proof), "constantTimeEqual true on match")
        check(!ClawPalAuth.constantTimeEqual(proof, String(repeating: "0", count: 64)), "constantTimeEqual false on mismatch")

        let ep = ClawPalEndpoint(host: "192.168.1.50", deviceId: "a1b2c3d4e5f6", challenge: "00112233445566778899aabbccddeeff")
        let h1 = ep.sign(method: "GET", path: "/monitor", token: token)
        let h2 = ep.sign(method: "GET", path: "/health", token: token)
        check(h1.contains("n=1,") && h2.contains("n=2,"), "HMAC counter increments per request")
        check(ClawPalAuth.isPrivateLAN("192.168.1.50") && !ClawPalAuth.isPrivateLAN("8.8.8.8"), "LAN address filter")

        // 2. UTF-8 byte boundary truncation
        let longPl = String(repeating: "ą", count: 40)
        let out = clawpalDisplayText(longPl, maxBufferBytes: 64)
        check(out.utf8.count < 64 && out == String(repeating: "ą", count: 31), "UTF-8 boundary truncation (<64 bytes)")
        check(clawpalDisplayText("hi\u{0001}\u{2028}ok", maxBufferBytes: 32) == "hiok", "control chars & U+2028 stripped")

        // 3. NFC UID + Spotify + Apple Music URL parsing
        check(NfcAlbumManager.normalizeUid("04:A1:B2:C3:D4:E5:80") == "04a1b2c3d4e580", "7-byte NTAG UID normalized")
        check(NfcAlbumManager.normalizeUid("not-hex") == nil, "invalid UID rejected")
        check(
            NfcAlbumManager.normalizeSpotifyUri("https://open.spotify.com/album/4LH4d3cOWNNsVw41Gqt2kv?si=abc")
                == "spotify:album:4LH4d3cOWNNsVw41Gqt2kv",
            "Spotify HTTPS album URL normalized"
        )
        let am = NfcAlbumManager.parseAppleMusicUrl("https://music.apple.com/gb/playlist/sample-mix/pl.u-00112233445566778899aabbccddeeff")
        check(
            am?.service == "apple_music"
                && am?.uri == "Sample Mix"
                && am?.catalogId == "pl.u-00112233445566778899aabbccddeeff"
                && am?.url == "music://music.apple.com/gb/playlist/sample-mix/pl.u-00112233445566778899aabbccddeeff",
            "Apple Music playlist URL parsed"
        )

        // 4. Schema 8 DeviceSettings
        var s = DeviceSettings()
        check(s.schema == 8 && s.isEnabled(.claude), "DeviceSettings schema 8 defaults")
        s.setEnabled(.claude, false)
        check(!s.isEnabled(.claude) && !s.homeOrder.contains(DisplayApp.claude.rawValue), "disabling app removes from homeOrder")
        s.setEnabled(.home, false)
        check(s.isEnabled(.home), "Home app stays enabled")
        let decoded = try JSONDecoder().decode(DeviceSettings.self, from: JSONEncoder().encode(s))
        check(decoded == s, "DeviceSettings JSON round trip")

        // 5. Claude snapshot rules
        let now: TimeInterval = 1_800_000_000
        let win = ProviderWindow(available: true, remainingPercent: 73.0, windowMinutes: 300, resetText: "", resetsAt: Int(now) + 1800)
        let session = ClaudeSessionRecord(
            id: "s1", title: "Release", project: "clawpal-mac", state: "working",
            seen: now, activityAt: now - 10, processId: 123, processStarted: 100,
            ended: false, primary: win, secondary: .empty, usageAt: now
        )
        let snap = ClaudeProvider.buildSnapshot(sessions: [session], now: now, alive: { _ in true })
        check(snap.running && snap.available && snap.status == "ready" && snap.activity?.workingCount == 1, "Claude live snapshot")
        let aged = ClaudeProvider.buildSnapshot(sessions: [session], now: now + 121, alive: { _ in true })
        check(aged.stale && aged.activity?.items.first?.state == "unknown", "Claude aged snapshot expires work after 120s")

        // 6. Vivid cover accent color + SystemStatsCollector
        var rgba = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = 220; rgba[i + 1] = 40; rgba[i + 2] = 60; rgba[i + 3] = 255
        }
        check(CoverConverter.accentColor(rgba: rgba) > 0, "CoverConverter vivid accent color")

        let sys = SystemStatsCollector()
        let sample = sys.sample()
        check(!sample.hostname.isEmpty && sample.memory.totalMb > 0 && !sample.cpu.name.isEmpty, "SystemStatsCollector native Mach/BSD sample")

        // 7. Jukebox audio route persistence & CoreAudio enumeration
        let outputs = AudioRouting.listCoreAudioOutputs()
        check(!outputs.isEmpty, "AudioRouting discovers CoreAudio output devices (\(outputs.count))")
        let tmpRoute = FileManager.default.temporaryDirectory.appendingPathComponent("clawpal-route-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpRoute) }
        let savedRoute = JukeboxAudioRoute(mode: .airplay, deviceName: "Living Room")
        try AudioRouting.saveRoute(savedRoute, to: tmpRoute)
        check(AudioRouting.loadRoute(from: tmpRoute) == savedRoute, "JukeboxAudioRoute round-trips cleanly")

        // 8. ClaudeLiveLimits parsing & merging
        let isoFuture = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: now + 3600))
        let usageJson = Data("""
        {"five_hour":{"utilization":28.5,"resets_at":"\(isoFuture)"},"seven_day":{"utilization":41.0,"resets_at":"\(isoFuture)"}}
        """.utf8)
        let parsedQuota = ClaudeLiveLimits.parseUsageResponse(usageJson, plan: "Max", now: now)
        check(parsedQuota?.primary.remainingPercent == 71.5 && parsedQuota?.secondary.remainingPercent == 59.0 && parsedQuota?.plan == "Max",
              "ClaudeLiveLimits parses 5h/7d utilization & reset timestamps")
        let microResetJson = Data("""
        {"five_hour":null,"seven_day":{"utilization":5.0,"resets_at":"2026-12-01T06:00:00.685537+00:00"}}
        """.utf8)
        let parsedMicro = ClaudeLiveLimits.parseUsageResponse(microResetJson, plan: "Max", now: 1_795_612_600)
        check(
            parsedMicro?.primary.available == false
                && parsedMicro?.secondary.available == true
                && parsedMicro?.secondary.remainingPercent == 95.0
                && (parsedMicro?.secondary.resetsAt ?? 0) > 1_795_612_600,
            "ClaudeLiveLimits parses null five_hour + microsecond seven_day resets_at"
        )
        let emptyLocal = ProviderStats(running: false, available: false, stale: false, status: "closed", plan: "", ageS: 0, primary: .empty, secondary: .empty, activity: nil)
        let merged = ClaudeLiveLimits.merge(local: emptyLocal, quota: parsedQuota, status: "live", now: now + 10)
        check(merged.available && !merged.stale && merged.status == "live" && merged.plan == "Max", "ClaudeLiveLimits merges live quota into claude object")

        let desktopTsMs = Int64((now - 5400) * 1000) // 90 minutes ago
        let desktopHistoryJson = Data("""
        {"version":2,"samples":[{"t":\(desktopTsMs - 3600_000),"u":{"fh":12,"sd":9}},{"t":\(desktopTsMs),"u":{"sd":4}}]}
        """.utf8)
        let desktopQuota = ClaudeLiveLimits.parseDesktopUsageHistory(desktopHistoryJson, plan: "Max", now: now)
        check(
            desktopQuota?.isDesktopFallback == true
                && desktopQuota?.primary.remainingPercent == 100.0
                && desktopQuota?.secondary.remainingPercent == 96.0
                && desktopQuota?.plan == "Max",
            "ClaudeLiveLimits parses Claude Desktop plan-usage-history.json (sd-only implies 100% 5h left)"
        )
        let mergedDesktop = ClaudeLiveLimits.merge(local: emptyLocal, quota: desktopQuota, status: "live", now: now)
        check(
            mergedDesktop.available && !mergedDesktop.stale && mergedDesktop.status == "live"
                && mergedDesktop.primary?.remainingPercent == 100.0
                && mergedDesktop.secondary?.remainingPercent == 96.0,
            "ClaudeLiveLimits merges recent Claude Desktop fallback without marking stale"
        )

        let transcriptJsonl = Data("""
        {"type":"user","cwd":"/Users/dev/projects/sample-api","message":{"role":"user","content":"<pasted_content id=\\"87a7\\"> command to update auth-cli global package"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Sure"}]}}
        """.utf8)
        let meta = ClaudeProvider.parseTranscriptMetadata(from: transcriptJsonl)
        check(
            meta.title == "command to update auth-cli global package" && meta.project == "sample-api",
            "ClaudeProvider extracts clean prompt title & project from JSONL transcript"
        )
        let customTitleJsonl = Data("""
        {"type":"user","cwd":"/Users/dev/projects/seo-tools","message":{"role":"user","content":"raw prompt"}}
        {"type":"custom-title","customTitle":"Sample SEO analysis tool"}
        """.utf8)
        let customMeta = ClaudeProvider.parseTranscriptMetadata(from: customTitleJsonl)
        check(
            customMeta.title == "Sample SEO analysis tool" && customMeta.project == "seo-tools",
            "ClaudeProvider prefers custom-title over first user prompt"
        )

        // 9. Amp usage & Need-You thread parsing
        let ampUsageSample = """
        Signed in as dev@example.com
        Amp Megawatt Tier: agent usage $19.93 of $20.00 remaining (100%), orb usage 662.6h of 750h a1.small orb hours remaining (88%) - period 2026-11-16 to 2026-12-16, resets upon renewal in 22 days
        Individual credits: $0.00 remaining - https://ampcode.com/settings
        """
        let parsedAmpUsage = AmpProvider.parseUsageOutput(ampUsageSample, now: now)
        check(
            parsedAmpUsage?.tier == "Megawatt"
                && parsedAmpUsage?.agentRemainingDollars == 19.93
                && parsedAmpUsage?.agentTotalDollars == 20.00
                && parsedAmpUsage?.orbRemainingHours == 662.6
                && parsedAmpUsage?.orbTotalHours == 750.0
                && parsedAmpUsage?.windowMinutes == 43_200
                && parsedAmpUsage?.resetsInDays == 22,
            "AmpProvider parses Megawatt agent + orb usage & period"
        )

        let exportJson = Data("""
        {
          "id": "T-123",
          "title": "Plan: monitoring app",
          "pinned": true,
          "updatedAt": "2026-11-23T18:25:37.474Z",
          "env": {"initial": {"trees": [{"uri": "file:///home/user/workspace/repo", "repository": {"url": "https://github.com/example-org/server-audit"}}]}},
          "meta": {
            "threadModel": {"model": "anthropic/claude-opus-5-5"},
            "statusMessage": {"text": "Plan ready: answer questions 1–4?", "updatedAt": "2026-11-23T18:25:37.474Z", "waitingOnInput": true},
            "lastKnownAgentState": {"state": "idle"}
          },
          "messages": [
            {"role": "assistant", "content": [{"type": "text", "text": "Here is the monitoring plan ready for your review."}]}
          ]
        }
        """.utf8)
        let exported = AmpProvider.parseExportedThread(
            exportJson,
            fallbackId: "T-123",
            fallbackTitle: "Fallback",
            fallbackUpdatedIso: "2026-11-23T18:25:37.474Z",
            fallbackUpdatedAt: now - 600,
            fallbackTree: nil,
            fallbackMessageCount: 5
        )
        check(
            exported?.waitingOnInput == true
                && exported?.project == "server-audit"
                && exported?.statusMessage == "Plan ready: answer questions 1–4?"
                && exported?.model == "claude-opus-5-5"
                && exported?.displayState == "waiting"
                && exported?.lastSnippet.contains("monitoring plan") == true,
            "AmpProvider parses exported Need-You thread metadata & snippet"
        )

        let idleThread = AmpThreadDetail(id: "T-idle", title: "Idle", url: "https://ampcode.com/threads/T-idle", updatedAt: now - 60, updatedIso: "", messageCount: 2, waitingOnInput: false)
        let ampStats = AmpProvider.buildProviderStats(
            usage: parsedAmpUsage,
            usageStatus: "ready",
            threads: [idleThread, exported!],
            fetchedAt: now,
            status: "local",
            now: now
        )
        check(
            ampStats.available
                && ampStats.plan == "Megawatt"
                && ampStats.primary?.available == true
                && ampStats.secondary?.available == true
                && ampStats.activity?.items.first?.state == "waiting"
                && ampStats.activity?.items.first?.project == "server-audit"
                && ampStats.activity?.items.first?.detail == "Plan ready: answer questions 1–4?",
            "AmpProvider prioritizes waiting Need-You threads, populates detail & usage gauges"
        )

        let manyWaiting = (0..<10).map { i in
            AmpThreadDetail(
                id: "T-w\(i)", title: "Waiting \(i)", url: "https://ampcode.com/threads/T-w\(i)",
                updatedAt: now - Double(i * 60), updatedIso: "", messageCount: 3,
                project: "proj-\(i)", waitingOnInput: true, statusMessage: "Action needed \(i)?"
            )
        }
        let multiStats = AmpProvider.buildProviderStats(
            usage: parsedAmpUsage, usageStatus: "ready", threads: manyWaiting,
            fetchedAt: now, status: "local", now: now
        )
        check(
            multiStats.activity?.items.count == 8
                && multiStats.activity?.items.last?.title == "Waiting 7"
                && multiStats.activity?.items.last?.detail == "Action needed 7?",
            "AmpProvider emits up to 8 waiting threads with 1-line detail"
        )

        print("\nAll \(passed) ClawPalCore Swift checks passed.")
    }
}
