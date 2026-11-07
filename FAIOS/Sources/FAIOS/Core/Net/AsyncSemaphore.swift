import Foundation

/// 限制并发数的异步信号量。
///
/// iOS 15 的 Swift Concurrency 已经可用，但没有 `AsyncSemaphore`，
/// 而 `DispatchSemaphore` 不能跨 await（会阻塞整个线程，直接死锁）。
/// 这里用 continuation 实现：**名额在 release 时直接转交给等待者**，不经过 inFlight 的加减，避免竞态。
actor AsyncSemaphore {
    private let limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        // 被唤醒时名额已经记在我们头上，inFlight 不变
    }

    func release() {
        if waiters.isEmpty {
            inFlight = max(0, inFlight - 1)
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
