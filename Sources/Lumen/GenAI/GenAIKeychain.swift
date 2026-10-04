import Foundation
import Security
import ImageCratCore

/// API keys live only in the macOS Keychain (generic passwords), never in UserDefaults or logs.
/// service = "app.imagecrat.editor.apikeys" (`Brand.keychainService`), account = provider id, accessible when unlocked, this device only.
struct GenAIKeychain {
    static let defaultService = Brand.keychainService
    static let shared = GenAIKeychain(service: defaultService)

    let service: String

    /// Cache of which providers have a key (avoids hitting the keychain from SwiftUI bodies).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var presence: [String: Bool] = [:]
    /// Secrets already read this session. Reading a login-keychain item written by an earlier (differently ad-hoc-signed)
    /// build makes securityd show an access prompt and blocks the reading thread until someone answers it, so secrets are
    /// only ever read on `secretQueue` (`loadKey`) and kept: at most one prompt per key, and the main thread never waits on it.
    nonisolated(unsafe) private static var secrets: [String: String] = [:]
    nonisolated(unsafe) private static var pendingPresence: Set<String> = []
    private static let queue = DispatchQueue(label: "app.lumen.keychain", qos: .userInitiated)
    /// Secret reads get their own queue: one waiting on an access prompt must not hold up the presence lookups.
    private static let secretQueue = DispatchQueue(label: "app.lumen.keychain.secrets", qos: .userInitiated)
    /// Self-test hook: stands in for the Keychain of the default service (presence and secret reads, which may sleep to
    /// simulate an unanswered access prompt) so the non-blocking paths can be tested without touching real items.
    nonisolated(unsafe) static var testReader: ((String) -> String?)?
    /// Accounts the UI asks about (every provider plus the fal admin key).
    static var accounts: [String] { ProviderID.allCases.map(\.rawValue) + [falAdminAccount] }
    /// Real keychain reads are off: automated runs, unless a self test installed `testReader`.
    static var readsBlocked: Bool { GenAIKeyOverrides.realKeysBlocked && testReader == nil }

