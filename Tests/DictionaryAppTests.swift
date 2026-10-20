// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
import Foundation

/// Contract tests for app-specific words on macOS (DESIGN §3.6). Every app,
/// bundle identifier and word is invented.
enum DictionaryAppTests {
    static func run() {
        testApps()
        testScopes()
        testDecodingWords()
        testEditing()
        testSuggestionAdds()
        testRemovingApps()
        testAppCapacity()
        testEditsNeedVocabulary()
        testStorage()
        testStorageCapacity()
        testGraphCache()
    }

    private static let chat = DictionaryApp(id: "com.example.chat", name: "Chat")!
    private static let mail = DictionaryApp(id: "com.example.mail", name: "Mail")!
    private static let notes = DictionaryApp(id: "org.example.notes-2", name: "Notes")!

    private static var editor: ScopedDictionaryEditor { ScopedDictionaryEditor(encoder: DictionaryTests.testEncoder) }

    private static func k(_ text: String) -> DictionaryKey { DictionaryKey(text) }

    private static func success(_ result: Result<ScopedDictionary, ScopedDictionaryEditError>?,
                                file: StaticString = #filePath, line: UInt = #line) -> ScopedDictionary {
        guard case .success(let dictionary)? = result else {
            fatalError("\(file):\(line): Expected a successful edit, got \(String(describing: result))")
        }
        return dictionary
    }

    /// Chat and Mail known; "Zorbik" in Chat only, "Plexa" in Chat and Mail,
    /// "Kubernetes" everywhere.
    private static func sample() -> ScopedDictionary {
        var dictionary = success(editor.registering(chat, in: ScopedDictionary()))
        dictionary = success(editor.registering(mail, in: dictionary))
        dictionary = success(editor.saving(text: "Kubernetes", strength: 1, apps: [], replacing: nil, in: dictionary))
        dictionary = success(editor.saving(text: "Zorbik", strength: 2, apps: [chat.id], replacing: nil, in: dictionary))
        dictionary = success(editor.saving(text: "Plexa", strength: 1.41, apps: [chat.id, mail.id], replacing: nil,
                                           in: dictionary))
        return dictionary
    }

    // MARK: - Apps

    private static func testApps() {
        TestSupport.expect(DictionaryApp(id: "com.example.chat", name: "Chat") != nil, "A bundle identifier")
        TestSupport.expect(DictionaryApp(id: "org.example.notes-2", name: nil) != nil, "Digits and hyphens are allowed")
        for id in ["", "com.example chat", "com.example_chat", "com.exämple.chat", "com/example",
                   String(repeating: "a", count: DictionaryApp.maxIDLength + 1)] {
            TestSupport.expect(DictionaryApp(id: id, name: "Chat") == nil, "Not a bundle identifier: \(id.debugDescription)")
        }
        TestSupport.expect(DictionaryApp(id: String(repeating: "a", count: DictionaryApp.maxIDLength), name: "A") != nil,
                           "155 characters is the longest identifier")

        TestSupport.expectEqual(DictionaryApp(id: "com.example.chat", name: "  Chat\n")?.name, "Chat")
        TestSupport.expectEqual(DictionaryApp(id: "com.example.chat", name: "Ch\u{7}at")?.name, "Chat")
        TestSupport.expectEqual(DictionaryApp(id: "com.example.chat", name: " \t ")?.name, "com.example.chat")
        TestSupport.expectEqual(DictionaryApp(id: "com.example.chat", name: nil)?.name, "com.example.chat")
        let long = DictionaryApp(id: "com.example.chat", name: String(repeating: "é", count: 150))
        TestSupport.expectEqual(long?.name.unicodeScalars.count, DictionaryApp.maxNameScalars)
    }

    // MARK: - Which words apply where

