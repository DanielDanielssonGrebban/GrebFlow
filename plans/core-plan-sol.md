# GrebFlowSol V1 core plan

## Version 1 decisions

| Area | Version 1 decision |
| --- | --- |
| Name | GrebFlowSol for the project, app, and code identifiers. |
| Parallel builds | One of three builds of the same plan. GrebFlowSol runs on the same Mac at the same time as GrebFlowClaude and GrebFlowArgon, with its own name, bundle ID, shortcut, storage, Keychain item, and permissions. See [Running alongside the other variants](#running-alongside-the-other-variants). |
| Platform | Native macOS app written in Swift. Demo runs on the user's Mac. |
| App entry point | Persistent menu bar icon and menu. Dashboard opens in a native window. |
| Shortcut | Hold right Command to record. Release to finish and paste. Allow changing the shortcut in Settings. |
| Recording feedback | Menu bar icon only. Respond to microphone activity and distinguish recording from processing. No floating overlay. |
| Insertion | Put plain text on the clipboard and simulate paste. Keep the destination app focused. Every pasted transcript ends with exactly one space so consecutive dictations flow together. |
| Terminal behavior | Single-line text, no embedded line breaks, no automatic Enter, no command generation or execution. |
| Transcription | Start with Apple's on-device English transcription. Recognize while the user speaks. |
| Performance | Aim for text within one second after release. Faster is better. Longer latency does not make the hackathon a failure. |
| Audio | Process transient microphone audio. Do not save recordings. |
| History | Save transcripts and small amounts of metadata in a local database. No hosted database or sync. |
| Retention | Keep history until the user clicks Delete all history. Rolling 7/30-day retention is in the [V2 plan](v2-plan.md). |
| AI | Anthropic with a low-cost Claude Haiku-family model by default. API key field in Settings, key stored in macOS Keychain. Never silently upgrade to a more expensive model. |
| Usage | An always-available Usage tab shows repeated phrases and sentences, plus AI groups of related meaning even when wording differs. No Generate report action is required. |
| Analysis trigger | After explicit opt-in, analyze pending transcripts automatically in background batches while the app runs. Dictation never waits for analysis. |
| Analysis input | Send only pending transcripts and existing group definitions from the same dataset. Cache results locally rather than repeatedly uploading all history. |
| Analysis instructions | Bundled, versioned grouping instructions and a validated JSON response. Editable report skills, additional report context, long-form reports, and skill or automation suggestions are V2. |
| Sample data | Optional, clearly labeled sample history, separate from real history. |
| Login | Provide a Launch at login setting. |
| Distribution | Outside V1. See the [V2 plan](v2-plan.md). |

## Product and demo goal

Build GrebFlowSol for a one-day company hackathon. It is a native macOS menu bar dictation app for developers. The user holds right Command, speaks an English prompt, releases the key, and gets plain text pasted into the focused input. Terminal and AI coding CLI input are first-class destinations.

The differentiator is an automatically updated overview of what the user repeatedly says in developer prompts. The Usage tab combines local statistics with AI groups of related phrases, sentences, and requests. Group by meaning rather than keyword overlap alone. Requests to "use conventional commits" and "include a commit subject and body" can appear under Commit preparation even though their wording differs.

These groups describe requests found in dictation, not proof that the user completed the requested work. Counts and source references come from local records. The app does not generate skills, suggest automations, or execute anything in V1.

The demo must show live dictation, local history, immediate local statistics, and genuine AI grouping that updates automatically after opt-in. Show differently phrased requests grouped together with their source dictations, without generating a report. Provide sample history because one day of real usage may not contain enough repetition.

## Version 1 boundaries

Build the recording and paste loop, menu bar states, local history, simple statistics, repeated phrase and sentence counts, background AI grouping by meaning, the Usage tab, Delete all history, API key and analysis settings, login setting, and separate demo data.

Defer long-form reports, editable report skills, per-report context, generation of skills or reusable prompts, automation recommendations, automatic output muting, automatic bilingual recognition, filler-word rewriting, cloud transcription, saved audio, code or shell-command generation, email or scheduled report delivery, multi-provider AI support, accounts, hosted services, cross-device synchronization, custom vocabulary management, app exclusions, and distribution. Normal recognizer punctuation is fine. Do not add an LLM cleanup step before paste.

Complete V1 before considering the optional features in the [V2 plan](v2-plan.md).

Support broad paste compatibility without claiming every application or field will accept it. Prove it in Terminal, the user's preferred terminal emulator if installed, an AI coding CLI, an editor, a browser text area, and a standard native text field.

## Menu and dashboard

Menu items:

- Current state and setup problem, if any.
- Hold right Command to dictate.
- Open dashboard.
- Copy latest transcript when available.
- Settings.
- Quit.

Icon states: idle microphone, audio-reactive recording icon, distinct processing animation, and setup/error indicator. Distinguish states by shape or movement as well as color. Do not open windows automatically during dictation.

The dashboard can use a simple sidebar or tabs:

- Overview: transcript count, dictated words, recording duration, words per minute, daily usage, and frequent non-stop-words.
- Usage: frequent phrases and sentences, semantic groups ranked by distinct source dictation count, representative excerpts, and access to the original dictations. Show the real or sample dataset, analyzed versus pending counts, last successful analysis time, and paused/error states. No Generate report button.
- History: timestamp, transcript, duration, and Copy. Detailed search and editing can wait.
- Settings: API key, low-cost model ID, automatic grouping consent and pause control, shortcut, Launch at login, setup status, demo mode, and Delete all history.

Statistics should come from local code and update as soon as a transcript is saved. Word frequency excludes common English stop words while retaining developer terms. Count recurring multiword phrases and sentences using documented, deterministic whitespace and case normalization. Do not ask AI to calculate frequencies. Clearly label words per minute as dictated words divided by recording duration. Do not invent typing-time savings without an agreed baseline.

Semantic groups are AI classifications, not exact phrase matches. Show each group's distinct source dictation count and real excerpts. One dictation may contain several intents and belong to several groups, so group counts must not be presented as mutually exclusive totals. Do not force unrelated or uncertain content into a group. Keep local statistics visible without an API key or connection; cached groups remain visible with their actual analysis time and coverage.

Keep Launch at login off until enabled. Use SMAppService.mainApp and show its real registration/approval state. Test from a stable app bundle location; user or system approval may be needed. [Apple's login item API](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)

## Target environment

Target macOS 26 and Apple silicon for the proof of concept. The development machine runs macOS 26.6.2 and has Xcode at /Applications/Xcode.app with Swift 6.2 and a macOS 26 SDK. Confirm the installed versions before implementation. Do not accidentally use macOS 27-only APIs from the latest online documentation.

Check English locale availability through SpeechTranscriber.supportedLocales and verify that the installed SDK includes progressive transcription presets, prepareToAnalyze, and explicit finalization methods. Keep Swedish support outside version 1; evaluate DictationTranscriber locales and assets separately for that later feature.

## Technical approach

The choices below are implementation defaults. Prefer simple implementations within the agreed scope.

| Need | Initial implementation |
| --- | --- |
| App and dashboard | SwiftUI with AppKit integration for status icon and window behavior. One macOS Xcode app target. |
| Menu bar | NSStatusItem with an NSMenu and a small custom icon drawing microphone level. This offers direct control over icon updates. |
| App lifecycle | LSUIElement enabled. No ordinary main window at launch. Opening the dashboard explicitly activates it. Closing it leaves dictation available. |
| Shortcut | Quartz event tap, handling flagsChanged and the physical right Command key independently of left Command. |
| Microphone | AVAudioEngine with an input tap. No audio-file output. |
| Speech | SpeechAnalyzer plus SpeechTranscriber, initially en-US and timeIndexedProgressiveTranscription. |
| Text insertion | NSPasteboard.general and synthetic Command-V through CGEvent. |
| Persistence | SwiftData with explicit store URLs under ~/Library/Application Support/com.grebban.GrebFlowSol/. Never rely on the default store location. Explicitly disable CloudKit integration. |
| API | A small URLSession client for Anthropic Messages. No third-party SDK needed. |
| Semantic grouping | A serial background batch coordinator, a bundled grouping prompt, validated JSON assignments, and locally cached groups linked to source transcripts. Start with a low-cost Haiku-family model. |
| Secrets | Security framework Keychain generic-password item with service `com.grebban.GrebFlowSol`. |
| Preferences | UserDefaults or AppStorage for non-secret settings. |
| Login | SMAppService.mainApp registration and actual service status. |
| Local usage counts | NaturalLanguage tokenization, deterministic phrase and sentence counting, and a small checked-in English stop-word list. |

Use a directly run local app bundle with stable identity and development signing where available. Use a non-App-Store, unsandboxed target for the POC's global input integration. Reassess sandboxing and distribution later.

Apple documents both SwiftUI MenuBarExtra and the LSUIElement behavior, but AppKit's status item is the implementation default here because the icon itself must animate. [Menu bar documentation](https://developer.apple.com/documentation/swiftui/menubarextra)

### Keep the code small

Use GrebFlowSol consistently throughout the project: GrebFlowSol.xcodeproj, the GrebFlowSol app target, scheme and Swift module, GrebFlowSolApp as the app entry point, and GrebFlowSol.app as the built product. Name the test target GrebFlowSolTests and use GrebFlowSol in window titles and menu labels. Use the bundle identifier `com.grebban.GrebFlowSol`.

Suggested folders and responsibilities, not a mandatory file count:

```text
GrebFlowSol/
  App/                 app entry point, service wiring, dashboard window
  Dictation/           session coordinator, shortcut, audio, speech, paste
  Storage/             models, local repository, history deletion, demo seeding
  Analysis/            batch coordinator, Anthropic client, grouping prompt
  Settings/            preferences, Keychain, permissions, login item
  UI/                  status item, dashboard views
GrebFlowSolTests/
  session lifecycle, transcript assembly, paste normalization,
  history deletion, grouping input and assignments, Anthropic responses
```

Keep one coordinator responsible for each recording session. Views display state and issue actions. Audio callbacks and the event tap do minimal work and hand off to the appropriate worker. Run storage and analysis preparation away from the audio callback. Use Swift concurrency isolation deliberately rather than adding detached tasks to silence compiler warnings.

Use small replaceable interfaces for speech, key events, paste, storage, and the API where they enable meaningful tests. Avoid a generalized plugin framework. Apply the audio callback and event-sequence rules in [Implementation requirements](#implementation-requirements) before the first live test.

### Keep presentation replaceable

Build the core so a later design plan can replace the dashboard's layout, navigation, and visual components without rewriting dictation, paste, persistence, statistics, or grouping services. Keep layout, colors, typography, and view composition in the presentation code. App wiring creates and owns services independently of individual views.

Views display state and dispatch actions through observable presentation models or controllers. They must not manage microphone sessions, write directly to SwiftData, prepare analysis requests, or calculate usage statistics during rendering. Compute statistics and analysis inputs outside views, respecting storage and concurrency isolation. Core services must not depend on dashboard views, navigation choices, or visual styling. Closing the dashboard must not stop enabled background analysis.

Use the small interfaces already justified by core tests. Do not introduce a plugin framework, generic view-model hierarchy, or full design system for a redesign that has not been specified.

Acceptance: replacing the dashboard's layout and visual components requires no changes to dictation, paste, storage, statistics, or grouping behavior. Core tests run without opening the dashboard and remain unchanged for a presentation-only redesign.

## Running alongside the other variants

This plan is one of three copies handed to different builders. The user runs all three apps on one Mac at the same time and compares them. This copy builds GrebFlowSol. Nothing in GrebFlowSol may break, intercept, or read data from the other two.

| | GrebFlowClaude | GrebFlowSol | GrebFlowArgon |
| --- | --- | --- | --- |
| Dictation key | right Option (key code 61) | right Command (key code 54) | right Shift (key code 60) |
| Bundle ID | `com.grebban.GrebFlowClaude` | `com.grebban.GrebFlowSol` | `com.grebban.GrebFlowArgon` |
| Menu bar badge | C | S | A |
| Project folder | `GrebFlowClaude/` | `GrebFlowSol/` | `GrebFlowArgon/` |

### Identity and files

Keep all code in a top-level `GrebFlowSol/` folder. Do not read or change the other variants' folders. Use only the identifiers in the GrebFlowSol column. macOS stores microphone, Input Monitoring, and Accessibility grants per bundle ID and signature, so GrebFlowSol needs its own grants even when another variant already has them.

Unsandboxed apps share ~/Library/Application Support, and SwiftData's default store file lands directly in it. Give both the real and the demo store explicit URLs inside `com.grebban.GrebFlowSol/`. Use standard UserDefaults (scoped by bundle ID) and no shared suite. Use `com.grebban.GrebFlowSol` as the Keychain service name and the os.Logger subsystem. The user may paste the same Anthropic key into all three apps; each stores its own copy.

### Shortcut and event tap

GrebFlowSol listens to right Command only. The other variants use right Option (GrebFlowClaude) and right Shift (GrebFlowArgon). All three event taps see every event, so:

- Pass every event through unchanged. The one exception is Escape while GrebFlowSol itself is recording, which it may consume to cancel. Never consume the shortcut key, other modifiers, or Escape when idle.
- Match the shortcut by key code on flagsChanged. Ignore synthetic events, meaning those whose source process ID is nonzero or whose source state is not the HID system state. The other variants post left Command (key code 55) and V while pasting, and GrebFlowSol must not react to them.
- If any other key or modifier goes down while right Command is held, cancel the session silently and let the key through. Right Command also takes part in normal typing and shortcuts. The same rule stops two variants from recording at once when the user holds two right-hand modifiers.
- The Settings shortcut picker may offer other keys, but keep right Command as the default and warn when the user picks a key another variant uses by default.

### Paste and clipboard

The clipboard is shared by all three apps. Before posting Command-V, require every physical modifier (Command, Option, Shift, Control, Fn) to be released, not only right Command. Otherwise a key held for another variant turns the paste into a different shortcut. Wait up to two seconds for release, then fall back to copyOnly with a recorded reason.

Record NSPasteboard.general.changeCount right after writing. Check it again immediately before posting the paste events. If it changed, another app wrote to the clipboard in between, so skip the paste and mark the outcome copyOnly. Delete all history clears the clipboard only when the count still matches GrebFlowSol's own write.

### Microphone, speech, and menu bar

Several apps can capture the default input at once. Do not enable voice processing on the input node or change the system input device, sample rate, or volume, since that affects the other variants. Speech assets are installed system-wide, but GrebFlowSol still runs its own asset check and locale reservation.

Three microphone icons will sit next to each other in the menu bar. Draw the badge letter "S" into every icon state so the user can see which app is recording. Put GrebFlowSol in the status item tooltip and at the top of the menu.

### Analysis

Budgets and queues are per app. The three apps may share one API key and its rate limit, so a rate-limit response pauses the queue and offers Retry as described in [Batching and cost control](#batching-and-cost-control). It never triggers an automatic retry.

## Implementation requirements

Implement the following requirements as part of the core dictation loop. A successful build or a Ready label alone does not prove live dictation works.

### Permission setup must include restart and recheck

Run the signed app bundle from one stable path with the same bundle identifier and signing identity. Request microphone, keyboard monitoring, and paste/Accessibility access through separate explicit setup actions. Download the English speech assets through their setup action.

After the user enables Input Monitoring or Accessibility, refresh the capability checks. If they still report missing access, quit GrebFlowSol completely and reopen the same built app bundle. A permission checkbox may not take effect in the already-running process. Recheck capabilities after relaunch before considering a rebuild or permission reset.

After relaunch, check microphone authorization, event-listening access, event-posting access, Accessibility trust, actual event-tap installation, and a prepared English recognizer before showing Ready. A model download and a permission grant must never start a recording. Require a fresh physical shortcut press. Keep setup and history usable while dictation is unavailable.

### Audio callbacks must run outside the main actor

AVAudioEngine invokes its input tap on an audio queue. An unannotated tap closure created inside an `@MainActor` method can inherit main-actor isolation. Do not pass such a callback to the audio engine. The callback must be safe to invoke on the audio queue as soon as the first buffer arrives.

Create the tap through an explicitly `nonisolated` factory whose input and output callback type is `@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void`. Pass that callback directly to `installTap`. It must capture only thread-safe audio helpers, never views or main-actor model state. Copy each borrowed audio buffer before handing it to the serial conversion queue. Protect first-buffer bookkeeping with a lock. Send amplitude, timing, and error updates back through `Task { @MainActor in ... }`.

Audio configuration notifications must also reach the main actor before changing session or UI state. Use a main-queue observer with an explicitly Sendable closure and an explicit main-actor handoff. Do not hide an isolation error with unchecked access to UI state or detached tasks.

Add a test that constructs the production tap from the main actor, invokes it on a background queue with a synthetic buffer, and verifies delivery off the main thread without a trap. This test must not request microphone access. Keep the callback factory separate from microphone capture so the test exercises the same callback used by the app.

### Every paste must release its synthetic modifiers

Keep the destination focused and leave synthetic modifier state neutral after each paste. Consecutive hold, release, and paste cycles must work without clicking the destination again.

Use one private CGEventSource for the complete sequence. Before posting, check physical modifier state with `CGEventSource.flagsState(.hidSystemState)`. Do not use combined synthetic state to decide whether the user still holds the shortcut or Command. Wait for actual shortcut release, retain the destination checks, and leave its focus alone.

Post these events in order through the HID event tap:

| Event | Virtual key | Event type | Flags |
| --- | --- | --- | --- |
| Left Command down | 55 | flagsChanged | maskCommand |
| V down | 9 | keyDown | maskCommand |
| V up | 9 | keyUp | maskCommand |
| Left Command up | 55 | flagsChanged | empty |

Set `source.localEventsSuppressionInterval = 0`. Allow local keyboard, mouse, and system-defined events in the source filters for both suppression-interval and remote-mouse-drag states. Preserve physical modifier guards. Never emit Return or carry Option, Shift, or Control into this sequence. Never activate the destination, restore focus with a mouse click, or automatically retry a paste as a workaround.

Test the actual event factory. Assert event order, key codes, event types, neutral final flags, zero suppression interval, and allowed local keyboard input. Repeat sequence construction several times and verify each sequence independently balances Command and contains no Return, Option, Shift, or Control events. These tests must inspect events from the production factory without posting into another app.

### Verify the menu bar app stays alive during recording

Retain the status controller and NSStatusItem for the app lifetime. Normal launch has a menu bar icon and no Dock icon. Provide explicit ways to open Settings and the dashboard, and leave dictation running when the dashboard closes. Keep the idle, recording, processing, and setup/error icon states distinct.

If the icon disappears, first check whether the GrebFlowSol process exited and inspect its crash report. An app crash also removes its menu bar item. Diagnose process termination separately from status-item creation or visibility. After correcting a crash, rebuild with the same identity, verify the signature, relaunch, and test capture again.

If the recording indicator responds but no text appears, check whether history contains the phrase and whether its outcome is copyOnly. Recognition may already be working. Inspect the reported paste-skip reason and physical modifier state before changing the speech engine or adding focus restoration. Log predefined failure reasons and timing metadata only, never transcript text, field contents, unrelated keyboard input, or API keys.

The core loop must pass the callback and paste tests, survive real microphone capture, and complete consecutive dictations without another click. If a UI automation tool cannot hold a modifier key alone, use a physical user test and record its result separately from automated checks.

## Permissions and first-run setup

Microphone access requires the user's macOS approval even though GrebFlowSol processes audio locally and does not save recordings. Unsandboxed operation does not bypass this permission.

### Build configuration

- Add NSMicrophoneUsageDescription to the app's built Info.plist, including when Xcode generates that file. Use: "GrebFlowSol uses your microphone while you hold the dictation shortcut to turn speech into text. Audio is processed on your Mac and is not saved."
- If Hardened Runtime is enabled, enable Audio Input in Signing & Capabilities, setting com.apple.security.device.audio-input to true in the signed app's entitlements. This capability does not grant user consent. Keep App Sandbox disabled as specified above.
- Run GrebFlowSol.app with a stable bundle identifier, signing identity, and location during development and rehearsal. Verify permission attribution belongs to GrebFlowSol rather than a command-line test tool. Changing app identity may require approval again.

Apple requires a microphone usage description and documents the audio-input capability separately from user authorization. [Microphone usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription), [Audio Input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)

### Microphone authorization flow

1. Read AVCaptureDevice.authorizationStatus(for: .audio) before installing the input tap or starting capture. Surface the result in Settings and the menu's setup status.
2. For notDetermined, show an Enable microphone action in Settings. On that action, call AVCaptureDevice.requestAccess(for: .audio) and await the result. macOS presents the approval dialog. GrebFlowSol cannot enable this permission itself.
3. For authorized, allow recording once the other dictation prerequisites are ready. Approval must not start a recording automatically; require a fresh shortcut press.
4. For denied, keep recording disabled and offer Open System Settings with instructions to enable GrebFlowSol under System Settings > Privacy & Security > Microphone. Do not repeatedly request access because the original dialog will not reappear. Use a pane-opening URL only if verified on the target macOS version; always retain the written navigation path.
5. For restricted, explain that a system or organization policy blocks access. Do not repeatedly prompt or attempt a workaround. History and Usage remain usable.
6. Recheck on app activation, returning from System Settings, and before every recording. On loss of access or capture failure, stop capture, discard the unfinished session, and expose the actionable setup state. If macOS requires relaunch after a permission change, make that explicit.

Permission setup must finish before normal dictation use so no approval dialog interrupts the hold-to-talk path. An unconfigured shortcut press may show a setup-needed icon/menu state, but must not queue a recording to start later. [Apple's media authorization flow](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media), [authorization status](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:))

### Other permissions

After permission changes, follow the restart and recheck procedure in [Implementation requirements](#implementation-requirements). Reopen the same signed bundle and verify actual capabilities rather than relying on the System Settings checkbox alone.

Microphone approval does not authorize keyboard observation or synthetic paste. Check the actual event-listening and event-posting capabilities with CGPreflightListenEventAccess and CGPreflightPostEventAccess. Use the corresponding request APIs from explicit setup actions, and expose Input Monitoring or Accessibility guidance only where needed by the chosen event-tap implementation. If focused-element checks use Accessibility APIs, also check AXIsProcessTrustedWithOptions. Verify the actual combination on the demo Mac instead of treating permission to one capability as permission to all of them.

SpeechAnalyzer's on-device transcriber modules do not need the separate SFSpeechRecognizer speech-recognition authorization flow. Do not request that additional permission for the planned engine. If a later implementation introduces SFSpeechRecognizer, revisit its authorization and NSSpeechRecognitionUsageDescription requirements. Speech-model downloads remain a separate setup prerequisite. [Apple's speech permission distinction](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)

## Dictation lifecycle

The primary state path is idle, starting, recording, finalizing, paste attempted, then idle. Missing setup produces a needs-setup state. Cancellation and errors must always stop capture and release session resources.

1. At launch, inspect microphone permission, shortcut event access, event-posting access, and English model availability using the setup flow above. Never start microphone capture before authorization. Download missing speech assets through an explicit setup action. Prepare the recognizer before advertising Ready.
2. Right Command down creates a unique session ID and remembers the destination application's process ID. If accessible, also remember the focused input element without reading its contents. Do not activate this app.
3. Start microphone capture. If release arrives during startup, remember it so delayed startup cannot leave the microphone recording.
4. Feed audio buffers into the analyzer continuously. Convert sample rate and channel format to the format the analyzer accepts. Derive icon amplitude from the same buffers and throttle UI updates to roughly 10 per second.
5. Assemble provisional and finalized recognition results by their audio ranges. Provisional results replace provisional text; they are not appended repeatedly. Only one final assembled transcript is committed.
6. On release, stop accepting new microphone input, hand off already captured buffers, terminate the input sequence, and explicitly finalize the analyzer. For analysis started with start, use finalizeAndFinishThroughEndOfInput after the stream ends. Ending an AsyncStream alone is insufficient.
7. Await the remaining results and construct one final transcript. Normalize it to safe single-line paste text.
8. Queue local persistence and attempt clipboard paste promptly. Persistence and analytics must not block input delivery. If saving fails, keep dictation usable and expose a storage error.
9. Release audio buffers and session tasks. Prepare a new analyzer for the next session. A finalized analyzer cannot simply accept another recording.

Use prepareToAnalyze to reduce model startup work. Consider the model-retention option after correctness is established. Keep the microphone stopped when idle; preparation must not become continuous background recording. [SpeechAnalyzer lifecycle](https://developer.apple.com/documentation/speech/speechanalyzer), [live transcription preset](https://developer.apple.com/documentation/speech/speechtranscriber/preset/timeindexedprogressivetranscription)

### Shortcut and cancellation details

- Right Command and left Command must be distinct. Generic Command flags alone are insufficient when both keys can be held. Identify the shortcut by virtual key code 54 on flagsChanged events.
- Detect right Command without consuming it. Handle the relevant physical key transitions without disturbing unrelated keyboard events or leaving modifier state stuck. See [Running alongside the other variants](#running-alongside-the-other-variants) for event tap rules.
- Wait for physical shortcut release and check hardware modifier flags through .hidSystemState before posting Command-V. Use the full Command down, V down, V up, Command up sequence specified above. End with empty flags. Never post Option-Command-V, Shift-Command-V, or Control-Command-V accidentally.
- Escape cancels an active recording. Cancellation discards that session's text and audio without clipboard changes or persistence.
- Ignore a new recording gesture while finalization is active; show the processing icon. Do not overlap sessions in version 1.
- Use session IDs to prevent results from a cancelled or old session being pasted later.
- Stop capture on sleep, device loss, quit, and permission failure. Handle disabled event taps without leaving input intercepted.
- Add a five-minute internal recording watchdog. If release was lost, stop capture and retain any completed text only for manual recovery; do not auto-paste on watchdog expiry.
- Configurable shortcut can initially mean a small picker of supported hold keys or chords. A full shortcut-recorder control is unnecessary for the demo.

### Clipboard and terminal behavior

Use the balanced event sequence in [Implementation requirements](#implementation-requirements). Consecutive recordings must paste into the same focused input without a mouse click between them. A focus-restoring click is not an acceptable fix.

Leave the latest dictated text on the clipboard. Do not implement clipboard restoration in version 1; a destination may consume paste asynchronously.

Before paste, collapse CR, LF, Unicode line/paragraph separators, tabs, and control characters into spaces. Preserve readable punctuation and Unicode text. Test this with shell metacharacters and transcripts containing code-like words. Do not append Return, generate shell syntax, or run a subprocess.

End every pasted transcript with exactly one trailing space, so a second dictation started right after the first continues the sentence instead of running into the previous word. Trim leading and trailing whitespace after normalization, then append the single space. Never paste a lone space for an empty transcript. The space belongs to the insertion text only: history keeps the recognized text without it, and Copy latest transcript copies the insertion text with the space.

Check the destination before injecting the paste. If the foreground application changed since keydown, keep the text available for manual copy and show a menu error instead of activating an old app. If a captured focused element can be compared reliably, reject a changed field as well. This is a best-effort protection, not a universal way to prove cursor identity across apps.

Treat event posting as a paste attempt. The OS does not provide a generic acknowledgment that a third-party field accepted the text. Persist pasteAttempted or copyOnly, not an unverified insertedSuccessfully claim. Do not automatically retry a paste that could duplicate text.

When there is no editable destination, retain the transcript in history and allow Copy. Empty or cancelled recordings must not replace the clipboard. Where secure-input state can be detected with public APIs, disable dictation there; do not bypass it.

The shared macOS clipboard can participate in Universal Clipboard and can be read by clipboard utilities. Do not describe it as app-private storage. [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard)

## Storage and history deletion

Use one real SwiftData store and a distinct demo store. No iCloud capability, remote database client, audio files, or cross-device history sync. Automatic transcript uploads are limited to explicitly enabled AI grouping for that dataset.

Transcript fields:

- id, startedAt, endedAt, durationSeconds, locale.
- Final recognized text and normalized insertion text, if different.
- Word count and optional destination application bundle ID. Do not store window titles, surrounding text, or unrelated keyboard input.
- Release-to-final and release-to-paste-event durations.
- Outcome such as pasteAttempted or copyOnly.

Store successful nonempty transcripts once. Cancelled and empty sessions need no content record. Keep recoverable recognition failures visible without claiming incomplete text is final.

Grouping data:

- Group ID, short label, concise description of the shared intent, and creation/update timestamps.
- Memberships linking a group to a source transcript ID and exact supporting excerpts. Do not duplicate entire transcripts in group summaries.
- Per-transcript analysis state, analyzedAt, model ID, and prompt version. A completed analysis may legitimately assign no groups.
- Batch metadata with source IDs, completion time, model ID, prompt version, input/output token usage if returned, and a snapshot of the dataset's deletion generation.

Keep group IDs stable across batches. Store each group/transcript membership once, even if several excerpts support it. Compute group counts from unique source IDs, never from model-supplied totals. Commit validated memberships and completion state together so a failed save does not lose pending work.

History and cached grouping stay until the user deletes them. Group dashboard days using local calendar time.

Delete all history clears both real and sample transcripts, groups, memberships, and analysis progress. Cancel queued and in-flight analysis, invalidate cached statistics, clear displayed excerpts, and clear this app's latest clipboard content only if clipboard ownership has not changed. Do not overwrite clipboard data copied by another app. Leave the API key and preferences alone; provide a separate Remove API key action.

Derived groups must not preserve deleted source content. Remove memberships when sources are deleted and remove groups that have no remaining sources. Before saving a network response, recheck source existence, dataset identity, deletion generation, and whether the request is still authorized. Late responses must not recreate deleted content.

Normal row deletion is application-level deletion, not a guarantee of forensic erasure from SQLite files, OS backups, or already-sent API requests. Do not promise secure erasure or custom encryption in this POC.

## Background AI grouping

Use direct HTTPS from this user's desktop app to Anthropic with their own API key. No hosted proxy and no embedded shared credential. This is a personal-key prototype, not a backend design for distributing a company-funded secret.

Settings uses a secure input field with Save, Replace, Remove, and connection status. Never print the key, persist it in UserDefaults, or include it in fixtures, crash logs, or Git. Clear the input after saving. A connection test can query model availability without sending history.

Use POST https://api.anthropic.com/v1/messages with x-api-key, anthropic-version: 2023-06-01, Content-Type: application/json, a model, bounded max_tokens, a system prompt, and a user message. x-api-key remains supported in the current official authentication docs. Confirm the API contract again at build time. [API overview](https://platform.claude.com/docs/en/api/overview), [authentication](https://platform.claude.com/docs/en/manage-claude/authentication)

### Low-cost model and consent

Default to an available Claude Haiku-family model suitable for short semantic classifications. Confirm the exact model ID, current pricing, supported request format, and account access against Anthropic's official catalog during implementation. Do not carry over the previous Sonnet default or invent a future Haiku model identifier. Make the model ID editable and validate access using the Models API. A more expensive model requires explicit user choice; never silently escalate or substitute providers. Avoid additional thinking modes or other cost-increasing options by default. [Model catalog](https://platform.claude.com/docs/en/models/overview)

Automatic grouping is off until the user opts in. Explain that enabling it sends existing unprocessed and future transcripts to Anthropic in batches using their API key, incurs API charges, and continues while GrebFlowSol runs even when the dashboard is closed. This is cloud analysis of text, not on-device transcription or a hosted history database.

Consent is dataset-specific. Enabling real-history grouping does not authorize sample analysis, and switching datasets does not enable uploads. Provide an explicit Enable sample analysis action for the demo dataset. Once enabled, normal analysis requires no Generate report action or confirmation for each batch.

Disabling grouping or removing the key stops new requests, cancels in-flight work, and rejects late results from that authorization. Keep cached groups visible with an honest paused state. Cancellation cannot recall data already sent. Dictation, local counts, history, and cached groups remain usable without an API key or internet connection after speech assets are installed.

### Batching and cost control

Use one asynchronous non-streaming request at a time for the app. Debounce new work until dictation is idle rather than sending a request for every utterance. Do not start a batch during capture or finalization. Network waits and input preparation must never block the main thread or delay recording and paste.

Analyze pending transcripts in bounded batches, including any backlog after opt-in. Choose conservative batch sizes, an idle debounce, a bounded output allowance, and a per-day request or token budget during implementation. Document their initial values. When the budget is reached, pause with a visible status until the budget resets; do not silently bypass it or switch models. Track actual token usage where returned, but do not claim an exact monetary cost without verified pricing.

Send only unprocessed transcripts from one dataset, along with existing group IDs, labels, and concise definitions from that dataset. Do not resend the whole history or all earlier excerpts to classify a new batch. Use existing definitions to reuse groups across batches. Keep successful results and pending progress across app restarts; reopening the dashboard must not trigger reanalysis of completed records.

Validate the complete request against the selected model's input limit and encoded request-size limit, reserving space for the output. Split pending work into fitting batches rather than truncating transcripts. If a single transcript or the group definitions cannot fit, show the limitation and keep affected records visibly unanalyzed. Do not silently drop records or introduce a vector database, embeddings service, or generalized clustering framework in V1.

A 120-second client timeout is an initial default. On authentication, model access, rate-limit, service, network, or response-validation failure, preserve cached results and pending records, pause the affected queue, and offer Retry. Do not automatically repeat failed billable requests. Resume normal successful batches automatically; analysis must not require manual generation.

### Grouping contract

Use a bundled, versioned instruction document for semantic grouping. No skill runner, editable report prompt, or per-request context editor is needed in V1. Ask for short English group labels, concise definitions, and structured JSON assignments, not a Markdown report or recommendations.

Each request snapshots its dataset, source IDs, deletion generation, model ID, prompt version, and authorization state. Include transcript text as clearly separated quoted data. Send no audio, destination app metadata, field contents, clipboard history, or API key as prompt content. Existing group labels and descriptions are data as well, never instructions. Give the model no tools, shell access, or ability to execute suggestions.

Group related intent even when wording differs. Distinguish that from literal phrase frequency. For example, "use conventional commits", "write a conventional commit message", and "include a commit subject and body" should be recognizable as related commit-preparation requests. A test-writing request must not join that group merely because both mention a repository. Allow several supported groups for a multi-intent dictation and no assignment where the intent is unclear.

Require one result entry per submitted transcript ID, including empty assignments where appropriate. Assignments reference an existing group ID or a proposed new group and exact supporting excerpts from that transcript. New groups receive durable app-generated IDs, reused by later batches. Do not ask the model to invent counts, completed activities, time savings, skills, prompts, or automations.

Read all text content blocks from the API response without assuming the first block is a string. Reject refusal, max-token truncation, malformed JSON, unknown source/group IDs, missing source results, and excerpts that are not present in the source text. Validate the entire batch before committing it. A rejected or cancelled response must not mark its sources analyzed or overwrite valid cached groups.

Before saving, recheck the dataset, source existence, deletion generation, and request authorization. Persist valid assignments idempotently and compute counts locally. Refresh the Usage tab from stored results, showing analysis time and coverage. Existing groups remain readable during pending work and failures. Global regrouping, manual merge/split controls, and automatic reanalysis of completed history after a model or prompt change are outside V1.

Local retention and cloud retention are distinct. Anthropic's commercial API policy currently describes standard backend deletion within 30 days with exceptions and contractual variations. The app's Delete all history only deletes local data and cannot revoke a request already sent. Explain that distinction briefly in Settings. [Anthropic data retention](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data)

## Demo data and presentation

Seed approximately 60 short English transcripts across the preceding seven days, relative to the current date. Include varied paraphrases of repeated developer tasks such as writing tests, preparing commit messages and PR descriptions, reviewing changes, explaining code, and repeating project instructions. Include the conventional-commit and subject/body examples above, a few multi-intent requests, and unrelated requests so every entry is not part of a contrived pattern.

Use fictional project names and no real secrets. Mark sample history and its groups clearly. Make seeding idempotent and provide Reset sample data, which also removes sample groups and invalidates pending sample analysis. Switching datasets must isolate pending requests and clear the displayed selection without authorizing uploads. Live microphone sessions always save to real history, even when the dashboard is viewing samples.

Demo script:

1. Show the menu bar app and a terminal containing an AI CLI prompt or a harmless input buffer.
2. Hold right Command and dictate a developer request. Point to the reactive menu bar icon.
3. Release, observe the plain text, and manually submit only if wanted.
4. Open real history and show that the new transcript exists.
5. Switch to labeled sample history and open Usage. Show local repeated phrases and sentences, then explicitly enable sample analysis if not already enabled.
6. Observe background grouping without a Generate report action. Open Commit preparation and show differently phrased source requests, their excerpts, and the locally calculated distinct dictation count.
7. With real-history analysis enabled, dictate another related request. Show local statistics updating immediately and its group membership updating after a background batch, without interrupting dictation.

Run real sample-data grouping with the configured Haiku-family model during rehearsal and retain the results. If the service is unavailable during presentation, show cached groups with their analysis timestamp and paused/pending state. Do not present a fixture or cached result as a fresh AI response.

## Build order

Build in dependency order. Adjust, add, or remove features with the user as implementation progresses.

1. Create the Xcode target, stable app identity and run path, retained menu icon, microphone usage description, applicable entitlements, permission setup with restart/recheck, and speech asset setup.
2. Implement the nonisolated Sendable audio tap and balanced paste-event factory with their automated tests before connecting live capture. Connect right Command, microphone capture, streaming transcription, finalization, and paste. Verify at least five consecutive hold/release/paste cycles in a terminal and a regular text field, with no refocusing click, automatic Enter, or focus stealing. Keep the app alive through recording and return to Ready after each session.
3. Add local transcript history and Delete all history. Verify persistence across restarts and that deletion invalidates derived data and pending analysis.
4. Add the separate sample store, local statistics, repeated phrase/sentence counts, and the Usage tab. Keep presentation separate from core services.
5. Add Keychain settings, a verified low-cost Haiku-family model, dataset-specific consent, the grouping contract, and background batching with cached assignments. Exercise one real sample-data batch early, then verify successive batches reuse groups and update Usage without manual generation.
6. Complete the login setting, shortcut picker, and recovery behavior.
7. Run end-to-end checks, measure latency with analysis enabled, and rehearse the demo with genuine cached sample groups available for network failure.

## Validation and acceptance

Use targeted tests for the parts that can duplicate text, leak deleted data, or mishandle asynchronous sessions. Manual testing is essential for permissions and cross-app input.

Automated checks:

- Construct the production audio callback from the main actor, invoke it on a background audio queue with a synthetic buffer, and verify it runs without an actor assertion or microphone permission request.
- Inspect the production paste-event factory for the full Command down, V down, V up, Command up sequence. Verify neutral final flags, no Return/Option/Shift/Control events, zero suppression interval, and local keyboard passthrough. Repeat for consecutive sequences.
- Use an injected permission service to check notDetermined, authorized, denied, and restricted states. Verify denied access never starts capture, prompts are user-triggered, and granting access requires a fresh shortcut press.
- Transcript assembly replaces revised segments and commits each range once.
- Release during startup, double release, cancellation, stale results, timeout, and rapid repeated gestures never create a stuck recording or duplicate paste.
- Event handling reacts only to physical right Command (key code 54). Synthetic events, left Command, the other variants' keys, and the other variants' paste sequences leave GrebFlowSol idle. Another key pressed during the hold cancels the session and passes through. No event except Escape during recording is consumed.
- The paste guard waits for all physical modifiers to clear, falls back to copyOnly after the timeout, and skips the paste when the pasteboard change count no longer matches.
- Paste normalization removes line breaks and control characters while preserving ordinary text. No insertion path posts Return.
- Every nonempty insertion text ends with exactly one space, with no doubled space when the recognizer already returned trailing whitespace. Empty transcripts produce no insertion text.
- In-memory persistence tests cover Delete all history removing transcripts, groups, memberships, and pending progress, plus late network responses after deletion or sample reset.
- Sample and real stores remain isolated; reset and seeding do not duplicate records.
- Local phrase/sentence normalization and frequency counts remain deterministic. Group counts use distinct source dictations, ignore duplicate memberships, and handle one dictation in several groups without claiming an exclusive total.
- No transcript uploads occur before dataset-specific opt-in. Disabling analysis or removing the key cancels work and prevents late results from being saved. Dataset switching never grants consent.
- Background scheduling batches pending records after idle, respects the daily budget, and never starts requests during capture/finalization. Completed records are not resent on view refresh or restart.
- Input preparation includes only pending records and group definitions from one dataset. Requests respect complete input/output and encoded-size limits; oversized records remain visibly pending rather than being truncated or silently dropped.
- Validated mock responses reuse stable group IDs across batches, support new groups, multiple intents, and empty assignments, and reject unknown IDs, missing source results, unsupported excerpts, and malformed payloads.
- Persisting an analysis batch is atomic and idempotent. Save failures keep work pending; cached groups, analysis metadata, and backlog survive restart without duplicated memberships.
- URLProtocol-based API tests cover authentication errors, unavailable models without automatic escalation, rate limits, multiple content blocks, refusal, truncation, cancellation, and a successful saved grouping batch without using a real key. Failed requests pause visibly rather than automatically retrying.

Manual checks on the user's Mac:

- Verify the built app's microphone usage description and applicable signed entitlements. On a clean permission state, Enable microphone shows the macOS dialog naming GrebFlowSol before any capture begins.
- Deny microphone access, enable it later in System Settings, and revoke it after use. Verify setup status, recovery, and that no recording starts automatically after approval. Confirm keyboard/paste permission status remains separate.
- After granting keyboard/paste permissions, quit and reopen the same signed app if capability checks remain stale. Verify Allowed and Ready after relaunch, with no automatic recording.
- Verify the menu icon exists before capture, reacts during capture, and remains present after multiple recordings and after closing the dashboard. If it vanishes, check process liveness and crash reports.
- Complete at least five consecutive dictations into the same terminal input without clicking between them. Start the next hold as soon as the previous text appears. Repeat in a regular text field. Confirm no stranded Command state, skipped paste, focus loss, or duplicate text, and that consecutive transcripts are separated by a single space.
- Terminal with a shell input line and with an AI CLI, plus another installed terminal if available.
- Editor input, browser text area, and native text field. Test cursor insertion and replacing a selection.
- Right Command release, left Command independence, both Command keys held, right Command combined with an ordinary key, and other shortcut conflicts.
- Silence, a quick tap, a 5-second phrase, a 30-second prompt, a 2-minute prompt, and developer terms such as SwiftUI, TypeScript, GitHub, and repository names.
- No auto-submit in terminal, including when recognized text contains line breaks or shell-like content.
- Destination app changes, dashboard opened mid-session, permission denial, sleep/wake, and microphone disconnection.
- History and cached groups after restart, deletion or sample reset during analysis, invalid API key, no internet, and budget exhaustion. Local statistics and dictation remain usable throughout.
- Enable automatic grouping explicitly and verify that the configured Haiku-family model groups the conventional-commit and subject/body paraphrases together while keeping unrelated requests separate. Inspect original excerpts and counts; mocked API tests alone cannot prove semantic quality.
- Dictate a related new request after a group exists. Verify immediate local count updates, later automatic group updates without Generate report, and no dictation latency or focus regression while an API request is in flight.
- Verify paused, pending, last-analyzed, and analyzed/total coverage states are honest. Disable analysis and confirm new transcripts stay local; switch datasets and confirm consent and cached results remain separate.
- Stable menu icon placement and no Dock or overlay interruption during dictation.
- With GrebFlowClaude and GrebFlowArgon running, dictate into the same terminal with each variant's key in turn. Only the matching app records and pastes. The S badge identifies GrebFlowSol's icon. No stuck modifiers, no double paste, and no lost keystrokes in normal typing with right Command.
- Confirm GrebFlowSol's store files, preferences, and Keychain item are separate from the other variants'.
- Launch at login from the stable app bundle location, with registration errors shown honestly.

Measure with a monotonic clock: shortcut down, first captured buffer, first recognition result, key release, final transcript, clipboard write, and paste-event posting. Store timing metadata only. Event posting is not the same as visible insertion; confirm visible delay manually in the target apps. Record cold start separately from warm runs, using about ten short and five longer dictations. Report typical and slow observed results without overstating statistical confidence.

Version 1 is demo-ready when live dictation and terminal paste work repeatedly without refocusing between recordings, no audio is saved, real history survives restart, Delete all history removes derived data as well, and the menu icon reflects activity. Usage must show immediate local statistics and genuine, cached Haiku-family grouping of differently phrased requests, with source evidence and accurate counts. After opt-in, new dictations update groups through background batches without Generate report. Consent, offline behavior, and pending coverage must remain clear. Subsecond latency is a goal rather than an acceptance gate.

## Instructions for the implementation handoff

Start with the core loop and keep the app runnable after each increment. Follow [Implementation requirements](#implementation-requirements) when writing capture and paste code. Implement the callback and event factories with their tests before live capture. Verify native APIs against the installed SDK. Add dependencies only when they save more work than they introduce.

Have the user grant dictation permissions and install English speech assets through the setup flow. Verify live dictation, consecutive paste, and menu bar behavior on the target Mac. Complete the compatibility matrix, low-cost model access and real semantic-grouping check, consent and deletion checks, login registration checks, and latency measurements before claiming demo readiness. Record automated results and manual observations separately. Do not assume that every app, field, or machine is compatible.
