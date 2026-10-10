import Darwin
import XCTest
@testable import TheineHelperCore

/// The helper's logic, run as the test itself over a folder of its own: a stand-in pmset that keeps SleepDisabled in a
/// file and a stand-in list of processes. Nothing here reads or changes the Mac's real setting.
final class HelperTests: XCTestCase {
    private static let theine = "/Applications/Theine.app/Contents/MacOS/Theine"

    /// The processes the helper is told about.
    private struct Processes: ProcessTable {
        var table: [pid_t: (String, uid_t)] = [:]

        func pids() -> [pid_t] {
            table.keys.sorted()
        }

        func process(_ pid: pid_t) -> (executable: String, uid: uid_t)? {
            table[pid].map { (executable: $0.0, uid: $0.1) }
        }
    }

    /// The world of one helper: the folder of requests, the file of the value from before, the stand-in pmset and the
    /// processes.
    private final class Rig {
        let root = TemporaryFolder("theine-helper")
        var processes = Processes()
        let requests: String
        let saved: String
        let pmset: String

        init() {
            requests = root.folder("Requests")
            saved = root.sub("SleepDisabledBefore")
            pmset = root.folder("pmset") + "/pmset"
            root.write("""
            #!/bin/sh
            # pmset as the helper uses it. SleepDisabled lives in the file "value" (no file: never set, that is 0); every
            # call goes to "calls", every change to "changes". "broken" breaks reading, "fails" breaks changing.
            here=$(/usr/bin/dirname "$0")
            echo "$*" >> "$here/calls"
            case "$1" in
            -g)
                [ -f "$here/broken" ] && exit 1
                echo "System-wide power settings:"
                [ -f "$here/value" ] && printf ' SleepDisabled\\t\\t%s\\n' "$(/bin/cat "$here/value")"
                echo "Currently in use:"
                echo " standby              1"
                echo " sleep                1"
                ;;
            -a)
                [ "$2" = disablesleep ] || exit 1
                [ -f "$here/fails" ] && exit 1
                printf %s "$3" > "$here/value"
                echo "$3" >> "$here/changes"
                ;;
            *)
                exit 1
                ;;
            esac
            """, to: "pmset/pmset", mode: 0o755)
        }

        var value: String? {
            get { root.read("pmset/value") }
            set {
                if let newValue { root.write(newValue, to: "pmset/value") } else { unlink(root.sub("pmset/value")) }
            }
        }

        var calls: [String] { lines("pmset/calls") }
        var changes: [String] { lines("pmset/changes") }
        var savedValue: String? { root.read("SleepDisabledBefore") }

        func flag(_ name: String, _ on: Bool) {
            if on { root.write("", to: "pmset/" + name) } else { unlink(root.sub("pmset/" + name)) }
        }

        private func lines(_ name: String) -> [String] {
            (root.read(name) ?? "").split(separator: "\n").map(String.init)
        }

        /// A Theine of this user, asking.
        func ask(pid: pid_t, executable: String = HelperTests.theine, uid: uid_t = getuid()) {
            processes.table[pid] = (executable, uid)
            XCTAssertTrue(HelperRequest.write(pid: pid, uid: getuid(), in: requests))
        }

        func run() -> HelperPass.Outcome {
            HelperPass(requests: requests, saved: saved, setting: PMSet(path: pmset), processes: processes).run()
        }
    }

    // MARK: Holding and giving back

    func testNobodyAsksAndNothingHappensNotEvenPmset() {
        let rig = Rig()
        XCTAssertEqual(rig.run(), .idle)
        XCTAssertEqual(rig.calls, [])
        XCTAssertNil(rig.savedValue)
    }

    func testATheineAsksAndSleepDisabledGoesOnWithTheValueFromBeforeWrittenDown() {
        let rig = Rig()
        rig.ask(pid: 4242)
        XCTAssertEqual(rig.run(), .held(before: false))
        XCTAssertEqual(rig.value, "1")
        XCTAssertEqual(rig.changes, ["1"])
        XCTAssertEqual(rig.savedValue, "0\n")
        XCTAssertEqual(rig.run(), .holding, "the next runs only look")
        XCTAssertEqual(rig.changes, ["1"])
    }

