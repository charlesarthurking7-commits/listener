import ListenerCore
import SwiftUI

/// The words dictation spells exactly, and how dictation behaves.
struct DictionaryView: View {
    @Bindable var model: DictionaryModel
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            SectionBar {
                Text("Dictionary")
                    .font(.geist(15, .semibold))
                    .tracking(-0.15)
                Text("Spellings dictation uses, learned from your fixes")
                    .font(.geist(12))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                Spacer()
                SearchField(prompt: "Find a word", text: $model.query)
                    .frame(width: 220)
                Button {
                    adding = true
                } label: {
                    Label("Add Word", systemImage: "plus")
                }
                .buttonStyle(SoftButtonStyle())
                .popover(isPresented: $adding, arrowEdge: .bottom) {
                    AddWord(model: model, isPresented: $adding)
                }
                Menu {
                    Button("Open dictionary.txt", action: model.openFile)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(IconButtonStyle())
                .fixedSize()
                .accessibilityLabel("More")
            }
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    WordList(model: model)
                    DictationOptions(store: model.store)
                        .frame(width: 300)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
        }
    }
}

private struct WordList: View {
    @Bindable var model: DictionaryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = model.message {
                MessageBanner(text: message) { model.message = nil }
            }
            HStack(spacing: 6) {
                Button {
                    model.filter = .all
                } label: {
                    Text("All ") + Text("\(model.words.count)").font(.geistMono(11))
                }
                .buttonStyle(FilterChipStyle(isOn: model.filter == .all))
                Button {
                    model.filter = .learned
                } label: {
                    Text("Learned ") + Text("\(model.learnedCount)").font(.geistMono(11))
                }
                .buttonStyle(FilterChipStyle(isOn: model.filter == .learned))
                Button {
                    model.filter = .added
                } label: {
                    Text("Added by you ") + Text("\(model.words.count - model.learnedCount)").font(.geistMono(11))
                }
                .buttonStyle(FilterChipStyle(isOn: model.filter == .added))
            }
            if model.words.isEmpty {
                EmptyDictionary()
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        SectionLabel("Word")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SectionLabel("Was heard as")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 24)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 10)
                    .frame(height: 34)
                    .background(Theme.hover)
                    LazyVStack(spacing: 0) {
                        ForEach(model.shown) { word in
                            Hairline()
                            WordRow(word: word) { model.remove(word) }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .card()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct WordRow: View {
    let word: DictionaryModel.Word
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Text(word.term)
                .font(word.term.contains(where: \.isNumber) ? .geistMono(13, .medium) : .geist(13.5, .medium))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch word.source {
                case .learned:
                    HStack(spacing: 6) {
                        ForEach(word.heardAs, id: \.self) { heard in
                            Text(heard)
                                .font(.geist(12))
                                .strikethrough(color: Theme.tertiaryText.opacity(0.6))
                                .foregroundStyle(Theme.secondaryText)
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .panel(Theme.hover, radius: 5)
                                .lineLimit(1)
                        }
                    }
                case .added:
                    Text("Added by you")
                case .settings:
                    Text("In settings.json")
                }
            }
            .font(.geist(12))
            .foregroundStyle(Theme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .opacity(hovering ? 1 : 0.5)
            .help("Forget \(word.term)")
            .accessibilityLabel("Forget \(word.term)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 46)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct EmptyDictionary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No words yet")
                .font(.geist(14, .semibold))
            Text(
                "Dictate with fn twice, then fix a name or term it got wrong in the text. A minute later it is here, and dictation spells it your way from then on. You can also add words yourself."
            )
            .font(.geist(12.5))
            .lineSpacing(2)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct AddWord: View {
    let model: DictionaryModel
    @Binding var isPresented: Bool
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spell it exactly like this")
                .font(.geist(13, .semibold))
            TextField("A name or term, e.g. Kestrelmoor", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.geist(13))
                .frame(width: 260)
                .onSubmit(add)
            HStack {
                Text("Several at once: separate them with commas")
                    .font(.geist(11))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button("Add", action: add)
                    .buttonStyle(FilledButtonStyle(small: true))
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func add() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        model.add(text)
        isPresented = false
    }
}

/// How much has been dictated: words, speed and dictations, then this week's words.
/// Dictation's own settings, next to the words it uses.
private struct DictationOptions: View {
    let store: SettingsStore

    var body: some View {
        let dictation = store.settings.dictation
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Dictation")
                Spacer()
                HStack(spacing: 4) {
                    Keycap(label: "fn")
                    Keycap(label: "fn")
                    Text("to start, fn to stop")
                        .font(.geist(11.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .frame(height: 24)
            VStack(spacing: 0) {
                OptionSwitch(
                    title: "Tidy up with Claude",
                    detail: "Fillers out, false starts fixed, set out the way you'd type it. About $0.003 each.",
                    isOn: dictation.tidy
                ) { store.set($0, at: "dictation.tidy") }
                Hairline()
                OptionSwitch(
                    title: "Paste lists as lists",
                    detail: "Real bullets and numbers in Outlook, Teams, Notes and Slack.",
                    isOn: dictation.formattedLists
                ) { store.set($0, at: "dictation.formattedLists") }
                Hairline()
                OptionSwitch(
                    title: "Learn from my fixes",
                    detail:
                        "For a minute after it types, a name you correct becomes a spelling. The text is read on this Mac only.",
                    isOn: dictation.learnWords
                ) { store.set($0, at: "dictation.learnWords") }
                Hairline()
                OptionSwitch(title: "Sounds", detail: "A sound when it starts and stops.", isOn: dictation.sounds) {
                    store.set($0, at: "dictation.sounds")
                }
            }
            .card()
            VStack(spacing: 0) {
                OptionMenu(
                    title: "Microphone",
                    detail: dictation.microphone == "built-in" ? "AirPods keep playing in full quality" : nil,
                    value: dictation.microphone == "built-in" ? "Built-in" : "System default"
                ) {
                    Button("Built-in") { store.set("built-in", at: "dictation.microphone") }
                    Button("System default") { store.set("default", at: "dictation.microphone") }
                }
                Hairline()
                OptionMenu(
                    title: "Speech to text", detail: "On this Mac, free",
                    value: dictation.recognizer == "parakeet" ? "Parakeet" : "Apple"
                ) {
                    Button("Parakeet (more accurate)") { store.set("parakeet", at: "dictation.recognizer") }
                    Button("Apple") { store.set("apple", at: "dictation.recognizer") }
                }
                Hairline()
                OptionSwitch(
                    title: "Dictate with fn twice",
                    detail: dictation.enabled == store.atLaunch.dictation.enabled
                        ? "Into any app, wherever the cursor is." : "Takes effect when Listener next starts.",
                    isOn: dictation.enabled
                ) { store.set($0, at: "dictation.enabled") }
            }
            .card()
            if let message = store.message {
                Text(message)
                    .font(.geist(11.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A setting that is on or off, with what it does under its name.
struct OptionSwitch: View {
    let title: String
    var detail: String?
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.geist(13, .medium))
                    .foregroundStyle(Theme.text)
                if let detail {
                    Text(detail)
                        .font(.geist(11.5))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(SwitchStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityLabel(title)
        .accessibilityHint(detail ?? "")
    }
}

/// A setting picked from a short list.
struct OptionMenu<Content: View>: View {
    let title: String
    var detail: String?
    let value: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.geist(13, .medium))
                if let detail {
                    Text(detail)
                        .font(.geist(11.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            SelectMenu(title: value, label: title, content: content)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
