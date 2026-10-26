import Foundation

/// Loads one of the keyboard's models (swipe typing, soft key edges, autocorrect) from a swipe bundle off the
/// main thread and hands it to its owner on the main thread. `ModelLoadSlot` decides when a load starts and
/// whether its result is installed (ARCHITECTURE.md, "Soft key edges"); the loader keeps no model, the owner's
/// `install` does. Each model has its own loader, so the models still load in parallel.
@MainActor
final class BundleModelLoader<Model: Sendable> {
    private var slot = ModelLoadSlot<URL>()

    nonisolated init() {}

    /// The owner wants the model from the bundle in `directory`, or none (nil). A model no longer wanted is
    /// dropped on the spot with `install(nil)`. A load starts unless the model is already held or loading:
    /// `load` runs off the main thread with the bundle's manifests, and `install` gets its model, on the main
    /// thread, only if the slot still wants it. A bundle without a readable `bundle.json`, or a nil from
    /// `load`, installs nothing, and the next request loads again.
    func request(_ directory: URL?, load: @escaping @Sendable (SwipeBundle) -> Model?,
                 install: @escaping @MainActor (Model?) -> Void) {
        let step = slot.request(directory)
        if step.dropModel { install(nil) }
        guard let ticket = step.load else { return }
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                SwipeBundle.decoded(at: ticket.source).flatMap(load)
            }.value
            guard let self, self.slot.finish(ticket, loaded: loaded != nil), let loaded else { return }
            install(loaded)
        }
    }
}
