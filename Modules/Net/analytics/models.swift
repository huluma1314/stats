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
    public let processDiscriminator: String
    public let interfaceName: String?
    public let isDelta: Bool
    public let download: UInt64
    public let upload: UInt64

    public init(
        identity: ApplicationIdentity,
        processID: Int32,
        processStartToken: UInt64,
        processDiscriminator: String? = nil,
        interfaceName: String? = nil,
        isDelta: Bool = false,
        download: UInt64,
        upload: UInt64
    ) {
        self.identity = identity
        self.processID = processID
        self.processStartToken = processStartToken
        self.processDiscriminator = processDiscriminator ?? "\(identity.id)|\(processID)|\(processStartToken)"
        self.interfaceName = interfaceName
        self.isDelta = isDelta
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
    /// The logical Wi-Fi network name, when the platform provides it.
    public let ssid: String?
    /// The currently observed access-point identifier. It is metadata, never part of a Wi-Fi ID.
    public let bssid: String?
    /// A stable hardware address for physical interfaces, when available.
    public let hardwareAddress: String?
    /// A stable service/VPN/device identifier, when available.
    public let serviceIdentifier: String?

    public init(
        id: String,
        displayName: String,
        interfaceName: String,
        kind: NetworkKind,
        ssid: String? = nil,
        bssid: String? = nil,
        hardwareAddress: String? = nil,
        serviceIdentifier: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.interfaceName = interfaceName
        self.kind = kind
        self.ssid = ssid
        self.bssid = bssid
        self.hardwareAddress = hardwareAddress
        self.serviceIdentifier = serviceIdentifier
    }
}

public enum TrafficRouteKind: String, Codable {
    case direct
    case systemProxy
    case tunnel
}

public struct TrafficRouteContext: Codable, Equatable {
    public let kind: TrafficRouteKind
    public let proxyHost: String?
    public let proxyPort: Int?
    public let systemProxyConfigured: Bool

    public init(
        kind: TrafficRouteKind,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        systemProxyConfigured: Bool = false
    ) {
        self.kind = kind
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.systemProxyConfigured = systemProxyConfigured
    }

    private enum CodingKeys: String, CodingKey { case kind, proxyHost, proxyPort, systemProxyConfigured }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(TrafficRouteKind.self, forKey: .kind)
        self.proxyHost = try container.decodeIfPresent(String.self, forKey: .proxyHost)
        self.proxyPort = try container.decodeIfPresent(Int.self, forKey: .proxyPort)
        self.systemProxyConfigured = try container.decodeIfPresent(Bool.self, forKey: .systemProxyConfigured) ?? false
    }
}

public enum TrafficRouteClassifier {
    public static func context(
        systemProxyConfigured: Bool,
        observedProxyApplication: Bool,
        observedTunnelInterface: Bool,
        proxyHost: String? = nil,
        proxyPort: Int? = nil
    ) -> TrafficRouteContext {
        if observedTunnelInterface {
            return TrafficRouteContext(kind: .tunnel, systemProxyConfigured: systemProxyConfigured)
        }
        if observedProxyApplication {
            return TrafficRouteContext(
                kind: .systemProxy,
                proxyHost: proxyHost,
                proxyPort: proxyPort,
                systemProxyConfigured: systemProxyConfigured
            )
        }
        // Configuration is descriptive metadata only; it never reassigns a direct sample.
        _ = systemProxyConfigured
        return TrafficRouteContext(kind: .direct, systemProxyConfigured: systemProxyConfigured)
    }

    public static func label(for context: TrafficRouteContext, systemProxyConfigured: Bool) -> String {
        switch context.kind {
        case .direct: return (systemProxyConfigured || context.systemProxyConfigured) ? "System proxy configured" : "Direct"
        case .systemProxy: return "System proxy forwarded"
        case .tunnel: return "Tunnel"
        }
    }
}

public struct TrafficSample: Codable, Equatable {
    public let timestamp: Date
    public let application: ApplicationIdentity
    public let network: NetworkIdentity
    public let processID: Int32
    public let processName: String
    public let processStartToken: UInt64
    public let processDiscriminator: String
    public let delta: TrafficDelta
    public let peakBytesPerSecond: UInt64
    public let routeContext: TrafficRouteContext
    public let processIdentity: ApplicationIdentity?

