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
            ("contentTypesAreAllowlisted", testContentTypesAreAllowlisted),
            ("choiceSurvivesForgettingTheUnit", testChoiceSurvivesForgettingTheUnit),
            ("messagesGeometryOnlyWhereMeasured", testMessagesGeometryOnlyWhereMeasured),
            ("placeholderReadingsAreIgnored", testPlaceholderReadingsAreIgnored),
            ("fingerprintChangesApplyAtTheNextGesture", testFingerprintChangesApplyAtTheNextGesture),
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
            TestSupport.expectEqual(choose(FieldFingerprint(traits: traits, unit: nil)), .messages)
            TestSupport.expectEqual(choose(FieldFingerprint(traits: traits, unit: .utf16)), .messages)
            // A field with this signature where the trackpad learned grapheme units is WebKit.
            TestSupport.expectEqual(choose(FieldFingerprint(traits: traits, unit: .grapheme)), .fullWidth)
        }
        // Light and dark Messages are one fingerprint: the appearance is not part of the key.
        TestSupport.expectEqual(FieldFingerprint(traits: messages[0], unit: nil).key, FieldFingerprint(traits: messages[1], unit: nil).key)
        for (name, traits) in others {
            TestSupport.expect(choose(FieldFingerprint(traits: traits, unit: nil)) == .fullWidth, "\(name) taken for Messages")
        }
        // A remembered choice beats the detection, both ways.
        let compose = FieldFingerprint(traits: messages[0], unit: .utf16)
        TestSupport.expectEqual(choose(compose, [compose.traitsKey: .fullWidth]), .fullWidth)
        let plain = FieldFingerprint(traits: others[1].1, unit: .utf16)
        TestSupport.expectEqual(choose(plain, [plain.key: .messages]), .messages)
    }

    /// The layout in portrait on a 393-point iPhone 15 Pro.
    private static let portrait = FieldGeometry(keyboardWidth: 393, isPortrait: true)

    private static func choose(_ fingerprint: FieldFingerprint, _ overrides: [String: FieldLayout] = [:],
                               geometry: FieldGeometry = portrait,
                               parameters: FieldLayoutParameters = .standard) -> FieldLayout {
        FieldLayoutChooser.layout(for: fingerprint, overrides: overrides, geometry: geometry, parameters: parameters)
    }

    private static func testChooserPrefersRememberedChoices() {
        var traits = FieldTraits()
        traits.returnKeyType = 9
        let fingerprint = FieldFingerprint(traits: traits, unit: .utf16)
        TestSupport.expectEqual(choose(fingerprint), parameters.defaultLayout)
        // A choice made before the unit was known still applies once it is.
        TestSupport.expectEqual(choose(fingerprint, [fingerprint.traitsKey: .messages]), .messages)
        // A choice made with the unit known takes precedence.
        TestSupport.expectEqual(choose(fingerprint, [fingerprint.traitsKey: .messages, fingerprint.key: .fullWidth]), .fullWidth)
        // Other fields are not affected.
        var other = traits
        other.keyboardType = 3
        TestSupport.expectEqual(choose(FieldFingerprint(traits: other, unit: .utf16), [fingerprint.key: .messages]),
                                parameters.defaultLayout)
        // The default is one constant.
        var messagesByDefault = FieldLayoutParameters.standard
        messagesByDefault.defaultLayout = .messages
        TestSupport.expectEqual(choose(fingerprint, parameters: messagesByDefault), .messages)
    }

    private static func testContentTypesAreAllowlisted() {
        // Sol's round-5 review: an app can set any string as its content type ("PrivateDraft"), which
        // was shown in the menu and hashed. Only Apple's constants pass, digits and hyphens included.
        let known: Set<String> = ["tel", "one-time-code", "address-line1", "username"]
        TestSupport.expectEqual(FieldTraits.contentTypeLabel(nil, known: known), nil)
        TestSupport.expectEqual(FieldTraits.contentTypeLabel("one-time-code", known: known), "one-time-code")
        TestSupport.expectEqual(FieldTraits.contentTypeLabel("address-line1", known: known), "address-line1")
        for custom in ["PrivateDraft", "draft-for-Alex", "x", "", "TEL", "tel "] {
            TestSupport.expectEqual(FieldTraits.contentTypeLabel(custom, known: known), "custom")
        }
        // Every custom value fingerprints alike, and the readout never shows it.
        var a = FieldTraits(), b = FieldTraits()
        a.textContentType = FieldTraits.contentTypeLabel("PrivateDraft", known: known)
        b.textContentType = FieldTraits.contentTypeLabel("SecretProject", known: known)
        TestSupport.expectEqual(FieldFingerprint(traits: a, unit: nil).key, FieldFingerprint(traits: b, unit: nil).key)
        TestSupport.expect(!FieldFingerprint(traits: a, unit: nil).summary.contains("Private"), "custom type shown")
    }

    private static func testChoiceSurvivesForgettingTheUnit() {
        // Sol's round-5 review: a choice made after the trackpad learned the unit was saved under the key
        // with the unit only; hiding forgets the unit, and on reopening the field was detected again.
        var traits = FieldTraits()
        traits.autocapitalization = 2
        var overrides: [String: FieldLayout] = [:]
        // Toggle with the unit known.
        let learned = FieldFingerprint(traits: traits, unit: .utf16)
        overrides.merge(FieldLayoutChooser.choiceEntries(for: learned, layout: .messages)) { _, new in new }
        // Hide and reopen: the unit is forgotten, and may never be learned again (ASCII-only moves).
        let reopened = FieldFingerprint(traits: traits, unit: nil)
        TestSupport.expectEqual(choose(reopened, overrides), .messages)
        TestSupport.expectEqual(choose(FieldFingerprint(traits: traits, unit: .grapheme), overrides), .messages)
        // A later choice, with the unit unknown, replaces the earlier one in every variant.
        overrides.merge(FieldLayoutChooser.choiceEntries(for: reopened, layout: .fullWidth)) { _, new in new }
        TestSupport.expectEqual(choose(learned, overrides), .fullWidth)
        TestSupport.expectEqual(choose(reopened, overrides), .fullWidth)
        TestSupport.expectEqual(FieldLayoutChooser.choiceEntries(for: learned, layout: .messages).count, 3)
    }

    private static func testMessagesGeometryOnlyWhereMeasured() {
        // Sol's round-5 review: the portrait chrome formula was applied in landscape and at any width.
        var traits = FieldTraits()
        traits.autocapitalization = 2
        traits.smartQuotes = 1
        traits.smartDashes = 1
        traits.smartInsertDelete = 2
        let compose = FieldFingerprint(traits: traits, unit: nil)
        for width in [390.0, 393, 402, 420, 440, 392.5] {
            TestSupport.expectEqual(choose(compose, geometry: FieldGeometry(keyboardWidth: width, isPortrait: true)), .messages)
        }
        // Landscape, Display Zoom at 375, Plus and iPad widths: full width unless chosen.
        for geometry in [FieldGeometry(keyboardWidth: 393, isPortrait: false), FieldGeometry(keyboardWidth: 852, isPortrait: false),
                         FieldGeometry(keyboardWidth: 375, isPortrait: true), FieldGeometry(keyboardWidth: 414, isPortrait: true),
                         FieldGeometry(keyboardWidth: 430, isPortrait: true), FieldGeometry(keyboardWidth: 820, isPortrait: true)] {
            TestSupport.expectEqual(choose(compose, geometry: geometry), .fullWidth)
            // A manual choice applies everywhere.
            TestSupport.expectEqual(choose(compose, [compose.key: .messages], geometry: geometry), .messages)
        }
    }
}

