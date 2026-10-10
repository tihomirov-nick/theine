// Theine's helper. launchd runs it as root at load, whenever the folder of requests changes and every few seconds; each
// run is one look at the requests and SleepDisabled (HelperPass), and out. It takes no arguments and reads nothing from
// its environment. Anyone else who runs it only learns its version: that is how Theine tells whether the installed
// helper is the one it ships.
import Darwin
import os
import TheineHelperCore

guard geteuid() == 0 else {
    print(Helper.version)
    exit(0)
}

let log = Logger(subsystem: Helper.label, category: "sleep")
switch HelperPass().run() {
case .idle, .holding:
    break
case .held(let before):
    log.notice("Theine asked: SleepDisabled is on (it was \(before ? 1 : 0, privacy: .public))")
case .retaken:
    log.notice("SleepDisabled was switched off while Theine held it: on again, 0 goes back later")
case .released(let restored):
    log.notice("Nobody asks any more: \(restored ? "SleepDisabled is back at 0" : "SleepDisabled left as it is", privacy: .public)")
case .failed(let reason):
    log.error("\(reason, privacy: .public)")
    exit(1)
}
