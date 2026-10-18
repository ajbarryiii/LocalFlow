import SwiftUI
import UIKit

/// The TestFlight typing test (ARCHITECTURE.md, "Typing test"): type an invented passage with LocalFlow or
/// Apple's keyboard, without correcting, and see what was dropped, wrong or extra. Attempts and the typed
/// text stay in memory. Remove before the first production release, with the typing counters.
struct TypingTestView: View {
    let settings: LocalFlowSettings?

    enum Keyboard: String, CaseIterable, Identifiable {
        case localFlow = "LocalFlow", apple = "Apple"
        var id: String { rawValue }
    }

    private struct Attempt: Identifiable {
        let id = UUID()
        let keyboard: Keyboard
        let passage: String
        let score: TypingTestScore
        let seconds: TimeInterval
        /// Touch-downs the keyboard counted during the attempt (LocalFlow with the counters on), once read.
        var touchDowns: Int?
    }

    @State private var keyboard = Keyboard.localFlow
    @State private var passageIndex = 0
    @State private var typed = ""
    @State private var firstEdit: Date?
    @State private var lastEdit: Date?
    @State private var countersAtStart: TypingCounters?
    @State private var attempts: [Attempt] = []

    private var passage: String { TypingTestScore.passages[passageIndex % TypingTestScore.passages.count] }

