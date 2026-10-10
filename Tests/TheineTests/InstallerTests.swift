import Darwin
import XCTest
import TheineCore
import TheineHelperCore

/// The install of the helper. The script that would run as root runs here as the test itself, over a layout in a folder
/// of the test's own: the real cp, codesign, base64, mkdir, chmod and mv, with stand-ins only for chown and launchctl,
/// which need root. /usr/bin/true plays the helper: Apple's signature, identifier "com.apple.true". No password dialog
/// opens anywhere: osascript runs the line only without administrator privileges.
final class InstallerTests: XCTestCase {
    private final class Rig {
        let root = TemporaryFolder("theine-install")
        let layout: HelperInstaller.Layout
        let source: String

        init() {
            root.folder("Library/LaunchDaemons")
            root.folder("tools")
            // The app may live in a folder with spaces and quotes in its name.
            let helpers = root.folder("Apps/Bob's Theine.app/Contents/Helpers")
            source = helpers + "/TheineHelper"
            try! FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: source)
            for tool in ["chown", "launchctl"] {
                root.write("#!/bin/sh\necho \"$*\" >> \"$(/usr/bin/dirname \"$0\")/\(tool).log\"\n", to: "tools/\(tool)", mode: 0o755)
            }
            layout = HelperInstaller.Layout(executable: root.sub("Library/PrivilegedHelperTools/com.theine.app.helper"),
                                            launchDaemon: root.sub("Library/LaunchDaemons/com.theine.app.helper.plist"),
                                            folder: root.sub("Library/Application Support/Theine"),
                                            requests: root.sub("Library/Application Support/Theine/Requests"),
                                            chown: root.sub("tools/chown"), launchctl: root.sub("tools/launchctl"),
                                            owner: getuid())
        }

        func installer(requirement: String = "identifier \"com.apple.true\"", runner: CommandRunning = ProcessRunner()) -> HelperInstaller {
            HelperInstaller(source: URL(fileURLWithPath: source), requirement: requirement, layout: layout, runner: runner)
        }

        func log(_ tool: String) -> [String] {
            (root.read("tools/\(tool).log") ?? "").split(separator: "\n").map(String.init)
        }

