import Foundation
import ZetaAI
import ZetaAgent
import ZetaCore
import ZetaPluginAPI

actor CLIPluginRuntime {
    private var hosts: [PluginHost] = []
    private var toolBindings: [(PluginRegistration, PluginHost)] = []

    func load(
        agentDirectory: URL,
        workingDirectory: URL,
        projectTrusted: Bool
    ) async -> [String] {
        await stop()
        var diagnostics: [String] = []
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
                    hosts.append(host)
                    for registration in await host.currentRegistrations() where registration.kind == .tool {
                        toolBindings.append((registration, host))
                    }
                } catch {
                    diagnostics.append("Swift plugin \(manifestURL.path): \(error.localizedDescription)")
                }
            }
        }
        return diagnostics
    }

    func tools() -> [AgentTool] {
        toolBindings.map { registration, host in
            AgentTool(
                definition: ToolDefinition(
                    name: registration.name,
                    description: "Swift plugin tool \(registration.name)",
                    parameters: [:]
                ),
                label: registration.name
            ) { _, arguments, _ in
                let payload = OrderedJSON.encode(arguments)
                let response = try await host.request(
                    method: registration.callback,
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
