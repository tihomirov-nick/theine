import XCTest
import TheineCore
@testable import Theine

/// When Theine asks for the administrator's password, and what a «Не сейчас» changes. The line before the dialog, the
/// dialog, the install and the kept refusal are stand-ins: nothing opens on screen, nothing goes to the preferences.
@MainActor
final class ClosedLidTests: XCTestCase {
    @MainActor private final class Rig {
        var installed = false
        var modeIsOn = true
        var optionIsOn = true
        /// «Продолжить» in the line before the dialog.
        var continues = true
        var outcome = HelperInstaller.Outcome.installed
        /// A good install really puts the helper in place.
        var installPutsHelper = true
        var confirmations = 0
        var installs = 0
        var holds = 0
        /// Blocks waiting for the menu to close; run at once unless `deferred`.
        var deferred = false
        var pending: [() -> Void] = []
        /// The refusal as the preferences would keep it.
        var keptDeclined = false

        func makeLid() -> ClosedLid {
            ClosedLid(world: ClosedLid.World(
                helperIsInstalled: { [unowned self] in installed },
                modeIsOn: { [unowned self] in modeIsOn },
                optionIsOn: { [unowned self] in optionIsOn },
                confirm: { [unowned self] in
                    confirmations += 1
                    return continues
                },
                install: { [unowned self] done in
                    installs += 1
                    if outcome == .installed, installPutsHelper { installed = true }
                    done(outcome)
                },
                holdAgain: { [unowned self] in holds += 1 },
                loadDeclined: { [unowned self] in keptDeclined },
                saveDeclined: { [unowned self] in keptDeclined = $0 },
                later: { [unowned self] block in if deferred { pending.append(block) } else { block() } }))
        }

    }

    func testTheModeTurningOnAsksOnceWithTheLineFirst() {
        let rig = Rig()
        let lid = rig.makeLid()
        lid.modeTurnedOn()
        XCTAssertEqual(rig.confirmations, 1, "one line about why, before the system's dialog")
        XCTAssertEqual(rig.installs, 1)
        XCTAssertTrue(lid.isInstalled)
        XCTAssertEqual(rig.holds, 1, "the running mode asks the new helper at once")
        XCTAssertFalse(lid.declined)
        XCTAssertFalse(lid.showsNote)
        lid.modeTurnedOn()
        XCTAssertEqual(rig.installs, 1, "the password is asked for once")
    }

    func testNothingIsAskedWhileTheModeOrTheOptionIsOff() {
        let rig = Rig()
        let lid = rig.makeLid()
        rig.modeIsOn = false
        lid.modeTurnedOn()
        rig.modeIsOn = true
        rig.optionIsOn = false
        lid.modeTurnedOn()
        XCTAssertEqual(rig.confirmations, 0)
        XCTAssertEqual(rig.installs, 0)
        XCTAssertFalse(lid.showsNote)
    }

    func testAnInstalledHelperIsNotAskedForAgainButANewVersionIs() {
        let rig = Rig()
        rig.installed = true
        let lid = rig.makeLid()
        lid.modeTurnedOn()
        XCTAssertEqual(rig.installs, 0)
        // Theine updated with a helper of a newer version: the installed one no longer counts.
        rig.installed = false
        lid.modeTurnedOn()
        XCTAssertEqual(rig.confirmations, 1)
        XCTAssertEqual(rig.installs, 1)
    }

    func testNotNowLeavesTheModeAloneAndPutsTheNoteInPlace() {
        let rig = Rig()
        rig.continues = false
        let lid = rig.makeLid()
        lid.modeTurnedOn()
        XCTAssertEqual(rig.installs, 0, "no system dialog after «Не сейчас»")
        XCTAssertTrue(lid.declined)
        XCTAssertTrue(lid.showsNote)
        XCTAssertEqual(rig.holds, 0)
        lid.modeTurnedOn()
        XCTAssertEqual(rig.confirmations, 1, "and Theine does not ask again by itself")
        rig.optionIsOn = false
        XCTAssertFalse(lid.showsNote, "no note while the option is off")
    }

    func testCancellingThePasswordIsARefusalTooAndItIsRemembered() {
        let rig = Rig()
        rig.outcome = .cancelled
        let lid = rig.makeLid()
        lid.modeTurnedOn()
        XCTAssertTrue(lid.declined)
        XCTAssertTrue(lid.showsNote)
        let afterRestart = rig.makeLid()
        XCTAssertTrue(afterRestart.declined, "kept in the preferences")
        afterRestart.modeTurnedOn()
        XCTAssertEqual(rig.installs, 1)
    }

    func testAFailedInstallIsTreatedAsARefusal() {
        let rig = Rig()
        rig.outcome = .failed("test-requirement: code failed")
        let lid = rig.makeLid()
        lid.modeTurnedOn()
        XCTAssertTrue(lid.showsNote)
        XCTAssertEqual(rig.holds, 0)
        rig.outcome = .installed
        rig.installPutsHelper = false
        lid.allow()
        XCTAssertTrue(lid.showsNote, "an install that leaves no helper of this version is no install")
    }

    func testAllowGoesStraightToThePasswordDialog() {
        let rig = Rig()
        rig.continues = false
        let lid = rig.makeLid()
        lid.modeTurnedOn()
        lid.allow()
        XCTAssertEqual(rig.confirmations, 1, "the click on «Разрешить…» says what it is for")
        XCTAssertEqual(rig.installs, 1)
        XCTAssertFalse(lid.declined)
        XCTAssertFalse(lid.showsNote)
        XCTAssertEqual(rig.holds, 1)
    }

    func testTurningTheOptionOnAnewAsksAgain() {
        let rig = Rig()
        rig.continues = false
        let lid = rig.makeLid()
        lid.modeTurnedOn()
        XCTAssertTrue(lid.declined)
        rig.continues = true
        lid.optionTurnedOn()
        XCTAssertEqual(rig.confirmations, 2)
        XCTAssertEqual(rig.installs, 1)
        XCTAssertTrue(lid.isInstalled)

        let other = Rig()
        other.continues = false
        let idle = other.makeLid()
        idle.modeTurnedOn()
        other.modeIsOn = false
        idle.optionTurnedOn()
        XCTAssertFalse(idle.declined, "the next turn on asks again")
        XCTAssertEqual(other.confirmations, 1, "but nothing opens while the mode is off")
    }

    func testOneDialogAtATime() {
        let rig = Rig()
        rig.deferred = true
        let lid = rig.makeLid()
        lid.modeTurnedOn()
        lid.modeTurnedOn()
        lid.allow()
        XCTAssertTrue(lid.isAsking)
        XCTAssertEqual(rig.pending.count, 1)
        rig.pending.forEach { $0() }
        XCTAssertEqual(rig.confirmations, 1)
        XCTAssertEqual(rig.installs, 1)
        XCTAssertFalse(lid.isAsking)
    }
}
