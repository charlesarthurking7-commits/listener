import AppKit
import ListenerCore
import SwiftUI

/// Settings, a page at a time. Every change is saved to settings.json at once; the
/// floating window's own looks are kept with the app's preferences, as before.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                SectionBar {
                    Text("Settings")
                        .font(.geist(15, .semibold))
                        .tracking(-0.15)
                    Spacer()
                }
                .padding(.horizontal, -12)
                .padding(.bottom, 12)
                ForEach(SettingsModel.Page.allCases) { page in
                    PageRow(page: page, isOn: model.page == page) { model.page = page }
                }
                Spacer()
                Button(action: model.openSettingsFile) {
                    Label("Open settings.json", systemImage: "curlybraces")
                        .labelStyle(CompactLabelStyle(spacing: 7))
                        .font(.geist(12))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                }
                .buttonStyle(.plain)
                .help(model.store.file.path)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .frame(width: 210)
            VerticalHairline()
            VStack(spacing: 0) {
                SectionBar {
                    Text(model.page.title)
                        .font(.geist(15, .semibold))
                        .tracking(-0.15)
                    Spacer()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if let problem = model.store.problem {
                            MessageBanner(
                                text:
                                    "settings.json can't be read, so nothing here is saved until it is fixed: \(problem)"
                            ) {}
                        }
                        if let message = model.store.message {
                            MessageBanner(text: message) { model.store.message = nil }
                        }
                        page
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onDisappear(perform: model.saveContext)
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .general: GeneralPage(model: model)
        case .answers: AnswersSettingsPage(model: model)
        case .speech: SpeechPage(model: model)
        case .shortcuts: ShortcutsPage(model: model)
        case .storage: StoragePage(model: model)
        case .apiKey: KeyPage(model: model)
        }
    }
}

private struct PageRow: View {
    let page: SettingsModel.Page
    let isOn: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(page.title)
                Spacer(minLength: 0)
            }
            .font(.geist(13, .medium))
            .foregroundStyle(isOn || hovering ? Theme.text : Theme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                isOn ? Theme.selection : hovering ? Theme.hover : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A titled group of settings in one card.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title)
                Spacer()
                if let note {
                    Text(note)
                        .font(.geist(11.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            VStack(spacing: 0) {
                content()
            }
            .card()
        }
    }
}

// MARK: General

private struct GeneralPage: View {
    let model: SettingsModel

    var body: some View {
        let window = model.settings.window
        let call = model.call
        SettingsGroup(title: "Floating window") {
            OptionMenu(
                title: "Look", detail: lookDetail(call.transparency), value: call.transparency.title
            ) {
                ForEach(WindowTransparency.allCases, id: \.self) { look in
                    Button(look.title) { call.setTransparency(look) }
                }
            }
            Hairline()
            OptionSlider(
                title: "Opacity", value: window.opacity, range: 0.2...1, format: { "\(Int(($0 * 100).rounded()))%" }
            ) { model.store.set(($0 * 100).rounded() / 100, at: "window.opacity") }
            Hairline()
            OptionSwitch(
                title: "Always on top", detail: "Stays above other windows, full-screen calls included.",
                isOn: window.alwaysOnTop
            ) { model.store.set($0, at: "window.alwaysOnTop") }
            Hairline()
            OptionSwitch(
                title: "Show the transcript during calls",
                detail: "Off, a call is just the bar and the answer, so it stays out of the way.",
                isOn: call.showsTranscriptInCall
            ) { _ in call.toggleTranscriptInCall() }
        }
        SettingsGroup(title: "App") {
            OptionSwitch(
                title: "Keep Listener in the Dock",
                detail: "Off, it lives in the menu bar and shows in the Dock only while this window is open.",
                isOn: window.showDockIcon
            ) { model.store.set($0, at: "window.showDockIcon") }
        }
    }

    private func lookDetail(_ look: WindowTransparency) -> String {
        switch look {
        case .solid: "Opaque, the easiest to read."
        case .glass: "Blurs what is behind it."
        case .clear: "See-through, and fades between answers in a call."
        }
    }
}

