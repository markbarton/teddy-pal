import CryptoKit
import Darwin
import Foundation
import Security

public enum ClawPalPaths {
    public static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clawpal-mac", isDirectory: true)
    }
    public static var configFile: URL { home.appendingPathComponent("config.json") }
    public static var claudeDir: URL { home.appendingPathComponent("claude", isDirectory: true) }
    public static var nfcAlbumsFile: URL { home.appendingPathComponent("nfc_albums.json") }
    public static var lastNfcFile: URL { home.appendingPathComponent("last_nfc.json") }
}

public struct PairingConfig: Codable, Equatable {
    public var device: String
    public var deviceWifiId: String?
    public var board: String?
    public var version: String?
    public var city: String?
    public var latitude: Double?
    public var longitude: Double?
    public var timezone: String?
    public var lastIp: String?

    public var effectiveDeviceId: String { deviceWifiId ?? device }

    enum CodingKeys: String, CodingKey {
        case device, board, version, city, latitude, longitude, timezone
        case deviceWifiId = "device_wifi_id"
        case lastIp = "last_ip"
    }

    public static func load(from url: URL = ClawPalPaths.configFile) throws -> PairingConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PairingConfig.self, from: data)
    }

    public func save(to url: URL = ClawPalPaths.configFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

public enum ClawPalKeychain {
    public static let service = "ClawPal pairing token"

    public static func loadToken(device: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: device,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback to `security` CLI if the Keychain item was created by Python/security ACL.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-a", device, "-s", service, "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw ClawPalError.missingToken(device)
        }
        return text
    }
}

public enum ClawPalError: LocalizedError {
    case missingToken(String)
    case displayNotFound
    case httpError(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken(let id): return "No pairing token in Keychain for \(id)"
        case .displayNotFound: return "ClawPal display not found on local network"
        case .httpError(let code, let body): return "Display answered HTTP \(code): \(body)"
        case .invalidResponse(let msg): return msg
        }
    }
}

public final class ClawPalEndpoint {
    public static let discoveryPort: UInt16 = 42170
    public static let monitorPort: UInt16 = 42171
    public static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public let host: String
    public let deviceId: String
    public let challenge: String
    private var counter: Int = 0

    public init(host: String, deviceId: String, challenge: String) {
        self.host = host
        self.deviceId = deviceId
        self.challenge = challenge
    }

    public func sign(method: String, path: String, token: String, bodyHash: String = ClawPalEndpoint.emptySHA256) -> String {
        counter += 1
        let sig = ClawPalAuth.requestSignature(
            token: token,
            method: method,
            path: path,
            challenge: challenge,
            counter: counter,
            bodyHash: bodyHash
        )
        return "ClawPal-HMAC c=\(challenge),n=\(counter),s=\(sig)"
    }
}

public enum ClawPalAuth {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hmacSHA256Hex(token: String, message: String) -> String {
        let key = SymmetricKey(data: Data(token.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    public static func helloProof(token: String, nonce: String, deviceId: String, port: Int, challenge: String) -> String {
        hmacSHA256Hex(token: token, message: "\(nonce)|\(deviceId)|\(port)|\(challenge)")
    }

    public static func requestSignature(token: String, method: String, path: String, challenge: String, counter: Int, bodyHash: String) -> String {
        let msg = "clawpal-auth-v2\n\(method)\n\(path)\n\(challenge)\n\(counter)\n\(bodyHash)"
        return hmacSHA256Hex(token: token, message: msg)
    }

    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    public static func isPrivateLAN(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254)
    }
}

public enum ClawPalDiscovery {
    private struct HelloPacket: Decodable {
        let type: String
        let v: Int
        let id: String
        let port: Int
        let nonce: String
        let challenge: String
        let proof: String
    }

    public static func discover(
        deviceId: String,
        token: String,
        lastHost: String? = nil,
        tries: Int = 3,
        discoveryPort: UInt16 = ClawPalEndpoint.discoveryPort,
        monitorPort: Int = Int(ClawPalEndpoint.monitorPort)
    ) -> ClawPalEndpoint? {
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        let nonce = nonceBytes.map { String(format: "%02x", $0) }.joined()

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var targets = ["255.255.255.255"]
        if let lastHost, !lastHost.isEmpty { targets.append(lastHost) }
        let probe = Array("BUDDYOS_DISCOVER_V1 \(nonce)".utf8)

        for _ in 0..<tries {
            for target in targets {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = discoveryPort.bigEndian
                guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
                _ = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(fd, probe, probe.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                var buf = [UInt8](repeating: 0, count: 1024)
                var senderAddr = sockaddr_in()
                var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &senderAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, &buf, buf.count, 0, $0, &senderLen)
                    }
                }
                if n <= 0 { break }

                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sinAddr = senderAddr.sin_addr
                inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                let senderIP = String(cString: ipBuf)
                guard ClawPalAuth.isPrivateLAN(senderIP) || senderIP == "127.0.0.1" else { continue }

                let data = Data(buf[0..<n])
                guard let hello = try? JSONDecoder().decode(HelloPacket.self, from: data),
                      hello.type == "buddy.hello",
                      hello.v == 2,
                      hello.nonce == nonce,
                      hello.id == deviceId else { continue }

                let expected = ClawPalAuth.helloProof(
                    token: token,
                    nonce: nonce,
                    deviceId: deviceId,
                    port: monitorPort,
                    challenge: hello.challenge
                )
                if ClawPalAuth.constantTimeEqual(expected, hello.proof) {
                    return ClawPalEndpoint(host: senderIP, deviceId: deviceId, challenge: hello.challenge)
                }
            }
        }
        return nil
    }
}

public enum ClawPalHTTP {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.httpMaximumConnectionsPerHost = 1
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 12
        return URLSession(configuration: cfg)
    }()

    public static func signedGet(endpoint: ClawPalEndpoint, token: String, path: String) async throws -> (Int, Data) {
        guard let url = URL(string: "http://\(endpoint.host):\(ClawPalEndpoint.monitorPort)\(path)") else {
            throw ClawPalError.invalidResponse("Bad URL for \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(endpoint.sign(method: "GET", path: path, token: token), forHTTPHeaderField: "Authorization")
        req.setValue("close", forHTTPHeaderField: "Connection")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    public static func signedPost(
        endpoint: ClawPalEndpoint,
        token: String,
        path: String,
        body: Data,
        contentType: String = "application/octet-stream",
        extraHeaders: [String: String] = [:]
    ) async throws -> (Int, Data) {
        guard let url = URL(string: "http://\(endpoint.host):\(ClawPalEndpoint.monitorPort)\(path)") else {
            throw ClawPalError.invalidResponse("Bad URL for \(path)")
        }
        let bodyHash = ClawPalAuth.sha256Hex(body)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(endpoint.sign(method: "POST", path: path, token: token, bodyHash: bodyHash), forHTTPHeaderField: "Authorization")
        req.setValue(bodyHash, forHTTPHeaderField: "X-ClawPal-Body-SHA256")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("close", forHTTPHeaderField: "Connection")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}
