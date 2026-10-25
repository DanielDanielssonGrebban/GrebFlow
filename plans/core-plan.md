# GrebFlow V1 core plan

Status: ready for implementation. This document defines the version 1 scope, technical requirements, build order, and acceptance checks.

Complete V1 before considering the optional features in the [V2 plan](v2-plan.md).

Build GrebFlow for a one-day company hackathon. The project and app name is GrebFlow.

## Implementation requirements

Implement the following requirements as part of the core dictation loop. A successful build or a Ready label alone does not prove live dictation works.

### Permission setup must include restart and recheck

Run the signed app bundle from one stable path with the same bundle identifier and signing identity. Request microphone, keyboard monitoring, and paste/Accessibility access through separate explicit setup actions. Download the English speech assets through their setup action.

After the user enables Input Monitoring or Accessibility, refresh the capability checks. If they still report missing access, quit GrebFlow completely and reopen the same built app bundle. A permission checkbox may not take effect in the already-running process. Recheck capabilities after relaunch before considering a rebuild or permission reset.

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

Set `source.localEventsSuppressionInterval = 0`. Allow local keyboard, mouse, and system-defined events in the source filters for both suppression-interval and remote-mouse-drag states. Preserve physical modifier guards. Never emit Return or carry Option into this sequence. Never activate the destination, restore focus with a mouse click, or automatically retry a paste as a workaround.

Test the actual event factory. Assert event order, key codes, event types, neutral final flags, zero suppression interval, and allowed local keyboard input. Repeat sequence construction several times and verify each sequence independently balances Command and contains no Return, Option, or Control events. These tests must inspect events from the production factory without posting into another app.

### Verify the menu bar app stays alive during recording

Retain the status controller and NSStatusItem for the app lifetime. Normal launch has a menu bar icon and no Dock icon. Provide explicit ways to open Settings and the dashboard, and leave dictation running when the dashboard closes. Keep the idle, recording, processing, and setup/error icon states distinct.

If the icon disappears, first check whether the GrebFlow process exited and inspect its crash report. An app crash also removes its menu bar item. Diagnose process termination separately from status-item creation or visibility. After correcting a crash, rebuild with the same identity, verify the signature, relaunch, and test capture again.

If the recording indicator responds but no text appears, check whether history contains the phrase and whether its outcome is copyOnly. Recognition may already be working. Inspect the reported paste-skip reason and physical modifier state before changing the speech engine or adding focus restoration. Log predefined failure reasons and timing metadata only, never transcript text, field contents, unrelated keyboard input, or API keys.

The core loop must pass the callback and paste tests, survive real microphone capture, and complete consecutive dictations without another click. If a UI automation tool cannot hold a modifier key alone, use a physical user test and record its result separately from automated checks.

## Product and demo goal

Build a native macOS menu bar dictation app for developers. The user holds right Option, speaks an English prompt, releases the key, and gets plain text pasted into the focused input. Terminal and AI coding CLI input are first-class destinations.

The differentiator is analysis of repeated developer work. The dashboard uses local transcript history to show usage and lets the user request a Claude report with suggestions for skills, reusable prompts, or automations. These remain suggestions. The app never executes them.

The demo must show live dictation, local history, basic statistics, and a genuine Anthropic report generated from an explicitly selected dataset. Provide sample history because one day of real usage may not contain enough repetition.

## Version 1 decisions

| Area | Version 1 decision |
| --- | --- |
| Name | GrebFlow for the project, app, and code identifiers. |
| Platform | Native macOS app written in Swift. Demo runs on the user's Mac. |
| App entry point | Persistent menu bar icon and menu. Dashboard opens in a native window. |
| Shortcut | Hold right Option to record. Release to finish and paste. Allow changing the shortcut in Settings. |
| Recording feedback | Menu bar icon only. Respond to microphone activity and distinguish recording from processing. No floating overlay. |
| Insertion | Put plain text on the clipboard and simulate paste. Keep the destination app focused. |
| Terminal behavior | Single-line text, no embedded line breaks, no automatic Enter, no command generation or execution. |
| Transcription | Start with Apple's on-device English transcription. Recognize while the user speaks. |
| Performance | Aim for text within one second after release. Faster is better. Longer latency does not make the hackathon a failure. |
| Audio | Process transient microphone audio. Do not save recordings. |
| History | Save transcripts and small amounts of metadata in a local database. No hosted database or sync. |
| Retention | Default 30 days, optional 7 days, and Delete all history. Reports must not preserve expired source history. |
| AI | Anthropic. API key field in Settings, key stored in macOS Keychain. |
| Report trigger | User clicks Generate report. Automatic weekly delivery comes later. |
| Sample data | Optional, clearly labeled sample history, separate from real history. |
| Login | Provide a Launch at login setting. |
| Distribution | Outside V1. See the [V2 plan](v2-plan.md). |

