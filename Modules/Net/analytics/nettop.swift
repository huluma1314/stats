//
//  nettop.swift
//  Net
//

import Foundation
import Darwin

public struct NettopCommand: Equatable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public static let connectionSnapshot = NettopCommand(
        executableURL: URL(fileURLWithPath: "/usr/bin/nettop"),
        arguments: ["-L", "1", "-n", "-x", "-J", "interface,bytes_in,bytes_out"]
    )
}

public enum NettopCollectionError: Error, Equatable, LocalizedError {
    case launchFailed(String)
    case timedOut
    case cancelled
    case emptyOutput
    case malformedOutput(Int)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message): return "Unable to launch nettop: \(message)"
        case .timedOut: return "Nettop collection timed out"
        case .cancelled: return "Nettop collection cancelled"
        case .emptyOutput: return "Nettop returned no usable rows"
        case .malformedOutput(let count): return "Nettop returned \(count) malformed row(s) and no usable rows"
        }
    }
}

public final class NettopCancellation {
    private let lock = NSLock()
    private var cancelled = false

    public var isCancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancelled
    }

    public init() {}

    public func cancel() {
        self.lock.lock()
        self.cancelled = true
        self.lock.unlock()
    }
}

public protocol NettopRunning: AnyObject {
    func run(command: NettopCommand, timeout: TimeInterval, cancellation: NettopCancellation) throws -> String
    func cancel()
}

public extension NettopRunning {
    func run(command: NettopCommand, timeout: TimeInterval) throws -> String {
        try self.run(command: command, timeout: timeout, cancellation: NettopCancellation())
    }
}

public protocol NettopProcessExecuting: AnyObject {
    var outputData: Data { get }
    var errorData: Data { get }

    func start(command: NettopCommand) throws
    func waitForExit(timeout: TimeInterval) -> Bool
    func terminate()
    func interrupt()
    func kill()
    func closeReaders()
    func waitForReaders(timeout: TimeInterval) -> Bool
}

private final class FoundationNettopProcessExecution: NettopProcessExecuting {
    private let task = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let reads = DispatchGroup()
    private let dataLock = NSLock()
    private var capturedOutput = Data()
    private var capturedError = Data()

    var outputData: Data {
        self.dataLock.lock()
        defer { self.dataLock.unlock() }
        return self.capturedOutput
    }

    var errorData: Data {
        self.dataLock.lock()
        defer { self.dataLock.unlock() }
        return self.capturedError
    }

    func start(command: NettopCommand) throws {
        self.dataLock.lock()
        defer { self.dataLock.unlock() }
        self.task.executableURL = command.executableURL
        self.task.arguments = command.arguments
        self.task.environment = [
            "NSUnbufferedIO": "YES",
            "LC_ALL": "en_US.UTF-8"
        ]
        self.task.standardOutput = self.outputPipe
        self.task.standardError = self.errorPipe
        try self.task.run()
        self.startReaders()
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        repeat {
            self.dataLock.lock()
            let isRunning = self.task.isRunning
            self.dataLock.unlock()
            if !isRunning { return true }
            Thread.sleep(forTimeInterval: 0.005)
        } while ProcessInfo.processInfo.systemUptime < deadline
        self.dataLock.lock()
        defer { self.dataLock.unlock() }
        return !self.task.isRunning
    }

    func terminate() {
        self.dataLock.lock()
        defer { self.dataLock.unlock() }
        if self.task.isRunning { self.task.terminate() }
    }

    func interrupt() {
        self.dataLock.lock()
        defer { self.dataLock.unlock() }
        if self.task.isRunning { self.task.interrupt() }
    }

    func kill() {
        self.dataLock.lock()
        defer { self.dataLock.unlock() }
        if self.task.isRunning { Darwin.kill(self.task.processIdentifier, SIGKILL) }
    }

    func closeReaders() {
        try? self.outputPipe.fileHandleForReading.close()
        try? self.errorPipe.fileHandleForReading.close()
    }

