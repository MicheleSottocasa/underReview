import Foundation

public enum Parallel {
    /// Starts a task per item, in order, with at most `limit` running at once, and waits for all of them.
    /// `start` runs on the caller's actor, so it can record each task (to cancel it alone); cancelling the
    /// caller cancels every started task, and items not started yet are skipped.
    public static func run<Item>(_ items: [Item], limit: Int, isolation: isolated (any Actor)? = #isolation,
                                 start: (Item) -> Task<Void, Never>) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, item) in items.enumerated() {
                if index >= max(1, limit) { await group.next() }
                if Task.isCancelled { break }
                let task = start(item)
                group.addTask { await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() } }
            }
            await group.waitForAll()
        }
    }
}