    func testANeverSetValueCountsAsZero() {
        let rig = Rig()
        rig.value = nil
        rig.ask(pid: 4242)
        XCTAssertEqual(rig.run(), .held(before: false))
        XCTAssertEqual(rig.value, "1")
    }

    func testTheRequestGoesAndTheZeroComesBack() {
        let rig = Rig()
        rig.value = "0"
        rig.ask(pid: 4242)
        _ = rig.run()
        HelperRequest.remove(uid: getuid(), in: rig.requests)
        XCTAssertEqual(rig.run(), .released(restored: true))
        XCTAssertEqual(rig.value, "0")
        XCTAssertNil(rig.savedValue, "nothing is held any more")
        XCTAssertEqual(rig.run(), .idle)
    }

    /// Amphetamine's closed-display mode had SleepDisabled on before Theine: it stays on when Theine lets go.
    func testSomeoneElsesOneIsNeitherChangedNorTakenAway() {
        let rig = Rig()
        rig.value = "1"
        rig.ask(pid: 4242)
        XCTAssertEqual(rig.run(), .held(before: true))
        XCTAssertEqual(rig.changes, [], "it was on already")
        XCTAssertEqual(rig.savedValue, "1\n")
        HelperRequest.remove(uid: getuid(), in: rig.requests)
        XCTAssertEqual(rig.run(), .released(restored: false))
        XCTAssertEqual(rig.value, "1")
        XCTAssertEqual(rig.changes, [])
        XCTAssertNil(rig.savedValue)
    }

    func testATheineThatDiedNoLongerHolds() {
        let rig = Rig()
        rig.value = "0"
        rig.ask(pid: 4242)
        _ = rig.run()
        // A crash or a forced quit: the request stays, the process is gone.
        rig.processes.table[4242] = nil
        XCTAssertEqual(rig.run(), .released(restored: true))
        XCTAssertEqual(rig.value, "0")
    }

    func testANumberThatIsNoTheineIsNoRequest() {
        let rig = Rig()
        rig.value = "0"
        // The PID of a dead Theine taken by another program.
        rig.ask(pid: 4242, executable: "/usr/bin/caffeinate")
        XCTAssertEqual(rig.run(), .idle)
        rig.ask(pid: 4243, executable: "/Users/someone/Theine")
        XCTAssertEqual(rig.run(), .idle, "an executable called Theine outside Theine.app does not count")
        XCTAssertEqual(rig.value, "0")
        XCTAssertEqual(rig.calls, [])
    }

    func testARequestCountsOnlyForATheineOfTheFilesOwner() {
        let rig = Rig()
        // Someone's file pointing at the Theine of another user.
        rig.ask(pid: 4242, uid: getuid() + 1)
        XCTAssertEqual(rig.run(), .idle)
    }

    func testTheRequestMustNameALiveTheineOfItsUser() {
        let rig = Rig()
        rig.value = "0"
        rig.ask(pid: 4242)
        // Another Theine of the same user that has not asked, an old copy for one.
        rig.processes.table[5151] = (Self.theine, getuid())
        XCTAssertEqual(rig.run(), .held(before: false))
        rig.processes.table[4242] = nil
        XCTAssertEqual(rig.run(), .released(restored: true), "the request names the Theine that died")
        rig.ask(pid: 5151)
        XCTAssertEqual(rig.run(), .held(before: false))
    }

    /// Anyone may put files into the folder of requests; the helper opens only the file of each running Theine's user.
    func testJunkInTheFolderHidesNoRequest() {
        let rig = Rig()
        rig.value = "0"
        for name in (0..<200).map({ String($0) }) + ["0000", "a", ".hidden"] where name != "\(getuid())" {
            rig.root.write("4242\n", to: "Requests/" + name)
        }
        XCTAssertEqual(rig.run(), .idle, "junk is no request")
        rig.ask(pid: 4242)
        XCTAssertEqual(rig.run(), .held(before: false))
    }