    func waitForReaders(timeout: TimeInterval) -> Bool {
        self.reads.wait(timeout: .now() + max(0, timeout)) == .success
    }

    private func startReaders() {
        self.reads.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = self.outputPipe.fileHandleForReading.readDataToEndOfFile()
            self.dataLock.lock()
            self.capturedOutput = data
            self.dataLock.unlock()
            self.reads.leave()
        }
        self.reads.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = self.errorPipe.fileHandleForReading.readDataToEndOfFile()
            self.dataLock.lock()
            self.capturedError = data
            self.dataLock.unlock()
            self.reads.leave()
        }
    }
}

public final class ProcessNettopRunner: NettopRunning {
    private let executionFactory: () -> NettopProcessExecuting
    private let cleanupTimeout: TimeInterval
    private let lock = NSLock()
    private let cleanupLock = NSLock()
    private var currentExecution: NettopProcessExecuting?

    public convenience init() {
        self.init(executionFactory: { FoundationNettopProcessExecution() })
    }

    public init(
        executionFactory: @escaping () -> NettopProcessExecuting,
        cleanupTimeout: TimeInterval = 0.2
    ) {
        self.executionFactory = executionFactory
        self.cleanupTimeout = cleanupTimeout
    }

    public func run(
        command: NettopCommand,
        timeout: TimeInterval,
        cancellation: NettopCancellation
    ) throws -> String {
        guard !cancellation.isCancelled else { throw NettopCollectionError.cancelled }
        let execution = self.executionFactory()
        self.lock.lock()
        guard self.currentExecution == nil, !cancellation.isCancelled else {
            self.lock.unlock()
            throw NettopCollectionError.cancelled
        }
        self.currentExecution = execution
        do {
            try execution.start(command: command)
        } catch {
            self.currentExecution = nil
            self.lock.unlock()
            execution.closeReaders()
            _ = execution.waitForReaders(timeout: self.cleanupTimeout)
            throw NettopCollectionError.launchFailed(error.localizedDescription)
        }
        self.lock.unlock()
        defer { self.clearCurrentExecution(execution) }

        if cancellation.isCancelled {
            self.cleanupExecution(execution)
            throw NettopCollectionError.cancelled
        }
        guard execution.waitForExit(timeout: timeout) else {
            self.cleanupExecution(execution)
            throw cancellation.isCancelled ? NettopCollectionError.cancelled : NettopCollectionError.timedOut
        }

        execution.closeReaders()
        guard execution.waitForReaders(timeout: self.cleanupTimeout) else {
            throw NettopCollectionError.launchFailed("Timed out draining nettop output")
        }
        guard !cancellation.isCancelled else { throw NettopCollectionError.cancelled }

        guard let output = String(data: execution.outputData, encoding: .utf8), !output.isEmpty else {
            let message = String(data: execution.errorData, encoding: .utf8) ?? ""
            if !message.isEmpty {
                throw NettopCollectionError.launchFailed(message)
            }
            throw NettopCollectionError.emptyOutput
        }
        return output
    }

    public func cancel() {
        self.lock.lock()
        guard let execution = self.currentExecution else {
            self.lock.unlock()
            return
        }
        self.cleanupExecution(execution)
        self.lock.unlock()
    }

    private func clearCurrentExecution(_ execution: NettopProcessExecuting) {
        self.lock.lock()
        if self.currentExecution === execution {
            self.currentExecution = nil
        }
        self.lock.unlock()
    }

    private func cleanupExecution(_ execution: NettopProcessExecuting) {
        self.cleanupLock.lock()
        defer { self.cleanupLock.unlock() }
        execution.terminate()
        if !execution.waitForExit(timeout: self.cleanupTimeout) {
            execution.interrupt()
            if !execution.waitForExit(timeout: self.cleanupTimeout) {
                execution.kill()
                _ = execution.waitForExit(timeout: self.cleanupTimeout)
            }
        }
        execution.closeReaders()
        _ = execution.waitForReaders(timeout: self.cleanupTimeout)
    }
}

