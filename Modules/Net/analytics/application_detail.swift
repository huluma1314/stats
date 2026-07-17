//
//  application_detail.swift
//  Net
//

import Cocoa
import Kit

internal final class ApplicationDetailView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let identityLabel = NSTextField(labelWithString: "")
    private let totalsLabel = NSTextField(labelWithString: "")
    private let processesLabel = NSTextField(labelWithString: "")
    private let enforcementLabel = NSTextField(wrappingLabelWithString: "")
    private let closeButton = NSButton(title: localizedString("Back"), target: nil, action: nil)

    var onClose: (() -> Void)?
    private let enforcer: NetworkRuleEnforcing

    init(enforcer: NetworkRuleEnforcing = UnavailableNetworkRuleEnforcer()) {
        self.enforcer = enforcer
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ summary: ApplicationTrafficSummary) {
        self.isHidden = false
        self.titleLabel.stringValue = summary.identity.displayName
        self.identityLabel.stringValue = [
            summary.identity.bundleIdentifier,
            summary.identity.executablePath
        ].compactMap { $0 }.joined(separator: "\n")
        self.totalsLabel.stringValue = [
            "\(localizedString("Download")): \(Units(bytes: Int64(summary.download)).getReadableMemory())",
            "\(localizedString("Upload")): \(Units(bytes: Int64(summary.upload)).getReadableMemory())",
            "\(localizedString("Peak")): \(Units(bytes: Int64(summary.peakBytesPerSecond)).getReadableMemory())/s",
            "\(localizedString("Total")): \(Units(bytes: Int64(summary.total)).getReadableMemory())"
        ].joined(separator: "  ·  ")
        self.processesLabel.stringValue = summary.processes.map {
            "\($0.processName) (\($0.processID))  ↓\(Units(bytes: Int64($0.download)).getReadableMemory())  ↑\(Units(bytes: Int64($0.upload)).getReadableMemory())"
        }.joined(separator: "\n")
        let capability = self.enforcer.capability
        switch capability {
        case .available:
            self.enforcementLabel.stringValue = localizedString("Network controls are available on this build.")
        case .unavailable(let reason):
            self.enforcementLabel.stringValue = "\(localizedString("Block/throttle requires Network Extension entitlement.") ) \(reason.message)"
        }
    }

    func hideDetail() {
        self.isHidden = true
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])

        self.closeButton.target = self
        self.closeButton.action = #selector(self.closeTapped)
        self.titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        self.identityLabel.textColor = .secondaryLabelColor
        self.identityLabel.maximumNumberOfLines = 3
        self.processesLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        self.processesLabel.maximumNumberOfLines = 12
        self.enforcementLabel.textColor = .secondaryLabelColor

        stack.addArrangedSubview(self.closeButton)
        stack.addArrangedSubview(self.titleLabel)
        stack.addArrangedSubview(self.identityLabel)
        stack.addArrangedSubview(self.totalsLabel)
        stack.addArrangedSubview(self.processesLabel)
        stack.addArrangedSubview(self.enforcementLabel)
        self.isHidden = true
    }

    @objc private func closeTapped() {
        self.hideDetail()
        self.onClose?()
    }
}
