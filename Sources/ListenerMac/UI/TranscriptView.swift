import ListenerCore
import SwiftUI

/// The live transcript. It follows the newest line until the user scrolls up, then
/// stays put and offers "Jump to latest" until they come back to the bottom.
struct TranscriptView: View {
    let model: CallModel

    var body: some View {
        if model.state.rows.isEmpty {
            EmptyTranscript(model: model)
        } else {
            TranscriptList(rows: model.state.rows)
        }
    }
}

private struct TranscriptList: View {
    let rows: [TranscriptRow]
    @State private var followsLatest = true

    private static let bottom = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        TranscriptRowView(row: row)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottom)
                }
                .padding(.horizontal, Theme.padding)
                .padding(.vertical, 10)
            }
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y,
                    distanceFromBottom: geometry.contentSize.height - geometry.visibleRect.maxY
                )
            } action: { old, new in
                if new.distanceFromBottom <= 24 {
                    followsLatest = true
                } else if new.offset < old.offset - 1 {
                    // Only scrolling up unpins. New lines make the distance grow
                    // without moving the offset, and must not stop the following.
                    followsLatest = false
                }
            }
            // A settled turn can land above the live line without changing the last row,
            // so the row count matters too.
            .onChange(of: rows.count) {
                followLatest(proxy)
            }
            .onChange(of: rows.last) {
                followLatest(proxy)
            }
            .onAppear {
                proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.bottom, anchor: .bottom)
                        }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(FilledButtonStyle(tint: .accentColor, compact: true))
                    .shadow(radius: 4, y: 2)
                    .padding(12)
                    .transition(.opacity)
                }
            }
        }
    }
}

extension TranscriptList {
    fileprivate func followLatest(_ proxy: ScrollViewProxy) {
        if followsLatest {
            proxy.scrollTo(Self.bottom, anchor: .bottom)
        }
    }
}

private struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var distanceFromBottom: CGFloat
}

private struct TranscriptRowView: View {
    let row: TranscriptRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SpeakerChip(speaker: row.speaker)
                .opacity(row.showsSpeaker ? 1 : 0)
                .accessibilityHidden(!row.showsSpeaker)
            Text(row.text)
                .font(Theme.transcriptFont)
                .foregroundStyle(row.isInterim ? .secondary : .primary)
                .italic(row.isInterim)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, row.showsSpeaker ? 8 : 0)
        .accessibilityElement(children: .combine)
    }
}

/// Before the first call: the setup checklist. While listening with nothing said
/// yet: a hint that the transcript will appear here.
private struct EmptyTranscript: View {
    let model: CallModel

    var body: some View {
        switch model.state.phase {
        case .starting, .listening:
            if case .downloading(let fraction) = model.onDeviceSpeech {
                ContentUnavailableView(
                    "Getting speech recognition ready",
                    systemImage: "arrow.down.circle",
                    description: Text(
                        "macOS is downloading the on-device speech model (\(Int((fraction * 100).rounded()))%).")
                )
            } else {
                ContentUnavailableView(
                    "Listening",
                    systemImage: "waveform",
                    description: Text("The transcript appears here as people speak.")
                )
            }
        case .stopping, .summarizing:
            ContentUnavailableView("Nothing was said", systemImage: "waveform.slash")
        case .idle, .finished:
            ScrollView {
                SetupChecklist(model: model)
                    .padding(Theme.padding)
            }
        }
    }
}
