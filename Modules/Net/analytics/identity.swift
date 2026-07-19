//
//  identity.swift
//  Net
//

import AppKit
import Darwin
import Foundation

public struct ProcessMetadata: Equatable {
    public let processID: Int32
    public let processName: String
    public let bundleIdentifier: String?
    public let bundleURL: URL?
    public let executablePath: String?
    public let parentProcessID: Int32?
    public let processStartToken: UInt64?

    public init(
        processID: Int32,
        processName: String,
        bundleIdentifier: String? = nil,
        bundleURL: URL? = nil,
        executablePath: String? = nil,
        parentProcessID: Int32? = nil,
        processStartToken: UInt64? = nil
    ) {
        self.processID = processID
        self.processName = processName
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.executablePath = executablePath
        self.parentProcessID = parentProcessID
        self.processStartToken = processStartToken
    }
}

public protocol ProcessMetadataProviding {
    func metadata(for processID: Int32, fallbackName: String) -> ProcessMetadata
}

public struct ApplicationIdentityResolver {
    private let provider: ProcessMetadataProviding

    public init(provider: ProcessMetadataProviding) {
        self.provider = provider
    }

    public func identity(
        processID: Int32,
        fallbackName: String,
        visited: Set<Int32> = []
    ) -> ApplicationIdentity {
        if visited.contains(processID) {
            return self.identity(from: ProcessMetadata(processID: processID, processName: fallbackName))
        }

        let metadata = self.provider.metadata(for: processID, fallbackName: fallbackName)
        if metadata.bundleIdentifier != nil || metadata.bundleURL != nil {
            return self.identity(from: metadata)
        }

        if let parent = metadata.parentProcessID, parent > 0, parent != processID {
            var nextVisited = visited
            nextVisited.insert(processID)
            let parentIdentity = self.identity(
                processID: parent,
                fallbackName: fallbackName,
                visited: nextVisited
            )
            if parentIdentity.bundleIdentifier != nil {
                return parentIdentity
            }
        }

        return self.identity(from: metadata)
    }

    public func processIdentity(processID: Int32, fallbackName: String) -> ApplicationIdentity {
        self.identity(from: self.provider.metadata(for: processID, fallbackName: fallbackName))
    }

    public func group(
        counters: [ProcessTrafficCounter]
    ) -> [ApplicationTrafficSummary] {
        var buckets: [String: (identity: ApplicationIdentity, download: UInt64, upload: UInt64, peak: UInt64, processes: [ProcessTrafficSummary])] = [:]

        for counter in counters {
            let identity = self.identity(
                processID: counter.processID,
                fallbackName: counter.identity.displayName
            )
            let process = ProcessTrafficSummary(
                processDiscriminator: counter.processDiscriminator,
                processID: counter.processID,
                processName: counter.identity.displayName,
                download: counter.download,
                upload: counter.upload,
                peakBytesPerSecond: counter.download + counter.upload,
                identity: self.processIdentity(processID: counter.processID, fallbackName: counter.identity.displayName)
            )
            var bucket = buckets[identity.id] ?? (
                identity: identity,
                download: 0,
                upload: 0,
                peak: 0,
                processes: []
            )
            bucket.download += counter.download
            bucket.upload += counter.upload
            bucket.peak = max(bucket.peak, process.peakBytesPerSecond)
            bucket.processes.append(process)
            buckets[identity.id] = bucket
        }

        return buckets.values
            .map {
                ApplicationTrafficSummary(
                    identity: $0.identity,
                    download: $0.download,
                    upload: $0.upload,
                    peakBytesPerSecond: $0.peak,
                    processes: $0.processes.sorted {
                        if $0.processID == $1.processID {
                            return ($0.processDiscriminator ?? "") < ($1.processDiscriminator ?? "")
                        }
                        return $0.processID < $1.processID
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.total == rhs.total {
                    return lhs.identity.displayName.localizedCaseInsensitiveCompare(rhs.identity.displayName) == .orderedAscending
                }
                return lhs.total > rhs.total
            }
    }

    public static func matches(
        _ summary: ApplicationTrafficSummary,
        search: String
    ) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let candidates = [
            summary.identity.displayName,
            summary.identity.bundleIdentifier,
            summary.identity.executablePath
        ] + summary.processes.map(\.processName)

        return candidates.compactMap { $0 }.contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func identity(from metadata: ProcessMetadata) -> ApplicationIdentity {
        if let bundleIdentifier = metadata.bundleIdentifier, !bundleIdentifier.isEmpty {
            let displayName = metadata.bundleURL
                .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
                ?? metadata.bundleURL?.deletingPathExtension().lastPathComponent
                ?? metadata.processName
            return ApplicationIdentity(
                id: "bundle:\(bundleIdentifier)",
                displayName: displayName.isEmpty ? bundleIdentifier : displayName,
                bundleIdentifier: bundleIdentifier,
                executablePath: metadata.executablePath
            )
        }

        if let path = metadata.executablePath, !path.isEmpty {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return ApplicationIdentity(
                id: "path:\(path)",
                displayName: name.isEmpty ? metadata.processName : name,
                bundleIdentifier: nil,
                executablePath: path
            )
        }

        let name = metadata.processName.isEmpty ? "\(metadata.processID)" : metadata.processName
        return ApplicationIdentity(
            id: "name:\(name)",
            displayName: name,
            bundleIdentifier: nil,
            executablePath: metadata.executablePath
        )
    }
}

public struct AppKitProcessMetadataProvider: ProcessMetadataProviding {
    public init() {}

    public func metadata(for processID: Int32, fallbackName: String) -> ProcessMetadata {
        let app = NSRunningApplication(processIdentifier: processID)
        let executablePath = app?.executableURL?.path ?? self.executablePath(for: processID)
        let bsdInfo = self.bsdInfo(for: processID)
        return ProcessMetadata(
            processID: processID,
            processName: app?.localizedName ?? fallbackName,
            bundleIdentifier: app?.bundleIdentifier,
            bundleURL: app?.bundleURL,
            executablePath: executablePath,
            parentProcessID: bsdInfo.map { Int32($0.pbi_ppid) },
            processStartToken: bsdInfo.map {
                UInt64($0.pbi_start_tvsec) * 1_000_000 + UInt64($0.pbi_start_tvusec)
            }
        )
    }

    private func executablePath(for processID: Int32) -> String? {
        // 4 * MAXPATHLEN, matching PROC_PIDPATHINFO_MAXSIZE without using the unavailable macro.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let result = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private func bsdInfo(for processID: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard result == size else { return nil }
        return info
    }
}
