import Foundation
import Security
import LocalAuthentication

struct DeviceSession: Codable {
    let token: String
    let deviceId: String
    let expiresAt: Double
    var expiry: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
}

enum DeviceAuthError: LocalizedError {
    case server(String)
    case keychain(OSStatus)
    case unavailable
    var errorDescription: String? {
        switch self {
        case .server("invalid_pairing_code"): return "配对码无效或已过期，请生成一个新的配对码。"
        case .server("device_not_authorized"): return "这台设备的授权已失效，请重新配对。"
        case .server("try_later"): return "尝试次数较多，请稍等一分钟再试。"
        case .server("authentication_required"): return "登录已到期，请使用 Face ID 继续。"
        case .server: return "暂时无法完成验证，请重试。"
        case .keychain(let status):
            #if DEBUG
            return "无法读取此设备的登录凭证（\(status)）。请确认手机已解锁。"
            #else
            return "无法读取此设备的登录凭证。请确认手机已解锁。"
            #endif
        case .unavailable: return "请先在系统设置中启用 Face ID 或 Touch ID。"
        }
    }
}

final class DeviceAuthentication {
    static let productionOrigin = URL(string: "https://ios.lin-che.com")!
    let origin: URL
    private let session: URLSession
    private let service: String
    private let keyTag: Data
    private let simulatorTest: Bool
    var cookieName: String { "__Host-LinCheNative" }

    init() {
        #if DEBUG && targetEnvironment(simulator)
        let testing = ProcessInfo.processInfo.environment["LINCHE_AUTH_TEST"] == "1"
        simulatorTest = testing
        origin = testing ? URL(string: "http://127.0.0.1:8765")! : Self.productionOrigin
        #else
        simulatorTest = false
        origin = Self.productionOrigin
        #endif
        let suffix = simulatorTest ? ".tests" : ""
        service = "com.linche.native-auth.v1" + suffix
        keyTag = Data(("com.linche.native-auth.device-key.v1" + suffix).utf8)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config, delegate: NoAuthRedirects(), delegateQueue: nil)
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read(_ account: String) throws -> Data? {
        var parameters = query(account)
        parameters[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(parameters as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DeviceAuthError.keychain(status) }
        return result as? Data
    }

    private func write(_ data: Data, account: String) throws {
        let parameters = query(account)
        let update = SecItemUpdate(parameters as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw DeviceAuthError.keychain(update) }
        var item = parameters
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceAuthError.keychain(status) }
    }

    func savedSession() throws -> DeviceSession? {
        guard let data = try read("session") else { return nil }
        return try JSONDecoder().decode(DeviceSession.self, from: data)
    }

    func deviceId() throws -> String? {
        guard let data = try read("device-id") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Called only after the user explicitly confirms replacement of local pairing.
    func resetPairing() throws {
        for account in ["session", "device-id"] {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceAuthError.keychain(status) }
        }
        let status = SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: keyTag, kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceAuthError.keychain(status) }
    }

    private func persist(_ value: DeviceSession) throws {
        try write(Data(value.deviceId.utf8), account: "device-id")
        try write(JSONEncoder().encode(value), account: "session")
    }

    func validate(_ value: DeviceSession) async throws {
        let data = try await request("status", cookie: value.token)
        let status = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status?["deviceId"] as? String == value.deviceId else { throw DeviceAuthError.server("authentication_required") }
    }

    private func request(_ endpoint: String, body: [String: String]? = nil, cookie: String? = nil) async throws -> Data {
        var request = URLRequest(url: origin.appendingPathComponent("native-auth/" + endpoint))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body = body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let cookie = cookie { request.setValue("\(cookieName)=\(cookie)", forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw DeviceAuthError.server(error?["error"] as? String ?? "connection_failed")
        }
        return data
    }

    private func key(context: LAContext, create: Bool) throws -> SecKey {
        var parameters: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: keyTag, kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecReturnRef as String: true, kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(parameters as CFDictionary, &result)
        if status == errSecSuccess { return result as! SecKey }
        guard status == errSecItemNotFound && create else { throw DeviceAuthError.keychain(status) }
        var privateAttributes: [String: Any] = [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: keyTag]
        parameters = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256]
        if !simulatorTest {
            var authError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else { throw DeviceAuthError.unavailable }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error) else { throw error!.takeRetainedValue() as Error }
            privateAttributes[kSecAttrAccessControl as String] = access
            parameters[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        } else {
            // Only loopback UI tests in DEBUG simulator builds can use a software key.
            privateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        parameters[kSecPrivateKeyAttrs as String] = privateAttributes
        parameters[kSecUseAuthenticationContext as String] = context
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(parameters as CFDictionary, &error) else { throw error!.takeRetainedValue() as Error }
        return key
    }

    private func sign(_ message: String, key: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(message.utf8) as CFData, &error) else { throw error!.takeRetainedValue() as Error }
        return (signature as Data).base64EncodedString()
    }

    func pair(code: String) async throws -> DeviceSession {
        let normalized = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        let proof = try await Task.detached { [self] () throws -> (String, String) in
            let context = LAContext()
            context.localizedReason = "将这台设备与 Lin & Che 配对"
            context.localizedFallbackTitle = ""
            let key = try self.key(context: context, create: true)
            guard let publicKey = SecKeyCopyPublicKey(key) else { throw DeviceAuthError.unavailable }
            var error: Unmanaged<CFError>?
            guard let raw = SecKeyCopyExternalRepresentation(publicKey, &error) else { throw error!.takeRetainedValue() as Error }
            let encoded = (raw as Data).base64EncodedString()
            let message = "LinChe pair v1\n\(origin.absoluteString)\n\(normalized)\n\(encoded)"
            return (encoded, try sign(message, key: key))
        }.value
        let data = try await request("pair", body: ["code": normalized, "publicKey": proof.0, "signature": proof.1])
        let value = try JSONDecoder().decode(DeviceSession.self, from: data)
        try persist(value)
        return value
    }

    func renew() async throws -> DeviceSession {
        guard let id = try deviceId() else { throw DeviceAuthError.server("device_not_authorized") }
        let data = try await request("challenge", body: ["deviceId": id])
        struct Challenge: Decodable { let challengeId: String; let message: String; let expiresAt: Double }
        let challenge = try JSONDecoder().decode(Challenge.self, from: data)
        let expected = "LinChe renew v1\n\(origin.absoluteString)\n\(id)\n\(challenge.challengeId)\n\(Int64(challenge.expiresAt))"
        guard challenge.message == expected else { throw DeviceAuthError.server("invalid_challenge") }
        let signature = try await Task.detached { [self] in
            let context = LAContext()
            context.localizedReason = "验证身份并继续使用 Lin & Che 30 天"
            context.localizedFallbackTitle = ""
            return try sign(challenge.message, key: key(context: context, create: false))
        }.value
        let result = try await request("renew", body: ["deviceId": id, "challengeId": challenge.challengeId, "signature": signature])
        let value = try JSONDecoder().decode(DeviceSession.self, from: result)
        try persist(value)
        return value
    }
}

private final class NoAuthRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
