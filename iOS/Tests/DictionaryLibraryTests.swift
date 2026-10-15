import Foundation

/// `DictionaryLibrary` over an isolated `UserDefaults` suite and a synthetic vocabulary. All words are invented.
enum DictionaryLibraryTests {
    static var tests: [TestCase] {
        [
            ("emptyStorage", isolated(testEmptyStorage)),
            ("savePersistsAndRaisesRevision", isolated(testSavePersistsAndRaisesRevision)),
            ("editRenamesAndRemoveDeletes", isolated(testEditRenamesAndRemoveDeletes)),
            ("invalidTextChangesNothing", isolated(testInvalidTextChangesNothing)),
            ("noVocabularyRefusesEdits", isolated(testNoVocabularyRefusesEdits)),
            ("unreadableDataIsKeptUntilReset", isolated(testUnreadableDataIsKeptUntilReset)),
            ("macFormatLoadsAndKeepsIgnoreList", isolated(testMacFormatLoadsAndKeepsIgnoreList)),
            ("setStrengthKeepsText", isolated(testSetStrengthKeepsText)),
            ("strengthSteps", isolated(testStrengthSteps)),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    /// Every lowercase and uppercase letter as its own piece, so any invented word is encodable; "#" is not.
    private static let encoder: BPEEncoder = {
        var pieces = ["<unk>", "▁"]
        pieces += "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars.map { String($0) }
        return BPEEncoder(pieces: pieces)
    }()

    /// A fresh suite, removed when `body` returns.
    @MainActor
    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "LocalFlowIOSTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @MainActor
    private static func testEmptyStorage() {
        withDefaults { defaults in
            let library = DictionaryLibrary(defaults: defaults, encoder: encoder)
            TestSupport.expectEqual(library.entries, [])
            TestSupport.expectEqual(library.snapshotEntries, [])
            TestSupport.expect(!library.loadFailed, "empty storage is not a failure")
            TestSupport.expect(library.canEdit, "empty storage refuses edits")
            TestSupport.expect(!library.isFull, "empty dictionary is full")
        }
    }

    @MainActor
    private static func testSavePersistsAndRaisesRevision() {
        withDefaults { defaults in
            let library = DictionaryLibrary(defaults: defaults, encoder: encoder)
            var changes = 0
            library.onChange = { changes += 1 }
            let before = library.revision
            TestSupport.expectEqual(library.save(text: "  Zorblax  ", strength: 2, replacing: nil), nil)
            TestSupport.expectEqual(library.entries, [DictionaryEntry(text: "Zorblax", strength: 2)])
            TestSupport.expectEqual(library.snapshotEntries, library.entries)
            TestSupport.expect(library.revision > before, "revision did not rise")
            TestSupport.expectEqual(changes, 1)

            let reloaded = DictionaryLibrary(defaults: defaults, encoder: encoder)
            TestSupport.expectEqual(reloaded.entries, [DictionaryEntry(text: "Zorblax", strength: 2)])
        }
    }

    @MainActor
    private static func testEditRenamesAndRemoveDeletes() {
        withDefaults { defaults in
            let library = DictionaryLibrary(defaults: defaults, encoder: encoder)
            _ = library.save(text: "Zorblax", strength: 1, replacing: nil)
            _ = library.save(text: "Quint Morrow", strength: 1.41, replacing: nil)
            let revision = library.revision
            TestSupport.expectEqual(library.save(text: "Zorblaxx", strength: 4, replacing: DictionaryKey("Zorblax")), nil)
            TestSupport.expect(!library.entries.contains { $0.text == "Zorblax" }, "the old entry stayed")
            TestSupport.expect(library.entries.contains(DictionaryEntry(text: "Zorblaxx", strength: 4)), "edit lost")
            TestSupport.expectEqual(library.entries.count, 2)
            TestSupport.expect(library.revision > revision, "edit did not raise revision")

            let afterEdit = library.revision
            library.remove(DictionaryKey("Quint Morrow"))
            TestSupport.expectEqual(library.entries, [DictionaryEntry(text: "Zorblaxx", strength: 4)])
            TestSupport.expect(library.revision > afterEdit, "remove did not raise revision")
            TestSupport.expectEqual(DictionaryLibrary(defaults: defaults, encoder: encoder).entries,
                                    [DictionaryEntry(text: "Zorblaxx", strength: 4)])
        }
    }

    @MainActor
    private static func testInvalidTextChangesNothing() {
        withDefaults { defaults in
            let library = DictionaryLibrary(defaults: defaults, encoder: encoder)
            _ = library.save(text: "Zorblax", strength: 1, replacing: nil)
            let stored = defaults.object(forKey: DictionaryLibrary.entriesKey) as? Data
            let revision = library.revision
            TestSupport.expectEqual(library.save(text: "   ", strength: 1, replacing: nil), DictionaryEntryError.empty.message)
            TestSupport.expectEqual(library.save(text: "Zor#blax", strength: 1, replacing: nil),
                                    DictionaryEntryError.unencodable.message)
            TestSupport.expectEqual(library.save(text: "Quint", strength: 9, replacing: nil),
                                    DictionaryEntryError.invalidStrength.message)
            TestSupport.expectEqual(library.revision, revision)
            TestSupport.expectEqual(library.entries, [DictionaryEntry(text: "Zorblax", strength: 1)])
            TestSupport.expectEqual(defaults.object(forKey: DictionaryLibrary.entriesKey) as? Data, stored)
        }
    }

    @MainActor
    private static func testNoVocabularyRefusesEdits() {
        withDefaults { defaults in
            let library = DictionaryLibrary(defaults: defaults, encoder: nil)
            TestSupport.expect(!library.canEdit, "edits allowed without a vocabulary")
            TestSupport.expectEqual(library.save(text: "Zorblax", strength: 1, replacing: nil), DictionaryEditor.unavailableMessage)
            TestSupport.expectEqual(library.entries, [])
            TestSupport.expectEqual(defaults.object(forKey: DictionaryLibrary.entriesKey) == nil, true)
        }
    }

    @MainActor
    private static func testUnreadableDataIsKeptUntilReset() {
        for bad in [Data("not json".utf8) as Any, "a string, not data" as Any] {
            withDefaults { defaults in
                defaults.set(bad, forKey: DictionaryLibrary.entriesKey)
                let library = DictionaryLibrary(defaults: defaults, encoder: encoder)
                TestSupport.expect(library.loadFailed, "unreadable data loaded")
                TestSupport.expectEqual(library.entries, [])
                TestSupport.expectEqual(library.snapshotEntries, [])
                TestSupport.expect(!library.canEdit, "edits allowed over unreadable data")
                TestSupport.expect(library.save(text: "Zorblax", strength: 1, replacing: nil) != nil, "save over unreadable data")
                TestSupport.expect(library.setStrength(2, for: DictionaryKey("Zorblax")) != nil, "strength over unreadable data")
                TestSupport.expect((defaults.object(forKey: DictionaryLibrary.entriesKey) as AnyObject).isEqual(bad),
                                   "unreadable data was overwritten")

                var changes = 0
                library.onChange = { changes += 1 }
                let revision = library.revision
                library.reset()
                TestSupport.expect(!library.loadFailed, "still failed after reset")
                TestSupport.expect(library.canEdit, "no edits after reset")
                TestSupport.expect(defaults.object(forKey: DictionaryLibrary.entriesKey) == nil, "reset kept the data")
                TestSupport.expect(library.revision > revision, "reset did not raise revision")
                TestSupport.expectEqual(changes, 1)
                TestSupport.expectEqual(library.save(text: "Zorblax", strength: 1, replacing: nil), nil)
            }
        }
    }

    @MainActor
    private static func testMacFormatLoadsAndKeepsIgnoreList() {
        withDefaults { defaults in
            // Written exactly as the macOS app writes it.
            defaults.set(Data(#"{"entries":[{"strength":1.41,"text":"Zorblax"}],"version":1}"#.utf8),
                         forKey: DictionaryLibrary.entriesKey)
            defaults.set(Data(#"{"ignore":["quint"],"version":1}"#.utf8), forKey: DictionaryLibrary.ignoreKey)
            let library = DictionaryLibrary(defaults: defaults, encoder: encoder)
            TestSupport.expect(!library.loadFailed, "macOS data did not load")
            TestSupport.expectEqual(library.entries, [DictionaryEntry(text: "Zorblax", strength: 1.41)])
            _ = library.save(text: "Morrow", strength: 1, replacing: nil)
            let reloaded = DictionaryLibrary(defaults: defaults, encoder: encoder)
            TestSupport.expectEqual(reloaded.dictionary.ignore, [DictionaryKey("quint")])
            TestSupport.expectEqual(reloaded.entries.count, 2)
        }
    }

    @MainActor
    private static func testSetStrengthKeepsText() {
        withDefaults { defaults in
            let library = DictionaryLibrary(defaults: defaults, encoder: encoder)
            _ = library.save(text: "Zorblax", strength: 1, replacing: nil)
            _ = library.save(text: "Morrow", strength: 1, replacing: nil)
            TestSupport.expectEqual(library.setStrength(2.83, for: DictionaryKey("zorblax")), nil)
            TestSupport.expectEqual(library.entries, [DictionaryEntry(text: "Zorblax", strength: 2.83),
                                                      DictionaryEntry(text: "Morrow", strength: 1)])
            TestSupport.expectEqual(library.setStrength(9, for: DictionaryKey("Zorblax")),
                                    DictionaryEntryError.invalidStrength.message)
            TestSupport.expect(library.setStrength(2, for: DictionaryKey("Quint")) != nil, "a missing entry was set")
            TestSupport.expectEqual(library.entries.count, 2)
            TestSupport.expectEqual(DictionaryLibrary(defaults: defaults, encoder: encoder).entries.first,
                                    DictionaryEntry(text: "Zorblax", strength: 2.83))
        }
    }

    @MainActor
    private static func testStrengthSteps() {
        TestSupport.expectEqual(DictionaryLibrary.strength(above: 1), 1.41)
        TestSupport.expectEqual(DictionaryLibrary.strength(below: 1), 0.5)
        TestSupport.expectEqual(DictionaryLibrary.strength(above: 5.66), 8)
        TestSupport.expectEqual(DictionaryLibrary.strength(above: 8), nil)
        TestSupport.expectEqual(DictionaryLibrary.strength(below: 0.5), nil)
        // Between presets (or below the lowest), the next preset in that direction.
        TestSupport.expectEqual(DictionaryLibrary.strength(above: 3), 4)
        TestSupport.expectEqual(DictionaryLibrary.strength(below: 3), 2.83)
        TestSupport.expectEqual(DictionaryLibrary.strength(above: 0.25), 0.5)
        TestSupport.expectEqual(DictionaryLibrary.strength(below: 0.25), nil)
    }
}
