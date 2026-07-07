# RouteBar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a native RouteBar menu-bar app matching the selected subscription-management design and managing real subscription data and sing-box runtime state.

**Architecture:** Pure Swift domain types and generators sit behind an observable application store. SwiftUI renders the menu-bar and management window; Keychain stores subscription URLs, while Application Support stores non-secret state.

**Tech Stack:** Swift 5, SwiftUI, Security, Foundation, Swift Package Manager tests, Xcode.

---

### Task 1: Domain model and parser

**Files:**
- Create: `Package.swift`
- Create: `RouteBar/Core/Models.swift`
- Create: `RouteBar/Core/VLESSParser.swift`
- Create: `RouteBarCoreTests/VLESSParserTests.swift`

- [x] Write tests that require base64 and plain-text VLESS subscriptions to parse, malformed entries to be ignored, and duplicate nodes to collapse by stable identity.
- [x] Run `swift test` and confirm failure because the parser types do not exist.
- [x] Implement the smallest models and parser satisfying those cases.
- [x] Run `swift test` and confirm all parser tests pass.

### Task 2: Deterministic configuration generation

**Files:**
- Create: `RouteBar/Core/ConfigurationGenerator.swift`
- Create: `RouteBarCoreTests/ConfigurationGeneratorTests.swift`

- [x] Write tests requiring stable ports from 7701, one inbound/outbound/route per enabled node, and one Surge SOCKS5 entry per node.
- [x] Run `swift test` and confirm failure because the generator does not exist.
- [x] Implement JSON-safe sing-box generation and Surge proxy/group generation.
- [x] Run `swift test` and confirm generation tests pass.

### Task 3: Persistence, Keychain, and runtime adapters

**Files:**
- Create: `RouteBar/Services/KeychainStore.swift`
- Create: `RouteBar/Services/StateStore.swift`
- Create: `RouteBar/Services/RuntimeManager.swift`
- Create: `RouteBar/AppModel.swift`

- [x] Implement Keychain-backed URLs and JSON metadata persistence.
- [x] Implement update-all, node merging, config validation/replacement, and launchctl status/actions in `AppModel`.
- [x] Verify domain tests still pass and build errors identify only missing UI integration.

### Task 4: Native subscription-management UI

**Files:**
- Replace: `RouteBar/ContentView.swift`
- Implemented in: `RouteBar/ContentView.swift`
- Replace: `RouteBar/RouteBarApp.swift`
- Delete: `RouteBar/Item.swift`

- [x] Implement the reference layout with native split views, toolbar, summary metrics, searchable rows, inspector, progress footer, and functional add/edit/update/toggle controls.
- [x] Add a `MenuBarExtra` with status, update, start/stop, open-window, logs/config shortcuts, and quit actions.
- [x] Build with `xcodebuild` and fix all compile errors.

### Task 5: Personal-build capabilities and visual QA

**Files:**
- Modify: `RouteBar.xcodeproj/project.pbxproj`
- Create: `design-qa.md`

- [x] Disable App Sandbox for the personal build while retaining hardened runtime.
- [x] Run all Swift tests and the Xcode build.
- [x] Launch RouteBar, capture the subscription screen at the reference state, compare it with the selected image, and record findings.
- [x] Fix all P0/P1/P2 visual differences and repeat until `design-qa.md` reports `final result: passed`.

### Task 6: Scheduling and latency domain logic

**Files:**
- Modify: `RouteBar/Core/Models.swift`
- Implemented in: `RouteBar/Core/Models.swift`
- Implemented in: `RouteBarCoreTests/VLESSParserTests.swift`

- [x] Write failing tests for next-update calculation, overdue subscriptions, paused scheduling, and persisted latency states.
- [x] Run `swift test` and confirm the new tests fail because scheduling types do not exist.
- [x] Implement deterministic scheduling and latency result models.
- [x] Run `swift test` and confirm the scheduling tests pass.

### Task 7: End-to-end SOCKS latency tester

**Files:**
- Implemented in: `RouteBar/Services/RuntimeManager.swift`
- Modify: `RouteBar/AppModel.swift`

- [x] Implement URLSession proxy configurations for per-port SOCKS requests with a six-task concurrency limit.
- [x] Record success, timeout, connection, and HTTP failures.
- [x] Expose single-node and all-node test actions in `AppModel`.
- [x] Run all core tests and build the app.

### Task 8: Application-lifetime automatic updates

**Files:**
- Implemented in: `RouteBar/AppModel.swift`
- Modify: `RouteBar/AppModel.swift`
- Modify: `RouteBar/RouteBarApp.swift`

- [x] Start the scheduler while RouteBar is running.
- [x] Recalculate overdue subscriptions after wake or activation.
- [x] Add pause/resume and next-update state to the menu bar.
- [x] Keep automatic updates process-local so no update process remains after RouteBar exits.

### Task 9: Native node workspace

**Files:**
- Modify: `RouteBar/ContentView.swift`
- Implemented in: `RouteBar/ContentView.swift`

- [x] Implement searchable and sortable node rows with subscription, region, port, latency, status, and enablement.
- [x] Implement filters and single/all latency actions.
- [x] Implement the selected-node inspector with Reality details and last-test state.
- [x] Build, capture, and update `design-qa.md` after comparison with the node-workbench reference.
