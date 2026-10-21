import Foundation

/// ARCHITECTURE.md, "Word autocorrect": the bundle's optional `autocorrect` section (`AutocorrectManifest`), the
/// loader that builds the corrector from an invented bundle (`AutocorrectLoader`), and the App Group settings
/// (`LocalFlowSettings`): the switch, the model and preset choices, the per-parameter overrides merged over the
/// preset, and the reset. Invented manifests, files and values only.
enum AutocorrectSettingsTests {
    static var tests: [TestCase] {
        [
            ("manifestReadsTheSection", testManifestReadsTheSection),
            ("manifestWithoutTheSectionHasNoAutocorrect", testManifestWithoutTheSectionHasNoAutocorrect),
            ("manifestTouchFallsBackToTheTapSection", testManifestTouchFallsBackToTheTapSection),
            ("manifestRejectsAnInvalidSection", testManifestRejectsAnInvalidSection),
            ("manifestRejectsPresetsOutOfTheirDomain", testManifestRejectsPresetsOutOfTheirDomain),
            ("anInvalidSectionRejectsOnlyAutocorrect", testAnInvalidSectionRejectsOnlyAutocorrect),
            ("manifestResolvesModelsAndPresets", testManifestResolvesModelsAndPresets),
            ("presetNamesOrderNumbersByValue", testPresetNamesOrderNumbersByValue),
            ("manifestReadsTheSpellingChannel", testManifestReadsTheSpellingChannel),
            ("spellingPresetsNeedTheTables", testSpellingPresetsNeedTheTables),
            ("loaderReadsTheSpellingTables", testLoaderReadsTheSpellingTables),
            ("spellingOverrideAcceptsItsRangeAndMerges", testSpellingOverrideAcceptsItsRangeAndMerges),
            ("settingsAreOffAndUnsetByDefault", testSettingsAreOffAndUnsetByDefault),
            ("overridesAcceptOnlyTheirRanges", testOverridesAcceptOnlyTheirRanges),
            ("overridesMergeOverThePreset", testOverridesMergeOverThePreset),
            ("malformedOverridesReadAsThePreset", testMalformedOverridesReadAsThePreset),
            ("insertionWeightsOverOneReadAsThePreset", testInsertionWeightsOverOneReadAsThePreset),
            ("resetClearsOnlyTheOverrides", testResetClearsOnlyTheOverrides),
        ]
    }

    // MARK: Fixtures

    /// A preset in the bundle's form, with `changes` applied (NSNull for a JSON null).
    private static func preset(_ changes: [String: Any] = [:]) -> [String: Any] {
        var params: [String: Any] = [
            "p_omit": 0.02, "p_insert": 0.03, "p_transpose": 0.004, "max_edits": 2, "max_edits_short": 1, "short_length": 4,
            "min_length": 2, "lm_weight": 0.8, "log_oov": -9.0, "margin_oov": 4.0, "margin_known": NSNull(),
            "margin_apostrophe": 50.0, "w_repeat": 0.4, "w_slip": 0.35,
        ]
        for (key, value) in changes { params[key] = value }
        return params
    }

    /// The params `preset()` decodes to.
    private static let presetParams = AutocorrectParams(
        pOmit: 0.02, pInsert: 0.03, pTranspose: 0.004, maxEdits: 2, maxEditsShort: 1, shortLength: 4, minLength: 2,
        lmWeight: 0.8, logOOV: -9, marginOOV: 4, marginKnown: .infinity, marginApostrophe: 50, wRepeat: 0.4, wSlip: 0.35)

    private static func section(_ changes: [String: Any] = [:]) -> [String: Any] {
        var section: [String: Any] = [
            "format": 1,
            "lexicon": "autocorrect/lexicon.lfwl",
            "models": [
                "w2": ["kind": "lstm", "path": "autocorrect/w2.lfwr"],
                "w0": ["kind": "unigram"],
                "w1": ["kind": "ngram", "path": "autocorrect/w1.lfwn"],
            ],
            "default_model": "w1",
            "presets": [
                "w0": ["balanced": preset(), "conservative": preset(["margin_oov": 10.0])],
                "w1": ["balanced": preset(["lm_weight": 1.2]), "conservative": preset(["margin_oov": NSNull()])],
                "w2": ["balanced": preset(["log_oov": -12.0])],
            ],
            "default_preset": "balanced",
        ]
        for (key, value) in changes { section[key] = value }
        return section
    }

