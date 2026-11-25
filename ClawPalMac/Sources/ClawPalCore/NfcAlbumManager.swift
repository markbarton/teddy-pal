import AppKit
import ApplicationServices
import Foundation

public struct NfcAlbumEntry: Codable, Equatable, Identifiable {
    public var id: String { uid }
    public var uid: String = ""
    public var service: String // "spotify" or "apple_music"
    public var uri: String
    public var label: String
    public var url: String?
    public var kind: String?
    public var catalogId: String?

    enum CodingKeys: String, CodingKey {
        case service, uri, label, url, kind
        case catalogId = "catalog_id"
    }

    public init(uid: String = "", service: String, uri: String, label: String, url: String? = nil, kind: String? = nil, catalogId: String? = nil) {
        self.uid = uid
        self.service = service
        self.uri = uri
        self.label = label
        self.url = url
        self.kind = kind
        self.catalogId = catalogId
    }
}

public struct LastNfcTap: Codable, Equatable {
    public var uid: String
    public var at: Double
}

public final class NfcAlbumManager {
    public let albumsURL: URL
    public let lastTapURL: URL

    public init(albumsURL: URL = ClawPalPaths.nfcAlbumsFile, lastTapURL: URL = ClawPalPaths.lastNfcFile) {
        self.albumsURL = albumsURL
        self.lastTapURL = lastTapURL
    }

