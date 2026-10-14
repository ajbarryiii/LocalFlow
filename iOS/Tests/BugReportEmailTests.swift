import Foundation

enum BugReportEmailTests {
    static var tests: [TestCase] {
        [
            ("draftContainsPromptsAndOnlySuppliedMetadata", testDraft),
            ("mailtoPreservesRecipientAndDraft", testMailto),
            ("reservedCharactersCannotAddRecipientsOrHeaders", testReservedCharacters),
        ]
    }

    private static func testDraft() {
        let draft = BugReportEmail(recipient: "support@example.invalid", appVersion: "0.1.0 (8)",
                                   systemVersion: "26.0", deviceModel: "iPad")
        TestSupport.expectEqual(draft.subject, "LocalFlow bug report")
        TestSupport.expectEqual(draft.body, """
        Steps to reproduce:
        1.

        Expected:

        What happened:

        App: LocalFlow 0.1.0 (8)
        iOS: 26.0
        Device: iPad
        """)
    }

    private static func testMailto() {
        let draft = BugReportEmail(recipient: "support+ios@example.invalid", appVersion: "0.1.0 (8)",
                                   systemVersion: "26.0", deviceModel: "iPhone")
        let url = draft.mailtoURL!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        TestSupport.expectEqual(components.scheme, "mailto")
        TestSupport.expectEqual(components.path, "support+ios@example.invalid")
        TestSupport.expectEqual(components.queryItems?.map(\.name), ["subject", "body"])
        TestSupport.expectEqual(components.queryItems?.first?.value, draft.subject)
        TestSupport.expectEqual(components.queryItems?.last?.value, draft.body)
        TestSupport.expectEqual(components.fragment, nil)
    }

    private static func testReservedCharacters() {
        let draft = BugReportEmail(recipient: "support@example.invalid", appVersion: "synthetic+build & 50%",
                                   systemVersion: "synthetic?cc=other@example.invalid#fragment",
                                   deviceModel: "Synthetic device\n日本語")
        let url = draft.mailtoURL!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        TestSupport.expectEqual(components.path, "support@example.invalid")
        TestSupport.expectEqual(components.queryItems?.map(\.name), ["subject", "body"])
        TestSupport.expectEqual(components.queryItems?.last?.value, draft.body)
        TestSupport.expectEqual(components.fragment, nil)
        TestSupport.expect(!components.percentEncodedQuery!.contains("+"), "mail clients must not treat a literal plus as a space")
    }
}
