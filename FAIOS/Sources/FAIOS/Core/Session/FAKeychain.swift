import Foundation
import Security

/// 极薄的 Keychain 封装：只存 FA 的 cookie 快照。
///
/// 为什么非要 Keychain 而不是 UserDefaults：
/// `a` / `b` 两个 cookie 等价于账号密码（拿到就能以你的身份发帖、发私信），
/// UserDefaults 是明文 plist，越狱机上随便一个 App 就能读。
///
/// ⚠️ 但 Keychain 需要 App 带 `application-identifier` entitlement。
/// 本地 ad-hoc 签名（`ldid -S`）默认**不带任何 entitlements**，这时
/// `SecItemAdd` 会返回 `errSecMissingEntitlement (-34018)` —— 写入静默失败。
/// 所以这里所有 API 都返回 `OSStatus`，由调用方决定降级（见 `FACookieStore`）。
///
/// 用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：
/// * `…ThisDeviceOnly`：不进 iCloud 备份、不随恢复迁移到别的设备
/// * `AfterFirstUnlock`：后台刷新也能读到（`WhenUnlocked` 在锁屏后会失败）
enum FAKeychain {

    private static let service = "app.faios.client"

    static func set(_ data: Data, account: String) -> OSStatus {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)

        var query = base
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func data(account: String) -> (status: OSStatus, data: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 给界面看的：为什么 keychain 不可用
    static func describe(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess: return "ok"
        case errSecMissingEntitlement: return "keychain 无权限（二进制缺少 application-identifier entitlement）"
        case errSecItemNotFound: return "未找到"
        case errSecDuplicateItem: return "已存在"
        default: return "OSStatus \(status)"
        }
    }
}
