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
              previous.processStartToken == current.processStartToken else {
            return .zero
        }

        return TrafficDelta(
            download: current.download >= previous.download ? current.download - previous.download : 0,
            upload: current.upload >= previous.upload ? current.upload - previous.upload : 0
        )
    }
}
