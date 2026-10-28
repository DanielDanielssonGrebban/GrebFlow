# GrebFlowClaude

Native macOS menu bar dictation app for developers. Hold right Option, speak, release, and the text is pasted into the focused field. A dashboard shows usage stats and Claude-generated groups of related requests.

This is one of three parallel builds of the same plan, made at a Grebban hackday. The other two are GrebFlowSol and GrebFlowArgon, in sibling worktrees. All three run on the same Mac at once.

**The spec is `../plans/core-plan-claude.md`.** Read it before changing behavior. `../plans/core-plan.md` is the shared base, and `../plans/v2-plan.md` lists deferred features. Don't build V2 items unless asked.

## Status

- V1 is implemented and runs. Live dictation, permissions, and paste were confirmed working by the user on their Mac.
- Not yet verified manually: five consecutive pastes in a row, all three variants running together, real grouping quality with an API key, Launch at login, latency numbers.
- Nothing is committed yet. Everything lives untracked in `GrebFlowClaude/` on branch `feat/greb-flow-claude`.

## Build, run, test

Run from this folder (`GrebFlowClaude/`):

```sh
scripts/run.sh          # Release build → build/GrebFlowClaude.app, stop the old copy, launch with --dashboard
scripts/run.sh --test   # tests first
xcodebuild -project GrebFlowClaude.xcodeproj -scheme GrebFlowClaude -derivedDataPath build/DerivedData test
```

- Always launch `build/GrebFlowClaude.app`. macOS ties microphone, Input Monitoring, and Accessibility grants to the bundle ID and signature, so a copy elsewhere (like DerivedData) asks for permission again.
- Launching the app needs `dangerouslyDisableSandbox: true` in the Bash tool. Building and testing don't.
- `open build/GrebFlowClaude.app` while it's running brings the dashboard back. The menu bar icon is often hidden behind the MacBook notch, so the user may not see it.
- Toolchain: Xcode 26.0.1, Swift 6.2, macOS 26 SDK, macOS 26.6.2, Apple silicon. Swift 6 language mode with strict concurrency. Keep the build warning-free.
- Signing: manual, `Apple Development` identity, team `6MKPN7MS3V`, hardened runtime on, sandbox off, `com.apple.security.device.audio-input` in `Config/GrebFlowClaude.entitlements`. Info.plist is generated from `INFOPLIST_KEY_*` build settings (LSUIElement, microphone usage text).

## Layout

The Xcode project uses synchronized folders (`PBXFileSystemSynchronizedRootGroup`), so new files under `GrebFlowClaude/` or `GrebFlowClaudeTests/` are picked up automatically. No pbxproj edits are needed for new files. `.md` files in the source folder become bundle resources.

```text
GrebFlowClaude/
  App/         GrebFlowClaudeApp (main + AppDelegate), AppModel (composition root), InsightsModel (dashboard data)
  Dictation/   DictationCoordinator, ShortcutMonitor (+ ShortcutInterpreter), AudioPipeline, MicrophoneCapture,
               SpeechEngine (LiveDictationEngine, SpeechAssets), TranscriptAssembler, Paste, SetupController
  Storage/     SwiftData models, HistoryStore, Statistics (UsageStats, PhraseCounter, StopWords), DemoSeeder
  Analysis/    AnthropicClient, GroupingPrompt (build + validate), GroupingInstructions.md, AnalysisCoordinator
  Settings/    Preferences, KeychainStore, PermissionService, APIKeyController, LoginItemController
  UI/          StatusItemController (+ StatusIcon), DashboardView (+ window controller), Overview/Usage/History/Settings views
GrebFlowClaudeTests/   Swift Testing suites, fakes in TestSupport.swift
```

## Architecture

