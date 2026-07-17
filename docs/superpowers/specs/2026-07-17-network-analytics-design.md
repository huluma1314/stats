# Network Analytics Design

## Objective

Extend the existing Stats Network preview with persistent, per-application
traffic analytics while preserving the current real-time monitoring page. The
feature must remain local-first, work on Intel and Apple Silicon, and keep the
project's macOS 12 deployment target.

The reference screenshots define the information architecture and interactions,
but the implementation uses Stats' existing AppKit visual language and does not
copy third-party source code, branding, or assets.

## Product Structure

The existing Network item in the Stats settings window remains the only entry
point. Its preview becomes a three-page segmented interface:

1. **Real-time monitor** preserves the current `Modules/Net/preview.swift`
   content and behavior.
2. **Traffic analysis** contains range controls, line/heatmap modes, network
   filtering, refresh controls, download/upload/total summaries, an interactive
   timeline, and a searchable application ranking.
3. **Usage overview** contains current billing-period usage, quota status,
   projected usage, a seven-day trend, and the highest-traffic applications.

The pages remain inside the existing resizable settings window. They do not add
a menu-bar item or open another window. The layout supports light and dark mode,
English, and Simplified Chinese.

## Time And Refresh Controls

Traffic analysis supports these ranges: 10 minutes, 1 hour, today, 7 days,
30 days, and current month. Line and heatmap views use the same selected range
and network filter.

Heatmap buckets are adaptive:

- 10 minutes: 30 seconds per cell
- 1 hour: 5 minutes per cell
- Today: 1 hour per cell
- 7 days: weekday by hour
- 30 days and current month: 1 day per cell

Hovering a point or cell shows download, upload, and total bytes. Selecting a
chart interval filters the application ranking to the same interval. Selecting
a heatmap cell zooms the timeline and ranking to that cell.

The display refresh choices are manual, 5 seconds, 10 seconds, 30 seconds,
1 minute, and 5 minutes. They only control UI refresh. Background collection
continues at one-second resolution. In manual mode, the existing refresh button
reloads the visible data.

## Collection And Application Identity

The existing `UsageReader` remains the source of interface totals and current
bandwidth. The existing `ProcessReader` remains the basis for process totals,
but parsing, identity resolution, and sampling are separated into testable
components.

Application identity follows these rules:

- Processes with a running macOS application are grouped by bundle identifier.
- Helper and child processes are grouped under their owning application when an
  owning bundle can be resolved.
- Processes without a bundle identifier are grouped by canonical executable
  path, with the process name as the fallback display name.
- The stored identity includes display name, bundle identifier when available,
  executable path when available, icon lookup metadata, and child process data.
- Search matches display name, bundle identifier, and process name.

The default ranking shows one row per application. Expanding a row shows its
processes. Columns are download, upload, peak transfer rate, and total. Sorting
is available on every numeric column.

Collection starts when the enhanced build first runs with the Network module
enabled. Existing lifetime interface counters are displayed only in the
real-time page and are not backfilled into historical analytics.

## Network Scope And De-duplication

Filters include all networks, Wi-Fi, Ethernet, hotspot/cellular, and
VPN/tunnel. Local-network traffic is included by default and can be disabled in
settings.

Each sample records the observed interface. The all-networks view de-duplicates
tunnel and physical-interface accounting where the same transfer is visible at
both layers. De-duplication uses interface class and primary-route context; it
never subtracts bytes from a single application's monotonic process counters.

## Persistence And Retention

Historical data is stored locally through Stats' existing LevelDB wrapper. A
dedicated serial repository queue owns all database access. Keys are ordered by
schema version, aggregation level, timestamp, network identifier, and
application identifier so range queries remain prefix-based.

Retention is tiered:

- One-second samples for 24 hours
- One-minute aggregates for 30 days
- One-hour aggregates for 2 years
- Monthly and yearly summaries without automatic expiry

Compaction is incremental and bounded so it cannot block the UI or the network
reader. Aggregation records preserve download, upload, peak rate, sample count,
and application/network dimensions. Settings provide a destructive, confirmed
action to clear all analytics history.

## Quotas, Forecasts, And Alerts

Users can define independent plans for network identities such as a Wi-Fi SSID
or hotspot. A plan contains its billing-cycle day, byte limit, and notification
thresholds. Defaults are the first day of the month and alerts at 80%, 90%, and
100%. Reaching a network quota never disconnects the network automatically.

