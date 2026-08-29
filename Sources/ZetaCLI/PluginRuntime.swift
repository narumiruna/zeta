import Foundation
import ZetaAI
import ZetaAgent
import ZetaCore
import ZetaPluginAPI

actor CLIPluginRuntime {
    private struct ToolBinding: Sendable {
        let registration: PluginRegistration
        let host: PluginHost
        let schema: PluginToolSchema?
    }

    private var hosts: [PluginHost] = []
    private var toolBindings: [ToolBinding] = []

    func load(
        agentDirectory: URL,
        workingDirectory: URL,
        projectTrusted: Bool
    ) async -> [String] {
        await stop()
        var diagnostics: [String] = []
        var loadedHosts: [PluginHost] = []
        var loadedBindings: [ToolBinding] = []
        var registeredToolNames = Set(BuiltinToolSchemas.values.keys)
        let roots = [
            (agentDirectory.appendingPathComponent("plugins"), true),
            (workingDirectory.appendingPathComponent(".pi/plugins"), projectTrusted),
        ]
        for (root, trusted) in roots {
            for manifestURL in Self.manifests(in: root) {
                do {
                    let manifest = try JSONDecoder().decode(
                        PluginManifest.self,
                        from: Data(contentsOf: manifestURL)
                    )
                    let host = PluginHost()
                    try await host.start(
                        manifest: manifest,
                        baseDirectory: manifestURL.deletingLastPathComponent(),
                        trusted: trusted
                    )
                    let registrations = await host.currentRegistrations()
                    let unsupported = registrations.filter { $0.kind != .tool }
                    guard unsupported.isEmpty else {
                        await host.stop()
                        throw CLIPluginRuntimeError.unsupportedRegistrations(
                            unsupported.map { $0.kind.rawValue }
                        )
                    }
                    let bindings: [ToolBinding]
                    var candidateNames = registeredToolNames
                    do {
                        for registration in registrations {
                            guard candidateNames.insert(registration.name).inserted else {
                                throw CLIPluginRuntimeError.duplicateToolName(registration.name)
                            }
                        }
                        bindings = try registrations.map { registration in
                            ToolBinding(
                                registration: registration,
                                host: host,
                                schema: try registration.schema.map(PluginToolSchema.init(data:))
                            )
                        }
                    } catch {
                        await host.stop()
                        throw error
                    }
                    loadedHosts.append(host)
                    loadedBindings.append(contentsOf: bindings)
                    registeredToolNames = candidateNames
                } catch {
                    diagnostics.append("Swift plugin \(manifestURL.path): \(error.localizedDescription)")
                }
            }
        }
        hosts = loadedHosts
        toolBindings = loadedBindings
        return diagnostics
    }

    func tools() -> [AgentTool] {
        toolBindings.map { binding in
            AgentTool(
                definition: ToolDefinition(
                    name: binding.registration.name,
                    description: "Swift plugin tool \(binding.registration.name)",
                    parameters: binding.schema?.definition ?? [:]
                ),
                label: binding.registration.name,
                parameterSchema: binding.schema?.validator
            ) { _, arguments, _ in
                let payload = OrderedJSON.encode(arguments)
                let response = try await binding.host.request(
                    method: binding.registration.callback,
                    payload: payload
                )
                if let value = try? OrderedJSON.decode(response),
                    case .array(let blocks) = value
                {
                    let content = blocks.compactMap { block -> ContentBlock? in
                        guard case .object(let object) = block,
                            case .string(let type)? = object["type"],
                            type == "text",
                            case .string(let text)? = object["text"]
                        else { return nil }
                        return .text(text: text)
                    }
                    if !content.isEmpty { return AgentToolResult(content: content) }
                }
                return AgentToolResult(
                    content: [.text(text: String(decoding: response, as: UTF8.self))]
                )
            }
        }
    }

    func stop() async {
        let current = hosts
        hosts = []
        toolBindings = []
        for host in current { await host.stop() }
    }

    private static func manifests(in root: URL) -> [URL] {
        var output: [URL] = []
        let direct = root.appendingPathComponent("zeta-plugin.json")
        if FileManager.default.fileExists(atPath: direct.path) { output.append(direct) }
        for child
            in (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
        {
            let candidate = child.appendingPathComponent("zeta-plugin.json")
            if FileManager.default.fileExists(atPath: candidate.path) { output.append(candidate) }
        }
        return output.sorted { $0.path < $1.path }
    }
}

private enum CLIPluginRuntimeError: LocalizedError {
    case duplicateToolName(String)
    case unsupportedRegistrations([String])

    var errorDescription: String? {
        switch self {
        case .duplicateToolName(let name):
            return "Plugin tool name collides with another plugin or built-in tool: \(name)"
        case .unsupportedRegistrations(let kinds):
            let names = Array(Set(kinds)).sorted().joined(separator: ", ")
            return
                "Unsupported registration kinds: \(names). The Zeta CLI currently wires only tool registrations; remove the unsupported registrations or run them through a host that implements those capabilities."
        }
    }
}
