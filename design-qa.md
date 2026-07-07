# RouteBar Design QA

- Source: `/Users/daniellau/.codex/generated_images/019f363a-0c4e-7480-9a9d-0417db9144f0/exec-56bf824d-844a-4762-9160-36ccb08e8dd1.png`
- Node source: `/Users/daniellau/.codex/generated_images/019f363a-0c4e-7480-9a9d-0417db9144f0/exec-dd1016b0-0215-4738-b71b-b66ec5a7b2af.png`
- Implementation capture: `/private/tmp/routebar-node-app.png`
- Viewport: native macOS window, 1380 × 820 points at Retina scale
- State: light mode, six subscriptions, first row selected

## Evidence

The native implementation preserves the references' subscription-first hierarchy and node-management workspace: toolbar filters, sortable table columns, row states, latency colors, inspector, sidebar, and footer. The in-process bitmap capture makes `NSVisualEffectView` side materials transparent black; this only affects the DEBUG capture. Center-column comparison verifies typography, compact row rhythm, separators, selection blue, success green, warning orange, and information density.

## Fidelity surfaces

- Typography: native San Francisco with matching hierarchy; relative dates localized to Chinese.
- Layout: native three-column split view, 12–18 point padding, 36-point node rows, compact toolbar and 40-point footer.
- Colors: semantic macOS background, separator, accent, success, destructive and secondary colors.
- Assets: native SF Symbols; no placeholder art or custom-drawn icons.
- Copy: Chinese actions, headings, states, inspector labels and menu commands.

## Findings

No actionable P0, P1, or P2 differences remain in the live implementation.

## Patches made

- Prevented toolbar and title truncation.
- Reduced node rows from 58 to 36 points and converted names to a single line to match the dense reference table.
- Added node filters, sorting, enable switches, latency status, and Reality detail inspection.
- Localized relative times.
- Added masked URLs and Keychain state.
- Added repeatable DEBUG snapshot capture.

## Follow-up polish

- [P3] Add a dedicated app icon before public distribution.
- [P3] Add dark-mode screenshot coverage.

final result: passed
