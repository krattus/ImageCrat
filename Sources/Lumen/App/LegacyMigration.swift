import AppKit
import Security
import ImageCratCore

/// First launch after the rename (Lumen → ImageCrat): carries the user's data over, once.
///
/// 1. Support folder: `Application Support/Lumen` becomes `Application Support/ImageCrat` with one rename (same volume,
///    so gigabytes of models move instantly). When both exist, the old folder is merged in item by item: anything
///    missing is moved; for a file in both places the newer copy wins and the older one is kept in
///    `ImageCrat/Older copies from Lumen/` (nothing is overwritten or deleted). Small text files (recovery manifests,
///    JSON settings) that name the old folder are pointed at the new one, and the log continues as ImageCrat.log.
/// 2. Preferences: every key of the old defaults domain `app.lumen.editor` that the new domain doesn't have is copied
///    (old folder paths inside values are rewritten). The old domain is left alone.
/// 3. Keychain: API keys in the old service `app.lumen.editor.apikeys` are copied to `app.imagecrat.editor.apikeys`
///    off the main thread (the read may show a one-time macOS access prompt, as the item belongs to another app).
///
/// Each step sets its own flag only when it finished, so an interrupted launch simply resumes; every step is a no-op
/// when there is nothing to do. Automated runs (self tests, fuzzing, scripts, droplets, `LUMEN_SUPPORT_DIR`) never run
/// it: the `rename` self test calls the steps directly with temporary folders, a temporary defaults suite and test
/// Keychain services.
enum LegacyMigration {
    enum Flag {
        static let supportFolder = "ImageCrat.Migration.supportFolder"
        static let preferences = "ImageCrat.Migration.preferences"
        static let keychain = "ImageCrat.Migration.keychain"
        static let announced = "ImageCrat.Migration.announced"
        static let carriedOver = "ImageCrat.Migration.carriedOver"
        static let all = [supportFolder, preferences, keychain, announced, carriedOver]
    }

    static let doneMessage = "Lumen is now ImageCrat — your settings and models were carried over."
    static let deferredMessage = "Lumen is still running: quit it and reopen ImageCrat to carry over its settings and models."
    static func keyNotCarriedMessage(_ provider: String) -> String {
        "The \(provider) API key from Lumen could not be carried over (macOS denied access). Please enter it again in Preferences ▸ Generative AI."
    }
    /// Folder (inside the new support folder) that keeps the older copy of a file both folders had.
    static let conflictsFolderName = "Older copies from Lumen"

    /// Lines for the diagnostic log (written once DiagLog can be created: after the support folder has moved).
    nonisolated(unsafe) private static var notes: [String] = []
    private static func note(_ s: String) { notes.append(s) }

    // MARK: Launch

    /// False for every automated or redirected run: they must never touch the user's real folders, preferences or keys.
    static var allowedInThisProcess: Bool {
        if GenAIKeyOverrides.realKeysBlocked || Automation.isProcessWide { return false }
        if let o = ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"], !o.isEmpty { return false }
        return true
    }
    /// Preferences and Keychain items belong to the app's bundle identifier: only the ImageCrat app bundle copies them
    /// (a `swift build` binary has a defaults domain of its own and would only trigger Keychain prompts).
    static var isAppBundle: Bool { Bundle.main.bundleIdentifier == Brand.bundleIdentifier }

