import Foundation

/// The bookkeeping for one model the keyboard loads off the main thread (soft key edges, autocorrect): which
/// source the owner wants, which source the model it holds came from, and the one load in flight. The owner
/// keeps the model itself and does the loading; the slot decides when a load starts and whether its result is
/// installed (ARCHITECTURE.md, "Soft key edges" and "Word autocorrect").
///
/// - Asking again for the source already held, or already loading, starts nothing: switching keyboards away
///   and back while a slow load runs does not load the model twice.
/// - Asking for another source, or for none, drops the model held. A load for a source no longer wanted ends
///   without being installed, unless that source is wanted again before it ends: then it is installed.
/// - A load superseded by one for another source ends without being installed, as does a load that failed;
///   either way the next request for the source loads it again, so no change leaves the model unloaded for
///   good.
///
/// Used on one actor (the main thread); `Source` is what the owner loads from, such as a bundle directory.
struct ModelLoadSlot<Source: Equatable & Sendable>: Equatable, Sendable {
    /// One load: the source to load from, and the request that started it.
    struct Ticket: Equatable, Sendable {
        let source: Source
        let id: Int
    }

    /// What the owner does after a request.
    struct Step: Equatable, Sendable {
        /// Drop the model held: it is not from the source wanted now.
        var dropModel: Bool
        /// Start this load, and report its end with `finish(_:loaded:)`; nil starts nothing.
        var load: Ticket?
    }

    /// The source the owner wants a model from; nil when it wants none.
    private(set) var wanted: Source?
    /// The source of the model the owner holds; nil when it holds none.
    private(set) var held: Source?
    /// The load in flight whose result can still be installed; nil when none.
    private(set) var loading: Ticket?
    private var lastID = 0

    init() {}

    /// The owner wants the model from `source`, or none (nil): the model to drop and the load to start.
    mutating func request(_ source: Source?) -> Step {
        wanted = source
        let dropModel = held != nil && held != source
        if dropModel { held = nil }
        guard let source, held == nil, loading?.source != source else {
            return Step(dropModel: dropModel, load: nil)
        }
        lastID += 1
        let ticket = Ticket(source: source, id: lastID)
        loading = ticket
        return Step(dropModel: dropModel, load: ticket)
    }

    /// The load `ticket` ended with a model (`loaded`) or without one. True: the owner installs the model,
    /// now held. False: the owner discards whatever it loaded.
    mutating func finish(_ ticket: Ticket, loaded: Bool) -> Bool {
        guard loading == ticket else { return false }
        loading = nil
        guard loaded, wanted == ticket.source else { return false }
        held = ticket.source
        return true
    }
}
