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
