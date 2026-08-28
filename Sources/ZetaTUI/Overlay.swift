import Foundation

public enum OverlayAnchor: String, Sendable {
    case center
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case topCenter
    case bottomCenter
    case leftCenter
    case rightCenter
}

public struct OverlayOptions: Sendable {
    public var width: Int?
    public var maximumHeight: Int?
    public var anchor: OverlayAnchor
    public var offsetX: Int
    public var offsetY: Int
    public var margin: Int
    public var nonCapturing: Bool

    public init(
        width: Int? = nil,
        maximumHeight: Int? = nil,
        anchor: OverlayAnchor = .center,
        offsetX: Int = 0,
        offsetY: Int = 0,
        margin: Int = 1,
        nonCapturing: Bool = false
    ) {
        self.width = width
        self.maximumHeight = maximumHeight
        self.anchor = anchor
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.margin = margin
        self.nonCapturing = nonCapturing
    }
}

public final class OverlayHandle: @unchecked Sendable {
    public let id: UUID
    private let hideOperation: @Sendable (UUID) -> Void
    private let visibilityOperation: @Sendable (UUID, Bool) -> Void

    init(
        id: UUID,
        hide: @escaping @Sendable (UUID) -> Void,
        visibility: @escaping @Sendable (UUID, Bool) -> Void
    ) {
        self.id = id
        hideOperation = hide
        visibilityOperation = visibility
    }

    public func hide() { hideOperation(id) }
    public func setHidden(_ hidden: Bool) {
        visibilityOperation(id, hidden)
    }
}

public enum ClipboardEscape {
    public static func osc52(_ text: String) -> String {
        "\u{1B}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}"
    }

    public static func hyperlink(text: String, url: URL) -> String {
        "\u{1B}]8;;\(url.absoluteString)\u{07}\(text)\u{1B}]8;;\u{07}"
    }
}
