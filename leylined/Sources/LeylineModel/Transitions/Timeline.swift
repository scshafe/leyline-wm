// The timeline core core state advances ONLY through synchronous,
// non-awaiting transitions — every async result (landed evidence, world event,
// journal ack) re-enters as its own transition. Files under Transitions/ are
// covered by the structural no-`await` lint in `ley test leylined`; the actor
// that serializes calls onto this type lives in the daemon, never here.
public struct Timeline<State> {
    public private(set) var state: State
    public private(set) var revision: Revision

    /// `revision` seeds from the journal's high-water mark on recovery
    /// A store recovered at900 continues at901.
    public init(state: State, revision: Revision) {
        self.state = state
        self.revision = revision
    }

    /// Apply one transition. The body mutates a DRAFT; the draft is committed
    /// and the revision minted iff the body reports `.accepted` — so
    /// "refused/noop/failed leave state unchanged" is a mechanism of this
    /// type, not a convention of its callers (core-spec §WmResult).
    @discardableResult
    public mutating func apply(_ body: (inout State) -> WmStatus) -> WmResult {
        var draft = state
        let status = body(&draft)
        switch status {
        case .accepted:
            state = draft
            revision = revision.next()
            return WmResult(status: .accepted, revision: revision)
        case .noop, .refused, .failed:
            return WmResult(status: status, revision: revision)
        }
    }
}
