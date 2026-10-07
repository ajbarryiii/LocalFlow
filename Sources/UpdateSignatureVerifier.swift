import Foundation
import Security

/// Checks a downloaded update before it replaces the running app: the update
/// must carry a valid Apple-anchored signature from the same developer team
/// and the same bundle identifier as this copy of the app.
enum UpdateSignatureVerifier {
    enum Failure: LocalizedError, Equatable {
        /// Ad-hoc and unsigned builds have no team to compare against.
        case runningAppHasNoTeam
        case invalidIdentity
        case signatureRejected(OSStatus)

        var errorDescription: String? {
            switch self {
            case .runningAppHasNoTeam:
                return "This copy of \(AppName.displayName) is not signed by a developer team, so the update cannot be verified. Download it from the release page instead."
            case .invalidIdentity:
                return "The app's signing identity could not be read."
            case .signatureRejected(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "The update's code signature did not match \(AppName.displayName) (\(detail))."
            }
        }
    }

    static func verifyMatchesRunningApp(_ appURL: URL) throws {
        try verify(appAt: appURL, bundleIdentifier: Bundle.main.bundleIdentifier,
                   teamIdentifier: runningTeamIdentifier())
    }

    static func verify(appAt appURL: URL, bundleIdentifier: String?, teamIdentifier: String?) throws {
        guard let teamIdentifier else { throw Failure.runningAppHasNoTeam }
        guard let bundleIdentifier,
              let text = requirementText(bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier) else {
            throw Failure.invalidIdentity
        }
        try verify(appAt: appURL, requirementText: text)
    }

    static func verify(appAt appURL: URL, requirementText: String) throws {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw Failure.invalidIdentity
        }
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw Failure.signatureRejected(status) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else { throw Failure.signatureRejected(status) }
    }

    /// Both values are validated so neither can change the requirement's meaning.
    static func requirementText(bundleIdentifier: String, teamIdentifier: String) -> String? {
        let isTeamIdentifier = teamIdentifier.count == 10
            && teamIdentifier.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
        let isBundleIdentifier = !bundleIdentifier.isEmpty
            && bundleIdentifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        guard isTeamIdentifier, isBundleIdentifier else { return nil }
        return "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let information = information as NSDictionary? else {
            return nil
        }
        return information[kSecCodeInfoTeamIdentifier] as? String
    }
}
