//
//  views.swift
//  Net
//

import Cocoa
import Foundation
import Kit

public enum NetworkPreviewPage: String, CaseIterable {
    case realtime
    case analysis
    case overview

    public static let storageKey = "Network_previewPage"

    public init(storedRawValue: String?) {
        if let storedRawValue, let page = NetworkPreviewPage(rawValue: storedRawValue) {
            self = page
        } else {
            self = .realtime
        }
    }

    public var title: String {
        switch self {
        case .realtime:
            return localizedString("Real-time")
        case .analysis:
            return localizedString("Traffic analysis")
        case .overview:
            return localizedString("Usage overview")
        }
    }
}
