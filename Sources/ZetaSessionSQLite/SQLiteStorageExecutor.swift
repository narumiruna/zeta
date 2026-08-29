import Dispatch

final class SQLiteStorageExecutor: SerialExecutor, @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    init() {
        queue = DispatchQueue(
            label: "works.earendil.zeta.session-sqlite.storage",
            qos: .utility
        )
        queue.setSpecific(key: queueKey, value: 1)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            unownedJob.runSynchronously(on: executor)
        }
    }

    var isCurrent: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }
}