    private static let tapTouch: [String: Any] = [
        "sigma": 0.3, "ratio": 1.2, "offset_y": 0.15, "tail_weight": 0.1, "tail_scale": 3.0, "space_spread": 0.5,
    ]

    private static func tapSection(touch: [String: Any] = tapTouch, centre: Double = 0.6) -> [String: Any] {
        ["format": 1, "models": ["67k": "tap/b.bin"], "default_model": "67k", "touch": touch,
         "rule": ["centre": centre, "margin": 3.0, "max_surprise": 3.0, "surprise_window": 8]]
    }

    private static func manifest(autocorrect: Any?, tap: [String: Any]? = nil) -> Data {
        var bundle: [String: Any] = [
            "format": 1, "decode": ["beam": 4, "top_k": 3, "length_power": 0.5, "freq_weight": 0.01, "length_bonus": 0.25],
            "files": ["lexicon.bin": "00"],
        ]
        if let autocorrect { bundle["autocorrect"] = autocorrect }
        if let tap { bundle["tap"] = tap }
        return try! JSONSerialization.data(withJSONObject: bundle)
    }

    private static func error(_ section: Any, tap: [String: Any]? = nil) -> AutocorrectManifest.ManifestError? {
        do {
            _ = try AutocorrectManifest.decode(from: manifest(autocorrect: section, tap: tap))
            return nil
        } catch {
            return error as? AutocorrectManifest.ManifestError
        }
    }

    private static func withSettings(_ body: (LocalFlowSettings, UserDefaults) -> Void) {
        let suite = "LocalFlowIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(LocalFlowSettings(defaults: defaults), defaults)
    }

    // MARK: Manifest

    private static func testManifestReadsTheSection() {
        let decoded = try! AutocorrectManifest.decode(from: manifest(autocorrect: section()))!
        TestSupport.expectEqual(decoded.lexicon, "autocorrect/lexicon.lfwl")
        TestSupport.expectEqual(decoded.models, [
            "w0": AutocorrectManifest.Model(kind: .unigram, path: nil),
            "w1": AutocorrectManifest.Model(kind: .ngram, path: "autocorrect/w1.lfwn"),
            "w2": AutocorrectManifest.Model(kind: .lstm, path: "autocorrect/w2.lfwr"),
        ])
        TestSupport.expectEqual(decoded.defaultModel, "w1")
        TestSupport.expectEqual(decoded.defaultPreset, "balanced")
        // Null margins are infinite.
        TestSupport.expectEqual(decoded.presets["w0"]?["balanced"], presetParams)
        var conservative = presetParams
        conservative.lmWeight = 0.8
        conservative.marginOOV = .infinity
        TestSupport.expectEqual(decoded.presets["w1"]?["conservative"], conservative)
        TestSupport.expectEqual(decoded.presets["w2"]?["balanced"]?.logOOV, -12)
        // No touch section in either: the keyboard uses the standard touch model.
        TestSupport.expectEqual(decoded.touch, nil)
        // Its own touch model wins over the tap section's.
        var own = section()
        own["touch"] = ["sigma": 0.2, "ratio": 1.0, "offset_y": 0.0, "tail_weight": 0.0, "tail_scale": 2.0, "space_spread": 0.6]
        TestSupport.expectEqual(try! AutocorrectManifest.decode(from: manifest(autocorrect: own, tap: tapSection()))?.touch,
                                SoftKeyEdgesManifest.Touch(sigma: 0.2, ratio: 1, offsetY: 0, tailWeight: 0, tailScale: 2, spaceSpread: 0.6))
    }

    private static func testManifestWithoutTheSectionHasNoAutocorrect() {
        TestSupport.expectEqual(try! AutocorrectManifest.decode(from: manifest(autocorrect: nil)), nil)
        TestSupport.expectEqual(try! AutocorrectManifest.decode(from: manifest(autocorrect: nil, tap: tapSection())), nil)
    }