extension FieldProfileTests {
    /// Measured in the simulator (iOS 26.4, round 6): what the proxy reports in Messages' compose field
    /// before its first `textDidChange` (no field identity), and after.
    fileprivate static var placeholderTraits: FieldTraits {
        var traits = FieldTraits()
        traits.smartQuotes = 1
        traits.smartDashes = 1
        traits.smartInsertDelete = 1
        traits.inlinePrediction = -1
        traits.mathExpressionCompletion = -1
        traits.writingToolsBehavior = -1
        return traits
    }

    fileprivate static var composeTraits: FieldTraits {
        var traits = placeholderTraits
        traits.autocapitalization = 2
        traits.smartInsertDelete = 2
        traits.keyboardAppearance = 2
        return traits
    }

    fileprivate static func layout(_ tracker: FieldProfileTracker) -> FieldLayout {
        tracker.layout(overrides: [:], geometry: portrait)
    }

    fileprivate static func testPlaceholderReadingsAreIgnored() {
        // The user's device (iOS 26.6.2): Messages was not detected at first. At the keyboard's first
        // appearance the proxy reports default traits without a field identity; such a reading is never
        // used, and a choice is never remembered for it.
        let field = UUID()
        var tracker = FieldProfileTracker()
        TestSupport.expect(!tracker.read(FieldFingerprint(traits: placeholderTraits, unit: nil), documentID: nil),
                           "a placeholder reading used")
        TestSupport.expectEqual(tracker.fingerprint, nil)
        TestSupport.expectEqual(layout(tracker), parameters.defaultLayout)
        TestSupport.expect(tracker.choiceEntries(.messages).isEmpty, "a choice remembered for a placeholder")
        // The first real reading.
        TestSupport.expect(tracker.read(FieldFingerprint(traits: composeTraits, unit: nil), documentID: field), "not read")
        TestSupport.expectEqual(layout(tracker), .messages)
        TestSupport.expectEqual(tracker.choiceEntries(.fullWidth).count, 3)
        // A placeholder later (the field reconnecting) changes nothing; a repeated reading is no change.
        TestSupport.expect(!tracker.read(FieldFingerprint(traits: placeholderTraits, unit: nil), documentID: nil), "used")
        TestSupport.expect(!tracker.read(FieldFingerprint(traits: composeTraits, unit: nil), documentID: field), "changed")
        TestSupport.expectEqual(layout(tracker), .messages)
        // Hiding forgets the field.
        tracker.forget()
        TestSupport.expectEqual(tracker.fingerprint, nil)
        TestSupport.expectEqual(layout(tracker), parameters.defaultLayout)
    }

