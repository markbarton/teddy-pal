import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

public struct AlbumCover: Equatable {
    public let id: Int
    public let pixels: Data
    public let color: Int
    public let previewImageData: Data?
}

public enum CoverConverter {
    public static let coverSize = 160

    /// Convert JPEG/PNG/TIFF artwork bytes into 160x160 RGB565 little-endian + dominant accent color.
    public static func makeCover(from imageData: Data) -> AlbumCover? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        // Center-crop to square (equivalent to Pillow ImageOps.fit).
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        let side = min(w, h)
        let cropRect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        let size = coverSize
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))

        var out = Data(count: size * size * 2)
        out.withUnsafeMutableBytes { rawBuf in
            let dst = rawBuf.bindMemory(to: UInt8.self)
            for p in 0..<(size * size) {
                let r = UInt16(rgba[p * 4])
                let g = UInt16(rgba[p * 4 + 1])
                let b = UInt16(rgba[p * 4 + 2])
                let v: UInt16 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
                dst[p * 2] = UInt8(v & 0xFF)
                dst[p * 2 + 1] = UInt8(v >> 8)
            }
        }

        let digest = Array(SHA256.hash(data: out))
        let rawId = Int(UInt32(digest[0]) | (UInt32(digest[1]) << 8) | (UInt32(digest[2]) << 16) | (UInt32(digest[3]) << 24)) & 0x7FFF_FFFF
        let color = accentColor(rgba: rgba)
        return AlbumCover(id: rawId == 0 ? 1 : rawId, pixels: out, color: color, previewImageData: imageData)
    }

    public static func accentColor(rgba: [UInt8]) -> Int {
        let pixels = rgba.count / 4
        guard pixels > 0 else { return 0 }
        var bins = Array(repeating: (w: 0.0, r: 0.0, g: 0.0, b: 0.0), count: 12)
        var total = 0.0

        for i in stride(from: 0, to: pixels * 4, by: 4) {
            let r = Double(rgba[i]) / 255.0
            let g = Double(rgba[i + 1]) / 255.0
            let b = Double(rgba[i + 2]) / 255.0
            let hi = max(r, max(g, b)), lo = min(r, min(g, b))
            let chroma = hi - lo
            let weight = chroma * chroma * (1.0 - abs(hi + lo - 1.0))
            if weight <= 0 { continue }
            var hue: Double
            if hi == r { hue = (g - b) / chroma }
            else if hi == g { hue = (b - r) / chroma + 2.0 }
            else { hue = (r - g) / chroma + 4.0 }
            if hue < 0 { hue += 6.0 }
            let slot = Int(hue * 2.0) % 12
            bins[slot].w += weight
            bins[slot].r += r * weight
            bins[slot].g += g * weight
            bins[slot].b += b * weight
            total += weight
        }

        guard total >= Double(pixels) * 0.004 else { return 0 }
        guard let best = bins.max(by: { $0.w < $1.w }), best.w > 0 else { return 0 }
        let r = best.r / best.w, g = best.g / best.w, b = best.b / best.w
        let hi = max(r, max(g, b)), lo = min(r, min(g, b))
        let l = (hi + lo) / 2.0
        let s = hi == lo ? 0.0 : (hi - lo) / (1.0 - abs(2.0 * l - 1.0))
        var h = 0.0
        if hi != lo {
            if hi == r { h = (g - b) / (hi - lo) }
            else if hi == g { h = (b - r) / (hi - lo) + 2.0 }
            else { h = (r - g) / (hi - lo) + 4.0 }
            if h < 0 { h += 6.0 }
        }
        let sat = min(max(s, 0.5), 0.85)
        let light = min(max(l, 0.58), 0.70)
        let c = (1.0 - abs(2.0 * light - 1.0)) * sat
        let x = c * (1.0 - abs(h.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = light - c / 2.0
        let rgb: (Double, Double, Double)
        switch Int(h) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        let R = Int((min(max(rgb.0 + m, 0), 1) * 255.0).rounded())
        let G = Int((min(max(rgb.1 + m, 0), 1) * 255.0).rounded())
        let B = Int((min(max(rgb.2 + m, 0), 1) * 255.0).rounded())
        return (R << 16) | (G << 8) | B
    }
}

public struct MediaTrack: Equatable {
    public let app: String
    public let state: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Int
    public let position: Int
    public let shuffle: Bool
    public let repeatMode: Int
    public let volume: Int
    public let trackId: String
    public let artUrl: String
}

/// Polls running Spotify or Music.app without ever launching either app, and executes display touch controls.
public final class MediaController {
    private static let sep = "\u{1f}"
    private let lock = NSLock()
    private var track: MediaTrack?
    private var running: Set<String> = []
    private var _cover: AlbumCover?
    private var coverKey = ""
    private var mutedVolume: [String: Int] = [:]

    public init() {}

    public var cover: AlbumCover? {
        lock.lock(); defer { lock.unlock() }
        return _cover
    }

    public func poll() {
        let activeApps = Self.runningMediaApps()
        var tracks: [MediaTrack] = []
        for app in ["Spotify", "Music"] where activeApps.contains(app) {
            if let t = Self.readPlayer(app) { tracks.append(t) }
        }
        let chosen = tracks.first(where: { $0.state == "playing" }) ?? tracks.first(where: { $0.state == "paused" })
        lock.lock()
        self.running = activeApps
        self.track = chosen
        lock.unlock()

        let key = (chosen != nil && chosen!.state != "stopped")
            ? "\(chosen!.app):\(chosen!.trackId):\(chosen!.album)"
            : ""
        if !key.isEmpty && key != coverKey {
            coverKey = key
            let fetched = chosen.flatMap(Self.fetchCover)
            lock.lock()
            _cover = fetched
            lock.unlock()
        } else if key.isEmpty {
            coverKey = ""
            lock.lock()
            _cover = nil
            lock.unlock()
        }
    }

    public func snapshot(control: (id: Int, ok: Bool, error: String)) -> MusicStats {
        lock.lock()
        let t = track
        let run = running
        let cov = _cover
        let muted = t.map { mutedVolume[$0.app] != nil } ?? false
        lock.unlock()

        let live = t != nil && t!.state != "stopped"
        var m = MusicStats()
        m.running = !run.isEmpty
        m.available = live
        m.playing = live && t!.state == "playing"
        m.title = clawpalDisplayText(live ? t!.title : "", maxBufferBytes: 192)
        m.artist = clawpalDisplayText(live ? t!.artist : "", maxBufferBytes: 128)
        m.album = clawpalDisplayText(live ? t!.album : "", maxBufferBytes: 128)
        m.positionS = live ? min(max(t!.position, 0), 604_800) : 0
        m.durationS = live ? min(max(t!.duration, 0), 604_800) : 0
        m.canPlayPause = live
        m.canNext = live
        m.canPrevious = live
        m.canShuffle = live
        m.shuffle = live && t!.shuffle
        m.canRepeat = live
        m.repeatMode = live ? t!.repeatMode : 0
        m.canSeek = live && t!.duration > 0
        m.canVolume = live
        m.volume = live ? min(max(t!.volume, 0), 100) : 0
        m.muted = live && muted
        m.source = live ? (t!.app == "Spotify" ? "Spotify" : "Apple Music") : ""
        m.artColor = (live && cov != nil) ? cov!.color : 0
        m.artId = (live && cov != nil) ? cov!.id : 0
        if control.id > 0 {
            m.controlId = control.id
            m.controlOk = control.ok
            m.controlError = clawpalDisplayText(control.error, maxBufferBytes: 32)
        }
        return m
    }

    public func execute(action: String, value: Int?) -> (Bool, String) {
        lock.lock()
        let t = track
        lock.unlock()
        guard let t, t.state != "stopped" else { return (false, "unavailable") }
        let app = t.app
        let body: String
        switch action {
        case "play_pause": body = "playpause"
        case "next": body = "next track"
        case "previous": body = "previous track"
        case "shuffle":
            body = app == "Spotify"
                ? "set shuffling to not shuffling"
                : "set shuffle enabled to not shuffle enabled"
        case "repeat":
            body = app == "Spotify"
                ? "set repeating to not repeating"
                : "if song repeat is off then\nset song repeat to all\nelse if song repeat is all then\nset song repeat to one\nelse\nset song repeat to off\nend if"
        case "seek":
            guard let v = value else { return (false, "unsupported") }
            body = "set player position to \(min(max(v, 0), max(t.duration - 1, 0)))"
        case "volume":
            guard let v = value else { return (false, "unsupported") }
            lock.lock(); mutedVolume.removeValue(forKey: app); lock.unlock()
            body = "set sound volume to \(min(max(v, 0), 100))"
        case "mute":
            lock.lock()
            let prev = mutedVolume.removeValue(forKey: app)
            if prev == nil { mutedVolume[app] = t.volume > 0 ? t.volume : 50 }
            lock.unlock()
            body = "set sound volume to \(prev ?? 0)"
        default:
            return (false, "unsupported")
        }

        let script = "tell application \"\(app)\"\n\(body)\nend tell"
        guard Self.runOsascript(script, timeout: 4) != nil else { return (false, "failed") }
        poll()
        return (true, "")
    }

    private static func runningMediaApps() -> Set<String> {
        var out: Set<String> = []
        for app in NSWorkspace.shared.runningApplications {
            if app.bundleIdentifier == "com.spotify.client" { out.insert("Spotify") }
            else if app.bundleIdentifier == "com.apple.Music" { out.insert("Music") }
        }
        return out
    }

    private static func readPlayer(_ app: String) -> MediaTrack? {
        let s = sep
        let script: String
        if app == "Spotify" {
            script = """
            tell application "Spotify"
              set s to (player state as text)
              if s is "stopped" then return s
              set t to current track
              return s & "\(s)" & (name of t) & "\(s)" & (artist of t) & "\(s)" & (album of t) & "\(s)" & ((duration of t) div 1000) & "\(s)" & (player position as integer) & "\(s)" & shuffling & "\(s)" & repeating & "\(s)" & sound volume & "\(s)" & (id of t) & "\(s)" & (artwork url of t)
            end tell
            """
        } else {
            script = """
            tell application "Music"
              set s to (player state as text)
              if s is "stopped" then return s
              set t to current track
              return s & "\(s)" & (name of t) & "\(s)" & (artist of t) & "\(s)" & (album of t) & "\(s)" & ((duration of t) as integer) & "\(s)" & (player position as integer) & "\(s)" & shuffle enabled & "\(s)" & (song repeat as text) & "\(s)" & sound volume & "\(s)" & (persistent ID of t) & "\(s)"
            end tell
            """
        }
        guard let raw = runOsascript(script, timeout: 4) else { return nil }
        let parts = raw.components(separatedBy: sep)
        if parts.first == "stopped" || parts.count < 11 {
            return MediaTrack(app: app, state: "stopped", title: "", artist: "", album: "", duration: 0, position: 0, shuffle: false, repeatMode: 0, volume: 0, trackId: "", artUrl: "")
        }
        func num(_ str: String) -> Int {
            Int(Double(str.replacingOccurrences(of: ",", with: ".")) ?? 0)
        }
        let repeatMap = ["true": 2, "false": 0, "off": 0, "one": 1, "all": 2]
        return MediaTrack(
            app: app,
            state: parts[0],
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: max(num(parts[4]), 0),
            position: max(num(parts[5]), 0),
            shuffle: parts[6] == "true",
            repeatMode: repeatMap[parts[7]] ?? 0,
            volume: min(max(num(parts[8]), 0), 100),
            trackId: parts[9],
            artUrl: parts[10]
        )
    }

    private static func fetchCover(for track: MediaTrack) -> AlbumCover? {
        if track.app == "Spotify", track.artUrl.hasPrefix("https://"), let url = URL(string: track.artUrl) {
            if let data = try? Data(contentsOf: url), data.count <= 4_000_000 {
                return CoverConverter.makeCover(from: data)
            }
            return nil
        }
        if track.app == "Music" {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clawpal-art-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let script = """
            tell application "Music"
              set d to raw data of artwork 1 of current track
            end tell
            set f to open for access (POSIX file "\(tmp.path)") with write permission
            set eof f to 0
            write d to f
            close access f
            """
            guard runOsascript(script, timeout: 6) != nil,
                  let data = try? Data(contentsOf: tmp) else { return nil }
            return CoverConverter.makeCover(from: data)
        }
        return nil
    }

    @discardableResult
    static func runOsascript(_ script: String, language: String? = nil, timeout: TimeInterval = 5) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        var args: [String] = []
        if let language { args += ["-l", language] }
        args += ["-e", script]
        proc.arguments = args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .newlines)
    }
}
