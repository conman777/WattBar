import Foundation
import Darwin

final class InstanceLock {
    private let fd: Int32

    init?(name: String) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("WattBar", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let lockPath = directory.appendingPathComponent("\(name).lock").path
        fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