    private static func testManifestTouchFallsBackToTheTapSection() {
        let decoded = try! AutocorrectManifest.decode(from: manifest(autocorrect: section(), tap: tapSection()))!
        TestSupport.expectEqual(decoded.touch, SoftKeyEdgesManifest.Touch(sigma: 0.3, ratio: 1.2, offsetY: 0.15, tailWeight: 0.1,
                                                                        tailScale: 3, spaceSpread: 0.5))
        // An invalid tap section gives no touch model (standard), and never rejects autocorrect.
        let invalidTap = try! AutocorrectManifest.decode(from: manifest(autocorrect: section(), tap: tapSection(centre: 0.99)))
        TestSupport.expect(invalidTap != nil, "an invalid tap section rejected autocorrect")
        TestSupport.expectEqual(invalidTap?.touch, nil)
    }

    private static func testManifestRejectsAnInvalidSection() {
        TestSupport.expectEqual(error(section(["format": 2])), .unsupportedFormat)
        for path in ["", "/a.lfwl", "../a.lfwl", "autocorrect/../a.lfwl", "autocorrect//a.lfwl", "./a.lfwl"] {
            TestSupport.expect(error(section(["lexicon": path])) == .invalidLexicon, "lexicon \(path)")
        }
        TestSupport.expectEqual(error(section(["default_model": "w9"])), .invalidModels)
        TestSupport.expectEqual(error(section(["models": [String: Any](), "presets": [String: Any]()])), .invalidModels)
        // A path is required for n-gram and LSTM models, inside the bundle, and never given for unigram.
        TestSupport.expectEqual(error(section(["models": ["w1": ["kind": "ngram"]], "presets": ["w1": ["balanced": preset()]]])),
                                .invalidModels)
        TestSupport.expectEqual(error(section(["models": ["w1": ["kind": "lstm", "path": "../w.lfwr"]],
                                               "presets": ["w1": ["balanced": preset()]]])), .invalidModels)
        TestSupport.expectEqual(error(section(["models": ["w1": ["kind": "unigram", "path": "w.bin"]],
                                               "presets": ["w1": ["balanced": preset()]], "default_model": "w1"])), .invalidModels)
        // Every model needs its presets with the default one; presets of unlisted models are invalid.
        TestSupport.expectEqual(error(section(["default_preset": "aggressive"])), .invalidPresets)
        TestSupport.expectEqual(error(section(["presets": ["w0": ["balanced": preset()], "w1": ["balanced": preset()]]])),
                                .invalidPresets)
        TestSupport.expectEqual(error(section(["presets": ["w0": ["balanced": preset()], "w1": ["balanced": preset()],
                                                           "w2": ["balanced": preset()], "w3": ["balanced": preset()]]])),
                                .invalidPresets)
        // An invalid touch model of its own.
        var touch = tapTouch
        touch["tail_weight"] = 1.0
        TestSupport.expectEqual(error(section(["touch": touch])), .invalidTouch)
        // A section of the wrong shape (a missing parameter, an unknown kind, a string margin) throws too.
        var missing = preset()
        missing["w_slip"] = nil
        for broken: [String: Any] in [
            ["presets": ["w0": ["balanced": missing], "w1": ["balanced": preset()], "w2": ["balanced": preset()]]],
            ["models": ["w0": ["kind": "trigram", "path": "w.bin"]]],
            ["presets": ["w0": ["balanced": preset(["margin_oov": "inf"])], "w1": ["balanced": preset()], "w2": ["balanced": preset()]]],
        ] {
            TestSupport.expect((try? AutocorrectManifest.decode(from: manifest(autocorrect: section(broken)))) == nil, "\(broken)")
        }
        TestSupport.expect((try? AutocorrectManifest.decode(from: manifest(autocorrect: ["format": 1]))) == nil, "incomplete")
    }