- `AppModel` creates and owns every service. Views only read observable state and call `AppModel` actions. Views never touch SwiftData, the mic, or analysis directly, and never compute stats in `body`. The plan requires that a dashboard redesign can't change core behavior.
- `InsightsModel.refresh(from:)` computes stats, phrases, sentences, groups, and coverage for the selected dataset. `AppModel.refreshInsights()` runs it after saves, deletes, batch saves, and dataset switches.
- Two separate SwiftData stores, `real.store` and `sample.store`, live in `~/Library/Application Support/com.grebban.GrebFlowClaude/` with explicit URLs and `cloudKitDatabase: .none`. Live dictation always saves to real history.
- The dictation session lifecycle lives in `DictationCoordinator` (idle → starting → recording → finalizing → idle). Every session has a UUID, and results from cancelled or old sessions are dropped. It depends on two protocols, `DictationEngine` and `TextInserting`, which the tests fake.
- Background grouping lives in `AnalysisCoordinator`: per-dataset consent, one request at a time for the whole app, a 10 s idle debounce, batches of 20, 4,096 output tokens, and a daily budget of 100 requests / 500k tokens (`AnalysisLimits`). Failures pause until Retry; nothing is retried automatically. Before saving it rechecks the authorization epoch, consent, the key, and the dataset. `HistoryStore.applyBatch` rechecks the deletion generation and that the sources still exist, and saves atomically with rollback.
- Grouping requests send only pending transcripts plus existing group definitions, as JSON inside `<data>` with short keys (`t1`, `g1`, `n1`). Replies are fully validated before anything is saved (`GroupingPrompt.validate`). Counts are always computed locally from memberships.

## Identity and coexistence rules (from the plan)

| | GrebFlowClaude | GrebFlowSol | GrebFlowArgon |
| --- | --- | --- | --- |
| Key | right Option (61) | right Command (54) | right Shift (60) |
| Bundle ID | `com.grebban.GrebFlowClaude` | `com.grebban.GrebFlowSol` | `com.grebban.GrebFlowArgon` |
| Badge | C | S | A |

- Keychain service and `os.Logger` subsystem are both `com.grebban.GrebFlowClaude`. Use standard UserDefaults, no shared suite.
- The event tap passes every event through. The only exception is Escape while starting or recording (`coordinator.isRecording`).
- Synthetic events are ignored when `eventSourceUnixProcessID != 0` or `eventSourceStateID != 1` (HID system state). That covers our own paste and the other variants' pastes.
- Any other key or modifier going down during the hold cancels the session silently. Right Option still types special characters on Swedish layouts.
- Paste waits up to 2 s for every physical modifier (Command, Option, Shift, Control, Fn) to be released, otherwise it falls back to copy-only. It writes the pasteboard, checks `changeCount` again right before posting, and skips the paste if another app wrote in between. Every paste ends with exactly one trailing space. History stores the recognized text without it.
- The paste sequence is: left Command down (flagsChanged), V down, V up, left Command up (empty flags), all from one private `CGEventSource`, posted to `.cghidEventTap`. Never send Return.

## Learnings and gotchas

Things that cost time in the first session:

