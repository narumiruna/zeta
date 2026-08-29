import Foundation
import ZetaConfig

enum CLIProjectTrust {
    struct Resolution: Sendable, Equatable {
        let trusted: Bool
        let diagnostic: String?
    }

    typealias Selector = @Sendable (URL) async -> TrustDecision?

    static func resolve(
        directory: URL,
        store: TrustStore,
        override: Bool?,
        default defaultDecision: ProjectTrustDefault,
        projectResourcesPresent: Bool,
        supportsInteractiveSelection: Bool,
        selector: Selector
    ) async throws -> Resolution {
        if let override {
            try await store.set(override ? .trusted : .denied, for: directory)
            return Resolution(trusted: override, diagnostic: nil)
        }
        guard projectResourcesPresent else {
            return Resolution(trusted: true, diagnostic: nil)
        }
        if let stored = await store.decision(for: directory) {
            return Resolution(trusted: stored == .trusted, diagnostic: nil)
        }
        switch defaultDecision {
        case .always:
            return Resolution(trusted: true, diagnostic: nil)
        case .never:
            return Resolution(trusted: false, diagnostic: nil)
        case .ask:
            break
        }
        guard supportsInteractiveSelection else {
            return Resolution(trusted: false, diagnostic: noninteractiveDiagnostic)
        }
        guard let selected = await selector(directory) else {
            return Resolution(
                trusted: false,
                diagnostic: "No project trust decision was selected; project resources are disabled."
            )
        }
        try await store.set(selected, for: directory)
        return Resolution(trusted: selected == .trusted, diagnostic: nil)
    }

    static func hasTrustRequiringResources(in directory: URL) -> Bool {
        let config = directory.standardizedFileURL.appendingPathComponent(".pi")
        let entries = [
            "settings.json", "extensions", "skills", "prompts", "themes", "packages", "plugins",
            "SYSTEM.md", "APPEND_SYSTEM.md",
        ]
        return entries.contains {
            FileManager.default.fileExists(atPath: config.appendingPathComponent($0).path)
        }
    }

    private static let noninteractiveDiagnostic =
        "Project trust is undecided in noninteractive mode; project resources are disabled. "
        + "Re-run interactively to choose, pass --approve to trust this project, "
        + "or set defaultProjectTrust to \"always\"."
}

enum CLITrustPrompt {
    static func select(directory: URL) -> TrustDecision? {
        let prompt = """
            Trust project folder?
            \(directory.standardizedFileURL.path)

            This allows Zeta to load project settings, resources, packages, and Swift plugins.
              1. Trust this project
              2. Do not trust this project
            Selection [2]:
            """
        while true {
            FileHandle.standardError.write(Data("\(prompt) ".utf8))
            guard let response = readLine() else { return nil }
            switch response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "trust", "yes", "y":
                return .trusted
            case "", "2", "deny", "no", "n":
                return .denied
            default:
                FileHandle.standardError.write(
                    Data("Invalid selection; enter 1 to trust or 2 to deny.\n".utf8)
                )
            }
        }
    }
}
