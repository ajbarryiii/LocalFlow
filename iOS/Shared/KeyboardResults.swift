import Foundation

/// What one keyboard instance does with the results it can read.
struct ResultPlan: Equatable, Sendable {
    /// Bound to the current field: claim and insert these now, oldest first.
    var autoInsert: [DictationResult] = []
    /// The newest other fresh, unclaimed result, offered as "Insert last dictation".
    var manualInsert: DictationResult?
}

/// Per-instance destination bindings and consumed requests. Held in memory only; delivery is at most
/// once and a transcript is auto-inserted only into the field its request is bound to. A
/// `documentID` is `textDocumentProxy.documentIdentifier`; nil never matches anything.
struct KeyboardResultLedger: Equatable, Sendable {
    enum Disposition: Equatable, Sendable { case autoInsert, offerManualInsert, ignore }

    private(set) var bindings: [UUID: UUID] = [:]
    /// Requests whose binding a focus change removed. Displaying them again never rebinds them.
    private(set) var invalidated: Set<UUID> = []
    private(set) var consumed: Set<UUID> = []

    /// Call after writing `finish(R)`. The user stopped R in this field, so this binding stands
    /// even if a focus change invalidated an earlier one.
    mutating func bindFinish(requestID: UUID, documentID: UUID?) {
        guard let documentID, !consumed.contains(requestID) else { return }
        bindings[requestID] = documentID
        invalidated.remove(requestID)
    }

    /// Call with every computed mode. An instance displaying R as recording or transcribing binds R
    /// to the current field, so a host auto-finish or another instance's finish still lands here.
    mutating func noteDisplayed(_ mode: KeyboardMode, intent: StoreRead<KeyboardIntent>, documentID: UUID?) {
        switch mode {
        case .recording, .transcribing: break
        default: return
        }
        guard let requestID = intent.value?.requestID, let documentID, bindings[requestID] == nil,
              !invalidated.contains(requestID), !consumed.contains(requestID) else { return }
        bindings[requestID] = documentID
    }

    /// Call whenever `documentIdentifier` may have changed (`textDidChange`, `viewWillAppear`).
    /// Bindings to any other field are invalidated.
    mutating func documentChanged(to documentID: UUID?) {
        for (requestID, bound) in bindings where bound != documentID {
            bindings[requestID] = nil
            invalidated.insert(requestID)
        }
    }

    func disposition(of result: DictationResult, documentID: UUID?, now: Date) -> Disposition {
        guard result.schema == DictationProtocol.schema, !consumed.contains(result.requestID),
              DictationProtocol.isFresh(result.createdAt, ttl: DictationProtocol.resultTTL, now: now)
        else { return .ignore }
        if let documentID, bindings[result.requestID] == documentID { return .autoInsert }
        return .offerManualInsert
    }

    func plan(for results: [DictationResult], documentID: UUID?, now: Date) -> ResultPlan {
        let ordered = results.sorted { ($0.createdAt, $0.requestID.uuidString) < ($1.createdAt, $1.requestID.uuidString) }
        return ResultPlan(
            autoInsert: ordered.filter { disposition(of: $0, documentID: documentID, now: now) == .autoInsert },
            manualInsert: ordered.last { disposition(of: $0, documentID: documentID, now: now) == .offerManualInsert })
    }

    /// Claim before insert: deletes `result-R.json` and returns true only if this call removed it,
    /// so a transcript is inserted at most once across instances and processes. R is consumed once
    /// the file is gone, whoever removed it. If the delete failed, the result may still be on disk,
    /// so the binding and eligibility stay as they were and a later poll retries.
    mutating func claim(requestID: UUID, in store: SharedDictationStore) -> Bool {
        guard !consumed.contains(requestID) else { return false }
        let removal = store.removeResult(requestID: requestID)
        guard removal != .failed else { return false }
        consumed.insert(requestID)
        bindings[requestID] = nil
        invalidated.remove(requestID)
        return removal == .removed
    }
}
