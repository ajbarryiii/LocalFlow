import Foundation

/// `SwipeBundle` and `BundleModelLoader`: the bundle's `bundle.json` is decoded section by section, and each
/// keyboard model loads off the main thread, at most once in flight, and is installed on the main thread
/// (ARCHITECTURE.md, "Soft key edges"). Invented manifests and models only.
enum BundleModelLoaderTests {
    static var tests: [TestCase] {
        [
            ("eachSectionDecodesOnItsOwn", testEachSectionDecodesOnItsOwn),
            ("anUnreadableManifestIsNoBundle", testAnUnreadableManifestIsNoBundle),
            ("loadsOffTheMainThreadAndInstallsOnIt", isolated(testLoadsOffTheMainThreadAndInstallsOnIt)),
            ("askingAgainWhileLoadingStartsNothing", isolated(testAskingAgainWhileLoadingStartsNothing)),
            ("askingForNoneDropsTheModelAtOnce", isolated(testAskingForNoneDropsTheModelAtOnce)),
            ("aFailedLoadInstallsNothingAndLoadsAgain", isolated(testAFailedLoadInstallsNothingAndLoadsAgain)),
            ("aBundleWithoutItsManifestLoadsNothing", isolated(testABundleWithoutItsManifestLoadsNothing)),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    private static let decode = #""decode": {"beam": 4, "top_k": 3, "length_power": 0.5, "freq_weight": 0.01, "length_bonus": 0.25}"#
    private static let tap = #""tap": {"format": 1, "models": {"67k": "tap/b.bin"}, "default_model": "67k", "touch": {"sigma": 0.3, "ratio": 1.2, "offset_y": 0.15, "tail_weight": 0.1, "tail_scale": 3.0, "space_spread": 0.5}, "rule": {"centre": 0.6, "margin": 3.0, "max_surprise": 3.0, "surprise_window": 8}}"#
    private static let autocorrect = #""autocorrect": {"format": 1, "lexicon": "autocorrect/lexicon.lfwl", "models": {"w0": {"kind": "unigram"}}, "default_model": "w0", "presets": {"w0": {"balanced": {"p_omit": 0.02, "p_insert": 0.03, "p_transpose": 0.004, "max_edits": 2, "max_edits_short": 1, "short_length": 4, "min_length": 2, "lm_weight": 0.8, "log_oov": -9.0, "margin_oov": 4.0, "margin_known": null, "margin_apostrophe": 50.0, "w_repeat": 0.4, "w_slip": 0.35}}}, "default_preset": "balanced"}"#

    /// A `bundle.json` with the given sections after the format and files.
    private static func manifest(_ sections: String...) -> Data {
        Data(#"{"format": 1, "files": {"lexicon.bin": "00"}\#(sections.map { ", " + $0 }.joined())}"#.utf8)
    }

    /// A temporary bundle directory holding `manifest` (none when nil); removed after `body`.
    private static func withBundle(_ manifest: Data?, _ body: (URL) -> Void) {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        if let manifest { try! manifest.write(to: directory.appendingPathComponent("bundle.json")) }
        body(directory)
    }

    private static func testEachSectionDecodesOnItsOwn() {
        withBundle(manifest(decode, tap, autocorrect)) { directory in
            let bundle = SwipeBundle(directory: directory)
            TestSupport.expectEqual(bundle?.directory, directory)
            TestSupport.expectEqual(bundle?.swipe, SwipeDecodeConfig(beam: 4, topK: 3, lengthPower: 0.5, freqWeight: 0.01, lengthBonus: 0.25))
            TestSupport.expectEqual(bundle?.tap?.defaultModel, "67k")
            TestSupport.expectEqual(bundle?.tap, try! SoftKeyEdgesManifest.decode(from: manifest(decode, tap)))
            TestSupport.expectEqual(bundle?.autocorrect?.defaultModel, "w0")
        }
        // An invalid section turns off only its own feature.
        withBundle(manifest(#""decode": {"beam": 0}"#, #""tap": {"format": 2}"#, autocorrect)) { directory in
            let bundle = SwipeBundle(directory: directory)
            TestSupport.expect(bundle != nil, "no bundle")
            TestSupport.expectEqual(bundle?.swipe, nil)
            TestSupport.expectEqual(bundle?.tap, nil)
            TestSupport.expectEqual(bundle?.autocorrect?.defaultModel, "w0")
        }
        withBundle(manifest(decode, #""autocorrect": {"format": 1}"#)) { directory in
            let bundle = SwipeBundle(directory: directory)
            TestSupport.expect(bundle?.swipe != nil, "swipe settings rejected")
            TestSupport.expectEqual(bundle?.tap, nil)
            TestSupport.expectEqual(bundle?.autocorrect, nil)
        }
        // `decoded(at:)` reads any bundle but the keyboard's own afresh.
        withBundle(manifest(decode)) { directory in
            TestSupport.expect(SwipeBundle.decoded(at: directory)?.swipe != nil, "not decoded")
            try! manifest(#""decode": {"beam": 0}"#).write(to: directory.appendingPathComponent("bundle.json"))
            TestSupport.expect(SwipeBundle.decoded(at: directory)?.swipe == nil, "not read again")
        }
    }

    private static func testAnUnreadableManifestIsNoBundle() {
        withBundle(nil) { directory in
            TestSupport.expect(SwipeBundle(directory: directory) == nil, "a directory without bundle.json is a bundle")
            TestSupport.expect(SwipeBundle.decoded(at: directory) == nil, "a directory without bundle.json is a bundle")
        }
        // Not JSON: still a bundle, with every section off.
        withBundle(Data("not json".utf8)) { directory in
            let bundle = SwipeBundle(directory: directory)
            TestSupport.expect(bundle != nil && bundle?.swipe == nil && bundle?.tap == nil && bundle?.autocorrect == nil,
                               "sections from an invalid manifest")
        }
    }

    /// What the owner was handed, in order.
    @MainActor
    private final class Installs {
        var models: [String?] = []
    }

    /// A load that records its calls and whether it ran on the main thread, waits for `gate` when given, and
    /// returns `result`.
    private final class FakeLoad: @unchecked Sendable {
        let calls = Locked<[Bool]>([])
        let bundles = Locked<[URL]>([])
        let gate: DispatchSemaphore?
        let result: Locked<String?>

        init(result: String?, gated: Bool = false) {
            self.result = Locked(result)
            gate = gated ? DispatchSemaphore(value: 0) : nil
        }

        func callAsFunction(_ bundle: SwipeBundle) -> String? {
            calls.update { $0.append(Thread.isMainThread) }
            bundles.update { $0.append(bundle.directory) }
            gate?.wait()
            return result.current
        }
    }

    @MainActor
    private static func testLoadsOffTheMainThreadAndInstallsOnIt() {
        withBundle(manifest(decode)) { directory in
            let loader = BundleModelLoader<String>()
            let installs = Installs()
            let load = FakeLoad(result: "model")
            var installedOnMain: [Bool] = []
            loader.request(directory, load: { load($0) }) { model in
                installedOnMain.append(Thread.isMainThread)
                installs.models.append(model)
            }
            TestSupport.expect(installs.models.isEmpty, "installed before loading")
            TestSupport.expect(TestSupport.waitUntil(timeout: 5) { installs.models == ["model"] }, "not installed")
            TestSupport.expectEqual(load.calls.current, [false])
            TestSupport.expectEqual(load.bundles.current, [directory])
            TestSupport.expectEqual(installedOnMain, [true])
            // Held: asking again loads nothing.
            loader.request(directory, load: { load($0) }) { installs.models.append($0) }
            TestSupport.expect(!TestSupport.waitUntil(timeout: 0.2) { load.calls.current.count > 1 }, "loaded again")
            TestSupport.expectEqual(installs.models, ["model"])
        }
    }

    @MainActor
    private static func testAskingAgainWhileLoadingStartsNothing() {
        withBundle(manifest(decode)) { directory in
            let loader = BundleModelLoader<String>()
            let installs = Installs()
            let load = FakeLoad(result: "model", gated: true)
            for _ in 0 ..< 3 { loader.request(directory, load: { load($0) }) { installs.models.append($0) } }
            TestSupport.expect(TestSupport.waitUntil(timeout: 5) { load.calls.current.count == 1 }, "not loading")
            load.gate?.signal()
            TestSupport.expect(TestSupport.waitUntil(timeout: 5) { installs.models == ["model"] }, "not installed once")
            TestSupport.expectEqual(load.calls.current.count, 1)
        }
    }

    @MainActor
    private static func testAskingForNoneDropsTheModelAtOnce() {
        withBundle(manifest(decode)) { directory in
            let loader = BundleModelLoader<String>()
            let installs = Installs()
            let load = FakeLoad(result: "model")
            loader.request(directory, load: { load($0) }) { installs.models.append($0) }
            TestSupport.expect(TestSupport.waitUntil(timeout: 5) { installs.models == ["model"] }, "not installed")
            loader.request(nil, load: { load($0) }) { installs.models.append($0) }
            TestSupport.expectEqual(installs.models, ["model", nil])
            // Nothing held: asking for none again drops nothing.
            loader.request(nil, load: { load($0) }) { installs.models.append($0) }
            TestSupport.expectEqual(installs.models, ["model", nil])
            // Wanted again: loaded again.
            loader.request(directory, load: { load($0) }) { installs.models.append($0) }
            TestSupport.expect(TestSupport.waitUntil(timeout: 5) { installs.models == ["model", nil, "model"] }, "not reloaded")
            TestSupport.expectEqual(load.calls.current.count, 2)
        }
    }

    @MainActor
    private static func testAFailedLoadInstallsNothingAndLoadsAgain() {
        withBundle(manifest(decode)) { directory in
            let loader = BundleModelLoader<String>()
            let installs = Installs()
            let load = FakeLoad(result: nil)
            loader.request(directory, load: { load($0) }) { installs.models.append($0) }
            TestSupport.expect(TestSupport.waitUntil(timeout: 5) { load.calls.current.count == 1 }, "not loading")
            load.result.update { $0 = "model" }
            // Asking again starts nothing while the failed load is in flight, then loads once it has ended.
            TestSupport.expect(TestSupport.waitUntil(timeout: 5) {
                loader.request(directory, load: { load($0) }) { installs.models.append($0) }
                return load.calls.current.count == 2
            }, "not loaded again")
            TestSupport.expect(TestSupport.waitUntil(timeout: 5) { installs.models == ["model"] }, "not installed")
            TestSupport.expectEqual(load.calls.current.count, 2)
        }
    }

    @MainActor
    private static func testABundleWithoutItsManifestLoadsNothing() {
        withBundle(nil) { directory in
            let loader = BundleModelLoader<String>()
            let installs = Installs()
            let load = FakeLoad(result: "model")
            loader.request(directory, load: { load($0) }) { installs.models.append($0) }
            TestSupport.expect(!TestSupport.waitUntil(timeout: 0.3) { !installs.models.isEmpty }, "installed without a manifest")
            TestSupport.expectEqual(load.calls.current.count, 0)
            // Once bundle.json is there, the next request loads: the first ended without installing.
            try! manifest(decode).write(to: directory.appendingPathComponent("bundle.json"))
            TestSupport.expect(TestSupport.waitUntil(timeout: 5) {
                loader.request(directory, load: { load($0) }) { installs.models.append($0) }
                return load.calls.current.count == 1
            }, "not loaded")
            TestSupport.expect(TestSupport.waitUntil(timeout: 5) { installs.models == ["model"] }, "not installed")
        }
    }
}