Applications can have daily, weekly, monthly, or custom-period quotas. Their
over-limit action is notify, rate-limit, or block. Upload and download limits
are configured independently. Rules can be paused or temporarily allowed for
10 minutes or 1 hour.

The usage forecast extrapolates the current billing-period rate over the
remaining days and explicitly labels insufficient-data states. Alerts include:

- Network or application quota thresholds
- Sustained upload above a user-defined rate and duration
- A traffic spike relative to the application's historical baseline
- Network disconnect, recovery, or repeated instability

Alerts appear in the notification center view and as timeline markers. The
default action is notification only. Automatic enforcement occurs only for a
rule the user explicitly configures.

## Enforcement Capability Boundary

Per-application blocking and throttling are modeled behind a
`NetworkRuleEnforcing` interface. The standard build uses an unavailable
implementation that reports the missing Network Extension entitlement and
never claims a rule is active.

A Network Extension implementation and its configuration UI are included as a
separate, capability-gated target. It becomes operational only after a future
build is signed with the Apple-granted entitlement. The project does not use
`pf` address rules as a substitute because those rules can affect unrelated
applications sharing an endpoint.

This boundary lets all analytics, quotas, forecasts, exports, and alerts work
without a paid Apple Developer account while keeping enforcement ready for
proper signing later.

## Export

The export menu contains CSV and JSON. Export uses the active time range,
network filter, and chart selection. Both formats include interval metadata,
download/upload/total values, application name, bundle identifier, and process
identity where applicable. Export work runs off the main thread and reports
file-system errors without losing the current selection.

## Component Boundaries

The implementation is divided into these units:

- **Sampling:** parse `nettop` output, resolve application identity, and emit
  normalized deltas.
- **Repository:** persist samples, aggregate retention tiers, query ranges, and
  clear history.
- **Analytics:** bucket time ranges, compute summaries, forecasts, rankings,
  heatmap intensity, and anomaly events.
- **Rules:** store quota and enforcement policies, evaluate thresholds, and
  call the capability-gated enforcer.
- **Presentation:** host the three AppKit pages, controls, charts, table, detail
  view, settings, alert list, and exports.

Readers never update AppKit views directly for the new analytics path. They
publish normalized samples to the repository and lightweight snapshots to the
main-thread presentation coordinator. Existing real-time callbacks remain
unchanged to avoid regressions.

## Failure Handling

- A failed `nettop` launch records a diagnostic event and retries with bounded
  backoff; the real-time interface reader continues independently.
- Malformed process rows are skipped individually and counted for diagnostics.
- Database open or write failure disables history for the session, shows a
  non-blocking status, and retains real-time monitoring.
- Interrupted aggregation is idempotent because aggregate keys are replaced
  atomically after source data has been read.
- Export failures leave the database and current UI state unchanged.
- Missing enforcement entitlement disables enforcement controls with an
  accurate explanation and no false success state.

## Testing And Acceptance

Unit tests cover process parsing, identity grouping, monotonic counter resets,
time bucketing across calendar boundaries, retention aggregation, filtering,
ranking, forecasts, quotas, anomalies, and CSV/JSON encoding. Repository tests
use a temporary LevelDB directory. Rule tests use a fake enforcer and verify
that the unavailable production enforcer cannot report success.

Integration verification covers:

- Existing Stats tests remain green.
- Debug builds succeed on the current machine with the macOS 12 target intact.
- Network preview callbacks still update the existing real-time page.
- History survives application restart and totals match exported data.
- Manual display refresh does not pause collection.
- Range, network, chart selection, and application ranking stay synchronized.
- The UI remains usable at the minimum settings-window size and at a wide
  desktop size in light and dark appearances.
- Intel and Apple Silicon code paths compile without architecture-specific
  assumptions.

## Delivery Sequence

Work is delivered in independently testable milestones:

1. Sampling models, parser, repository, retention, analytics, and tests.
2. Three-page host with the existing real-time page preserved.
3. Traffic-analysis controls, charts, heatmap, ranking, and export.
4. Usage overview, plans, forecasts, alerts, and settings.
5. Application detail, rule storage, and entitlement-gated enforcement UI.
6. Localization, appearance verification, performance checks, and public fork
   documentation.

No milestone introduces a paid subscription or Pro feature gate.
