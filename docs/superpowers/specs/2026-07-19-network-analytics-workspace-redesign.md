# Network Analytics Workspace Redesign

## Status

Approved on July 19, 2026. This specification corrects the presentation structure in
`2026-07-17-network-analytics-design.md`. The analytics backend, retention, alerts,
exports, network plans, application rules, and entitlement boundary remain unchanged.

## Objective

Present Network Analytics as a dedicated, full-width Stats workspace matching the
three supplied acceptance screenshots. The existing Network settings page remains
for widget, collector, quota, retention, and capability configuration; it is not the
analytics product surface.

## Entry And Window Structure

- Stats exposes a Network Analytics action from the Network module.
- The action opens or raises one reusable `NSWindow` owned by the Network module.
- The workspace is approximately 1080 x 760 by default, resizable, and usable down
  to 720 x 480.
- Closing the workspace does not stop collection or delete selection state.
- The current Network settings page remains reachable from the workspace gear button.
- The workspace contains no Stats settings sidebar and no widget configuration tabs.

## Shared Header

The title bar uses the normal macOS traffic-light controls. A centered three-item
icon selector switches pages:

1. line-chart icon: monthly overview;
2. bar-chart icon: history analysis;
3. waveform icon: live application traffic.

The right side contains alert history, manual refresh, and settings buttons. Icon-only
controls have localized accessibility descriptions and tooltips. Page selection and
window frame persist across close/reopen and application restart.

## Monthly Overview

The overview follows the supplied overview screenshot:

- a full-width anomaly status strip;
- a large current-period usage card showing total usage, billing progress, quota
  remainder when configured, and month-end forecast;
- a seven-day card with daily average, seven-day total, weekday labels, values, and
  a filled trend curve;
- a six-item application grid with resolved icons, application name, bytes, share,
  and honest proxy/tunnel labels;
- a local-first footer stating that analytics remain on the Mac.

Cards keep stable heights for loading, empty, insufficient-data, and error states.

## History Analysis

The history page follows the supplied analysis screenshot:

- first toolbar row: 10 minutes, 1 hour, today, 7 days, 30 days, current month,
  custom range, line/heatmap, concrete network, export, and refresh mode;
- three equal summary cards for download, upload, and total;
- a timeline card with title, drag-selection help, alert-marker help, chart, hover
  details, and a compact chart-options menu;
- an application-ranking card with title, interval-link help, search, sortable
  columns, icons, expandable process rows, and an empty-state message;
- selection, network, search, sort, grouping, chart options, and refresh mode reload
  through the existing `TrafficSelectionStore`.

At 720-point width, secondary options move into the More menu while range, network,
export, alerts, and refresh remain visible and operable.

## Live Application Traffic

The live page follows the supplied live screenshot:

- an all-app/single-app focus control;
- a full-width rate summary card showing download, upload, and total rates;
- a 60-second/5-minute/15-minute chart card with two independent series and stable
  axes;
- an active-process card sorted by current rate, with application/process icons,
  proxy/tunnel metadata, and separate upload/download values;
- existing interface diagnostics remain available from a secondary disclosure or
  detail area and do not dominate the live analytics page.

The live chart refreshes once per second. Changing display page or range never pauses
the collection coordinator.

## Settings And Rules

The workspace gear opens the existing Network settings destination. Application
detail remains available from history/live rows. Without a functional Apple Network
Extension entitlement, rate-limit and block rules can be saved but remain inactive;
apply controls stay disabled and no `pf` or privileged fallback is introduced.

## Architecture

- Add a Network-owned window controller and a shared workspace root view.
- Reuse `TrafficAnalyticsEngine`, `TrafficHistoryRepository`, `TrafficRuleStore`,
  `NetworkRegistry`, `TrafficSelectionStore`, and the existing presentation helpers.
- Refactor `TrafficOverviewView`, `TrafficAnalysisView`, and `LiveTrafficView` into
  card-based workspace pages rather than duplicating analytics logic.
- Keep the legacy Stats Network preview for compact diagnostics and provide a clear
  action that opens the workspace.
- The Network module owns one repository/engine pair shared by collection, preview,
  and workspace. No second LevelDB owner or duplicate collector is created.

## Localization And Accessibility

Every visible string is localized in English and Simplified Chinese. Controls expose
roles, labels, values, and tooltips. Numeric table sorting uses raw values rather than
formatted strings. Light and dark appearances use semantic AppKit colors.

## Verification

Completion requires:

- focused analytics tests and unsigned Debug build pass;
- one workspace window is reused when opened repeatedly;
- screenshots at approximately 1080 x 760 and 720 x 480;
- overview, history, and live screenshots visually match the supplied hierarchy;
- light and dark appearances and English/Simplified Chinese do not clip controls;
- real traffic updates the live chart and ranking;
- history range/network/export/alert controls remain reachable at minimum width;
- the settings gear opens Network settings;
- an unsigned build shows saved-but-inactive enforcement with disabled apply controls;
- final changes are committed and pushed to `codex/network-analytics`.