    func testAnEmptyFolderMeansNobodyAsksWithoutListingProcesses() throws {
        let folder = TemporaryFolder()
        XCTAssertFalse(HelperRequest.isOccupied(folder.path))
        XCTAssertFalse(HelperRequest.isOccupied(folder.sub("missing")))
        folder.write("", to: ".x")
        XCTAssertTrue(HelperRequest.isOccupied(folder.path))
    }

    // MARK: Someone else changes the setting meanwhile

    func testSwitchedOffWhileHeldItGoesOnAgainAndZeroIsWhatComesBack() {
        let rig = Rig()
        rig.value = "1"
        rig.ask(pid: 4242)
        XCTAssertEqual(rig.run(), .held(before: true))
        // Amphetamine ends its session and turns SleepDisabled off under Theine.
        rig.value = "0"
        XCTAssertEqual(rig.run(), .retaken)
        XCTAssertEqual(rig.value, "1")
        XCTAssertEqual(rig.savedValue, "0\n", "0 is what that someone wants now")
        HelperRequest.remove(uid: getuid(), in: rig.requests)
        XCTAssertEqual(rig.run(), .released(restored: true))
        XCTAssertEqual(rig.value, "0", "the Mac may sleep again")
    }

    func testSwitchedOffAfterTheineLetGoStaysOff() {
        let rig = Rig()
        rig.value = "1"
        rig.ask(pid: 4242)
        _ = rig.run()
        HelperRequest.remove(uid: getuid(), in: rig.requests)
        rig.value = "0"
        XCTAssertEqual(rig.run(), .released(restored: false))
        XCTAssertEqual(rig.value, "0")
    }

    // MARK: The start of the daemon

    /// The Mac restarted (or the helper was stopped) while Theine held: at load nobody asks, the old value comes back.
    func testAtLoadWithoutALiveRequestTheValueFromBeforeComesBack() {
        let rig = Rig()
        rig.value = "1"
        rig.root.write("0\n", to: "SleepDisabledBefore")
        // The request of the Theine that ran before the restart.
        rig.root.write("4242\n", to: "Requests/\(getuid())")
        XCTAssertEqual(rig.run(), .released(restored: true))
        XCTAssertEqual(rig.value, "0")
        XCTAssertNil(rig.savedValue)
    }

    func testAtLoadWithALiveRequestTheHoldGoesOn() {
        let rig = Rig()
        rig.value = "1"
        rig.root.write("0\n", to: "SleepDisabledBefore")
        rig.ask(pid: 4242)
        XCTAssertEqual(rig.run(), .holding, "a helper updated under a running Theine changes nothing")
        XCTAssertEqual(rig.savedValue, "0\n")
        XCTAssertEqual(rig.changes, [])
    }

    func testADamagedRecordLetsTheMacSleep() {
        let rig = Rig()
        rig.value = "1"
        rig.root.write("garbage", to: "SleepDisabledBefore")
        XCTAssertEqual(rig.run(), .released(restored: true))
        XCTAssertEqual(rig.value, "0")
    }

    // MARK: Failures

    func testAnUnreadableSettingChangesNothing() {
        let rig = Rig()
        rig.ask(pid: 4242)
        rig.flag("broken", true)
        XCTAssertEqual(rig.run(), .failed("SleepDisabled cannot be read"))
        XCTAssertNil(rig.savedValue)
        XCTAssertEqual(rig.changes, [])
    }

