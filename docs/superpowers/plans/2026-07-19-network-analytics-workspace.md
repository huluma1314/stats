# Network Analytics Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the embedded analytics preview with a reusable, full-width Network Analytics window whose overview, history, and live pages match the supplied acceptance screenshots.

**Architecture:** The Network module owns one repository and engine shared by collection, the compact legacy preview, and a new `NetworkAnalyticsWindowController`. A workspace root view owns the shared header and swaps three card-based page views. Existing query, selection, export, alert, rule, and icon services are reused rather than duplicated.

**Tech Stack:** Swift 5, AppKit, Auto Layout, existing Stats `Kit`, LevelDB-backed analytics repository, XCTest, macOS 12 deployment target.

---

### Task 1: Add The Reusable Workspace Window And Entry Point

**Files:**
- Create: `Modules/Net/analytics/workspace_window.swift`
- Create: `Modules/Net/analytics/workspace_view.swift`
- Modify: `Modules/Net/main.swift`
- Modify: `Modules/Net/preview.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`
- Test: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Write failing window ownership tests**

Add tests that instantiate a window controller with an in-memory repository and assert one reusable window, persisted page selection, `1080 x 760` default size, `720 x 480` minimum size, and no settings sidebar.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild test -project Stats.xcodeproj -scheme Stats -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:Tests/NetAnalyticsTests/testNetworkAnalyticsWorkspaceReusesOneWindowAndPersistsSelectedPage -only-testing:Tests/NetAnalyticsTests/testNetworkAnalyticsWorkspaceHasNoSettingsSidebarAndUsesMinimumSize
```

Expected: compile failure because the window controller and workspace page types do not exist.

- [ ] **Step 3: Implement the window controller**

Create `NetworkAnalyticsWorkspacePage` with `overview`, `history`, and `live`, plus a controller with:

```swift
@discardableResult func show() -> NSWindow
func select(_ page: NetworkAnalyticsWorkspacePage)
var selectedPage: NetworkAnalyticsWorkspacePage { get }
```

Use one lazily created `NSWindow`, default content size `1080 x 760`, minimum `720 x 480`, autosave name `NetworkAnalyticsWorkspaceWindow`, and raise rather than duplicate the window.

- [ ] **Step 4: Add a compact preview action**

Add `Open Network Analytics` to the legacy Network preview. Wire it through `Network` so collection, preview, and workspace share the same repository and engine; never create a second LevelDB owner.

- [ ] **Step 5: Verify and commit**

```bash
git add Modules/Net/analytics/workspace_window.swift Modules/Net/analytics/workspace_view.swift Modules/Net/main.swift Modules/Net/preview.swift Stats.xcodeproj/project.pbxproj Tests/NetAnalytics.swift
git commit -m "feat(net): add analytics workspace window"
```

### Task 2: Build The Shared Header And Page Host

**Files:**
- Modify: `Modules/Net/analytics/workspace_view.swift`
- Modify: `Modules/Net/analytics/views.swift`
- Modify: `Stats/Supporting Files/en.lproj/Localizable.strings`
- Modify: `Stats/Supporting Files/zh-Hans.lproj/Localizable.strings`
- Test: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Write failing header tests**

Assert stable identifiers `analytics-page-overview`, `analytics-page-history`, `analytics-page-live`, `analytics-alerts`, `analytics-refresh`, and `analytics-settings`.

- [ ] **Step 2: Verify RED**

Run only the new test. Expected: missing controls and identifiers.

- [ ] **Step 3: Implement the header**

Use a centered segmented control with SF Symbols `chart.xyaxis.line`, `chart.bar.fill`, and `waveform.path.ecg`. Add trailing alert, refresh, and settings icon buttons with localized accessibility descriptions and tooltips. Swap exactly one full-width page in the host.

- [ ] **Step 4: Persist page state**

Persist under `net.analytics.workspace.page.v1`; invalid values restore `.overview`. Keep frame persistence under the window autosave name.

- [ ] **Step 5: Verify and commit**

```bash
git add Modules/Net/analytics/workspace_view.swift Modules/Net/analytics/views.swift 'Stats/Supporting Files/en.lproj/Localizable.strings' 'Stats/Supporting Files/zh-Hans.lproj/Localizable.strings' Tests/NetAnalytics.swift
git commit -m "feat(net): build analytics workspace navigation"
```

### Task 3: Rebuild The Monthly Overview

**Files:**
- Modify: `Modules/Net/analytics/overview_view.swift`
- Modify: `Modules/Net/analytics/charts.swift`
- Modify: localization files
- Test: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Write failing overview hierarchy tests**

Assert identifiers `overview-anomaly-status`, `overview-period-card`, `overview-seven-day-card`, and `overview-top-applications`.

- [ ] **Step 2: Verify RED**

Run the new overview test. Expected: current hierarchy lacks the acceptance cards.

- [ ] **Step 3: Implement the card hierarchy**

Build a vertical scroll content view with semantic AppKit colors: 32-point status strip, 145-point usage card, 172-point seven-day trend card, 202-point top-applications card, and 28-point local-first footer. Show billing progress, quota remainder, forecast, seven weekday/value labels, a filled curve, and a responsive 3x2 or 2x3 icon grid.

- [ ] **Step 4: Add stable empty states**

Keep card heights unchanged while showing localized empty, insufficient-data, loading, or error text.

- [ ] **Step 5: Verify and commit**

```bash
git add Modules/Net/analytics/overview_view.swift Modules/Net/analytics/charts.swift 'Stats/Supporting Files/en.lproj/Localizable.strings' 'Stats/Supporting Files/zh-Hans.lproj/Localizable.strings' Tests/NetAnalytics.swift
git commit -m "feat(net): redesign monthly analytics overview"
```

### Task 4: Rebuild History Analysis

**Files:**
- Modify: `Modules/Net/analytics/analysis_view.swift`
- Modify: `Modules/Net/analytics/application_table.swift`
- Modify: `Modules/Net/analytics/charts.swift`
- Modify: `Modules/Net/analytics/export.swift`
- Test: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Write failing hierarchy and minimum-width tests**

Assert `history-toolbar`, `history-download-card`, `history-upload-card`, `history-total-card`, `history-timeline-card`, and `history-ranking-card`. At 720 points, assert range, network, export, alerts, and refresh have non-empty visible rects.

- [ ] **Step 2: Verify RED**

Expected: current embedded stack does not match the target hierarchy.

- [ ] **Step 3: Implement the target composition**

Create a toolbar, three equal summary cards, timeline card, and ranking card. Below 900 points, move refresh mode, grouping, proxy labels, series visibility, and alert markers into More while keeping range, network, export, alerts, and refresh visible.

- [ ] **Step 4: Preserve immutable export parity**

Capture snapshot, selection, network metadata, and grouping before leaving the main thread. Keep schema v2 and ensure exported traffic rows sum to visible totals.

- [ ] **Step 5: Verify and commit**

```bash
git add Modules/Net/analytics/analysis_view.swift Modules/Net/analytics/application_table.swift Modules/Net/analytics/charts.swift Modules/Net/analytics/export.swift Tests/NetAnalytics.swift
git commit -m "feat(net): redesign history analytics workspace"
```

### Task 5: Rebuild Live Application Traffic

**Files:**
- Modify: `Modules/Net/analytics/analysis_view.swift`
- Modify: `Modules/Net/preview.swift`
- Test: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Write failing live hierarchy tests**

Assert `live-focus`, `live-rate-card`, `live-chart-card`, and `live-active-processes`.

- [ ] **Step 2: Verify RED**

Expected: current live view lacks the acceptance composition.

- [ ] **Step 3: Implement the live layout**

Create a focus control, full-width summary card, 60s/5m/15m chart card, and active-process card. Use owner/process icons, independent blue download and orange upload series, monospaced rates, and current-frame sorting by total rate.

- [ ] **Step 4: Preserve diagnostics outside the dominant page**

Keep interface diagnostics in the compact legacy preview or a secondary disclosure; do not let them dominate the live analytics workspace.

- [ ] **Step 5: Verify and commit**

```bash
git add Modules/Net/analytics/analysis_view.swift Modules/Net/preview.swift Tests/NetAnalytics.swift
git commit -m "feat(net): redesign live application workspace"
```

### Task 6: Visual Acceptance And Delivery

**Files:**
- Modify defects in `Modules/Net/analytics/*.swift`
- Modify localization files
- Modify `README.md` if entry instructions change
- Test: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Run automated verification**

```bash
xcodebuild test -project Stats.xcodeproj -scheme Stats -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:Tests/NetAnalyticsTests
xcodebuild build -project Stats.xcodeproj -scheme Stats -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: analytics tests pass, Debug build succeeds, and diff check is empty. Record the unrelated Kit baseline separately.

- [ ] **Step 2: Capture wide screenshots**

Run the unsigned Debug app, open the workspace at approximately `1080 x 760`, and capture overview, history, and live pages. Compare hierarchy, spacing, cards, controls, icons, and empty states with the supplied screenshots.

- [ ] **Step 3: Verify 720 x 480**

Confirm page selector, alerts, refresh, settings, history range, network, export, and live range remain reachable without horizontal scrolling.

- [ ] **Step 4: Verify appearance and localization**

Inspect light/dark mode and English/Simplified Chinese. Fix clipping, untranslated strings, contrast, and accessibility labels.

- [ ] **Step 5: Verify entitlement boundary**

Confirm rate-limit/block rules save inactive, apply stays disabled, the localized explanation is visible, and no active state or `pf` fallback appears.

- [ ] **Step 6: Commit and push**

```bash
git add Modules/Net Stats/Supporting\ Files/en.lproj/Localizable.strings Stats/Supporting\ Files/zh-Hans.lproj/Localizable.strings Tests/NetAnalytics.swift README.md Stats.xcodeproj/project.pbxproj
git commit -m "feat(net): deliver full-width analytics workspace"
git push origin codex/network-analytics
```

Expected: remote screenshots and implementation show the three target analytics pages, not the Network settings page.
