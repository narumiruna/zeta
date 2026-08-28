import Foundation
import ZetaPluginAPI
import ZetaPluginSDK

@main
enum AllCapabilitiesPlugin {
    static func main() async throws {
        let callbacks = [
            PluginCallback(id: "tool.echo") { payload in payload },
            PluginCallback(id: "command.hello") { _ in Data("hello".utf8) },
            PluginCallback(id: "provider.stream") { payload in payload },
            PluginCallback(id: "flag.verbose") { payload in payload },
            PluginCallback(id: "event.input") { payload in payload },
            PluginCallback(id: "auth.sample") { payload in payload },
            PluginCallback(id: "resource.skills") { _ in Data("[]".utf8) },
            PluginCallback(id: "session.info") { payload in payload },
            PluginCallback(id: "ui.dialog") { _ in Data("accepted".utf8) },
        ]
        let registrations = [
            PluginRegistration(kind: .tool, name: "echo", callback: "tool.echo"),
            PluginRegistration(kind: .command, name: "hello", callback: "command.hello"),
            PluginRegistration(kind: .provider, name: "sample", callback: "provider.stream"),
            PluginRegistration(kind: .flag, name: "verbose", callback: "flag.verbose"),
            PluginRegistration(kind: .event, name: "input", callback: "event.input"),
            PluginRegistration(kind: .authentication, name: "sample", callback: "auth.sample"),
            PluginRegistration(kind: .resource, name: "skills", callback: "resource.skills"),
            PluginRegistration(kind: .session, name: "info", callback: "session.info"),
            PluginRegistration(kind: .ui, name: "dialog", callback: "ui.dialog"),
        ]
        try await PluginSDK.run(
            definition: PluginDefinition(
                registrations: registrations,
                callbacks: callbacks
            )
        )
    }
}
