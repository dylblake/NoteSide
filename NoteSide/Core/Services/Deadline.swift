import Foundation

/// Bounded waiting on work that must not hold up the UI. The task keeps
/// running after the deadline so the caller can still apply its result
/// later.
nonisolated enum Deadline {
    /// The task's value if it finishes before `instant`, otherwise nil.
    static func value<T: Sendable>(of task: Task<T, Never>, until instant: ContinuousClock.Instant) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(until: instant, clock: .continuous)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
