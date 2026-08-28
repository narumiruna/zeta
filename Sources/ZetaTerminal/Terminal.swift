import Darwin
import Foundation

public protocol Terminal: AnyObject, Sendable {
    var columns: Int { get }
    var rows: Int { get }
    func start(onInput: @escaping @Sendable (Data) -> Void, onResize: @escaping @Sendable () -> Void) throws
    func stop()
    func write(_ data: Data)
}

public final class ProcessTerminal: Terminal, @unchecked Sendable {
    private static let activeLock = NSLock()
    private nonisolated(unsafe) static var active: [ObjectIdentifier: ProcessTerminal] = [:]

    public static func restoreActiveTerminals() {
        let terminals = activeLock.withLock { Array(active.values) }
        for terminal in terminals { terminal.stop() }
    }

    public var columns: Int { size().columns }
    public var rows: Int { size().rows }

    private let input: FileHandle
    private let output: FileHandle
    private var original = termios()
    private var started = false
    private var readSource: DispatchSourceRead?
    private var decoder = TerminalInputDecoder()
    private var escapeWorkItem: DispatchWorkItem?
    private var resizeSource: DispatchSourceSignal?
    private var previousWindowSignal: sig_t?

    public init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input
        self.output = output
    }

    public func start(onInput: @escaping @Sendable (Data) -> Void, onResize: @escaping @Sendable () -> Void) throws {
        guard !started else { return }
        let descriptor = input.fileDescriptor
        guard tcgetattr(descriptor, &original) == 0 else { throw POSIXError(.ENOTTY) }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(descriptor, TCSAFLUSH, &raw) == 0 else { throw POSIXError(.EIO) }
        started = true
        Self.activeLock.withLock { Self.active[ObjectIdentifier(self)] = self }
        write(Data("\u{1B}[?2004h\u{1B}[>7u\u{1B}[>4;2m".utf8))
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = self.input.availableData
            guard !data.isEmpty else { return }
            self.escapeWorkItem?.cancel()
            for sequence in self.decoder.push(data) {
                if !TerminalInputDecoder.isKeyRelease(sequence) {
                    onInput(sequence)
                }
            }
            if self.decoder.hasPendingEscape {
                let delay =
                    ProcessInfo.processInfo.environment["SSH_CONNECTION"] == nil
                    ? 0.01 : 0.1
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    for sequence in self.decoder.flushEscape() { onInput(sequence) }
                }
                self.escapeWorkItem = work
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
        source.resume()
        readSource = source
        previousWindowSignal = signal(SIGWINCH, SIG_IGN)
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        resize.setEventHandler(handler: onResize)
        resize.resume()
        resizeSource = resize
        onResize()
    }

    public func stop() {
        guard started else { return }
        escapeWorkItem?.cancel()
        escapeWorkItem = nil
        readSource?.cancel()
        readSource = nil
        resizeSource?.cancel()
        resizeSource = nil
        signal(SIGWINCH, previousWindowSignal ?? SIG_DFL)
        previousWindowSignal = nil
        decoder = TerminalInputDecoder()
        write(Data("\u{1B}[<u\u{1B}[>4m\u{1B}[?2004l\u{1B}[?25h".utf8))
        var value = original
        tcsetattr(input.fileDescriptor, TCSAFLUSH, &value)
        started = false
        Self.activeLock.withLock { Self.active[ObjectIdentifier(self)] = nil }
    }

    public func write(_ data: Data) {
        try? output.write(contentsOf: data)
    }

    deinit { stop() }

    private func size() -> (columns: Int, rows: Int) {
        var value = winsize()
        if ioctl(output.fileDescriptor, TIOCGWINSZ, &value) == 0 {
            return (max(1, Int(value.ws_col)), max(1, Int(value.ws_row)))
        }
        return (80, 24)
    }
}

public final class VirtualTerminal: Terminal, @unchecked Sendable {
    public let columns: Int
    public let rows: Int
    public private(set) var writes: [Data] = []
    private var inputHandler: (@Sendable (Data) -> Void)?

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = columns
        self.rows = rows
    }

    public func start(onInput: @escaping @Sendable (Data) -> Void, onResize: @escaping @Sendable () -> Void) throws {
        inputHandler = onInput
        onResize()
    }

    public func stop() { inputHandler = nil }
    public func write(_ data: Data) { writes.append(data) }
    public func send(_ value: String) { inputHandler?(Data(value.utf8)) }
    public var output: String { writes.map { String(decoding: $0, as: UTF8.self) }.joined() }
}
