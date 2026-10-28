# GrebFlowClaude

The Claude build of [plans/core-plan-claude.md](../plans/core-plan-claude.md). It runs next to GrebFlowSol and GrebFlowArgon on the same Mac, with its own key, bundle ID, data, and permissions.

| | |
| --- | --- |
| Dictation key | right Option |
| Bundle ID | `com.grebban.GrebFlowClaude` |
| Menu bar | microphone with a **C** badge |
| Data | `~/Library/Application Support/com.grebban.GrebFlowClaude/` |
| Keychain item | service `com.grebban.GrebFlowClaude` |
| Grouping model | `claude-haiku-5-5` by default |

## Run it

Needs macOS 26 on Apple silicon and Xcode 26. From this folder:

```sh
scripts/run.sh          # build, install to build/GrebFlowClaude.app, launch
scripts/run.sh --test   # same, with the unit tests first
```

Always launch `build/GrebFlowClaude.app`. macOS ties permissions to the bundle ID and signature, so GrebFlowClaude needs its own grants even if the other variants have theirs.

First run: click the C microphone, choose **Settings…**, and work down the Setup list.

1. **Enable microphone** and approve the macOS dialog.
2. **Input Monitoring** and **Accessibility**: request each, then switch GrebFlowClaude on in System Settings.
3. If the shortcut listener still isn't running, click **Quit and reopen GrebFlowClaude**. macOS often only applies these after a restart.
4. **Download** the English speech model.

When it says **Ready to dictate**, hold right Option, speak, and let go. The text is pasted as one line with a trailing space and no Enter. Escape cancels while recording. Pressing any other key during the hold cancels too, so right Option still types special characters.

## Usage and grouping

The **Usage** tab shows repeated phrases and sentences straight away, counted on this Mac. Grouping by meaning needs an Anthropic API key (Settings > Anthropic) and your consent per dataset. Nothing is sent until you turn it on.

Initial limits, all in `AnalysisLimits`:

| Setting | Value |
| --- | --- |
| Batch size | 20 transcripts |
| Idle wait before a batch | 10 s without dictation |
| Output allowance | 4,096 tokens per request |
| Daily budget | 100 requests and 500,000 tokens |
| Request timeout | 120 s |

Failed requests pause the queue until you click Retry; nothing is retried automatically.

## Tests

```sh
xcodebuild -project GrebFlowClaude.xcodeproj -scheme GrebFlowClaude -derivedDataPath build/DerivedData test
```

They run without a host app, so they never touch the microphone, the keyboard, the menu bar, or the network.