        /// What is left of the staging folders.
        var staged: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.sub("Library/PrivilegedHelperTools"))) ?? [])
                .filter { $0.hasPrefix(".") }
        }
    }

    private func runScript(_ installer: HelperInstaller) -> CommandResult {
        shell("/bin/sh", ["-c", installer.script()])
    }

    func testTheScriptPutsEverythingInPlaceAndStartsTheJob() throws {
        let rig = Rig()
        let result = runScript(rig.installer())
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.hasSuffix("theine-helper-installed\n"), result.output)

        XCTAssertTrue(FileManager.default.contentsEqual(atPath: rig.layout.executable, andPath: rig.source), "the helper, as it was")
        XCTAssertEqual(rig.root.mode("Library/PrivilegedHelperTools/com.theine.app.helper"), 0o755)
        XCTAssertEqual(FileManager.default.contents(atPath: rig.layout.launchDaemon), Helper.launchDaemonPlist())
        XCTAssertEqual(rig.root.mode("Library/LaunchDaemons/com.theine.app.helper.plist"), 0o644)
        XCTAssertEqual(shell("/usr/bin/plutil", ["-lint", rig.layout.launchDaemon]).status, 0)
        XCTAssertEqual(rig.root.mode("Library/Application Support/Theine"), 0o755)
        XCTAssertEqual(rig.root.mode("Library/Application Support/Theine/Requests"), 0o1777, "anyone may ask, nobody may take another's file")
        XCTAssertEqual(rig.staged, [], "the staging folder goes")

        let chown = rig.log("chown")
        XCTAssertEqual(chown.count, 2)
        XCTAssertTrue(chown.allSatisfy { $0.hasPrefix("root:wheel ") }, "\(chown)")
        let staged = chown[0].split(separator: " ").map(String.init)
        XCTAssertEqual(staged.count, 3)
        XCTAssertEqual(staged.dropFirst().map { ($0 as NSString).lastPathComponent }, ["helper", "job.plist"], "the staged copies")
        XCTAssertTrue(staged[1].hasPrefix(rig.root.sub("Library/PrivilegedHelperTools/.com.theine.app.helper.")))
        XCTAssertEqual(chown[1], "root:wheel \(rig.layout.folder) \(rig.layout.requests)")
        XCTAssertEqual(rig.log("launchctl"), ["bootout system/com.theine.app.helper", "enable system/com.theine.app.helper",
                                              "bootstrap system \(rig.layout.launchDaemon)"],
                       "the old job stops before the new files go in, the new one starts after")
    }

    func testAHelperWithAnotherSignatureIsNeverInstalled() {
        let rig = Rig()
        for requirement in ["identifier \"com.theine.app.helper\" and certificate leaf = H\"af82036140843a7d76497ea8e4cd23403c8aedc2\"",
                            "identifier \"com.theine.app.helper\""] {
            let result = runScript(rig.installer(requirement: requirement))
            XCTAssertNotEqual(result.status, 0, requirement)
            XCTAssertFalse(result.output.contains("theine-helper-installed"))
            XCTAssertFalse(rig.root.exists("Library/PrivilegedHelperTools/com.theine.app.helper"))
            XCTAssertFalse(rig.root.exists("Library/LaunchDaemons/com.theine.app.helper.plist"))
            XCTAssertEqual(rig.log("launchctl"), [], "no job is touched")
            XCTAssertEqual(rig.staged, [], "the rejected copy goes with its staging folder")
        }
    }

    func testAMissingHelperStopsTheScript() throws {
        let rig = Rig()
        try FileManager.default.removeItem(atPath: rig.source)
        XCTAssertNotEqual(runScript(rig.installer()).status, 0)
        XCTAssertEqual(rig.log("launchctl"), [])
    }

    func testInstallingAgainReplacesTheOldHelper() {
        let rig = Rig()
        rig.root.folder("Library/PrivilegedHelperTools")
        rig.root.write("old helper", to: "Library/PrivilegedHelperTools/com.theine.app.helper", mode: 0o700)
        rig.root.folder("Library/Application Support/Theine/Requests")
        XCTAssertEqual(runScript(rig.installer()).status, 0)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: rig.layout.executable, andPath: rig.source))
        XCTAssertEqual(rig.root.mode("Library/PrivilegedHelperTools/com.theine.app.helper"), 0o755)
        XCTAssertEqual(rig.root.mode("Library/Application Support/Theine/Requests"), 0o1777)
        XCTAssertEqual(runScript(rig.installer()).status, 0, "and again")
    }

    func testTheScriptPassesShellSyntaxCheck() throws {
        let folder = TemporaryFolder()
        let file = folder.sub("install.sh")
        let real = HelperInstaller(source: URL(fileURLWithPath: "/Applications/Theine.app/Contents/Helpers/TheineHelper"),
                                   requirement: "identifier \"com.theine.app.helper\" and certificate leaf = H\"af82036140843a7d76497ea8e4cd23403c8aedc2\"")
        try real.script().write(toFile: file, atomically: true, encoding: .utf8)
        let check = shell("/bin/sh", ["-n", file])
        XCTAssertEqual(check.status, 0, check.output)
        // The real layout: only root's folders, and launchctl for the system domain.
        let script = real.script()
        XCTAssertTrue(script.contains("'/Library/PrivilegedHelperTools/com.theine.app.helper'"))
        XCTAssertTrue(script.contains("'/Library/LaunchDaemons/com.theine.app.helper.plist'"))
        XCTAssertTrue(script.contains("/usr/bin/codesign --verify --strict -R '=identifier \"com.theine.app.helper\" and certificate leaf"))
        XCTAssertTrue(script.contains("'/bin/launchctl' bootstrap system"))
        XCTAssertTrue(script.contains("'/usr/sbin/chown' root:wheel"))
    }

    // MARK: Through osascript

    func testTheAppleScriptLineIsOneLineAndAsksForAdministratorPrivileges() {
        let line = Rig().installer().appleScript(prompt: "Theine ставит \"помощника\".")
        XCTAssertFalse(line.contains("\n"), "one line for osascript")
        XCTAssertTrue(line.hasPrefix("do shell script \""))
        XCTAssertTrue(line.hasSuffix("with prompt \"Theine ставит \\\"помощника\\\".\" with administrator privileges without altering line endings"))
    }

    /// The very line osascript would run, without administrator privileges: the shell gets the script exactly, quotes,
    /// backslashes and line breaks included, and it works.
    func testOsascriptHandsTheScriptToTheShellUnchanged() throws {
        let rig = Rig()
        let installer = rig.installer()
        let line = installer.appleScript(prompt: "", privileged: false)
        XCTAssertFalse(line.contains("administrator"))
        let result = shell(HelperInstaller.osascript, ["-e", line])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("theine-helper-installed"), result.output)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: rig.layout.executable, andPath: rig.source))
        XCTAssertEqual(rig.log("launchctl").last, "bootstrap system \(rig.layout.launchDaemon)")
    }

    // MARK: Outcomes

    private struct Answer: CommandRunning {
        let result: CommandResult?
        let calls = Calls()

        final class Calls: @unchecked Sendable {
            var list: [(String, [String])] = []
        }

        func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult? {
            calls.list.append((path, arguments))
            return result
        }
    }

    func testTheOutcomeOfThePasswordDialog() {
        let rig = Rig()
        let done = Answer(result: CommandResult(status: 0, output: "theine-helper-installed\n"))
        XCTAssertEqual(rig.installer(runner: done).install(prompt: "p"), .installed)
        XCTAssertEqual(done.calls.list.first?.0, "/usr/bin/osascript")
        XCTAssertEqual(done.calls.list.first?.1, ["-e", rig.installer().appleScript(prompt: "p")])
        XCTAssertEqual(rig.installer(runner: Answer(result: CommandResult(status: 1, output: "execution error: User canceled. (-128)\n")))
            .install(prompt: "p"), .cancelled)
        XCTAssertEqual(rig.installer(runner: Answer(result: CommandResult(status: 1, output: "test-requirement: code failed\n")))
            .install(prompt: "p"), .failed("test-requirement: code failed"))
        XCTAssertEqual(rig.installer(runner: Answer(result: CommandResult(status: 0, output: "")))
            .install(prompt: "p"), .failed(""), "no last line, no install")
        XCTAssertEqual(rig.installer(runner: Answer(result: nil)).install(prompt: "p"),
                       .failed("osascript did not start or took too long"))
    }

    func testTheInstalledVersionIsWhatTheInstalledHelperSays() {
        let rig = Rig()
        let says = Answer(result: CommandResult(status: 0, output: "1\n"))
        XCTAssertNil(HelperInstaller.installedVersion(layout: rig.layout, runner: says), "nothing installed")
        XCTAssertTrue(says.calls.list.isEmpty, "and nothing run")
        XCTAssertEqual(runScript(rig.installer()).status, 0)
        XCTAssertEqual(HelperInstaller.installedVersion(layout: rig.layout, runner: says), 1)
        XCTAssertEqual(says.calls.list.last?.0, rig.layout.executable)
        XCTAssertEqual(says.calls.list.last?.1, [], "asked with no arguments")
        XCTAssertNil(HelperInstaller.installedVersion(layout: rig.layout, runner: Answer(result: CommandResult(status: 1, output: "1"))))
        XCTAssertNil(HelperInstaller.installedVersion(layout: rig.layout, runner: Answer(result: CommandResult(status: 0, output: "?"))))
        var other = rig.layout
        other.owner = getuid() + 1
        XCTAssertNil(HelperInstaller.installedVersion(layout: other, runner: says), "files that are not root's do not count")
        unlink(rig.layout.launchDaemon)
        XCTAssertNil(HelperInstaller.installedVersion(layout: rig.layout, runner: says), "a helper without its job does not count")
    }
}
