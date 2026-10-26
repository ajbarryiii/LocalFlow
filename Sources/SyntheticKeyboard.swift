import Carbon
import CoreGraphics

/// Posts synthetic key presses to the focused app. Main actor, like the layout lookup it uses.
@MainActor
enum SyntheticKeyboard {
    static let returnKey: CGKeyCode = 36

    /// Posts `key` down then up. Without `flags`, the events keep the flags their source gives them.
    static func press(_ key: CGKeyCode, flags: CGEventFlags? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            if let flags {
                event?.flags = flags
            }
            event?.post(tap: .cgSessionEventTap)
        }
    }

    /// Command-V, using the key that types "v" in the current keyboard layout.
    static func paste() {
        press(keyCode(for: "v") ?? 9, flags: .maskCommand)
    }

    /// The key that types `character` in the current keyboard layout.
    static func keyCode(for character: String) -> CGKeyCode? {
        guard let char = character.lowercased().utf16.first else { return nil }
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let layout = ptr.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            for keyCode in UInt16(0)..<UInt16(128) {
                var chars = [UniChar](repeating: 0, count: 4)
                var charCount = 0
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, 4, &charCount, &chars
                )
                if status == noErr, charCount > 0, chars[0] == char {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }
}