public final class NettopCollector {
    private let runner: NettopRunning
    private let command: NettopCommand
    private let timeout: TimeInterval

    public init(
        runner: NettopRunning = ProcessNettopRunner(),
        command: NettopCommand = .connectionSnapshot,
        timeout: TimeInterval = 5
    ) {
        self.runner = runner
        self.command = command
        self.timeout = timeout
    }

    public func snapshot(cancellation: NettopCancellation = NettopCancellation()) throws -> NettopParseResult {
        let output = try self.runner.run(
            command: self.command,
            timeout: self.timeout,
            cancellation: cancellation
        )
        guard !cancellation.isCancelled else { throw NettopCollectionError.cancelled }
        guard !output.isEmpty else { throw NettopCollectionError.emptyOutput }
        let result = NettopSnapshotParser.parse(csv: output)
        guard !cancellation.isCancelled else { throw NettopCollectionError.cancelled }
        guard !result.rows.isEmpty else {
            if result.malformedRowCount > 0 {
                throw NettopCollectionError.malformedOutput(result.malformedRowCount)
            }
            throw NettopCollectionError.emptyOutput
        }
        return result
    }

    public func cancel() {
        self.runner.cancel()
    }
}

public struct NettopRow: Equatable {
    public let processName: String
    public let processID: Int32
    public let connectionID: String?
    public let interfaceName: String?
    public let download: UInt64
    public let upload: UInt64
    public let isProcessSummary: Bool

    public init(
        processName: String,
        processID: Int32,
        connectionID: String? = nil,
        interfaceName: String? = nil,
        download: UInt64,
        upload: UInt64,
        isProcessSummary: Bool = true
    ) {
        self.processName = processName
        self.processID = processID
        self.connectionID = connectionID
        self.interfaceName = interfaceName
        self.download = download
        self.upload = upload
        self.isProcessSummary = isProcessSummary
    }
}

public struct NettopParseResult: Equatable {
    public let rows: [NettopRow]
    public let malformedRowCount: Int

    public init(rows: [NettopRow], malformedRowCount: Int) {
        self.rows = rows
        self.malformedRowCount = malformedRowCount
    }
}

