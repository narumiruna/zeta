import Darwin
import Foundation
import ZetaClient
import ZetaUnixTransport

@main
enum InteropClient {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: zeta-interop-client <socket>\n".utf8))
            exit(2)
        }
        do {
            let client = try PiClient(
                transportFactory: createUnixTransportFactory(
                    path: CommandLine.arguments[1]
                )
            )
            try await client.connect()
            let sessions = try await client.listSessions()
            print("{\"sessions\":\(sessions.count)}")
            await client.dispose()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