The remaining choices below are implementation defaults. Prefer simple implementations within the agreed scope.

## Target environment

Target macOS 26 and Apple silicon for the proof of concept. The development machine runs macOS 26.6.2 and has Xcode at /Applications/Xcode.app with Swift 6.2 and a macOS 26 SDK. Confirm the installed versions before implementation. Do not accidentally use macOS 27-only APIs from the latest online documentation.

Check English locale availability through SpeechTranscriber.supportedLocales and verify that the installed SDK includes progressive transcription presets, prepareToAnalyze, and explicit finalization methods. Keep Swedish support outside version 1; evaluate DictationTranscriber locales and assets separately for that later feature.

## Version 1 boundaries

Build the recording and paste loop, menu bar states, local history, simple statistics, Anthropic reports, retention, API key settings, login setting, and separate demo data.

Defer automatic output muting, automatic bilingual recognition, filler-word rewriting, cloud transcription, saved audio, code or shell-command generation, email delivery, scheduling, multi-provider AI support, accounts, hosted services, synchronization, custom vocabulary management, app exclusions, and distribution. Normal recognizer punctuation is fine. Do not add an LLM cleanup step before paste.

Optional follow-up features and their technical requirements live in the [V2 plan](v2-plan.md). Deferred items are not V1 acceptance requirements.

Support broad paste compatibility without claiming every application or field will accept it. Prove it in Terminal, the user's preferred terminal emulator if installed, an AI coding CLI, an editor, a browser text area, and a standard native text field.

## Technical approach

| Need | Initial implementation |
| --- | --- |
| App and dashboard | SwiftUI with AppKit integration for status icon and window behavior. One macOS Xcode app target. |
| Menu bar | NSStatusItem with an NSMenu and a small custom icon drawing microphone level. This offers direct control over icon updates. |
| App lifecycle | LSUIElement enabled. No ordinary main window at launch. Opening the dashboard explicitly activates it. Closing it leaves dictation available. |
| Shortcut | Quartz event tap, handling flagsChanged and the physical right Option key independently of left Option. |
| Microphone | AVAudioEngine with an input tap. No audio-file output. |
| Speech | SpeechAnalyzer plus SpeechTranscriber, initially en-US and timeIndexedProgressiveTranscription. |
| Text insertion | NSPasteboard.general and synthetic Command-V through CGEvent. |
| Persistence | SwiftData backed by a local store in Application Support. Explicitly disable CloudKit integration. |
| API | A small URLSession client for Anthropic Messages. No third-party SDK needed. |
| Secrets | Security framework Keychain generic-password item. |
| Preferences | UserDefaults or AppStorage for non-secret settings. |
| Login | SMAppService.mainApp registration and actual service status. |
| Word counts | NaturalLanguage tokenization and a small checked-in English stop-word list. |

Use a directly run local app bundle with stable identity and development signing where available. Use a non-App-Store, unsandboxed target for the POC's global input integration. Reassess sandboxing and distribution later.

Apple documents both SwiftUI MenuBarExtra and the LSUIElement behavior, but AppKit's status item is the implementation default here because the icon itself must animate. [Menu bar documentation](https://developer.apple.com/documentation/swiftui/menubarextra)

### Keep the code small

Use GrebFlow consistently throughout the project: GrebFlow.xcodeproj, the GrebFlow app target, scheme and Swift module, GrebFlowApp as the app entry point, and GrebFlow.app as the built product. Name the test target GrebFlowTests and use GrebFlow in window titles and menu labels.

Suggested folders and responsibilities, not a mandatory file count:

```text
GrebFlow/
  App/                 app entry point, service wiring, dashboard window
  Dictation/           session coordinator, shortcut, audio, speech, paste
  Storage/             models, local repository, retention, demo seeding
  Reports/             Anthropic client, report preparation and prompt
  Settings/            preferences, Keychain, permissions, login item
  UI/                  status item, dashboard views
GrebFlowTests/
  session lifecycle, transcript assembly, paste normalization,
  retention, report input, Anthropic response handling
```

Keep one coordinator responsible for each recording session. Views display state and issue actions. Audio callbacks and the event tap do minimal work and hand off to the appropriate worker. Run storage and report preparation away from the audio callback. Use Swift concurrency isolation deliberately rather than adding detached tasks to silence compiler warnings.

Use small replaceable interfaces for speech, key events, paste, storage, and the API where they enable meaningful tests. Avoid a generalized plugin framework. Apply the audio callback and event-sequence rules in [Implementation requirements](#implementation-requirements) before the first live test.

## Permissions and first-run setup

Microphone access requires the user's macOS approval even though GrebFlow processes audio locally and does not save recordings. Unsandboxed operation does not bypass this permission.

### Build configuration

- Add NSMicrophoneUsageDescription to the app's built Info.plist, including when Xcode generates that file. Use: "GrebFlow uses your microphone while you hold the dictation shortcut to turn speech into text. Audio is processed on your Mac and is not saved."
- If Hardened Runtime is enabled, enable Audio Input in Signing & Capabilities, setting com.apple.security.device.audio-input to true in the signed app's entitlements. This capability does not grant user consent. Keep App Sandbox disabled as specified above.
- Run GrebFlow.app with a stable bundle identifier, signing identity, and location during development and rehearsal. Verify permission attribution belongs to GrebFlow rather than a command-line test tool. Changing app identity may require approval again.

Apple requires a microphone usage description and documents the audio-input capability separately from user authorization. [Microphone usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription), [Audio Input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)

### Microphone authorization flow

1. Read AVCaptureDevice.authorizationStatus(for: .audio) before installing the input tap or starting capture. Surface the result in Settings and the menu's setup status.
2. For notDetermined, show an Enable microphone action in Settings. On that action, call AVCaptureDevice.requestAccess(for: .audio) and await the result. macOS presents the approval dialog. GrebFlow cannot enable this permission itself.
3. For authorized, allow recording once the other dictation prerequisites are ready. Approval must not start a recording automatically; require a fresh shortcut press.
4. For denied, keep recording disabled and offer Open System Settings with instructions to enable GrebFlow under System Settings > Privacy & Security > Microphone. Do not repeatedly request access because the original dialog will not reappear. Use a pane-opening URL only if verified on the target macOS version; always retain the written navigation path.
5. For restricted, explain that a system or organization policy blocks access. Do not repeatedly prompt or attempt a workaround. History and reports remain usable.
6. Recheck on app activation, returning from System Settings, and before every recording. On loss of access or capture failure, stop capture, discard the unfinished session, and expose the actionable setup state. If macOS requires relaunch after a permission change, make that explicit.

Permission setup must finish before normal dictation use so no approval dialog interrupts the hold-to-talk path. An unconfigured shortcut press may show a setup-needed icon/menu state, but must not queue a recording to start later. [Apple's media authorization flow](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media), [authorization status](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:))

### Other permissions

After permission changes, follow the restart and recheck procedure in [Implementation requirements](#implementation-requirements). Reopen the same signed bundle and verify actual capabilities rather than relying on the System Settings checkbox alone.

Microphone approval does not authorize keyboard observation or synthetic paste. Check the actual event-listening and event-posting capabilities with CGPreflightListenEventAccess and CGPreflightPostEventAccess. Use the corresponding request APIs from explicit setup actions, and expose Input Monitoring or Accessibility guidance only where needed by the chosen event-tap implementation. If focused-element checks use Accessibility APIs, also check AXIsProcessTrustedWithOptions. Verify the actual combination on the demo Mac instead of treating permission to one capability as permission to all of them.

SpeechAnalyzer's on-device transcriber modules do not need the separate SFSpeechRecognizer speech-recognition authorization flow. Do not request that additional permission for the planned engine. If a later implementation introduces SFSpeechRecognizer, revisit its authorization and NSSpeechRecognitionUsageDescription requirements. Speech-model downloads remain a separate setup prerequisite. [Apple's speech permission distinction](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)

## Dictation lifecycle

The primary state path is idle, starting, recording, finalizing, paste attempted, then idle. Missing setup produces a needs-setup state. Cancellation and errors must always stop capture and release session resources.

1. At launch, inspect microphone permission, shortcut event access, event-posting access, and English model availability using the setup flow above. Never start microphone capture before authorization. Download missing speech assets through an explicit setup action. Prepare the recognizer before advertising Ready.
2. Right Option down creates a unique session ID and remembers the destination application's process ID. If accessible, also remember the focused input element without reading its contents. Do not activate this app.
3. Start microphone capture. If release arrives during startup, remember it so delayed startup cannot leave the microphone recording.
4. Feed audio buffers into the analyzer continuously. Convert sample rate and channel format to the format the analyzer accepts. Derive icon amplitude from the same buffers and throttle UI updates to roughly 10 per second.
5. Assemble provisional and finalized recognition results by their audio ranges. Provisional results replace provisional text; they are not appended repeatedly. Only one final assembled transcript is committed.
6. On release, stop accepting new microphone input, hand off already captured buffers, terminate the input sequence, and explicitly finalize the analyzer. For analysis started with start, use finalizeAndFinishThroughEndOfInput after the stream ends. Ending an AsyncStream alone is insufficient.
7. Await the remaining results and construct one final transcript. Normalize it to safe single-line paste text.
8. Queue local persistence and attempt clipboard paste promptly. Persistence and analytics must not block input delivery. If saving fails, keep dictation usable and expose a storage error.
9. Release audio buffers and session tasks. Prepare a new analyzer for the next session. A finalized analyzer cannot simply accept another recording.

Use prepareToAnalyze to reduce model startup work. Consider the model-retention option after correctness is established. Keep the microphone stopped when idle; preparation must not become continuous background recording. [SpeechAnalyzer lifecycle](https://developer.apple.com/documentation/speech/speechanalyzer), [live transcription preset](https://developer.apple.com/documentation/speech/speechtranscriber/preset/timeindexedprogressivetranscription)

### Shortcut and cancellation details

- Right Option and left Option must be distinct. Generic Option flags alone are insufficient when both keys can be held.
- Reserve right Option for dictation while enabled. Handle the relevant physical key transitions without disturbing unrelated keyboard events or leaving modifier state stuck.
- Wait for physical shortcut release and check hardware modifier flags through .hidSystemState before posting Command-V. Use the full Command down, V down, V up, Command up sequence specified above. End with empty flags. Never post Option-Command-V accidentally.
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

Check the destination before injecting the paste. If the foreground application changed since keydown, keep the text available for manual copy and show a menu error instead of activating an old app. If a captured focused element can be compared reliably, reject a changed field as well. This is a best-effort protection, not a universal way to prove cursor identity across apps.

Treat event posting as a paste attempt. The OS does not provide a generic acknowledgment that a third-party field accepted the text. Persist pasteAttempted or copyOnly, not an unverified insertedSuccessfully claim. Do not automatically retry a paste that could duplicate text.

When there is no editable destination, retain the transcript in history and allow Copy. Empty or cancelled recordings must not replace the clipboard. Where secure-input state can be detected with public APIs, disable dictation there; do not bypass it.

The shared macOS clipboard can participate in Universal Clipboard and can be read by clipboard utilities. Do not describe it as app-private storage. [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard)

## Storage and retention

Use one real SwiftData store and a distinct demo store. No iCloud capability, remote database client, audio files, or automatic uploads.

Transcript fields:

- id, startedAt, endedAt, durationSeconds, locale.
- Final recognized text and normalized insertion text, if different.
- Word count and optional destination application bundle ID. Do not store window titles, surrounding text, or unrelated keyboard input.
- Release-to-final and release-to-paste-event durations.
- Outcome such as pasteAttempted or copyOnly.

Store successful nonempty transcripts once. Cancelled and empty sessions need no content record. Keep recoverable recognition failures visible without claiming incomplete text is final.

Report fields:

- id, generatedAt, periodStart, periodEnd, sourceTranscriptIDs.
- Model ID, prompt version, generated Markdown, and input/output token usage if returned.
- expiresAt, no later than the earliest expiration of any source transcript.
- Snapshot of the history deletion generation, used to prevent stale request results being saved.

Run retention at launch, before history queries and report requests, when settings change, and periodically while running. Use a daily timer plus a wake check. Queries must exclude expired rows even before physical cleanup finishes. Compare rolling 7- or 30-day age against timestamps, and group dashboard days using local calendar time.

Changing from 30 to 7 days purges the older records immediately. Delete all history clears transcripts and reports, cancels report work, invalidates cached statistics, and clears this app's latest clipboard content only if clipboard ownership has not changed. Do not overwrite clipboard data copied by another app. Leave the API key and preferences alone; provide a separate Remove API key action.

Delete saved reports when their source records expire or are deleted. Also clear displayed report text. Before saving a network response, recheck source existence, expiry, and deletion generation so a late response cannot recreate deleted content.

The app cannot run cleanup while fully quit. Perform it on next launch. Normal row deletion is application-level retention, not a guarantee of forensic erasure from SQLite files, OS backups, or already-sent API requests. Do not promise secure erasure or custom encryption in this POC.

## Menu and dashboard

Menu items:

- Current state and setup problem, if any.
- Hold right Option to dictate.
- Open dashboard.
- Copy latest transcript when available.
- Settings.
- Quit.

Icon states: idle microphone, audio-reactive recording icon, distinct processing animation, and setup/error indicator. Distinguish states by shape or movement as well as color. Do not open windows automatically during dictation.

The dashboard can use a simple sidebar or tabs:

- Overview: transcript count, dictated words, recording duration, words per minute, daily usage, and frequent non-stop-words.
- History: timestamp, transcript, duration, and Copy. Detailed search and editing can wait.
- Reports: Last 7 days or Last 30 days within available retention, Generate report, progress, errors, and saved results.
- Settings: API key, model ID, retention, shortcut, Launch at login, setup status, demo mode, and Delete all history.

Statistics should come from local code. Word frequency excludes common English stop words while retaining developer terms. Clearly label words per minute as dictated words divided by recording duration. Do not invent typing-time savings without an agreed baseline.

Keep Launch at login off until enabled. Use SMAppService.mainApp and show its real registration/approval state. Test from a stable app bundle location; user or system approval may be needed. [Apple's login item API](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)

## Anthropic report implementation

Use direct HTTPS from this user's desktop app to Anthropic with their own API key. No hosted proxy and no embedded shared credential. This is a personal-key prototype, not a backend design for distributing a company-funded secret.

Settings uses a secure input field with Save, Replace, Remove, and connection status. Never print the key, persist it in UserDefaults, or include it in fixtures, crash logs, or Git. Clear the input after saving. A connection test can query model availability without sending history.

Use POST https://api.anthropic.com/v1/messages with x-api-key, anthropic-version: 2023-06-01, Content-Type: application/json, a model, bounded max_tokens, a system prompt, and a user message. x-api-key remains supported in the current official authentication docs. Confirm the API contract again at build time. [API overview](https://platform.claude.com/docs/en/api/overview), [authentication](https://platform.claude.com/docs/en/manage-claude/authentication)

Use claude-sonnet-5-5 as the proposed default model ID and confirm its availability in Anthropic's official catalog before implementation. Make the model ID editable and validate access using the Models API. If the key cannot use it, explain the error and let the user choose an available model. Do not silently substitute providers or assume all accounts have access. Avoid custom temperature or thinking parameters in the first request. [Model catalog](https://platform.claude.com/docs/en/models/overview)

Use one asynchronous non-streaming request initially, with visible progress and Cancel. Keep the main thread and dictation responsive. A 120-second client timeout is an initial default. Streaming report display is optional after the complete request path works.

Report generation flow:

1. Purge and filter history for the selected period and current dataset.
2. Show the date range, transcript count, and text stating that Generate report sends that text to Anthropic. The button is the explicit send action; do not add a modal confirmation on every run.
3. Include dated transcript IDs, recording times, text, and locally computed counts. Do not send audio, app window contents, clipboard history, or the API key as prompt content.
4. Set an initial payload ceiling of 100,000 UTF-8 bytes of transcript data. Select whole records newest first, then present them chronologically. If records are omitted or a single record is too large, state how many were included. No silent truncation or complex chunking pipeline in version 1.
5. Ask for a concise Markdown report in English with repeated workflows, evidence using real supplied transcript IDs and short excerpts, and up to five practical suggestions for a skill, reusable prompt, or automation. Ask the model to distinguish observed repetitions from inferred similarities. Say when evidence is insufficient.
6. Treat transcript text as quoted user data, not instructions for the report generator. Include no tools, shell access, web search, or automation execution. Do not claim measured time savings from speculative recommendations.
7. Read all text content blocks from the response. Handle non-text blocks without assuming the first block is a string. Distinguish successful completion from refusal or max-token truncation. Start with an output allowance of 4,096 tokens and adjust only if evidence requires it.
8. Save completed results and their source IDs after rechecking deletion state. Render as ordinary text/Markdown with Copy report. Do not automatically open links, install skills, or execute suggestions.

Handle missing/invalid keys, unavailable models, offline state, rate limits, service errors, malformed responses, truncation, and cancellation. Keep existing reports visible and offer Retry; do not automatically repeat billable report requests. Dictation continues without an API key or internet connection after speech assets are installed.

Local retention and cloud retention are distinct. Anthropic's commercial API policy currently describes standard backend deletion within 30 days with exceptions and contractual variations. The app's Delete all history only deletes local data and cannot revoke a request already sent. Explain that distinction briefly in Settings. [Anthropic data retention](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data)

## Demo data and presentation

Seed approximately 60 short English transcripts across the preceding seven days, relative to the current date. Include varied paraphrases of repeated developer tasks such as writing tests, preparing PR descriptions, reviewing changes, explaining code, and repeating project instructions. Add a few unrelated requests so every entry is not part of a contrived pattern.

Use fictional project names and no real secrets. Mark the dashboard and report input as sample data. Make seeding idempotent and provide Reset sample data. Switching datasets must cancel or isolate pending requests and clear the displayed selection. Live microphone sessions always save to real history, even when the dashboard is viewing samples.

Demo script:

1. Show the menu bar app and a terminal containing an AI CLI prompt or a harmless input buffer.
2. Hold right Option and dictate a developer request. Point to the reactive menu bar icon.
3. Release, observe the plain text, and manually submit only if wanted.
4. Open real history and show that the new transcript exists.
5. Switch to labeled sample history, show usage and repeated terms, and click Generate report.
6. Explain one Claude recommendation and its supporting excerpts. Copy the report without executing anything.

Generate and retain one sample report during rehearsal. If the service is unavailable during presentation, show that saved report with its generation timestamp and label it as previously generated. Do not present a fixture as a fresh AI response.

## Build order

Build in dependency order. Adjust, add, or remove features with the user as implementation progresses.

1. Create the Xcode target, stable app identity and run path, retained menu icon, microphone usage description, applicable entitlements, permission setup with restart/recheck, and speech asset setup.
2. Implement the nonisolated Sendable audio tap and balanced paste-event factory with their automated tests before connecting live capture. Connect right Option, microphone capture, streaming transcription, finalization, and paste. Verify at least five consecutive hold/release/paste cycles in a terminal and a regular text field, with no refocusing click, automatic Enter, or focus stealing. Keep the app alive through recording and return to Ready after each session.
3. Add local transcript history and retention. Verify persistence across restarts and deletion of expired records.
4. Add the dashboard statistics and separate sample store.
5. Add Keychain settings and on-demand Claude reports. Generate a real report from sample history.
6. Complete the login setting, shortcut picker, and recovery behavior.
7. Run end-to-end checks, measure latency, and rehearse the demo with a saved, labeled report available for network failure.

## Validation and acceptance

Use targeted tests for the parts that can duplicate text, leak expired data, or mishandle asynchronous sessions. Manual testing is essential for permissions and cross-app input.

Automated checks:

- Construct the production audio callback from the main actor, invoke it on a background audio queue with a synthetic buffer, and verify it runs without an actor assertion or microphone permission request.
- Inspect the production paste-event factory for the full Command down, V down, V up, Command up sequence. Verify neutral final flags, no Return/Option/Control events, zero suppression interval, and local keyboard passthrough. Repeat for consecutive sequences.
- Use an injected permission service to check notDetermined, authorized, denied, and restricted states. Verify denied access never starts capture, prompts are user-triggered, and granting access requires a fresh shortcut press.
- Transcript assembly replaces revised segments and commits each range once.
- Release during startup, double release, cancellation, stale results, timeout, and rapid repeated gestures never create a stuck recording or duplicate paste.
- Paste normalization removes line breaks and control characters while preserving ordinary text. No insertion path posts Return.
- In-memory persistence tests cover 7/30-day boundaries, settings changes, source report deletion, and late network responses after Delete all history.
- Sample and real stores remain isolated; reset and seeding do not duplicate records.
- Report preparation filters dates, enforces input bounds, exposes omissions, and sends only the selected dataset.
- URLProtocol-based API tests cover authentication errors, rate limits, multiple content blocks, truncated output, cancellation, and a successful saved report without using a real key.

Manual checks on the user's Mac:

- Verify the built app's microphone usage description and applicable signed entitlements. On a clean permission state, Enable microphone shows the macOS dialog naming GrebFlow before any capture begins.
- Deny microphone access, enable it later in System Settings, and revoke it after use. Verify setup status, recovery, and that no recording starts automatically after approval. Confirm keyboard/paste permission status remains separate.
- After granting keyboard/paste permissions, quit and reopen the same signed app if capability checks remain stale. Verify Allowed and Ready after relaunch, with no automatic recording.
- Verify the menu icon exists before capture, reacts during capture, and remains present after multiple recordings and after closing the dashboard. If it vanishes, check process liveness and crash reports.
- Complete at least five consecutive dictations into the same terminal input without clicking between them. Start the next hold as soon as the previous text appears. Repeat in a regular text field. Confirm no stranded Command state, skipped paste, focus loss, or duplicate text.
- Terminal with a shell input line and with an AI CLI, plus another installed terminal if available.
- Editor input, browser text area, and native text field. Test cursor insertion and replacing a selection.
- Right Option release, left Option independence, both Option keys held, and other shortcut conflicts.
- Silence, a quick tap, a 5-second phrase, a 30-second prompt, a 2-minute prompt, and developer terms such as SwiftUI, TypeScript, GitHub, and repository names.
- No auto-submit in terminal, including when recognized text contains line breaks or shell-like content.
- Destination app changes, dashboard opened mid-session, permission denial, sleep/wake, and microphone disconnection.
- Retention after restart, deleting history while a report is in flight, invalid API key, no internet, and sample-mode report generation.
- Stable menu icon placement and no Dock or overlay interruption during dictation.
- Launch at login from the stable app bundle location, with registration errors shown honestly.

Measure with a monotonic clock: shortcut down, first captured buffer, first recognition result, key release, final transcript, clipboard write, and paste-event posting. Store timing metadata only. Event posting is not the same as visible insertion; confirm visible delay manually in the target apps. Record cold start separately from warm runs, using about ten short and five longer dictations. Report typical and slow observed results without overstating statistical confidence.

Version 1 is demo-ready when live dictation and terminal paste work repeatedly without refocusing between recordings, no audio is saved, real history survives restart, retention works, the menu icon reflects activity, the dashboard shows useful basic data, and a real Anthropic request produces a readable report from selected data. Subsecond latency is a goal rather than an acceptance gate.

## Instructions for the implementation handoff

Start with the core loop and keep the app runnable after each increment. Follow [Implementation requirements](#implementation-requirements) when writing capture and paste code. Implement the callback and event factories with their tests before live capture. Verify native APIs against the installed SDK. Add dependencies only when they save more work than they introduce.

Have the user grant dictation permissions and install English speech assets through the setup flow. Verify live dictation, consecutive paste, and menu bar behavior on the target Mac. Complete the compatibility matrix, Anthropic report test, login registration checks, and latency measurements before claiming demo readiness. Record automated results and manual observations separately. Do not assume that every app, field, or machine is compatible.