    public static func normalizeUid(_ raw: String) -> String? {
        let cleaned = raw.lowercased().filter { !":-\t\n ".contains($0) }
        guard (8...20).contains(cleaned.count), cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }
        return cleaned
    }

    public static func normalizeSpotifyUri(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^spotify:(album|playlist|track|artist):[A-Za-z0-9]{10,40}$"#, options: .regularExpression) != nil {
            return text
        }
        guard let url = URL(string: text),
              let host = url.host?.lowercased(),
              ["open.spotify.com", "play.spotify.com"].contains(host) else { return nil }
        var parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 3 && parts[0].hasPrefix("intl-") { parts.removeFirst() }
        guard parts.count >= 2, ["album", "playlist", "track", "artist"].contains(parts[0]) else { return nil }
        let uri = "spotify:\(parts[0]):\(parts[1])"
        return uri.range(of: #"^spotify:(album|playlist|track|artist):[A-Za-z0-9]{10,40}$"#, options: .regularExpression) != nil ? uri : nil
    }

    public static func parseAppleMusicUrl(_ raw: String) -> NfcAlbumEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "music"].contains(scheme),
              let host = url.host?.lowercased(),
              ["music.apple.com", "itunes.apple.com"].contains(host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let kind: String, slug: String, cid: String
        if parts.count >= 4, ["album", "playlist", "station", "artist"].contains(parts[1]) {
            kind = parts[1]; slug = parts[2]; cid = parts[3]
        } else if parts.count >= 3, ["album", "playlist", "station", "artist"].contains(parts[0]) {
            kind = parts[0]; slug = parts[1]; cid = parts[2]
        } else {
            return nil
        }
        let title = slug.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return NfcAlbumEntry(
            service: "apple_music",
            uri: title,
            label: title,
            url: "music://\(host)\(url.path)",
            kind: kind,
            catalogId: cid
        )
    }

    public static func makeEntry(uid rawUid: String, target rawTarget: String, label customLabel: String = "", forceAppleMusicName: Bool = false) -> NfcAlbumEntry? {
        guard let uid = normalizeUid(rawUid) else { return nil }
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        if forceAppleMusicName {
            return NfcAlbumEntry(uid: uid, service: "apple_music", uri: target, label: customLabel.isEmpty ? target : customLabel)
        }
        if let sp = normalizeSpotifyUri(target) {
            return NfcAlbumEntry(uid: uid, service: "spotify", uri: sp, label: customLabel.isEmpty ? sp : customLabel)
        }
        if var am = parseAppleMusicUrl(target) {
            am.uid = uid
            if !customLabel.isEmpty { am.label = customLabel }
            return am
        }
        // Fallback: treat plain text as an Apple Music library album/playlist name.
        return NfcAlbumEntry(uid: uid, service: "apple_music", uri: target, label: customLabel.isEmpty ? target : customLabel)
    }

    public func loadAll() -> [NfcAlbumEntry] {
        guard let data = try? Data(contentsOf: albumsURL),
              let dict = try? JSONDecoder().decode([String: NfcAlbumEntry].self, from: data) else {
            return []
        }
        return dict.map { key, val in
            var copy = val
            copy.uid = key
            return copy
        }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    public func save(_ entry: NfcAlbumEntry) throws {
        var dict = loadDictionary()
        dict[entry.uid] = entry
        try writeDictionary(dict)
    }

    public func remove(uid: String) throws {
        var dict = loadDictionary()
        dict.removeValue(forKey: uid)
        try writeDictionary(dict)
    }

    public func recordLastTap(uid: String) {
        let tap = LastNfcTap(uid: uid, at: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(tap) {
            try? FileManager.default.createDirectory(at: lastTapURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: lastTapURL, options: .atomic)
        }
    }

    public func readLastTap() -> LastNfcTap? {
        guard let data = try? Data(contentsOf: lastTapURL) else { return nil }
        return try? JSONDecoder().decode(LastNfcTap.self, from: data)
    }

    public func handleTap(rawUid: String) -> (uid: String?, played: Bool, label: String, note: String) {
        guard let uid = Self.normalizeUid(rawUid) else { return (nil, false, "", "invalid uid") }
        recordLastTap(uid: uid)
        let dict = loadDictionary()
        guard let entry = dict[uid] else {
            return (uid, false, "", "unmapped")
        }
        let (ok, note) = play(entry)
        return (uid, ok, entry.label, note)
    }

    public func play(_ entry: NfcAlbumEntry) -> (Bool, String) {
        let route = AudioRouting.loadRoute()
        var routeNote = ""
        if route.mode != .default {
            let (ok, msg) = AudioRouting.applyRoute(route)
            if !ok { routeNote = "route warning: \(msg)" }
        }

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        if entry.service == "spotify" {
            guard let uri = Self.normalizeSpotifyUri(entry.uri) else { return (false, "invalid spotify uri") }
            let script = "tell application \"Spotify\"\n  play track \"\(esc(uri))\"\nend tell"
            return MediaController.runOsascript(script, timeout: 8) != nil ? (true, routeNote) : (false, "Spotify script failed")
        }

        let name = esc(entry.uri)
        let url = esc(entry.url ?? "")
        let fallback = url.isEmpty
            ? "    error \"Playlist or album not found in Music library\"\n"
            : "    open location \"\(url)\"\n    activate\n    return \"opened_url\"\n"

        let script = """
        tell application "Music"
          if exists playlist "\(name)" then
            play playlist "\(name)"
            return "played"
          else
            set matches to (every track of library playlist 1 whose album is "\(name)")
            if (count of matches) > 0 then
              if not (exists user playlist "ClawPal NFC") then
                make new user playlist with properties {name:"ClawPal NFC"}
              else
                delete every track of user playlist "ClawPal NFC"
              end if
              repeat with t in matches
                duplicate t to user playlist "ClawPal NFC"
              end repeat
              play user playlist "ClawPal NFC"
              return "played"
            else
        \(fallback)    end if
          end if
        end tell
        """
        guard let output = MediaController.runOsascript(script, timeout: 10) else {
            return (false, "Apple Music script failed")
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "opened_url" {
            let (clicked, detail) = Self.clickMusicContentPlayButton()
            let combined = [routeNote, detail].filter { !$0.isEmpty }.joined(separator: "; ")
            return (clicked || true, combined)
        }
        return (true, routeNote)
    }

    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public static func promptAccessibilityPermission() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Native AXUIElement helper that waits for Music.app's opened catalog page to render
    /// and presses its content-area Play button (ignoring the top transport bar).
    private static func clickMusicContentPlayButton() -> (Bool, String) {
        guard AXIsProcessTrusted() else {
            _ = promptAccessibilityPermission()
            return (false, "needs Accessibility permission for ClawPalMac (System Settings -> Privacy & Security -> Accessibility)")
        }
        guard let musicApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Music" }) else {
            return (false, "Music.app not running")
        }
        let axApp = AXUIElementCreateApplication(musicApp.processIdentifier)
        let deadline = Date().addingTimeInterval(6.0)
        var lastSeenPlayButtons: [String] = []

        // Brief initial pause so Music starts navigating to the new URL before we click an old page's button.
        Thread.sleep(forTimeInterval: 0.6)

        while Date() < deadline {
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement],
               let win = windows.first {
                let winY = axPosition(win)?.y ?? 0
                var seen: [String] = []
                if let btn = findContentPlayButton(in: win, windowTopY: winY, depth: 0, seen: &seen) {
                    let err = AXUIElementPerformAction(btn.element, kAXPressAction as CFString)
                    if err == .success {
                        return (true, "auto-played '\(btn.label)'")
                    }
                    return (false, "AXPress failed (\(err.rawValue)) on '\(btn.label)'")
                }
                if !seen.isEmpty { lastSeenPlayButtons = seen }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let info = lastSeenPlayButtons.isEmpty ? "none" : lastSeenPlayButtons.prefix(6).joined(separator: ", ")
        return (false, "content Play button not found (saw: \(info))")
    }

    private static func axString(_ el: AXUIElement, _ attr: String) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let s = ref as? String else {
            return ""
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func axPosition(_ el: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &ref) == .success,
              let val = ref, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero
        return AXValueGetValue(val as! AXValue, .cgPoint, &pt) ? pt : nil
    }

    private static func findContentPlayButton(
        in el: AXUIElement,
        windowTopY: CGFloat,
        depth: Int,
        seen: inout [String]
    ) -> (element: AXUIElement, label: String)? {
        if depth > 22 { return nil }
        let role = axString(el, kAXRoleAttribute as String)
        if role == (kAXButtonRole as String) {
            let title = axString(el, kAXTitleAttribute as String)
            let desc = axString(el, kAXDescriptionAttribute as String)
            let label = !title.isEmpty ? title : desc
            let lower = label.lowercased()
            if lower == "play" || lower.hasPrefix("play ") {
                let relY = (axPosition(el)?.y ?? 0) - windowTopY
                seen.append("\(label)@y=\(Int(relY))")
                // Skip Music.app's top transport bar (typically y ~ 10..65 relative to window top).
                if relY > 85 {
                    return (el, label)
                }
            }
        }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }
        for kid in kids {
            if let hit = findContentPlayButton(in: kid, windowTopY: windowTopY, depth: depth + 1, seen: &seen) {
                return hit
            }
        }
        return nil
    }

    private func loadDictionary() -> [String: NfcAlbumEntry] {
        guard let data = try? Data(contentsOf: albumsURL),
              let dict = try? JSONDecoder().decode([String: NfcAlbumEntry].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func writeDictionary(_ dict: [String: NfcAlbumEntry]) throws {
        try FileManager.default.createDirectory(at: albumsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dict)
        try data.write(to: albumsURL, options: .atomic)
    }
}
