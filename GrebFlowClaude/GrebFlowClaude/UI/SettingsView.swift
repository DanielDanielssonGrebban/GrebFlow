import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var keyInput = ""
    @State private var modelIDInput = ""
    @State private var confirmDelete = false
    @State private var consentDataset: Dataset?

    var body: some View {
        Form {
            setupSection
            dictationSection
            anthropicSection
            groupingSection
            historySection
            generalSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            modelIDInput = model.preferences.modelID
            model.loginItem.refresh()
            Task { await model.setup.refresh() }
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmDelete) {
            Button("Delete all history", role: .destructive) { model.deleteAllHistory() }
        } message: {
            Text("Deletes all real and sample transcripts, their groups, and analysis progress, and stops any analysis in flight. Your API key and preferences are kept.")
        }
        .confirmationDialog(
            "Turn on automatic grouping for \(consentDataset?.label.lowercased() ?? "")?",
            isPresented: Binding(get: { consentDataset != nil }, set: { if !$0 { consentDataset = nil } }),
            presenting: consentDataset
        ) { dataset in
            Button("Turn on") { model.setAnalysisEnabled(true, for: dataset) }
        } message: { dataset in
            Text(AnalysisConsent.explanation(dataset: dataset, modelID: model.preferences.modelID))
        }
    }

    // MARK: Setup

    private var setupSection: some View {
        let snapshot = model.setup.snapshot
        let keyboardOK = snapshot.accessibilityTrusted && snapshot.canPost
        return Section {
            if snapshot.mayNeedRelaunch {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    Text("Permissions changed. macOS applies Input Monitoring and Accessibility after GrebFlowClaude restarts.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Quit and reopen") { model.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
            }
            SetupRow(title: "Microphone", ok: snapshot.microphone == .authorized, detail: microphoneDetail(snapshot.microphone)) {
                if snapshot.microphone == .notDetermined || snapshot.microphone == .denied {
                    Button("Grant access") { Task { await model.setup.grantMicrophone() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            SetupRow(
                title: "Input Monitoring",
                ok: snapshot.canListen,
                detail: snapshot.canListen
                    ? "Allowed"
                    : "Lets GrebFlowClaude notice right Option. Click Grant access, then switch on GrebFlowClaude in the list that opens. If it isn't listed, click + and pick build/GrebFlowClaude.app."
            ) {
                if !snapshot.canListen {
                    Button("Grant access") { model.setup.grantInputMonitoring() }
                        .buttonStyle(.borderedProminent)
                }
            }
            SetupRow(
                title: "Accessibility",
                ok: keyboardOK,
                detail: keyboardOK
                    ? "Allowed"
                    : "Lets GrebFlowClaude paste with Command-V. Click Grant access, then switch on GrebFlowClaude in the list that opens."
            ) {
                if !keyboardOK {
                    Button("Grant access") { model.setup.grantAccessibility() }
                        .buttonStyle(.borderedProminent)
                }
            }
            SetupRow(
                title: "Shortcut listener",
                ok: snapshot.eventTapInstalled,
                detail: snapshot.eventTapInstalled ? "Running" : "Starts once Input Monitoring and Accessibility are allowed."
            ) { EmptyView() }
            SetupRow(title: snapshot.modelName, ok: snapshot.speech == .installed, detail: snapshot.speech.label) {
                switch snapshot.speech {
                case .notInstalled, .failed:
                    Button("Download") { Task { await model.setup.installSpeechModel() } }
                case let .downloading(fraction):
                    ProgressView(value: fraction).frame(width: 100)
                default:
                    EmptyView()
                }
            }
            SetupRow(
                title: "Recognizer",
                ok: snapshot.recognizerPrepared,
                detail: snapshot.recognizerError ?? (snapshot.recognizerPrepared ? "Ready" : (snapshot.speech == .installed ? snapshot.preparingMessage : "Prepares after the model is downloaded"))
            ) { EmptyView() }

            HStack {
                Button("Check again") { Task { await model.setup.refresh() } }
                Button("Quit and reopen GrebFlowClaude") { model.relaunch() }
                Spacer()
                Text(snapshot.isReady ? "Ready to dictate" : (snapshot.problem ?? ""))
                    .foregroundStyle(snapshot.isReady ? .green : .secondary)
            }
        } header: {
            Text("Setup")
        } footer: {
            Text("GrebFlowClaude needs its own permissions even if GrebFlowSol or GrebFlowArgon already has them. Audio is processed on this Mac and never saved. Granting a permission never starts a recording; press the shortcut again.")
        }
    }

    private func microphoneDetail(_ status: MicrophoneAuthorization) -> String {
        switch status {
        case .authorized: "Allowed"
        case .notDetermined: "Not asked yet. Grant access shows the macOS dialog."
        case .denied: "Turned off. Grant access opens \(PrivacyPane.microphone.navigationPath) so you can switch it on."
        case .restricted: "Blocked by a system or organization policy. History and Usage still work."
        }
    }

    // MARK: Dictation

    private var dictationSection: some View {
        Section("Dictation") {
            Picker("Speech model", selection: Binding(
                get: { model.preferences.recognizer },
                set: { model.setRecognizer($0) }
            )) {
                ForEach(Recognizer.allCases) { recognizer in
                    Text(recognizer.label).tag(recognizer)
                }
            }
            .pickerStyle(.menu)
            Text(model.preferences.recognizer.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Hold to dictate", selection: Binding(
                get: { model.preferences.shortcut },
                set: { model.setShortcut($0) }
            )) {
                ForEach(DictationShortcut.allCases) { shortcut in
                    Text(shortcut.label).tag(shortcut)
                }
            }
            if let other = model.preferences.shortcut.otherVariant {
                Label("\(other) uses \(model.preferences.shortcut.label) by default. If it's running, both apps will react to this key.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Release to paste into the focused field, followed by one space. Escape cancels a recording. Pressing any other key or modifier while holding the shortcut also cancels, so the key still works for normal typing.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Anthropic

    private var anthropicSection: some View {
        Section {
            HStack {
                SecureField(model.apiKey.hasKey ? "Replace API key" : "API key", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                Button(model.apiKey.hasKey ? "Replace" : "Save") {
                    if model.apiKey.save(keyInput) { keyInput = "" }
                }
                .disabled(keyInput.isEmpty)
                if model.apiKey.hasKey {
                    Button("Remove API key", role: .destructive) { model.apiKey.remove() }
                }
            }
            LabeledContent("Status", value: model.apiKey.hasKey ? "Key stored in the Keychain" : "No key")

            HStack {
                TextField("Model ID", text: $modelIDInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveModelID)
                Button("Save") { saveModelID() }
                    .disabled(modelIDInput.trimmingCharacters(in: .whitespaces).isEmpty || modelIDInput == model.preferences.modelID)
                Button("Test connection") {
                    saveModelID()
                    Task { await model.apiKey.test(modelID: model.preferences.modelID) }
                }
                .disabled(!model.apiKey.hasKey || model.apiKey.isTesting)
            }
            if !model.preferences.isLowCostModel {
                Text("This isn't a Haiku model, so grouping will cost more. GrebFlowClaude never switches models on its own; the default is \(Preferences.defaultModelID).")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let status = model.apiKey.status {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Anthropic")
        } footer: {
            Text("Test connection only checks the key and model; it sends no history. Requests go straight from this Mac to Anthropic with your own key.")
        }
    }

    private func saveModelID() {
        let trimmed = modelIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.preferences.modelID = trimmed
        modelIDInput = trimmed
    }

    // MARK: History

    private var groupingSection: some View {
        let limits = model.analysis.limits
        return Section {
            ForEach(Dataset.allCases) { dataset in
                HStack {
                    Toggle(dataset == .real ? "Group real history" : "Group sample data", isOn: Binding(
                        get: { model.preferences.isAnalysisEnabled(for: dataset) },
                        set: { enabled in
                            if enabled { consentDataset = dataset } else { model.setAnalysisEnabled(false, for: dataset) }
                        }
                    ))
                    Spacer()
                    Text(model.analysis.state(for: dataset).label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            LabeledContent("Used today", value: "\(model.analysis.requestsToday) of \(limits.dailyRequestLimit) requests · about \(model.analysis.tokensToday.formatted()) of \(limits.dailyTokenLimit.formatted()) tokens")
        } header: {
            Text("Automatic grouping")
        } footer: {
            Text("Off until you turn it on, separately for each dataset. Turning it off stops new requests and keeps existing groups. Batches of up to \(limits.batchSize) transcripts start after \(Int(limits.idleDelay.components.seconds)) seconds without dictation, one request at a time, with up to \(limits.maxOutputTokens.formatted()) output tokens each. At the daily limit, grouping pauses until midnight. Failed requests pause until you click Retry.")
        }
    }

    // MARK: History

    private var historySection: some View {
        Section {
            HStack {
                Button("Reset sample data") { model.resetSampleData() }
                Spacer()
                Button("Delete all history…", role: .destructive) { confirmDelete = true }
            }
            if let error = model.storageError {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("History")
        } footer: {
            Text("History and groups stay on this Mac until you delete them. Deleting removes local data only; it can't recall transcripts already sent to Anthropic, which keeps API data under its own retention policy (currently up to 30 days for standard commercial use). Deleted rows aren't securely erased from disk or backups.")
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { model.loginItem.isEnabled },
                set: { model.loginItem.setEnabled($0) }
            ))
            LabeledContent("Status", value: model.loginItem.statusDescription)
            if model.loginItem.status == .requiresApproval {
                Button("Open Login Items settings") { model.loginItem.openSystemSettings() }
            }
            if let error = model.loginItem.lastError {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("General")
        }
    }
}

struct SetupRow<Actions: View>: View {
    let title: String
    let ok: Bool
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions()
        }
    }
}