    static var legacyAppRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Brand.Legacy.bundleIdentifier).isEmpty }

    /// Called first thing at launch (`LumenApp.init`), before any module reads the support folder or preferences.
    static func runAtLaunch() {
        guard allowedInThisProcess else { return }
        let defaults = UserDefaults.standard
        let pending = !defaults.bool(forKey: Flag.supportFolder) || (isAppBundle && !defaults.bool(forKey: Flag.preferences))
        guard pending else { return }
        if legacyAppRunning {
            // moving the folder under a running Lumen would split its files between the two; try again next launch
            note("Migration from Lumen postponed: Lumen is running.")
            deferredAtLaunch = true
            flushNotes()
            return
        }
        let old = Brand.applicationSupport.appendingPathComponent(Brand.Legacy.supportFolderName, isDirectory: true)
        if !defaults.bool(forKey: Flag.supportFolder) {
            let r = migrateSupportFolder(from: old, to: Brand.supportFolder)
            if r.complete { defaults.set(true, forKey: Flag.supportFolder) }
            if r.outcome == .moved || r.outcome == .merged { defaults.set(true, forKey: Flag.carriedOver) }
        }
        if isAppBundle && !defaults.bool(forKey: Flag.preferences) {
            let n = migratePreferences(fromDomain: Brand.Legacy.bundleIdentifier, into: defaults, domain: Brand.bundleIdentifier,
                                       oldFolder: old, newFolder: Brand.supportFolder)
            defaults.set(true, forKey: Flag.preferences)
            if n > 0 { defaults.set(true, forKey: Flag.carriedOver) }
        }
        flushNotes()
    }
    nonisolated(unsafe) private(set) static var deferredAtLaunch = false

    /// After the window is up: copies Keychain items in the background and shows the one-time status message.
    static func afterLaunch() {
        guard allowedInThisProcess else { return }
        let defaults = UserDefaults.standard
        if deferredAtLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppModel.shared.setStatus(deferredMessage) }
            return
        }
        if isAppBundle && !defaults.bool(forKey: Flag.keychain) {
            let old = LegacyKeychain(service: Brand.Legacy.keychainService)
            DispatchQueue.global(qos: .utility).async {
                let r = migrateKeychain(accounts: GenAIKeychain.accounts, from: old, to: GenAIKeychain.shared)
                DispatchQueue.main.async {
                    if r.finished { defaults.set(true, forKey: Flag.keychain) }
                    if !r.copied.isEmpty { defaults.set(true, forKey: Flag.carriedOver); GenAISettings.shared.keysRevision += 1 }
                    if let first = r.failed.first {
                        AppModel.shared.setStatus(keyNotCarriedMessage(ProviderID(rawValue: first)?.displayName ?? first))
                    }
                    flushNotes()
                }
            }
        }
        if defaults.bool(forKey: Flag.carriedOver) && !defaults.bool(forKey: Flag.announced) {
            defaults.set(true, forKey: Flag.announced)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppModel.shared.setStatus(doneMessage) }
        }
    }

    private static func flushNotes() {
        let list = notes
        notes = []
        for n in list { DiagLog.shared.info(n) }
    }

    // MARK: 1. Support folder

    enum FolderOutcome: Equatable { case nothingToDo, moved, merged, failed }
    struct FolderResult {
        var outcome: FolderOutcome = .nothingToDo
        /// Items moved from the old folder into the new one (1 for a whole-folder move).
        var moved = 0
        /// Files both folders had (the older copy is in `conflictsFolderName`).
        var conflicts = 0
        /// Items that stayed in the old folder (another volume, or a move that failed).
        var leftBehind = 0
        /// Small files whose old-folder paths were rewritten.
        var rewritten = 0
        /// Finished (also when there was nothing to do); false when interrupted or failed, so the next launch retries.
        var complete = false
    }

    /// Self-test hook: stop after this many item moves, as if the app had quit mid-merge.
    nonisolated(unsafe) static var testInterruptAfter: Int?

    @discardableResult
    static func migrateSupportFolder(from old: URL, to new: URL) -> FolderResult {
        let fm = FileManager.default
        var r = FolderResult()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { r.complete = true; return r }
        var newIsDir: ObjCBool = false
        var newExists = fm.fileExists(atPath: new.path, isDirectory: &newIsDir)
        // an ImageCrat folder holding nothing but empty folders (e.g. Models/, created by a development build or an early
        // look at Preferences) doesn't count: it is removed so the whole Lumen folder can still move with one rename
        if newExists && newIsDir.boolValue && !containsFiles(new) {
            removeEmptyFolders(new)
            newExists = fm.fileExists(atPath: new.path, isDirectory: &newIsDir)
        }
        if newExists && !newIsDir.boolValue {
            note("Migration from Lumen: “\(new.lastPathComponent)” in Application Support is a file, not a folder; nothing was moved.")
            r.outcome = .failed
            return r
        }
        if !newExists {
            // one rename: instant on the same volume, models included
            do {
                try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: old, to: new)
                r.outcome = .moved; r.moved = 1
                note("Moved the Lumen support folder to Application Support/\(new.lastPathComponent).")
            } catch {
                note("Could not move the Lumen support folder (\(error.localizedDescription)); merging it item by item instead.")
            }
        }
        if r.outcome != .moved {
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)
            var budget = testInterruptAfter
            let ok = merge(old, into: new, root: new, relative: "", result: &r, budget: &budget)
            r.outcome = .merged
            if !ok { return r }    // interrupted: the flag stays off and the next launch continues
            removeEmptyFolders(old)
            let still = fm.fileExists(atPath: old.path)
            note("Merged the Lumen support folder into the existing ImageCrat folder: \(r.moved) item\(r.moved == 1 ? "" : "s") moved, "
                 + "\(r.conflicts) file\(r.conflicts == 1 ? "" : "s") in both (older copies kept in “\(conflictsFolderName)”)"
                 + (r.leftBehind > 0 ? ", \(r.leftBehind) left in the old folder" : "") + (still ? "." : "; the old folder was removed."))
        }
        r.rewritten = rewriteFolderReferences(in: new, old: old, new: new)
        continueLog(in: new)
        r.complete = true
        return r
    }

    /// Moves everything in `src` into `dst` (recursing into folders both have). Returns false when interrupted.
    private static func merge(_ src: URL, into dst: URL, root: URL, relative: String, result r: inout FolderResult, budget: inout Int?) -> Bool {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .volumeIdentifierKey]
        let items = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: keys, options: [])) ?? []
        let dstVolume = (try? dst.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? NSObject
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent
            let rel = relative.isEmpty ? name : relative + "/" + name
            if name == conflictsFolderName && relative.isEmpty { continue }
            if name == ".DS_Store" { try? fm.removeItem(at: item); continue }    // Finder's view settings
            if let b = budget { if b <= 0 { return false }; budget = b - 1 }
            let v = try? item.resourceValues(forKeys: Set(keys))
            let target = dst.appendingPathComponent(name)
            let isLink = v?.isSymbolicLink == true
            let isDir = !isLink && v?.isDirectory == true
            let targetExists = fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil
            if !targetExists {
                // a move to another volume would be a slow copy at launch: leave it where it is
                if let sv = v?.volumeIdentifier as? NSObject, let dv = dstVolume, !sv.isEqual(dv) {
                    r.leftBehind += 1
                    note("Migration from Lumen: “\(rel)” is on another volume and was left in the old folder.")
                    continue
                }
                do { try fm.moveItem(at: item, to: target); r.moved += 1 } catch {
                    r.leftBehind += 1
                    note("Migration from Lumen: could not move “\(rel)” (\(error.localizedDescription)).")
                }
                continue
            }
            var targetIsDir: ObjCBool = false
            _ = fm.fileExists(atPath: target.path, isDirectory: &targetIsDir)
            if isDir && targetIsDir.boolValue {
                if !merge(item, into: target, root: root, relative: rel, result: &r, budget: &budget) { return false }
                continue
            }
            // in both places: the newer copy stays / becomes the ImageCrat one, the older one is kept aside
            let oldDate = v?.contentModificationDate ?? .distantPast
            let newDate = (try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let aside = uniqueURL(root.appendingPathComponent(conflictsFolderName).appendingPathComponent(rel))
            try? fm.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                if oldDate > newDate {
                    try fm.moveItem(at: target, to: aside)      // (interrupted here: the next run finds the target missing and moves it)
                    try fm.moveItem(at: item, to: target)
                    note("Migration from Lumen: “\(rel)” existed in both folders; Lumen's copy was newer and is used, ImageCrat's is in “\(conflictsFolderName)”.")
                } else {
                    try fm.moveItem(at: item, to: aside)
                    note("Migration from Lumen: “\(rel)” existed in both folders; ImageCrat's copy is newer and kept, Lumen's is in “\(conflictsFolderName)”.")
                }
                r.conflicts += 1
            } catch {
                r.leftBehind += 1
                note("Migration from Lumen: could not merge “\(rel)” (\(error.localizedDescription)).")
            }
        }
        return true
    }

    private static func uniqueURL(_ u: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: u.path) else { return u }
        let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
        for i in 2... {
            let c = u.deletingLastPathComponent().appendingPathComponent("\(base) \(i)" + (ext.isEmpty ? "" : "." + ext))
            if !fm.fileExists(atPath: c.path) { return c }
        }
        return u
    }

    /// True when anything other than folders (and Finder's .DS_Store) is inside `dir`.
    private static func containsFiles(_ dir: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return true }
        for case let u as URL in e where u.lastPathComponent != ".DS_Store" {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v?.isDirectory != true || v?.isSymbolicLink == true { return true }
        }
        return false
    }

    /// Removes `dir` and its subfolders when they hold nothing but other empty folders.
    @discardableResult
    private static func removeEmptyFolders(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []
        var empty = true
        for i in items {
            let v = try? i.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if i.lastPathComponent == ".DS_Store" { try? fm.removeItem(at: i); continue }
            if v?.isDirectory == true && v?.isSymbolicLink != true { if !removeEmptyFolders(i) { empty = false } } else { empty = false }
        }
        if empty { try? fm.removeItem(at: dir) }
        return empty
    }

    /// Small JSON / plist files that name the old folder by its full path (recovery manifests' original paths, saved
    /// settings) now name the new one. Models and other large files are not read.
    static func rewriteFolderReferences(in folder: URL, old: URL, new: URL) -> Int {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var n = 0
        for case let u as URL in e {
            if u.lastPathComponent == "Models" || u.lastPathComponent == conflictsFolderName { e.skipDescendants(); continue }
            guard ["json", "plist", "txt"].contains(u.pathExtension.lowercased()),
                  let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true, (v.fileSize ?? 0) < 4_000_000,
                  let data = try? Data(contentsOf: u), let changed = rewritten(data, old: old, new: new) else { continue }
            if (try? changed.write(to: u, options: .atomic)) != nil { n += 1 }
        }
        if n > 0 { note("Migration from Lumen: updated old folder paths in \(n) file\(n == 1 ? "" : "s").") }
        return n
    }

    /// Old-folder paths (plain, and with JSON's escaped slashes) replaced in JSON / plain text or a property list; nil if
    /// unchanged or not one of those (bookmarks and other binary data are never edited as text).
    static func rewritten(_ data: Data, old: URL, new: URL) -> Data? {
        let head = data.prefix(64)
        let isPlist = head.starts(with: Data("bplist".utf8)) || String(decoding: head, as: UTF8.self).contains("<!DOCTYPE plist")
        if !isPlist {
            guard let s = String(data: data, encoding: .utf8), let first = s.first(where: { !$0.isWhitespace }), "{[\"".contains(first) || looksLikeText(s) else { return nil }
            let t = rewritePaths(s, old: old, new: new)
            return t == s ? nil : Data(t.utf8)
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let p = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &format) else { return nil }
        let q = rewriteValue(p, old: old, new: new)
        guard !(q as AnyObject).isEqual(p as AnyObject) else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: q, format: format, options: 0)
    }

    /// Plain text without control characters (a .txt file, not binary data that happens to decode as UTF-8).
    private static func looksLikeText(_ s: String) -> Bool { !s.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" } }

    static func rewritePaths(_ s: String, old: URL, new: URL) -> String {
        let o = old.standardizedFileURL.path, n = new.standardizedFileURL.path
        guard s.contains(o) || s.contains(escapedSlashes(o)) else { return s }
        var t = s
        for (a, b) in [(o + "/", n + "/"), (escapedSlashes(o + "/"), escapedSlashes(n + "/"))] { t = t.replacingOccurrences(of: a, with: b) }
        // the folder itself (end of a string)
        for (a, b) in [(o + "\"", n + "\""), (escapedSlashes(o) + "\"", escapedSlashes(n) + "\"")] { t = t.replacingOccurrences(of: a, with: b) }
        if t == o { t = n }
        return t
    }
    private static func escapedSlashes(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "\\/") }

    static func rewriteValue(_ v: Any, old: URL, new: URL) -> Any {
        switch v {
        case let s as String: return rewritePaths(s, old: old, new: new)
        case let a as [Any]: return a.map { rewriteValue($0, old: old, new: new) }
        case let d as [String: Any]: return d.mapValues { rewriteValue($0, old: old, new: new) }
        case let data as Data: return rewritten(data, old: old, new: new) ?? data
        default: return v
        }
    }

    /// The log continues under the new name: Lumen.log becomes ImageCrat.log (which DiagLog then rotates into
    /// ImageCrat.previous.log, so a bug report still shows what happened before the update).
    private static func continueLog(in folder: URL) {
        let logs = folder.appendingPathComponent("Logs")
        let old = logs.appendingPathComponent(Brand.Legacy.name + ".log"), cur = logs.appendingPathComponent(Brand.name + ".log")
        let fm = FileManager.default
        if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: cur.path) { try? fm.moveItem(at: old, to: cur) }
    }

    // MARK: 2. Preferences

    /// Copies the keys of `oldDomain` that `defaults` (whose own domain is `domain`) doesn't have yet; returns how many.
    @discardableResult
    static func migratePreferences(fromDomain oldDomain: String, into defaults: UserDefaults, domain: String, oldFolder: URL, newFolder: URL) -> Int {
        guard let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return 0 }
        let mine = defaults.persistentDomain(forName: domain) ?? [:]
        var copied = 0, skipped = 0
        for (k, v) in old where mine[k] == nil && !Flag.all.contains(k) {
            defaults.set(rewriteValue(v, old: oldFolder, new: newFolder), forKey: k)
            copied += 1
        }
        skipped = old.count - copied
        note("Copied \(copied) preference\(copied == 1 ? "" : "s") from Lumen" + (skipped > 0 ? " (\(skipped) already set in ImageCrat were kept)." : ".")
             + " Lumen's own preferences were left in place.")
        return copied
    }

    // MARK: 3. Keychain

    /// The old app's items: read with the file-based (login) keychain, where an unentitled build stored them, and the
    /// data-protection keychain when this build can use it.
    struct LegacyKeychain {
        var service: String
        /// Test hook: stands in for the secret read (nil = denied / unreadable).
        var reader: ((String) -> String?)? = nil
        /// Automated runs never look at the real old service (self tests use their own service names).
        private var blocked: Bool { GenAIKeyOverrides.realKeysBlocked && service == Brand.Legacy.keychainService }

        private func query(_ account: String, dataProtection: Bool) -> [String: Any] {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
            if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
            return q
        }
        private var variants: [Bool] { GenAIKeychain.dataProtectionAvailable ? [false, true] : [false] }

        /// Attributes only: answers without reading the secret (no access prompt).
        func exists(_ account: String) -> Bool {
            if blocked { return false }
            return variants.contains { dp in
                var q = query(account, dataProtection: dp)
                q[kSecReturnAttributes as String] = true
                q[kSecMatchLimit as String] = kSecMatchLimitOne
                var out: AnyObject?
                return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
            }
        }
        /// The secret (may wait for the macOS access prompt). Nil when denied or unreadable.
        func read(_ account: String) -> String? {
            if blocked { return nil }
            if let reader { return reader(account) }
            for dp in variants {
                var q = query(account, dataProtection: dp)
                q[kSecReturnData as String] = true
                q[kSecMatchLimit as String] = kSecMatchLimitOne
                var out: AnyObject?
                if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
                   let s = String(data: d, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            }
            return nil
        }
    }

    struct KeychainResult {
        var copied: [String] = []
        /// Already had a key in the new service (left untouched).
        var kept: [String] = []
        /// Present in the old service but unreadable (access denied) or not writable.
        var failed: [String] = []
        var blocked = false
        var finished = false
    }

    /// Copies each account that has an item in `old` and none in `new`. Blocking (call it off the main thread).
    /// Never logs key values. Refuses the real services in automated runs.
    static func migrateKeychain(accounts: [String], from old: LegacyKeychain, to new: GenAIKeychain) -> KeychainResult {
        var r = KeychainResult()
        if GenAIKeyOverrides.realKeysBlocked && (old.service == Brand.Legacy.keychainService || new.service == GenAIKeychain.defaultService) {
            r.blocked = true
            return r
        }
        for a in accounts {
            guard old.exists(a) else { continue }
            if new.itemExists(a) { r.kept.append(a); continue }     // already set up in ImageCrat: never overwritten
            guard let key = old.read(a) else {
                r.failed.append(a)
                note("Keychain: could not read the \(ProviderID(rawValue: a)?.displayName ?? a) API key stored by Lumen (access denied or "
                     + "unreadable); it was left as it is. Re-enter it in Preferences ▸ Generative AI.")
                continue
            }
            if new.set(key, for: a) == errSecSuccess {
                r.copied.append(a)
                note("Keychain: carried over the \(ProviderID(rawValue: a)?.displayName ?? a) API key from Lumen.")
            } else {
                r.failed.append(a)
                note("Keychain: could not store the \(ProviderID(rawValue: a)?.displayName ?? a) API key under ImageCrat. "
                     + "Re-enter it in Preferences ▸ Generative AI.")
            }
        }
        r.finished = true
        return r
    }

    /// Self test: the notes collected so far (and clears them).
    static func takeNotes() -> [String] { defer { notes = [] }; return notes }
}

extension GenAIKeychain {
    /// Attributes-only lookup (no access prompt, no cache): is there an item for `account` in this service?
    func itemExists(_ account: String) -> Bool {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if GenAIKeychain.dataProtectionAvailable { q[kSecUseDataProtectionKeychain as String] = true }
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }
}
