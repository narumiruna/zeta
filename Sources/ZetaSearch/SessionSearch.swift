import Foundation

public struct SearchDocument: Sendable, Equatable {
    public var sessionID: String
    public var entryID: String
    public var entryType: String
    public var timestamp: Int64?
    public var text: String
    public var label: String?

    public init(
        sessionID: String,
        entryID: String,
        entryType: String,
        timestamp: Int64? = nil,
        text: String,
        label: String? = nil
    ) {
        self.sessionID = sessionID
        self.entryID = entryID
        self.entryType = entryType
        self.timestamp = timestamp
        self.text = text
        self.label = label
    }
}

public struct SessionSearchHit: Sendable, Equatable {
    public var sessionID: String
    public var entryID: String
    public var entryType: String
    public var timestamp: Int64?
    public var snippet: String
    public var label: String?
}

public struct SessionSearchOptions: Sendable {
    public var entryTypes: Set<String>?
    public var limit: Int
    public var snippetCharacters: Int

    public init(
        entryTypes: Set<String>? = nil,
        limit: Int = 100,
        snippetCharacters: Int = 160
    ) {
        self.entryTypes = entryTypes
        self.limit = limit
        self.snippetCharacters = snippetCharacters
    }
}

public enum SessionSearchError: Error, Sendable {
    case duplicateSessionID(String)
}

public enum SessionSearch {
    public static func scan<Sources: AsyncSequence>(
        _ sources: Sources,
        query: String,
        options: SessionSearchOptions = SessionSearchOptions()
    ) -> AsyncThrowingStream<SessionSearchHit, Error>
    where
        Sources: Sendable,
        Sources.AsyncIterator: Sendable,
        Sources.Element == (sessionID: String, documents: [SearchDocument])
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !needle.isEmpty,
                        options.limit > 0,
                        options.entryTypes?.isEmpty != true
                    else {
                        continuation.finish()
                        return
                    }
                    var seen = Set<String>()
                    var emitted = 0
                    for try await source in sources {
                        try Task.checkCancellation()
                        guard seen.insert(source.sessionID).inserted else {
                            throw SessionSearchError.duplicateSessionID(source.sessionID)
                        }
                        for document in source.documents {
                            try Task.checkCancellation()
                            guard options.entryTypes?.contains(document.entryType) ?? true
                            else {
                                continue
                            }
                            let haystack = document.text + "\n" + (document.label ?? "")
                            guard let range = haystack.range(of: needle, options: .caseInsensitive)
                            else {
                                continue
                            }
                            let offset = haystack.distance(
                                from: haystack.startIndex,
                                to: range.lowerBound
                            )
                            let lower = max(0, offset - options.snippetCharacters / 2)
                            let upper = min(
                                haystack.count,
                                lower + options.snippetCharacters
                            )
                            let start = haystack.index(haystack.startIndex, offsetBy: lower)
                            let end = haystack.index(haystack.startIndex, offsetBy: upper)
                            continuation.yield(
                                SessionSearchHit(
                                    sessionID: document.sessionID,
                                    entryID: document.entryID,
                                    entryType: document.entryType,
                                    timestamp: document.timestamp,
                                    snippet: String(haystack[start..<end]),
                                    label: document.label
                                )
                            )
                            emitted += 1
                            if emitted == options.limit {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func jsonLineDocuments(
        sessionID: String,
        data: Data
    ) -> [SearchDocument] {
        data.split(separator: 0x0A).compactMap { line in
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                let id = object["id"] as? String,
                let type = object["type"] as? String,
                type != "session"
            else {
                return nil
            }
            let textData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            return SearchDocument(
                sessionID: sessionID,
                entryID: id,
                entryType: type,
                text: textData.map { String(decoding: $0, as: UTF8.self) } ?? ""
            )
        }
    }
}

public struct ArraySearchSources: AsyncSequence, Sendable {
    public typealias Element = (sessionID: String, documents: [SearchDocument])
    private let values: [Element]

    public init(_ values: [Element]) { self.values = values }

    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        var values: [Element]
        mutating public func next() async -> Element? {
            values.isEmpty ? nil : values.removeFirst()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(values: values)
    }
}