    private static func testManifestRejectsPresetsOutOfTheirDomain() {
        func rejects(_ changes: [String: Any]) -> Bool {
            error(section(["presets": ["w0": ["balanced": preset(changes)], "w1": ["balanced": preset()],
                                       "w2": ["balanced": preset()]]])) == .invalidPresets
        }
        for change: [String: Any] in [
            ["p_omit": 0.0], ["p_insert": 1.0], ["p_transpose": -0.1], ["max_edits": 4], ["max_edits_short": -1],
            ["short_length": 0], ["min_length": 0], ["min_length": 33], ["lm_weight": -0.5], ["log_oov": 0.0], ["log_oov": 0.5],
            ["margin_oov": 0.5], ["margin_known": 0.0], ["w_repeat": 1.5], ["w_slip": -0.1], ["w_repeat": 0.7, "w_slip": 0.4],
        ] {
            TestSupport.expect(rejects(change), "accepted \(change)")
        }
        // Values outside the sliders' narrower ranges are still valid presets.
        for change: [String: Any] in [["margin_oov": 100.0], ["p_omit": 0.2], ["log_oov": -30.0], ["lm_weight": 3.0],
                                      ["short_length": 8], ["w_repeat": 0.5, "w_slip": 0.5], ["max_edits": 0]] {
            TestSupport.expect(!rejects(change), "rejected \(change)")
        }
    }

    private static func testAnInvalidSectionRejectsOnlyAutocorrect() {
        let data = manifest(autocorrect: section(["format": 2]), tap: tapSection())
        TestSupport.expect((try? AutocorrectManifest.decode(from: data)) == nil, "invalid section accepted")
        TestSupport.expect((try? SoftKeyEdgesManifest.decode(from: data)) != nil, "soft key edges rejected")
        TestSupport.expectEqual(try? SwipeBundleManifest.decodeConfig(from: data),
                                SwipeDecodeConfig(beam: 4, topK: 3, lengthPower: 0.5, freqWeight: 0.01, lengthBonus: 0.25))
    }

    private static func testManifestResolvesModelsAndPresets() {
        let decoded = try! AutocorrectManifest.decode(from: manifest(autocorrect: section()))!
        // Unigram, then n-gram, then LSTM.
        TestSupport.expectEqual(decoded.modelNames, ["w0", "w1", "w2"])
        TestSupport.expectEqual(decoded.modelName("w2"), "w2")
        TestSupport.expectEqual(decoded.modelName("w9"), "w1")
        TestSupport.expectEqual(decoded.modelName(nil), "w1")
        // The default preset first.
        TestSupport.expectEqual(decoded.presetNames(model: "w0"), ["balanced", "conservative"])
        TestSupport.expectEqual(decoded.presetNames(model: "w2"), ["balanced"])
        TestSupport.expectEqual(decoded.presetName("conservative", model: "w0"), "conservative")
        TestSupport.expectEqual(decoded.presetName("conservative", model: "w2"), "balanced")
        TestSupport.expectEqual(decoded.presetName(nil, model: "w1"), "balanced")
        TestSupport.expectEqual(decoded.params(model: "w0", preset: "conservative").marginOOV, 10)
        TestSupport.expectEqual(decoded.params(model: nil, preset: nil).lmWeight, 1.2)
        TestSupport.expectEqual(decoded.params(model: "w9", preset: "conservative").marginOOV, .infinity)
        TestSupport.expectEqual(decoded.params(model: "w2", preset: "conservative").logOOV, -12)
    }

    private static func testPresetNamesOrderNumbersByValue() {
        let presets: [String: Any] = ["w0": ["1:10": preset(), "1:1": preset(), "1:5": preset(), "1:3": preset()],
                                      "w1": ["1:3": preset()],
                                      "w2": ["1:10": preset(), "1:3": preset()]]
        let decoded = try! AutocorrectManifest.decode(
            from: manifest(autocorrect: section(["presets": presets, "default_preset": "1:3"])))!
        // The default first, then the rest with their numbers compared by value, not by character.
        TestSupport.expectEqual(decoded.presetNames(model: "w0"), ["1:3", "1:1", "1:5", "1:10"])
        TestSupport.expectEqual(decoded.presetNames(model: "w2"), ["1:3", "1:10"])
    }

    // MARK: Spelling channel

