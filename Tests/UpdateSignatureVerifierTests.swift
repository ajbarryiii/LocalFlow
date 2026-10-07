import Foundation
import Security

enum UpdateSignatureVerifierTests {
    private static let bundleIdentifier = "com.example.localflow-test"
    private static let teamIdentifier = "ABCDE12345"
    // A validly Apple-signed local app whose identity never matches a LocalFlow team.
    private static let systemApp = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    static func run() {
        testRequirementPinsBundleAndTeam()
        testRequirementRejectsMalformedIdentities()
        testRunningAppWithoutTeamIsRejected()
        testUnsignedBundleIsRejected()
        testSignedAppFromAnotherTeamIsRejected()
    }

    private static func testRequirementPinsBundleAndTeam() {
        TestSupport.expectEqual(
            UpdateSignatureVerifier.requirementText(bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier),
            "anchor apple generic and identifier \"com.example.localflow-test\" and certificate leaf[subject.OU] = \"ABCDE12345\""
        )
    }

    private static func testRequirementRejectsMalformedIdentities() {
        for team in ["", "ABCDE1234", "abcde12345", "ABCDE1234\"", "ABCDE12345 or anchor apple"] {
            TestSupport.expect(
                UpdateSignatureVerifier.requirementText(bundleIdentifier: bundleIdentifier, teamIdentifier: team) == nil,
                "Malformed team identifier must be rejected: \(team)"
            )
        }
        for bundle in ["", "com.example\" or anchor apple or identifier \"x", "com.example app", "com.exämple"] {
            TestSupport.expect(
                UpdateSignatureVerifier.requirementText(bundleIdentifier: bundle, teamIdentifier: teamIdentifier) == nil,
                "Malformed bundle identifier must be rejected: \(bundle)"
            )
        }
    }

    private static func testRunningAppWithoutTeamIsRejected() {
        TestSupport.expectEqual(
            failure { try UpdateSignatureVerifier.verify(appAt: systemApp, bundleIdentifier: bundleIdentifier, teamIdentifier: nil) },
            .runningAppHasNoTeam
        )
    }

    private static func testUnsignedBundleIsRejected() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateSignatureVerifierTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Unsigned.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": bundleIdentifier, "CFBundleExecutable": "Unsigned",
                                       "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            let executable = macOS.appendingPathComponent("Unsigned")
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        } catch {
            fatalError("Failed to create unsigned test bundle: \(error)")
        }

        TestSupport.expect(
            isSignatureRejection(failure {
                try UpdateSignatureVerifier.verify(appAt: app, bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier)
            }),
            "An unsigned app must not pass update verification"
        )
    }

    private static func testSignedAppFromAnotherTeamIsRejected() {
        // The validation flags must accept a correctly signed universal app...
        TestSupport.expectEqual(
            failure { try UpdateSignatureVerifier.verify(appAt: systemApp, requirementText: "anchor apple and identifier \"com.apple.calculator\"") },
            nil
        )
        // ...so this rejection comes from the pinned team, not a broken signature.
        TestSupport.expectEqual(
            failure {
                try UpdateSignatureVerifier.verify(appAt: systemApp, bundleIdentifier: "com.apple.calculator", teamIdentifier: teamIdentifier)
            },
            .signatureRejected(OSStatus(errSecCSReqFailed))
        )
    }

    private static func failure(_ body: () throws -> Void) -> UpdateSignatureVerifier.Failure? {
        do {
            try body()
            return nil
        } catch let failure as UpdateSignatureVerifier.Failure {
            return failure
        } catch {
            fatalError("Unexpected error: \(error)")
        }
    }

    private static func isSignatureRejection(_ failure: UpdateSignatureVerifier.Failure?) -> Bool {
        if case .signatureRejected = failure { return true }
        return false
    }
}