    func testAFailedChangeIsTriedAgainByTheNextRun() {
        let rig = Rig()
        rig.value = "0"
        rig.ask(pid: 4242)
        rig.flag("fails", true)
        XCTAssertEqual(rig.run(), .failed("SleepDisabled cannot be turned on"))
        XCTAssertEqual(rig.savedValue, "0\n", "written down before the change, so nothing is lost")
        rig.flag("fails", false)
        XCTAssertEqual(rig.run(), .retaken)
        XCTAssertEqual(rig.value, "1")

        HelperRequest.remove(uid: getuid(), in: rig.requests)
        rig.flag("fails", true)
        XCTAssertEqual(rig.run(), .failed("SleepDisabled cannot be turned off"))
        XCTAssertEqual(rig.savedValue, "0\n", "kept until the zero is really back")
        rig.flag("fails", false)
        XCTAssertEqual(rig.run(), .released(restored: true))
        XCTAssertEqual(rig.value, "0")
    }

    // MARK: Requests

    func testTheRequestIsAPlainFileWithThePID() throws {
        let folder = TemporaryFolder()
        XCTAssertTrue(HelperRequest.write(pid: 4242, uid: 501, in: folder.path))
        XCTAssertEqual(folder.read("501"), "4242\n")
        XCTAssertEqual(folder.mode("501"), 0o644)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["501"], "no half-written file left")
        let before = try FileManager.default.attributesOfItem(atPath: folder.sub("501"))[.systemFileNumber] as? Int
        XCTAssertTrue(HelperRequest.write(pid: 4242, uid: 501, in: folder.path))
        let after = try FileManager.default.attributesOfItem(atPath: folder.sub("501"))[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "the same request is not written again, so the helper is not woken for nothing")
        XCTAssertTrue(HelperRequest.write(pid: 777, uid: 501, in: folder.path))
        XCTAssertEqual(folder.read("501"), "777\n")
        HelperRequest.remove(uid: 501, in: folder.path)
        XCTAssertFalse(folder.exists("501"))
    }

    func testWithoutTheHelpersFolderThereIsNoRequest() {
        let folder = TemporaryFolder()
        XCTAssertFalse(HelperRequest.write(pid: 4242, uid: 501, in: folder.sub("missing")))
    }

    func testOnlyASmallPlainFileWithThePIDIsARequest() throws {
        let rig = Rig()
        rig.processes.table[4242] = (Self.theine, getuid())
        let request = rig.requests + "/\(getuid())"
        rig.root.write("4242", to: "target")
        let files = FileManager.default
        try files.createSymbolicLink(atPath: request, withDestinationPath: rig.root.sub("target"))
        XCTAssertEqual(HelperRequest.live(in: rig.requests, processes: rig.processes), [], "a link")
        unlink(request)
        try files.createDirectory(atPath: request, withIntermediateDirectories: false)
        XCTAssertEqual(HelperRequest.live(in: rig.requests, processes: rig.processes), [], "a folder")
        rmdir(request)
        XCTAssertEqual(mkfifo(request, 0o644), 0)
        XCTAssertEqual(HelperRequest.live(in: rig.requests, processes: rig.processes), [], "a pipe")
        unlink(request)
        for text in [String(repeating: " ", count: 40) + "4242", "4242 4243", "-4242", "4243", "1", "forty-two", ""] {
            rig.root.write(text, to: "Requests/\(getuid())")
            XCTAssertEqual(HelperRequest.live(in: rig.requests, processes: rig.processes), [], "«\(text)»")
        }
        // A request under way: written to a hidden file first, renamed into place after.
        unlink(request)
        rig.root.write("4242", to: "Requests/.\(getuid()).4242")
        XCTAssertEqual(HelperRequest.live(in: rig.requests, processes: rig.processes), [])
        XCTAssertEqual(rig.run(), .idle)
        rig.root.write("  4242 \n", to: "Requests/\(getuid())")
        XCTAssertEqual(HelperRequest.live(in: rig.requests, processes: rig.processes), [4242])
    }

    func testTheExecutableOfTheineIsInsideTheineApp() {
        XCTAssertTrue(Helper.isTheine(executable: "/Applications/Theine.app/Contents/MacOS/Theine"))
        XCTAssertTrue(Helper.isTheine(executable: "/Users/nick/Applications/Theine.app/Contents/MacOS/Theine"))
        XCTAssertFalse(Helper.isTheine(executable: "/Applications/Theine.app/Contents/Helpers/TheineHelper"))
        XCTAssertFalse(Helper.isTheine(executable: "/Applications/NotTheine.app/Contents/MacOS/NotTheine"))
        XCTAssertFalse(Helper.isTheine(executable: "/tmp/Theine"))
    }

    // MARK: The system's side

    func testPmsetIsReadTheWayItPrintsTheSetting() {
        XCTAssertTrue(PMSet.sleepDisabled(in: "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"))
        XCTAssertFalse(PMSet.sleepDisabled(in: "System-wide power settings:\n SleepDisabled\t\t0\nCurrently in use:\n"))
        XCTAssertFalse(PMSet.sleepDisabled(in: "Currently in use:\n standby 1\n sleep 1\n"), "no line: the default, off")
    }

    func testTheRealPmsetCanBeRead() {
        // Reading needs no root and changes nothing.
        XCTAssertNotNil(PMSet().read())
    }

    func testTheSystemKnowsALiveProcessAndForgetsAFinishedOne() throws {
        XCTAssertTrue(SystemProcesses().pids().contains(getpid()))
        let own = try XCTUnwrap(SystemProcesses().process(getpid()))
        XCTAssertEqual(own.uid, getuid())
        XCTAssertTrue(own.executable.hasPrefix("/"))
        XCTAssertEqual(own.executable, URL(fileURLWithPath: own.executable).resolvingSymlinksInPath().path,
                       "the file the process really runs")

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, nil), 0)
        // Not waited for yet: a zombie, which counts as no process.
        let limit = Date().addingTimeInterval(3)
        while SystemProcesses().process(pid) != nil, Date() < limit { usleep(20_000) }
        XCTAssertNil(SystemProcesses().process(pid))
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        XCTAssertNil(SystemProcesses().process(pid))
        XCTAssertNil(SystemProcesses().process(0))
        XCTAssertNil(SystemProcesses().process(1), "launchd is never Theine")
    }

    // MARK: The launchd job and the helper itself

    func testTheLaunchdJobPassesPlutilAndPointsOnlyAtRootsFiles() throws {
        let folder = TemporaryFolder()
        let file = folder.sub("job.plist")
        try Helper.launchDaemonPlist().write(to: URL(fileURLWithPath: file))
        let lint = shell("/usr/bin/plutil", ["-lint", file])
        XCTAssertEqual(lint.status, 0, lint.output)
        XCTAssertTrue(lint.output.contains("OK"))

        let job = try XCTUnwrap(PropertyListSerialization.propertyList(from: Helper.launchDaemonPlist(), format: nil) as? [String: Any])
        XCTAssertEqual(job["Label"] as? String, "com.theine.app.helper")
        XCTAssertEqual(job["ProgramArguments"] as? [String], ["/Library/PrivilegedHelperTools/com.theine.app.helper"],
                       "the installed copy, never the one inside the app")
        XCTAssertEqual(job["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(job["StartInterval"] as? Int, 5)
        XCTAssertEqual(job["WatchPaths"] as? [String], ["/Library/Application Support/Theine/Requests"])
        XCTAssertNil(job["UserName"], "it runs as root")
        XCTAssertNil(job["EnvironmentVariables"])
        let text = String(decoding: Helper.launchDaemonPlist(), as: UTF8.self)
        XCTAssertFalse(text.contains(".app/"), "nothing inside an app bundle")
    }

    /// Run by anyone but root, the helper only says its version: that is how Theine asks it.
    func testTheHelperTellsItsVersionToAnyoneButRootAndDoesNothingElse() throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("TheineHelper").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper), "the helper is built next to the tests")
        XCTAssertNotEqual(geteuid(), 0)
        let result = shell(helper, ["anything", "/etc/passwd"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "\(Helper.version)\n", "and it takes no arguments")
    }
}
