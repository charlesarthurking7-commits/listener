import ListenerCore
import SwiftUI

/// The live transcript, newest line at the bottom. It follows the newest line until the
/// user scrolls up, then stays put and offers "Jump to latest" until they come back.
///
/// Built to stay cheap for an hour-long call: rows are lazy, equatable and keyed by
/// turn, and settled turns and live text are separate lists that read separate model
/// slices, so interim words redraw only the live rows.
struct TranscriptView: View {
    let model: CallModel
    @State private var followsLatest = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bottom = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SettledRows(model: model)
                    LiveRows(model: model)
                    Color.clear
                        .frame(height: 12)
                        .id(Self.bottom)
                }
                .padding(.horizontal, Theme.gutter)
            }
            .modifier(SoftTopEdge())
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            // While following, growing text and a card appearing above both keep the
            // newest line in place at the bottom. After scrolling up, nothing moves.
            .defaultScrollAnchor(followsLatest ? .bottom : nil, for: .sizeChanges)
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
            .onChange(of: model.transcriptRevision) {
                if followsLatest {
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    JumpToLatestButton {
                        followsLatest = true
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                            proxy.scrollTo(Self.bottom, anchor: .bottom)
                        }
                    }
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: followsLatest)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript")
    }
}

private struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var distanceFromBottom: CGFloat
}

private struct SettledRows: View {
    let model: CallModel

    var body: some View {
        ForEach(model.settledRows) { row in
            TranscriptRowView(row: row)
                .equatable()
        }
    }
}

private struct LiveRows: View {
    let model: CallModel

    var body: some View {
        ForEach(model.liveRows) { row in
            TranscriptRowView(row: row)
                .equatable()
        }
    }
}

/// One turn. The first of a run by the same speaker carries the speaker's name and
/// when they started; text still being recognised is dimmed until it settles.
private struct TranscriptRowView: View, Equatable {
    let row: TranscriptRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if row.showsSpeaker {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.speaker.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(row.speaker.tint)
                    if let start = row.start {
                        Text(DisplayFormat.clock(start))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 16)
            }
            Text(row.text)
                .font(Theme.transcriptFont)
                .lineSpacing(Theme.transcriptLineSpacing)
                .foregroundStyle(row.isInterim ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, row.showsSpeaker ? 14 : 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let speaker = row.speaker.spokenName
        return row.isInterim ? "\(speaker), still speaking: \(row.text)" : "\(speaker): \(row.text)"
    }
}

/// Floats over the transcript, so on macOS 26 it is Liquid Glass; earlier it is a
/// material capsule.
private struct JumpToLatestButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label("Jump to latest", systemImage: "arrow.down")
                .labelStyle(CompactLabelStyle(spacing: 5))
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(FloatingCapsule())
        .help("Follow the newest line again")
    }
}

private struct FloatingCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            materialCapsule(content)
        }
    }

    private func materialCapsule(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

/// Lines scrolling under the answer card fade out instead of being cut off. Uses the
/// system's own scroll edge effect on macOS 26, which costs nothing extra; earlier
/// systems keep the plain edge rather than pay for a mask on every scroll.
private struct SoftTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}
