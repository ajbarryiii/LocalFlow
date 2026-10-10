import Foundation

enum FieldProfileTests {
    static var tests: [TestCase] {
        [
            ("messagesWrapWidthMatchesMeasurement", testMessagesWrapWidthMatchesMeasurement),
            ("fullWidthKeepsTodaysTuning", testFullWidthKeepsTodaysTuning),
            ("linePitchIsLineHeightPlusLeading", testLinePitchIsLineHeightPlusLeading),
            ("verticalStepsUseTheRealPitch", testVerticalStepsUseTheRealPitch),
            ("fingerprintsAreStableAndContentFree", testFingerprintsAreStableAndContentFree),
            ("chooserPrefersRememberedChoices", testChooserPrefersRememberedChoices),
            ("measuredFingerprintsPickTheirLayout", testMeasuredFingerprintsPickTheirLayout),
        ]
    }

    private static let parameters = FieldLayoutParameters.standard

    private static func close(_ actual: Double, _ expected: Double, _ tolerance: Double, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        TestSupport.expect(abs(actual - expected) <= tolerance, "\(what): expected \(expected), got \(actual)",
                           file: file, line: line)
    }

    private static func testMessagesWrapWidthMatchesMeasurement() {
        // Calibration report, "Field geometry": screen width − 2·m − 117.33, m = 16 below 414 pt.
        close(parameters.wrapWidth(.messages, keyboardWidth: 393), 243.67, 0.01, "iPhone 15 Pro")
        // The measured simulators (17e 240.8, 17 Pro 253.0, Air 262.6, Pro Max 282.7), within 0.35 pt.
        close(parameters.wrapWidth(.messages, keyboardWidth: 390), 240.8, 0.35, "17e")
        close(parameters.wrapWidth(.messages, keyboardWidth: 402), 253.0, 0.35, "17 Pro")
        close(parameters.wrapWidth(.messages, keyboardWidth: 420), 262.6, 0.35, "Air")
        close(parameters.wrapWidth(.messages, keyboardWidth: 440), 282.7, 0.35, "Pro Max")
        TestSupport.expectEqual(parameters.margin(keyboardWidth: 413.9), 16)
        TestSupport.expectEqual(parameters.margin(keyboardWidth: 414), 20)
        TestSupport.expectEqual(parameters.lineFragmentPadding, 0)
        // Never absurdly narrow.
        TestSupport.expectEqual(parameters.wrapWidth(.messages, keyboardWidth: 100), parameters.minimumWidth)
    }

    private static func testFullWidthKeepsTodaysTuning() {
        TestSupport.expectEqual(parameters.wrapWidth(.fullWidth, keyboardWidth: 393), 353)
        TestSupport.expectEqual(parameters.wrapWidth(.fullWidth, keyboardWidth: 440), 392)
        TestSupport.expectEqual(parameters.defaultLayout, .fullWidth)
        TestSupport.expectEqual(FieldLayout.messages.other, .fullWidth)
        TestSupport.expectEqual(FieldLayout.fullWidth.title, "Full-width")
        TestSupport.expectEqual(FieldLayout.messages.title, "Messages-width")
    }

    private static func testLinePitchIsLineHeightPlusLeading() {
        // Measured: text views advance 24.00 pt per line at the default size (body lineHeight 22.29),
        // not lineHeight, which made every vertical step 7.7 % short.
        close(FieldLayoutParameters.linePitch(lineHeight: 22.29, leading: 1.71), 24, 1e-9, "default size")
        TestSupport.expectEqual(FieldLayoutParameters.linePitch(lineHeight: 20, leading: -1), 20)
    }

    private static func testVerticalStepsUseTheRealPitch() {
        // With a 24-point pitch the next line's center is 24 points down, and the caret moves to it
        // only past half of that: 11.9 points stay, 12.1 go. Regression: 22.29 snapped 0.9 points early
        // and landed every multi-line move short.
        let text = "abcdefghij" + "klmnopqrst" + "uvwxyzabcd"
        func caret(after travel: Double) -> Int {
            var host = FakeTextHost(text: text, caret: 3)
            var session = TrackpadSession(before: host.context.before, after: host.context.after, unit: nil,
                                          parameters: .flat, layout: FixedWidthLayout(columns: 10), linePitch: 24,
                                          layoutWidth: 10_000)
            runGesture(&session, host: &host, samples: [(0, travel)])
            return host.caret
        }
        TestSupport.expectEqual(caret(after: 11.9), 3)
        TestSupport.expectEqual(caret(after: 12.1), 13)
        TestSupport.expectEqual(caret(after: 48), 23)
        TestSupport.expectEqual(caret(after: 35.9), 13)
        TestSupport.expectEqual(caret(after: 36.1), 23)
    }

    private static func testFingerprintsAreStableAndContentFree() {
        var traits = FieldTraits()
        traits.autocapitalization = 2
        traits.textContentType = "telephoneNumber"
        let unknown = FieldFingerprint(traits: traits, unit: nil)
        let learned = FieldFingerprint(traits: traits, unit: .utf16)
        // Stable across launches and processes: FNV-1a of the traits, never Swift's seeded hashing.
        TestSupport.expectEqual(unknown.key, FieldFingerprint(traits: traits, unit: nil).key)
        TestSupport.expectEqual(FieldFingerprint.hash(""), "cbf29ce484222325")
        TestSupport.expectEqual(FieldFingerprint.hash("a"), "af63dc4c8601ec8c")
        TestSupport.expectEqual(unknown.key.count, 16)
        TestSupport.expect(unknown.key.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "not lowercase hex")
        // Without a unit the key is the traits key; with one, a different key.
        TestSupport.expectEqual(unknown.key, unknown.traitsKey)
        TestSupport.expect(learned.key != unknown.key, "the unit does not count")
        TestSupport.expectEqual(learned.traitsKey, unknown.traitsKey)
        var other = traits
        other.returnKeyType = 7
        TestSupport.expect(FieldFingerprint(traits: other, unit: nil).key != unknown.key, "traits do not count")
        // The readout is the short key and the traits.
        TestSupport.expect(learned.summary.hasPrefix(String(learned.key.prefix(8))), "summary key")
        TestSupport.expect(learned.summary.contains("ac2") && learned.summary.contains("cttelephoneNumber"), "summary traits")
    }

