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
    private let periodControl = NSPopUpButton()
    private let quotaControl = NSPopUpButton()
    private let downloadControl = NSPopUpButton()
    private let uploadControl = NSPopUpButton()
    private let actionControl = NSPopUpButton()
    private let pausedControl = NSButton(checkboxWithTitle: localizedString("Pause rule"), target: nil, action: nil)
    private let saveRuleButton = NSButton(title: localizedString("Save rule"), target: nil, action: nil)
    private let clearRuleButton = NSButton(title: localizedString("Clear rule"), target: nil, action: nil)

    var onClose: (() -> Void)?
    private let enforcer: NetworkRuleEnforcing
    private let ruleStore: TrafficRuleStore
    private var currentSummary: ApplicationTrafficSummary?

    private let quotaValuesGB = [0, 1, 5, 10, 50, 100]
    private let rateValues: [UInt64?] = [nil, 128_000, 512_000, 1_000_000, 5_000_000, 10_000_000]

    init(
        enforcer: NetworkRuleEnforcing = UnavailableNetworkRuleEnforcer(),
        ruleStore: TrafficRuleStore = TrafficRuleStore()
    ) {
        self.enforcer = enforcer
        self.ruleStore = ruleStore
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ summary: ApplicationTrafficSummary) {
        self.currentSummary = summary
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
        self.loadRule(applicationID: summary.identity.id)
    }

    func hideDetail() {
        self.isHidden = true
    }

    private func build() {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
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
        self.titleLabel.alignment = .left
        self.identityLabel.textColor = .secondaryLabelColor
        self.identityLabel.alignment = .left
        self.identityLabel.maximumNumberOfLines = 3
        self.totalsLabel.alignment = .left
        self.processesLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        self.processesLabel.alignment = .left
        self.processesLabel.maximumNumberOfLines = 12
        self.enforcementLabel.textColor = .secondaryLabelColor
        self.enforcementLabel.alignment = .left

        stack.addArrangedSubview(self.closeButton)
        stack.addArrangedSubview(self.titleLabel)
        self.titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(self.identityLabel)
        self.identityLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(self.totalsLabel)
        self.totalsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(self.processesLabel)
        self.processesLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        self.configureRuleControls()
        let editor = FlippedStackView()
        editor.orientation = .vertical
        editor.alignment = .width
        editor.spacing = 7
        editor.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 8
        editor.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        [
            self.controlRow(title: localizedString("Quota period"), control: self.periodControl),
            self.controlRow(title: localizedString("Application quota"), control: self.quotaControl),
            self.controlRow(title: localizedString("Download limit"), control: self.downloadControl),
            self.controlRow(title: localizedString("Upload limit"), control: self.uploadControl),
            self.controlRow(title: localizedString("Over-quota action"), control: self.actionControl)
        ].forEach { row in
            editor.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        }
        editor.addArrangedSubview(self.pausedControl)

        let actions = NSStackView(views: [self.saveRuleButton, self.clearRuleButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        editor.addArrangedSubview(actions)
        stack.addArrangedSubview(editor)
        editor.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(self.enforcementLabel)
        self.enforcementLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addSubview(editor, positioned: .above, relativeTo: nil)
        self.isHidden = true
    }

    private func configureRuleControls() {
        self.periodControl.identifier = NSUserInterfaceItemIdentifier("traffic-rule-period")
        QuotaPeriod.allCases.forEach { self.periodControl.addItem(withTitle: self.periodTitle($0)) }

        self.quotaControl.identifier = NSUserInterfaceItemIdentifier("traffic-rule-quota")
        self.quotaValuesGB.forEach {
            self.quotaControl.addItem(withTitle: $0 == 0 ? localizedString("No quota") : "\($0) GB")
        }

        self.downloadControl.identifier = NSUserInterfaceItemIdentifier("traffic-rule-download")
        self.uploadControl.identifier = NSUserInterfaceItemIdentifier("traffic-rule-upload")
        self.rateValues.forEach { value in
            let title = value.map { Units(bytes: Int64($0)).getReadableMemory() + "/s" } ?? localizedString("Unlimited")
            self.downloadControl.addItem(withTitle: title)
            self.uploadControl.addItem(withTitle: title)
        }

        self.actionControl.identifier = NSUserInterfaceItemIdentifier("traffic-rule-action")
        QuotaAction.allCases.forEach { self.actionControl.addItem(withTitle: self.actionTitle($0)) }
        self.pausedControl.identifier = NSUserInterfaceItemIdentifier("traffic-rule-paused")
        self.saveRuleButton.identifier = NSUserInterfaceItemIdentifier("traffic-rule-save")
        self.clearRuleButton.identifier = NSUserInterfaceItemIdentifier("traffic-rule-clear")
        self.saveRuleButton.target = self
        self.saveRuleButton.action = #selector(self.saveRule)
        self.clearRuleButton.target = self
        self.clearRuleButton.action = #selector(self.clearRule)
    }

    private func controlRow(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        return row
    }

    private func loadRule(applicationID: String) {
        let rule = self.ruleStore.applicationRules().first { $0.applicationID == applicationID }
            ?? ApplicationTrafficRule(applicationID: applicationID)
        self.periodControl.selectItem(at: QuotaPeriod.allCases.firstIndex(of: rule.period) ?? 2)
        let quotaGB = rule.byteLimit.map { Int($0 / 1_000_000_000) } ?? 0
        self.quotaControl.selectItem(at: self.quotaValuesGB.firstIndex(of: quotaGB) ?? 0)
        self.downloadControl.selectItem(at: self.rateValues.firstIndex { $0 == rule.downloadLimitBytesPerSecond } ?? 0)
        self.uploadControl.selectItem(at: self.rateValues.firstIndex { $0 == rule.uploadLimitBytesPerSecond } ?? 0)
        self.actionControl.selectItem(at: QuotaAction.allCases.firstIndex(of: rule.action) ?? 0)
        self.pausedControl.state = rule.isPaused ? .on : .off
    }

    @objc private func saveRule() {
        guard let summary = self.currentSummary else { return }
        let period = QuotaPeriod.allCases.indices.contains(self.periodControl.indexOfSelectedItem)
            ? QuotaPeriod.allCases[self.periodControl.indexOfSelectedItem] : .monthly
        let quotaGB = self.quotaValuesGB.indices.contains(self.quotaControl.indexOfSelectedItem)
            ? self.quotaValuesGB[self.quotaControl.indexOfSelectedItem] : 0
        let download = self.rateValues.indices.contains(self.downloadControl.indexOfSelectedItem)
            ? self.rateValues[self.downloadControl.indexOfSelectedItem] : nil
        let upload = self.rateValues.indices.contains(self.uploadControl.indexOfSelectedItem)
            ? self.rateValues[self.uploadControl.indexOfSelectedItem] : nil
        let action = QuotaAction.allCases.indices.contains(self.actionControl.indexOfSelectedItem)
            ? QuotaAction.allCases[self.actionControl.indexOfSelectedItem] : .notify
        let rule = ApplicationTrafficRule(
            applicationID: summary.identity.id,
            period: period,
            byteLimit: quotaGB == 0 ? nil : UInt64(quotaGB) * 1_000_000_000,
            downloadLimitBytesPerSecond: download,
            uploadLimitBytesPerSecond: upload,
            action: action,
            isPaused: self.pausedControl.state == .on
        )
        var rules = self.ruleStore.applicationRules().filter { $0.applicationID != summary.identity.id }
        rules.append(rule)
        self.ruleStore.save(applicationRules: rules)
        self.applyEnforcement(rule)
    }

    @objc private func clearRule() {
        guard let applicationID = self.currentSummary?.identity.id else { return }
        self.ruleStore.save(applicationRules: self.ruleStore.applicationRules().filter { $0.applicationID != applicationID })
        if case .available = self.enforcer.capability {
            try? self.enforcer.apply(NetworkEnforcementAction(applicationID: applicationID, kind: .clear))
        }
        self.loadRule(applicationID: applicationID)
        self.enforcementLabel.stringValue = localizedString("Rule cleared")
    }

    private func applyEnforcement(_ rule: ApplicationTrafficRule) {
        guard case .available = self.enforcer.capability else {
            if case .unavailable(let reason) = self.enforcer.capability {
                self.enforcementLabel.stringValue = "\(localizedString("Rule saved but inactive")): \(reason.message)"
            }
            return
        }
        let kind: NetworkEnforcementAction.Kind
        if rule.isPaused {
            kind = .pause
        } else {
            switch rule.action {
            case .notify: kind = .clear
            case .rateLimit:
                kind = .rateLimit(
                    downloadBytesPerSecond: rule.downloadLimitBytesPerSecond,
                    uploadBytesPerSecond: rule.uploadLimitBytesPerSecond
                )
            case .block: kind = .block(.both)
            }
        }
        do {
            try self.enforcer.apply(NetworkEnforcementAction(applicationID: rule.applicationID, kind: kind))
            self.enforcementLabel.stringValue = localizedString("Rule saved and applied")
        } catch {
            self.enforcementLabel.stringValue = "\(localizedString("Rule saved but inactive")): \(error.localizedDescription)"
        }
    }

    private func periodTitle(_ period: QuotaPeriod) -> String {
        switch period {
        case .daily: return localizedString("Daily")
        case .weekly: return localizedString("Weekly")
        case .monthly: return localizedString("Monthly")
        case .custom: return localizedString("Custom")
        }
    }

    private func actionTitle(_ action: QuotaAction) -> String {
        switch action {
        case .notify: return localizedString("Notify")
        case .rateLimit: return localizedString("Rate limit")
        case .block: return localizedString("Block")
        }
    }

    @objc private func closeTapped() {
        self.hideDetail()
        self.onClose?()
    }
}
