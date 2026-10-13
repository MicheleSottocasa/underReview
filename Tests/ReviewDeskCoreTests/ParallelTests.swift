import Foundation
import Testing
@testable import ReviewDeskCore

private actor Tracker {
    var running = 0, peak = 0, finished: [Int] = [], cancelled: [Int] = []
    func begin() { running += 1; peak = max(peak, running) }
    func end(_ item: Int, cancelled wasCancelled: Bool) {
        running -= 1
        if wasCancelled { cancelled.append(item) } else { finished.append(item) }
    }
}

@Test func runsEveryItemWithAtMostTheLimitAtOnce() async {
    let tracker = Tracker()
    await Parallel.run(Array(1...7), limit: 3) { item in
        Task {
            await tracker.begin()
            try? await Task.sleep(for: .milliseconds(30))
            await tracker.end(item, cancelled: false)
        }
    }
    #expect(await tracker.peak == 3)
    #expect(await tracker.finished.sorted() == Array(1...7))
}

@Test func cancellingTheCallerStopsRunningItemsAndSkipsTheRest() async throws {
    let tracker = Tracker()
    let started = LockedList()
    let caller = Task {
        await Parallel.run(Array(1...6), limit: 2) { item in
            started.append(item)
            return Task {
                await tracker.begin()
                let wasCancelled = (try? await Task.sleep(for: .seconds(5))) == nil
                await tracker.end(item, cancelled: wasCancelled)
            }
        }
    }
    try await Task.sleep(for: .milliseconds(100))
    caller.cancel()
    await caller.value
    #expect(started.value == [1, 2])                 // the rest never started
    #expect(await tracker.cancelled.sorted() == [1, 2]) // and the running ones were cancelled
}

@Test func oneItemCanBeCancelledAlone() async {
    let tracker = Tracker()
    let tasks = LockedTasks()
    await Parallel.run([1, 2], limit: 2) { item in
        let task = Task {
            await tracker.begin()
            let wasCancelled = (try? await Task.sleep(for: .milliseconds(item == 1 ? 5000 : 50))) == nil
            await tracker.end(item, cancelled: wasCancelled)
        }
        tasks.append(task)
        if item == 2 { tasks.first?.cancel() } // like Cancel on one row
        return task
    }
    #expect(await tracker.cancelled == [1])
    #expect(await tracker.finished == [2])
}

private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []
    var value: [Int] { lock.withLock { items } }
    func append(_ item: Int) { lock.withLock { items.append(item) } }
}

private final class LockedTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    var first: Task<Void, Never>? { lock.withLock { tasks.first } }
    func append(_ task: Task<Void, Never>) { lock.withLock { tasks.append(task) } }
}