    public init(
        timestamp: Date,
        application: ApplicationIdentity,
        network: NetworkIdentity,
        processID: Int32,
        processName: String? = nil,
        processStartToken: UInt64 = 0,
        processDiscriminator: String? = nil,
        delta: TrafficDelta,
        peakBytesPerSecond: UInt64,
        routeContext: TrafficRouteContext = TrafficRouteContext(kind: .direct),
        processIdentity: ApplicationIdentity? = nil
    ) {
        self.timestamp = timestamp
        self.application = application
        self.network = network
        self.processID = processID
        self.processName = processName ?? application.displayName
        self.processStartToken = processStartToken
        self.processDiscriminator = processDiscriminator ?? "\(application.id)|\(processID)|\(processStartToken)"
        self.delta = delta
        self.peakBytesPerSecond = peakBytesPerSecond
        self.routeContext = routeContext
        self.processIdentity = processIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case application
        case network
        case processID
        case processName
        case processStartToken
        case processDiscriminator
        case delta
        case peakBytesPerSecond
        case routeContext
        case processIdentity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.application = try container.decode(ApplicationIdentity.self, forKey: .application)
        self.network = try container.decode(NetworkIdentity.self, forKey: .network)
        self.processID = try container.decode(Int32.self, forKey: .processID)
        self.processName = try container.decodeIfPresent(String.self, forKey: .processName) ?? self.application.displayName
        self.processStartToken = try container.decodeIfPresent(UInt64.self, forKey: .processStartToken) ?? 0
        self.processDiscriminator = try container.decodeIfPresent(String.self, forKey: .processDiscriminator)
            ?? "\(self.application.id)|\(self.processID)|\(self.processStartToken)"
        self.delta = try container.decode(TrafficDelta.self, forKey: .delta)
        self.peakBytesPerSecond = try container.decode(UInt64.self, forKey: .peakBytesPerSecond)
        self.routeContext = try container.decodeIfPresent(TrafficRouteContext.self, forKey: .routeContext) ?? TrafficRouteContext(kind: .direct)
        self.processIdentity = try container.decodeIfPresent(ApplicationIdentity.self, forKey: .processIdentity)
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
    public let processDiscriminator: String?
    public let processID: Int32
    public let processName: String
    public let download: UInt64
    public let upload: UInt64
    public let peakBytesPerSecond: UInt64
    public let sampleCount: Int?
    public let identity: ApplicationIdentity?

    public init(
        processDiscriminator: String? = nil,
        processID: Int32,
        processName: String,
        download: UInt64,
        upload: UInt64,
        peakBytesPerSecond: UInt64,
        sampleCount: Int? = nil,
        identity: ApplicationIdentity? = nil
    ) {
        self.processDiscriminator = processDiscriminator
        self.processID = processID
        self.processName = processName
        self.download = download
        self.upload = upload
        self.peakBytesPerSecond = peakBytesPerSecond
        self.sampleCount = sampleCount
        self.identity = identity
    }

    private enum CodingKeys: String, CodingKey {
        case processDiscriminator, processID, processName, download, upload, peakBytesPerSecond, sampleCount, identity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.processDiscriminator = try container.decodeIfPresent(String.self, forKey: .processDiscriminator)
        self.processID = try container.decode(Int32.self, forKey: .processID)
        self.processName = try container.decode(String.self, forKey: .processName)
        self.download = try container.decode(UInt64.self, forKey: .download)
        self.upload = try container.decode(UInt64.self, forKey: .upload)
        self.peakBytesPerSecond = try container.decode(UInt64.self, forKey: .peakBytesPerSecond)
        self.sampleCount = try container.decodeIfPresent(Int.self, forKey: .sampleCount)
        self.identity = try container.decodeIfPresent(ApplicationIdentity.self, forKey: .identity)
    }
}

public struct ApplicationTrafficSummary: Codable, Equatable {
    public let identity: ApplicationIdentity
    public let download: UInt64
    public let upload: UInt64
    public let peakBytesPerSecond: UInt64
    public let processes: [ProcessTrafficSummary]
    public let routeContexts: [TrafficRouteContext]
    public let sampleCount: Int?

    public var total: UInt64 { self.download + self.upload }

    public init(
        identity: ApplicationIdentity,
        download: UInt64,
        upload: UInt64,
        peakBytesPerSecond: UInt64,
        processes: [ProcessTrafficSummary],
        routeContexts: [TrafficRouteContext] = [],
        sampleCount: Int? = nil
    ) {
        self.identity = identity
        self.download = download
        self.upload = upload
        self.peakBytesPerSecond = peakBytesPerSecond
        self.processes = processes
        self.routeContexts = routeContexts
        self.sampleCount = sampleCount
    }

    private enum CodingKeys: String, CodingKey {
        case identity, download, upload, peakBytesPerSecond, processes, routeContexts, sampleCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.identity = try container.decode(ApplicationIdentity.self, forKey: .identity)
        self.download = try container.decode(UInt64.self, forKey: .download)
        self.upload = try container.decode(UInt64.self, forKey: .upload)
        self.peakBytesPerSecond = try container.decode(UInt64.self, forKey: .peakBytesPerSecond)
        self.processes = try container.decode([ProcessTrafficSummary].self, forKey: .processes)
        self.routeContexts = try container.decodeIfPresent([TrafficRouteContext].self, forKey: .routeContexts) ?? []
        self.sampleCount = try container.decodeIfPresent(Int.self, forKey: .sampleCount)
    }
}
