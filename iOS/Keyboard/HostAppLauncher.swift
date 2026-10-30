import UIKit

/// EXPERIMENTAL, and an App Review gray area: validate on iOS 26 and 27 devices and call it out in
/// the PR. Keyboards have no supported API to open their containing app, so this walks the
/// responder chain to the application object and calls `open(_:options:completionHandler:)`
/// through the Objective-C runtime, because that method and `UIApplication.shared` are
/// unavailable to extensions at compile time. The legacy `openURL:` is deliberately not used:
/// iOS 18 and later ignore it. The supported fallback is the user opening LocalFlow themselves.
///
/// An https URL (the universal link of App Store builds) is opened universal-links-only, so iOS
/// opens it only in the app verified for its domain, never in Safari or another app; otherwise the
/// completion reports false.
@MainActor
enum HostAppLauncher {
    private typealias OpenURL = @convention(c) (
        AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void

    /// Returns whether the open call was made. `completion` then reports whether iOS opened the URL;
    /// it is not called when this returns false.
    static func open(_ url: URL, from responder: UIResponder,
                     completion: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        let options: NSDictionary = url.scheme?.lowercased() == "https"
            ? [UIApplication.OpenExternalURLOptionsKey.universalLinksOnly.rawValue: true]
            : [:]
        var next: UIResponder? = responder
        while let current = next {
            if current is UIApplication, current.responds(to: selector) {
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                open(current, selector, url as NSURL, options) { opened in
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(opened) } }
                }
                return true
            }
            next = current.next
        }
        return false
    }
}
