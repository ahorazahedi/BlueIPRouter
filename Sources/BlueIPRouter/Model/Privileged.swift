import AppKit
import BlueIPRouterCore
import Foundation

enum PrivilegedError: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Administrator authorization was cancelled."
        case .failed(let message): return message
        }
    }
}

/// Single-quotes a value for /bin/sh.
func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Runs shell commands as root through the standard macOS administrator prompt.
/// The authorization is reused by macOS for a few minutes, so batches of changes need one prompt.
@MainActor
enum Privileged {
    static func run(_ commands: [String], prompt: String, stopOnError: Bool = true) throws -> String {
        let script = commands.joined(separator: stopOnError ? " && " : " ; ")
        let escape: (String) -> String = {
            $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"\(escape(script))\" with prompt \"\(escape(prompt))\" "
            + "with administrator privileges without altering line endings"
        guard let apple = NSAppleScript(source: source) else { throw PrivilegedError.failed("Could not prepare the command.") }
        var error: NSDictionary?
        let result = apple.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw PrivilegedError.cancelled }
            throw PrivilegedError.failed((error[NSAppleScript.errorMessage] as? String) ?? "The command failed.")
        }
        return result.stringValue ?? ""
    }

    /// Path of the helper bundled inside the .app (or next to the binary during development).
    static var bundledHelper: String? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "blueiprouter-helper") { return url.path }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("blueiprouter-helper").path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
    }

    static func daemonPlist(interval: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(BIR.helperLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(BIR.helperBinary)</string>
            <string>daemon</string>
            <string>--interval</string>
            <string>\(max(15, interval))</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ThrottleInterval</key><integer>10</integer>
          <key>ProcessType</key><string>Background</string>
          <key>StandardOutPath</key><string>/dev/null</string>
          <key>StandardErrorPath</key><string>\(BIR.log)</string>
        </dict>
        </plist>
        """
    }

    // MARK: Command builders

    static func installHelperCommands() throws -> [String] {
        guard let helper = bundledHelper else {
            throw PrivilegedError.failed("The bundled helper is missing. Rebuild the app with scripts/build.sh.")
        }
        return [
            "mkdir -p /Library/PrivilegedHelperTools \(shq(BIR.systemDir)) \(shq(BIR.runDir))",
            "install -o root -g wheel -m 755 \(shq(helper)) \(shq(BIR.helperBinary))",
        ]
    }

    static func installDaemonCommands(interval: Int) throws -> [String] {
        let staged = Storage.stagingDir.appendingPathComponent("\(BIR.helperLabel).plist")
        try daemonPlist(interval: interval).write(to: staged, atomically: true, encoding: .utf8)
        return [
            "(launchctl bootout system/\(BIR.helperLabel) 2>/dev/null || true)",
            "install -o root -g wheel -m 644 \(shq(staged.path)) \(shq(BIR.daemonPlist))",
            "launchctl bootstrap system \(shq(BIR.daemonPlist))",
        ]
    }

    static let removeDaemonCommands = [
        "(launchctl bootout system/\(BIR.helperLabel) 2>/dev/null || true)",
        "rm -f \(shq(BIR.daemonPlist))",
    ]

}
