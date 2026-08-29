import Darwin
import Foundation

enum ToolProcessLifecycle {
    static func prepare(_ process: Process) {
        _ = setpgid(process.processIdentifier, process.processIdentifier)
    }

    static func terminate(_ process: Process, closing handles: [FileHandle] = []) {
        for handle in handles {
            try? handle.close()
        }
        let identifier = process.processIdentifier
        guard identifier > 0 else { return }
        signalTree(identifier, signal: SIGTERM)
        signalTree(identifier, signal: SIGKILL)
    }

    private static func signalTree(_ identifier: pid_t, signal: Int32) {
        let descendants = descendants(of: identifier)
        _ = kill(-identifier, signal)
        for child in descendants.reversed() {
            _ = kill(child, signal)
        }
        _ = kill(identifier, signal)
    }

    private static func descendants(of identifier: pid_t) -> [pid_t] {
        let count = proc_listchildpids(identifier, nil, 0)
        guard count > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: Int(count))
        let actualCount = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(identifier, buffer.baseAddress, Int32(buffer.count))
        }
        guard actualCount > 0 else { return [] }
        children.removeSubrange(min(Int(actualCount), children.count)..<children.count)
        return children.filter { $0 > 0 }.flatMap { child in descendants(of: child) + [child] }
    }
}