public enum NettopSnapshotParser {
    public static func parse(csv: String) -> NettopParseResult {
        var rows: [NettopRow] = []
        var malformed = 0
        var header: [String] = []
        var parent: (name: String, pid: Int32)?
        var connectionIndexes: [String: Int] = [:]
        var unattributedConnectionIndexes: [String: Int] = [:]
        var attributedConnectionKeys: Set<String> = []

        csv.enumerateLines { line, _ in
            let columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if header.isEmpty {
                header = columns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                return
            }

            guard !columns.isEmpty else { return }
            let identity = columns[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identity.isEmpty else { return }

            let interfaceIndex = header.firstIndex(of: "interface")
            let downloadIndex = header.firstIndex(of: "bytes_in") ?? 1
            let uploadIndex = header.firstIndex(of: "bytes_out") ?? 2
            let requiredIndex = max(interfaceIndex ?? 0, downloadIndex, uploadIndex)
            guard columns.count > requiredIndex,
                  !columns[downloadIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !columns[uploadIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                malformed += 1
                return
            }

            if !self.isConnectionIdentity(identity), let process = self.processIdentity(identity) {
                guard let download = self.optionalBytes(columns[downloadIndex]),
                      let upload = self.optionalBytes(columns[uploadIndex]) else {
                    malformed += 1
                    return
                }
                parent = process
                rows.append(NettopRow(
                    processName: process.name,
                    processID: process.pid,
                    connectionID: nil,
                    interfaceName: interfaceIndex.flatMap { self.interface(columns[$0]) },
                    download: download,
                    upload: upload,
                    isProcessSummary: true
                ))
                return
            }

            guard let parent else {
                malformed += 1
                return
            }
            guard let download = self.optionalBytes(columns[downloadIndex]),
                  let upload = self.optionalBytes(columns[uploadIndex]) else {
                malformed += 1
                return
            }
            let interfaceName = interfaceIndex.flatMap { self.interface(columns[$0]) }
            let baseDuplicateKey = "\(parent.pid)|\(identity)|\(download)|\(upload)"
            let duplicateKey = "\(baseDuplicateKey)|\(interfaceName ?? "")"
            let row = NettopRow(
                processName: parent.name,
                processID: parent.pid,
                connectionID: identity,
                interfaceName: interfaceName,
                download: download,
                upload: upload,
                isProcessSummary: false
            )
            if connectionIndexes[duplicateKey] != nil { return }
            if interfaceName == nil {
                guard !attributedConnectionKeys.contains(baseDuplicateKey) else { return }
                connectionIndexes[duplicateKey] = rows.count
                unattributedConnectionIndexes[baseDuplicateKey] = rows.count
                rows.append(row)
                return
            }
            attributedConnectionKeys.insert(baseDuplicateKey)
            if let index = unattributedConnectionIndexes.removeValue(forKey: baseDuplicateKey) {
                rows[index] = row
                connectionIndexes[duplicateKey] = index
                return
            }
            connectionIndexes[duplicateKey] = rows.count
            rows.append(row)
        }

        return NettopParseResult(rows: rows, malformedRowCount: malformed)
    }

    private static func processIdentity(_ identity: String) -> (name: String, pid: Int32)? {
        guard let separator = identity.lastIndex(of: ".") else { return nil }
        let name = String(identity[..<separator])
        let pidPart = String(identity[identity.index(after: separator)...])
        guard let pid = Int32(pidPart), pid >= 0 else { return nil }
        return (name.isEmpty ? "\(pid)" : name, pid)
    }

    private static func isConnectionIdentity(_ identity: String) -> Bool {
        guard let protocolName = identity.split(whereSeparator: { $0.isWhitespace }).first else { return false }
        return ["tcp4", "tcp6", "udp4", "udp6", "quic"].contains(protocolName)
    }

    private static func optionalBytes(_ value: String) -> UInt64? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return 0 }
        return UInt64(value)
    }

