import AppKit

/// QA automation: headless UI answers (`Automation` / `UIBlock`), the launched-app menu / dialog / panel / shortcut
/// fuzz driver (`Lumen --menu-fuzz=<scenario> --out=<dir>`, see scripts/menu_fuzz_runner.sh) and the `qamenus` self test.
enum QAMenusModule {
    static func register() {
        Automation.bootstrap()
        FeatureModules.selfTests.append(("qamenus", { out in QAMenusSelfTest.run(out) }))
        if Automation.isFuzz { MenuFuzz.prepareLaunch() }
    }
}
