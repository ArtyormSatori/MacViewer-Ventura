import Foundation

/// Latest-wins hand-off for decoded screen frames at the presentation
/// boundary (LAG_AUDIT FX-1).
///
/// Screen frames are complete bitmaps, so a frame that has not been
/// presented yet carries no information a newer frame does not already
/// supersede. Before this hand-off existed, decoded frames queued in
/// two unbounded FIFO streams between the session and the screen: the
/// picture stayed live-looking but fell further and further behind
/// reality, and every click's visible effect queued behind the backlog.
/// The coalescer bounds that queue at the presentation boundary:
///
/// - at most one frame is *awaiting consumption* (handed downstream,
///   not yet signalled consumed), and at most one further frame is
///   *pending* behind it;
/// - a newer frame offered while one is pending replaces it — the
///   replaced frame is counted in `coalescedDrops` and never presented;
/// - non-frame events never pass through here at all: the adapter
///   forwards them directly, in order, untouched.
///
/// Used only from the main actor (the adapter's reader and the model's
/// consumption signal both live there), so no internal locking.
final class LatestFrameCoalescer<Frame> {
    enum OfferOutcome {
        /// No frame was awaiting consumption: present this one now.
        case present(Frame)
        /// A frame is awaiting consumption; this one is queued behind it.
        case queued
        /// This one replaced an unpresented pending frame, which is
        /// dropped and counted in `coalescedDrops`.
        case coalesced
    }

    /// Frames dropped because a newer frame superseded them before
    /// they could be presented.
    private(set) var coalescedDrops = 0
    private var awaitingConsumption: Frame?
    private var pending: Frame?

    func offer(_ frame: Frame) -> OfferOutcome {
        if awaitingConsumption == nil {
            awaitingConsumption = frame
            return .present(frame)
        }
        if pending != nil {
            coalescedDrops += 1
            pending = frame
            return .coalesced
        }
        pending = frame
        return .queued
    }

    /// The consumer took the awaiting frame. Returns the pending frame
    /// to present next, if one queued up behind it.
    func consume() -> Frame? {
        awaitingConsumption = nil
        guard let next = pending else { return nil }
        pending = nil
        awaitingConsumption = next
        return next
    }

    /// Drops all hand-off state without counting: the session behind
    /// the frames is gone, so their freshness no longer matters.
    func reset() {
        awaitingConsumption = nil
        pending = nil
    }

    /// Whether a frame is currently handed downstream awaiting its
    /// consumption signal. Exposed for tests.
    var hasAwaitingFrame: Bool { awaitingConsumption != nil }
    /// Whether a newer frame is queued behind the awaiting one.
    var hasPendingFrame: Bool { pending != nil }
}