- **Tests run without a host app.** `xcodebuild test` with `TEST_HOST` failed from the CLI: `IDELaunchServicesLauncher` asserted `childPID > 0` and left stuck host processes. The test target now links `GrebFlowClaude.debug.dylib` directly (`OTHER_LDFLAGS` and `LD_RUNPATH_SEARCH_PATHS` in the pbxproj) and runs inside `xctest`. That only works for Debug builds, since the debug dylib only exists there. Don't put `TEST_HOST` back.
- **Load bundle resources with `Bundle(for: BundleToken.self)`, not `Bundle.main`.** In tests `Bundle.main` is xctest. `BundleToken` lives in `GroupingPrompt.swift`.
- **SourceKit shows false "Cannot find type X in scope" errors across files** in this project. Trust `xcodebuild`, not the editor diagnostics.
- **Input Monitoring needs `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`.** Without that call the app never appears in the System Settings list, so the user has nothing to switch on. `CGRequestListenEventAccess` alone wasn't enough. Each permission has one "Grant access" button: request first, then open the pane if access still isn't granted.
- **A permission granted while the app runs often only takes effect after a relaunch.** `SetupSnapshot.relaunchRecommended` turns on when a keyboard permission flips to granted during this run, and Settings then shows a "Quit and reopen" bar (`AppModel.relaunch()`).
- **An active tap works with Accessibility alone,** so a running tap counts as keyboard access even if the Input Monitoring preflight says no.
- **Quitting via AppleScript (`tell application id ... to quit`) is silently ignored.** `run.sh` uses `pkill -f` on the exact installed path instead. Only stop processes this project launched. The permission classifier blocks killing other PIDs, and the sibling variants' apps must keep running.
- **AVAudioConverter holds back about 15 ms of audio** when resampling. `AudioPipeline.close()` flushes it with `.endOfStream`, otherwise the last word gets clipped. A test covers this.
- **A finalized `SpeechAnalyzer` can't be reused.** The preparation task stores its result itself, and `start` takes ownership only if the identity matches. This fixed a race where a used analyzer was put back.
- **Release detection falls back to the generic modifier flag** when a keyboard doesn't report device-dependent bits (`ShortcutInterpreter.isRightKeyDown`). The hardware release poller uses the same function.
- **The audio tap closure comes from a `nonisolated` factory** (`AudioTapFactory.makeTap`) so it never inherits main-actor isolation. Main-actor handoffs use `Task { @MainActor in }`. Don't paper over isolation errors with `@unchecked` UI access or detached tasks.
- **The menu bar icon can hide behind the notch.** `--dashboard` opens the window at launch, and `DashboardWindowController.show` uses `orderFrontRegardless()` because accessory apps can't always activate themselves.
- **Accessory apps need an Edit menu,** or Command-V doesn't work in dashboard text fields. `AppDelegate.makeMainMenu()` provides one.
- **Screen capture and System Events scripting aren't authorized from the CLI session,** so UI state can't be checked from here. Ask the user what they see.

## Anthropic API decisions

- Raw `URLSession`, with `anthropic-version: 2023-06-01` (the plan's choice) and `x-api-key`.
- Default model: `claude-haiku-5-5`. Requests to Haiku models send `thinking: {"type": "disabled"}` to keep cost down. No `fallbacks` parameter, since the plan forbids silently switching models. No temperature or tools.
- The Models API (`GET /v1/models/{id}`, which reports `max_input_tokens` and `max_tokens`) validates access and context size. A 404 pauses grouping with a message and never tries another model.
- Branch on `stop_reason`: `refusal` and `max_tokens` are errors. After a truncated reply, Retry sends half the batch.

## Testing approach

- Swift Testing (`import Testing`). More than 100 tests, about 1 s total. Run them three times after async changes to catch flakiness.
- Fakes in `TestSupport.swift`: `FakeEngine`, `FakeInserter`, `FakePermissions`, `FakeSpeechAssets`, `FakePasteEnvironment`, `InMemorySecretStore`, and `MockURLProtocol`, which routes by a per-session header so parallel tests don't clash.
- In-memory stores get unique names (`HistoryStore.inMemory`) so parallel tests don't share data.
- The plan wants automated checks and manual Mac checks reported separately. Never claim cross-app paste or permission behavior works without the user confirming it.

## Working conventions

- Write prose (comments, docs, commit messages) in a plain, direct voice, per the user's global `unslop` rule. Comments explain why, not what.
- Commits: this repo is under `~/code/grebban/`, so use the `grebban-commit` skill. It checks that the active GitHub account is `DanielDanielssonGrebban` and asks the user to approve the commit plan. Only commit or push when asked.
- Keep everything inside `GrebFlowClaude/`. Don't touch the root README or the other variants' folders.

## Leftovers from the first session

- An older build used bundle ID `com.grebban.grebflow.claude`. Its data folder (`~/Library/Application Support/com.grebban.grebflow.claude/`), Keychain item, and permission entries are still there. Ask the user before deleting them.
