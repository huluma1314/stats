//
//  export.swift
//  Net
//

import Foundation

public enum TrafficExportFormat: String {
    case csv
    case json
}

public enum TrafficExportError: Error, Equatable {
    case encodingFailed
    case writeFailed
}

public struct TrafficExportDocument: Codable, Equatable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let range: String
    public let start: Date
    public let end: Date
    public let networkFilter: String?
    public let download: UInt64
    public let upload: UInt64
    public let total: UInt64
    public let applications: [TrafficExportApplication]

    public init(snapshot: TrafficAnalyticsSnapshot, networkFilter: NetworkKind?) {
        self.schemaVersion = 1
        self.exportedAt = Date()
        self.range = snapshot.range.rawValue
        self.start = snapshot.start
        self.end = snapshot.end
        self.networkFilter = networkFilter?.rawValue
        self.download = snapshot.download
        self.upload = snapshot.upload
        self.total = snapshot.total
        self.applications = snapshot.ranking.map(TrafficExportApplication.init)
    }
}

public struct TrafficExportApplication: Codable, Equatable {
    public let name: String
    public let bundleIdentifier: String?
    public let executablePath: String?
    public let download: UInt64
    public let upload: UInt64
    public let peakBytesPerSecond: UInt64
    public let total: UInt64

    public init(_ summary: ApplicationTrafficSummary) {
        self.name = summary.identity.displayName
        self.bundleIdentifier = summary.identity.bundleIdentifier
        self.executablePath = summary.identity.executablePath
        self.download = summary.download
        self.upload = summary.upload
        self.peakBytesPerSecond = summary.peakBytesPerSecond
        self.total = summary.total
    }
}

public enum TrafficExporter {
    public static func csv(from snapshot: TrafficAnalyticsSnapshot, networkFilter: NetworkKind?) -> String {
        var rows = [
            "schema_version,range,start,end,network_filter,application,bundle_id,executable_path,download,upload,peak_bps,total"
        ]
        let formatter = ISO8601DateFormatter()
        let network = networkFilter?.rawValue ?? ""
        for app in snapshot.ranking {
            rows.append([
                "1",
                snapshot.range.rawValue,
                formatter.string(from: snapshot.start),
                formatter.string(from: snapshot.end),
                Self.csvEscape(network),
                Self.csvEscape(app.identity.displayName),
                Self.csvEscape(app.identity.bundleIdentifier ?? ""),
                Self.csvEscape(app.identity.executablePath ?? ""),
                "\(app.download)",
                "\(app.upload)",
                "\(app.peakBytesPerSecond)",
                "\(app.total)"
            ].joined(separator: ","))
        }
        if snapshot.ranking.isEmpty {
            rows.append([
                "1",
                snapshot.range.rawValue,
                formatter.string(from: snapshot.start),
                formatter.string(from: snapshot.end),
                Self.csvEscape(network),
                "",
                "",
                "",
                "\(snapshot.download)",
                "\(snapshot.upload)",
                "0",
                "\(snapshot.total)"
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    public static func json(from snapshot: TrafficAnalyticsSnapshot, networkFilter: NetworkKind?) throws -> Data {
        let document = TrafficExportDocument(snapshot: snapshot, networkFilter: networkFilter)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    public static func write(
        snapshot: TrafficAnalyticsSnapshot,
        networkFilter: NetworkKind?,
        format: TrafficExportFormat,
        to url: URL
    ) throws {
        let data: Data
        switch format {
        case .csv:
            guard let encoded = self.csv(from: snapshot, networkFilter: networkFilter).data(using: .utf8) else {
                throw TrafficExportError.encodingFailed
            }
            data = encoded
        case .json:
            data = try self.json(from: snapshot, networkFilter: networkFilter)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw TrafficExportError.writeFailed
        }
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
