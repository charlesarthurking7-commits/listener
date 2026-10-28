import AppKit
import ListenerCore
import SwiftUI

/// The call types on the left, the one picked on the right: how answers should go, and
/// the background Claude reads with every answer.
struct CallTypesView: View {
    let model: CallTypesModel

    var body: some View {
        HStack(spacing: 0) {
            CallTypeList(model: model)
                .frame(width: 290)
            VerticalHairline()
            if let name = model.selected {
                CallTypeEditor(model: model, name: name)
                    .id(name)
            } else {
                Color.clear
            }
        }
    }
}

private struct CallTypeList: View {
    let model: CallTypesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionBar {
                SectionTitle(title: "Call types")
                Spacer()
                Button(action: model.create) {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle())
                .help("New call type")
                .accessibilityLabel("New call type")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("How answers go, and what Claude reads first, for each kind of call.")
                        .font(.geist(12))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    ForEach(model.names, id: \.self) { name in
                        CallTypeRow(
                            name: name, files: model.fileCounts[name] ?? 0, isNext: name == model.call.callType,
                            isOn: name == model.selected
                        ) {
                            model.select(name)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
            }
        }
    }
}

private struct CallTypeRow: View {
    let name: String
    let files: Int
    let isNext: Bool
    let isOn: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                IconTile(symbol: CallTypeIcon.symbol(for: name))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.geist(13, .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if isNext {
                            Text("Next call")
                                .font(.geist(10.5, .semibold))
                                .foregroundStyle(Theme.accentText)
                                .padding(.horizontal, 6)
                                .frame(height: 17)
                                .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                    Text(files == 0 ? "No files" : files == 1 ? "1 file" : "\(files) files")
                        .font(.geist(11.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .rowBackground(isOn: isOn, hovering: hovering, radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A small square behind an icon, at the start of a row.
private struct IconTile: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
            .frame(width: 28, height: 28)
            .background(Theme.selection, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

enum CallTypeIcon {
    static func symbol(for name: String) -> String {
        let name = name.lowercased()
        if name.contains("meeting") || name.contains("sync") || name.contains("stand") {
            return "person.2"
        }
        return "phone"
    }
}

private struct CallTypeEditor: View {
    let model: CallTypesModel
    let name: String
    @State private var editing: CallTypesModel.Note?
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            SectionBar {
                SectionTitle(title: name)
                Spacer()
                if name == model.call.callType {
                    Label("Used for the next call", systemImage: "checkmark")
                        .labelStyle(CompactLabelStyle(spacing: 5))
                        .font(.geist(12, .medium))
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    Button("Use for the next call", action: model.useForNextCall)
                        .buttonStyle(SoftButtonStyle())
                        .disabled(model.call.isCallRunning)
                        .help("The call type the next call starts with. A running call keeps its own.")
                }
                Menu {
                    Button("Rename…") { askForName() }
                    Button("Duplicate", action: model.duplicate)
                    Button("Show in Finder", action: model.revealInFinder)
                    Divider()
                    Button("Move to Bin…", action: model.delete)
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
                VStack(alignment: .leading, spacing: 14) {
                    if let message = model.message {
                        MessageBanner(text: message) { model.message = nil }
                    }
                    instructions
                    background
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.addFiles(urls)
                return true
            } isTargeted: {
                isTargeted = $0
            }
        }
        .sheet(item: $editing) { note in
            NoteEditor(model: model, note: note, callType: name)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "How answers should go") {
                Text("Added to the general rules, and wins where they differ")
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 2)
            TextArea(
                text: Binding(
                    get: { model.texts[.instructions] ?? "" }, set: { model.setText($0, for: .instructions) }),
                label: "How answers should go on a \(name)",
                prompt:
                    "For example: a call with a broker's dealing desk. Keep answers short, and suggest confirming anything about client funds in writing.",
                minHeight: 120, framed: false)
        }
        .card()
    }

    private var background: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Background Claude reads") {
                HStack(spacing: 10) {
                    Text(
                        "\(DisplayFormat.tokens(model.tokens)) of \(DisplayFormat.tokens(CallTypeLibrary.documentBudgetTokens)) tokens"
                    )
                    .font(.geistMono(11))
                    BudgetBar(fraction: Double(model.tokens) / Double(CallTypeLibrary.documentBudgetTokens))
                        .frame(width: 56)
                }
                .help(CallTypeLibrary.budgetNote)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            NoteRow(
                title: "Brief", detail: noteDetail(.brief, empty: "Your own notes for this kind of call"),
                symbol: "square.and.pencil", isEmpty: (model.texts[.brief] ?? "").isEmpty
            ) {
                editing = .brief
            }
            Hairline()
                .padding(.leading, 56)
                .padding(.trailing, 16)
            NoteRow(
                title: "Stories",
                detail: noteDetail(.stories, empty: "Your stories for \u{201C}tell me about a time\u{201D} questions"),
                symbol: "book.closed", isEmpty: (model.texts[.stories] ?? "").isEmpty
            ) {
                editing = .stories
            }
            ForEach(documents) { file in
                Hairline()
                    .padding(.leading, 56)
                    .padding(.trailing, 16)
                FileRow(file: file, model: model)
            }
            DropZone(model: model)
                .padding(.top, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .card()
    }

    /// Every background file but the brief and the stories, which have rows of their own.
    private var documents: [LoadedCallType.File] {
        model.files.filter {
            ![CallTypeLibrary.briefFile, CallTypeLibrary.storiesFile].contains($0.url.lastPathComponent)
        }
    }

    private func noteDetail(_ note: CallTypesModel.Note, empty: String) -> String {
        let file = model.files.first { $0.url.lastPathComponent == note.file }
        if let file, file.problem == nil {
            return "\(DisplayFormat.tokens(file.tokens)) tokens"
        }
        return empty
    }

    private func askForName() {
        let alert = NSAlert()
        alert.messageText = "Rename \(name)"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            model.rename(to: field.stringValue)
        }
    }
}

private struct BudgetBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Theme.selection)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(fraction >= 1 ? Theme.amber : Theme.accent)
                        .frame(width: max(fraction > 0 ? 4 : 0, proxy.size.width * min(fraction, 1)))
                }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct NoteRow: View {
    let title: String
    let detail: String
    let symbol: String
    let isEmpty: Bool
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.geist(13, .medium))
                Text(detail)
                    .font(isEmpty ? .geist(11.5) : .geistMono(11.5))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer(minLength: 8)
            Button(isEmpty ? "Write" : "Edit", action: edit)
                .buttonStyle(SoftButtonStyle(small: true))
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 54)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }
}

