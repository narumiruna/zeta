import Foundation

actor RPCOutputWriter {
    func write(_ data: Data) {
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}
