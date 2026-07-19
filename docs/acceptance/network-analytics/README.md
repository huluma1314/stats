# Network Analytics visual acceptance

Captured from the unsigned Debug build on 2026-07-19 using the real
`NetworkAnalyticsWindowController` workspace (not the Network settings page).

- `overview.png`, `history.png`, `live.png`: Simplified Chinese, approximately 1080x760 content.
- `history-min-720x480.png`, `live-min-720x480.png`: minimum-size reachability with vertical scrolling.
- `live-dark-en.png`: English in Dark Aqua.

The unsigned-build entitlement boundary is covered by `NetAnalyticsTests`: block and
rate-limit rules save inactive, Apply remains unavailable, the localized Network
Extension explanation is exposed, and the shipping enforcer has no `pf` fallback.