    private static func testManifestReadsTheSpellingChannel() {
        // No spelling path: none, and presets without w_spelling (bundles from before the channel) have 0.
        let plain = try! AutocorrectManifest.decode(from: manifest(autocorrect: section()))!
        TestSupport.expectEqual(plain.spelling, nil)
        TestSupport.expect(plain.presets.values.allSatisfy { $0.values.allSatisfy { $0.wSpelling == 0 } }, "w_spelling 0")
        // A path, and presets that use it (or give 0 explicitly).
        let spelled = try! AutocorrectManifest.decode(from: manifest(autocorrect: section([
            "spelling": "autocorrect/spelling.lfwe",
            "presets": ["w0": ["balanced": preset(["w_spelling": 0.1])], "w1": ["balanced": preset(["w_spelling": 0.0])],
                        "w2": ["balanced": preset(["w_spelling": 3.0])]],
        ])))!
        TestSupport.expectEqual(spelled.spelling, "autocorrect/spelling.lfwe")
        var expected = presetParams
        expected.wSpelling = 0.1
        TestSupport.expectEqual(spelled.presets["w0"]?["balanced"], expected)
        TestSupport.expectEqual(spelled.presets["w1"]?["balanced"]?.wSpelling, 0)
        TestSupport.expectEqual(spelled.presets["w2"]?["balanced"]?.wSpelling, 3)  // the slider's range is not required
        // Paths outside the bundle, and weights outside the domain.
        for path in ["", "/s.lfwe", "../s.lfwe", "autocorrect/../s.lfwe", "autocorrect//s.lfwe", "./s.lfwe"] {
            TestSupport.expect(error(section(["spelling": path])) == .invalidSpelling, "spelling \(path)")
        }
        for weight in [-0.1, -1e-300] {
            TestSupport.expect(error(section(["spelling": "s.lfwe", "presets": ["w0": ["balanced": preset(["w_spelling": weight])],
                                                                             "w1": ["balanced": preset()], "w2": ["balanced": preset()]]]))
                == .invalidPresets, "w_spelling \(weight)")
        }
        TestSupport.expect((try? AutocorrectManifest.decode(from: manifest(autocorrect: section([
            "spelling": "s.lfwe",
            "presets": ["w0": ["balanced": preset(["w_spelling": "0.1"])], "w1": ["balanced": preset()], "w2": ["balanced": preset()]],
        ])))) == nil, "a string weight")
    }

    private static func testSpellingPresetsNeedTheTables() {
        // A preset with w_spelling > 0 in a section without tables is inconsistent: the section is refused
        // (only autocorrect; soft key edges and swipe stay), as the exporter refuses to write it.
        let presets: [String: Any] = ["w0": ["balanced": preset(), "conservative": preset(["w_spelling": 0.03])],
                                      "w1": ["balanced": preset()], "w2": ["balanced": preset()]]
        TestSupport.expectEqual(error(section(["presets": presets])), .invalidSpelling)
        let data = manifest(autocorrect: section(["presets": presets]), tap: tapSection())
        TestSupport.expect((try? SoftKeyEdgesManifest.decode(from: data)) != nil, "soft key edges rejected")
        TestSupport.expectEqual(error(section(["presets": presets, "spelling": "autocorrect/spelling.lfwe"])), nil)
    }

    /// An invented bundle directory: the lexicon, optionally spelling tables, and the manifest's section.
    private static func withBundle(spelling: Data?, _ body: (URL) -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFlowIOSTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = directory.appendingPathComponent("autocorrect")
        try! FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try! AutocorrectTestFiles.lexicon([("cat", 200), ("the", 250), ("receive", 150)]).write(to: files.appendingPathComponent("lexicon.lfwl"))
        if let spelling { try! spelling.write(to: files.appendingPathComponent("spelling.lfwe")) }
        body(directory)
    }

