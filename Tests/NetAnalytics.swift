//
//  NetAnalytics.swift
//  Tests
//

import XCTest
@testable import Net

final class NetAnalyticsTests: XCTestCase {
    private let identity = ApplicationIdentity(
        id: "com.example.client",
        displayName: "Example",
        bundleIdentifier: "com.example.client",
        executablePath: nil
    )

    func testDeltaUsesMonotonicCounterGrowth() {
        let previous = self.counter(startToken: 1, download: 900, upload: 500)
        let current = self.counter(startToken: 1, download: 1_200, upload: 650)

        XCTAssertEqual(
            TrafficDeltaCalculator.delta(from: previous, to: current),
            TrafficDelta(download: 300, upload: 150)
        )
    }

    func testDeltaIgnoresCounterReset() {
        let previous = self.counter(startToken: 1, download: 900, upload: 500)
        let current = self.counter(startToken: 1, download: 100, upload: 50)

        XCTAssertEqual(TrafficDeltaCalculator.delta(from: previous, to: current), .zero)
    }

    func testDeltaIgnoresReusedProcessIdentifier() {
        let previous = self.counter(startToken: 1, download: 900, upload: 500)
        let current = self.counter(startToken: 2, download: 1_200, upload: 650)

        XCTAssertEqual(TrafficDeltaCalculator.delta(from: previous, to: current), .zero)
    }

