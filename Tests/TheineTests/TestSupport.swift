import Foundation
import XCTest
import TheineHelperCore

/// A folder of the test's own, gone with the test.
final class TemporaryFolder {
    let path: String

    init(_ name: String = "theine") {
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(name)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func sub(_ name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }

    /// Makes the folder `name` (with its parents) and returns its path.
    @discardableResult
    func folder(_ name: String) -> String {
        let folder = sub(name)
        try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    func write(_ text: String, to name: String, mode: Int = 0o644) {
        let file = sub(name)
        FileManager.default.createFile(atPath: file, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
    }

    func read(_ name: String) -> String? {
        FileManager.default.contents(atPath: sub(name)).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ name: String) -> Bool {
        var info = stat()
        return lstat(sub(name), &info) == 0
    }

    func mode(_ name: String) -> Int? {
        var info = stat()
        guard lstat(sub(name), &info) == 0 else { return nil }
        return Int(info.st_mode & 0o7777)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Runs a program as the test itself.
@discardableResult
func shell(_ path: String, _ arguments: [String], timeout: TimeInterval = 60) -> CommandResult {
    ProcessRunner().run(path, arguments, timeout: timeout) ?? CommandResult(status: -1, output: "did not run")
}
