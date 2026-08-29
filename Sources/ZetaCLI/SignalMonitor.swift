import Darwin
import Foundation
import ZetaPluginAPI
import ZetaTerminal

private nonisolated(unsafe) var terminationSignalWriteDescriptor: Int32 = -1

private func writeTerminationSignal(_ number: Int32) {
    var value = number
    if terminationSignalWriteDescriptor >= 0 {
        _ = Darwin.write(
            terminationSignalWriteDescriptor,
            &value,
            MemoryLayout<Int32>.size
        )
    }
}

final class TerminationSignalMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let readDescriptor: Int32
    private let writeDescriptor: Int32
    private let source: DispatchSourceRead
    private var continuation: CheckedContinuation<Int32, Never>?
    private var cancelled = false

    init() throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
        terminationSignalWriteDescriptor = writeDescriptor
        signal(SIGTERM, writeTerminationSignal)
        signal(SIGHUP, writeTerminationSignal)
        source = DispatchSource.makeReadSource(
            fileDescriptor: readDescriptor,
            queue: .global()
        )
        source.setEventHandler { [weak self] in self?.receive() }
        source.resume()
    }

    func wait() async -> Int32 {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Int32? = lock.withLock {
                    if cancelled { return 0 }
                    self.continuation = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let callback: CheckedContinuation<Int32, Never>? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            let value = continuation
            continuation = nil
            return value
        }
        callback?.resume(returning: 0)
        source.cancel()
        if terminationSignalWriteDescriptor == writeDescriptor {
            terminationSignalWriteDescriptor = -1
        }
        signal(SIGTERM, SIG_DFL)
        signal(SIGHUP, SIG_DFL)
        close(readDescriptor)
        close(writeDescriptor)
    }

    private func receive() {
        var signalNumber: Int32 = 0
        guard Darwin.read(readDescriptor, &signalNumber, MemoryLayout<Int32>.size) == MemoryLayout<Int32>.size else {
            return
        }
        let exitCode: Int32 = signalNumber == SIGTERM ? 143 : 129
        ProcessTerminal.restoreActiveTerminals()
        PluginHost.terminateActiveProcesses()
        Darwin._exit(exitCode)
    }

    deinit { cancel() }
}