    private static func testScopes() {
        let dictionary = sample()
        TestSupport.expectEqual(dictionary.scopes.apps, [chat, mail])
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("kubernetes")), [])
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("ZORBIK")), [chat.id])
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("plexa")), [chat.id, mail.id])

        TestSupport.expect(dictionary.applies(k("kubernetes"), in: nil), "An unlimited word applies without an app")
        TestSupport.expect(dictionary.applies(k("kubernetes"), in: "com.example.other"), "and in any app")
        TestSupport.expect(dictionary.applies(k("zorbik"), in: chat.id), "A limited word applies in its app")
        TestSupport.expect(!dictionary.applies(k("zorbik"), in: mail.id), "but not in another app")
        TestSupport.expect(!dictionary.applies(k("zorbik"), in: nil), "nor without an app")
        TestSupport.expect(!dictionary.applies(k("absent"), in: chat.id), "A missing word applies nowhere")

        TestSupport.expectEqual(dictionary.scopes.wordCount(in: chat.id), 2)
        TestSupport.expectEqual(dictionary.scopes.wordCount(in: mail.id), 1)
        TestSupport.expectEqual(dictionary.scopes.wordCount(in: "com.example.other"), 0)
    }

    private static func testDecodingWords() {
        let dictionary = sample()
        func texts(_ appID: String?) -> [String] { dictionary.decodingWords(for: appID).entries.map(\.text) }
        TestSupport.expectEqual(texts(nil), ["Kubernetes"])
        TestSupport.expectEqual(texts(chat.id), ["Kubernetes", "Zorbik", "Plexa"])
        TestSupport.expectEqual(texts(mail.id), ["Kubernetes", "Plexa"])
        TestSupport.expectEqual(texts("com.example.other"), ["Kubernetes"])
        TestSupport.expectEqual(dictionary.decodingWords(for: chat.id).entries.map(\.strength), [1, 2, 1.41])

        // Only an app with limited words is recorded, so every other app shares the global graph.
        TestSupport.expectEqual(dictionary.decodingWords(for: chat.id).appID, chat.id)
        TestSupport.expectEqual(dictionary.decodingWords(for: "com.example.other").appID, nil)
        TestSupport.expectEqual(dictionary.decodingWords(for: nil).appID, nil)
        let unused = success(editor.registering(notes, in: dictionary))
        TestSupport.expectEqual(unused.decodingWords(for: notes.id).appID, nil)
    }

    // MARK: - Editing

    private static func testEditing() {
        var dictionary = sample()
        TestSupport.expect(editor.saving(text: "Quillon", strength: 1, apps: ["com.example.unknown"], replacing: nil,
                                         in: dictionary) == .failure(.app(.unknownApp)), "Apps must be known")
        TestSupport.expect(editor.saving(text: "naïve—x", strength: 1, apps: [chat.id], replacing: nil, in: dictionary)
                           == .failure(.edit(.invalid(.unencodable))), "Words are validated as before")

        // Saving sets the apps; an edit can widen, narrow or clear them.
        dictionary = success(editor.saving(text: "Zorbik", strength: 2, apps: [chat.id, mail.id],
                                           replacing: k("zorbik"), in: dictionary))
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("zorbik")), [chat.id, mail.id])
        dictionary = success(editor.saving(text: "Zorbik", strength: 2, apps: [], replacing: k("zorbik"), in: dictionary))
        TestSupport.expect(dictionary.applies(k("zorbik"), in: nil), "No apps means everywhere")
        dictionary = success(editor.saving(text: "Zorbik", strength: 2, apps: [mail.id], replacing: k("zorbik"),
                                           in: dictionary))
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("zorbik")), [mail.id])

        // A new text keeps the apps under the new key.
        dictionary = success(editor.saving(text: "Zorbix", strength: 2, apps: [mail.id], replacing: k("zorbik"),
                                           in: dictionary))
        TestSupport.expect(!dictionary.dictionary.contains(k("zorbik")), "The old entry is gone")
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("zorbik")), [])
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("zorbix")), [mail.id])

        // Removing an entry removes its apps; re-adding it starts everywhere.
        dictionary = success(editor.removing(k("zorbix"), in: dictionary))
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("zorbix")), [])
        TestSupport.expect(editor.removing(k("zorbix"), in: dictionary) == nil, "Nothing to remove")
        dictionary = success(editor.saving(text: "Zorbix", strength: 1, apps: [], replacing: nil, in: dictionary))
        TestSupport.expect(dictionary.applies(k("zorbix"), in: nil), "No stale limit survives a removal")

        // The ignore list stays global.
        dictionary = success(editor.ignoring(k("eldar"), in: dictionary))
        TestSupport.expect(dictionary.dictionary.isIgnored(k("eldar")), "Ignored")
        dictionary = success(editor.unignoring(k("eldar"), in: dictionary))
        TestSupport.expect(!dictionary.dictionary.isIgnored(k("eldar")), "Unignored")

        // One capacity across every app.
        var full = success(editor.registering(chat, in: ScopedDictionary()))
        for index in 0..<DictionaryValidation.capacity {
            full = success(editor.saving(text: "word\(index)x", strength: 1, apps: index.isMultiple(of: 2) ? [chat.id] : [],
                                         replacing: nil, in: full))
        }
        TestSupport.expect(editor.saving(text: "overflow", strength: 1, apps: [chat.id], replacing: nil, in: full)
                           == .failure(.edit(.full)), "Limited words count toward the 1000 entries")
        TestSupport.expect(editor.saving(text: "overflow", strength: 1, apps: [], replacing: nil, in: full)
                           == .failure(.edit(.full)), "and so do the others")
    }

    private static func testSuggestionAdds() {
        let start = sample()

        // Add to <App> with a new word limits it to that app.
        var dictionary = success(editor.adding("Vantor", strength: 2, to: chat, in: start))
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("vantor")), [chat.id])
        TestSupport.expectEqual(dictionary.dictionary.entries.last, DictionaryEntry(text: "Vantor", strength: 2))

        // An unknown app is registered by the add, and a known one has its name updated.
        let renamed = DictionaryApp(id: chat.id, name: "Chat Pro")!
        dictionary = success(editor.adding("Wexley", strength: 1, to: notes, in: dictionary))
        TestSupport.expectEqual(dictionary.scopes.app(id: notes.id), notes)
        dictionary = success(editor.adding("Yarrow", strength: 1, to: renamed, in: dictionary))
        TestSupport.expectEqual(dictionary.scopes.app(id: chat.id)?.name, "Chat Pro")
        TestSupport.expectEqual(dictionary.scopes.apps.map(\.id), [chat.id, mail.id, notes.id])

        // An existing limited word gains the app, keeps its text and takes the higher strength.
        dictionary = success(editor.adding("ZORBIK", strength: 1.41, to: mail, in: start))
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("zorbik")), [chat.id, mail.id])
        TestSupport.expectEqual(dictionary.dictionary.entries.first { $0.key == k("zorbik") },
                                DictionaryEntry(text: "Zorbik", strength: 2))
        dictionary = success(editor.adding("zorbik", strength: 4, to: notes, in: dictionary))
        TestSupport.expectEqual(dictionary.dictionary.entries.first { $0.key == k("zorbik") }?.strength, 4)
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("zorbik")), [chat.id, mail.id, notes.id])

        // A word that already applies everywhere stays everywhere.
        dictionary = success(editor.adding("Kubernetes", strength: 2, to: chat, in: start))
        TestSupport.expect(dictionary.applies(k("kubernetes"), in: nil), "Still everywhere")
        TestSupport.expectEqual(dictionary.dictionary.entries.first { $0.key == k("kubernetes") }?.strength, 2)

        // Add everywhere: new words are unlimited, limited words become unlimited.
        dictionary = success(editor.adding("Vantor", strength: 1, to: nil, in: start))
        TestSupport.expect(dictionary.applies(k("vantor"), in: nil), "Added everywhere")
        dictionary = success(editor.adding("plexa", strength: 1, to: nil, in: dictionary))
        TestSupport.expect(dictionary.applies(k("plexa"), in: nil), "Widened to everywhere")
        TestSupport.expectEqual(dictionary.dictionary.entries.first { $0.key == k("plexa") },
                                DictionaryEntry(text: "Plexa", strength: 1.41))
        TestSupport.expectEqual(dictionary.scopes.apps, [chat, mail])

        TestSupport.expect(editor.adding("naïve—x", strength: 1, to: chat, in: start) == .failure(.edit(.invalid(.unencodable))),
                           "Suggested words are validated")
    }

    private static func testRemovingApps() {
        var dictionary = sample()
        dictionary = success(editor.removingApp(chat.id, in: dictionary))
        TestSupport.expectEqual(dictionary.scopes.apps, [mail])
        TestSupport.expect(!dictionary.dictionary.contains(k("zorbik")), "A word only in the removed app is removed, never made global")
        TestSupport.expectEqual(dictionary.scopes.apps(for: k("plexa")), [mail.id])
        TestSupport.expect(dictionary.applies(k("kubernetes"), in: nil), "Unlimited words stay")
        TestSupport.expect(editor.removingApp(chat.id, in: dictionary) == nil, "Removing an unknown app changes nothing")

        dictionary = success(editor.removingApp(mail.id, in: dictionary))
        TestSupport.expectEqual(dictionary.dictionary.entries.map(\.text), ["Kubernetes"])
        TestSupport.expect(dictionary.scopes.apps.isEmpty, "No apps left")
    }

    private static func testAppCapacity() {
        var dictionary = ScopedDictionary()
        for index in 0..<DictionaryAppScopes.appCapacity {
            dictionary = success(editor.registering(DictionaryApp(id: "com.example.app\(index)", name: "App \(index)")!,
                                                    in: dictionary))
        }
        let extra = DictionaryApp(id: "com.example.extra", name: "Extra")!
        TestSupport.expect(editor.registering(extra, in: dictionary) == .failure(.app(.appsFull)), "32 apps at most")
        TestSupport.expect(editor.adding("Vantor", strength: 1, to: extra, in: dictionary) == .failure(.app(.appsFull)),
                           "An add to a 33rd app is refused")
        let renamed = DictionaryApp(id: "com.example.app0", name: "Renamed")!
        dictionary = success(editor.registering(renamed, in: dictionary))
        TestSupport.expectEqual(dictionary.scopes.app(id: renamed.id), renamed)
        TestSupport.expectEqual(dictionary.scopes.apps.count, DictionaryAppScopes.appCapacity)
        for error in [ScopedDictionaryEditError.app(.appsFull), .app(.unknownApp)] {
            TestSupport.expect(!error.message.contains("App 0") && !error.message.contains("com.example"),
                               "Errors never quote an app")
        }
    }

    private static func testEditsNeedVocabulary() {
        let dictionary = sample()
        let locked = ScopedDictionaryEditor(encoder: nil)
        TestSupport.expect(!locked.canEdit, "No vocabulary, no edits")
        func refused(_ result: Result<ScopedDictionary, ScopedDictionaryEditError>?) -> Bool {
            if case .failure(.edit(.noVocabulary))? = result { return true }
            return false
        }
        TestSupport.expect(refused(locked.saving(text: "Vantor", strength: 1, apps: [chat.id], replacing: nil, in: dictionary)),
                           "Save refused")
        TestSupport.expect(refused(locked.removing(k("zorbik"), in: dictionary)), "Delete refused")
        TestSupport.expect(refused(locked.adding("Vantor", strength: 1, to: chat, in: dictionary)), "Suggestion add refused")
        TestSupport.expect(refused(locked.registering(notes, in: dictionary)), "Adding an app refused")
        TestSupport.expect(refused(locked.removingApp(chat.id, in: dictionary)), "Removing an app refused")
        TestSupport.expect(refused(locked.ignoring(k("eldar"), in: dictionary)), "Don't suggest refused")
    }

    // MARK: - Storage

    private static func load(_ apps: String?, entries: [DictionaryEntry]) -> Result<DictionaryAppScopes, DictionaryStorageError> {
        DictionaryAppStorage.load(apps.map { Data($0.utf8) }, entries: entries)
    }

    private static func testStorage() {
        let dictionary = sample()
        guard case .success(let missing) = load(nil, entries: dictionary.dictionary.entries) else {
            fatalError("Missing app data must load")
        }
        TestSupport.expect(missing == DictionaryAppScopes(), "Missing means every word applies everywhere")

        let stored = DictionaryAppStorage.encode(dictionary.scopes)
        TestSupport.expectEqual(String(decoding: stored, as: UTF8.self), #"{"apps":[{"id":"com.example.chat","name":"Chat"},{"id":"com.example.mail","name":"Mail"}],"version":1,"words":[{"apps":["com.example.chat","com.example.mail"],"key":"plexa"},{"apps":["com.example.chat"],"key":"zorbik"}]}"#)
        guard case .success(let reloaded) = DictionaryAppStorage.load(stored, entries: dictionary.dictionary.entries) else {
            fatalError("Written app data must load")
        }
        TestSupport.expect(reloaded == dictionary.scopes, "App data round-trips")

        // A known app without words is kept.
        let unused = success(editor.registering(notes, in: dictionary))
        guard case .success(let withUnused) = DictionaryAppStorage.load(DictionaryAppStorage.encode(unused.scopes),
                                                                         entries: unused.dictionary.entries) else {
            fatalError("An app without words loads")
        }
        TestSupport.expectEqual(withUnused.apps, [chat, mail, notes])

        // Words that are no longer entries (an older build removed or renamed them) are dropped.
        let older = dictionary.dictionary.entries.filter { $0.key != k("zorbik") }
        guard case .success(let pruned) = DictionaryAppStorage.load(stored, entries: older) else {
            fatalError("Words without entries are dropped, not corrupt")
        }
        TestSupport.expectEqual(pruned.apps(for: k("zorbik")), [])
        TestSupport.expectEqual(pruned.apps(for: k("plexa")), [chat.id, mail.id])
        TestSupport.expectEqual(pruned.apps, [chat, mail])

        let entries = [DictionaryEntry(text: "Zorbik", strength: 1)]
        let app = #"{"id":"com.example.chat","name":"Chat"}"#
        let corrupt = [
            "not json",
            #"["com.example.chat"]"#,
            #"{"apps":[],"words":[]}"#,
            #"{"apps":[],"version":2,"words":[]}"#,
            #"{"apps":[{"id":"com example","name":"Chat"}],"version":1,"words":[]}"#,
            #"{"apps":[{"id":"com.example.chat","name":" Chat"}],"version":1,"words":[]}"#,
            #"{"apps":[{"id":"com.example.chat","name":""}],"version":1,"words":[]}"#,
            #"{"apps":[{"id":"com.example.chat"}],"version":1,"words":[]}"#,
            "{\"apps\":[\(app),\(app)],\"version\":1,\"words\":[]}",
            "{\"apps\":[\(app)],\"version\":1,\"words\":[{\"apps\":[],\"key\":\"zorbik\"}]}",
            "{\"apps\":[\(app)],\"version\":1,\"words\":[{\"apps\":[\"com.example.mail\"],\"key\":\"zorbik\"}]}",
            "{\"apps\":[\(app)],\"version\":1,\"words\":[{\"apps\":[\"com.example.chat\",\"com.example.chat\"],\"key\":\"zorbik\"}]}",
            "{\"apps\":[\(app)],\"version\":1,\"words\":[{\"apps\":[\"com.example.chat\"],\"key\":\"Zorbik\"}]}",
            "{\"apps\":[\(app)],\"version\":1,\"words\":[{\"apps\":[\"com.example.chat\"],\"key\":\"\"}]}",
            "{\"apps\":[\(app)],\"version\":1,\"words\":[{\"apps\":[\"com.example.chat\"],\"key\":\"zorbik\"},{\"apps\":[\"com.example.chat\"],\"key\":\"zorbik\"}]}",
            "{\"apps\":[\(app)],\"version\":1}",
        ]
        for payload in corrupt {
            TestSupport.expect(load(payload, entries: entries) == .failure(.unreadable),
                               "Corrupt app data must be rejected: \(payload)")
        }
        let tooManyApps = "{\"apps\":[" + (0...DictionaryAppScopes.appCapacity)
            .map { "{\"id\":\"com.example.app\($0)\",\"name\":\"App\"}" }.joined(separator: ",") + "],\"version\":1,\"words\":[]}"
        TestSupport.expect(load(tooManyApps, entries: entries) == .failure(.unreadable), "More than 32 apps is corrupt")
        let tooManyWords = "{\"apps\":[\(app)],\"version\":1,\"words\":[" + (0...DictionaryValidation.capacity)
            .map { "{\"apps\":[\"com.example.chat\"],\"key\":\"w\($0)x\"}" }.joined(separator: ",") + "]}"
        TestSupport.expect(load(tooManyWords, entries: entries) == .failure(.unreadable), "More than 1000 words is corrupt")
        TestSupport.expect(DictionaryAppStorage.load(Data(count: DictionaryAppStorage.maxBytes + 1), entries: entries)
                           == .failure(.unreadable), "Over 8 MiB is corrupt")
    }

    /// The largest payload: 32 apps with 155-character identifiers and
    /// 100-scalar names of 4-byte scalars, and 1000 words of 300-scalar keys
    /// (pin P6) of 4-byte scalars, each in every app.
    private static func testStorageCapacity() {
        let wide = String(repeating: "\u{20000}", count: DictionaryApp.maxNameScalars)
        let apps = (0..<DictionaryAppScopes.appCapacity).map { index in
            DictionaryApp(id: String(format: "%03d", index) + String(repeating: "a", count: DictionaryApp.maxIDLength - 3),
                          name: wide)!
        }
        var scopes = DictionaryAppScopes()
        for app in apps { TestSupport.expect(scopes.register(app) == nil, "Apps fill up") }
        var entries: [DictionaryEntry] = []
        for index in 0..<DictionaryValidation.capacity {
            let key = DictionaryKey(folded: [Unicode.Scalar(0x20000 + index)!]
                + Array(repeating: Unicode.Scalar(0x20000)!, count: DictionaryKey.maxScalars - 1))
            TestSupport.expect(scopes.setApps(Set(apps.map(\.id)), for: key) == nil, "Every word in every app")
            // Loading drops words without an entry, so each key needs one.
            entries.append(DictionaryEntry(text: key.text, strength: 1))
        }
        let stored = DictionaryAppStorage.encode(scopes)
        TestSupport.expect(stored.count > 4 << 20, "The largest app payload is over 4 MiB")
        TestSupport.expect(stored.count <= DictionaryAppStorage.maxBytes, "Saved app data stays within the load cap")
        guard case .success(let reloaded) = DictionaryAppStorage.load(stored, entries: entries) else {
            fatalError("The largest app data must load again")
        }
        TestSupport.expect(reloaded == scopes, "The largest app data round-trips")
    }

    // MARK: - Graph cache

    private static func testGraphCache() {
        let entries = [DictionaryEntry(text: "Kubernetes", strength: 1)]
        var builds = 0
        var cache = BiasGraphCache()
        func graph(_ revision: UInt64, _ appID: String?, entries: [DictionaryEntry] = entries) -> BiasGraph? {
            cache.graph(for: DictionarySnapshot(revision: revision, entries: entries, appID: appID)) {
                builds += 1
                return BiasGraph.build(entries: entries, encoder: DictionaryTests.testEncoder)
            }
        }
        TestSupport.expect(graph(1, nil, entries: []) == nil && builds == 0, "An empty snapshot has no graph and builds nothing")
        TestSupport.expect(graph(1, nil) != nil, "Built")
        _ = graph(1, nil)
        TestSupport.expectEqual(builds, 1)
        _ = graph(1, chat.id)
        _ = graph(1, mail.id)
        _ = graph(1, chat.id)
        _ = graph(1, nil)
        TestSupport.expectEqual(builds, 3)

        // Up to 4 graphs; the least recently used goes first.
        _ = graph(1, notes.id)
        _ = graph(1, "com.example.fourth")
        TestSupport.expectEqual(builds, 5)
        _ = graph(1, mail.id)
        TestSupport.expectEqual(builds, 6)
        _ = graph(1, notes.id)
        _ = graph(1, "com.example.fourth")
        _ = graph(1, nil)
        TestSupport.expectEqual(builds, 6)

        // A new revision drops every older graph.
        _ = graph(2, nil)
        _ = graph(2, chat.id)
        TestSupport.expectEqual(builds, 8)
        _ = graph(1, nil)
        TestSupport.expectEqual(builds, 9)
    }
}
