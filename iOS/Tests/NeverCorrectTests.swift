import Foundation

/// Never correct (ARCHITECTURE.md, "Word autocorrect", Never correct; requested by the owner 2026-10-20): a revert
/// offers to never correct its word, only a tap on the offer stores it, and stored words are never corrected or
/// offered. Also the bounded list and its file in the App Group. Every word is invented; every file lives in a
/// temporary directory.
enum NeverCorrectTests {
    static var tests: [TestCase] {
        [
            ("directoryIsInGroupApplicationSupport", testDirectoryIsInGroupApplicationSupport),
            ("onlyCorrectorWordsAreStorable", testOnlyCorrectorWordsAreStorable),
            ("boundDropsTheLeastRecentlyAddedFirst", testBoundDropsTheLeastRecentlyAddedFirst),
            ("listDropsInvalidAndRepeatedWords", testListDropsInvalidAndRepeatedWords),
            ("missingFileReadsAsEmptyAndCreatesNothing", testMissingFileReadsAsEmptyAndCreatesNothing),
            ("addedWordsOutliveTheStore", testAddedWordsOutliveTheStore),
            ("storedListIsBounded", testStoredListIsBounded),
            ("corruptFilesReadAsEmptyAndAreReplaced", testCorruptFilesReadAsEmptyAndAreReplaced),
            ("invalidEntriesAreDroppedOnRead", testInvalidEntriesAreDroppedOnRead),
            ("failedWriteLeavesTheFile", testFailedWriteLeavesTheFile),
            ("writesLeaveOnlyTheFile", testWritesLeaveOnlyTheFile),
            ("clearForgetsEverything", testClearForgetsEverything),
            ("aClearDuringAnAddNeverBringsWordsBack", testAClearDuringAnAddNeverBringsWordsBack),
            ("createsDirectoryExcludedFromBackup", testCreatesDirectoryExcludedFromBackup),
            ("aRevertAloneStoresNothing", testARevertAloneStoresNothing),
            ("aRevertOffersToNeverCorrectTheWord", testARevertOffersToNeverCorrectTheWord),
            ("acceptingStoresTheWordForEveryInstance", testAcceptingStoresTheWordForEveryInstance),
            ("acceptingFromTheStripClosesIt", testAcceptingFromTheStripClosesIt),
            ("anythingElseEndsTheOffer", testAnythingElseEndsTheOffer),
            ("ownEchoesKeepTheOffer", testOwnEchoesKeepTheOffer),
            ("noOfferWithoutAStoreOrForAWordItCannotKeep", testNoOfferWithoutAStoreOrForAWordItCannotKeep),
            ("bindingAStoreReplacesTheWordsInMemory", testBindingAStoreReplacesTheWordsInMemory),
            ("nothingIsOfferedWhereNothingIsCorrected", testNothingIsOfferedWhereNothingIsCorrected),
            ("dictationUIWinsTheBar", testDictationUIWinsTheBar),
        ]
    }

    private static func withStore(_ body: (NeverCorrectStore) -> Void) {
        let root = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        body(NeverCorrectStore(directory: NeverCorrectStore.directory(inContainer: root)))
    }

    private static func put(_ data: Data, in store: NeverCorrectStore) {
        try! FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try! data.write(to: store.fileURL)
    }

