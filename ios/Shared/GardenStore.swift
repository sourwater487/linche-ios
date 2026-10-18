import Foundation
import Security

struct GardenSentence: Codable {
    let date: Date
    let text: String
}

struct GardenSnapshot: Codable {
    let generatedAt: Date
    let validUntil: Date
    let entries: [GardenSentence]

    func current(at date: Date) -> GardenSentence? {
        guard date < validUntil else { return nil }
        return entries.last { $0.date <= date }
    }
}

struct GardenCredential: Codable {
    let token: String
    let expiresAt: Double
    var expiry: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
}

enum GardenStore {
    static let kind = "LinCheGarden"
    private static let originalGroup = "group.com.linche.privateapp.garden"
    // SideStore rewrites App Groups during signing. Read the installed profile,
    // not a hardcoded team identifier, and let the OS enforce container access.
    static let group: String? = {
        var candidates = [originalGroup]
        let profile = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        if let data = try? Data(contentsOf: profile),
           let start = data.range(of: Data("<plist".utf8)),
           let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
           let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any],
           let groups = entitlements["com.apple.security.application-groups"] as? [String] {
            candidates = groups.filter { $0.contains(originalGroup) } + candidates
        }
        return candidates.first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
    }()

    private static var cacheURL: URL? {
        guard let group else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("garden-timeline.json")
    }

    private static var credentialQuery: [String: Any]? {
        guard let group else { return nil }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.linche.garden-widget.v1",
                kSecAttrAccount as String: "session", kSecAttrAccessGroup as String: group]
    }

    @discardableResult static func saveCredential(_ value: GardenCredential) -> Bool {
        guard let query = credentialQuery, let data = try? JSONEncoder().encode(value) else { return false }
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func credential() -> GardenCredential? {
        guard var query = credentialQuery else { return nil }
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(GardenCredential.self, from: data)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let text = try value.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: value.codingPath, debugDescription: "Invalid Garden date"))
        }
        return decoder
    }

    static func cached() -> GardenSnapshot? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(GardenSnapshot.self, from: data)
    }

    private static func save(_ snapshot: GardenSnapshot) {
        guard let url = cacheURL else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func invalidate() {
        saveCredential(GardenCredential(token: "", expiresAt: 0))
        save(GardenSnapshot(generatedAt: Date(), validUntil: Date(), entries: []))
    }

    static func fetch() async throws -> GardenSnapshot? {
        guard let auth = credential(), !auth.token.isEmpty, auth.expiry > Date() else { return nil }
        var request = URLRequest(url: URL(string: "https://ios.lin-che.com/api/garden/widget")!)
        request.setValue("__Host-LinCheNative=\(auth.token)", forHTTPHeaderField: "Cookie")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: GardenNoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard credential()?.token == auth.token else { return nil }
        guard let response = response as? HTTPURLResponse else { return nil }
        if response.statusCode == 401 || response.statusCode == 403 { invalidate(); return nil }
        guard response.statusCode == 200, data.count <= 256 * 1024 else { return nil }
        let remote = try decoder().decode(GardenSnapshot.self, from: data)
        guard remote.validUntil > Date(), remote.validUntil.timeIntervalSinceNow <= 3 * 86400,
              !remote.entries.isEmpty, remote.entries.count <= 200,
              remote.entries.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 1000 }) else { return nil }
        let until = min(remote.validUntil, auth.expiry)
        let snapshot = GardenSnapshot(generatedAt: remote.generatedAt, validUntil: until,
            entries: remote.entries.filter { $0.date < until }.sorted { $0.date < $1.date })
        save(snapshot)
        return snapshot
    }
}

private final class GardenNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