    /// The data-protection keychain (honours kSecAttrAccessibleWhenUnlockedThisDeviceOnly) needs a signed app with a
    /// keychain-access-groups entitlement; unsigned/dev builds fall back to the login keychain (errSecMissingEntitlement).
    static let dataProtectionAvailable: Bool = {
        // Lookups don't report the missing entitlement; a throwaway add does.
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Brand.bundleIdentifier + ".probe",
                                kSecAttrAccount as String: "probe-\(UUID().uuidString)", kSecUseDataProtectionKeychain as String: true]
        var add = q
        add[kSecValueData as String] = Data()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let st = SecItemAdd(add as CFDictionary, nil)
        if st == errSecSuccess { SecItemDelete(q as CFDictionary) }
        return st == errSecSuccess
    }()

    private func baseQuery(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if GenAIKeychain.dataProtectionAvailable { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Stores (or replaces) a key. Empty string deletes it. Returns the OSStatus for diagnostics.
    @discardableResult
    func set(_ key: String, for account: String) -> OSStatus {
        // Automated runs never overwrite the user's real keys either (a UI fuzz could type into Preferences).
        if GenAIKeyOverrides.realKeysBlocked, service == GenAIKeychain.defaultService { return errSecNotAvailable }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete(account) }
        let data = Data(trimmed.utf8)
        var status = SecItemUpdate(baseQuery(account) as CFDictionary,
                                   [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel as String] = "\(Brand.name) API key (\(account))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecSuccess { cache(account, true); storeSecret(account, trimmed) }
        return status
    }

    /// True in automated runs (self tests, fuzzing, scripts): the real keychain service is neither read nor written.
    static var automatedRun: Bool { GenAIKeyOverrides.realKeysBlocked }

    func get(_ account: String) -> String? {
        // Automated runs never read the user's real keys (see GenAIKeyOverrides.realKeysBlocked).
        if GenAIKeyOverrides.realKeysBlocked, service == GenAIKeychain.defaultService { return nil }
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else {
            cache(account, false)
            return nil
        }
        cache(account, true)
        return s
    }

    /// Reads the accessibility class stored on an item (for tests).
    func accessibility(_ account: String) -> String? {
        var q = baseQuery(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let attrs = out as? [String: Any] else { return nil }
        return attrs[kSecAttrAccessible as String] as? String
    }

    @discardableResult
    func delete(_ account: String) -> OSStatus {
        if GenAIKeyOverrides.realKeysBlocked, service == GenAIKeychain.defaultService { return errSecNotAvailable }
        let s = SecItemDelete(baseQuery(account) as CFDictionary)
        cache(account, false)
        storeSecret(account, nil)
        return s
    }

    /// Whether an item exists. Off the main thread this asks the Keychain (attributes only); on the main thread (view
    /// bodies, menu validation) it never waits: an unknown answer is looked up in the background and reads as "no key"
    /// until it arrives, when `keysRevision` is bumped so pickers refresh (see `presenceKnown`).
    func has(_ account: String) -> Bool {
        if let c = cached(account) { return c }
        if Thread.isMainThread { lookUpInBackground(service == GenAIKeychain.defaultService ? [account] + GenAIKeychain.accounts : [account]); return false }
        return lookUpPresence(account)
    }

    private func cached(_ account: String) -> Bool? {
        GenAIKeychain.lock.lock(); defer { GenAIKeychain.lock.unlock() }
        return GenAIKeychain.presence[service + "/" + account]
    }

    private func lookUpPresence(_ account: String) -> Bool {
        let found: Bool
        if service == GenAIKeychain.defaultService, let r = GenAIKeychain.testReader {
            found = r(account) != nil
        } else {
            // Attributes-only lookup: answers "is there an item?" without reading the secret (no access prompt).
            var q = baseQuery(account)
            q[kSecReturnAttributes as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            found = SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
        }
        cache(account, found)
        return found
    }

    private func lookUpInBackground(_ accounts: [String]) {
        GenAIKeychain.lock.lock()
        let todo = Array(Set(accounts)).filter { GenAIKeychain.presence[service + "/" + $0] == nil && GenAIKeychain.pendingPresence.insert(service + "/" + $0).inserted }
        GenAIKeychain.lock.unlock()
        guard !todo.isEmpty else { return }
        GenAIKeychain.queue.async {
            for a in todo { _ = self.lookUpPresence(a) }
            GenAIKeychain.lock.lock(); for a in todo { GenAIKeychain.pendingPresence.remove(self.service + "/" + a) }; GenAIKeychain.lock.unlock()
            DispatchQueue.main.async { GenAISettings.shared.keysRevision += 1 }
        }
    }

    /// Launch: learn which keys exist (and probe the data-protection keychain) in the background, so opening a
    /// generative dialog never waits for securityd. Secrets themselves are read only when a job needs one.
    static func warmUp() {
        guard !readsBlocked else { return }
        queue.async { _ = dataProtectionAvailable }
        shared.lookUpInBackground(accounts)
    }

    /// False while the background presence lookup for the UI's accounts has not answered yet.
    var presenceKnown: Bool {
        if GenAIKeychain.readsBlocked { return true }
        GenAIKeychain.lock.lock(); defer { GenAIKeychain.lock.unlock() }
        return GenAIKeychain.accounts.allSatisfy { GenAIKeychain.presence[service + "/" + $0] != nil }
    }

    /// Waits (without blocking the caller's thread) until the presence lookups have answered.
    func waitForPresence() async {
        guard !presenceKnown else { return }
        lookUpInBackground(GenAIKeychain.accounts)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in GenAIKeychain.queue.async { c.resume() } }
    }

    private func cache(_ account: String, _ v: Bool) {
        GenAIKeychain.lock.lock()
        GenAIKeychain.presence[service + "/" + account] = v
        GenAIKeychain.lock.unlock()
    }

    private func storeSecret(_ account: String, _ v: String?) {
        GenAIKeychain.lock.lock()
        GenAIKeychain.secrets[service + "/" + account] = v
        GenAIKeychain.lock.unlock()
    }

    private func cachedSecret(_ account: String) -> String? {
        GenAIKeychain.lock.lock(); defer { GenAIKeychain.lock.unlock() }
        return GenAIKeychain.secrets[service + "/" + account]
    }

    /// Reads a secret on the (serial) secret queue, so concurrent jobs share one prompt, and keeps it for the session.
    /// Nil when there is no item or access was denied.
    func loadSecret(_ account: String) async -> String? {
        if let s = cachedSecret(account) { return s }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            GenAIKeychain.secretQueue.async {
                if let s = self.cachedSecret(account) { c.resume(returning: s); return }
                let s: String?
                if self.service == GenAIKeychain.defaultService, let r = GenAIKeychain.testReader { s = r(account) } else { s = self.get(account) }
                if let s, !s.isEmpty { self.cache(account, true); self.storeSecret(account, s) }
                c.resume(returning: s?.isEmpty == false ? s : nil)
            }
        }
    }

    /// Test / automation cleanup: forget every cached presence answer and secret.
    static func resetCaches() {
        lock.lock(); presence = [:]; secrets = [:]; pendingPresence = []; lock.unlock()
    }

    // Provider convenience
    /// The key if it is already known (override or read earlier this session). Never touches the Keychain, so it is safe
    /// anywhere; jobs that need the key use `loadKey`.
    func key(_ p: ProviderID) -> String? {
        // Debug/mock only: lets the self test inject a fake key without touching the real keychain.
        if let k = GenAIKeyOverrides.value(p) { return k }
        if GenAIKeychain.readsBlocked { return nil }
        return cachedSecret(p.rawValue)
    }
    /// The key for a job, read off the main thread (it may wait for a Keychain access prompt).
    func loadKey(_ p: ProviderID) async -> String? {
        if let k = GenAIKeyOverrides.value(p) { return k }
        if GenAIKeychain.readsBlocked { return nil }
        return await loadSecret(p.rawValue)
    }
    func hasKey(_ p: ProviderID) -> Bool {
        if GenAIKeyOverrides.value(p) != nil { return true }
        return GenAIKeychain.readsBlocked ? false : has(p.rawValue)
    }

    /// Optional second fal.ai key with Admin scope, used only for the Platform APIs (billing / usage).
    static let falAdminAccount = "fal-admin"
    func loadFalAdminKey() async -> String? {
        if GenAIKeyOverrides.active || GenAIKeyOverrides.realKeysBlocked { return GenAIKeyOverrides.falAdmin }
        return await loadSecret(GenAIKeychain.falAdminAccount)
    }
    var hasFalAdminKey: Bool { (GenAIKeyOverrides.active || GenAIKeyOverrides.realKeysBlocked) ? GenAIKeyOverrides.falAdmin != nil : has(GenAIKeychain.falAdminAccount) }
    /// Every provider that has a stored key.
    var keyedProviders: [ProviderID] { ProviderID.allCases.filter { hasKey($0) } }
}

/// In-memory key overrides used only by the self test (mock server). Never persisted.
enum GenAIKeyOverrides {
    nonisolated(unsafe) static var keys: [ProviderID: String] = [:]
    /// fal.ai admin key for the mock Platform API (nil = "no admin key stored").
    nonisolated(unsafe) static var falAdmin: String?
    /// True while the self test runs against the mock: the real keychain's admin key is never read then.
    nonisolated(unsafe) static var active = false
    static func value(_ p: ProviderID) -> String? { keys[p] }

    /// SAFETY: automated runs (self tests, perf tests, menu fuzzing, headless command-line modes) must never spend the
    /// user's money or upload anything: the real Keychain keys are invisible to them. Only keys injected through
    /// `keys` (the mock server tests) are usable.
    static let realKeysBlocked: Bool = {
        let args = CommandLine.arguments
        if ProcessInfo.processInfo.environment["LUMEN_AUTOMATION"] != nil { return true }
        return args.contains { $0 == "--selftest" || $0 == "--perftest" || $0.hasPrefix("--menu-fuzz") || $0 == "--run-action" || $0 == "--run-script"
            || $0 == "--inpaint-test" }
    }()
}
