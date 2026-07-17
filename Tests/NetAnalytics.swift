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
