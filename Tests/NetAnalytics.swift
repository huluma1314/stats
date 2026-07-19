//
//  NetAnalytics.swift
//  Tests
//

import XCTest
import Kit
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

    func testDeltaCalculatesDirectionResetsIndependently() {
        let previous = self.counter(startToken: 1, download: 900, upload: 500)

        XCTAssertEqual(
            TrafficDeltaCalculator.delta(
                from: previous,
                to: self.counter(startToken: 1, download: 100, upload: 650)
            ),
            TrafficDelta(download: 0, upload: 150)
        )
        XCTAssertEqual(
            TrafficDeltaCalculator.delta(
                from: previous,
                to: self.counter(startToken: 1, download: 1_200, upload: 50)
            ),
            TrafficDelta(download: 300, upload: 0)
        )
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

    func testNettopParserDoesNotTreatIPv6EndpointPortAsProcessParent() {
        let csv = """
        ,interface,bytes_in,bytes_out,
        Browser Helper.55,,100,20,
        tcp6 fe80::1.61234<->2606:4700:4700::1111.443,en0,10,2,
        """

        let result = NettopSnapshotParser.parse(csv: csv)
        XCTAssertEqual(result.malformedRowCount, 0)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[1].processID, 55)
        XCTAssertEqual(result.rows[1].processName, "Browser Helper")
        XCTAssertEqual(result.rows[1].connectionID, "tcp6 fe80::1.61234<->2606:4700:4700::1111.443")
        XCTAssertFalse(result.rows[1].isProcessSummary)
    }

    func testNettopParserRecognizesOnlyExactConnectionProtocolTokens() {
        let csv = """
        ,interface,bytes_in,bytes_out,
        tcpdump.123,,100,20,
        tcp4 a<->b,en0,10,2,
        tcp6 a<->b,en0,11,3,
        udp4 a<->b,en0,12,4,
        udp6 a<->b,en0,13,5,
        quic a<->b,en0,14,6,
        """

        let result = NettopSnapshotParser.parse(csv: csv)
        XCTAssertEqual(result.malformedRowCount, 0)
        XCTAssertEqual(result.rows.count, 6)
        guard let parent = result.rows.first else { return }
        XCTAssertEqual(parent.processName, "tcpdump")
        XCTAssertEqual(parent.processID, 123)
        XCTAssertTrue(parent.isProcessSummary)
        XCTAssertTrue(result.rows.dropFirst().allSatisfy { $0.processName == "tcpdump" && !$0.isProcessSummary })
    }

    func testNettopParserKeepsExactRowsOnDistinctConcreteInterfaces() {
        let csv = """
        ,interface,bytes_in,bytes_out,
        Client.55,,100,20,
        tcp4 a<->b,en0,10,2,
        tcp4 a<->b,utun3,10,2,
        """

        let rows = NettopSnapshotParser.parse(csv: csv).rows.filter { !$0.isProcessSummary }
        XCTAssertEqual(rows.map(\.interfaceName), ["en0", "utun3"])
    }

    func testNettopParserRemovesUnattributedExactDuplicateWhenAttributedRowExists() {
        let csv = """
        ,interface,bytes_in,bytes_out,
        Client.55,,100,20,
        tcp4 a<->b,,10,2,
        tcp4 a<->b,en0,10,2,
        """

        let rows = NettopSnapshotParser.parse(csv: csv).rows.filter { !$0.isProcessSummary }
        XCTAssertEqual(rows.map(\.interfaceName), ["en0"])
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
                applicationID: "app.a",
                processDiscriminator: samples[1].processDiscriminator
            ),
            "net.analytics.v2|second|00000000001721234567|wifi-home|app.a|app.a%7C1%7C1"
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

    func testRawRankingKeepsPIDReuseLifetimesDistinctAfterRestart() {
        let store = RecordingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let wifi = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = Date(timeIntervalSince1970: 1_721_234_700)
        let firstLifetime = self.sample(
            at: now.addingTimeInterval(-2),
            network: wifi,
            applicationID: "app.owner",
            processID: 77,
            processName: "Helper",
            processStartToken: 101,
            download: 10,
            upload: 2
        )
        let secondLifetime = self.sample(
            at: now.addingTimeInterval(-1),
            network: wifi,
            applicationID: "app.owner",
            processID: 77,
            processName: "Helper",
            processStartToken: 202,
            download: 25,
            upload: 5
        )
        XCTAssertSuccess(repository.ingest([firstLifetime, secondLifetime]))

        let snapshot = TrafficAnalyticsEngine(repository: TrafficHistoryRepository(store: store)).snapshot(
            for: TrafficAnalyticsQuery(range: .tenMinutes, now: now)
        )

        XCTAssertEqual(snapshot.total, 42)
        XCTAssertEqual(snapshot.ranking.map(\.total), [42])
        XCTAssertEqual(snapshot.ranking[0].processes.count, 2)
        XCTAssertEqual(
            Set(snapshot.ranking[0].processes.compactMap(\.processDiscriminator)),
            Set([firstLifetime.processDiscriminator, secondLifetime.processDiscriminator])
        )
        XCTAssertEqual(snapshot.ranking[0].processes.reduce(UInt64(0)) { $0 + $1.download + $1.upload }, 42)
    }

    func testRawRankingFallsBackToPIDForLegacySamplesWithoutDiscriminator() throws {
        let networkJSON = """
        {
          "id": "wifi",
          "displayName": "Wi-Fi",
          "interfaceName": "en0",
          "kind": "wifi"
        }
        """
        let sampleJSON: (String, UInt64, UInt64) -> String = { timestamp, download, upload in
            """
            {
              "timestamp": "\(timestamp)",
              "application": {
                "id": "legacy.owner",
                "displayName": "legacy.owner",
                "bundleIdentifier": "legacy.owner"
              },
              "network": \(networkJSON),
              "processID": 77,
              "processName": "Helper",
              "delta": {
                "download": \(download),
                "upload": \(upload)
              },
              "peakBytesPerSecond": \(download + upload)
            }
            """
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let samples = try [
            sampleJSON("2024-07-17T00:00:00Z", 10, 2),
            sampleJSON("2024-07-17T00:00:01Z", 25, 5)
        ].map { try decoder.decode(TrafficSample.self, from: Data($0.utf8)) }

        let ranking = TrafficAnalyticsEngine(repository: TrafficHistoryRepository(store: InMemoryTrafficStore()))
            .rank(samples: samples)

        XCTAssertEqual(ranking.map(\.total), [42])
        XCTAssertEqual(ranking[0].processes.count, 1)
        XCTAssertEqual(ranking[0].processes[0].processID, 77)
        XCTAssertEqual(ranking[0].processes[0].download, 35)
        XCTAssertEqual(ranking[0].processes[0].upload, 7)
    }

    func testProcessTrafficSummaryDecodesLegacyPayloadWithoutDiscriminator() throws {
        let legacy = """
        {
          "processID": 77,
          "processName": "Helper",
          "download": 10,
          "upload": 2,
          "peakBytesPerSecond": 12
        }
        """

        let decoded = try JSONDecoder().decode(ProcessTrafficSummary.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.processDiscriminator)
        XCTAssertEqual(decoded.processID, 77)
        XCTAssertEqual(decoded.processName, "Helper")
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

    func testPreviewPageFallsBackToRealtimeForInvalidValue() {
        XCTAssertEqual(NetworkPreviewPage(storedRawValue: "analysis"), .analysis)
        XCTAssertEqual(NetworkPreviewPage(storedRawValue: "overview"), .overview)
        XCTAssertEqual(NetworkPreviewPage(storedRawValue: "realtime"), .realtime)
        XCTAssertEqual(NetworkPreviewPage(storedRawValue: "nope"), .realtime)
        XCTAssertEqual(NetworkPreviewPage(storedRawValue: nil), .realtime)
    }

    func testTrafficAnalysisLayoutUsesAvailableWidthAndKeepsControlsVisible() {
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let view = TrafficAnalysisView(
            engine: TrafficAnalyticsEngine(repository: repository),
            repository: repository
        )
        view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 620)
        view.layoutSubtreeIfNeeded()

        let descendants = self.descendants(of: view)
        let rangeControl = descendants
            .compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == TrafficRange.allCases.count }
        let chart = descendants.compactMap { $0 as? TrafficTimelineChartView }.first
        let outline = descendants.compactMap { $0 as? NSOutlineView }.first
        let detail = descendants.compactMap { $0 as? ApplicationDetailView }.first
        let customRange = descendants.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "traffic-custom-range"
        }
        let more = descendants.compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "traffic-more-options"
        }

        XCTAssertNotNil(rangeControl)
        XCTAssertNotNil(customRange)
        XCTAssertNotNil(more)
        XCTAssertGreaterThan(rangeControl?.frame.height ?? 0, 20)
        XCTAssertGreaterThan(chart?.frame.width ?? 0, 1_000)
        XCTAssertGreaterThan(outline?.enclosingScrollView?.frame.width ?? 0, 1_000)
        XCTAssertGreaterThan(detail?.frame.width ?? 0, 1_000)
    }

    func testNetworkPreviewAnalysisPageStretchesItsContent() {
        let previousPage = Store.shared.string(
            key: NetworkPreviewPage.storageKey,
            defaultValue: NetworkPreviewPage.realtime.rawValue
        )
        Store.shared.set(key: NetworkPreviewPage.storageKey, value: NetworkPreviewPage.analysis.rawValue)
        defer { Store.shared.set(key: NetworkPreviewPage.storageKey, value: previousPage) }

        let preview = Preview(.network)
        let scrollView = ScrollableStackView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        scrollView.stackView.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        scrollView.stackView.addArrangedSubview(preview)
        scrollView.layoutSubtreeIfNeeded()

        let descendants = self.descendants(of: preview)
        let chart = descendants.compactMap { $0 as? TrafficTimelineChartView }.first
        let rangeControl = descendants
            .compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == TrafficRange.allCases.count }
        let summaryCards = descendants
            .compactMap { $0 as? NSStackView }
            .first { $0.identifier?.rawValue == "traffic-summary-cards" }
        let analysisView = descendants.compactMap { $0 as? TrafficAnalysisView }.first

        XCTAssertFalse(analysisView?.isFlipped == true)
        XCTAssertTrue(chart?.superview is FlippedStackView)
        XCTAssertGreaterThanOrEqual(analysisView?.frame.height ?? 0, 700)
        if let analysisView, let rangeControl, let chart {
            let controlsRect = rangeControl.convert(rangeControl.bounds, to: scrollView.stackView)
            let chartRect = chart.convert(chart.bounds, to: scrollView.stackView)
            XCTAssertLessThan(controlsRect.minY, chartRect.minY)
        }
        XCTAssertGreaterThan(chart?.frame.width ?? 0, 1_000)
        XCTAssertGreaterThan(summaryCards?.frame.width ?? 0, 1_000)
        XCTAssertGreaterThan(rangeControl?.frame.height ?? 0, 20)
    }

    func testSwitchingNetworkPreviewPagesKeepsPageSelectorVisible() {
        let previousPage = Store.shared.string(
            key: NetworkPreviewPage.storageKey,
            defaultValue: NetworkPreviewPage.realtime.rawValue
        )
        Store.shared.set(key: NetworkPreviewPage.storageKey, value: NetworkPreviewPage.realtime.rawValue)
        defer { Store.shared.set(key: NetworkPreviewPage.storageKey, value: previousPage) }

        let preview = Preview(.network)
        let wrapper = ScrollableStackView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 620))
        wrapper.stackView.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        wrapper.stackView.addArrangedSubview(preview)
        wrapper.layoutSubtreeIfNeeded()

        let descendants = self.descendants(of: wrapper)
        guard let pageControl = descendants.compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.segmentCount == NetworkPreviewPage.allCases.count }) else {
            XCTFail("Expected preview page selector")
            return
        }

        pageControl.selectedSegment = 1
        pageControl.sendAction(pageControl.action, to: pageControl.target)
        wrapper.layoutSubtreeIfNeeded()

        XCTAssertEqual(pageControl.selectedSegment, 1)
        XCTAssertGreaterThan(pageControl.frame.height, 20)
    }

    func testNetworkPreviewOverviewPageUsesFullWidthCards() {
        let previousPage = Store.shared.string(
            key: NetworkPreviewPage.storageKey,
            defaultValue: NetworkPreviewPage.realtime.rawValue
        )
        Store.shared.set(key: NetworkPreviewPage.storageKey, value: NetworkPreviewPage.overview.rawValue)
        defer { Store.shared.set(key: NetworkPreviewPage.storageKey, value: previousPage) }

        let preview = Preview(.network)
        let wrapper = ScrollableStackView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        wrapper.stackView.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        wrapper.stackView.addArrangedSubview(preview)
        wrapper.layoutSubtreeIfNeeded()

        let cards = self.descendants(of: preview)
            .compactMap { $0 as? NSStackView }
            .first { $0.identifier?.rawValue == "traffic-overview-cards" }
        let topApps = self.descendants(of: preview)
            .compactMap { $0 as? NSStackView }
            .first { $0.identifier?.rawValue == "traffic-overview-top-apps" }

        XCTAssertGreaterThan(cards?.frame.width ?? 0, 1_000)
        XCTAssertLessThan(cards?.frame.minX ?? 10_000, 10)
        XCTAssertLessThan(topApps?.frame.minY ?? 10_000, 400)
    }

    func testTrafficSelectionRefreshIntervals() {
        XCTAssertNil(TrafficRefreshMode.manual.interval)
        XCTAssertEqual(TrafficRefreshMode.fiveSeconds.interval, 5)
        XCTAssertEqual(TrafficRefreshMode.tenSeconds.interval, 10)
        XCTAssertEqual(TrafficRefreshMode.thirtySeconds.interval, 30)
        XCTAssertEqual(TrafficRefreshMode.oneMinute.interval, 60)
        XCTAssertEqual(TrafficRefreshMode.fiveMinutes.interval, 300)

        let now = Date(timeIntervalSince1970: 1_721_234_567)
        let selection = TrafficSelection(range: .tenMinutes)
        let interval = selection.interval(now: now)
        XCTAssertEqual(interval.duration, 600, accuracy: 0.001)
    }

    func testCustomTrafficRangeValidation() {
        let now = Date(timeIntervalSince1970: 2_200_000_000)
        XCTAssertNil(TrafficCustomRange.interval(start: now, end: now, now: now))
        XCTAssertNil(TrafficCustomRange.interval(start: now, end: now.addingTimeInterval(-1), now: now))

        let interval = TrafficCustomRange.interval(
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(60),
            now: now
        )
        XCTAssertEqual(interval?.start, now.addingTimeInterval(-3_600))
        XCTAssertEqual(interval?.end, now)
    }

    func testAnalyticsEngineFetchesOutsidePresetForCustomInterval() {
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let engine = TrafficAnalyticsEngine(repository: repository)
        let now = Date(timeIntervalSince1970: 2_200_000_000)
        let wifi = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        repository.insert(self.sample(
            at: now.addingTimeInterval(-2 * 60 * 60),
            network: wifi,
            applicationID: "app.custom",
            download: 500,
            upload: 100
        ))

        let snapshot = engine.snapshot(for: TrafficAnalyticsQuery(
            range: .tenMinutes,
            selectedInterval: DateInterval(start: now.addingTimeInterval(-3 * 60 * 60), end: now),
            now: now
        ))

        XCTAssertEqual(snapshot.total, 600)
        XCTAssertEqual(snapshot.ranking.map(\.identity.id), ["app.custom"])
    }

    func testLiveTrafficWindowDurations() {
        XCTAssertEqual(LiveTrafficWindow.sixtySeconds.duration, 60)
        XCTAssertEqual(LiveTrafficWindow.fiveMinutes.duration, 300)
        XCTAssertEqual(LiveTrafficWindow.fifteenMinutes.duration, 900)
    }

    func testLiveTrafficSnapshotBuildsCurrentFrameAndApplicationFocus() {
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let engine = TrafficAnalyticsEngine(repository: repository)
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let wifi = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)

        repository.insert(samples: [
            self.sample(at: now.addingTimeInterval(-70), network: wifi, applicationID: "old", download: 999, upload: 999),
            self.sample(at: now.addingTimeInterval(-2), network: wifi, applicationID: "app.a", download: 100, upload: 20),
            self.sample(at: now.addingTimeInterval(-1), network: wifi, applicationID: "app.b", download: 50, upload: 30),
            self.sample(at: now, network: wifi, applicationID: "app.a", download: 20, upload: 10)
        ])

        let all = engine.liveSnapshot(window: .sixtySeconds, now: now)
        XCTAssertEqual(all.points.count, 3)
        XCTAssertEqual(all.downloadBytesPerSecond, 20)
        XCTAssertEqual(all.uploadBytesPerSecond, 10)
        XCTAssertEqual(all.activeApplications.map(\.identity.id), ["app.a"])

        let focused = engine.liveSnapshot(window: .sixtySeconds, applicationID: "app.b", now: now)
        XCTAssertEqual(focused.points.count, 1)
        XCTAssertEqual(focused.downloadBytesPerSecond, 50)
        XCTAssertEqual(focused.uploadBytesPerSecond, 30)
        XCTAssertEqual(focused.activeApplications.map(\.identity.id), ["app.b"])
    }

    func testLiveTrafficViewExposesBytetallyControls() {
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let view = LiveTrafficView(engine: TrafficAnalyticsEngine(repository: repository))
        view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 560)
        view.layoutSubtreeIfNeeded()

        let descendants = self.descendants(of: view)
        XCTAssertNotNil(descendants.compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertNotNil(descendants.compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 })
        XCTAssertTrue(descendants.contains { $0 is LiveTrafficChartView })
        XCTAssertTrue(descendants.contains { $0 is LiveTrafficAppsView })
    }

    func testNetworkPreviewRealtimePageStretchesLiveTraffic() {
        let previousPage = Store.shared.string(
            key: NetworkPreviewPage.storageKey,
            defaultValue: NetworkPreviewPage.realtime.rawValue
        )
        Store.shared.set(key: NetworkPreviewPage.storageKey, value: NetworkPreviewPage.realtime.rawValue)
        defer { Store.shared.set(key: NetworkPreviewPage.storageKey, value: previousPage) }

        let preview = Preview(.network)
        let wrapper = ScrollableStackView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        wrapper.stackView.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        wrapper.stackView.addArrangedSubview(preview)
        wrapper.layoutSubtreeIfNeeded()

        let chart = self.descendants(of: preview).compactMap { $0 as? LiveTrafficChartView }.first
        XCTAssertGreaterThan(chart?.frame.width ?? 0, 1_000)
    }

    func testChartGeometrySelectionAndHeatmapIndex() {
        let points = [
            ChartPoint(timestamp: Date(timeIntervalSince1970: 100), download: 1, upload: 1),
            ChartPoint(timestamp: Date(timeIntervalSince1970: 200), download: 2, upload: 2),
            ChartPoint(timestamp: Date(timeIntervalSince1970: 300), download: 3, upload: 3)
        ]
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        let plot = TrafficChartGeometry.plotRect(in: bounds)
        let interval = TrafficChartGeometry.selectionInterval(
            from: plot.minX,
            to: plot.maxX,
            points: points,
            in: bounds
        )
        XCTAssertEqual(interval?.start, points.first?.timestamp)
        XCTAssertEqual(interval?.end, points.last?.timestamp)

        let cells = [
            HeatmapCell(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2), download: 1, upload: 1, intensity: 0.2),
            HeatmapCell(start: Date(timeIntervalSince1970: 2), end: Date(timeIntervalSince1970: 3), download: 2, upload: 2, intensity: 0.8)
        ]
        let first = TrafficChartGeometry.heatmapIndex(at: CGPoint(x: plot.minX + 2, y: plot.maxY - 2), cells: cells, in: bounds)
        XCTAssertEqual(first, 0)
        XCTAssertNil(TrafficChartGeometry.heatmapIndex(at: CGPoint(x: 0, y: 0), cells: cells, in: bounds))
    }

    func testApplicationPresenterSortAndFilter() {
        let a = ApplicationTrafficSummary(
            identity: ApplicationIdentity(id: "a", displayName: "Alpha", bundleIdentifier: "com.a", executablePath: nil),
            download: 10,
            upload: 1,
            peakBytesPerSecond: 5,
            processes: []
        )
        let b = ApplicationTrafficSummary(
            identity: ApplicationIdentity(id: "b", displayName: "Beta", bundleIdentifier: "com.b", executablePath: nil),
            download: 30,
            upload: 2,
            peakBytesPerSecond: 9,
            processes: []
        )
        let sorted = ApplicationTrafficPresenter.sort([a, b], by: .total, ascending: false)
        XCTAssertEqual(sorted.map(\.identity.id), ["b", "a"])
        XCTAssertEqual(ApplicationTrafficPresenter.filter([a, b], search: "alp").map(\.identity.id), ["a"])
    }

    func testExportCSVAndJSON() throws {
        let snapshot = TrafficAnalyticsSnapshot(
            range: .tenMinutes,
            start: Date(timeIntervalSince1970: 10),
            end: Date(timeIntervalSince1970: 20),
            download: 30,
            upload: 5,
            total: 35,
            buckets: [],
            ranking: [
                ApplicationTrafficSummary(
                    identity: ApplicationIdentity(id: "app.a", displayName: "App, A", bundleIdentifier: "com.a", executablePath: "/A"),
                    download: 30,
                    upload: 5,
                    peakBytesPerSecond: 12,
                    processes: []
                )
            ],
            forecast: nil
        )
        let csv = TrafficExporter.csv(from: snapshot, networkFilter: .wifi)
        XCTAssertTrue(csv.contains("schema_version"))
        XCTAssertTrue(csv.contains("\"App, A\""))
        let data = try TrafficExporter.json(from: snapshot, networkFilter: .wifi)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object?["total"] as? UInt64, 35)
    }

    func testRuleEngineThresholdsAndPause() {
        let evaluation = TrafficRuleEngine.evaluate(
            usageBytes: 90,
            limitBytes: 100,
            thresholds: [80, 90, 100],
            alreadyNotified: [80],
            action: .notify,
            isPaused: false,
            allowUntil: nil,
            now: Date()
        )
        XCTAssertEqual(evaluation.triggeredThresholds, [90])

        let paused = TrafficRuleEngine.evaluate(
            usageBytes: 100,
            limitBytes: 100,
            thresholds: [100],
            alreadyNotified: [],
            action: .block,
            isPaused: true,
            allowUntil: nil,
            now: Date()
        )
        XCTAssertTrue(paused.triggeredThresholds.isEmpty)
        XCTAssertNil(paused.action)

        XCTAssertTrue(TrafficRuleEngine.validate(plan: .default))
        XCTAssertFalse(TrafficRuleEngine.validate(billingCycleDay: 0, byteLimit: 1, thresholds: [80, 70]))
    }

    func testTrafficAnalyticsPreferencesPersistBytetallySettings() {
        let suite = UserDefaults(suiteName: "net.analytics.preferences.tests")!
        suite.removePersistentDomain(forName: "net.analytics.preferences.tests")
        let store = TrafficAnalyticsPreferencesStore(defaults: suite)
        var preferences = store.preferences()
        XCTAssertTrue(preferences.quotaAlertsEnabled)
        XCTAssertEqual(preferences.minuteRetentionDays, 7)

        preferences.quotaAlertsEnabled = false
        preferences.anomalyDetectionEnabled = true
        preferences.overQuotaAction = .rateLimit
        preferences.minuteRetentionDays = 14
        store.save(preferences)

        let reloaded = store.preferences()
        XCTAssertFalse(reloaded.quotaAlertsEnabled)
        XCTAssertTrue(reloaded.anomalyDetectionEnabled)
        XCTAssertEqual(reloaded.overQuotaAction, .rateLimit)
        XCTAssertEqual(reloaded.minuteRetentionDays, 14)
    }

    func testApplicationTrafficRulesPersistAndDetailExposesControls() {
        let suiteName = "net.analytics.application.rules.tests"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let store = TrafficRuleStore(defaults: suite)
        let rule = ApplicationTrafficRule(
            applicationID: "app.control",
            period: .weekly,
            byteLimit: 5_000_000_000,
            downloadLimitBytesPerSecond: 1_000_000,
            uploadLimitBytesPerSecond: 500_000,
            action: .rateLimit
        )
        store.save(applicationRules: [rule])
        XCTAssertEqual(store.applicationRules(), [rule])

        let view = ApplicationDetailView(enforcer: FakeNetworkRuleEnforcer(), ruleStore: store)
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 520)
        view.show(ApplicationTrafficSummary(
            identity: ApplicationIdentity(id: "app.control", displayName: "Control", bundleIdentifier: "app.control", executablePath: nil),
            download: 100,
            upload: 50,
            peakBytesPerSecond: 20,
            processes: []
        ))
        view.layoutSubtreeIfNeeded()

        let identifiers = Set(self.descendants(of: view).compactMap { $0.identifier?.rawValue })
        XCTAssertTrue(identifiers.contains("traffic-rule-period"))
        XCTAssertTrue(identifiers.contains("traffic-rule-download"))
        XCTAssertTrue(identifiers.contains("traffic-rule-upload"))
        XCTAssertTrue(identifiers.contains("traffic-rule-action"))
        XCTAssertTrue(identifiers.contains("traffic-rule-save"))
    }

    func testUnavailableEnforcerNeverSucceeds() {
        let enforcer = UnavailableNetworkRuleEnforcer()
        XCTAssertEqual(enforcer.capability, .unavailable(.missingEntitlement))
        XCTAssertThrowsError(
            try enforcer.apply(NetworkEnforcementAction(applicationID: "app", kind: .block(.both)))
        )
        let fake = FakeNetworkRuleEnforcer()
        XCTAssertNoThrow(try fake.apply(NetworkEnforcementAction(applicationID: "app", kind: .rateLimit(downloadBytesPerSecond: 1, uploadBytesPerSecond: 2))))
        XCTAssertEqual(fake.applied.count, 1)
    }

    func testAnomalyDetectorConnectivityAndDedup() {
        let detector = TrafficAnomalyDetector(sustainedUploadBytesPerSecond: 10, sustainedDurationSeconds: 30, spikeMultiplier: 2, minimumBaselineBytes: 1)
        let sample = TrafficSample(
            timestamp: Date(),
            application: ApplicationIdentity(id: "a", displayName: "A", bundleIdentifier: nil, executablePath: nil),
            network: NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi),
            processID: 1,
            delta: TrafficDelta(download: 0, upload: 100),
            peakBytesPerSecond: 100
        )
        let events = detector.evaluate(
            recentSamples: [sample],
            baselineAverageBytes: 10,
            connectivityOnline: true,
            previousConnectivityOnline: false,
            disconnectCountLastHour: 3
        )
        XCTAssertTrue(events.contains { $0.kind == .sustainedUpload })
        XCTAssertTrue(events.contains { $0.kind == .baselineSpike })
        XCTAssertTrue(events.contains { $0.kind == .connectivity })
        XCTAssertEqual(detector.deduplicate(events + events).count, events.count)
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

    func testCoordinatorRetriesFailedSamplesWithOriginalTimestampsInNextAtomicBatch() {
        let store = RecordingTrafficStore()
        store.failNextWrite = true
        let repository = TrafficHistoryRepository(store: store)
        let clock = MutableTrafficClock(now: Date(timeIntervalSince1970: 100))
        let coordinator = TrafficAnalyticsCoordinator(repository: repository, clock: clock)
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        coordinator.start()
        coordinator.updateNetwork(network)

        let first = ProcessTrafficCounter(
            identity: self.identity,
            processID: 42,
            processStartToken: 1,
            isDelta: true,
            download: 10,
            upload: 1
        )
        coordinator.ingest(counters: [first])
        XCTAssertEqual(coordinator.snapshot().samplesWritten, 0)
        XCTAssertNotNil(coordinator.snapshot().lastError)

        clock.advance(by: 5)
        let second = ProcessTrafficCounter(
            identity: self.identity,
            processID: 42,
            processStartToken: 1,
            isDelta: true,
            download: 20,
            upload: 2
        )
        coordinator.ingest(counters: [second])

        let samples = repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: Date(timeIntervalSince1970: 99),
            end: Date(timeIntervalSince1970: 106)
        ))
        XCTAssertEqual(samples.map(\.timestamp), [
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 105)
        ])
        XCTAssertEqual(samples.map(\.delta), [
            TrafficDelta(download: 10, upload: 1),
            TrafficDelta(download: 20, upload: 2)
        ])
        XCTAssertEqual(store.atomicWrites.count, 1)
        XCTAssertEqual(store.atomicWrites[0].puts.count, 2)
        XCTAssertEqual(coordinator.snapshot().samplesWritten, 2)
        XCTAssertNil(coordinator.snapshot().lastError)
    }

    func testCoordinatorDisablesHistoryAfterBoundedPersistenceFailures() {
        let store = RecordingTrafficStore()
        store.failAllWrites = true
        let repository = TrafficHistoryRepository(store: store)
        let coordinator = TrafficAnalyticsCoordinator(
            repository: repository,
            persistencePolicy: TrafficPersistencePolicy(maxPendingSamples: 4, maxConsecutiveFailures: 2)
        )
        coordinator.start()

        for value in 1...6 {
            coordinator.ingest(counters: [ProcessTrafficCounter(
                identity: self.identity,
                processID: 42,
                processStartToken: 1,
                isDelta: true,
                download: UInt64(value),
                upload: 0
            )])
        }

        let snapshot = coordinator.snapshot()
        XCTAssertFalse(snapshot.isHistoryEnabled)
        XCTAssertEqual(snapshot.pendingSamples, 0)
        XCTAssertEqual(snapshot.samplesWritten, 0)
        XCTAssertEqual(store.attemptedWrites.map { $0.puts.count }, [1, 1])
        XCTAssertTrue(snapshot.lastError?.contains("disabled") == true)
        XCTAssertTrue(snapshot.lastError?.contains("dropped 2") == true)
    }

    func testCoordinatorClearDiscardsFailedSamplesAndBaselinesBeforeCollectionContinues() throws {
        let store = RecordingTrafficStore()
        store.failNextWrite = true
        let repository = TrafficHistoryRepository(store: store)
        let clock = MutableTrafficClock(now: Date(timeIntervalSince1970: 100))
        let coordinator = TrafficAnalyticsCoordinator(repository: repository, clock: clock)
        coordinator.start()

        coordinator.ingest(counters: [ProcessTrafficCounter(
            identity: self.identity,
            processID: 42,
            processStartToken: 1,
            download: 100,
            upload: 10
        )])
        clock.advance(by: 5)
        coordinator.ingest(counters: [ProcessTrafficCounter(
            identity: self.identity,
            processID: 42,
            processStartToken: 1,
            download: 110,
            upload: 11
        )])
        XCTAssertEqual(coordinator.snapshot().pendingSamples, 1)

        try coordinator.clearAnalyticsData()
        XCTAssertEqual(coordinator.snapshot().pendingSamples, 0)
        XCTAssertEqual(coordinator.snapshot().samplesWritten, 0)

        clock.advance(by: 5)
        coordinator.ingest(counters: [ProcessTrafficCounter(
            identity: self.identity,
            processID: 42,
            processStartToken: 1,
            download: 130,
            upload: 13
        )])
        clock.advance(by: 5)
        coordinator.ingest(counters: [ProcessTrafficCounter(
            identity: self.identity,
            processID: 42,
            processStartToken: 1,
            download: 150,
            upload: 15
        )])

        let samples = repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: Date(timeIntervalSince1970: 99),
            end: Date(timeIntervalSince1970: 116)
        ))
        XCTAssertEqual(samples.map(\.timestamp), [Date(timeIntervalSince1970: 115)])
        XCTAssertEqual(samples.map(\.delta), [TrafficDelta(download: 20, upload: 2)])
    }

    func testCoordinatorClearSerializesWithInFlightIngestion() throws {
        let store = BlockingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let coordinator = TrafficAnalyticsCoordinator(repository: repository)
        coordinator.start()

        let ingestFinished = expectation(description: "ingest finished")
        DispatchQueue.global().async {
            coordinator.ingest(counters: [ProcessTrafficCounter(
                identity: self.identity,
                processID: 42,
                processStartToken: 1,
                isDelta: true,
                download: 10,
                upload: 1
            )])
            ingestFinished.fulfill()
        }
        XCTAssertTrue(store.waitUntilWriteStarts())

        let clearFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? coordinator.clearAnalyticsData()
            clearFinished.signal()
        }
        XCTAssertEqual(clearFinished.wait(timeout: .now() + 0.05), .timedOut)

        store.finishBlockedWrite()
        wait(for: [ingestFinished], timeout: 1)
        XCTAssertEqual(clearFinished.wait(timeout: .now() + 1), .success)

        XCTAssertTrue(repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: Date().addingTimeInterval(-60),
            end: Date().addingTimeInterval(60)
        )).isEmpty)
    }

    func testCoordinatorStopFlushesPendingSamplesAndReportsSuccess() {
        let store = RecordingTrafficStore()
        store.failNextWrite = true
        let repository = TrafficHistoryRepository(store: store)
        let coordinator = TrafficAnalyticsCoordinator(repository: repository)
        coordinator.start()
        coordinator.ingest(counters: [ProcessTrafficCounter(
            identity: self.identity,
            processID: 42,
            processStartToken: 1,
            isDelta: true,
            download: 10,
            upload: 1
        )])

        XCTAssertTrue(coordinator.stop())

        let snapshot = coordinator.snapshot()
        XCTAssertFalse(snapshot.isCollecting)
        XCTAssertEqual(snapshot.samplesWritten, 1)
        XCTAssertEqual(snapshot.pendingSamples, 0)
        XCTAssertNil(snapshot.lastError)
    }

    func testCoordinatorStopReportsFailedFinalFlushWithoutClaimingPersistence() {
        let store = RecordingTrafficStore()
        store.failAllWrites = true
        let repository = TrafficHistoryRepository(store: store)
        let coordinator = TrafficAnalyticsCoordinator(
            repository: repository,
            persistencePolicy: TrafficPersistencePolicy(maxPendingSamples: 4, maxConsecutiveFailures: 3)
        )
        coordinator.start()
        coordinator.ingest(counters: [ProcessTrafficCounter(
            identity: self.identity,
            processID: 42,
            processStartToken: 1,
            isDelta: true,
            download: 10,
            upload: 1
        )])

        XCTAssertFalse(coordinator.stop())

        let snapshot = coordinator.snapshot()
        XCTAssertFalse(snapshot.isCollecting)
        XCTAssertEqual(snapshot.samplesWritten, 0)
        XCTAssertEqual(snapshot.pendingSamples, 1)
        XCTAssertNotNil(snapshot.lastError)
        XCTAssertEqual(store.attemptedWrites.map { $0.puts.count }, [1, 1])
    }

    func testRetentionCompactionPromotesSecondsToMinutes() throws {
        let store = InMemoryTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let wifi = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-25 * 60 * 60)
        repository.insert(samples: [
            self.sample(at: old, network: wifi, applicationID: "app.a", download: 10, upload: 1),
            self.sample(at: old.addingTimeInterval(30), network: wifi, applicationID: "app.a", download: 5, upload: 2)
        ])

        try TrafficAggregation.compact(
            repository: repository,
            now: now,
            policy: TrafficRetentionPolicy(minuteRetentionDays: 30, hourRetentionDays: 730, dayRetentionDays: 730)
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

    func testDailyAggregationUsesCalendarDayBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let timestamp = Date(timeIntervalSince1970: 1_710_069_300) // 2024-03-10 01:55 PST

        let daily = TrafficAggregation.aggregate(
            samples: [self.sample(at: timestamp, network: network, applicationID: "app", download: 1, upload: 2)],
            level: .day,
            calendar: calendar
        )

        XCTAssertEqual(daily.first?.timestamp, calendar.startOfDay(for: timestamp))
    }

    func testAggregateConvergesAcrossTwoRestartedCompactionPassesWithExactCountsAndMultipleHelpers() throws {
        let store = RecordingTrafficStore()
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_010)
        let policy = TrafficRetentionPolicy(minuteRetentionDays: 7, hourRetentionDays: 60, dayRetentionDays: 730)
        let firstNow = timestamp.addingTimeInterval(TrafficRetentionPolicy.secondRetention + 2 * 60)
        let secondNow = timestamp.addingTimeInterval(TrafficRetentionPolicy.secondRetention + 3 * 60)
        let firstHelperA = self.sample(at: timestamp, network: network, applicationID: "app.owner", processID: 41, processName: "Helper A", processStartToken: 101, download: 10, upload: 1)
        let firstHelperB = self.sample(at: timestamp.addingTimeInterval(1), network: network, applicationID: "app.owner", processID: 42, processName: "Helper B", processStartToken: 102, download: 20, upload: 2)
        let firstRepository = TrafficHistoryRepository(store: store)
        XCTAssertSuccess(firstRepository.ingest([firstHelperA, firstHelperB]))
        let firstSourceKeys = store.keys(prefix: "net.analytics.v2|second|")

        try TrafficAggregation.compact(
            repository: firstRepository,
            now: firstNow,
            policy: policy
        )

        XCTAssertTrue(firstSourceKeys.allSatisfy { store.get(key: $0) == nil })
        let secondHelperA = self.sample(at: timestamp.addingTimeInterval(20), network: network, applicationID: "app.owner", processID: 41, processName: "Helper A", processStartToken: 101, download: 5, upload: 4)
        let secondHelperC = self.sample(at: timestamp.addingTimeInterval(21), network: network, applicationID: "app.owner", processID: 43, processName: "Helper C", processStartToken: 103, download: 7, upload: 3)
        let restarted = TrafficHistoryRepository(store: store)
        XCTAssertSuccess(restarted.ingest([secondHelperA, secondHelperC]))
        let secondSourceKeys = store.keys(prefix: "net.analytics.v2|second|")

        try TrafficAggregation.compact(
            repository: restarted,
            now: secondNow,
            policy: policy
        )

        let finalRepository = TrafficHistoryRepository(store: store)
        let minuteRecords = finalRepository.fetchRecords(TrafficHistoryQuery(
            level: .minute,
            start: timestamp.addingTimeInterval(-60),
            end: timestamp.addingTimeInterval(60)
        ))
        XCTAssertEqual(minuteRecords.count, 1)
        XCTAssertEqual(minuteRecords[0].sample.delta, TrafficDelta(download: 42, upload: 10))
        XCTAssertEqual(minuteRecords[0].sample.peakBytesPerSecond, 22)
        XCTAssertEqual(minuteRecords[0].sampleCount, 4)
        XCTAssertEqual(minuteRecords[0].processSummaries, [
            StoredProcessTrafficSummary(
                processDiscriminator: firstHelperA.processDiscriminator,
                processID: 41,
                processName: "Helper A",
                download: 15,
                upload: 5,
                peakBytesPerSecond: 11,
                sampleCount: 2
            ),
            StoredProcessTrafficSummary(
                processDiscriminator: firstHelperB.processDiscriminator,
                processID: 42,
                processName: "Helper B",
                download: 20,
                upload: 2,
                peakBytesPerSecond: 22,
                sampleCount: 1
            ),
            StoredProcessTrafficSummary(
                processDiscriminator: secondHelperC.processDiscriminator,
                processID: 43,
                processName: "Helper C",
                download: 7,
                upload: 3,
                peakBytesPerSecond: 10,
                sampleCount: 1
            )
        ])
        XCTAssertTrue(secondSourceKeys.allSatisfy { store.get(key: $0) == nil })
        XCTAssertEqual(store.atomicWrites.last?.deletes.sorted(), secondSourceKeys.sorted())
        XCTAssertEqual(store.keys(prefix: "net.analytics.v2|second|").count, 0)
        XCTAssertEqual(store.keys(prefix: "net.analytics.v2|minute|").count, 1)

        try TrafficAggregation.compact(
            repository: finalRepository,
            now: secondNow,
            policy: policy
        )
        XCTAssertEqual(finalRepository.fetchRecords(TrafficHistoryQuery(
            level: .minute,
            start: timestamp.addingTimeInterval(-60),
            end: timestamp.addingTimeInterval(60)
        )), minuteRecords)
    }

    func testAnalyticsSnapshotRestoresCompactedHelperBreakdownAfterRestartWithoutDoubleCountingTotals() throws {
        let store = RecordingTrafficStore()
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = Date(timeIntervalSince1970: 1_800_010_000)
        let timestamp = now.addingTimeInterval(-(TrafficRetentionPolicy.secondRetention + 2 * 60 * 60))
        let helperA = self.sample(
            at: timestamp,
            network: network,
            applicationID: "app.owner",
            processID: 41,
            processName: "Helper A",
            processStartToken: 101,
            download: 10,
            upload: 1
        )
        let helperB = self.sample(
            at: timestamp.addingTimeInterval(1),
            network: network,
            applicationID: "app.owner",
            processID: 42,
            processName: "Helper B",
            processStartToken: 102,
            download: 20,
            upload: 2
        )
        let helperASecondSample = self.sample(
            at: timestamp.addingTimeInterval(2),
            network: network,
            applicationID: "app.owner",
            processID: 41,
            processName: "Helper A",
            processStartToken: 101,
            download: 5,
            upload: 4
        )
        let repository = TrafficHistoryRepository(store: store)
        XCTAssertSuccess(repository.ingest([helperA, helperB, helperASecondSample]))

        try TrafficAggregation.compact(
            repository: repository,
            now: now,
            policy: TrafficRetentionPolicy(
                minuteRetentionDays: 30,
                hourRetentionDays: 730,
                dayRetentionDays: 730
            )
        )

        let restarted = TrafficHistoryRepository(store: store)
        let raw = restarted.fetch(TrafficHistoryQuery(
            level: .minute,
            start: timestamp.addingTimeInterval(-60),
            end: timestamp.addingTimeInterval(60)
        ))
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw[0].delta, TrafficDelta(download: 35, upload: 7))

        let engine = TrafficAnalyticsEngine(repository: restarted)
        let snapshot = engine.snapshot(for: TrafficAnalyticsQuery(range: .sevenDays, now: now))
        XCTAssertEqual(snapshot.download, 35)
        XCTAssertEqual(snapshot.upload, 7)
        XCTAssertEqual(snapshot.total, 42)
        XCTAssertEqual(snapshot.buckets.reduce(UInt64(0)) { $0 + $1.download + $1.upload }, 42)
        XCTAssertEqual(snapshot.ranking.count, 1)
        XCTAssertEqual(snapshot.ranking[0].download, 35)
        XCTAssertEqual(snapshot.ranking[0].upload, 7)
        XCTAssertEqual(snapshot.ranking[0].processes, [
            ProcessTrafficSummary(
                processDiscriminator: helperA.processDiscriminator,
                processID: 41,
                processName: "Helper A",
                download: 15,
                upload: 5,
                peakBytesPerSecond: 11
            ),
            ProcessTrafficSummary(
                processDiscriminator: helperB.processDiscriminator,
                processID: 42,
                processName: "Helper B",
                download: 20,
                upload: 2,
                peakBytesPerSecond: 22
            )
        ])

        let searched = engine.snapshot(for: TrafficAnalyticsQuery(
            range: .sevenDays,
            applicationSearch: "Helper B",
            now: now
        ))
        XCTAssertEqual(searched.ranking.map(\.total), [42])
    }

    func testAnalyticsSnapshotFallsBackToRepresentativeProcessForLegacyAggregateWithoutSummaries() throws {
        let store = RecordingTrafficStore()
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = Date(timeIntervalSince1970: 1_800_010_000)
        let timestamp = now.addingTimeInterval(-(TrafficRetentionPolicy.secondRetention + 2 * 60 * 60))
        let legacy = self.sample(
            at: timestamp,
            network: network,
            applicationID: "legacy.owner",
            processID: 77,
            processName: "Legacy Representative",
            download: 30,
            upload: 12
        )
        let key = "net.analytics.v1|minute|\(String(format: "%020lld", Int64(timestamp.timeIntervalSince1970)))|wifi|legacy.owner"
        try store.writeAtomically(puts: [(key, try self.encode(legacy))], deletes: [])

        let snapshot = TrafficAnalyticsEngine(repository: TrafficHistoryRepository(store: store)).snapshot(
            for: TrafficAnalyticsQuery(range: .sevenDays, now: now)
        )

        XCTAssertEqual(snapshot.total, 42)
        XCTAssertEqual(snapshot.ranking.first?.total, 42)
        XCTAssertEqual(snapshot.ranking.first?.processes, [
            ProcessTrafficSummary(
                processDiscriminator: legacy.processDiscriminator,
                processID: 77,
                processName: "Legacy Representative",
                download: 30,
                upload: 12,
                peakBytesPerSecond: 42
            )
        ])
    }

    func testAnalyticsSnapshotKeepsCompactedPIDReuseLifetimesDistinctAfterRestart() throws {
        let store = RecordingTrafficStore()
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = Date(timeIntervalSince1970: 1_800_020_000)
        let timestamp = now.addingTimeInterval(-(TrafficRetentionPolicy.secondRetention + 2 * 60 * 60))
        let firstLifetime = self.sample(
            at: timestamp,
            network: network,
            applicationID: "app.owner",
            processID: 77,
            processName: "Helper",
            processStartToken: 101,
            download: 10,
            upload: 2
        )
        let secondLifetime = self.sample(
            at: timestamp.addingTimeInterval(1),
            network: network,
            applicationID: "app.owner",
            processID: 77,
            processName: "Helper",
            processStartToken: 202,
            download: 25,
            upload: 5
        )
        let repository = TrafficHistoryRepository(store: store)
        XCTAssertSuccess(repository.ingest([firstLifetime, secondLifetime]))

        try TrafficAggregation.compact(
            repository: repository,
            now: now,
            policy: TrafficRetentionPolicy(
                minuteRetentionDays: 30,
                hourRetentionDays: 730,
                dayRetentionDays: 730
            )
        )

        let restarted = TrafficHistoryRepository(store: store)
        let compacted = restarted.fetchRecords(TrafficHistoryQuery(
            level: .minute,
            start: timestamp.addingTimeInterval(-60),
            end: timestamp.addingTimeInterval(60)
        ))
        XCTAssertEqual(compacted.count, 1)
        XCTAssertEqual(compacted[0].sample.delta.total, 42)
        XCTAssertEqual(
            Set(compacted[0].processSummaries?.map(\.processDiscriminator) ?? []),
            Set([firstLifetime.processDiscriminator, secondLifetime.processDiscriminator])
        )

        let snapshot = TrafficAnalyticsEngine(repository: restarted).snapshot(
            for: TrafficAnalyticsQuery(range: .sevenDays, now: now)
        )
        XCTAssertEqual(snapshot.total, 42)
        XCTAssertEqual(snapshot.ranking.map(\.total), [42])
        XCTAssertEqual(snapshot.ranking[0].processes.count, 2)
        XCTAssertEqual(
            Set(snapshot.ranking[0].processes.compactMap(\.processDiscriminator)),
            Set([firstLifetime.processDiscriminator, secondLifetime.processDiscriminator])
        )
        XCTAssertEqual(snapshot.ranking[0].processes.reduce(UInt64(0)) { $0 + $1.download + $1.upload }, 42)
    }

    func testAggregateMergePropagatesUnknownCountsAcrossRestart() throws {
        let store = RecordingTrafficStore()
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_010)
        let bucketStart = Date(timeIntervalSince1970: 1_800_000_000)
        let unknown = self.sample(at: bucketStart, network: network, applicationID: "app.owner", processID: 41, processName: "Helper A", processStartToken: 101, download: 10, upload: 1)
        let initialRepository = TrafficHistoryRepository(store: store)
        try initialRepository.replaceAtomically(records: [
            StoredTrafficRecord(schema: .v2, level: .minute, sample: unknown, sampleCount: nil)
        ], deleting: TrafficHistoryQuery(level: .second, start: timestamp, end: timestamp))

        let exact = self.sample(at: timestamp.addingTimeInterval(20), network: network, applicationID: "app.owner", processID: 41, processName: "Helper A", processStartToken: 101, download: 5, upload: 4)
        let compactionNow = timestamp.addingTimeInterval(TrafficRetentionPolicy.secondRetention + 3 * 60)
        let restarted = TrafficHistoryRepository(store: store)
        XCTAssertSuccess(restarted.ingest([exact]))
        try TrafficAggregation.compact(
            repository: restarted,
            now: compactionNow,
            policy: TrafficRetentionPolicy(minuteRetentionDays: 7, hourRetentionDays: 60, dayRetentionDays: 730)
        )

        let record = TrafficHistoryRepository(store: store).fetchRecords(TrafficHistoryQuery(
            level: .minute,
            start: timestamp.addingTimeInterval(-60),
            end: timestamp.addingTimeInterval(60)
        )).first
        XCTAssertEqual(record?.sample.delta, TrafficDelta(download: 15, upload: 5))
        XCTAssertNil(record?.sampleCount)
        XCTAssertEqual(record?.processSummaries?.first?.download, 15)
        XCTAssertEqual(record?.processSummaries?.first?.upload, 5)
        XCTAssertNil(record?.processSummaries?.first?.sampleCount)
    }

    func testHistoryV2ReadsLegacyV1AndWritesOnlyV2() throws {
        let store = RecordingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let network = NetworkIdentity(id: "wifi|home%\n", displayName: "Home", interfaceName: "en0", kind: .wifi)
        let timestamp = Date(timeIntervalSince1970: 1_721_234_567)
        let legacy = self.sample(at: timestamp, network: network, applicationID: "legacy.app", download: 4, upload: 1)
        let legacyKey = "net.analytics.v1|second|00000000001721234567|wifi|home%\n|legacy.app"
        try store.writeAtomically(puts: [(legacyKey, try self.encode(legacy))], deletes: [])

        XCTAssertEqual(repository.fetch(TrafficHistoryQuery(level: .second, start: timestamp, end: timestamp)), [legacy])

        let fresh = self.sample(
            at: timestamp.addingTimeInterval(1),
            network: network,
            applicationID: "fresh|app%\n",
            processID: 7,
            processStartToken: 88,
            download: 9,
            upload: 2
        )
        XCTAssertSuccess(repository.ingest([fresh]))
        XCTAssertEqual(store.keys(prefix: "net.analytics.v1").count, 1)
        XCTAssertEqual(store.keys(prefix: "net.analytics.v2|second|").count, 1)
        XCTAssertTrue(store.keys(prefix: "net.analytics.v2|second|")[0].contains("wifi%7Chome%25%0A"))
        XCTAssertTrue(store.keys(prefix: "net.analytics.v2|second|")[0].contains("fresh%7Capp%25%0A"))
    }

    func testHistoryV2RawKeysRoundTripMultipleHelpersAcrossRestart() {
        let store = RecordingTrafficStore()
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let first = self.sample(at: timestamp, network: network, applicationID: "app.owner", processID: 41, processStartToken: 101, download: 10, upload: 1)
        let second = self.sample(at: timestamp, network: network, applicationID: "app.owner", processID: 42, processStartToken: 102, download: 20, upload: 2)

        XCTAssertSuccess(TrafficHistoryRepository(store: store).ingest([first, second]))
        XCTAssertEqual(store.keys(prefix: "net.analytics.v2|second|").count, 2)

        let restarted = TrafficHistoryRepository(store: store)
        let fetched = restarted.fetch(TrafficHistoryQuery(level: .second, start: timestamp, end: timestamp))
        XCTAssertEqual(Set(fetched.map(\.processDiscriminator)), Set([first.processDiscriminator, second.processDiscriminator]))
        XCTAssertEqual(
            TrafficHistoryRepository.makeKey(level: .minute, timestamp: timestamp, networkID: network.id, applicationID: first.application.id),
            TrafficHistoryRepository.makeKey(level: .minute, timestamp: timestamp, networkID: network.id, applicationID: second.application.id)
        )
    }

    func testCollectorBuilderCoordinatorRepositoryKeepsPIDReuseLifetimesAsDistinctV2Records() throws {
        let store = RecordingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let provider = MutableProcessMetadataProvider(entry: ProcessMetadata(
            processID: 77,
            processName: "Helper",
            executablePath: "/Applications/App.app/Helper",
            processStartToken: 111
        ))
        let runner = RecordingNettopRunner(results: [
            .success(self.pidReuseFixture(download: 10, upload: 1)),
            .success(self.pidReuseFixture(download: 20, upload: 3)),
            .success(self.pidReuseFixture(download: 5, upload: 1)),
            .success(self.pidReuseFixture(download: 12, upload: 4))
        ])
        let collector = NettopCollector(runner: runner)
        let builder = ProcessTrafficCounterBuilder(provider: provider)
        let clock = MutableTrafficClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = TrafficAnalyticsCoordinator(
            repository: repository,
            resolver: ApplicationIdentityResolver(provider: provider),
            clock: clock
        )
        coordinator.start()

        coordinator.ingest(counters: builder.counters(rows: try collector.snapshot().rows))
        clock.advance(by: 1)
        coordinator.ingest(counters: builder.counters(rows: try collector.snapshot().rows))

        provider.entry = ProcessMetadata(
            processID: 77,
            processName: "Helper",
            executablePath: "/Applications/App.app/Helper",
            processStartToken: 222
        )
        clock.advance(by: 1)
        coordinator.ingest(counters: builder.counters(rows: try collector.snapshot().rows))
        clock.advance(by: 1)
        coordinator.ingest(counters: builder.counters(rows: try collector.snapshot().rows))

        let fetched = repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_000_010)
        ))
        XCTAssertEqual(fetched.map(\.processStartToken), [111, 222])
        XCTAssertEqual(fetched.map(\.delta), [
            TrafficDelta(download: 10, upload: 2),
            TrafficDelta(download: 7, upload: 3)
        ])
        XCTAssertEqual(Set(fetched.map(\.processDiscriminator)).count, 2)
        XCTAssertEqual(store.keys(prefix: "net.analytics.v2|second|").count, 2)
    }

    func testNettopCollectorPassesExactProductionCommandIntoProductionParser() throws {
        let runner = RecordingNettopRunner(results: [.success(self.connectionFixture)])
        let collector = NettopCollector(runner: runner, timeout: 0.75)

        let result = try collector.snapshot()

        XCTAssertEqual(runner.commands, [.connectionSnapshot])
        XCTAssertEqual(runner.timeouts, [0.75])
        XCTAssertEqual(NettopCommand.connectionSnapshot.executableURL.path, "/usr/bin/nettop")
        XCTAssertEqual(
            NettopCommand.connectionSnapshot.arguments,
            ["-L", "1", "-n", "-x", "-J", "interface,bytes_in,bytes_out"]
        )
        XCTAssertEqual(result.malformedRowCount, 0)
        XCTAssertEqual(result.rows.filter { !$0.isProcessSummary }.map(\.interfaceName), ["en0", "utun4", "en0", nil])
        XCTAssertTrue(result.rows.filter { !$0.isProcessSummary }.allSatisfy { $0.processID == 55 && $0.processName == "Client Helper" })
        XCTAssertEqual(result.rows.filter { !$0.isProcessSummary }.first?.connectionID, "tcp4 10.0.0.2:1<->1.1.1.1:443")
    }

    func testConnectionCountersAggregateOncePerProcessLifetimeAndInterface() {
        let provider = FakeProcessMetadataProvider(entries: [
            55: ProcessMetadata(processID: 55, processName: "Client Helper", executablePath: "/Client", processStartToken: 900)
        ])
        let builder = ProcessTrafficCounterBuilder(provider: provider, fallbackInterfaceName: "en9")
        _ = builder.counters(rows: NettopSnapshotParser.parse(csv: self.connectionFixture).rows)

        let next = self.connectionFixture
            .replacingOccurrences(of: "100,20", with: "140,30")
            .replacingOccurrences(of: "50,10", with: "70,15")
            .replacingOccurrences(of: "25,5", with: "35,8")
            .replacingOccurrences(of: "5,1", with: "8,2")
        let counters = builder.counters(rows: NettopSnapshotParser.parse(csv: next).rows)

        XCTAssertEqual(counters.map(\.interfaceName), ["en0", "en9", "utun4"])
        XCTAssertEqual(counters.first { $0.interfaceName == "en0" }?.download, 50)
        XCTAssertEqual(counters.first { $0.interfaceName == "en0" }?.upload, 13)
        XCTAssertEqual(counters.first { $0.interfaceName == "utun4" }?.download, 20)
        XCTAssertEqual(counters.first { $0.interfaceName == "utun4" }?.upload, 5)
        XCTAssertEqual(counters.first { $0.interfaceName == "en9" }?.download, 3)
        XCTAssertEqual(counters.first { $0.interfaceName == "en9" }?.upload, 1)
    }

    func testConnectionSnapshotDeduplicatesRepeatedRowsWithoutAddingProcessSummaryBytes() {
        let provider = FakeProcessMetadataProvider(entries: [
            55: ProcessMetadata(processID: 55, processName: "Client Helper", executablePath: "/Client", processStartToken: 900)
        ])
        let builder = ProcessTrafficCounterBuilder(provider: provider)
        _ = builder.counters(rows: NettopSnapshotParser.parse(csv: self.connectionFixture).rows)
        let next = self.connectionFixture.replacingOccurrences(of: "100,20", with: "110,22")
        let counters = builder.counters(rows: NettopSnapshotParser.parse(csv: next).rows)
        let en0 = counters.first { $0.interfaceName == "en0" }
        XCTAssertEqual(en0?.download, 10)
        XCTAssertEqual(en0?.upload, 2)
    }

    func testConnectionSnapshotPrefersAttributedDuplicateOverFallbackInterface() {
        let provider = FakeProcessMetadataProvider(entries: [
            55: ProcessMetadata(processID: 55, processName: "Client Helper", executablePath: "/Client", processStartToken: 900)
        ])
        let builder = ProcessTrafficCounterBuilder(provider: provider, fallbackInterfaceName: "en9")
        let first = """
        ,interface,bytes_in,bytes_out,
        Client Helper.55,,1000,200,
        tcp4 10.0.0.2:1<->1.1.1.1:443,,100,20,
        tcp4 10.0.0.2:1<->1.1.1.1:443,en0,100,20,
        """
        let second = first.replacingOccurrences(of: "100,20", with: "125,25")

        _ = builder.counters(rows: NettopSnapshotParser.parse(csv: first).rows)
        let counters = builder.counters(rows: NettopSnapshotParser.parse(csv: second).rows)

        XCTAssertEqual(counters.count, 1)
        XCTAssertEqual(counters[0].interfaceName, "en0")
        XCTAssertEqual(counters[0].download, 25)
        XCTAssertEqual(counters[0].upload, 5)
    }

    func testConnectionSnapshotCollapsesUnattributedDuplicateWhenConcreteInterfacesExist() {
        let provider = FakeProcessMetadataProvider(entries: [
            55: ProcessMetadata(processID: 55, processName: "Client Helper", executablePath: "/Client", processStartToken: 900)
        ])
        let builder = ProcessTrafficCounterBuilder(provider: provider, fallbackInterfaceName: "en9")
        let first = """
        ,interface,bytes_in,bytes_out,
        Client Helper.55,,1000,200,
        tcp4 a<->b,,500,100,
        tcp4 a<->b,en0,100,20,
        tcp4 a<->b,en0,100,20,
        tcp4 a<->b,utun3,50,10,
        """
        let second = """
        ,interface,bytes_in,bytes_out,
        Client Helper.55,,1100,220,
        tcp4 a<->b,,700,140,
        tcp4 a<->b,en0,125,25,
        tcp4 a<->b,en0,125,25,
        tcp4 a<->b,utun3,60,12,
        """

        _ = builder.counters(rows: NettopSnapshotParser.parse(csv: first).rows)
        let counters = builder.counters(rows: NettopSnapshotParser.parse(csv: second).rows)

        XCTAssertEqual(counters.map(\.interfaceName), ["en0", "utun3"])
        XCTAssertEqual(counters.first { $0.interfaceName == "en0" }?.download, 25)
        XCTAssertEqual(counters.first { $0.interfaceName == "en0" }?.upload, 5)
        XCTAssertEqual(counters.first { $0.interfaceName == "utun3" }?.download, 10)
        XCTAssertEqual(counters.first { $0.interfaceName == "utun3" }?.upload, 2)
        XCTAssertNil(counters.first { $0.interfaceName == "en9" })
    }

    func testConnectionSnapshotPreservesSameBaseConnectionOnPhysicalAndTunnelInterfaces() {
        let provider = FakeProcessMetadataProvider(entries: [
            55: ProcessMetadata(processID: 55, processName: "Client Helper", executablePath: "/Client", processStartToken: 900)
        ])
        let builder = ProcessTrafficCounterBuilder(provider: provider)
        let first = """
        ,interface,bytes_in,bytes_out,
        Client Helper.55,,1000,200,
        tcp4 a<->b,en0,100,20,
        tcp4 a<->b,utun3,50,10,
        """
        let second = """
        ,interface,bytes_in,bytes_out,
        Client Helper.55,,1100,220,
        tcp4 a<->b,en0,130,26,
        tcp4 a<->b,utun3,70,15,
        """

        _ = builder.counters(rows: NettopSnapshotParser.parse(csv: first).rows)
        let counters = builder.counters(rows: NettopSnapshotParser.parse(csv: second).rows)

        XCTAssertEqual(counters.map(\.interfaceName), ["en0", "utun3"])
        XCTAssertEqual(counters.first { $0.interfaceName == "en0" }?.download, 30)
        XCTAssertEqual(counters.first { $0.interfaceName == "en0" }?.upload, 6)
        XCTAssertEqual(counters.first { $0.interfaceName == "utun3" }?.download, 20)
        XCTAssertEqual(counters.first { $0.interfaceName == "utun3" }?.upload, 5)
    }

    func testConnectionInterfaceMigrationResetsBaselineWithoutSpuriousDelta() {
        let provider = FakeProcessMetadataProvider(entries: [
            55: ProcessMetadata(processID: 55, processName: "Client Helper", executablePath: "/Client", processStartToken: 900)
        ])
        let builder = ProcessTrafficCounterBuilder(provider: provider)
        let physical = """
        ,interface,bytes_in,bytes_out,
        Client Helper.55,,1000,200,
        tcp4 a<->b,en0,100,20,
        """
        let tunnel = """
        ,interface,bytes_in,bytes_out,
        Client Helper.55,,1100,220,
        tcp4 a<->b,utun3,130,26,
        """
        let tunnelNext = tunnel
            .replacingOccurrences(of: "130,26", with: "145,30")

        _ = builder.counters(rows: NettopSnapshotParser.parse(csv: physical).rows)
        let migrated = builder.counters(rows: NettopSnapshotParser.parse(csv: tunnel).rows)
        let next = builder.counters(rows: NettopSnapshotParser.parse(csv: tunnelNext).rows)

        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].interfaceName, "utun3")
        XCTAssertEqual(migrated[0].download, 0)
        XCTAssertEqual(migrated[0].upload, 0)
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].interfaceName, "utun3")
        XCTAssertEqual(next[0].download, 15)
        XCTAssertEqual(next[0].upload, 4)
    }

    func testConnectionCounterDirectionResetsAreIndependent() {
        let provider = FakeProcessMetadataProvider(entries: [
            55: ProcessMetadata(processID: 55, processName: "Client", executablePath: "/Client", processStartToken: 900)
        ])
        let builder = ProcessTrafficCounterBuilder(provider: provider)
        let initial = """
        ,interface,bytes_in,bytes_out,
        Client.55,,1000,200,
        tcp4 a<->b,en0,100,20,
        """
        let downloadReset = """
        ,interface,bytes_in,bytes_out,
        Client.55,,1100,220,
        tcp4 a<->b,en0,10,25,
        """
        let uploadReset = """
        ,interface,bytes_in,bytes_out,
        Client.55,,1200,240,
        tcp4 a<->b,en0,30,3,
        """

        _ = builder.counters(rows: NettopSnapshotParser.parse(csv: initial).rows)
        let first = builder.counters(rows: NettopSnapshotParser.parse(csv: downloadReset).rows)
        let second = builder.counters(rows: NettopSnapshotParser.parse(csv: uploadReset).rows)

        XCTAssertEqual(first.first?.download, 0)
        XCTAssertEqual(first.first?.upload, 5)
        XCTAssertEqual(second.first?.download, 20)
        XCTAssertEqual(second.first?.upload, 0)
    }

    func testProcessNettopRunnerTimeoutCleanupEscalatesAndSynchronizesReadersWithinBounds() {
        let execution = RecordingNettopExecution(
            waits: [false, false, false, true],
            readerWaits: [true]
        )
        let runner = ProcessNettopRunner(executionFactory: { execution })

        XCTAssertThrowsError(try runner.run(command: .connectionSnapshot, timeout: 0.25)) { error in
            XCTAssertEqual(error as? NettopCollectionError, .timedOut)
        }
        XCTAssertEqual(execution.events, [
            .start,
            .waitForExit(0.25),
            .terminate,
            .waitForExit(0.2),
            .interrupt,
            .waitForExit(0.2),
            .kill,
            .waitForExit(0.2),
            .closeReaders,
            .waitForReaders(0.2)
        ])
        XCTAssertFalse(execution.usedUnboundedWait)
    }

    func testProcessReaderRetriesLaunchTimeoutEmptyMalformedThenRecoversWithCappedBackoff() {
        let runner = RecordingNettopRunner(results: [
            .failure(.launchFailed("launch")),
            .failure(.timedOut),
            .failure(.emptyOutput),
            .success(",interface,bytes_in,bytes_out,\nbroken.1,en0,nope,2,\n"),
            .success(self.pidReuseFixture(download: 10, upload: 1))
        ])
        let clock = MutableTrafficClock(now: Date(timeIntervalSince1970: 10))
        let scheduler = ManualProcessReadScheduler(clock: clock)
        let provider = FakeProcessMetadataProvider(entries: [
            77: ProcessMetadata(processID: 77, processName: "Helper", executablePath: "/Helper", processStartToken: 1)
        ])
        let reader = ProcessReader(
            .network,
            collector: NettopCollector(runner: runner, timeout: 0.25),
            counterBuilder: ProcessTrafficCounterBuilder(provider: provider),
            scheduler: scheduler
        )
        var diagnostics: [String] = []
        var ingested: [[ProcessTrafficCounter]] = []
        reader.analyticsFailure = { diagnostics.append($0) }
        reader.analyticsIngest = { ingested.append($0) }

        reader.read()
        XCTAssertEqual(scheduler.delays, [1])
        scheduler.runNext()
        XCTAssertEqual(scheduler.delays, [1, 2])
        scheduler.runNext()
        XCTAssertEqual(scheduler.delays, [1, 2, 4])
        scheduler.runNext()
        XCTAssertEqual(scheduler.delays, [1, 2, 4, 8])
        scheduler.runNext()

        XCTAssertEqual(runner.timeouts, [0.25, 0.25, 0.25, 0.25, 0.25])
        XCTAssertEqual(diagnostics.count, 4)
        XCTAssertEqual(ingested.count, 1)
        XCTAssertTrue(scheduler.delays.allSatisfy { $0 <= 30 })
        XCTAssertFalse(scheduler.hasPendingWork)
    }

    func testProcessReaderFailureBackoffCapsAtThirtySeconds() {
        let runner = RecordingNettopRunner(results: Array(repeating: .failure(.timedOut), count: 8))
        let clock = MutableTrafficClock(now: Date(timeIntervalSince1970: 10))
        let scheduler = ManualProcessReadScheduler(clock: clock)
        let reader = ProcessReader(
            .network,
            collector: NettopCollector(runner: runner),
            counterBuilder: ProcessTrafficCounterBuilder(provider: FakeProcessMetadataProvider(entries: [:])),
            scheduler: scheduler
        )

        reader.read()
        for _ in 0..<7 { scheduler.runNext() }

        XCTAssertEqual(scheduler.delays, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testProcessReaderStopCancelsScheduledRetryWithoutCollectorOrCallbacks() {
        let runner = RecordingNettopRunner(results: [
            .failure(.timedOut),
            .success(self.pidReuseFixture(download: 10, upload: 1))
        ])
        let clock = MutableTrafficClock(now: Date(timeIntervalSince1970: 10))
        let scheduler = ManualProcessReadScheduler(clock: clock)
        let reader = ProcessReader(
            .network,
            collector: NettopCollector(runner: runner),
            counterBuilder: ProcessTrafficCounterBuilder(provider: FakeProcessMetadataProvider(entries: [:])),
            scheduler: scheduler
        )
        var failures = 0
        var callbacks = 0
        var ingests = 0
        var stops = 0
        reader.analyticsFailure = { _ in failures += 1 }
        reader.analyticsIngest = { _ in ingests += 1 }
        reader.analyticsStop = { stops += 1 }
        reader.callbackHandler = { _ in callbacks += 1 }

        reader.read()
        XCTAssertEqual(runner.timeouts.count, 1)
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(scheduler.hasPendingWork)

        reader.stop()
        scheduler.runNext()

        XCTAssertEqual(runner.timeouts.count, 1)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(ingests, 0)
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(scheduler.hasPendingWork)
        XCTAssertEqual(scheduler.delays, [1])
    }

    func testProcessReaderClearResetsConnectionBaseline() {
        let runner = RecordingNettopRunner(results: [
            .success(self.pidReuseFixture(download: 100, upload: 10)),
            .success(self.pidReuseFixture(download: 140, upload: 15)),
            .success(self.pidReuseFixture(download: 200, upload: 20)),
            .success(self.pidReuseFixture(download: 225, upload: 23))
        ])
        let provider = FakeProcessMetadataProvider(entries: [
            77: ProcessMetadata(processID: 77, processName: "Helper", executablePath: "/Helper", processStartToken: 1)
        ])
        let reader = ProcessReader(
            .network,
            collector: NettopCollector(runner: runner),
            counterBuilder: ProcessTrafficCounterBuilder(provider: provider)
        )
        var ingested: [[ProcessTrafficCounter]] = []
        reader.analyticsIngest = { ingested.append($0) }

        reader.read()
        reader.read()
        reader.resetTrafficBaselines()
        reader.read()
        reader.read()

        XCTAssertEqual(ingested.count, 4)
        XCTAssertEqual(ingested[1].first?.download, 40)
        XCTAssertEqual(ingested[1].first?.upload, 5)
        XCTAssertEqual(ingested[2].first?.download, 0)
        XCTAssertEqual(ingested[2].first?.upload, 0)
        XCTAssertEqual(ingested[3].first?.download, 25)
        XCTAssertEqual(ingested[3].first?.upload, 3)
    }

    func testProcessReaderStopCancelsInFlightCollectionWithoutCallbacksOrRetry() {
        let runner = BlockingNettopRunner(
            blockedResult: .failure(.timedOut),
            remainingResults: []
        )
        let scheduler = ManualProcessReadScheduler(clock: MutableTrafficClock(now: Date(timeIntervalSince1970: 10)))
        let reader = ProcessReader(
            .network,
            collector: NettopCollector(runner: runner),
            counterBuilder: ProcessTrafficCounterBuilder(provider: FakeProcessMetadataProvider(entries: [:])),
            scheduler: scheduler
        )
        var failures = 0
        var callbacks = 0
        var ingests = 0
        reader.analyticsFailure = { _ in failures += 1 }
        reader.analyticsIngest = { _ in ingests += 1 }
        reader.callbackHandler = { _ in callbacks += 1 }

        let readFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            reader.read()
            readFinished.signal()
        }
        XCTAssertTrue(runner.waitUntilBlockedRunStarts())

        reader.stop()

        XCTAssertEqual(runner.cancelCount, 1)
        XCTAssertTrue(runner.waitUntilBlockedRunFinishes())
        XCTAssertEqual(readFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(ingests, 0)
        XCTAssertEqual(callbacks, 0)
        XCTAssertFalse(scheduler.hasPendingWork)
    }

    func testProcessReaderRejectsStaleCompletionAndResetsConnectionBaselineAfterRestart() {
        let old = self.pidReuseFixture(download: 100, upload: 10)
        let firstAfterRestart = self.pidReuseFixture(download: 200, upload: 20)
        let secondAfterRestart = self.pidReuseFixture(download: 230, upload: 24)
        let runner = BlockingNettopRunner(
            blockedResult: .success(old),
            remainingResults: [.success(firstAfterRestart), .success(secondAfterRestart)],
            finishBlockedRunOnCancel: false
        )
        let scheduler = ManualProcessReadScheduler(clock: MutableTrafficClock(now: Date(timeIntervalSince1970: 10)))
        let provider = FakeProcessMetadataProvider(entries: [
            77: ProcessMetadata(processID: 77, processName: "Helper", executablePath: "/Helper", processStartToken: 1)
        ])
        let reader = ProcessReader(
            .network,
            collector: NettopCollector(runner: runner),
            counterBuilder: ProcessTrafficCounterBuilder(provider: provider),
            scheduler: scheduler
        )
        var failures = 0
        var callbacks = 0
        var ingested: [[ProcessTrafficCounter]] = []
        reader.analyticsFailure = { _ in failures += 1 }
        reader.analyticsIngest = { ingested.append($0) }
        reader.callbackHandler = { _ in callbacks += 1 }

        let oldReadFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            reader.read()
            oldReadFinished.signal()
        }
        XCTAssertTrue(runner.waitUntilBlockedRunStarts())

        reader.stop()
        reader.start()
        runner.finishBlockedRun()
        XCTAssertTrue(runner.waitUntilBlockedRunFinishes())
        XCTAssertEqual(oldReadFinished.wait(timeout: .now() + 1), .success)

        reader.read()
        reader.read()

        XCTAssertEqual(runner.cancelCount, 1)
        XCTAssertEqual(runner.runCount, 3)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(callbacks, 2)
        XCTAssertEqual(ingested.count, 2)
        XCTAssertEqual(ingested[0].first?.download, 0)
        XCTAssertEqual(ingested[0].first?.upload, 0)
        XCTAssertEqual(ingested[1].first?.download, 30)
        XCTAssertEqual(ingested[1].first?.upload, 4)
        XCTAssertFalse(scheduler.hasPendingWork)
    }

    func testProductionAnalyticsClearRejectsBlockedPreClearCompletionAndRestartsWithBaseline() throws {
        let old = self.pidReuseFixture(download: 100, upload: 10)
        let firstAfterClear = self.pidReuseFixture(download: 200, upload: 20)
        let secondAfterClear = self.pidReuseFixture(download: 230, upload: 24)
        let runner = BlockingNettopRunner(
            blockedResult: .success(old),
            remainingResults: [.success(firstAfterClear), .success(secondAfterClear)],
            finishBlockedRunOnCancel: false
        )
        let provider = FakeProcessMetadataProvider(entries: [
            77: ProcessMetadata(processID: 77, processName: "Helper", executablePath: "/Helper", processStartToken: 1)
        ])
        let reader = ProcessReader(
            .network,
            collector: NettopCollector(runner: runner),
            counterBuilder: ProcessTrafficCounterBuilder(provider: provider)
        )
        let store = RecordingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let clock = MutableTrafficClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = TrafficAnalyticsCoordinator(
            repository: repository,
            resolver: ApplicationIdentityResolver(provider: provider),
            clock: clock
        )
        coordinator.start()
        reader.analyticsIngest = { coordinator.ingest(counters: $0) }

        let oldReadFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            reader.read()
            oldReadFinished.signal()
        }
        XCTAssertTrue(runner.waitUntilBlockedRunStarts())

        let clearFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            try? reader.clearAnalyticsData {
                try coordinator.clearAnalyticsData()
            }
            clearFinished.signal()
        }
        XCTAssertEqual(clearFinished.wait(timeout: .now() + 0.05), .timedOut)

        runner.finishBlockedRun()
        XCTAssertTrue(runner.waitUntilBlockedRunFinishes())
        XCTAssertEqual(oldReadFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(clearFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: clock.now().addingTimeInterval(-1),
            end: clock.now().addingTimeInterval(1)
        )).isEmpty)

        reader.read()
        XCTAssertTrue(repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: clock.now().addingTimeInterval(-1),
            end: clock.now().addingTimeInterval(1)
        )).isEmpty)

        clock.advance(by: 1)
        reader.read()

        let samples = repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_000_001)
        ))
        XCTAssertEqual(samples.map(\.delta), [TrafficDelta(download: 30, upload: 4)])
        XCTAssertEqual(coordinator.snapshot().samplesWritten, 1)
        XCTAssertEqual(runner.cancelCount, 1)
    }

    func testProcessReaderTerminateStopsAnalyticsOnce() {
        let reader = ProcessReader(
            .network,
            collector: NettopCollector(runner: RecordingNettopRunner(results: [])),
            counterBuilder: ProcessTrafficCounterBuilder(provider: FakeProcessMetadataProvider(entries: [:]))
        )
        var stops = 0
        reader.analyticsStop = { stops += 1 }

        reader.terminate()

        XCTAssertEqual(stops, 1)
    }

    func testProcessReaderLifecycleRestartsAnalyticsAfterDisable() {
        let reader = ProcessReader(
            .network,
            collector: NettopCollector(runner: RecordingNettopRunner(results: [
                .success(self.pidReuseFixture(download: 1, upload: 1))
            ])),
            counterBuilder: ProcessTrafficCounterBuilder(provider: FakeProcessMetadataProvider(entries: [:]))
        )
        var starts = 0
        var stops = 0
        reader.analyticsStart = { starts += 1 }
        reader.analyticsStop = { stops += 1 }

        reader.stop()
        reader.start()

        XCTAssertEqual(stops, 1)
        XCTAssertEqual(starts, 1)
    }

    func testNettopCollectorRejectsOutputWithoutUsableRows() {
        let outputs = [
            ",interface,bytes_in,bytes_out,\n",
            ",interface,bytes_in,bytes_out,\nbroken.1,en0,nope,2,\n",
            ",interface,bytes_in,bytes_out,\ntcp4 a<->b,en0,10,2,\n"
        ]

        for (index, output) in outputs.enumerated() {
            let collector = NettopCollector(runner: RecordingNettopRunner(results: [.success(output)]))
            XCTAssertThrowsError(try collector.snapshot()) { error in
                let expected: NettopCollectionError = index == 0 ? .emptyOutput : .malformedOutput(1)
                XCTAssertEqual(error as? NettopCollectionError, expected)
            }
        }
    }

    func testLegacyAggregateWithoutSampleCountRemainsUnknown() throws {
        let store = RecordingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = self.sample(at: timestamp, network: NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi), applicationID: "app", download: 10, upload: 2)
        let key = "net.analytics.v1|minute|00000000001700000000|wifi|app"
        try store.writeAtomically(puts: [(key, try self.encode(sample))], deletes: [])

        let records = repository.fetchRecords(TrafficHistoryQuery(level: .minute, start: timestamp, end: timestamp))
        XCTAssertEqual(records.first?.sampleCount, nil)
    }

    func testHistoryRepositorySerializesStoreAccessOnItsOwnerQueue() {
        let key = DispatchSpecificKey<String>()
        let queue = DispatchQueue(label: "tests.analytics.owner")
        queue.setSpecific(key: key, value: "owner")
        let store = RecordingTrafficStore(queueKey: key, expectedQueueValue: "owner")
        let repository = TrafficHistoryRepository(store: store, queue: queue)
        let sample = self.sample(at: Date(timeIntervalSince1970: 10), network: NetworkIdentity(id: "n", displayName: "N", interfaceName: "en0", kind: .wifi), applicationID: "a", download: 1, upload: 1)

        XCTAssertSuccess(repository.ingest([sample]))
        _ = repository.fetch(TrafficHistoryQuery(level: .second, start: sample.timestamp, end: sample.timestamp))
        XCTAssertTrue(store.accessesAllOnExpectedQueue)
    }

    func testHistoryReplacementCommitsDestinationsAndSourceDeletesAtomically() throws {
        let store = RecordingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let timestamp = Date(timeIntervalSince1970: 100)
        let source = self.sample(at: timestamp, network: network, applicationID: "app", download: 1, upload: 1)
        XCTAssertSuccess(repository.ingest([source]))
        let sourceKeys = store.keys(prefix: "net.analytics.v2|second|")

        let destination = self.sample(at: timestamp, network: network, applicationID: "app", download: 2, upload: 2)
        try repository.replaceAtomically(level: .minute, samples: [destination], deleting: sourceKeys)

        XCTAssertEqual(store.atomicWrites.last?.puts.count, 1)
        XCTAssertEqual(store.atomicWrites.last?.deletes, sourceKeys)
        XCTAssertTrue(store.keys(prefix: "net.analytics.v2|second|").isEmpty)
        XCTAssertEqual(store.keys(prefix: "net.analytics.v2|minute|").count, 1)
    }

    func testRawIngestMergesSameSecondSamplesAcrossBatchAndSequentialWrites() {
        let store = RecordingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let timestamp = Date(timeIntervalSince1970: 100.25)
        let first = self.sample(at: timestamp, network: network, applicationID: "app", processID: 7, processStartToken: 9, download: 10, upload: 2)
        let second = self.sample(at: timestamp.addingTimeInterval(0.5), network: network, applicationID: "app", processID: 7, processStartToken: 9, download: 20, upload: 3)
        let third = self.sample(at: timestamp.addingTimeInterval(0.7), network: network, applicationID: "app", processID: 7, processStartToken: 9, download: 5, upload: 4)

        XCTAssertSuccess(repository.ingest([first, second]))
        XCTAssertSuccess(repository.ingest([third]))

        let records = repository.fetchRecords(TrafficHistoryQuery(
            level: .second,
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 101)
        ))
        XCTAssertEqual(store.keys(prefix: "net.analytics.v2|second|").count, 1)
        XCTAssertEqual(records.count, 1)
        guard let record = records.first else { return }
        XCTAssertEqual(record.sample.delta, TrafficDelta(download: 35, upload: 9))
        XCTAssertEqual(record.sample.peakBytesPerSecond, 23)
        XCTAssertEqual(record.sampleCount, 3)
        XCTAssertEqual(record.processSummaries?.map(\.sampleCount), [3])
    }

    func testCoordinatorRetryMergesPendingAndNewSameSecondSampleWithoutDuplicateKeyFailure() {
        let store = RecordingTrafficStore()
        store.failNextWrite = true
        let repository = TrafficHistoryRepository(store: store)
        let clock = MutableTrafficClock(now: Date(timeIntervalSince1970: 100.1))
        let coordinator = TrafficAnalyticsCoordinator(repository: repository, clock: clock)
        coordinator.start()

        coordinator.ingest(counters: [ProcessTrafficCounter(
            identity: self.identity,
            processID: 42,
            processStartToken: 1,
            isDelta: true,
            download: 10,
            upload: 1
        )])
        clock.advance(by: 0.5)
        coordinator.ingest(counters: [ProcessTrafficCounter(
            identity: self.identity,
            processID: 42,
            processStartToken: 1,
            isDelta: true,
            download: 20,
            upload: 2
        )])

        let records = repository.fetchRecords(TrafficHistoryQuery(
            level: .second,
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 101)
        ))
        XCTAssertEqual(store.atomicWrites.count, 1)
        XCTAssertEqual(store.atomicWrites[0].puts.count, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sample.delta, TrafficDelta(download: 30, upload: 3))
        XCTAssertEqual(records[0].sampleCount, 2)
        XCTAssertEqual(coordinator.snapshot().samplesWritten, 2)
        XCTAssertNil(coordinator.snapshot().lastError)
    }

    func testAtomicIngestFailureProducesNoCommittedBatch() {
        let store = RecordingTrafficStore()
        store.failNextWrite = true
        let repository = TrafficHistoryRepository(store: store)
        let sample = self.sample(at: Date(timeIntervalSince1970: 100), network: NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi), applicationID: "app", download: 1, upload: 1)

        XCTAssertFailure(repository.ingest([sample]))
        XCTAssertTrue(repository.fetch(TrafficHistoryQuery(level: .second, start: sample.timestamp, end: sample.timestamp)).isEmpty)
    }

    func testDBRawBatchRejectsDuplicatePutKeysWithoutCrashing() {
        XCTAssertThrowsError(try DB.shared.writeRawAtomically(
            puts: [("duplicate", "first"), ("duplicate", "second")],
            deletes: []
        )) { error in
            XCTAssertEqual(error as? DB.RawWriteError, .duplicateKey("duplicate"))
        }
    }

    func testFailedAtomicReplacementNeverPublishesPartialDestinationOrSourceDeletion() throws {
        let store = IsolatedTransactionTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let timestamp = Date(timeIntervalSince1970: 100)
        let source = self.sample(at: timestamp, network: network, applicationID: "app", download: 1, upload: 1)
        XCTAssertSuccess(repository.ingest([source]))
        let sourceKeys = store.keys(prefix: "net.analytics.v2|second|")
        store.failAfterApplyingToIsolatedTransaction = true

        let destination = self.sample(at: timestamp, network: network, applicationID: "app", download: 2, upload: 2)
        XCTAssertThrowsError(try repository.replaceAtomically(
            level: .minute,
            samples: [destination],
            deleting: sourceKeys
        ))

        XCTAssertEqual(store.lastAttempt?.puts.count, 1)
        XCTAssertEqual(store.lastAttempt?.deletes, sourceKeys)
        XCTAssertEqual(store.keys(prefix: "net.analytics.v2|second|"), sourceKeys)
        XCTAssertTrue(store.keys(prefix: "net.analytics.v2|minute|").isEmpty)
        XCTAssertEqual(repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: timestamp,
            end: timestamp
        )), [source])
        XCTAssertTrue(repository.fetch(TrafficHistoryQuery(
            level: .minute,
            start: timestamp,
            end: timestamp
        )).isEmpty)
    }

    func testDeleteTrafficHistoryUsesDelimiterBoundedNamespaces() throws {
        let store = RecordingTrafficStore()
        try store.writeAtomically(puts: [
            ("net.analytics.v1|second|legacy", "legacy"),
            ("net.analytics.v2|second|current", "current"),
            ("net.analytics.v10|second|other", "other-v10"),
            ("net.analytics.v20|second|other", "other-v20")
        ], deletes: [])
        let repository = TrafficHistoryRepository(store: store)

        try repository.deleteTrafficHistory()

        XCTAssertTrue(store.keys(prefix: "net.analytics.v1|").isEmpty)
        XCTAssertTrue(store.keys(prefix: "net.analytics.v2|").isEmpty)
        XCTAssertEqual(store.keys(prefix: "net.analytics.v10|"), ["net.analytics.v10|second|other"])
        XCTAssertEqual(store.keys(prefix: "net.analytics.v20|"), ["net.analytics.v20|second|other"])
    }

    func testCompactionPropagatesReplacementFailure() {
        let store = RecordingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertSuccess(repository.ingest([
            self.sample(at: now.addingTimeInterval(-(TrafficRetentionPolicy.secondRetention + 2 * 60)), network: network, applicationID: "app", download: 1, upload: 1)
        ]))
        store.failNextWrite = true

        XCTAssertThrowsError(try TrafficAggregation.compact(
            repository: repository,
            now: now,
            policy: TrafficRetentionPolicy(minuteRetentionDays: 7, hourRetentionDays: 60, dayRetentionDays: 730)
        )) { error in
            XCTAssertTrue(error is TrafficPersistenceError)
        }
    }

    func testDeleteTrafficHistoryPreservesAlertsRulesAndPreferences() throws {
        let suiteName = "net.analytics.delete.traffic.tests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let alertStore = TrafficAlertStore(defaults: defaults)
        alertStore.append([TrafficAlertEvent(kind: .quota, message: "quota")])
        let rules = TrafficRuleStore(defaults: defaults)
        rules.save(networkPlan: NetworkPlan(billingCycleDay: 3, byteLimit: 99, thresholds: [50]))
        rules.markNotified(thresholds: [50], scope: "network")
        let preferences = TrafficAnalyticsPreferencesStore(defaults: defaults)
        var value = preferences.preferences()
        value.minuteRetentionDays = 14
        preferences.save(value)
        let repository = TrafficHistoryRepository(store: RecordingTrafficStore(), alertStore: alertStore, ruleStore: rules)
        XCTAssertSuccess(repository.ingest([self.sample(at: Date(), network: NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi), applicationID: "app", download: 1, upload: 1)]))

        try repository.deleteTrafficHistory()
        XCTAssertEqual(alertStore.all().count, 1)
        XCTAssertEqual(rules.networkPlan().billingCycleDay, 3)
        XCTAssertEqual(rules.notifiedThresholds(for: "network"), [50])
        XCTAssertEqual(preferences.preferences().minuteRetentionDays, 14)
    }

    func testClearAnalyticsDataRemovesTrafficAlertsAndRuntimeStateButPreservesPreferences() throws {
        let suiteName = "net.analytics.clear.tests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let alertStore = TrafficAlertStore(defaults: defaults)
        alertStore.append([TrafficAlertEvent(kind: .quota, message: "quota")])
        let rules = TrafficRuleStore(defaults: defaults)
        let plan = NetworkPlan(billingCycleDay: 7, byteLimit: 100, thresholds: [80])
        rules.save(networkPlan: plan)
        let appRule = ApplicationTrafficRule(applicationID: "app", byteLimit: 50)
        rules.save(applicationRules: [appRule])
        rules.includeLocalNetwork = false
        rules.markNotified(thresholds: [80], scope: "network")
        defaults.set(["app": "Alias"], forKey: "net.analytics.aliases.v1")
        let preferences = TrafficAnalyticsPreferencesStore(defaults: defaults)
        var value = preferences.preferences()
        value.hourRetentionDays = 90
        preferences.save(value)
        let repository = TrafficHistoryRepository(store: RecordingTrafficStore(), alertStore: alertStore, ruleStore: rules)
        XCTAssertSuccess(repository.ingest([self.sample(at: Date(), network: NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi), applicationID: "app", download: 1, upload: 1)]))

        try repository.clearAnalyticsData()
        XCTAssertTrue(alertStore.all().isEmpty)
        XCTAssertTrue(rules.notifiedThresholds(for: "network").isEmpty)
        XCTAssertEqual(rules.networkPlan(), plan)
        XCTAssertEqual(rules.applicationRules(), [appRule])
        XCTAssertFalse(rules.includeLocalNetwork)
        XCTAssertEqual(preferences.preferences().hourRetentionDays, 90)
        XCTAssertEqual(defaults.dictionary(forKey: "net.analytics.aliases.v1") as? [String: String], ["app": "Alias"])
    }

    func testSettingsDelegatesConfirmedAnalyticsClearToInjectedService() throws {
        let settings = Settings(.network)
        var clearCalls = 0
        settings.clearAnalyticsHistoryCallback = { clearCalls += 1 }

        try settings.performAnalyticsClear()

        XCTAssertEqual(clearCalls, 1)
    }

    func testRetentionDefaultsAreFixed24HoursAndConfigurable7_60_730Days() {
        XCTAssertEqual(TrafficRetentionPolicy.secondRetention, 24 * 60 * 60)
        XCTAssertEqual(TrafficRetentionPolicy.standard.minuteRetentionDays, 7)
        XCTAssertEqual(TrafficRetentionPolicy.standard.hourRetentionDays, 60)
        XCTAssertEqual(TrafficRetentionPolicy.standard.dayRetentionDays, 730)
        XCTAssertEqual(TrafficRetentionPolicy.standard.compactionBatchSize, 2_000)

        let custom = TrafficRetentionPolicy(
            minuteRetentionDays: 3,
            hourRetentionDays: 14,
            dayRetentionDays: 365,
            compactionBatchSize: 25
        )
        XCTAssertEqual(custom.minuteRetentionDays, 3)
        XCTAssertEqual(custom.hourRetentionDays, 14)
        XCTAssertEqual(custom.dayRetentionDays, 365)
        XCTAssertEqual(custom.compactionBatchSize, 25)

        let preferences = TrafficAnalyticsPreferences.default
        XCTAssertEqual(preferences.minuteRetentionDays, 7)
        XCTAssertEqual(preferences.hourRetentionDays, 60)
        XCTAssertEqual(preferences.dayRetentionDays, 730)
    }

    func testSettingsResetInvokesClearAnalyticsDataNotTrafficOnlyDeletion() throws {
        let suiteName = "net.analytics.settings.clear.semantics.tests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let alerts = TrafficAlertStore(defaults: defaults)
        alerts.append([TrafficAlertEvent(kind: .quota, message: "quota")])
        let rules = TrafficRuleStore(defaults: defaults)
        rules.save(networkPlan: NetworkPlan(billingCycleDay: 9, byteLimit: 100, thresholds: [80]))
        rules.markNotified(thresholds: [80], scope: "network")
        let repository = TrafficHistoryRepository(
            store: InMemoryTrafficStore(),
            alertStore: alerts,
            ruleStore: rules
        )
        let settings = Settings(.network)
        settings.clearAnalyticsHistoryCallback = { try repository.clearAnalyticsData() }

        try settings.performAnalyticsClear()

        XCTAssertTrue(alerts.all().isEmpty)
        XCTAssertTrue(rules.notifiedThresholds(for: "network").isEmpty)
        XCTAssertEqual(rules.networkPlan().billingCycleDay, 9)
    }

    func testCompactionPromotesSecondMinuteHourDayMonthAndYearWithoutLoss() throws {
        let calendar = self.calendar(timeZone: "UTC")
        let store = RecordingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let sourceDate = self.date(2022, 1, 15, 12, 0, 10, calendar: calendar)
        let now = self.date(2025, 3, 15, 12, 0, 0, calendar: calendar)
        XCTAssertSuccess(repository.ingest([
            self.sample(at: sourceDate, network: network, applicationID: "app", download: 10, upload: 1),
            self.sample(at: sourceDate.addingTimeInterval(20), network: network, applicationID: "app", download: 20, upload: 2)
        ]))

        try TrafficAggregation.compact(
            repository: repository,
            now: now,
            policy: TrafficRetentionPolicy(
                minuteRetentionDays: 1,
                hourRetentionDays: 1,
                dayRetentionDays: 1,
                compactionBatchSize: 2_000
            ),
            calendar: calendar
        )

        for level in [TrafficAggregationLevel.second, .minute, .hour, .day] {
            XCTAssertTrue(repository.fetchRecords(TrafficHistoryQuery(
                level: level,
                start: self.date(2020, 1, 1, calendar: calendar),
                end: now
            )).isEmpty, "Expected \(level) to be promoted")
        }
        let months = repository.fetchRecords(TrafficHistoryQuery(
            level: .month,
            start: self.date(2020, 1, 1, calendar: calendar),
            end: now
        ))
        let years = repository.fetchRecords(TrafficHistoryQuery(
            level: .year,
            start: self.date(2020, 1, 1, calendar: calendar),
            end: now
        ))
        XCTAssertEqual(months.map(\.sample.delta.total), [33])
        XCTAssertEqual(years.map(\.sample.delta.total), [33])

        try TrafficAggregation.compact(
            repository: TrafficHistoryRepository(store: store),
            now: now,
            policy: TrafficRetentionPolicy(
                minuteRetentionDays: 1,
                hourRetentionDays: 1,
                dayRetentionDays: 1,
                compactionBatchSize: 2_000
            ),
            calendar: calendar
        )
        XCTAssertEqual(TrafficHistoryRepository(store: store).fetchRecords(TrafficHistoryQuery(
            level: .year,
            start: self.date(2020, 1, 1, calendar: calendar),
            end: now
        )).map(\.sample.delta.total), [33])
    }

    func testRetentionAtNonAlignedNowWaitsForWholeDestinationBucketBeforeCompacting() throws {
        let calendar = self.calendar(timeZone: "UTC")
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = self.date(2026, 7, 18, 12, 34, 30, calendar: calendar)
        let cutoff = now.addingTimeInterval(-TrafficRetentionPolicy.secondRetention)
        let previousMinute = cutoff.addingTimeInterval(-45)
        let partialMinute = cutoff.addingTimeInterval(-10)
        XCTAssertSuccess(repository.ingest([
            self.sample(at: previousMinute, network: network, applicationID: "old", download: 10, upload: 0),
            self.sample(at: partialMinute, network: network, applicationID: "partial", download: 20, upload: 0)
        ]))

        try TrafficAggregation.compact(repository: repository, now: now, policy: .standard, calendar: calendar)

        XCTAssertEqual(repository.fetch(TrafficHistoryQuery(
            level: .minute,
            start: previousMinute.addingTimeInterval(-60),
            end: cutoff
        )).map(\.delta.total), [10])
        XCTAssertEqual(repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: previousMinute.addingTimeInterval(-60),
            end: cutoff
        )).map(\.delta.total), [20])
    }

    func testMonthlyAndYearlySummariesNeverExpire() throws {
        let calendar = self.calendar(timeZone: "UTC")
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let old = self.date(2001, 1, 1, calendar: calendar)
        XCTAssertSuccess(repository.ingest([
            self.sample(at: old, network: network, applicationID: "month", download: 10, upload: 1)
        ], level: .month))
        XCTAssertSuccess(repository.ingest([
            self.sample(at: old, network: network, applicationID: "year", download: 20, upload: 2)
        ], level: .year))

        try TrafficAggregation.compact(
            repository: repository,
            now: self.date(2026, 7, 18, calendar: calendar),
            policy: .standard,
            calendar: calendar
        )

        XCTAssertEqual(repository.fetch(TrafficHistoryQuery(level: .month, start: old, end: Date.distantFuture)).count, 1)
        XCTAssertFalse(repository.fetch(TrafficHistoryQuery(level: .year, start: old, end: Date.distantFuture)).isEmpty)
    }

    func testQueryPlannerSplitsARequestAcrossAvailableTiersWithoutOverlap() {
        let calendar = self.calendar(timeZone: "UTC")
        let now = self.date(2026, 7, 18, 12, 34, 56, calendar: calendar)
        let start = self.date(2023, 1, 1, calendar: calendar)
        let end = now.addingTimeInterval(1)
        let plan = TrafficQueryPlanner(calendar: calendar).plan(
            interval: DateInterval(start: start, end: end),
            now: now,
            policy: .standard
        )

        XCTAssertEqual(plan.segments.map(\.level), [.year, .month, .day, .hour, .minute, .second])
        XCTAssertEqual(plan.segments.first?.interval.start, start)
        XCTAssertEqual(plan.segments.last?.interval.end, end)
        for pair in zip(plan.segments, plan.segments.dropFirst()) {
            XCTAssertEqual(pair.0.interval.end, pair.1.interval.start)
            XCTAssertLessThanOrEqual(pair.0.interval.end, pair.1.interval.start)
        }
    }

    func testCustomRangeAcrossTierBoundariesHasNoMissingOrDuplicateBytes() {
        let calendar = self.calendar(timeZone: "UTC")
        let now = self.date(2026, 7, 18, 12, 34, 56, calendar: calendar)
        let start = self.date(2023, 1, 1, calendar: calendar)
        let end = now
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let policy = TrafficRetentionPolicy.standard
        let plan = TrafficQueryPlanner(calendar: calendar).plan(
            interval: DateInterval(start: start, end: end.addingTimeInterval(1)),
            now: now,
            policy: policy
        )
        for (index, segment) in plan.segments.enumerated() {
            let timestamp = segment.interval.start
            XCTAssertSuccess(repository.ingest([
                self.sample(
                    at: timestamp,
                    network: network,
                    applicationID: "tier-\(index)",
                    download: UInt64(index + 1) * 10,
                    upload: UInt64(index + 1)
                )
            ], level: segment.level))
        }

        let snapshot = TrafficAnalyticsEngine(
            repository: repository,
            calendar: calendar,
            retentionPolicy: policy
        ).snapshot(for: TrafficAnalyticsQuery(
            range: .tenMinutes,
            selectedInterval: DateInterval(start: start, end: end),
            now: now
        ))

        XCTAssertEqual(snapshot.total, 231)
        XCTAssertEqual(snapshot.ranking.count, plan.segments.count)
    }

    func testCompactionRespectsCalendarDayMonthYearAcrossDST() throws {
        let calendar = self.calendar(timeZone: "America/Los_Angeles")
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let springDay = self.date(2024, 3, 10, calendar: calendar)
        XCTAssertSuccess(repository.ingest([
            self.sample(at: self.date(2024, 3, 10, 1, 30, calendar: calendar), network: network, applicationID: "dst", download: 10, upload: 1),
            self.sample(at: self.date(2024, 3, 10, 3, 30, calendar: calendar), network: network, applicationID: "dst", download: 20, upload: 2)
        ], level: .hour))

        try TrafficAggregation.compact(
            repository: repository,
            now: self.date(2024, 3, 12, 12, 0, calendar: calendar),
            policy: TrafficRetentionPolicy(
                minuteRetentionDays: 1,
                hourRetentionDays: 1,
                dayRetentionDays: 730,
                compactionBatchSize: 2_000
            ),
            calendar: calendar
        )

        let days = repository.fetchRecords(TrafficHistoryQuery(
            level: .day,
            start: springDay,
            end: self.date(2024, 3, 11, calendar: calendar)
        ))
        XCTAssertEqual(days.map(\.sample.timestamp), [springDay])
        XCTAssertEqual(days.map(\.sample.delta.total), [33])

        try TrafficAggregation.compact(
            repository: repository,
            now: self.date(2027, 5, 1, calendar: calendar),
            policy: TrafficRetentionPolicy(
                minuteRetentionDays: 1,
                hourRetentionDays: 1,
                dayRetentionDays: 1,
                compactionBatchSize: 2_000
            ),
            calendar: calendar
        )
        XCTAssertEqual(repository.fetchRecords(TrafficHistoryQuery(
            level: .month,
            start: self.date(2024, 3, 1, calendar: calendar),
            end: self.date(2024, 4, 1, calendar: calendar)
        )).map(\.sample.delta.total), [33])
        XCTAssertEqual(repository.fetchRecords(TrafficHistoryQuery(
            level: .year,
            start: self.date(2024, 1, 1, calendar: calendar),
            end: self.date(2025, 1, 1, calendar: calendar)
        )).map(\.sample.delta.total), [33])
    }

    func testCompactionBatchLimitInsideOneDestinationBucketFinishesTheWholeBucket() throws {
        let calendar = self.calendar(timeZone: "UTC")
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = self.date(2026, 7, 18, 12, 0, calendar: calendar)
        let firstMinute = self.date(2026, 7, 17, 10, 0, calendar: calendar)
        XCTAssertSuccess(repository.ingest([
            self.sample(at: firstMinute.addingTimeInterval(1), network: network, applicationID: "a", download: 1, upload: 0),
            self.sample(at: firstMinute.addingTimeInterval(2), network: network, applicationID: "b", download: 2, upload: 0),
            self.sample(at: firstMinute.addingTimeInterval(3), network: network, applicationID: "c", download: 3, upload: 0),
            self.sample(at: firstMinute.addingTimeInterval(61), network: network, applicationID: "later", download: 4, upload: 0)
        ]))

        try TrafficAggregation.compact(
            repository: repository,
            now: now,
            policy: TrafficRetentionPolicy(
                minuteRetentionDays: 7,
                hourRetentionDays: 60,
                dayRetentionDays: 730,
                compactionBatchSize: 2
            ),
            calendar: calendar
        )

        XCTAssertEqual(repository.fetch(TrafficHistoryQuery(
            level: .minute,
            start: firstMinute,
            end: firstMinute.addingTimeInterval(59)
        )).reduce(UInt64(0)) { $0 + $1.delta.total }, 6)
        XCTAssertEqual(repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: firstMinute.addingTimeInterval(60),
            end: firstMinute.addingTimeInterval(120)
        )).map(\.delta.total), [4])
    }

    func testInterruptedCompleteBucketCompactionRestartsWithoutLossOrDuplication() throws {
        let calendar = self.calendar(timeZone: "UTC")
        let store = RecordingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = self.date(2026, 7, 18, 12, 0, calendar: calendar)
        let source = self.date(2026, 7, 17, 10, 0, calendar: calendar)
        XCTAssertSuccess(repository.ingest([
            self.sample(at: source.addingTimeInterval(1), network: network, applicationID: "app", download: 10, upload: 1),
            self.sample(at: source.addingTimeInterval(2), network: network, applicationID: "app", download: 20, upload: 2)
        ]))
        store.failNextWrite = true

        XCTAssertThrowsError(try TrafficAggregation.compact(repository: repository, now: now, policy: .standard, calendar: calendar))
        XCTAssertEqual(repository.fetch(TrafficHistoryQuery(level: .second, start: source, end: source.addingTimeInterval(59))).count, 2)
        XCTAssertTrue(repository.fetch(TrafficHistoryQuery(level: .minute, start: source, end: source.addingTimeInterval(59))).isEmpty)

        let restarted = TrafficHistoryRepository(store: store)
        try TrafficAggregation.compact(repository: restarted, now: now, policy: .standard, calendar: calendar)
        try TrafficAggregation.compact(repository: restarted, now: now, policy: .standard, calendar: calendar)
        XCTAssertTrue(restarted.fetch(TrafficHistoryQuery(level: .second, start: source, end: source.addingTimeInterval(59))).isEmpty)
        XCTAssertEqual(restarted.fetch(TrafficHistoryQuery(level: .minute, start: source, end: source.addingTimeInterval(59))).map(\.delta.total), [33])
    }

    func testRawToMinuteCompactionPreservesProcessSummariesForExportHelper() throws {
        let calendar = self.calendar(timeZone: "UTC")
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        let now = self.date(2026, 7, 18, 12, 0, calendar: calendar)
        let source = self.date(2026, 7, 17, 10, 0, calendar: calendar)
        let helperA = self.sample(at: source.addingTimeInterval(1), network: network, applicationID: "owner", processID: 41, processName: "A", processStartToken: 1, download: 10, upload: 1)
        let helperB = self.sample(at: source.addingTimeInterval(2), network: network, applicationID: "owner", processID: 42, processName: "B", processStartToken: 2, download: 20, upload: 2)
        XCTAssertSuccess(repository.ingest([helperA, helperB]))

        try TrafficAggregation.compact(repository: repository, now: now, policy: .standard, calendar: calendar)

        let records = repository.fetchRecords(TrafficHistoryQuery(level: .minute, start: source, end: source.addingTimeInterval(59)))
        XCTAssertEqual(records.first?.processSummaries?.map(\.processDiscriminator), [helperA.processDiscriminator, helperB.processDiscriminator])
        let ranking = TrafficAnalyticsEngine(repository: repository, calendar: calendar).rank(records: records)
        XCTAssertEqual(ranking.first?.processes.map { $0.download + $0.upload }, [11, 22])
        XCTAssertEqual(ranking.first?.total, 33)
    }

    func testCoordinatorSchedulesBoundedMaintenanceFromCurrentPreferencesAndCancelsOnStop() {
        let suiteName = "net.analytics.maintenance.preferences.tests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let preferencesStore = TrafficAnalyticsPreferencesStore(defaults: defaults)
        var preferences = preferencesStore.preferences()
        preferences.minuteRetentionDays = 1
        preferences.hourRetentionDays = 1
        preferences.dayRetentionDays = 1
        preferencesStore.save(preferences)
        let scheduler = ManualTrafficMaintenanceScheduler()
        let clock = MutableTrafficClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let repository = TrafficHistoryRepository(store: InMemoryTrafficStore())
        let network = NetworkIdentity(id: "wifi", displayName: "Wi-Fi", interfaceName: "en0", kind: .wifi)
        XCTAssertSuccess(repository.ingest([
            self.sample(at: clock.now().addingTimeInterval(-25 * 60 * 60), network: network, applicationID: "app", download: 10, upload: 1)
        ]))
        let coordinator = TrafficAnalyticsCoordinator(
            repository: repository,
            clock: clock,
            preferencesStore: preferencesStore,
            maintenanceScheduler: scheduler,
            maintenanceInterval: 6 * 60 * 60
        )

        coordinator.start()
        XCTAssertEqual(scheduler.delays, [0])
        scheduler.runNext()
        XCTAssertTrue(self.waitUntil { scheduler.delays == [0, 6 * 60 * 60] })
        XCTAssertTrue(repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: Date(timeIntervalSince1970: 0),
            end: clock.now()
        )).isEmpty)

        _ = coordinator.stop()
        XCTAssertFalse(scheduler.hasPendingWork)
    }

    func testCoordinatorMaintenanceNeverOverlapsIngestionOrClear() throws {
        let scheduler = ManualTrafficMaintenanceScheduler()
        let store = BlockingTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let clock = MutableTrafficClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let coordinator = TrafficAnalyticsCoordinator(
            repository: repository,
            clock: clock,
            maintenanceScheduler: scheduler
        )
        coordinator.start()

        let ingestFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            coordinator.ingest(counters: [ProcessTrafficCounter(
                identity: self.identity,
                processID: 42,
                processStartToken: 1,
                isDelta: true,
                download: 10,
                upload: 1
            )])
            ingestFinished.signal()
        }
        XCTAssertTrue(store.waitUntilWriteStarts())

        scheduler.runNext()
        let clearFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? coordinator.clearAnalyticsData()
            clearFinished.signal()
        }
        XCTAssertEqual(clearFinished.wait(timeout: .now() + 0.05), .timedOut)

        store.finishBlockedWrite()
        XCTAssertEqual(ingestFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(clearFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(repository.fetch(TrafficHistoryQuery(
            level: .second,
            start: Date.distantPast,
            end: Date.distantFuture
        )).isEmpty)
        _ = coordinator.stop()
    }


    func testNetworkRegistryUsesStableWiFiEthernetHotspotAndTunnelIDs() {
        let defaults = UserDefaults(suiteName: "net-analytics-registry-")!
        defaults.removePersistentDomain(forName: "net-analytics-registry-")
        let registry = NetworkRegistry(defaults: defaults)
        let inputs = [
            NetworkIdentity(id: "volatile-wifi", displayName: "Home Wi-Fi", interfaceName: "en0", kind: .wifi, ssid: " Home ", bssid: "AA:BB"),
            NetworkIdentity(id: "volatile-ethernet", displayName: "Ethernet", interfaceName: "en1", kind: .ethernet, hardwareAddress: "AA:BB:CC:DD:EE:FF"),
            NetworkIdentity(id: "volatile-hotspot", displayName: "iPhone", interfaceName: "bridge0", kind: .hotspot, serviceIdentifier: "iPhone"),
            NetworkIdentity(id: "volatile-tunnel", displayName: "VPN", interfaceName: "utun4", kind: .tunnel, serviceIdentifier: "work-vpn")
        ]

        let registered = inputs.map { registry.observe($0, at: Date(timeIntervalSince1970: 100)) }
        XCTAssertEqual(registered.map(\.identity.id), [
            "wifi:home",
            "ethernet:aa:bb:cc:dd:ee:ff",
            "hotspot:iphone|bridge0",
            "tunnel:work-vpn"
        ])
    }

    func testWiFiRoamingAcrossBSSIDsKeepsOneCanonicalSSIDIdentity() {
        let suite = "net-analytics-roaming-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let registry = NetworkRegistry(defaults: defaults)
        let first = registry.observe(
            NetworkIdentity(id: "first", displayName: "Home", interfaceName: "en0", kind: .wifi, ssid: "Home", bssid: "AA:AA"),
            at: Date(timeIntervalSince1970: 100)
        )
        let second = registry.observe(
            NetworkIdentity(id: "second", displayName: "Home", interfaceName: "en1", kind: .wifi, ssid: " home ", bssid: "BB:BB"),
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(first.identity.id, second.identity.id)
        XCTAssertEqual(registry.all().count, 1)
        XCTAssertEqual(Set(registry.all()[0].observedBSSIDs), ["AA:AA", "BB:BB"])
    }

    func testNetworkAliasSurvivesRediscoveryAndDoesNotChangeStoredSampleID() {
        let suite = "net-analytics-alias-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let registry = NetworkRegistry(defaults: defaults)
        let first = registry.observe(
            NetworkIdentity(id: "volatile", displayName: "Home", interfaceName: "en0", kind: .wifi, ssid: "Home", bssid: "AA"),
            at: Date(timeIntervalSince1970: 100)
        )
        registry.setAlias("Apartment", for: first.identity.id)
        let restarted = NetworkRegistry(defaults: defaults)
        let rediscovered = restarted.observe(
            NetworkIdentity(id: "other-volatile-id", displayName: "Home", interfaceName: "en9", kind: .wifi, ssid: "HOME", bssid: "BB"),
            at: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(rediscovered.identity.id, first.identity.id)
        XCTAssertEqual(restarted.displayName(for: first.identity.id), "Apartment")
        XCTAssertEqual(rediscovered.identity.id, "wifi:home")
    }

    func testNetworkPlansAreIndependentPerRegisteredNetwork() {
        let suite = "net-analytics-plans-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = TrafficRuleStore(defaults: defaults)
        let wifi = NetworkPlan(billingCycleDay: 5, byteLimit: 10, thresholds: [50])
        let ethernet = NetworkPlan(billingCycleDay: 20, byteLimit: 20, thresholds: [80])

        store.save(networkPlan: wifi, for: "wifi:home")
        store.save(networkPlan: ethernet, for: "ethernet:aa")

        XCTAssertEqual(store.networkPlan(for: "wifi:home"), wifi)
        XCTAssertEqual(store.networkPlan(for: "ethernet:aa"), ethernet)
        XCTAssertEqual(store.allNetworkPlans().count, 2)
    }

    func testConcreteNetworkFilterSelectsOnlyThatNetwork() {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = InMemoryTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let app = self.identity
        let home = NetworkIdentity(id: "wifi:home", displayName: "Home", interfaceName: "en0", kind: .wifi)
        let work = NetworkIdentity(id: "wifi:work", displayName: "Work", interfaceName: "en0", kind: .wifi)
        XCTAssertSuccess(repository.ingest([
            TrafficSample(timestamp: now, application: app, network: home, processID: 1, delta: TrafficDelta(download: 10, upload: 1), peakBytesPerSecond: 11),
            TrafficSample(timestamp: now, application: app, network: work, processID: 1, delta: TrafficDelta(download: 20, upload: 2), peakBytesPerSecond: 22)
        ]))

        let snapshot = TrafficAnalyticsEngine(repository: repository).snapshot(
            for: TrafficAnalyticsQuery(range: .today, networkID: "wifi:work", now: now)
        )
        XCTAssertEqual(snapshot.total, 22)
        XCTAssertEqual(snapshot.ranking.first?.download, 20)
    }

    func testAllNetworksDeduplicatesTunnelAndPhysicalButConcreteFiltersDoNot() {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = InMemoryTrafficStore()
        let repository = TrafficHistoryRepository(store: store)
        let app = self.identity
        let physical = NetworkIdentity(id: "wifi:home", displayName: "Home", interfaceName: "en0", kind: .wifi)
        let tunnel = NetworkIdentity(id: "tunnel:work", displayName: "VPN", interfaceName: "utun4", kind: .tunnel)
        XCTAssertSuccess(repository.ingest([
            TrafficSample(timestamp: now, application: app, network: physical, processID: 1, delta: TrafficDelta(download: 10, upload: 1), peakBytesPerSecond: 11),
            TrafficSample(timestamp: now, application: app, network: tunnel, processID: 1, delta: TrafficDelta(download: 10, upload: 1), peakBytesPerSecond: 11)
        ]))
        let engine = TrafficAnalyticsEngine(repository: repository)

        let all = engine.snapshot(for: TrafficAnalyticsQuery(range: .today, now: now))
        let concrete = engine.snapshot(for: TrafficAnalyticsQuery(range: .today, networkID: "tunnel:work", now: now))
        XCTAssertEqual(all.total, 11)
        XCTAssertEqual(concrete.total, 11)
        XCTAssertEqual(concrete.download, 10)
    }

    func testOverviewUsesTheSelectedNetworksBillingPlan() {
        let suite = "net-analytics-overview-plan-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = TrafficRuleStore(defaults: defaults)
        store.save(networkPlan: NetworkPlan(billingCycleDay: 3, byteLimit: 100, thresholds: [50]), for: "wifi:home")
        store.save(networkPlan: NetworkPlan(billingCycleDay: 17, byteLimit: 200, thresholds: [75]), for: "wifi:work")

        XCTAssertEqual(store.networkPlan(for: "wifi:home").billingCycleDay, 3)
        XCTAssertEqual(store.networkPlan(for: "wifi:work").byteLimit, 200)
    }

    private func waitUntil(timeout: TimeInterval = 1, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        return condition()
    }

    private func calendar(timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        _ second: Int = 0,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }

    private func sample(
        at timestamp: Date,
        network: NetworkIdentity,
        applicationID: String,
        processID: Int32 = 1,
        processName: String? = nil,
        processStartToken: UInt64 = 1,
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
            processID: processID,
            processName: processName,
            processStartToken: processStartToken,
            processDiscriminator: "\(applicationID)|\(processID)|\(processStartToken)",
            delta: TrafficDelta(download: download, upload: upload),
            peakBytesPerSecond: download + upload
        )
    }

    private func sample(from counter: ProcessTrafficCounter) -> TrafficSample {
        TrafficSample(
            timestamp: Date(),
            application: counter.identity,
            network: NetworkIdentity(
                id: "iface:\(counter.interfaceName ?? "unknown")",
                displayName: counter.interfaceName ?? "Unknown",
                interfaceName: counter.interfaceName ?? "unknown",
                kind: TrafficAnalyticsCoordinator.networkKind(
                    interfaceName: counter.interfaceName ?? "unknown",
                    displayName: counter.interfaceName ?? "Unknown",
                    wifiSSID: nil
                )
            ),
            processID: counter.processID,
            processStartToken: counter.processStartToken,
            processDiscriminator: counter.processDiscriminator,
            delta: TrafficDelta(download: counter.download, upload: counter.upload),
            peakBytesPerSecond: counter.download + counter.upload
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(data: try encoder.encode(value), encoding: .utf8)!
    }

    private var connectionFixture: String {
        """
        ,interface,bytes_in,bytes_out,
        Client Helper.55,,1000,200,
        tcp4 10.0.0.2:1<->1.1.1.1:443,en0,100,20,
        tcp4 10.0.0.2:1<->1.1.1.1:443,en0,100,20,
        tcp4 10.0.0.2:2<->10.0.0.1:443,utun4,50,10,
        udp4 10.0.0.2:3<->8.8.8.8:53,en0,25,5,
        udp4 *:4<->*:*, ,5,1,
        """
    }

    private func pidReuseFixture(download: UInt64, upload: UInt64) -> String {
        """
        ,interface,bytes_in,bytes_out,
        Helper.77,,\(download),\(upload),
        tcp4 a<->b,en0,\(download),\(upload),
        """
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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + self.descendants(of: $0) }
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

private final class MutableProcessMetadataProvider: ProcessMetadataProviding {
    var entry: ProcessMetadata

    init(entry: ProcessMetadata) {
        self.entry = entry
    }

    func metadata(for processID: Int32, fallbackName: String) -> ProcessMetadata {
        self.entry.processID == processID
            ? self.entry
            : ProcessMetadata(processID: processID, processName: fallbackName)
    }
}

private final class MutableTrafficClock: TrafficClock {
    private(set) var current: Date

    init(now: Date) {
        self.current = now
    }

    func now() -> Date {
        self.current
    }

    func advance(by interval: TimeInterval) {
        self.current = self.current.addingTimeInterval(interval)
    }
}

private final class ManualTrafficMaintenanceScheduler: TrafficMaintenanceScheduling {
    private final class Token: TrafficMaintenanceCancellation {
        var isCancelled = false
        func cancel() { self.isCancelled = true }
    }

    private var work: [(delay: TimeInterval, token: Token, block: () -> Void)] = []
    private(set) var delays: [TimeInterval] = []
    var hasPendingWork: Bool { self.work.contains { !$0.token.isCancelled } }

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> TrafficMaintenanceCancellation {
        let token = Token()
        self.delays.append(delay)
        self.work.append((delay, token, block))
        return token
    }

    func runNext() {
        while !self.work.isEmpty {
            let next = self.work.removeFirst()
            if next.token.isCancelled { continue }
            next.block()
            return
        }
        XCTFail("Expected scheduled maintenance")
    }
}

private final class ManualProcessReadScheduler: ProcessReadScheduling {
    private let clock: MutableTrafficClock
    private var work: [(delay: TimeInterval, block: () -> Void)] = []
    private(set) var delays: [TimeInterval] = []
    var hasPendingWork: Bool { !self.work.isEmpty }

    init(clock: MutableTrafficClock) {
        self.clock = clock
    }

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        self.delays.append(delay)
        self.work.append((delay, block))
    }

    func runNext() {
        guard !self.work.isEmpty else {
            XCTFail("Expected scheduled process read")
            return
        }
        let next = self.work.removeFirst()
        self.clock.advance(by: next.delay)
        next.block()
    }
}

private enum RecordingTrafficStoreError: Error {
    case injected
}

private final class RecordingTrafficStore: TrafficKeyValueStoring {
    struct AtomicWrite {
        let puts: [(key: String, value: String)]
        let deletes: [String]
    }

    private var storage: [String: String] = [:]
    private let lock = NSLock()
    private let queueKey: DispatchSpecificKey<String>?
    private let expectedQueueValue: String?
    private(set) var atomicWrites: [AtomicWrite] = []
    private(set) var attemptedWrites: [AtomicWrite] = []
    private(set) var accessesAllOnExpectedQueue = true
    var failNextWrite = false
    var failAllWrites = false

    init(queueKey: DispatchSpecificKey<String>? = nil, expectedQueueValue: String? = nil) {
        self.queueKey = queueKey
        self.expectedQueueValue = expectedQueueValue
    }

    func writeAtomically(puts: [(key: String, value: String)], deletes: [String]) throws {
        self.recordQueue()
        self.lock.lock()
        defer { self.lock.unlock() }
        let write = AtomicWrite(puts: puts, deletes: deletes)
        self.attemptedWrites.append(write)
        if self.failAllWrites {
            throw RecordingTrafficStoreError.injected
        }
        if self.failNextWrite {
            self.failNextWrite = false
            throw RecordingTrafficStoreError.injected
        }
        var next = self.storage
        puts.forEach { next[$0.key] = $0.value }
        deletes.forEach { next.removeValue(forKey: $0) }
        self.storage = next
        self.atomicWrites.append(write)
    }

    func get(key: String) -> String? {
        self.recordQueue()
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage[key]
    }

    func values(prefix: String) -> [String] {
        self.recordQueue()
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }.map(\.value)
    }

    func keys(prefix: String) -> [String] {
        self.recordQueue()
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func recordQueue() {
        guard let queueKey, let expectedQueueValue else { return }
        if DispatchQueue.getSpecific(key: queueKey) != expectedQueueValue {
            self.accessesAllOnExpectedQueue = false
        }
    }
}

private final class BlockingTrafficStore: TrafficKeyValueStoring {
    private let store = InMemoryTrafficStore()
    private let writeStarted = DispatchSemaphore(value: 0)
    private let allowWrite = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldBlock = true

    func writeAtomically(puts: [(key: String, value: String)], deletes: [String]) throws {
        self.lock.lock()
        let block = self.shouldBlock
        if block { self.shouldBlock = false }
        self.lock.unlock()
        if block {
            self.writeStarted.signal()
            self.allowWrite.wait()
        }
        try self.store.writeAtomically(puts: puts, deletes: deletes)
    }

    func get(key: String) -> String? {
        self.store.get(key: key)
    }

    func values(prefix: String) -> [String] {
        self.store.values(prefix: prefix)
    }

    func keys(prefix: String) -> [String] {
        self.store.keys(prefix: prefix)
    }

    func waitUntilWriteStarts() -> Bool {
        self.writeStarted.wait(timeout: .now() + 1) == .success
    }

    func finishBlockedWrite() {
        self.allowWrite.signal()
    }
}

private final class BlockingNettopRunner: NettopRunning {
    private let lock = NSLock()
    private let runStarted = DispatchSemaphore(value: 0)
    private let allowBlockedRunToFinish = DispatchSemaphore(value: 0)
    private let blockedRunFinished = DispatchSemaphore(value: 0)
    private let blockedResult: Result<String, NettopCollectionError>
    private var remainingResults: [Result<String, NettopCollectionError>]
    private let finishBlockedRunOnCancel: Bool
    private var _cancelCount = 0
    private var _runCount = 0

    var cancelCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._cancelCount
    }

    var runCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._runCount
    }

    init(
        blockedResult: Result<String, NettopCollectionError>,
        remainingResults: [Result<String, NettopCollectionError>],
        finishBlockedRunOnCancel: Bool = true
    ) {
        self.blockedResult = blockedResult
        self.remainingResults = remainingResults
        self.finishBlockedRunOnCancel = finishBlockedRunOnCancel
    }

    func run(
        command: NettopCommand,
        timeout: TimeInterval,
        cancellation: NettopCancellation
    ) throws -> String {
        self.lock.lock()
        self._runCount += 1
        let runNumber = self._runCount
        let result: Result<String, NettopCollectionError>
        if runNumber == 1 {
            result = self.blockedResult
        } else {
            result = self.remainingResults.removeFirst()
        }
        self.lock.unlock()

        if runNumber == 1 {
            self.runStarted.signal()
            self.allowBlockedRunToFinish.wait()
            self.blockedRunFinished.signal()
        }
        return try result.get()
    }

    func cancel() {
        self.lock.lock()
        self._cancelCount += 1
        let shouldFinish = self.finishBlockedRunOnCancel
        self.lock.unlock()
        if shouldFinish {
            self.allowBlockedRunToFinish.signal()
        }
    }

    func waitUntilBlockedRunStarts() -> Bool {
        self.runStarted.wait(timeout: .now() + 1) == .success
    }

    func waitUntilBlockedRunFinishes() -> Bool {
        self.blockedRunFinished.wait(timeout: .now() + 1) == .success
    }

    func finishBlockedRun() {
        self.allowBlockedRunToFinish.signal()
    }
}

