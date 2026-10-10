import Darwin
import Foundation

/// What the helper learns about processes. The system answers in `SystemProcesses`; tests give a list of their own.
public protocol ProcessTable {
    /// The PIDs of the processes running now.
    func pids() -> [pid_t]
    /// The executable and the user of a live process; nil when no process has this PID (a zombie counts as none).
    func process(_ pid: pid_t) -> (executable: String, uid: uid_t)?
}

/// The live processes, from the kernel: proc_pidinfo for the user and the state, proc_pidpath for the executable, the
/// file the process really runs, with links resolved. Root sees every process this way.
public struct SystemProcesses: ProcessTable {
    public init() {}

    public func pids() -> [pid_t] {
        // The list may grow between the two calls: room for more, and only what came back counts.
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return found > 0 ? Array(pids.prefix(Int(found))) : []
    }

    public func process(_ pid: pid_t) -> (executable: String, uid: uid_t)? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != UInt32(SZOMB) else { return nil }
        var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return (String(cString: path), info.pbi_uid)
    }
}

/// Theine's request to keep the Mac awake with the lid closed: a file in `Helper.requests` named after the user's uid,
/// holding the PID of the Theine that asks. Theine writes it while the mode with this option runs and removes it when the
/// mode ends or the app quits. A request whose Theine has died since no longer counts.
public enum HelperRequest {
    /// The largest file the helper reads: a PID and a line break take a dozen bytes.
    static let maximumSize = 32

    /// Theine's side. Puts the request in place whole (a hidden file renamed into place, so the helper never reads half
    /// of it); false when the folder is missing, which means there is no helper, or refuses the file. A request that
    /// already says the same is left alone, so the helper is not woken for nothing.
    @discardableResult
    public static func write(pid: pid_t = getpid(), uid: uid_t = getuid(), in folder: String = Helper.requests) -> Bool {
        let path = folder + "/\(uid)"
        if let present = read(path), present.pid == pid, present.owner == uid { return true }
        let temporary = folder + "/.\(uid).\(pid)"
        unlink(temporary)
        let file = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard file >= 0 else { return false }
        let text = Array("\(pid)\n".utf8)
        let written = text.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
        close(file)
        guard written == text.count, rename(temporary, path) == 0 else {
            unlink(temporary)
            return false
        }
        return true
    }

    /// Theine's side: the request goes, the helper notices at once.
    public static func remove(uid: uid_t = getuid(), in folder: String = Helper.requests) {
        unlink(folder + "/\(uid)")
    }

    /// The helper's side: the PIDs of the Theines asking now. The helper starts from the Theines that run, not from the
    /// folder, where anyone may put anything: for each one it opens only the file named after its user. The request
    /// counts when that file is a small plain file (no link, no folder, no pipe) of the same user, holding this very PID.
    /// With nothing in the folder there is nothing to look for, and the processes are not even listed.
    public static func live(in folder: String, processes: ProcessTable) -> [pid_t] {
        guard isOccupied(folder) else { return [] }
        return processes.pids().compactMap { pid in
            guard let process = processes.process(pid), Helper.isTheine(executable: process.executable),
                  let request = read(folder + "/\(process.uid)"), request.pid == pid, request.owner == process.uid else { return nil }
            return pid
        }
    }

    /// Something besides "." and ".." is in the folder; a look at its first entry is enough.
    static func isOccupied(_ folder: String) -> Bool {
        guard let directory = opendir(folder) else { return false }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            if name != ".", name != ".." { return true }
        }
        return false
    }

    /// The PID in a request and the file's owner; nil for anything but a small plain file with a number in it.
    static func read(_ path: String) -> (pid: pid_t, owner: uid_t)? {
        var before = stat()
        guard lstat(path, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size <= Int64(maximumSize) else { return nil }
        // No following a link put in its place meanwhile, and no waiting on a pipe.
        let file = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var opened = stat()
        guard fstat(file, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_ino == before.st_ino,
              opened.st_dev == before.st_dev else { return nil }
        var bytes = [UInt8](repeating: 0, count: maximumSize + 1)
        let count = Darwin.read(file, &bytes, bytes.count)
        guard count > 0, count <= maximumSize else { return nil }
        let text = String(decoding: bytes[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 10, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let pid = pid_t(text), pid > 1 else { return nil }
        return (pid, opened.st_uid)
    }
}
