# RouteBar Design

## Goal

Build a fast, native macOS menu-bar utility for managing multiple proxy subscriptions and the local sing-box/Surge integration from one place.

## Product surface

- A `MenuBarExtra` provides service status, update-all, start/stop, and a shortcut to the management window.
- A native SwiftUI management window follows the selected “Subscription First” reference image.
- The first complete screen includes sidebar navigation, subscription list, summary metrics, search, selection, detail inspector, add/edit/delete, enable/disable, and update actions.

## Data and security

- Subscription metadata and parsed node summaries persist in Application Support as JSON.
- Subscription URLs are stored in Keychain and never written into generated UI-state files.
- VLESS nodes receive stable identifiers derived from connection attributes so multiple subscriptions can be merged and deduplicated.

## Runtime integration

- RouteBar generates sing-box JSON and a Surge profile using atomic temporary-file replacement.
- The generated sing-box configuration must pass `sing-box check` before replacing the active file.
- A runtime adapter wraps `launchctl` and reports running, stopped, and failed states without blocking the UI.
- The personal build disables App Sandbox because it manages user-owned files and processes outside its container. A distributable version will replace this with a reviewed helper architecture.

## Failure behavior

- Failed downloads retain the previous subscription snapshot and show the error on that subscription.
- Invalid or empty subscriptions do not replace working generated configuration.
- Generation or runtime failures preserve the last known-good configuration and appear in the UI and logs.

## Verification

- Swift package tests cover VLESS parsing, deduplication, deterministic port allocation, and configuration generation.
- Xcode builds the macOS app without warnings introduced by RouteBar.
- Visual QA compares a running app screenshot against the selected reference and records the result in `design-qa.md`.

## Node management and in-app scheduling

- The node workspace uses the existing native RouteBar visual language with a dense table and detail inspector.
- Users can search, filter by subscription/region/latency, sort, enable nodes, and test one or all nodes.
- Latency tests make an end-to-end HTTP request through each node's local SOCKS port with six concurrent tests at most.
- Results persist with measurement time and distinguish success, timeout, connection failure, and HTTP failure.
- Each enabled subscription schedules its next update from its last successful update and configured interval.
- Scheduling runs only while RouteBar is running. Sleep/wake and foreground transitions recalculate overdue work.
- Successful updates regenerate and validate configurations before replacement. Failed updates retain the previous nodes and configuration.