    func testNettopParserReadsValidRows() {
        let csv = """
        ,bytes_in,bytes_out,
        launchd.1,10,20,
        mDNSResponder.538,100,200,
        """

        let result = NettopSnapshotParser.parse(csv: csv)
        XCTAssertEqual(result.malformedRowCount, 0)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0], NettopRow(processName: "launchd", processID: 1, download: 10, upload: 20))
        XCTAssertEqual(result.rows[1], NettopRow(processName: "mDNSResponder", processID: 538, download: 100, upload: 200))
    }

    func testNettopParserKeepsDotsInProcessName() {
        let csv = """
        ,bytes_in,bytes_out,
        Google Chrome Helper.1234,50,75,
        com.example.tool.99,1,2,
        """

        let result = NettopSnapshotParser.parse(csv: csv)
        XCTAssertEqual(result.rows.map(\.processName), ["Google Chrome Helper", "com.example.tool"])
        XCTAssertEqual(result.rows.map(\.processID), [1234, 99])
    }

    func testNettopParserCountsMissingFieldsAndInvalidBytes() {
        let csv = """
        ,bytes_in,bytes_out,
        incomplete.1,10,
        broken.2,abc,5,
        ok.3,7,8,
        """

        let result = NettopSnapshotParser.parse(csv: csv)
        XCTAssertEqual(result.rows, [NettopRow(processName: "ok", processID: 3, download: 7, upload: 8)])
        XCTAssertEqual(result.malformedRowCount, 2)
    }

    func testNettopParserHandlesHeaderOnlyOutput() {
        let result = NettopSnapshotParser.parse(csv: ",bytes_in,bytes_out,\n")
        XCTAssertEqual(result.rows, [])
        XCTAssertEqual(result.malformedRowCount, 0)
    }

    func testIdentityGroupsHelpersUnderOwningBundle() {
        let provider = FakeProcessMetadataProvider(entries: [
            100: ProcessMetadata(
                processID: 100,
                processName: "Chrome Helper",
                bundleIdentifier: nil,
                executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helper",
                parentProcessID: 10
            ),
            10: ProcessMetadata(
                processID: 10,
                processName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
                executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            )
        ])
        let resolver = ApplicationIdentityResolver(provider: provider)
        let counters = [
            ProcessTrafficCounter(
                identity: ApplicationIdentity(id: "helper", displayName: "Chrome Helper", bundleIdentifier: nil, executablePath: nil),
                processID: 100,
                processStartToken: 1,
                download: 40,
                upload: 10
            ),
            ProcessTrafficCounter(
                identity: ApplicationIdentity(id: "chrome", displayName: "Google Chrome", bundleIdentifier: nil, executablePath: nil),
                processID: 10,
                processStartToken: 1,
                download: 100,
                upload: 20
            )
        ]

        let summaries = resolver.group(counters: counters)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].identity.bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(summaries[0].download, 140)
        XCTAssertEqual(summaries[0].upload, 30)
        XCTAssertEqual(summaries[0].processes.count, 2)
    }

    func testIdentityKeepsCommandLineToolsSeparateByPath() {
        let provider = FakeProcessMetadataProvider(entries: [
            20: ProcessMetadata(
                processID: 20,
                processName: "curl",
                executablePath: "/usr/bin/curl"
            ),
            21: ProcessMetadata(
                processID: 21,
                processName: "curl",
                executablePath: "/opt/homebrew/bin/curl"
            )
        ])
        let resolver = ApplicationIdentityResolver(provider: provider)
        let counters = [
            ProcessTrafficCounter(
                identity: ApplicationIdentity(id: "a", displayName: "curl", bundleIdentifier: nil, executablePath: nil),
                processID: 20,
                processStartToken: 1,
                download: 5,
                upload: 1
            ),
            ProcessTrafficCounter(
                identity: ApplicationIdentity(id: "b", displayName: "curl", bundleIdentifier: nil, executablePath: nil),
                processID: 21,
                processStartToken: 1,
                download: 7,
                upload: 2
            )
        ]

        let summaries = resolver.group(counters: counters)
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(Set(summaries.map { $0.identity.executablePath }), [
            "/usr/bin/curl",
            "/opt/homebrew/bin/curl"
        ])
    }

    func testIdentitySearchMatchesNameBundleAndProcess() {
        let summary = ApplicationTrafficSummary(
            identity: ApplicationIdentity(
                id: "bundle:com.openai.chat",
                displayName: "ChatGPT",
                bundleIdentifier: "com.openai.chat",
                executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            ),
            download: 10,
            upload: 2,
            peakBytesPerSecond: 12,
            processes: [
                ProcessTrafficSummary(
                    processID: 55,
                    processName: "ChatGPT Helper",
                    download: 4,
                    upload: 1,
                    peakBytesPerSecond: 5
                )
            ]
        )

        XCTAssertTrue(ApplicationIdentityResolver.matches(summary, search: "chat"))
        XCTAssertTrue(ApplicationIdentityResolver.matches(summary, search: "openai"))
        XCTAssertTrue(ApplicationIdentityResolver.matches(summary, search: "Helper"))
        XCTAssertFalse(ApplicationIdentityResolver.matches(summary, search: "chrome"))
    }

    func testHistoryRepositoryInsertsAndFetchesOrderedRange() {
        let store = InMemoryTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let network = NetworkIdentity(id: "wifi-home", displayName: "Home", interfaceName: "en0", kind: .wifi)
        let t0 = Date(timeIntervalSince1970: 1_721_234_567)
        let samples = [
            self.sample(at: t0.addingTimeInterval(2), network: network, applicationID: "app.a", download: 20, upload: 5),
            self.sample(at: t0, network: network, applicationID: "app.a", download: 10, upload: 1),
            self.sample(at: t0.addingTimeInterval(1), network: network, applicationID: "app.b", download: 3, upload: 2)
        ]
        repository.insert(samples: samples)

        let fetched = repository.fetch(
            TrafficHistoryQuery(level: .second, start: t0, end: t0.addingTimeInterval(2))
        )
        XCTAssertEqual(fetched.map(\.timestamp), [t0, t0.addingTimeInterval(1), t0.addingTimeInterval(2)])
        XCTAssertEqual(
            TrafficHistoryRepository.makeKey(
                level: .second,
                timestamp: t0,
                networkID: network.id,
                applicationID: "app.a"
            ),
            "net.analytics.v1|second|00000000001721234567|wifi-home|app.a"
        )
    }

    func testHistoryRepositoryFiltersByNetworkAndApplication() {
        let store = InMemoryTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let wifi = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let eth = NetworkIdentity(id: "eth", displayName: "Ethernet", interfaceName: "en1", kind: .ethernet)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        repository.insert(samples: [
            self.sample(at: t0, network: wifi, applicationID: "app.a", download: 1, upload: 1),
            self.sample(at: t0.addingTimeInterval(1), network: eth, applicationID: "app.a", download: 2, upload: 2),
            self.sample(at: t0.addingTimeInterval(2), network: wifi, applicationID: "app.b", download: 3, upload: 3)
        ])

        let filtered = repository.fetch(
            TrafficHistoryQuery(
                level: .second,
                start: t0,
                end: t0.addingTimeInterval(10),
                networkID: "wifi",
                applicationID: "app.a"
            )
        )
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].application.id, "app.a")
        XCTAssertEqual(filtered[0].network.id, "wifi")
    }

    func testHistoryRepositoryDeletesAllSamples() {
        let store = InMemoryTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let t0 = Date(timeIntervalSince1970: 1_700_000_100)
        repository.insert(self.sample(at: t0, network: network, applicationID: "app.a", download: 9, upload: 1))
        repository.deleteAll()
        XCTAssertTrue(
            repository.fetch(TrafficHistoryQuery(level: .second, start: t0.addingTimeInterval(-10), end: t0.addingTimeInterval(10))).isEmpty
        )
    }

    func testHeatmapKindsMatchSelectedRanges() {
        XCTAssertEqual(TrafficAggregation.heatmapKind(for: .tenMinutes), .thirtySeconds)
        XCTAssertEqual(TrafficAggregation.heatmapKind(for: .oneHour), .fiveMinutes)
        XCTAssertEqual(TrafficAggregation.heatmapKind(for: .today), .oneHour)
        XCTAssertEqual(TrafficAggregation.heatmapKind(for: .sevenDays), .weekdayHour)
        XCTAssertEqual(TrafficAggregation.heatmapKind(for: .thirtyDays), .oneDay)
        XCTAssertEqual(TrafficAggregation.heatmapKind(for: .currentMonth), .oneDay)
    }

    func testAnalyticsEngineRanksAndTotalsSamples() {
        let store = InMemoryTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let wifi = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = Date(timeIntervalSince1970: 1_721_234_600)
        repository.insert(samples: [
            self.sample(at: now.addingTimeInterval(-30), network: wifi, applicationID: "app.a", download: 100, upload: 20),
            self.sample(at: now.addingTimeInterval(-20), network: wifi, applicationID: "app.b", download: 40, upload: 10),
            self.sample(at: now.addingTimeInterval(-10), network: wifi, applicationID: "app.a", download: 50, upload: 5)
        ])

        let engine = TrafficAnalyticsEngine(repository: repository)
        let snapshot = engine.snapshot(for: TrafficAnalyticsQuery(range: .tenMinutes, now: now))
        XCTAssertEqual(snapshot.download, 190)
        XCTAssertEqual(snapshot.upload, 35)
        XCTAssertEqual(snapshot.total, 225)
        XCTAssertEqual(snapshot.ranking.map(\.identity.id), ["app.a", "app.b"])
        XCTAssertEqual(snapshot.ranking[0].download, 150)
        XCTAssertFalse(snapshot.buckets.isEmpty)
    }

    func testAnalyticsEngineDeduplicatesTunnelAgainstPhysical() {
        let store = InMemoryTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let wifi = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let tunnel = NetworkIdentity(id: "utun", displayName: "VPN", interfaceName: "utun0", kind: .tunnel)
        let now = Date(timeIntervalSince1970: 1_721_234_700)
        repository.insert(samples: [
            self.sample(at: now.addingTimeInterval(-5), network: wifi, applicationID: "app.a", download: 100, upload: 10),
            self.sample(at: now.addingTimeInterval(-5), network: tunnel, applicationID: "app.a", download: 100, upload: 10)
        ])

        let engine = TrafficAnalyticsEngine(repository: repository)
        let snapshot = engine.snapshot(for: TrafficAnalyticsQuery(range: .tenMinutes, now: now))
        XCTAssertEqual(snapshot.total, 110)
    }

    func testAnalyticsEngineForecastUsesBillingRate() {
        let store = InMemoryTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let engine = TrafficAnalyticsEngine(repository: repository, calendar: calendar)
        let start = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 00:00 UTC
        let samples = [
            self.sample(
                at: start,
                network: NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi),
                applicationID: "app.a",
                download: 100,
                upload: 0
            ),
            self.sample(
                at: start.addingTimeInterval(2 * 86_400),
                network: NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi),
                applicationID: "app.a",
                download: 200,
                upload: 0
            )
        ]
        let forecast = engine.forecast(samples: samples, billingCycleDay: 1, now: start.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(forecast.state, .ready)
        // 300 total bytes over 2 elapsed days => 150 bytes/day average.
        XCTAssertEqual(forecast.averageBytesPerDay, 150)
        XCTAssertNotNil(forecast.projectedBytes)
    }

    func testCoordinatorBaselinesThenWritesDeltas() {
        let store = InMemoryTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let provider = FakeProcessMetadataProvider(entries: [
            42: ProcessMetadata(
                processID: 42,
                processName: "Example",
                bundleIdentifier: "com.example.client",
                executablePath: "/Applications/Example.app/Contents/MacOS/Example"
            )
        ])
        let coordinator = TrafficAnalyticsCoordinator(
            repository: repository,
            resolver: ApplicationIdentityResolver(provider: provider)
        )
        coordinator.start()
        coordinator.updateNetwork(
            NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        )

        let first = ProcessTrafficCounter(
            identity: ApplicationIdentity(id: "x", displayName: "Example", bundleIdentifier: nil, executablePath: nil),
            processID: 42,
            processStartToken: 1,
            download: 100,
            upload: 20
        )
        coordinator.ingest(counters: [first])
        XCTAssertEqual(coordinator.snapshot().samplesWritten, 0)

        let second = ProcessTrafficCounter(
            identity: ApplicationIdentity(id: "x", displayName: "Example", bundleIdentifier: nil, executablePath: nil),
            processID: 42,
            processStartToken: 1,
            download: 150,
            upload: 30
        )
        coordinator.ingest(counters: [second])
        XCTAssertEqual(coordinator.snapshot().samplesWritten, 1)

        let samples = repository.fetch(
            TrafficHistoryQuery(
                level: .second,
                start: Date().addingTimeInterval(-60),
                end: Date().addingTimeInterval(60)
            )
        )
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].delta.download, 50)
        XCTAssertEqual(samples[0].delta.upload, 10)
        XCTAssertEqual(samples[0].application.bundleIdentifier, "com.example.client")
    }

    func testCoordinatorIgnoresIngestWhileStopped() {
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let coordinator = TrafficAnalyticsCoordinator(repository: repository)
        let counter = ProcessTrafficCounter(
            identity: ApplicationIdentity(id: "x", displayName: "Example", bundleIdentifier: nil, executablePath: nil),
            processID: 1,
            processStartToken: 1,
            download: 10,
            upload: 1
        )
        coordinator.ingest(counters: [counter])
        XCTAssertFalse(coordinator.snapshot().isCollecting)
        XCTAssertEqual(coordinator.snapshot().samplesWritten, 0)
    }

    func testRetentionCompactionPromotesSecondsToMinutes() {
        let store = InMemoryTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let wifi = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-25 * 60 * 60)
        repository.insert(samples: [
            self.sample(at: old, network: wifi, applicationID: "app.a", download: 10, upload: 1),
            self.sample(at: old.addingTimeInterval(30), network: wifi, applicationID: "app.a", download: 5, upload: 2)
        ])

        TrafficAggregation.compact(
            repository: repository,
            now: now,
            policy: TrafficRetentionPolicy(secondRetention: 24 * 60 * 60, minuteRetention: 30 * 24 * 60 * 60, hourRetention: 2 * 365 * 24 * 60 * 60)
        )

        let seconds = repository.fetch(
            TrafficHistoryQuery(level: .second, start: old.addingTimeInterval(-120), end: now)
        )
        let minutes = repository.fetch(
            TrafficHistoryQuery(level: .minute, start: old.addingTimeInterval(-120), end: now)
        )
        XCTAssertTrue(seconds.isEmpty)
        XCTAssertEqual(minutes.count, 1)
        XCTAssertEqual(minutes.first?.delta.download, 15)
        XCTAssertEqual(minutes.first?.delta.upload, 3)
    }

    private func sample(
        at timestamp: Date,
        network: NetworkIdentity,
        applicationID: String,
        download: UInt64,
        upload: UInt64
    ) -> TrafficSample {
        TrafficSample(
            timestamp: timestamp,
            application: ApplicationIdentity(
                id: applicationID,
                displayName: applicationID,
                bundleIdentifier: applicationID,
                executablePath: nil
            ),
            network: network,
            processID: 1,
            delta: TrafficDelta(download: download, upload: upload),
            peakBytesPerSecond: download + upload
        )
    }

    private func counter(
        startToken: UInt64,
        download: UInt64,
        upload: UInt64
    ) -> ProcessTrafficCounter {
        ProcessTrafficCounter(
            identity: self.identity,
            processID: 42,
            processStartToken: startToken,
            download: download,
            upload: upload
        )
    }
}

private struct FakeProcessMetadataProvider: ProcessMetadataProviding {
    let entries: [Int32: ProcessMetadata]

    func metadata(for processID: Int32, fallbackName: String) -> ProcessMetadata {
        if let entry = self.entries[processID] {
            return entry
        }
        return ProcessMetadata(processID: processID, processName: fallbackName)
    }
}
