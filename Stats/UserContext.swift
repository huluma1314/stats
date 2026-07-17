//
//  UserContext.swift
//  Stats
//

import AppKit
import CoreGraphics

enum UserContext {
    static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }

        if let locked = session["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    static func secondsSinceLastInput() -> TimeInterval {
        guard let anyInputEvent = CGEventType(rawValue: UInt32.max) else {
            return 0
        }

        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEvent
        )
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    static func busyReason() -> String? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return nil
        }

        if displays.prefix(Int(count)).contains(where: { CGDisplayIsInMirrorSet($0) != 0 }) {
            return "display mirroring is active"
        }
        return nil
    }
}