    private static func fileNames(in store: NeverCorrectStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).sorted()
    }

    private static func storeIsEmpty(_ store: NeverCorrectStore) -> Bool {
        !FileManager.default.fileExists(atPath: store.directory.path)
    }

    /// Invented words of letters only: "qa", "qb", ... "qaa", ...
    private static func syntheticWord(_ index: Int) -> String {
        var letters = ""
        var value = index
        repeat {
            letters.append(Character(Unicode.Scalar(UInt8(97 + value % 26))))
            value /= 26
        } while value > 0
        return "q" + letters
    }

    /// A rig with a store bound, as the keyboard binds it when it appears with autocorrect on.
    private static func rig(_ store: NeverCorrectStore, corrections: [String: String] = ["teh": "the"],
                            alternatives: [String: [String]] = [:]) -> AutocorrectRig {
        let rig = AutocorrectRig("", corrections: corrections, alternatives: alternatives)
        rig.editor.useNeverCorrectStore(store)
        return rig
    }

    /// Types "teh", a space (corrected to "the "), and a Delete that reverts it: the offer is up.
    private static func revert(_ rig: AutocorrectRig, _ word: String = "teh") {
        rig.tap(word)
        rig.press(.space)
        rig.heldDelete()
    }

    // MARK: The list

    private static func testDirectoryIsInGroupApplicationSupport() {
        let container = URL(fileURLWithPath: "/synthetic/container", isDirectory: true)
        TestSupport.expectEqual(NeverCorrectStore.directory(inContainer: container).path,
                                "/synthetic/container/Library/Application Support/LocalFlowAutocorrect")
        TestSupport.expectEqual(NeverCorrectStore(directory: NeverCorrectStore.directory(inContainer: container)).fileURL.path,
                                "/synthetic/container/Library/Application Support/LocalFlowAutocorrect/never-correct-words.json")
    }

    private static func testOnlyCorrectorWordsAreStorable() {
        for word in ["teh", "q", "can't", "o'clock", "rock'n'roll", String(repeating: "z", count: NeverCorrectWords.maximumLength)] {
            TestSupport.expect(NeverCorrectWords.isStorable(word), "\(word) is not storable")
        }
        for word in ["", "Teh", "TEH", "te h", "teh ", "'teh", "teh'", "'", "can\u{2019}t", "t3h", "tëh", "te-h", "te\nh",
                     String(repeating: "z", count: NeverCorrectWords.maximumLength + 1)] {
            TestSupport.expect(!NeverCorrectWords.isStorable(word), "\(word) is storable")
        }
        var words = NeverCorrectWords()
        TestSupport.expect(!words.insert("Teh"), "inserted a word that is not storable")
        TestSupport.expect(words.isEmpty, "a word that is not storable was kept")
    }

    private static func testBoundDropsTheLeastRecentlyAddedFirst() {
        var words = NeverCorrectWords()
        for index in 0 ..< NeverCorrectWords.limit { words.insert(syntheticWord(index)) }
        TestSupport.expectEqual(words.count, NeverCorrectWords.limit)
        // Added again, the oldest becomes the most recent, so the next word evicts the second oldest.
        words.insert(syntheticWord(0))
        words.insert("zzq")
        TestSupport.expectEqual(words.count, NeverCorrectWords.limit)
        TestSupport.expect(words.contains(syntheticWord(0)), "the word added again was evicted")
        TestSupport.expect(!words.contains(syntheticWord(1)), "the least recently added word was kept")
        TestSupport.expectEqual(Array(words.words.suffix(2)), [syntheticWord(0), "zzq"])
        TestSupport.expectEqual(words.words.first, syntheticWord(2))
    }

    private static func testListDropsInvalidAndRepeatedWords() {
        let words = NeverCorrectWords(["teh", "Wrld", "hte", "", "teh", "adn"])
        TestSupport.expectEqual(words.words, ["hte", "teh", "adn"])
        let many = NeverCorrectWords((0 ..< NeverCorrectWords.limit + 5).map(syntheticWord))
        TestSupport.expectEqual(many.count, NeverCorrectWords.limit)
        TestSupport.expectEqual(many.words.first, syntheticWord(5))
        TestSupport.expectEqual(many.words.last, syntheticWord(NeverCorrectWords.limit + 4))
    }

    // MARK: The file

    private static func testMissingFileReadsAsEmptyAndCreatesNothing() {
        withStore { store in
            TestSupport.expectEqual(store.load(), NeverCorrectWords())
            TestSupport.expectEqual(store.add("Teh"), NeverCorrectWords())
            TestSupport.expect(storeIsEmpty(store), "a read or a refused word created the directory")
        }
    }

    private static func testAddedWordsOutliveTheStore() {
        withStore { store in
            store.add("teh")
            store.add("wrld")
            TestSupport.expectEqual(store.add("hte").words, ["teh", "wrld", "hte"])
            let reopened = NeverCorrectStore(directory: store.directory)
            TestSupport.expectEqual(reopened.load().words, ["teh", "wrld", "hte"])
            // Adding a stored word again makes it the most recent.
            TestSupport.expectEqual(reopened.add("teh").words, ["wrld", "hte", "teh"])
            TestSupport.expectEqual(store.load().words, ["wrld", "hte", "teh"])
        }
    }

    private static func testStoredListIsBounded() {
        withStore { store in
            let words = (0 ..< NeverCorrectWords.limit).map(syntheticWord)
            put(Data((#"{"schema": 1, "words": ["# + words.map { "\"\($0)\"" }.joined(separator: ",") + "]}").utf8), in: store)
            TestSupport.expectEqual(store.load().count, NeverCorrectWords.limit)
            store.add("zzq")
            let stored = store.load()
            TestSupport.expectEqual(stored.count, NeverCorrectWords.limit)
            TestSupport.expect(!stored.contains(syntheticWord(0)), "the least recently added word was kept")
            TestSupport.expectEqual(stored.words.first, syntheticWord(1))
            TestSupport.expectEqual(stored.words.last, "zzq")
        }
    }

    private static func testCorruptFilesReadAsEmptyAndAreReplaced() {
        let corrupt: [Data] = [
            Data("not json".utf8),
            Data(),
            Data([0xFF, 0xFE, 0x00, 0x01]),
            Data(#"{"words": ["teh"]}"#.utf8),
            Data(#"{"schema": 2, "words": ["teh"]}"#.utf8),
            Data(#"{"schema": "1", "words": ["teh"]}"#.utf8),
            Data(#"{"schema": 1, "words": "teh"}"#.utf8),
            Data(#"{"schema": 1, "words": [1, 2]}"#.utf8),
            Data(#"["teh"]"#.utf8),
            // Larger than any list the keyboard writes.
            Data((#"{"schema": 1, "words": ["teh"], "pad": ""# + String(repeating: " ", count: NeverCorrectStore.maximumFileSize) + #""}"#).utf8),
        ]
        for data in corrupt {
            withStore { store in
                put(data, in: store)
                TestSupport.expectEqual(store.load(), NeverCorrectWords())
                TestSupport.expectEqual(store.add("wrld").words, ["wrld"])
                TestSupport.expectEqual(NeverCorrectStore(directory: store.directory).load().words, ["wrld"])
            }
        }
        // A directory where the file should be cannot be read either; nothing crashes.
        withStore { store in
            try! FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
            TestSupport.expectEqual(store.load(), NeverCorrectWords())
            TestSupport.expectEqual(store.add("wrld").words, ["wrld"])
        }
    }

    private static func testInvalidEntriesAreDroppedOnRead() {
        withStore { store in
            put(Data(#"{"schema": 1, "words": ["teh", "Wrld", "", "hte", "teh", "t3h"], "future": true}"#.utf8), in: store)
            TestSupport.expectEqual(store.load().words, ["hte", "teh"])
        }
    }

    private static func testFailedWriteLeavesTheFile() {
        withStore { store in
            store.add("teh")
            let path = store.directory.path
            try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
            defer { try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
            // The result is what the file would hold; the file keeps the earlier list, and no staging file is left.
            TestSupport.expectEqual(store.add("wrld").words, ["teh", "wrld"])
            TestSupport.expectEqual(store.load().words, ["teh"])
            TestSupport.expectEqual(fileNames(in: store), [NeverCorrectStore.fileName])
        }
    }

    private static func testWritesLeaveOnlyTheFile() {
        withStore { store in
            for index in 0 ..< 20 { store.add(syntheticWord(index)) }
            TestSupport.expectEqual(fileNames(in: store), [NeverCorrectStore.fileName])
            // A staging file a crashed write left long ago is swept by the next write.
            let abandoned = store.directory.appendingPathComponent(NeverCorrectStore.stagingPrefix + "abandoned")
            try! Data("{}".utf8).write(to: abandoned)
            try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: abandoned.path)
            store.add("teh")
            TestSupport.expectEqual(fileNames(in: store), [NeverCorrectStore.fileName])
        }
    }

    private static func testClearForgetsEverything() {
        withStore { store in
            TestSupport.expect(store.clear(), "clearing nothing failed")
            store.add("teh")
            store.add("wrld")
            let abandoned = store.directory.appendingPathComponent(NeverCorrectStore.stagingPrefix + "abandoned")
            try! Data("{}".utf8).write(to: abandoned)
            TestSupport.expect(store.clear(), "clear failed")
            TestSupport.expectEqual(store.load(), NeverCorrectWords())
            TestSupport.expect(storeIsEmpty(store), "clear left files")
            // The next word starts a new list.
            TestSupport.expectEqual(store.add("hte").words, ["hte"])
        }
    }

    private static func testAClearDuringAnAddNeverBringsWordsBack() {
        // The app clears (its own store instance, as another process would) while the keyboard's add has read the
        // old words and not yet written: the clear waits for the add, so the cleared word never comes back.
        withStore { store in
            store.add("teh")
            let clearDone = DispatchGroup()
            let clearedEarly = DispatchSemaphore(value: 0)
            let clearing = NeverCorrectStore(directory: store.directory)
            var adding = NeverCorrectStore(directory: store.directory)
            adding.beforeWrite = {
                clearDone.enter()
                DispatchQueue.global().async {
                    clearing.clear()
                    clearedEarly.signal()
                    clearDone.leave()
                }
                // Without the lock the clear finishes here, before the write; with it, it waits for the add.
                _ = clearedEarly.wait(timeout: .now() + 0.3)
            }
            adding.add("wrld")
            TestSupport.expect(clearDone.wait(timeout: .now() + 5) == .success, "the clear never finished")
            TestSupport.expect(!store.load().contains("teh"), "a cleared word came back")
            TestSupport.expectEqual(store.load(), NeverCorrectWords())
        }
    }

    private static func testCreatesDirectoryExcludedFromBackup() {
        withStore { store in
            store.add("teh")
            let values = try! store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            TestSupport.expectEqual(values.isExcludedFromBackup, true)
        }
    }

    // MARK: The offer

    private static func testARevertAloneStoresNothing() {
        withStore { store in
            // A Delete and a strip choice revert, in this instance only.
            let first = rig(store)
            revert(first)
            TestSupport.expectEqual(first.text, "teh")
            first.press(.space)
            first.tap("wrld")
            first.corrector.corrections["wrld"] = "world"
            first.press(.space)
            first.choose(0)
            TestSupport.expectEqual(first.text, "teh wrld ")
            TestSupport.expectEqual(first.editor.revertedWords, ["teh", "wrld"])
            first.editor.hide(now: first.tick())
            TestSupport.expect(storeIsEmpty(store), "a revert stored its word")
            // A new keyboard instance corrects both again.
            let second = rig(store, corrections: ["teh": "the", "wrld": "world"])
            second.tap("teh")
            second.press(.space)
            second.tap("wrld")
            second.press(.space)
            TestSupport.expectEqual(second.text, "the world ")
        }
    }

    private static func testARevertOffersToNeverCorrectTheWord() {
        withStore { store in
            // By a Delete: the word as typed, in its case and without trailing apostrophes.
            let deleted = rig(store, corrections: ["teh": "the"])
            deleted.tap("Teh'")
            deleted.press(.space)
            TestSupport.expectEqual(deleted.text, "The' ")
            TestSupport.expectEqual(deleted.editor.neverCorrectOffer, nil)
            deleted.heldDelete()
            TestSupport.expectEqual(deleted.text, "Teh'")
            TestSupport.expectEqual(deleted.editor.neverCorrectOffer, NeverCorrectOffer(word: "teh", typed: "Teh"))
            TestSupport.expectEqual(deleted.events, [.checked, .corrected, .reverted, .offered])
            // By choosing the typed word on the strip, which stays open underneath.
            let chosen = rig(store, alternatives: ["teh": ["the"]])
            chosen.tap("TEH")
            chosen.press(.character(","))
            chosen.choose(0)
            TestSupport.expectEqual(chosen.text, "TEH,")
            TestSupport.expectEqual(chosen.editor.neverCorrectOffer, NeverCorrectOffer(word: "teh", typed: "TEH"))
            TestSupport.expectEqual(chosen.strip, SwipeStrip(candidates: ["TEH", "THE"], inserted: 0))
            TestSupport.expectEqual(chosen.events, [.checked, .corrected, .reverted, .offered])
            TestSupport.expect(storeIsEmpty(store), "an offer stored its word")
        }
    }

    private static func testAcceptingStoresTheWordForEveryInstance() {
        withStore { store in
            store.add("wrld")
            let first = rig(store)
            revert(first, "Teh")
            first.editor.acceptNeverCorrect()
            TestSupport.expectEqual(first.editor.neverCorrectOffer, nil)
            TestSupport.expectEqual(store.load().words, ["wrld", "teh"])
            TestSupport.expectEqual(first.editor.neverCorrectWords, ["wrld", "teh"])
            TestSupport.expectEqual(first.events, [.checked, .corrected, .reverted, .offered, .neverCorrected])
            // Accepting again does nothing.
            first.editor.acceptNeverCorrect()
            TestSupport.expectEqual(first.events.last, .neverCorrected)
            TestSupport.expectEqual(first.events.count, 5)
            // A new instance never corrects or offers it, in any case, without asking the corrector.
            let second = rig(NeverCorrectStore(directory: store.directory), alternatives: ["teh": ["the"]])
            second.tap("TEH")
            second.press(.space)
            second.tap("teh")
            second.press(.character("."))
            TestSupport.expectEqual(second.text, "TEH teh.")
            TestSupport.expectEqual(second.strip, nil)
            TestSupport.expectEqual(second.corrector.calls.count, 0)
            TestSupport.expectEqual(second.corrector.suggestionCalls.count, 0)
            TestSupport.expectEqual(second.events, [])
            // Other words still are.
            second.corrector.corrections["hte"] = "the"
            second.press(.space)
            second.tap("hte")
            second.press(.space)
            TestSupport.expectEqual(second.text, "TEH teh. the ")
        }
    }

    private static func testAcceptingFromTheStripClosesIt() {
        withStore { store in
            let rig = rig(store, alternatives: ["teh": ["the"]])
            rig.tap("teh")
            rig.press(.space)
            rig.choose(0)
            rig.editor.acceptNeverCorrect()
            TestSupport.expectEqual(rig.strip, nil)
            TestSupport.expectEqual(rig.text, "teh ")
            TestSupport.expectEqual(store.load().words, ["teh"])
            TestSupport.expectEqual(rig.events, [.checked, .corrected, .reverted, .offered, .neverCorrected])
        }
    }

    private static func testAnythingElseEndsTheOffer() {
        let endings: [(String, (AutocorrectRig) -> Void)] = [
            ("a letter", { $0.tap("s") }),
            ("a space", { $0.press(.space) }),
            ("shift", { $0.press(.shift) }),
            ("a layer key", { $0.press(.layer(.numbers)) }),
            ("Return", { $0.press(.returnKey) }),
            ("a Delete", { $0.heldDelete() }),
            ("VoiceOver's delete", { $0.press(.delete) }),
            ("a swipe", { $0.swipe(["go"]) }),
            ("dictation", { $0.editor.insertDictation("now", now: $0.tick()) }),
            ("the trackpad", { $0.editor.closeSwipeStrip() }),
            ("hiding", { $0.editor.hide(now: $0.tick()) }),
            ("an outside edit", { rig in
                rig.document.hostInserts("A ", at: 0)
                rig.pump()
            }),
            ("another field", { rig in
                rig.document.focus(FakeTextHost(text: ""), id: UUID())
                rig.pump()
            }),
        ]
        for (name, end) in endings {
            withStore { store in
                let rig = rig(store)
                revert(rig)
                TestSupport.expect(rig.editor.neverCorrectOffer != nil, "no offer before \(name)")
                end(rig)
                TestSupport.expectEqual(rig.editor.neverCorrectOffer, nil)
                rig.editor.acceptNeverCorrect()
                TestSupport.expect(storeIsEmpty(store), "\(name) kept the offer")
            }
        }
        // Another strip choice: the correction chosen back.
        withStore { store in
            let rig = rig(store)
            rig.tap("teh")
            rig.press(.space)
            rig.choose(0)
            rig.choose(1)
            TestSupport.expectEqual(rig.text, "the ")
            TestSupport.expectEqual(rig.editor.neverCorrectOffer, nil)
        }
    }

    private static func testOwnEchoesKeepTheOffer() {
        withStore { store in
            let rig = rig(store)
            revert(rig)
            rig.pump()
            rig.editor.service(now: rig.tick())
            TestSupport.expectEqual(rig.editor.neverCorrectOffer, NeverCorrectOffer(word: "teh", typed: "teh"))
            // A rotation keeps it too.
            rig.editor.layoutChanged()
            rig.editor.acceptNeverCorrect()
            TestSupport.expectEqual(store.load().words, ["teh"])
        }
    }

    private static func testNoOfferWithoutAStoreOrForAWordItCannotKeep() {
        // No store bound (autocorrect off or no Full Access when the keyboard appeared): a revert as before.
        let unbound = AutocorrectRig("", corrections: ["teh": "the"])
        revert(unbound)
        TestSupport.expectEqual(unbound.editor.neverCorrectOffer, nil)
        TestSupport.expectEqual(unbound.events, [.checked, .corrected, .reverted])
        unbound.editor.acceptNeverCorrect()
        TestSupport.expectEqual(unbound.events, [.checked, .corrected, .reverted])
        // A word longer than the store keeps is reverted in this instance only, without an offer.
        withStore { store in
            let long = String(repeating: "q", count: NeverCorrectWords.maximumLength + 1)
            let rig = rig(store, corrections: [long: "the"])
            revert(rig, long)
            TestSupport.expectEqual(rig.text, long)
            TestSupport.expectEqual(rig.editor.neverCorrectOffer, nil)
            TestSupport.expectEqual(rig.editor.revertedWords, [long])
        }
    }

    private static func testBindingAStoreReplacesTheWordsInMemory() {
        withStore { store in
            let rig = rig(store)
            revert(rig)
            rig.editor.acceptNeverCorrect()
            // Cleared in the app: the keyboard's next appearance binds the store again. The session's own revert
            // still holds in this instance (as before), so a new instance shows the clear.
            store.clear()
            rig.editor.hide(now: rig.tick())
            rig.editor.reset(numeric: false)
            rig.editor.useNeverCorrectStore(store)
            TestSupport.expectEqual(rig.editor.neverCorrectWords, [])
            TestSupport.expectEqual(rig.editor.revertedWords, ["teh"])
            let fresh = Self.rig(store)
            fresh.tap("teh")
            fresh.press(.space)
            TestSupport.expectEqual(fresh.text, "the ")
            // No store when the keyboard appears: no words from it, and no offer.
            store.add("hte")
            let unbound = Self.rig(store, corrections: ["hte": "the"])
            TestSupport.expectEqual(unbound.editor.neverCorrectWords, ["hte"])
            unbound.editor.useNeverCorrectStore(nil)
            TestSupport.expectEqual(unbound.editor.neverCorrectWords, [])
            unbound.tap("hte")
            unbound.press(.space)
            TestSupport.expectEqual(unbound.text, "the ")
        }
    }

    private static func testNothingIsOfferedWhereNothingIsCorrected() {
        // A secure field, a field that turns autocorrection off, and autocorrect off: no correction, so Delete is a
        // plain Delete, nothing is offered and nothing stored.
        let setups: [(String, (AutocorrectRig) -> Void)] = [
            ("secure", { $0.secure = true }),
            ("autocorrection off", { $0.autocorrectionDisabled = true }),
            ("autocorrect off", { $0.enabled = false }),
        ]
        for (name, setUp) in setups {
            withStore { store in
                let rig = rig(store)
                setUp(rig)
                revert(rig)
                TestSupport.expectEqual(rig.text, "teh")
                TestSupport.expect(rig.editor.revertedWords.isEmpty, "\(name) reverted")
                TestSupport.expectEqual(rig.editor.neverCorrectOffer, nil)
                rig.editor.acceptNeverCorrect()
                TestSupport.expect(storeIsEmpty(store), "\(name) stored a word")
            }
        }
    }

    private static func testDictationUIWinsTheBar() {
        let offer = NeverCorrectOffer(word: "teh", typed: "Teh")
        TestSupport.expect(NeverCorrectOffer.barShows(offer, dictationInProgress: false, dictationUndoShown: false), "hidden")
        TestSupport.expect(!NeverCorrectOffer.barShows(offer, dictationInProgress: true, dictationUndoShown: false),
                           "shown over a dictation in progress")
        TestSupport.expect(!NeverCorrectOffer.barShows(offer, dictationInProgress: false, dictationUndoShown: true),
                           "shown over dictation's Undo")
        TestSupport.expect(!NeverCorrectOffer.barShows(nil, dictationInProgress: false, dictationUndoShown: false), "shown without an offer")
    }
}