    private static func interface(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public final class ProcessTrafficCounterBuilder {
    private struct BaseConnectionKey: Hashable {
        let processDiscriminator: String
        let connectionID: String
    }

    private struct ConnectionKey: Hashable {
        let base: BaseConnectionKey
        let interfaceName: String?
    }

    private let provider: ProcessMetadataProviding
    private let resolver: ApplicationIdentityResolver
    private let fallbackInterfaceName: String?
    private var previousConnections: [ConnectionKey: (download: UInt64, upload: UInt64)] = [:]

    public init(
        provider: ProcessMetadataProviding = AppKitProcessMetadataProvider(),
        fallbackInterfaceName: String? = nil
    ) {
        self.provider = provider
        self.resolver = ApplicationIdentityResolver(provider: provider)
        self.fallbackInterfaceName = fallbackInterfaceName
    }

    public func reset() {
        self.previousConnections.removeAll()
    }

    public func counters(rows: [NettopRow]) -> [ProcessTrafficCounter] {
        let hasConnectionRows = rows.contains { !$0.isProcessSummary }
        var childrenByPID: [Int32: [NettopRow]] = [:]
        var summariesByPID: [Int32: NettopRow] = [:]
        for row in rows {
            if row.isProcessSummary {
                summariesByPID[row.processID] = row
            } else {
                childrenByPID[row.processID, default: []].append(row)
            }
        }

        if !hasConnectionRows {
            return Dictionary(grouping: rows, by: \.processID).compactMap { pid, processRows in
                guard let first = processRows.first else { return nil }
                let metadata = self.provider.metadata(for: pid, fallbackName: first.processName)
                guard let startToken = metadata.processStartToken else { return nil }
                let identity = self.resolver.identity(processID: pid, fallbackName: first.processName)
                return ProcessTrafficCounter(
                    identity: identity,
                    processID: pid,
                    processStartToken: startToken,
                    processDiscriminator: "\(metadata.executablePath ?? identity.id)|\(pid)|\(startToken)",
                    interfaceName: self.fallbackInterfaceName,
                    download: processRows.reduce(UInt64(0)) { $0 + $1.download },
                    upload: processRows.reduce(UInt64(0)) { $0 + $1.upload }
                )
            }.sorted { $0.processID < $1.processID }
        }

        var observations: [ConnectionKey: (row: NettopRow, metadata: ProcessMetadata, identity: ApplicationIdentity)] = [:]
        for pid in Set(summariesByPID.keys).union(childrenByPID.keys) {
            let fallbackName = summariesByPID[pid]?.processName ?? childrenByPID[pid]?.first?.processName ?? "\(pid)"
            let metadata = self.provider.metadata(for: pid, fallbackName: fallbackName)
            guard let startToken = metadata.processStartToken else { continue }
            let identity = self.resolver.identity(processID: pid, fallbackName: fallbackName)
            let processDiscriminator = "\(metadata.executablePath ?? identity.id)|\(pid)|\(startToken)"
            let children = childrenByPID[pid] ?? []
            let sourceRows: [NettopRow]
            if hasConnectionRows {
                sourceRows = children.isEmpty ? summariesByPID[pid].map { [$0] } ?? [] : children
            } else {
                sourceRows = rows.filter { $0.processID == pid }
            }

            for row in sourceRows {
                let connectionID = row.connectionID ?? "process-summary"
                let key = ConnectionKey(
                    base: BaseConnectionKey(
                        processDiscriminator: processDiscriminator,
                        connectionID: connectionID
                    ),
                    interfaceName: row.interfaceName
                )
                let existing = observations[key]
                if existing == nil
                    || row.download > existing!.row.download
                    || row.upload > existing!.row.upload {
                    observations[key] = (row, metadata, identity)
                }
            }
        }

        let attributedBases = Set(observations.keys.compactMap { key in
            key.interfaceName == nil ? nil : key.base
        })
        observations = observations.filter { key, _ in
            key.interfaceName != nil || !attributedBases.contains(key.base)
        }

        var next: [ConnectionKey: (download: UInt64, upload: UInt64)] = [:]
        struct AggregateKey: Hashable {
            let discriminator: String
            let interfaceName: String?
        }
        var aggregates: [AggregateKey: (metadata: ProcessMetadata, identity: ApplicationIdentity, download: UInt64, upload: UInt64)] = [:]

        for (observationKey, observation) in observations {
            let interfaceName = observation.row.interfaceName ?? self.fallbackInterfaceName
            let counterKey = ConnectionKey(base: observationKey.base, interfaceName: interfaceName)
            next[counterKey] = (observation.row.download, observation.row.upload)
            let aggregateKey = AggregateKey(discriminator: observationKey.base.processDiscriminator, interfaceName: interfaceName)
            var aggregate = aggregates[aggregateKey] ?? (observation.metadata, observation.identity, 0, 0)
            if let previous = self.previousConnections[counterKey] {
                if observation.row.download >= previous.download {
                    aggregate.download += observation.row.download - previous.download
                }
                if observation.row.upload >= previous.upload {
                    aggregate.upload += observation.row.upload - previous.upload
                }
            }
            aggregates[aggregateKey] = aggregate
        }
        self.previousConnections = next

        return aggregates.map { key, value in
            ProcessTrafficCounter(
                identity: value.identity,
                processID: value.metadata.processID,
                processStartToken: value.metadata.processStartToken!,
                processDiscriminator: key.discriminator,
                interfaceName: key.interfaceName,
                isDelta: true,
                download: value.download,
                upload: value.upload
            )
        }.sorted {
            if $0.processDiscriminator == $1.processDiscriminator {
                return ($0.interfaceName ?? "") < ($1.interfaceName ?? "")
            }
            return $0.processDiscriminator < $1.processDiscriminator
        }
    }
}
