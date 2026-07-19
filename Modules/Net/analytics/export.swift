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
    case inconsistentTotals
}

public struct TrafficExportContext: Equatable {
    public let networkID: String?
    public let networkAlias: String?
    public let network: NetworkIdentity?
    public let chartInterval: DateInterval?
    public let groupByProcess: Bool
    public let routeContext: TrafficRouteContext?

    public init(
        networkID: String? = nil,
        networkAlias: String? = nil,
        network: NetworkIdentity? = nil,
        chartInterval: DateInterval? = nil,
        groupByProcess: Bool = false,
        routeContext: TrafficRouteContext? = nil
    ) {
        self.networkID = networkID
        self.networkAlias = networkAlias
        self.network = network
        self.chartInterval = chartInterval
        self.groupByProcess = groupByProcess
        self.routeContext = routeContext
    }
}

public struct TrafficExportDocument: Codable, Equatable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let range: String
    public let start: Date
    public let end: Date
    public let selectedIntervalStart: Date?
    public let selectedIntervalEnd: Date?
    public let networkFilter: String?
    public let networkID: String?
    public let networkAlias: String?
    public let networkKind: String?
    public let networkInterface: String?
    public let groupingMode: String
    public let routeContext: TrafficRouteContext?
    public let download: UInt64
    public let upload: UInt64
    public let total: UInt64
    public let sampleCount: Int
    public let applications: [TrafficExportApplication]
    public let alerts: [TrafficExportAlert]

    public init(
        snapshot: TrafficAnalyticsSnapshot,
        networkFilter: NetworkKind?,
        context: TrafficExportContext = TrafficExportContext(),
        exportedAt: Date = Date()
    ) {
        self.schemaVersion = 2
        self.exportedAt = exportedAt
        self.range = snapshot.range.rawValue
        self.start = snapshot.start
        self.end = snapshot.end
        self.selectedIntervalStart = context.chartInterval?.start
        self.selectedIntervalEnd = context.chartInterval?.end
        self.networkFilter = networkFilter?.rawValue
        self.networkID = context.networkID ?? context.network?.id
        self.networkAlias = context.networkAlias
        self.networkKind = context.network?.kind.rawValue
        self.networkInterface = context.network?.interfaceName
        let exportsProcesses = TrafficExporter.canExportProcesses(snapshot: snapshot, requested: context.groupByProcess)
        self.groupingMode = exportsProcesses ? "process" : "application"
        self.routeContext = context.routeContext
        self.download = snapshot.download
        self.upload = snapshot.upload
        self.total = snapshot.total
        self.sampleCount = snapshot.buckets.reduce(0) { $0 + $1.sampleCount }
        self.applications = snapshot.ranking.map {
            TrafficExportApplication($0, includeProcesses: exportsProcesses, routeContext: context.routeContext)
        }
        self.alerts = snapshot.alerts.map(TrafficExportAlert.init)
    }
}

public struct TrafficExportApplication: Codable, Equatable {
    public let name: String
    public let bundleIdentifier: String?
    public let executablePath: String?
    public let routeContext: TrafficRouteContext?
    public let download: UInt64
    public let upload: UInt64
    public let peakBytesPerSecond: UInt64
    public let total: UInt64
    public let sampleCount: Int?
    public let processes: [TrafficExportProcess]

    public init(
        _ summary: ApplicationTrafficSummary,
        includeProcesses: Bool = false,
        routeContext: TrafficRouteContext? = nil
    ) {
        self.name = summary.identity.displayName
        self.bundleIdentifier = summary.identity.bundleIdentifier
        self.executablePath = summary.identity.executablePath
        self.routeContext = routeContext ?? (summary.routeContexts.count == 1 ? summary.routeContexts.first : nil)
        self.download = summary.download
        self.upload = summary.upload
        self.peakBytesPerSecond = summary.peakBytesPerSecond
        self.total = summary.total
        self.sampleCount = summary.sampleCount
        self.processes = includeProcesses ? summary.processes.map(TrafficExportProcess.init) : []
    }
}

public struct TrafficExportProcess: Codable, Equatable {
    public let processDiscriminator: String?
    public let processID: Int32
    public let processName: String
    public let bundleIdentifier: String?
    public let executablePath: String?
    public let download: UInt64
    public let upload: UInt64
    public let peakBytesPerSecond: UInt64
    public let total: UInt64
    public let sampleCount: Int?

    public init(_ summary: ProcessTrafficSummary) {
        self.processDiscriminator = summary.processDiscriminator
        self.processID = summary.processID
        self.processName = summary.processName
        self.bundleIdentifier = summary.identity?.bundleIdentifier
        self.executablePath = summary.identity?.executablePath
        self.download = summary.download
        self.upload = summary.upload
        self.peakBytesPerSecond = summary.peakBytesPerSecond
        self.total = summary.download + summary.upload
        self.sampleCount = summary.sampleCount
    }
}

public struct TrafficExportAlert: Codable, Equatable {
    public let id: String
    public let kind: String
    public let timestamp: Date
    public let severity: String
    public let message: String

    public init(_ event: TrafficAlertEvent) {
        self.id = event.id
        self.kind = event.kind.rawValue
        self.timestamp = event.timestamp
        self.severity = event.severity.rawValue
        self.message = event.message
    }
}