// MARK: Answers

private struct AnswersSettingsPage: View {
    let model: SettingsModel

    var body: some View {
        let answers = model.settings.answers
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("About you and your calls")
                Spacer()
                Text("Sent with every answer and summary")
                    .font(.geist(11.5))
                    .foregroundStyle(Theme.tertiaryText)
            }
            TextArea(
                text: Binding(get: { model.context }, set: { model.setContext($0) }), label: "About you and your calls",
                prompt:
                    "For example: I'm an operations engineer at a trading platform. My calls are with brokers about fills, outages and connectivity. Keep answers short enough to say out loud.",
                minHeight: 130, font: .geist(13))
            Text(
                "Who you are, what your calls are about and how you like answers. Each call type can add its own instructions."
            )
            .font(.geist(11.5))
            .foregroundStyle(Theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        SettingsGroup(title: "Models") {
            ModelRow(
                model: model, title: "Quick", detail: "A line to say, fast", symbol: AnswerTier.quick.symbol,
                settings: answers.quick, path: "answers.quick")
            Hairline()
            ModelRow(
                model: model, title: "Deep", detail: "A fuller answer with detail", symbol: AnswerTier.deep.symbol,
                settings: answers.deep, path: "answers.deep")
            Hairline()
            ModelRow(
                model: model, title: "Recap", detail: "Where the call has got to", symbol: AnswerTier.recap.symbol,
                settings: answers.recap, path: "answers.recap")
        }
        SettingsGroup(title: "During a call") {
            OptionMenu(
                title: "Conversation sent with each answer",
                detail: "More remembers further back, and costs a little more per answer.",
                value: "\(DisplayFormat.tokens(answers.transcriptBudgetTokens)) tokens"
            ) {
                ForEach([4_000, 8_000, 16_000, 32_000], id: \.self) { tokens in
                    Button(budgetTitle(tokens)) { model.store.set(tokens, at: "answers.transcriptBudgetTokens") }
                }
            }
            Hairline()
            OptionSwitch(
                title: "Start answers early",
                detail:
                    "Drafts a quick answer each time they stop talking, so it shows the moment you press the key. A fraction of a cent a turn.",
                isOn: answers.draftAhead
            ) { model.store.set($0, at: "answers.draftAhead") }
        }
        SettingsGroup(title: "After a call") {
            OptionSwitch(
                title: "Write a summary",
                detail: "Decisions, action items, open questions and a follow-up email.",
                isOn: model.settings.summary.enabled
            ) { model.store.set($0, at: "summary.enabled") }
            if model.settings.summary.enabled {
                Hairline()
                ModelRow(
                    model: model, title: "Summary", detail: nil, symbol: "doc.text",
                    settings: model.settings.summary.model, path: "summary.model")
            }
        }
    }

    private func budgetTitle(_ tokens: Int) -> String {
        let minutes = tokens / 400
        return "\(DisplayFormat.tokens(tokens)) tokens, about \(minutes) minutes"
    }
}

