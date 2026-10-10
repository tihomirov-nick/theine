import CryptoKit
import Foundation
import Security
import TheineHelperCore

/// Installs the helper (Helper.swift) with the administrator's password: one `do shell script … with administrator
/// privileges`, the way Mole runs its steps as root, so the system asks for the password once. The script goes inline,
/// never through a file another process could change. As root it copies the helper out of the app into a folder only root
/// may write to and checks that copy's signature first: the helper's identifier and the certificate the running Theine
/// is signed with. Only then do the helper, its launchd job and the folder of requests go in place, and the job starts.
/// Neither the job nor the helper ever points into the app: the app's folder is the user's to change.
public struct HelperInstaller: Sendable {
    /// Where things go. `system` is the only real one; tests put everything into a folder of their own and stand in
    /// for the two tools that need root.
    public struct Layout: Sendable {
        public var executable: String
        public var launchDaemon: String
        public var folder: String
        public var requests: String
        public var chown: String
        public var launchctl: String
        /// The user the installed files belong to: root.
        public var owner: uid_t

        public init(executable: String, launchDaemon: String, folder: String, requests: String, chown: String,
                    launchctl: String, owner: uid_t) {
            self.executable = executable
            self.launchDaemon = launchDaemon
            self.folder = folder
            self.requests = requests
            self.chown = chown
            self.launchctl = launchctl
            self.owner = owner
        }

        public static let system = Layout(executable: Helper.executable, launchDaemon: Helper.launchDaemon,
                                          folder: Helper.folder, requests: Helper.requests, chown: "/usr/sbin/chown",
                                          launchctl: "/bin/launchctl", owner: 0)
    }

    public enum Outcome: Equatable, Sendable {
        case installed
        /// The password dialog was cancelled.
        case cancelled
        /// osascript did not start or took too long, or a step failed: its words, for the log.
        case failed(String)
    }

    /// The helper inside the app.
    public var source: URL
    /// What the copy must satisfy, in the language of code requirements.
    public var requirement: String
    public var layout: Layout
    public var runner: CommandRunning

    public static let osascript = "/usr/bin/osascript"
    /// The script's last line, after everything worked.
    static let doneMarker = "theine-helper-installed"

    public init(source: URL, requirement: String, layout: Layout = .system, runner: CommandRunning = ProcessRunner()) {
        self.source = source
        self.requirement = requirement
        self.layout = layout
        self.runner = runner
    }

    /// The installer of the running app: its own helper, held to the certificate the app itself is signed with. Nil for a
    /// build signed ad hoc: without a certificate nothing tells its helper from any other program.
    public static func forThisApp(bundle: Bundle = .main) -> HelperInstaller? {
        guard let leaf = signingCertificateHash() else { return nil }
        return HelperInstaller(source: bundle.bundleURL.appendingPathComponent(Helper.bundledPath),
                               requirement: "identifier \"\(Helper.label)\" and certificate leaf = H\"\(leaf)\"")
    }

    /// The script root runs. A step that fails stops it, and the folder it staged in goes away.
    public func script() -> String {
        let tools = (layout.executable as NSString).deletingLastPathComponent
        let plist = Helper.launchDaemonPlist().base64EncodedString()
        return """
        set -eu
        umask 022
        /bin/mkdir -p -m 1755 \(quote(tools))
        stage=$(/usr/bin/mktemp -d \(quote(tools + "/.\(Helper.label).XXXXXX")))
        trap '/bin/rm -rf "$stage"' EXIT
        /bin/cp -X \(quote(source.path)) "$stage/helper"
        /usr/bin/codesign --verify --strict -R \(quote("=" + requirement)) "$stage/helper"
        /bin/echo \(quote(plist)) | /usr/bin/base64 -D -o "$stage/job.plist"
        \(quote(layout.chown)) root:wheel "$stage/helper" "$stage/job.plist"
        /bin/chmod 755 "$stage/helper"
        /bin/chmod 644 "$stage/job.plist"
        \(quote(layout.launchctl)) bootout system/\(Helper.label) 2>/dev/null || true
        /bin/mkdir -p \(quote(layout.requests))
        \(quote(layout.chown)) root:wheel \(quote(layout.folder)) \(quote(layout.requests))
        /bin/chmod 755 \(quote(layout.folder))
        /bin/chmod 1777 \(quote(layout.requests))
        /bin/mv -f "$stage/helper" \(quote(layout.executable))
        /bin/mv -f "$stage/job.plist" \(quote(layout.launchDaemon))
        \(quote(layout.launchctl)) enable system/\(Helper.label)
        \(quote(layout.launchctl)) bootstrap system \(quote(layout.launchDaemon))
        echo \(Self.doneMarker)
        """
    }

    /// The AppleScript line osascript runs; `prompt` is what the password dialog says the password is for. Tests run the
    /// same line without `privileged`, as themselves, over a layout of their own.
    public func appleScript(prompt: String, privileged: Bool = true) -> String {
        let shell = "do shell script \"\(Self.escape(script()))\""
        guard privileged else { return shell + " without altering line endings" }
        return shell + " with prompt \"\(Self.escape(prompt))\" with administrator privileges without altering line endings"
    }

    /// Asks for the password and installs. It waits for the dialog, so it runs off the main thread.
    public func install(prompt: String, timeout: TimeInterval = 600) -> Outcome {
        guard let result = runner.run(Self.osascript, ["-e", appleScript(prompt: prompt)], timeout: timeout) else {
            return .failed("osascript did not start or took too long")
        }
        if result.status == 0, result.output.contains(Self.doneMarker) { return .installed }
        if result.output.contains("-128") { return .cancelled }
        return .failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The version the installed helper reports; nil when the helper, its job or the folder of requests is missing, or
    /// does not belong to root. The helper answers this way to anyone but root and does nothing else.
    public static func installedVersion(layout: Layout = .system, runner: CommandRunning = ProcessRunner()) -> Int? {
        guard owned(layout.executable, by: layout.owner), owned(layout.launchDaemon, by: layout.owner),
              owned(layout.requests, by: layout.owner),
              let result = runner.run(layout.executable, [], timeout: 10), result.status == 0 else { return nil }
        return Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func owned(_ path: String, by owner: uid_t) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_uid == owner
    }

    /// SHA-1 of the certificate the running app is signed with, the way code requirements name it; nil for a build
    /// signed ad hoc.
    static func signingCertificateHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    }

    /// A word for the shell, in single quotes.
    private func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A string for AppleScript, in double quotes.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