    private static func testLoaderReadsTheSpellingTables() {
        let tables = AutocorrectTestFiles.flatSpelling(log(1e-6), ["trans": [("e", "i", 0.5)]])
        let good = AutocorrectTestFiles.spelling(tables)
        let named = try! AutocorrectManifest.decode(from: manifest(autocorrect: section([
            "spelling": "autocorrect/spelling.lfwe",
            "presets": ["w0": ["balanced": preset(["w_spelling": 1.0])], "w1": ["balanced": preset()], "w2": ["balanced": preset()]],
        ])))!
        let unnamed = try! AutocorrectManifest.decode(from: manifest(autocorrect: section()))!
        func load(_ manifest: AutocorrectManifest, _ url: URL) -> Autocorrector? {
            AutocorrectLoader.load(manifest: manifest, bundleURL: url, model: "w0") as? Autocorrector
        }
        withBundle(spelling: good) { url in
            // Named: read, widened from float32; the corrector uses them (a cognitive misspelling is corrected).
            let corrector = load(named, url)
            TestSupport.expect(corrector?.spelling == (try! SpellingTables(data: good)), "tables loaded")
            let p = named.params(model: "w0", preset: nil)
            var motor = p
            motor.wSpelling = 0
            let points = AutocorrectCoreTests.centreTaps("recieve"), keys = AutocorrectCoreTests.keys
            TestSupport.expectEqual(corrector?.correct(context: "", word: "recieve", points: points, keys: keys, params: p), "receive")
            TestSupport.expectEqual(corrector?.correct(context: "", word: "recieve", points: points, keys: keys, params: motor), "recieve")
            // Not named: a motor-only corrector, the file ignored.
            let plain = load(unnamed, url)
            TestSupport.expect(plain != nil && plain?.spelling == nil, "motor-only corrector")
        }
        // Named but missing or invalid: no corrector, as for any other file it needs.
        withBundle(spelling: nil) { url in
            TestSupport.expect(load(named, url) == nil, "missing tables loaded")
            TestSupport.expect(load(unnamed, url) != nil, "a bundle without tables")
        }
        var badMagic = good
        badMagic.replaceSubrange(0 ..< 4, with: Array("LFWL".utf8))
        var badValue = good
        badValue.replaceSubrange(12 ..< 16, with: withUnsafeBytes(of: Float(0.5).bitPattern.littleEndian) { Array($0) })
        for (name, data) in [("bad magic", badMagic), ("short", good.dropLast(4)), ("long", good + Data(count: 8)), ("bad value", badValue),
                             ("empty", Data())] {
            withBundle(spelling: Data(data)) { url in TestSupport.expect(load(named, url) == nil, "\(name) tables loaded") }
        }
    }

    private static func testSpellingOverrideAcceptsItsRangeAndMerges() {
        withSettings { settings, defaults in
            TestSupport.expectEqual(AutocorrectSetting.wSpelling.range, 0 ... 1)
            for value in [0, 0.001, 0.03, 1] {
                settings.setAutocorrectOverride(.wSpelling, value)
                TestSupport.expect(settings.autocorrectOverride(.wSpelling) == value, "\(value) not stored")
            }
            for value in [-0.1, 1.5, .nan, .infinity, -.infinity] {
                settings.setAutocorrectOverride(.wSpelling, value)
                TestSupport.expect(settings.autocorrectOverride(.wSpelling) == 1, "\(value) stored")
            }
            for stored: Any in ["0.1", true, -1.0, 3.0] {
                defaults.set(stored, forKey: "autocorrectParam.w_spelling")
                TestSupport.expect(settings.autocorrectOverride(.wSpelling) == nil, "\(stored) read")
            }
            var preset = presetParams
            preset.wSpelling = 0.3
            TestSupport.expectEqual(settings.autocorrectParams(over: preset).wSpelling, 0.3)
            settings.setAutocorrectOverride(.wSpelling, 0.01)
            TestSupport.expectEqual(settings.autocorrectParams(over: preset).wSpelling, 0.01)
            TestSupport.expectEqual(settings.autocorrectParams(over: presetParams).wSpelling, 0.01)
            settings.resetAutocorrectParams()
            TestSupport.expectEqual(settings.autocorrectParams(over: preset).wSpelling, 0.3)
        }
    }

    // MARK: Settings

