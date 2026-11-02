import SwiftUI

/// A plain text field for trying the keyboard; under "More practice", folded away at first, the destination-binding test
/// and the cursor practice. The text lives in view state only and is gone when the screen closes.
struct TryItView: View {
    @EnvironmentObject private var host: HostSessionController
    @State private var fieldA = ""
    @State private var fieldB = ""
    @State private var practice = Self.practiceSample
    @State private var showsMore = false
    @FocusState private var focus: Field?

    private enum Field { case a, b, practice }

    /// Invented text for cursor tests: long sentences that wrap softly on a phone, short lines and
    /// hard line breaks, a blank line, and emoji, accents and numbers for word deletion.
    static let practiceSample = """
        Cursor practice. This first paragraph is one long sentence, written so that it wraps across several lines on a phone, which gives the cursor soft line breaks to cross without leaving the paragraph.
        Short line.
        Another short line with a typo: teh quick brown fox.

        After a blank line comes the last paragraph, with numbers like 3.14 and 1,200, a thumbs-up \u{1F44D}\u{1F3FD}, a flag \u{1F1EB}\u{1F1F7} and an accented cafe\u{301}, for word deletion and emoji tests.
        """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DictationCue()
                field("Field A", text: $fieldA, field: .a, identifier: "tryit.fieldA")

                if host.session != .active {
                    Label("No session yet: Start on the keyboard opens one.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryInk)
                }

                moreToggle
                    .padding(.top, 6)
                if showsMore { more }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.screenBackground.ignoresSafeArea())
        .navigationTitle("Try it")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") {
                    fieldA = ""
                    fieldB = ""
                }
                .disabled(fieldA.isEmpty && fieldB.isEmpty)
            }
        }
        .onAppear { host.tryItVisible = true }
        .onDisappear { host.tryItVisible = false }
    }

    /// "More practice": a chevron that turns as the group opens.
    private var moreToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { showsMore.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .rotationEffect(.degrees(showsMore ? 90 : 0))
                    .accessibilityHidden(true)
                Text("More practice")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.secondaryInk)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsMore ? "Shown" : "Hidden")
        .accessibilityIdentifier("tryit.more")
    }

    @ViewBuilder
    private var more: some View {
        practiceHeader("Destination test", symbol: "arrow.left.arrow.right")
        field("Field B", text: $fieldB, field: .b, identifier: "tryit.fieldB")
        Text("Start in A, then tap B before the text arrives. It stays out of B; the keyboard offers **Insert last** instead.")
            .font(.footnote)
            .foregroundStyle(Theme.secondaryInk)

        HStack {
            practiceHeader("Cursor practice", symbol: "text.cursor")
            Spacer()
            Button("Reset text") { practice = Self.practiceSample }
                .font(.footnote)
                .disabled(practice == Self.practiceSample)
        }
        .padding(.top, 10)
        TextEditor(text: $practice)
            .focused($focus, equals: .practice)
            .frame(height: 220)
            .padding(8)
            .scrollContentBackground(.hidden)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(focusEdge(.practice, cornerRadius: 16))
            .accessibilityIdentifier("tryit.practice")
        Text("Touch and hold the space bar, then slide to move the cursor.")
            .font(.footnote)
            .foregroundStyle(Theme.secondaryInk)
    }

    private func practiceHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.secondaryInk)
            .accessibilityAddTraits(.isHeader)
    }

    private func focusEdge(_ field: Field, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(focus == field ? 0.5 : 0), lineWidth: 1)
    }

    private func field(_ title: String, text: Binding<String>, field: Field, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryInk)
                .accessibilityHidden(true)
            TextField("Tap here and dictate…", text: text, axis: .vertical)
                .lineLimit(3...8)
                .focused($focus, equals: field)
                .padding(14)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(focusEdge(field, cornerRadius: 16))
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// How to dictate, as the keyboard shows it: the globe key, Start with the mark, speaking, Stop. In a row of glyphs, or
/// numbered lines where the row does not fit (large text).
private struct DictationCue: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                chip { Image(systemName: "globe") }
                arrow
                chip { HStack(spacing: 6) { RidgeMarkView(side: 17); Text("Start") } }
                arrow
                Image(systemName: "waveform").font(.body.weight(.medium))
                arrow
                chip { Label("Stop", systemImage: "stop.fill").labelStyle(AccentGlyphLabelStyle()) }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                HowToRow(number: 1, text: "Switch to the LocalFlow keyboard with \(Image(systemName: "globe"))")
                HowToRow(number: 2, text: "Tap **Start** and speak")
                HowToRow(number: 3, text: "Tap **Stop**")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(16)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tap a field, switch to the LocalFlow keyboard with the globe key, tap Start, speak, then tap Stop.")
        .accessibilityIdentifier("tryit.cue")
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.secondaryInk)
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .islandSurface()
    }
}

private struct HowToRow: View {
    var number: Int
    var text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            NumberBadge(number: number)
            Text(text).font(.subheadline.weight(.regular))
        }
    }
}
