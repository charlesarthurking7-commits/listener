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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel("This call")
                Spacer(minLength: 8)
                callTypeMenu
            }
            VStack(spacing: 0) {
                ForEach(model.callFiles) { file in
                    FileRow(file: file) { model.removeCallFile(file.url) }
                    Hairline()
                }
                dropZone
                    .padding(10)
            }
            .panel(
                Theme.surface, radius: Theme.cardRadius, stroke: isTargeted ? Theme.accent : Theme.border,
                lineWidth: isTargeted ? 1.5 : 1
            )
            .dropDestination(for: URL.self) { urls, _ in
                model.addFiles(urls)
                return true
            } isTargeted: {
                isTargeted = $0
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This call")
    }

    private var callTypeMenu: some View {
        SelectMenu(title: model.callType, label: "Call type") {
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
        }
        .fixedSize()
        .help("The kind of call: it changes how answers go")
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            Text(
                model.callFiles.isEmpty
                    ? "Drop a CV or notes here, or copy a job description or its link and paste it."
                    : "Drop more files here, or paste text or a link."
            )
            .font(.geist(12.5))
            .lineSpacing(2)
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
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
            }
            .buttonStyle(SoftButtonStyle(small: true))
            let tokens = model.callFiles.reduce(0) { $0 + $1.tokens }
            if tokens > 0 {
                Text(
                    "\(DisplayFormat.tokens(tokens)) of \(DisplayFormat.tokens(CallTypeLibrary.documentBudgetTokens)) tokens of background"
                )
                .font(.geistMono(11))
                .foregroundStyle(Theme.tertiaryText)
                .help(CallTypeLibrary.budgetNote)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.strongBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}

private struct FileRow: View {
    let file: LoadedCallType.File
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 16)
            Text(file.name)
                .font(.geist(13, .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(file.problem ?? "\(DisplayFormat.tokens(file.tokens)) tokens")
                .font(file.problem == nil ? .geistMono(11) : .geist(12))
                .foregroundStyle(file.problem == nil ? Theme.tertiaryText : Theme.amber)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .help("Move to the Bin")
            .accessibilityLabel("Remove \(file.name)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 40)
        // After combining, or VoiceOver reads the tooltip once for every part of the row.
        .accessibilityElement(children: .combine)
        .help(help)
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