    private static func testSettingsAreOffAndUnsetByDefault() {
        withSettings { settings, defaults in
            TestSupport.expect(!settings.autocorrectEnabled, "on by default")
            TestSupport.expectEqual(settings.autocorrectModel, nil)
            TestSupport.expectEqual(settings.autocorrectPreset, nil)
            for setting in AutocorrectSetting.allCases {
                TestSupport.expectEqual(settings.autocorrectOverride(setting), nil)
                TestSupport.expectEqual(defaults.object(forKey: "autocorrectParam.\(setting.rawValue)") == nil, true)
            }
            TestSupport.expectEqual(settings.autocorrectParams(over: presetParams), presetParams)
            settings.autocorrectEnabled = true
            settings.autocorrectModel = "w2"
            settings.autocorrectPreset = "conservative"
            let reread = LocalFlowSettings(defaults: defaults)
            TestSupport.expect(reread.autocorrectEnabled, "enabled stored")
            TestSupport.expectEqual(reread.autocorrectModel, "w2")
            TestSupport.expectEqual(reread.autocorrectPreset, "conservative")
            // Invalid names forget the choice; an invalid stored value reads as unset.
            settings.autocorrectModel = ""
            TestSupport.expectEqual(settings.autocorrectModel, nil)
            settings.autocorrectPreset = String(repeating: "p", count: 65)
            TestSupport.expectEqual(settings.autocorrectPreset, nil)
            defaults.set(3, forKey: "autocorrectModel")
            TestSupport.expectEqual(settings.autocorrectModel, nil)
            defaults.set("yes", forKey: "autocorrectEnabled")
            TestSupport.expect(!settings.autocorrectEnabled, "invalid enabled value")
            // The names are the contract (w_spelling since the spelling channel, 2026-10-20).
            TestSupport.expectEqual(AutocorrectSetting.allCases.map(\.rawValue),
                                    ["log_oov", "margin_oov", "margin_known", "margin_apostrophe", "lm_weight", "p_omit", "p_insert",
                                     "p_transpose", "w_repeat", "w_slip", "short_length", "w_spelling"])
        }
    }

    private static func testOverridesAcceptOnlyTheirRanges() {
        withSettings { settings, defaults in
            let accepted: [(AutocorrectSetting, [Double])] = [
                (.logOOV, [log(1e-10), log(1e-5), log(1e-1)]), (.marginOOV, [1, 12.5, 30]), (.marginKnown, [1, 300, 1000, .infinity]),
                (.marginApostrophe, [1, 1000, .infinity]), (.lmWeight, [0.25, 2]), (.pOmit, [0.001, 0.1]), (.pInsert, [0.05]),
                (.pTranspose, [0.001]), (.wRepeat, [0, 1]), (.wSlip, [0.5]), (.shortLength, [3, 4, 5]),
            ]
            for (setting, values) in accepted {
                for value in values {
                    settings.setAutocorrectOverride(setting, value)
                    TestSupport.expect(settings.autocorrectOverride(setting) == value, "\(setting) \(value) not stored")
                }
            }
            // Infinity is stored as text; property lists have none.
            TestSupport.expectEqual(defaults.object(forKey: "autocorrectParam.margin_known") as? String, "inf")
            let rejected: [(AutocorrectSetting, [Double])] = [
                (.logOOV, [log(1e-11), 0, -.infinity]), (.marginOOV, [0.5, 31, .infinity]), (.marginKnown, [0.9, 1001, .nan]),
                (.lmWeight, [0.2, 2.5]), (.pOmit, [0.0009, 0.2]), (.wRepeat, [-0.1, 1.1]), (.shortLength, [2, 6, 3.5]),
            ]
            for (setting, values) in rejected {
                let before = settings.autocorrectOverride(setting)
                for value in values {
                    settings.setAutocorrectOverride(setting, value)
                    TestSupport.expect(settings.autocorrectOverride(setting) == before, "\(setting) \(value) stored")
                }
            }
            // Nil forgets.
            settings.setAutocorrectOverride(.lmWeight, nil)
            TestSupport.expectEqual(settings.autocorrectOverride(.lmWeight), nil)
        }
    }

