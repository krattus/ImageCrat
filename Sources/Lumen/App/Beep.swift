import AppKit

/// The app's alert sound. Every beep goes through here (raw `NSSound.beep()` is rejected by `scripts/check_no_raw_beep.sh`
/// and the `beep` self-test) so automated runs stay silent: self tests, perf tests, menu fuzzing, droplet / script runs
/// (`--run-*`) and `LUMEN_AUTOMATION` hit failed-guard paths constantly and used to beep through the speakers all day.
enum Beep {
    /// True for every non-interactive run. The command line and environment are fixed for the process, so this is
    /// computed once.
    static let isSilenced: Bool = {
        let args = CommandLine.arguments
        if ProcessInfo.processInfo.environment["LUMEN_AUTOMATION"] != nil { return true }
        return args.contains { a in
            a == "--selftest" || a == "--perftest" || a.hasPrefix("--menu-fuzz") || a.hasPrefix("--run-") || a == "--inpaint-test"
        } || GenAIKeyOverrides.realKeysBlocked || FilesModule.headless || Automation.isProcessWide
    }()

    /// Beeps that were suppressed (self tests can check a guard path was taken without hearing it).
    nonisolated(unsafe) private(set) static var suppressedCount = 0

    /// AppKit beeps on its own when a key event reaches the end of the responder chain unhandled
    /// (`-[NSResponder noResponderFor:]`). Self tests send plenty of synthetic keys, so in automated runs that
    /// method is replaced with a silent one. Interactive runs keep AppKit's behaviour. Call once at launch.
    static func installHeadlessGuards() {
        guard isSilenced, !guardsInstalled else { return }
        guardsInstalled = true
        let sel = NSSelectorFromString("noResponderFor:")
        guard let m = class_getInstanceMethod(NSResponder.self, sel) else { return }
        let silent: @convention(block) (AnyObject, Selector) -> Void = { _, _ in suppressedCount += 1 }
        method_setImplementation(m, imp_implementationWithBlock(silent))
    }
    nonisolated(unsafe) private static var guardsInstalled = false

    /// Plays the system alert sound, unless the app runs headless.
    static func play() {
        if isSilenced { suppressedCount += 1; return }
        NSSound.beep()
    }
}
