import Foundation

// Serializes whole-archive writes off the main actor. Streaming checkpoints
// coalesce to the newest snapshot; critical saves wait for any in-flight
// checkpoint before writing, so an older snapshot can never win the race.
final class ArchiveWriter {
    private let destination: URL
    private let queue = DispatchQueue(label: "keel.archive-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: SavedTasks?
    private var writing = false
    private var storedError: Error?

    init(destination: URL) {
        self.destination = destination
    }

    @discardableResult
    func writeNow(_ archive: SavedTasks) -> Bool {
        // Discard a queued checkpoint; wait for one already in flight, then
        // write this newer snapshot before returning to the caller. Hold the
        // writing flag so a checkpoint arriving mid-write is queued after it
        // instead of racing an older snapshot over this one.
        lock.lock(); pending = nil; writing = true; lock.unlock()
        var ok = false
        queue.sync {
            do {
                try archive.write(to: destination)
                ok = true
            } catch {
                lock.lock(); storedError = error; lock.unlock()
                ok = false
            }
        }
        lock.lock()
        writing = false
        let next = pending
        if next != nil { writing = true }
        lock.unlock()
        if next != nil { queue.async { [weak self] in self?.drain() } }
        return ok
    }

    func writeCheckpoint(_ archive: SavedTasks) {
        lock.lock()
        pending = archive
        let start = !writing
        if start { writing = true }
        lock.unlock()
        guard start else { return }
        queue.async { [weak self] in self?.drain() }
    }

    // Wait for any queued/in-flight checkpoint. Tests and foreground exits use
    // this so a relaunch cannot reopen an older archive.
    func flush() {
        queue.sync { }
    }

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return storedError
    }

    private func drain() {
        while true {
            lock.lock()
            guard let archive = pending else {
                writing = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            do {
                try archive.write(to: destination)
            } catch {
                lock.lock(); storedError = error; lock.unlock()
            }
        }
    }
}
