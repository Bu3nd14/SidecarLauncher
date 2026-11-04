import Darwin
import Foundation

public enum SingleInstanceResult: Sendable, Equatable {
    case acquired
    case alreadyRunning(pid: Int32)
    case failed(String)
}

public final class SingleInstance: @unchecked Sendable {
    public let lockPath: String
    private let directory: URL
    private var descriptor: Int32 = -1

    public init(directory: URL) {
        self.directory = directory
        self.lockPath = directory.appendingPathComponent("app.lock").path
    }

    deinit {
        release()
    }

    public func acquire() -> SingleInstanceResult {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return .failed("impossibile creare \(directory.path): \(error)")
            }
        }
        chmod(directory.path, 0o700)

        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return .failed("open \(lockPath) errno \(errno)")
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            let pid = readPID(fd: fd)
            close(fd)
            if code == EWOULDBLOCK { return .alreadyRunning(pid: pid) }
            return .failed("flock errno \(code)")
        }

        descriptor = fd
        chmod(lockPath, 0o600)
        ftruncate(fd, 0)
        let payload = "\(getpid())\n"
        _ = payload.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
        fsync(fd)
        return .acquired
    }

    private func readPID(fd: Int32) -> Int32 {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return 0 }
        let text = String(decoding: buffer[0..<count], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(text) ?? 0
    }

    public func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
