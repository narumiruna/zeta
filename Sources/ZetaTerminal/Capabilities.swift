import Foundation

public enum InlineImageProtocol: String, Codable, Sendable {
    case kitty
    case iterm
    case none
}

public struct TerminalCapabilities: Codable, Sendable, Equatable {
    public var hyperlinks: Bool
    public var trueColor: Bool
    public var imageProtocol: InlineImageProtocol
    public var kittyKeyboard: Bool
    public var synchronizedOutput: Bool

    public init(
        hyperlinks: Bool,
        trueColor: Bool,
        imageProtocol: InlineImageProtocol,
        kittyKeyboard: Bool,
        synchronizedOutput: Bool = true
    ) {
        self.hyperlinks = hyperlinks
        self.trueColor = trueColor
        self.imageProtocol = imageProtocol
        self.kittyKeyboard = kittyKeyboard
        self.synchronizedOutput = synchronizedOutput
    }

    public static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalCapabilities {
        let program = environment["TERM_PROGRAM"]?.lowercased() ?? ""
        let term = environment["TERM"]?.lowercased() ?? ""
        let inMultiplexer = environment["TMUX"] != nil || term.hasPrefix("screen")
        let kitty =
            environment["KITTY_WINDOW_ID"] != nil
            || program.contains("ghostty")
            || program.contains("wezterm")
        let iterm = program.contains("iterm")
        var image: InlineImageProtocol =
            kitty && !inMultiplexer
            ? .kitty
            : iterm && !inMultiplexer ? .iterm : .none
        if let override = environment["PI_IMAGE_PROTOCOL"],
            let value = InlineImageProtocol(rawValue: override.lowercased())
        {
            image = value
        }
        let trueColor = booleanOverride(
            environment["PI_TRUE_COLOR"],
            fallback: environment["COLORTERM"]?.lowercased().contains("truecolor") == true
                || program.contains("iterm") || kitty
        )
        let hyperlinks = booleanOverride(
            environment["PI_HYPERLINKS"],
            fallback: !term.contains("dumb")
        )
        return TerminalCapabilities(
            hyperlinks: hyperlinks,
            trueColor: trueColor,
            imageProtocol: image,
            kittyKeyboard: kitty
        )
    }

    private static func booleanOverride(
        _ value: String?,
        fallback: Bool
    ) -> Bool {
        guard let value else { return fallback }
        switch value.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return fallback
        }
    }
}