    var body: some View {
        List {
            Section {
                Picker("Keyboard", selection: $keyboard) {
                    ForEach(Keyboard.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("typingTest.keyboard")
                Text(passage)
                    .font(.title3)
                    .accessibilityIdentifier("typingTest.passage")
                RawTextView(text: $typed, onBeginEditing: beganEditing, onEdit: edited)
                    .frame(minHeight: 110)
                    .accessibilityIdentifier("typingTest.field")
                HStack {
                    Button("Score", action: score)
                        .disabled(typed.isEmpty)
                        .accessibilityIdentifier("typingTest.score")
                    Spacer()
                    Button("Next passage") {
                        startOver()
                        passageIndex += 1
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Typing test (TestFlight)")
            } footer: {
                Text("Pick the keyboard, switch to it with the globe key, then type the passage at your normal speed. Don't correct anything, then tap Score. Autocorrect, predictions and capitals are off in this field for both keyboards. With Count typing events on, LocalFlow attempts also show whether the dropped taps reached the keys.")
            }

            if !attempts.isEmpty {
                Section("Summary") {
                    ForEach(Keyboard.allCases) { option in
                        summary(option)
                    }
                    Button("Clear results", role: .destructive) { attempts = [] }
                }
                Section("Attempts, newest first") {
                    ForEach(attempts.reversed()) { attempt in
                        AttemptRow(attempt: attempt)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Typing test")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func summary(_ keyboard: Keyboard) -> some View {
        let mine = attempts.filter { $0.keyboard == keyboard }
        let characters = mine.reduce(0) { $0 + $1.score.passageCount }
        if characters > 0 {
            let dropped = mine.reduce(0) { $0 + $1.score.dropped }, wrong = mine.reduce(0) { $0 + $1.score.wrong }
            let seconds = mine.reduce(0) { $0 + $1.seconds }, typedCount = mine.reduce(0) { $0 + $1.score.typedCount }
            LabeledContent(keyboard.rawValue) {
                Text(String(format: "%.1f dropped · %.1f wrong per 100 · %.0f cpm",
                            Double(dropped) / Double(characters) * 100, Double(wrong) / Double(characters) * 100,
                            seconds > 0 ? Double(typedCount) / seconds * 60 : 0))
                    .monospacedDigit()
            }
        }
    }

    private func beganEditing() {
        // The keyboard added its pending counts when it last hid, so this is where the attempt's counting starts.
        if firstEdit == nil { countersAtStart = settings?.typingCounters }
    }

    private func edited() {
        let now = Date()
        if firstEdit == nil {
            firstEdit = now
            if countersAtStart == nil { countersAtStart = settings?.typingCounters }
        }
        lastEdit = now
    }

    private func score() {
        let attempt = Attempt(keyboard: keyboard, passage: passage, score: TypingTestScore.score(passage: passage, typed: typed),
                              seconds: (lastEdit ?? Date()).timeIntervalSince(firstEdit ?? Date()))
        attempts.append(attempt)
        let start = countersAtStart
        // Closing the keyboard makes it add its pending counts; read them a moment later.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if keyboard == .localFlow, settings?.typingCountersEnabled == true, let start {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard let end = settings?.typingCounters,
                      let index = attempts.firstIndex(where: { $0.id == attempt.id }) else { return }
                attempts[index].touchDowns = max(0, end.total(.touchDown) - start.total(.touchDown))
            }
        }
        startOver()
        passageIndex += 1
    }

    private func startOver() {
        typed = ""
        firstEdit = nil
        lastEdit = nil
        countersAtStart = nil
    }

    private struct AttemptRow: View {
        let attempt: Attempt

        var body: some View {
            let score = attempt.score
            VStack(alignment: .leading, spacing: 4) {
                Text("\(attempt.keyboard.rawValue) · \(cpm)")
                    .font(.subheadline.weight(.semibold))
                Text("Dropped \(score.dropped) · wrong \(score.wrong) · extra \(score.extra) of \(score.passageCount)")
                    .font(.caption).monospacedDigit()
                Text("Dropped by row: top \(score.dropped(in: .top)) · middle \(score.dropped(in: .middle)) · bottom \(score.dropped(in: .bottom)) · space \(score.dropped(in: .space))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text("Dropped at: word start \(score.dropped(at: .wordStart)) · word end \(score.dropped(at: .wordEnd)) · inside \(score.dropped(at: .inside)) · space \(score.dropped(at: .space))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if let touchDowns = attempt.touchDowns {
                    Text(reach(touchDowns))
                        .font(.caption).monospacedDigit()
                }
                Text(Self.highlighted(score.ops))
                    .font(.callout)
                    .padding(.top, 2)
            }
            .padding(.vertical, 2)
        }

        private var cpm: String {
            attempt.score.charactersPerMinute(seconds: attempt.seconds).map { String(format: "%.0f cpm", $0) } ?? "—"
        }

        private func reach(_ touchDowns: Int) -> String {
            let typed = attempt.score.typedCount
            if touchDowns > typed {
                return "Touch-downs \(touchDowns), characters \(typed): \(touchDowns - typed) touches reached the keys but typed nothing"
            }
            return "Touch-downs \(touchDowns), characters \(typed): every touch that reached the keys typed"
        }

        /// The passage with dropped characters struck through in red, wrong ones orange (as typed), and extra
        /// ones blue. A dropped or extra space shows as "·".
        static func highlighted(_ ops: [TypingTestScore.Op]) -> AttributedString {
            var text = AttributedString()
            for op in ops {
                var piece: AttributedString
                switch op {
                case .matched(let character):
                    piece = AttributedString(String(character))
                case .dropped(let character):
                    piece = AttributedString(character == " " ? "·" : String(character))
                    piece.foregroundColor = Color.red
                    piece.strikethroughStyle = Text.LineStyle.single
                case .wrong(_, let typed):
                    piece = AttributedString(String(typed))
                    piece.foregroundColor = Color.orange
                case .extra(let character):
                    piece = AttributedString(character == " " ? "·" : String(character))
                    piece.foregroundColor = Color.blue
                }
                text += piece
            }
            return text
        }
    }
}

/// A plain text view with every typing aid off (ARCHITECTURE.md, "Typing test"), so either keyboard types raw.
private struct RawTextView: UIViewRepresentable {
    @Binding var text: String
    var onBeginEditing: () -> Void
    var onEdit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.inlinePredictionType = .no
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 8
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RawTextView

        init(parent: RawTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onBeginEditing()
        }

        /// Return is not part of any passage.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            text != "\n"
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.onEdit()
        }
    }
}
