//
//  icon_resolver.swift
//  Net
//

import Cocoa
import Foundation
import Kit

public protocol ApplicationIconLookupProviding: AnyObject {
    func bundleIcon(for identity: ApplicationIdentity) -> NSImage?
    func executableIcon(for identity: ApplicationIdentity) -> NSImage?
    func runningApplicationIcon(for identity: ApplicationIdentity) -> NSImage?
    func defaultIcon() -> NSImage
}

public protocol ApplicationIconResolving: AnyObject {
    func icon(for identity: ApplicationIdentity) -> NSImage
}

public final class WorkspaceApplicationIconProvider: ApplicationIconLookupProviding {
    public init() {}
    public func bundleIcon(for identity: ApplicationIdentity) -> NSImage? {
        guard let bundleIdentifier = identity.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    public func executableIcon(for identity: ApplicationIdentity) -> NSImage? {
        guard let path = identity.executablePath else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
    public func runningApplicationIcon(for identity: ApplicationIdentity) -> NSImage? {
        guard let bundleIdentifier = identity.bundleIdentifier else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier
        }?.icon
    }
    public func defaultIcon() -> NSImage { Constants.defaultProcessIcon }
}

public final class ApplicationIconResolver: ApplicationIconResolving {
    private let provider: ApplicationIconLookupProviding
    private let queue = DispatchQueue(label: "eu.exelban.Stats.Net.analytics.icons", qos: .utility)
    private var cache: [String: NSImage] = [:]

    public init(provider: ApplicationIconLookupProviding = WorkspaceApplicationIconProvider()) {
        self.provider = provider
    }

    public func icon(for identity: ApplicationIdentity) -> NSImage {
        let key = "\(identity.id)|\(identity.bundleIdentifier ?? "")|\(identity.executablePath ?? "")"
        if let cached = self.queue.sync(execute: { self.cache[key] }) { return cached }
        // Presentation controllers call this on the main thread after query results exist.
        // The cache queue protects metadata only; AppKit lookup never enters aggregation paths.
        let lookup = {
            self.provider.bundleIcon(for: identity)
                ?? self.provider.executableIcon(for: identity)
                ?? self.provider.runningApplicationIcon(for: identity)
                ?? self.provider.defaultIcon()
        }
        let icon = Thread.isMainThread ? lookup() : DispatchQueue.main.sync(execute: lookup)
        self.queue.sync { self.cache[key] = icon }
        return icon
    }
}