    fileprivate static func testFingerprintChangesApplyAtTheNextGesture() {
        let field = UUID()
        var tracker = FieldProfileTracker()
        // The traits arrive between gestures: the next gesture uses them.
        tracker.read(FieldFingerprint(traits: placeholderTraits, unit: nil), documentID: field)
        TestSupport.expectEqual(tracker.gestureBegan(overrides: [:], geometry: portrait), .fullWidth)
        tracker.gestureEnded()
        TestSupport.expect(tracker.read(FieldFingerprint(traits: composeTraits, unit: nil), documentID: field), "not read")
        TestSupport.expectEqual(tracker.gestureBegan(overrides: [:], geometry: portrait), .messages)
        // A change during a gesture (here the trackpad learning a grapheme unit) is deferred: the gesture
        // and the readout keep their layout until the lift, and the next gesture uses the new one.
        TestSupport.expect(tracker.read(FieldFingerprint(traits: composeTraits, unit: .grapheme), documentID: field),
                           "not read")
        TestSupport.expectEqual(tracker.gestureLayout, .messages)
        TestSupport.expectEqual(tracker.displayedLayout(overrides: [:], geometry: portrait), .messages)
        tracker.gestureEnded()
        TestSupport.expectEqual(tracker.displayedLayout(overrides: [:], geometry: portrait), .fullWidth)
        TestSupport.expectEqual(tracker.gestureBegan(overrides: [:], geometry: portrait), .fullWidth)
        tracker.gestureEnded()
        // Another field is a change too.
        TestSupport.expect(tracker.read(FieldFingerprint(traits: composeTraits, unit: nil), documentID: UUID()), "not read")
        TestSupport.expectEqual(tracker.gestureBegan(overrides: [:], geometry: portrait), .messages)
    }
}