private final class RecordingNettopRunner: NettopRunning {
    private var results: [Result<String, NettopCollectionError>]
    private(set) var commands: [NettopCommand] = []
    private(set) var timeouts: [TimeInterval] = []

    init(results: [Result<String, NettopCollectionError>]) {
        self.results = results
    }

    func run(
        command: NettopCommand,
        timeout: TimeInterval,
        cancellation: NettopCancellation
    ) throws -> String {
        self.commands.append(command)
        self.timeouts.append(timeout)
        return try self.results.removeFirst().get()
    }

    func cancel() {}
}

private final class RecordingNettopExecution: NettopProcessExecuting {
    enum Event: Equatable {
        case start
        case waitForExit(TimeInterval)
        case terminate
        case interrupt
        case kill
        case closeReaders
        case waitForReaders(TimeInterval)
    }

    private var waits: [Bool]
    private var readerWaits: [Bool]
    private(set) var events: [Event] = []
    private(set) var usedUnboundedWait = false
    var outputData = Data()
    var errorData = Data()

    init(waits: [Bool], readerWaits: [Bool]) {
        self.waits = waits
        self.readerWaits = readerWaits
    }

    func start(command: NettopCommand) throws {
        self.events.append(.start)
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        self.events.append(.waitForExit(timeout))
        return self.waits.removeFirst()
    }

