import ListenerCore
import SwiftUI

/// Before a call: what kind of call it is, and the background Claude reads with every
/// answer. Nothing here needs the keyboard, so the window never takes it: a menu for the
/// call type, files dropped onto the card, Paste for copied text or a link, and the
/// brief and stories in TextEdit.
struct CallSetupCard: View {
    let model: CallModel
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            if model.callFiles.isEmpty {
                Text("Drop a CV or other files here, or copy a job description or its link and press Paste.")
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(model.callFiles.enumerated()), id: \.element.id) { index, file in
                    if index > 0 {
                        Hairline()
                            .padding(.leading, 36)
                    }
                    FileRow(file: file) { model.removeCallFile(file.url) }
                }
            }
            Hairline()
            actions
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Theme.cardStroke, lineWidth: isTargeted ? 1.5 : 0.5)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return true
        } isTargeted: {
            isTargeted = $0
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This call")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("This call")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            Menu {
                ForEach(model.callTypes, id: \.self) { name in
                    Button {
                        model.selectCallType(name)
                    } label: {
                        if name == model.callType {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                Divider()
                Button("Edit Instructions", action: model.editCallTypeInstructions)
                Button("Edit Stories", action: model.editStories)
                Button("Show in Finder", action: model.revealCallTypes)
            } label: {
                Text(model.callType)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The kind of call: it changes how answers go")
            .accessibilityLabel("Call type: \(model.callType)")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: model.pasteFromClipboard) {
                Label(model.isImportingPage ? "Reading Page…" : "Paste", systemImage: "doc.on.clipboard")
            }
            .disabled(model.isImportingPage)
            .help("Adds the copied text, files or link")
            Button(action: model.editBrief) {
                Label("Edit Brief", systemImage: "square.and.pencil")
            }
            .help("Your notes for this call, in TextEdit")
            Spacer(minLength: 8)
            let tokens = model.callFiles.reduce(0) { $0 + $1.tokens }
            if tokens > 0 {
                Text("\(DisplayFormat.tokens(tokens)) tokens")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help(CallTypeLibrary.budgetNote)
            }
        }
        .buttonStyle(SoftButtonStyle(small: true))
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

private struct FileRow: View {
    let file: LoadedCallType.File
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(file.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(file.problem ?? "\(DisplayFormat.tokens(file.tokens)) tokens")
                .font(.system(size: 11))
                .foregroundStyle(file.problem == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 20))
            .help("Move to the Bin")
            .accessibilityLabel("Remove \(file.name)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 30)
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch file.url.lastPathComponent {
        case CallTypeLibrary.briefFile: return "note.text"
        case CallTypeLibrary.storiesFile: return "text.book.closed"
        default: break
        }
        return switch file.url.pathExtension.lowercased() {
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