/// One kind of answer's model, effort and thinking.
private struct ModelRow: View {
    let model: SettingsModel
    let title: String
    let detail: String?
    let symbol: String
    let settings: ModelSettings
    let path: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 28, height: 28)
                .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.geist(13, .medium))
                if let detail {
                    Text(detail)
                        .font(.geist(11.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            Spacer(minLength: 8)
            SelectMenu(title: DisplayFormat.modelName(settings.model), label: "\(title) model") {
                ForEach(models, id: \.self) { id in
                    Button(DisplayFormat.modelName(id)) { update { $0.model = id } }
                }
            }
            .frame(width: 124)
            SelectMenu(title: settings.effort.capitalized, label: "\(title) effort") {
                ForEach(efforts, id: \.self) { effort in
                    Button(effort.capitalized) { update { $0.effort = effort } }
                }
            }
            .frame(width: 96)
            SelectMenu(title: settings.thinking == .off ? "No thinking" : "Thinks", label: "\(title) thinking") {
                Button("No thinking") { update { $0.thinking = .off } }
                Button("Thinks when it helps") { update { $0.thinking = .adaptive } }
            }
            .frame(width: 116)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var models: [String] {
        let known = model.models
        return known.contains(settings.model) ? known : known + [settings.model]
    }

    private var efforts: [String] {
        let known = ["low", "medium", "high"]
        return known.contains(settings.effort) ? known : known + [settings.effort]
    }

    private func update(_ change: (inout ModelSettings) -> Void) {
        var changed = settings
        change(&changed)
        model.setModel(changed, at: path)
    }
}

// MARK: Speech

private struct SpeechPage: View {
    let model: SettingsModel

    var body: some View {
        let speech = model.settings.speech
        SettingsGroup(title: "Speech to text", note: "Changes apply from the next call") {
            OptionMenu(
                title: "Recognition", detail: providerDetail(speech.provider), value: providerTitle(speech.provider)
            ) {
                Button("Automatic") { model.store.set("auto", at: "speech.provider") }
                Button("On this Mac") { model.store.set("apple", at: "speech.provider") }
                Button("Google Cloud") { model.store.set("google", at: "speech.provider") }
            }
            Hairline()
            OptionMenu(title: "Language", detail: nil, value: languageTitle(speech.languageCode)) {
                ForEach(Self.languages, id: \.code) { language in
                    Button(language.name) { model.store.set(language.code, at: "speech.languageCode") }
                }
            }
            Hairline()
            OptionSlider(
                title: "Pause that ends a turn", value: Double(model.settings.turns.silenceMs), range: 300...1500,
                format: { "\(Int(($0 / 50).rounded()) * 50) ms" }
            ) { model.store.set(Int(($0 / 50).rounded()) * 50, at: "turns.silenceMs") }
        }
        if speech.provider == "google" {
            SettingsGroup(title: "Google Cloud") {
                OptionField(title: "Project", value: speech.googleProjectID ?? "", prompt: "your-gcp-project-id") {
                    model.store.set($0.isEmpty ? nil : JSONValue.string($0), at: "speech.googleProjectID")
                }
                Hairline()
                OptionField(title: "Location", value: speech.googleLocation, prompt: "eu") {
                    model.store.set($0, at: "speech.googleLocation")
                }
                Hairline()
                OptionField(title: "Model", value: speech.model, prompt: "chirp_3") {
                    model.store.set($0, at: "speech.model")
                }
                Hairline()
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Credentials")
                            .font(.geist(13, .medium))
                        Text(speech.googleCredentialsFile ?? "Application Default Credentials")
                            .font(.geistMono(11))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if speech.googleCredentialsFile != nil {
                        Button("Default") { model.store.set(nil, at: "speech.googleCredentialsFile") }
                            .buttonStyle(SoftButtonStyle(small: true))
                    }
                    Button("Choose…", action: model.chooseCredentialsFile)
                        .buttonStyle(SoftButtonStyle(small: true))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
        SettingsGroup(title: "Audio") {
            OptionMenu(
                title: "System audio", detail: "How the other side of the call is heard.",
                value: model.settings.capture.systemAudioBackend == "sck" ? "Screen capture" : "Audio tap"
            ) {
                Button("Audio tap") { model.store.set("tap", at: "capture.systemAudioBackend") }
                Button("Screen capture") { model.store.set("sck", at: "capture.systemAudioBackend") }
            }
            Hairline()
            OptionSwitch(
                title: "Echo cancellation",
                detail: "Only for calls on speakers, where the microphone hears the other side too.",
                isOn: model.settings.capture.voiceProcessing
            ) { model.store.set($0, at: "capture.voiceProcessing") }
        }
    }

    private static let languages: [(code: String, name: String)] = [
        ("en-GB", "English (UK)"), ("en-US", "English (US)"), ("en-IE", "English (Ireland)"),
        ("en-AU", "English (Australia)"), ("en-IN", "English (India)"), ("fr-FR", "French"), ("de-DE", "German"),
        ("es-ES", "Spanish"), ("it-IT", "Italian"), ("nl-NL", "Dutch"), ("pt-PT", "Portuguese"),
    ]

    private func languageTitle(_ code: String) -> String {
        Self.languages.first { $0.code == code }?.name ?? code
    }

    private func providerTitle(_ provider: String) -> String {
        switch provider {
        case "apple": "On this Mac"
        case "google": "Google Cloud"
        case "fake": "Scripted"
        default: "Automatic"
        }
    }

    private func providerDetail(_ provider: String) -> String {
        switch provider {
        case "apple": "Free, and nothing leaves this Mac."
        case "google": "Chirp 3 in Google's EU region, billed by the minute."
        default: "On this Mac where it can, otherwise Google Cloud."
        }
    }
}

// MARK: Shortcuts

private struct ShortcutsPage: View {
    let model: SettingsModel

    var body: some View {
        SettingsGroup(title: "Shortcuts", note: "Work in any app") {
            ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 {
                    Hairline()
                }
                HStack(spacing: 14) {
                    Text(action.title.prefix(1).uppercased() + action.title.dropFirst())
                        .font(.geist(13, .medium))
                    Spacer()
                    if model.call.activeHotkeys[action] == nil, model.recording != action {
                        Text("Taken by another app")
                            .font(.geist(11.5))
                            .foregroundStyle(Theme.amber)
                            .help(
                                "macOS wouldn't give Listener this shortcut, usually because another app has it. Pick another."
                            )
                    }
                    ShortcutRecorder(model: model, action: action)
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
            }
            Hairline()
            HStack(spacing: 14) {
                Text("Dictate")
                    .font(.geist(13, .medium))
                Spacer()
                HStack(spacing: 4) {
                    Keycap(label: "fn", large: true)
                    Keycap(label: "fn", large: true)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
        }
        Text("Click a shortcut, then press the keys you want. Escape cancels.")
            .font(.geist(12))
            .foregroundStyle(Theme.tertiaryText)
    }
}

/// Shows a shortcut, and records a new one when clicked.
private struct ShortcutRecorder: View {
    let model: SettingsModel
    let action: HotkeyAction
    @State private var monitor: Any?

    var body: some View {
        let recording = model.recording == action
        HStack(spacing: 6) {
            Button {
                if recording {
                    model.stopRecording()
                } else {
                    model.startRecording(action)
                }
            } label: {
                Group {
                    if recording {
                        Text("Type the shortcut…")
                            .font(.geist(12, .medium))
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 10)
                    } else if let hotkey = try? Hotkey(parsing: model.settings.hotkeys.binding(for: action)) {
                        HotkeyKeycaps(hotkey: hotkey, large: true)
                            .padding(.horizontal, 4)
                    } else {
                        Text("None").foregroundStyle(Theme.tertiaryText).padding(.horizontal, 10)
                    }
                }
                .frame(minWidth: 110, minHeight: 30)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(recording ? Theme.accent : Theme.border, lineWidth: recording ? 1.5 : 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(action.title) shortcut")
            if model.settings.hotkeys.binding(for: action) != Settings().hotkeys.binding(for: action) {
                Button {
                    model.resetShortcut(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Back to the default")
                .accessibilityLabel("Reset \(action.title)")
            }
        }
        .onChange(of: recording, initial: true) { _, isRecording in
            if isRecording {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    model.record(keyCode: event.keyCode, modifiers: event.modifierFlags)
                    return nil
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
        .onDisappear {
            if recording {
                model.stopRecording()
            }
        }
    }
}

// MARK: Storage and privacy

private struct StoragePage: View {
    let model: SettingsModel

    var body: some View {
        let storage = model.settings.storage
        SettingsGroup(title: "Calls") {
            OptionMenu(
                title: "Keep calls for", detail: "Older calls are deleted when Listener starts.",
                value: storage.retentionDays <= 0 ? "Forever" : "\(storage.retentionDays) days"
            ) {
                ForEach([7, 14, 30, 90, 365], id: \.self) { days in
                    Button("\(days) days") { model.store.set(days, at: "storage.retentionDays") }
                }
                Divider()
                Button("Forever") { model.store.set(0, at: "storage.retentionDays") }
            }
            Hairline()
            OptionSwitch(
                title: "Keep the audio",
                detail: "Saves both sides as WAV files with each call. Off, only the words are kept.",
                isOn: storage.saveAudio
            ) { model.store.set($0, at: "storage.saveAudio") }
            Hairline()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Folder")
                        .font(.geist(13, .medium))
                    Text(model.sessionsFolder)
                        .font(.geistMono(11))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                if storage.directory != nil {
                    Button("Default", action: model.resetSessionsFolder)
                        .buttonStyle(SoftButtonStyle(small: true))
                }
                Button("Change…", action: model.chooseSessionsFolder)
                    .buttonStyle(SoftButtonStyle(small: true))
                Button {
                    model.call.openSessionsFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        SettingsGroup(title: "Screen sharing") {
            OptionSwitch(
                title: "Hide the floating window when sharing",
                detail: "Sharing your whole screen leaves the window out. Screenshots do too.",
                isOn: model.call.hidesFromScreenSharing
            ) { _ in model.call.toggleHidingFromScreenSharing() }
        }
    }
}

// MARK: API key

private struct KeyPage: View {
    let model: SettingsModel
    @State private var key = ""

    var body: some View {
        SettingsGroup(title: "Anthropic") {
            HStack(spacing: 12) {
                Circle()
                    .fill(model.keySource == nil ? Theme.amber : Theme.ready)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.keySource == nil ? "No API key" : "API key found")
                        .font(.geist(13, .medium))
                    Text(model.keySource.map { "In \($0)" } ?? "Answers, summaries and tidied dictation need one.")
                        .font(.geist(11.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                if model.keySource == "Keychain" {
                    Button("Remove…", action: model.removeKey)
                        .buttonStyle(SoftButtonStyle(small: true))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Hairline()
            HStack(spacing: 8) {
                SecureField(
                    model.keySource == nil ? "Paste your key, sk-ant-…" : "Paste a new key to replace it", text: $key
                )
                .textFieldStyle(.plain)
                .font(.geistMono(12))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
                }
                .onSubmit(save)
                Button("Save", action: save)
                    .buttonStyle(FilledButtonStyle(small: true))
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.keyMessage {
                Text(message)
                    .font(.geist(12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Text("Listener keeps the key in your login Keychain and sends it only to Anthropic, with each request.")
                .font(.geist(12))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Get a key from the Anthropic Console", action: model.openConsole)
                .buttonStyle(LinkButtonStyle())
        }
    }

    private func save() {
        model.saveKey(key)
        key = ""
    }
}

// MARK: Controls

/// A number picked on a slider, saved when the slider is let go.
private struct OptionSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let set: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.geist(13, .medium))
            Spacer(minLength: 8)
            Slider(value: binding, in: range) { editing in
                commit(editing)
            }
            .controlSize(.small)
            .frame(width: 200)
            Text(format(dragging ?? value))
                .font(.geistMono(11.5))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var binding: Binding<Double> {
        Binding(get: { dragging ?? value }, set: { dragging = $0 })
    }

    private func commit(_ editing: Bool) {
        guard !editing, let dragging else {
            return
        }
        set(dragging)
        self.dragging = nil
    }
}

/// A line of text, saved when the field is left or Return is pressed.
private struct OptionField: View {
    let title: String
    let value: String
    let prompt: String
    let set: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.geist(13, .medium))
            Spacer(minLength: 8)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.geistMono(12))
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .frame(width: 240)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused {
                        commit()
                    }
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .onAppear { text = value }
        .onChange(of: value) { _, new in
            if !focused {
                text = new
            }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed != value {
            set(trimmed)
        }
    }
}