    func terminate() {
        self.events.append(.terminate)
    }

    func interrupt() {
        self.events.append(.interrupt)
    }

    func kill() {
        self.events.append(.kill)
    }

    func closeReaders() {
        self.events.append(.closeReaders)
    }

    func waitForReaders(timeout: TimeInterval) -> Bool {
        self.events.append(.waitForReaders(timeout))
        return self.readerWaits.removeFirst()
    }
}

private final class IsolatedTransactionTrafficStore: TrafficKeyValueStoring {
    struct Attempt {
        let puts: [(key: String, value: String)]
        let deletes: [String]
    }

    private var committed: [String: String] = [:]
    private let lock = NSLock()
    private(set) var lastAttempt: Attempt?
    var failAfterApplyingToIsolatedTransaction = false

    func writeAtomically(puts: [(key: String, value: String)], deletes: [String]) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.lastAttempt = Attempt(puts: puts, deletes: deletes)
        var transaction = self.committed
        puts.forEach { transaction[$0.key] = $0.value }
        deletes.forEach { transaction.removeValue(forKey: $0) }
        if self.failAfterApplyingToIsolatedTransaction {
            self.failAfterApplyingToIsolatedTransaction = false
            throw RecordingTrafficStoreError.injected
        }
        self.committed = transaction
    }

    func get(key: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.committed[key]
    }

    func values(prefix: String) -> [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.committed.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }.map(\.value)
    }

    func keys(prefix: String) -> [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.committed.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}

private func XCTAssertSuccess<T, E>(_ result: Result<T, E>, file: StaticString = #filePath, line: UInt = #line) {
    if case .failure(let error) = result {
        XCTFail("Expected success, got \(error)", file: file, line: line)
    }
}

private func XCTAssertFailure<T, E>(_ result: Result<T, E>, file: StaticString = #filePath, line: UInt = #line) {
    if case .success = result {
        XCTFail("Expected failure", file: file, line: line)
    }
}
