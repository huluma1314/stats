//
//  models.swift
//  Net
//

import Foundation

public struct ApplicationIdentity: Codable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let bundleIdentifier: String?
    public let executablePath: String?

    public init(
        id: String,
        displayName: String,
        bundleIdentifier: String?,
        executablePath: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
    }
}

public struct ProcessTrafficCounter: Codable, Equatable {
    public let identity: ApplicationIdentity
    public let processID: Int32
    public let processStartToken: UInt64
    public let download: UInt64
    public let upload: UInt64

    public init(
        identity: ApplicationIdentity,
        processID: Int32,
        processStartToken: UInt64,
        download: UInt64,
        upload: UInt64
    ) {
        self.identity = identity
        self.processID = processID
        self.processStartToken = processStartToken
        self.download = download
        self.upload = upload
    }
}

public struct TrafficDelta: Codable, Equatable {
    public static let zero = TrafficDelta(download: 0, upload: 0)

    public let download: UInt64
    public let upload: UInt64
    public var total: UInt64 { self.download + self.upload }

    public init(download: UInt64, upload: UInt64) {
        self.download = download
        self.upload = upload
    }
}

public enum NetworkKind: String, Codable, CaseIterable {
    case wifi
    case ethernet
    case hotspot
    case tunnel
    case other
}

public struct NetworkIdentity: Codable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let interfaceName: String
    public let kind: NetworkKind

    public init(id: String, displayName: String, interfaceName: String, kind: NetworkKind) {
        self.id = id
        self.displayName = displayName
        self.interfaceName = interfaceName
        self.kind = kind
    }
}

public struct TrafficSample: Codable, Equatable {
    public let timestamp: Date
    public let application: ApplicationIdentity
    public let network: NetworkIdentity
    public let processID: Int32
    public let delta: TrafficDelta
    public let peakBytesPerSecond: UInt64

    public init(
        timestamp: Date,
        application: ApplicationIdentity,
        network: NetworkIdentity,
        processID: Int32,
        delta: TrafficDelta,
        peakBytesPerSecond: UInt64
    ) {
        self.timestamp = timestamp
        self.application = application
        self.network = network
        self.processID = processID
        self.delta = delta
        self.peakBytesPerSecond = peakBytesPerSecond
    }
}

public struct TrafficBucket: Codable, Equatable {
    public let start: Date
    public let end: Date
    public let download: UInt64
    public let upload: UInt64
    public let peakBytesPerSecond: UInt64
    public let sampleCount: Int

    public init(
        start: Date,
        end: Date,
        download: UInt64,
        upload: UInt64,
        peakBytesPerSecond: UInt64,
        sampleCount: Int
    ) {
        self.start = start
        self.end = end
        self.download = download
        self.upload = upload
        self.peakBytesPerSecond = peakBytesPerSecond
        self.sampleCount = sampleCount
    }
}

public struct ProcessTrafficSummary: Codable, Equatable {
    public let processID: Int32
    public let processName: String
    public let download: UInt64
    public let upload: UInt64
    public let peakBytesPerSecond: UInt64

    public init(
        processID: Int32,
        processName: String,
        download: UInt64,
        upload: UInt64,
        peakBytesPerSecond: UInt64
    ) {
        self.processID = processID
        self.processName = processName
        self.download = download
        self.upload = upload
        self.peakBytesPerSecond = peakBytesPerSecond
    }
}

public struct ApplicationTrafficSummary: Codable, Equatable {
    public let identity: ApplicationIdentity
    public let download: UInt64
    public let upload: UInt64
    public let peakBytesPerSecond: UInt64
    public let processes: [ProcessTrafficSummary]

    public var total: UInt64 { self.download + self.upload }

    public init(
        identity: ApplicationIdentity,
        download: UInt64,
        upload: UInt64,
        peakBytesPerSecond: UInt64,
        processes: [ProcessTrafficSummary]
    ) {
        self.identity = identity
        self.download = download
        self.upload = upload
        self.peakBytesPerSecond = peakBytesPerSecond
        self.processes = processes
    }
}
