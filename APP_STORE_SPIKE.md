# App Store Sandbox Spike — Findings

Branch-only experiment (`spike/app-store-sandbox`); not merged to main.
Sandbox was enabled (`ENABLE_APP_SANDBOX = YES` + `com.apple.security.app-sandbox`
in Debug entitlements) and the app was built, signed, launched, and driven
on 2026-07-22.

## What was tested empirically (sandboxed build, real launch)

| Capability | Result |
|---|---|
| App launch, menu bar item, panels, global hotkeys | **Works** unchanged |
| Container creation | Works — prefs and notes move to `~/Library/Containers/com.dylblake.noteside/` |
| Finder Apple Events (folder context) with `temporary-exception.apple-events` | **Works** — drawer resolved `~/Documents` via the Finder script |
| Onboarding, trial flow, on-device title generation | Works |

## What this means for a MAS build

1. **Apple Events are technically fine, but review is the risk.**
   `com.apple.security.temporary-exception.apple-events` works at runtime
   (verified for Finder). App Review historically rejects broad exception
   lists; NoteSide needs ~12 targets (10 browsers + Finder + Xcode).
   Mitigations to explore, in order:
   - AX-based URL reading for browsers (Safari/Chrome expose the address
     bar via accessibility) — removes browser exceptions entirely and is
     the strongest play. Prototype not yet built.
   - Trim the exception list to Finder + Xcode only.
2. **Accessibility API needs no entitlement.** User grants it in System
   Settings; sandboxed MAS apps (Magnet et al.) ship this way. Slack /
   Figma / VS Code detection and the AXObserver survive as-is.
3. **Data migration is mandatory.** The container gets a fresh
   `Application Support/SideNote`; existing users' notes at
   `~/Library/Application Support/SideNote/notes.json` must be imported
   on first sandboxed launch (a one-time copy; the old path is readable
   via a user-selected-file or migration entitlement — or ship the
   migration in the *last* non-sandboxed release).
4. **File-identity tracking degrades.** Without read access to arbitrary
   paths, `fileResourceIdentifier` (inode) and security-scoped bookmark
   creation fail for files the user never granted; file notes fall back
   to path-keyed identity (rename tracking is lost until the file is
   opened via an open panel / drag). Acceptable, but should be a known
   regression.
5. **The self-updater must be compiled out.** `hdiutil`, `Process`,
   bundle swap, and quarantine-stripping are all sandbox/MAS
   incompatible. Gate `UpdateChecker` behind a build flag.
6. **The license model conflicts with MAS rules.** Selling unlock keys
   outside Apple IAP is not allowed in-app. Options: paid-up-front app,
   IAP unlock alongside the existing key system (external keys accepted
   but never sold in-app), or freemium via IAP. Business decision, not
   engineering.
7. **Dictation, SMAppService login item, FoundationModels** — all
   sandbox-compatible.

## Rough cost to ship on MAS

- AX-based browser URL prototype: ~1 week including per-browser quirks
- Container migration + build-flag updater removal: 1–2 days
- IAP or pricing rework: business decision + a few days
- Review-cycle risk on the remaining Apple Events exceptions: unknown,
  budget at least one rejection round

## How to reproduce

```
git checkout spike/app-store-sandbox
xcodebuild -scheme NoteSide -configuration Debug build
# entitlements: NoteSide/NoteSide.Debug.entitlements
```
