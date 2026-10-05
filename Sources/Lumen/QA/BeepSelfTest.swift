import AppKit

/// Automated runs are silent (App/Beep.swift), and no raw `NSSound.beep()` / `NSBeep()` creeps back into the app.
///
///     LUMEN_SELFTEST_ONLY=beep .build/debug/Lumen --selftest <dir>
enum BeepSelfTest {
    static func register() { FeatureModules.selfTests.append(("beep", { _ in run() })) }

    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") beep: \(name)\(d.isEmpty ? "" : " — " + d)")
    }

    static func run() {
        failures = 0; passes = 0
        check(Beep.isSilenced, "self tests are silent")

        let before = Beep.suppressedCount
        Beep.play()
        check(Beep.suppressedCount == before + 1, "Beep.play() is suppressed (counted, not played)")

        // AppKit's own beep for a key nobody handles goes through -[NSResponder noResponderFor:]
        let r = NSResponder()
        let k = Beep.suppressedCount
        r.noResponder(for: #selector(NSResponder.keyDown(with:)))
        check(Beep.suppressedCount == k + 1, "AppKit's unhandled-key beep is silenced")

        // Source scan: only App/Beep.swift may call the system beep. Skipped when the sources are not next to the binary
        // (an installed app); scripts/check_no_raw_beep.sh does the same check at build time.
        let here = URL(fileURLWithPath: #filePath)   // …/Sources/Lumen/QA/BeepSelfTest.swift
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("App/Beep.swift").path) {
            var offenders: [String] = []
            // a call, not a mention: string literals and // comments are stripped first (same rule as the script)
            let call = try! NSRegularExpression(pattern: #"\bNSSound\s*\.\s*beep\s*\(|\bNSBeep\s*\("#)
            let strings = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)
            let comment = try! NSRegularExpression(pattern: #"//.*$"#)
            func strip(_ re: NSRegularExpression, _ s: String) -> String {
                re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
            if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.pathExtension == "swift" {
                    let rel = String(u.path.dropFirst(root.path.count + 1))
                    guard rel != "App/Beep.swift", let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                    for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                        let code = strip(comment, strip(strings, String(line)))
                        if call.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                            offenders.append("\(rel):\(i + 1)")
                        }
                    }
                }
            }
            check(offenders.isEmpty, "no raw NSSound.beep() / NSBeep() outside App/Beep.swift", offenders.prefix(10).joined(separator: ", "))
        } else {
            print("beep: sources not found next to the binary; source scan skipped")
        }
        print("beep: \(passes) passed, \(failures) failed")
    }
}
