//
//  deltas.swift
//  Net
//

import Foundation

public enum TrafficDeltaCalculator {
    public static func delta(
        from previous: ProcessTrafficCounter?,
        to current: ProcessTrafficCounter
    ) -> TrafficDelta {
        guard let previous,
              previous.processID == current.processID,
              previous.processStartToken == current.processStartToken,
              current.download >= previous.download,
              current.upload >= previous.upload else {
            return .zero
        }

        return TrafficDelta(
            download: current.download - previous.download,
            upload: current.upload - previous.upload
        )
    }
}