private struct FileRow: View {
    let file: LoadedCallType.File
    let model: CallTypesModel

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.geist(13, .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.problem ?? "\(DisplayFormat.tokens(file.tokens)) tokens")
                    .font(file.problem == nil ? .geistMono(11.5) : .geist(11.5))
                    .foregroundStyle(file.problem == nil ? Theme.tertiaryText : Theme.amber)
            }
            Spacer(minLength: 8)
            Button {
                model.remove(file)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .help("Move to the Bin")
            .accessibilityLabel("Remove \(file.name)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 54)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(file) }
        .contextMenu {
            Button("Open") { model.open(file) }
            Button("Show in Finder") { model.reveal(file) }
            Divider()
            Button("Move to Bin") { model.remove(file) }
        }
        .help(help)
    }

    private var symbol: String {
        switch file.url.pathExtension.lowercased() {
        case "pdf", "doc", "docx", "rtf", "rtfd", "odt": "doc.richtext"
        default: "doc.text"
        }
    }

    private var help: String {
        switch file.problem {
        case "Cut to fit", "Left out": CallTypeLibrary.budgetNote
        case "No text found": "No text in this file. A scanned PDF has none; export it as text instead."
        default: file.url.lastPathComponent
        }
    }
}

/// The background card's last row: where files and pasted pages come in.
private struct DropZone: View {
    let model: CallTypesModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 28)
            Text(model.isImportingPage ? "Reading the page…" : "Drop files here, or paste text or a link")
                .font(.geist(12.5))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: model.paste) {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(SoftButtonStyle(small: true))
            .disabled(model.isImportingPage)
            .help("Adds the copied text, files or link")
            Button("Add Files…", action: model.chooseFiles)
                .buttonStyle(SoftButtonStyle(small: true))
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(Theme.hover)
        .overlay(alignment: .top) { Hairline() }
    }
}

/// The brief or the stories in a sheet: a big editor and what the file is for.
private struct NoteEditor: View {
    let model: CallTypesModel
    let note: CallTypesModel.Note
    let callType: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(note.title) for \(callType)")
                    .font(.geist(16, .semibold))
                    .tracking(-0.2)
                Text(hint)
                    .font(.geist(12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextArea(
                text: Binding(get: { model.texts[note] ?? "" }, set: { model.setText($0, for: note) }),
                label: note.title, minHeight: 360)
            HStack {
                Text("Saved as you type")
                    .font(.geist(11.5))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button("Done") {
                    model.saveNow()
                    dismiss()
                }
                .buttonStyle(FilledButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
        .background(Theme.windowBackground)
    }

    private var hint: String {
        switch note {
        case .brief:
            "Who the call is with, what it is for, and anything Listener should know. Claude reads it with every answer."
        case .stories:
            "One block per story: a heading with a short name, a \u{201C}Good for:\u{201D} line with the kinds of question it answers, then Situation, Task, Action and Result. Only real numbers belong here."
        case .instructions:
            "How answers should go on this kind of call."
        }
    }
}

/// A problem with the last action, in the section it happened in.
struct MessageBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.amber)
                .padding(.top, 1)
            Text(text)
                .font(.geist(12.5))
                .lineSpacing(2)
                .foregroundStyle(Theme.proseText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 20))
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 9)
        .panel(Theme.noteFill, radius: Theme.bannerRadius, stroke: Theme.noteBorder)
    }
}
