//
//  nettop.swift
//  Net
//

import Foundation

public struct NettopRow: Equatable {
    public let processName: String
    public let processID: Int32
    public let download: UInt64
    public let upload: UInt64

    public init(processName: String, processID: Int32, download: UInt64, upload: UInt64) {
        self.processName = processName
        self.processID = processID
        self.download = download
        self.upload = upload
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
        var isHeader = true

        csv.enumerateLines { line, _ in
            if isHeader {
                isHeader = false
                return
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return
            }

            let columns = trimmed.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3 else {
                malformed += 1
                return
            }

            let identity = String(columns[0])
            guard let separator = identity.lastIndex(of: ".") else {
                malformed += 1
                return
            }

            let namePart = String(identity[..<separator])
            let pidPart = String(identity[identity.index(after: separator)...])
            guard let pid = Int32(pidPart), pid >= 0 else {
                malformed += 1
                return
            }

            guard let download = UInt64(columns[1]), let upload = UInt64(columns[2]) else {
                malformed += 1
                return
            }

            rows.append(
                NettopRow(
                    processName: namePart.isEmpty ? "\(pid)" : namePart,
                    processID: pid,
                    download: download,
                    upload: upload
                )
            )
        }

        return NettopParseResult(rows: rows, malformedRowCount: malformed)
    }
}
