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
                Text("Describe what happened and how to reproduce it. You can edit or cancel the draft in your email app before sending.")
                LabeledContent("To") {
                    Text(recipient).textSelection(.enabled)
                }
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
                .accessibilityIdentifier("support.writeEmail")
            } footer: {
                Text("The draft includes only the app version, iOS version, and device type shown below. No recordings, transcripts, or logs are attached.")
            }

            Section("Email draft") {
                Text(draft.body)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("support.emailDraft")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Report a bug")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t open email", isPresented: $emailUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Send your report to \(recipient). You can select and copy the address and draft on this screen into an email app.")
        }
    }
}
