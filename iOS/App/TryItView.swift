import SwiftUI

/// Two plain text fields for trying the keyboard, including the destination-binding test. The text
/// lives in view state only and is gone when the screen closes.
struct TryItView: View {
    @EnvironmentObject private var host: HostSessionController
    @State private var fieldA = ""
    @State private var fieldB = ""
    @FocusState private var focus: Field?

    private enum Field { case a, b }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HowToRow(number: 1, text: "Tap a field, then switch to the LocalFlow keyboard with \(Image(systemName: "globe")).")
                    HowToRow(number: 2, text: "Tap the microphone, speak, and tap it again to stop.")
                    HowToRow(number: 3, text: "The text appears in the field you dictated into.")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                field("Field A", text: $fieldA, field: .a, identifier: "tryit.fieldA")
                field("Field B", text: $fieldB, field: .b, identifier: "tryit.fieldB")

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(Theme.violet).padding(.top, 2)
                    Text("**Destination test.** Start dictating in Field A, then tap Field B before the text arrives. It must not appear in B; the keyboard offers **Insert last dictation** instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Theme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if host.session != .active {
                    Label("No session is running. The keyboard will open LocalFlow to start one.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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

    private func field(_ title: String, text: Binding<String>, field: Field, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Tap here and dictate…", text: text, axis: .vertical)
                .lineLimit(3...8)
                .focused($focus, equals: field)
                .padding(14)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(focus == field ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.clear), lineWidth: 2))
                .accessibilityIdentifier(identifier)
        }
    }
}

private struct HowToRow: View {
    var number: Int
    var text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.gradient, in: Circle())
            Text(text).font(.subheadline)
        }
    }
}
