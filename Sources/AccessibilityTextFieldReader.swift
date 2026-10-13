import ApplicationServices
import Foundation

/// Accessibility access for the correction watcher (DESIGN §3.5). High risk:
/// it reads text from another application's field. Every call is bounded:
/// a 0.25 s messaging timeout on each element used, only the role, subrole,
/// focus, character count, selection and `AXStringForRange` attributes are
/// read, and the full `AXValue` is never requested. Nothing read is logged.
/// Used only on the watcher's serial queue.
final class AccessibilityTextFieldReader: TextFieldReader {
    private static let messagingTimeout: Float = 0.25
    private static let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole,
                                                 kAXComboBoxRole]

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func captureFocusedTextField() -> TextFieldTarget? {
        guard let (pid, element) = focusedElement(), pid != ownPID, isWatchable(element) else { return nil }
        return TextFieldTarget(pid: pid, element: element)
    }

    func check(_ target: TextFieldTarget) -> TextFieldCheck {
        guard CFGetTypeID(target.element) == AXUIElementGetTypeID() else { return .failed }
        let element = target.element as! AXUIElement
        guard let (pid, focused) = focusedElement() else { return .failed }
        guard pid == target.pid, CFEqual(focused, element) else { return .focusChanged }
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        guard let subrole = stringAttribute(element, kAXSubroleAttribute) else {
            // A missing subrole is normal; an error establishing it is not.
            return subroleIsAbsent(element) ? .ok : .failed
        }
        return subrole == kAXSecureTextFieldSubrole ? .secure : .ok
    }

    func characterCount(_ target: TextFieldTarget) -> Int? {
        guard let element = axElement(target),
              let value = copyAttribute(element, kAXNumberOfCharactersAttribute),
              CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var count = 0
        guard CFNumberGetValue((value as! CFNumber), .cfIndexType, &count), count >= 0 else { return nil }
        return count
    }

    func selectedRange(_ target: TextFieldTarget) -> TextFieldRange? {
        guard let element = axElement(target),
              let value = copyAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.location <= Int.max - range.length else { return nil }
        return TextFieldRange(location: range.location, length: range.length)
    }

    func string(_ target: TextFieldTarget, range: TextFieldRange) -> String? {
        guard let element = axElement(target), range.location >= 0, range.length >= 0 else { return nil }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                               parameter, &value)
        guard error == .success, let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as! CFString as String
    }

    // MARK: - Helpers

    private func axElement(_ target: TextFieldTarget) -> AXUIElement? {
        guard CFGetTypeID(target.element) == AXUIElementGetTypeID() else { return nil }
        let element = target.element as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return element
    }

    /// The system-wide focused element and its process, with timeouts set on
    /// both objects used. The focused application must own the element.
    private func focusedElement() -> (Int32, AXUIElement)? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
        guard let focusedApp = copyAttribute(systemWide, kAXFocusedApplicationAttribute),
              CFGetTypeID(focusedApp) == AXUIElementGetTypeID(),
              let focused = copyAttribute(systemWide, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let app = focusedApp as! AXUIElement, element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var appPID: pid_t = 0, elementPID: pid_t = 0
        guard AXUIElementGetPid(app, &appPID) == .success, AXUIElementGetPid(element, &elementPID) == .success,
              appPID == elementPID, appPID > 0 else { return nil }
        return (appPID, element)
    }

    /// An editable text area, text field or combo box that is not secure.
    private func isWatchable(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(element, kAXRoleAttribute), Self.textRoles.contains(role) else { return false }
        if let subrole = stringAttribute(element, kAXSubroleAttribute) {
            guard subrole != kAXSecureTextFieldSubrole else { return false }
        } else if !subroleIsAbsent(element) {
            return false
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    private func subroleIsAbsent(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        return error == .noValue || error == .attributeUnsupported
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as! CFString as String
    }
}
