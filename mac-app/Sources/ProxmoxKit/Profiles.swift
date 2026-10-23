import Foundation
import Security

// MARK: - 서버 프로필 (여러 Proxmox 인스턴스 전환용)
/// host:port:user@realm 1쌍을 하나의 PVE 인스턴스로 지칭하며,
/// 목록은 UserDefaults에 JSON으로, 비밀번호는 Keychain에 개별 보관한다.
public struct PVEProfile: Codable, Identifiable, Hashable {
    public var id: String          // host:port:user@realm
    public var label: String
    public var host: String
    public var port: Int
    public var user: String
    public var realm: String
    public var savePassword: Bool

    public init(label: String, host: String, port: Int, user: String, realm: String, savePassword: Bool) {
        self.label = label
        self.host = host
        self.port = port
        self.user = user
        self.realm = realm
        self.savePassword = savePassword
        self.id = "\(host):\(port):\(user)@\(realm)"
    }
}

// MARK: - Keychain 비밀번호 보관 래퍼 (프로필별 GenericPassword)
public enum KeychainStore {
    static let service = "kr.park.bastion.passwords"
    /// 실행 세션 내 재읽기 방지 (키체인 권한 요청 반복 경감)
    private static var cache: [String: String] = [:]

    static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func setPassword(_ pw: String, account: String) {
        var add = baseQuery(account: account)
        add[kSecValueData as String] = Data(pw.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func password(account: String) -> String? {
        if let cached = cache[account] { return cached }
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let d = result as? Data else { return nil }
        let pw = String(data: d, encoding: .utf8)
        if let pw { cache[account] = pw }
        return pw
    }

    public static func deletePassword(account: String) {
        cache.removeValue(forKey: account)
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

// MARK: - 프로필 목록 보관 (UserDefaults JSON)
public enum ProfileStore {
    static let key = "pve.profiles.v1"

    public static func load() -> [PVEProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([PVEProfile].self, from: data) else { return [] }
        return list
    }

    public static func save(_ list: [PVEProfile]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 추가 또는 갱신(id 동일 기준) 후 전체 목록 반환
    @discardableResult
    public static func upsert(_ profile: PVEProfile) -> [PVEProfile] {
        var list = load()
        if let i = list.firstIndex(where: { $0.id == profile.id }) {
            list[i] = profile
        } else {
            list.append(profile)
        }
        save(list)
        return list
    }

    /// 삭제 후 전체 목록 반환
    @discardableResult
    public static func remove(id: String) -> [PVEProfile] {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
        return list
    }

    public static func find(id: String) -> PVEProfile? {
        load().first { $0.id == id }
    }
}
