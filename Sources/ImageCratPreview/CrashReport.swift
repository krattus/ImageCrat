import Foundation
import WinSDK
import ImageCratWinSupport

/// Last-resort handler: if the process hits an internal error (a Swift runtime trap or an access violation), tell the
/// user what happened and where to report it instead of vanishing, and keep a log line.
enum CrashReport {
    static func install() {
        SetUnhandledExceptionFilter { info in
            let code = info?.pointee.ExceptionRecord?.pointee.ExceptionCode ?? 0
            CrashReport.report(code: UInt32(code))
            return W32.EXCEPTION_EXECUTE_HANDLER
        }
    }

    static func report(code: UInt32) {
        let file = App.shared.currentPath ?? "(no file open)"
        let hex = String(code, radix: 16, uppercase: true)
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(BuildInfo.versionLine)  exception 0x\(hex)  file: \(file)\n"
        if let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] {
            let dir = URL(fileURLWithPath: base).appendingPathComponent("ImageCrat").appendingPathComponent("Preview")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let log = dir.appendingPathComponent("crash.log")
            if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
            else { try? Data(line.utf8).write(to: log) }
        }
        FileHandle.standardError.write(Data(("internal error: " + line).utf8))
        if !App.shared.headless {
            let text = "ImageCrat Preview hit an internal error (exception 0x\(hex)) and has to close.\n\nLast file: \(file)\n\nPlease report this at \(BuildInfo.website)/issues together with the file if you can share it. A log line was written to %LOCALAPPDATA%\\ImageCrat\\Preview\\crash.log."
            _ = withWide(text) { t in withWide("ImageCrat Preview") { c in MessageBoxW(nil, t, c, W32.MB_OK | W32.MB_ICONERROR) } }
        }
    }
}
