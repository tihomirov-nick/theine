import Foundation

/// What a program printed (its output and its errors together) and how it ended.
public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// Runs other programs: pmset for the helper, osascript and the installed helper for Theine. Tests put a stand-in here.
public protocol CommandRunning: Sendable {
    /// Runs the program by its full path and waits at most `timeout` seconds; nil when it could not start or took too
    /// long (then it is stopped).
    func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult?
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // The programs are named by their full paths; nothing from the caller's environment comes along.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let box = Box()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        if reading.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = reading.wait(timeout: .now() + 2)
            return nil
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: box.data, as: UTF8.self))
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }
}