    /// Traits as fields reported them to the keyboard (iOS 26.4 simulator, 2026-10-09), in the order
    /// kb rt ac co sp sq sd si ap; the proxy reports no inline prediction, math or Writing Tools trait.
    private static func measured(_ values: [Int], returnAuto: Bool = false) -> FieldTraits {
        var traits = FieldTraits()
        traits.keyboardType = values[0]
        traits.returnKeyType = values[1]
        traits.autocapitalization = values[2]
        traits.autocorrection = values[3]
        traits.spellChecking = values[4]
        traits.smartQuotes = values[5]
        traits.smartDashes = values[6]
        traits.smartInsertDelete = values[7]
        traits.keyboardAppearance = values[8]
        traits.inlinePrediction = -1
        traits.mathExpressionCompletion = -1
        traits.writingToolsBehavior = -1
        traits.enablesReturnKeyAutomatically = returnAuto
        return traits
    }

    private static func testMeasuredFingerprintsPickTheirLayout() {
        let messages = [measured([0, 0, 2, 0, 0, 1, 1, 2, 2]), measured([0, 0, 2, 0, 0, 1, 1, 2, 1])]   // light, dark
        let others: [(String, FieldTraits)] = [
            ("Messages To:", measured([0, 0, 2, 0, 0, 2, 2, 2, 0])),
            ("UITextView and UITextField defaults, SwiftUI Try it fields", measured([0, 0, 2, 0, 0, 2, 2, 2, 2])),
            ("UITextView without autocorrection or smart punctuation", measured([0, 0, 2, 1, 1, 1, 1, 2, 2])),
            ("WebKit textarea and contenteditable", measured([0, 0, 2, 2, 0, 2, 2, 2, 0])),
            ("Safari address", measured([10, 1, 0, 1, 0, 1, 1, 2, 2])),
            ("Contacts, Settings and Files search", measured([0, 6, 2, 1, 0, 2, 2, 2, 2], returnAuto: true)),
            ("Maps search", measured([0, 6, 2, 1, 1, 2, 2, 2, 2], returnAuto: true)),
            ("Number pad", measured([4, 0, 2, 0, 0, 1, 1, 1, 2])),
        ]
        for traits in messages {
            TestSupport.expectEqual(FieldLayoutChooser.layout(for: FieldFingerprint(traits: traits, unit: nil), overrides: [:]),
                                    .messages)
            TestSupport.expectEqual(FieldLayoutChooser.layout(for: FieldFingerprint(traits: traits, unit: .utf16), overrides: [:]),
                                    .messages)
            // A field with this signature where the trackpad learned grapheme units is WebKit.
            TestSupport.expectEqual(FieldLayoutChooser.layout(for: FieldFingerprint(traits: traits, unit: .grapheme),
                                                              overrides: [:]), .fullWidth)
        }
        // Light and dark Messages are one fingerprint: the appearance is not part of the key.
        TestSupport.expectEqual(FieldFingerprint(traits: messages[0], unit: nil).key, FieldFingerprint(traits: messages[1], unit: nil).key)
        for (name, traits) in others {
            TestSupport.expect(FieldLayoutChooser.layout(for: FieldFingerprint(traits: traits, unit: nil), overrides: [:]) == .fullWidth,
                               "\(name) taken for Messages")
        }
        // A remembered choice beats the detection, both ways.
        let compose = FieldFingerprint(traits: messages[0], unit: .utf16)
        TestSupport.expectEqual(FieldLayoutChooser.layout(for: compose, overrides: [compose.traitsKey: .fullWidth]), .fullWidth)
        let plain = FieldFingerprint(traits: others[1].1, unit: .utf16)
        TestSupport.expectEqual(FieldLayoutChooser.layout(for: plain, overrides: [plain.key: .messages]), .messages)
    }

    private static func testChooserPrefersRememberedChoices() {
        var traits = FieldTraits()
        traits.returnKeyType = 9
        let fingerprint = FieldFingerprint(traits: traits, unit: .utf16)
        TestSupport.expectEqual(FieldLayoutChooser.layout(for: fingerprint, overrides: [:]), parameters.defaultLayout)
        // A choice made before the unit was known still applies once it is.
        TestSupport.expectEqual(FieldLayoutChooser.layout(for: fingerprint, overrides: [fingerprint.traitsKey: .messages]),
                                .messages)
        // A choice made with the unit known takes precedence.
        TestSupport.expectEqual(FieldLayoutChooser.layout(for: fingerprint, overrides: [
            fingerprint.traitsKey: .messages, fingerprint.key: .fullWidth,
        ]), .fullWidth)
        // Other fields are not affected.
        var other = traits
        other.keyboardType = 3
        TestSupport.expectEqual(FieldLayoutChooser.layout(for: FieldFingerprint(traits: other, unit: .utf16),
                                                          overrides: [fingerprint.key: .messages]), parameters.defaultLayout)
        // The default is one constant.
        var messagesByDefault = FieldLayoutParameters.standard
        messagesByDefault.defaultLayout = .messages
        TestSupport.expectEqual(FieldLayoutChooser.layout(for: fingerprint, overrides: [:], parameters: messagesByDefault),
                                .messages)
    }
}
