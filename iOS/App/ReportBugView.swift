import SwiftUI
import UIKit

/// Opens a mail draft only after a tap. The email app owns editing, sending, and cancellation.
struct ReportBugView: View {
    let recipient: String
    @Environment(\.openURL) private var openURL
    @State private var emailUnavailable = false

    private var draft: BugReportEmail {
        BugReportEmail(recipient: recipient, appVersion: AppIdentity.version,
                       systemVersion: UIDevice.current.systemVersion, deviceModel: UIDevice.current.model)
    }

    var body: some View {
        List {
            Section {
                Text("Describe what happened and how to make it happen again.")
                LabeledContent("To") {
                    Text(recipient).textSelection(.enabled)
                }
            } footer: {
                Label("Only the details below. No recordings, transcripts or logs.", systemImage: "lock.fill")
                    .font(.footnote)
            }
            .listRowBackground(Theme.cardBackground)

            Section {
                Button {
                    guard let url = draft.mailtoURL else {
                        emailUnavailable = true
                        return
                    }
                    openURL(url) { accepted in
                        emailUnavailable = !accepted
                    }
                } label: {
                    Label("Write email", systemImage: "envelope")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("support.writeEmail")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section("Email draft") {
                Text(draft.body)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("support.emailDraft")
            }
            .listRowBackground(Theme.cardBackground)
        }
        .listStyle(.insetGrouped)
        .themedListBackground()
        .navigationTitle("Report a bug")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t open email", isPresented: $emailUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Send your report to \(recipient). You can select and copy the address and draft on this screen into an email app.")
        }
    }
}
