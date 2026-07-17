# Network Analytics UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Network preview root with a three-page AppKit interface containing the existing real-time monitor, traffic analysis, usage overview, and CSV/JSON export.

**Architecture:** `Preview` becomes a page host. Existing content moves unchanged into `RealtimeNetworkView`; analysis pages render immutable core snapshots. Controls update one shared `TrafficSelection`, keeping timeline, heatmap, totals, and ranking synchronized.

**Tech Stack:** AppKit, existing Kit controls, Core Graphics charts, XCTest state tests, macOS 12 SF Symbols.

---

### Task 1: Preserve Real-time UI In A Three-page Host

**Files:**
- Create: `Modules/Net/analytics/views.swift`
- Modify: `Modules/Net/preview.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write host state tests**

Test `NetworkPreviewPage` cases `realtime`, `analysis`, and `overview`; an invalid stored raw value falls back to real-time.

- [ ] **Step 2: Verify RED**

Run the focused Net analytics test command. Expected: missing page state.

- [ ] **Step 3: Extract current preview and add host**

Move current controls and callbacks into `RealtimeNetworkView`. Keep `Preview.usageCallback` and `connectivityCallback` as forwarding methods. Add a centered icon segmented control and borderless `NSTabView`. Real-time rendering must remain unchanged.

- [ ] **Step 4: Verify and commit**

Run the full suite and commit as `feat(net): add three-page network preview`.

### Task 2: Add Shared Analysis Controls And Summary Cards

**Files:**
- Create: `Modules/Net/analytics/selection.swift`
- Create: `Modules/Net/analytics/analysis_view.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing selection tests**

Verify six ranges map to exact intervals and refresh choices map to manual, 5, 10, 30, 60, and 300 seconds. Manual must not schedule a timer.

- [ ] **Step 2: Implement controls and cards**

Add Stats-style range and line/heatmap segmented controls, network/export/refresh menus, a refresh icon button, and fixed-height download/upload/total sections. Every input calls one `reload(selection:)` path.

- [ ] **Step 3: Verify and commit**

Run focused and full tests. Commit as `feat(net): add traffic analysis controls`.

### Task 3: Add Timeline And Adaptive Heatmap

**Files:**
- Create: `Modules/Net/analytics/charts.swift`
- Modify: `Modules/Net/analytics/analysis_view.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing chart geometry tests**

Cover empty, single-point, and large datasets; every heatmap dimension; drag selection normalization; hover hit testing; and heatmap cell selection.

- [ ] **Step 2: Implement chart views**

Use Core Graphics with Stats colors, stable insets, accessible labels, tooltip tracking, drag-to-select for lines, and click-to-zoom for heatmap cells. Empty/loading/data states retain identical dimensions.

- [ ] **Step 3: Verify and commit**

Run focused and full tests. Commit as `feat(net): add interactive traffic charts`.

### Task 4: Add Application Ranking And Detail Navigation

**Files:**
- Create: `Modules/Net/analytics/application_table.swift`
- Create: `Modules/Net/analytics/application_detail.swift`
- Modify: `Modules/Net/analytics/analysis_view.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing presenter tests**

Test every sort column, stable ties, search matching, expansion, child totals, and missing icon/bundle formatting.

- [ ] **Step 2: Implement ranking and detail**

Use `NSOutlineView` for application/process rows and `NSSearchField` for filtering. Disclosure opens an in-page detail with the same range. Set fixed numeric column widths and compression priorities for the 540-point content minimum.

- [ ] **Step 3: Verify and commit**

Run focused and full tests. Commit as `feat(net): add application traffic ranking`.

### Task 5: Add Usage Overview And Export

**Files:**
- Create: `Modules/Net/analytics/overview_view.swift`
- Create: `Modules/Net/analytics/export.swift`
- Modify: `Modules/Net/analytics/views.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing export and overview tests**

Verify CSV quoting and stable columns, JSON schema version, active-selection metadata, billing dates, forecast, seven-day totals, and top-app percentages.

- [ ] **Step 2: Implement overview and export**

Build quota status, period total, forecast, seven-day chart, and top-app sections. Use `NSSavePanel`, encode off-main, expose only CSV and JSON, and report file errors on main.

- [ ] **Step 3: Verify and commit**

Run focused and full tests. Commit as `feat(net): add usage overview and exports`.
