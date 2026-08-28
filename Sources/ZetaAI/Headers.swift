import Foundation

public struct CaseInsensitiveHeaders: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        var originalName: String
        var value: String
    }

    private var values: [String: Entry] = [:]

    public init(_ headers: [String: String?] = [:]) {
        merge(headers)
    }

    public mutating func merge(_ headers: [String: String?]) {
        for (name, value) in headers {
            let key = name.lowercased()
            if let value {
                values[key] = Entry(originalName: name, value: value)
            } else {
                values[key] = nil
            }
        }
    }

    public subscript(_ name: String) -> String? {
        get { values[name.lowercased()]?.value }
        set {
            let key = name.lowercased()
            if let newValue {
                values[key] = Entry(originalName: name, value: newValue)
            } else {
                values[key] = nil
            }
        }
    }

    public var dictionary: [String: String] {
        Dictionary(
            uniqueKeysWithValues: values.values.map {
                ($0.originalName, $0.value)
            }
        )
    }
}

public typealias HeaderTransform =
    @Sendable (
        [String: String?]
    ) async throws -> [String: String?]