    private static func testOverridesMergeOverThePreset() {
        withSettings { settings, _ in
            settings.setAutocorrectOverride(.logOOV, log(1e-5))
            settings.setAutocorrectOverride(.marginOOV, 20)
            settings.setAutocorrectOverride(.marginKnown, 300)
            settings.setAutocorrectOverride(.marginApostrophe, .infinity)
            settings.setAutocorrectOverride(.lmWeight, 1.5)
            settings.setAutocorrectOverride(.pOmit, 0.05)
            settings.setAutocorrectOverride(.pInsert, 0.002)
            settings.setAutocorrectOverride(.pTranspose, 0.01)
            settings.setAutocorrectOverride(.wRepeat, 0.6)
            settings.setAutocorrectOverride(.wSlip, 0.2)
            settings.setAutocorrectOverride(.shortLength, 5)
            let merged = settings.autocorrectParams(over: presetParams)
            TestSupport.expectEqual(merged, AutocorrectParams(
                pOmit: 0.05, pInsert: 0.002, pTranspose: 0.01, maxEdits: 2, maxEditsShort: 1, shortLength: 5, minLength: 2,
                lmWeight: 1.5, logOOV: log(1e-5), marginOOV: 20, marginKnown: 300, marginApostrophe: .infinity, wRepeat: 0.6,
                wSlip: 0.2))
            // Merged over whichever preset is selected.
            var other = presetParams
            other.maxEdits = 1
            other.marginKnown = 2
            TestSupport.expectEqual(settings.autocorrectParams(over: other).maxEdits, 1)
            TestSupport.expectEqual(settings.autocorrectParams(over: other).marginKnown, 300)
        }
    }

    private static func testMalformedOverridesReadAsThePreset() {
        withSettings { settings, defaults in
            let malformed: [(String, Any)] = [
                ("log_oov", "1e-5"), ("margin_oov", "inf"), ("margin_known", "infinity"), ("margin_apostrophe", true),
                ("lm_weight", 9.0), ("p_omit", [0.01]), ("p_insert", 0.5), ("p_transpose", false), ("w_repeat", "0.2"),
                ("w_slip", -1.0), ("short_length", 4.5),
            ]
            for (name, value) in malformed { defaults.set(value, forKey: "autocorrectParam.\(name)") }
            for setting in AutocorrectSetting.allCases {
                TestSupport.expect(settings.autocorrectOverride(setting) == nil, "\(setting) read")
            }
            TestSupport.expectEqual(settings.autocorrectParams(over: presetParams), presetParams)
            // A stored whole number of another type still reads.
            defaults.set(4, forKey: "autocorrectParam.short_length")
            TestSupport.expectEqual(settings.autocorrectOverride(.shortLength), 4)
        }
    }

    private static func testInsertionWeightsOverOneReadAsThePreset() {
        withSettings { settings, _ in
            settings.setAutocorrectOverride(.wRepeat, 0.7)
            // 0.7 + 0.35 (the preset's w_slip) is over 1: both read as the preset's.
            var merged = settings.autocorrectParams(over: presetParams)
            TestSupport.expectEqual(merged.wRepeat, 0.4)
            TestSupport.expectEqual(merged.wSlip, 0.35)
            settings.setAutocorrectOverride(.wSlip, 0.3)
            merged = settings.autocorrectParams(over: presetParams)
            TestSupport.expectEqual(merged.wRepeat, 0.7)
            TestSupport.expectEqual(merged.wSlip, 0.3)
            // Exactly 1 is allowed.
            settings.setAutocorrectOverride(.wSlip, 0.3 + 1e-12)
            TestSupport.expectEqual(settings.autocorrectParams(over: presetParams).wRepeat, 0.7)
        }
    }

    private static func testResetClearsOnlyTheOverrides() {
        withSettings { settings, defaults in
            settings.autocorrectEnabled = true
            settings.autocorrectModel = "w2"
            settings.autocorrectPreset = "conservative"
            for setting in AutocorrectSetting.allCases {
                settings.setAutocorrectOverride(setting, setting.range.lowerBound)
            }
            settings.resetAutocorrectParams()
            for setting in AutocorrectSetting.allCases {
                TestSupport.expectEqual(settings.autocorrectOverride(setting), nil)
                TestSupport.expect(defaults.object(forKey: "autocorrectParam.\(setting.rawValue)") == nil, "\(setting) kept")
            }
            TestSupport.expectEqual(settings.autocorrectParams(over: presetParams), presetParams)
            TestSupport.expect(settings.autocorrectEnabled, "reset turned autocorrect off")
            TestSupport.expectEqual(settings.autocorrectModel, "w2")
            TestSupport.expectEqual(settings.autocorrectPreset, "conservative")
        }
    }
}