public enum TrafficExporter {
    private static let csvHeader = "schema_version,exported_at,range,start,end,selected_start,selected_end,network_filter,network_id,network_alias,network_kind,network_interface,grouping_mode,route_kind,proxy_host,proxy_port,row_type,application,bundle_id,executable_path,process_id,process_name,download,upload,peak_bps,total,sample_count,alert_ids,alert_kinds,alert_timestamps"

    public static func csv(
        from snapshot: TrafficAnalyticsSnapshot,
        networkFilter: NetworkKind?,
        context: TrafficExportContext = TrafficExportContext(),
        exportedAt: Date = Date()
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let alertIDs = snapshot.alerts.map(\.id).joined(separator: "|")
        let alertKinds = snapshot.alerts.map { $0.kind.rawValue }.joined(separator: "|")
        let alertTimestamps = snapshot.alerts.map { formatter.string(from: $0.timestamp) }.joined(separator: "|")
        let exportsProcesses = self.canExportProcesses(snapshot: snapshot, requested: context.groupByProcess)
        let prefix: [String] = [
            "2", formatter.string(from: exportedAt), snapshot.range.rawValue,
            formatter.string(from: snapshot.start), formatter.string(from: snapshot.end),
            context.chartInterval.map { formatter.string(from: $0.start) } ?? "",
            context.chartInterval.map { formatter.string(from: $0.end) } ?? "",
            networkFilter?.rawValue ?? "", context.networkID ?? context.network?.id ?? "",
            context.networkAlias ?? "", context.network?.kind.rawValue ?? "",
            context.network?.interfaceName ?? "", exportsProcesses ? "process" : "application"
        ]
        var rows = [self.csvHeader]
        for app in snapshot.ranking {
            let route = context.routeContext ?? (app.routeContexts.count == 1 ? app.routeContexts.first : nil)
            let routeColumns = [
                route?.kind.rawValue ?? "", route?.proxyHost ?? "", route?.proxyPort.map(String.init) ?? ""
            ]
            if exportsProcesses, !app.processes.isEmpty {
                for process in app.processes {
                    rows.append(self.csvRow(prefix + routeColumns + [
                        "process", app.identity.displayName,
                        process.identity?.bundleIdentifier ?? app.identity.bundleIdentifier ?? "",
                        process.identity?.executablePath ?? app.identity.executablePath ?? "",
                        String(process.processID), process.processName,
                        String(process.download), String(process.upload), String(process.peakBytesPerSecond),
                        String(process.download + process.upload), process.sampleCount.map(String.init) ?? "", alertIDs, alertKinds, alertTimestamps
                    ]))
                }
            } else {
                rows.append(self.csvRow(prefix + routeColumns + [
                    "application", app.identity.displayName, app.identity.bundleIdentifier ?? "",
                    app.identity.executablePath ?? "", "", "", String(app.download), String(app.upload),
                    String(app.peakBytesPerSecond), String(app.total), app.sampleCount.map(String.init) ?? "", alertIDs, alertKinds, alertTimestamps
                ]))
            }
        }
        if snapshot.ranking.isEmpty {
            let routeColumns = [
                context.routeContext?.kind.rawValue ?? "", context.routeContext?.proxyHost ?? "",
                context.routeContext?.proxyPort.map(String.init) ?? ""
            ]
            rows.append(self.csvRow(prefix + routeColumns + [
                "total", "", "", "", "", "", String(snapshot.download), String(snapshot.upload), "0",
                String(snapshot.total), String(snapshot.buckets.reduce(0) { $0 + $1.sampleCount }),
                alertIDs, alertKinds, alertTimestamps
            ]))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    public static func json(
        from snapshot: TrafficAnalyticsSnapshot,
        networkFilter: NetworkKind?,
        context: TrafficExportContext = TrafficExportContext()
    ) throws -> Data {
        let document = TrafficExportDocument(snapshot: snapshot, networkFilter: networkFilter, context: context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    public static func write(
        snapshot: TrafficAnalyticsSnapshot,
        networkFilter: NetworkKind?,
        context: TrafficExportContext = TrafficExportContext(),
        format: TrafficExportFormat,
        to url: URL
    ) throws {
        let data: Data
        switch format {
        case .csv:
            guard let encoded = self.csv(from: snapshot, networkFilter: networkFilter, context: context).data(using: .utf8) else {
                throw TrafficExportError.encodingFailed
            }
            data = encoded
        case .json:
            data = try self.json(from: snapshot, networkFilter: networkFilter, context: context)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw TrafficExportError.writeFailed
        }
    }

    private static func csvRow(_ values: [String]) -> String {
        values.map(self.csvEscape).joined(separator: ",")
    }

    fileprivate static func canExportProcesses(snapshot: TrafficAnalyticsSnapshot, requested: Bool) -> Bool {
        guard requested else { return false }
        return snapshot.ranking.allSatisfy { app in
            guard !app.processes.isEmpty else { return true }
            return app.processes.reduce(UInt64(0)) { $0 + $1.download } == app.download
                && app.processes.reduce(UInt64(0)) { $0 + $1.upload } == app.upload
        }
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
