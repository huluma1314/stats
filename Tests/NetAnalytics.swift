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
