# Resident command integration fixtures

`two_spaces.json` fixes an enabled two-window Space A and an independently
disabled Space B. Both displays have a 30-point top reservation. Three east
resize actions must accumulate three 40-point changes while at most one effect
is in flight and one desired batch is pending.

`leylined self-test resident-commands` drives the actual registered socket
surface, resident command controller, native planner, journal and effector.
Only the external AX port is injected. It acknowledges setters before
publishing independent generation/token-bound AX observations back through
CoreServer, so cached state and setter acknowledgments cannot silently count as
landing and recursive publication deadlocks are exercised.

Space OFF cancels an already issued command as `failed`, retaining its committed
desired revision and requested frames while reporting no landed frames when
the external port has not written. Cancellation does not claim unchanged model
state or verified completion.

Each normal rig first waits for named resident reconciliations to durably
bootstrap actual Space partitions and normalize their composite display scope.
Empty and all-OFF identified worlds commit model-only
journal records with a recoverable high-water revision and no AX issue. A real
Space change and return exercise the controller's dormant manual arrangement
cache. Bootstrap storage failure fences subsequent commands explicitly.

Healthy app/focus registration changes preserve issued and already admitted
frame goals only when the world epoch, exact scoped membership, PID, lifetime,
Space, display and topology remain valid. Targeted landing reports the actual
new observation generation while retaining the original request generation.
The checks also refuse new commands from stale modal authority and fence every
tested identity, scope or completeness change before another external write.
Restored world completeness starts a fresh reconciliation rather than replaying
the obsolete effect.

The 24 frozen scenarios include independent activation regressions. A same-value
Space B OFF command cannot allocate a revision or cancel held Space A work.
Meaningful B ON/OFF changes retain A's resize mode, interaction and captured
window lifetime/Space scope. Removing a sparse false activation override restores
the default ON value consistently to focus, windows and both context surfaces.
The baseline segment explicitly names its display; a separate unscoped specimen
keeps one-pass bootstrap, forces durable state-only normalization on resize entry and verifies the
world mode and origin commit alongside the model interaction with zero AX.

Matching cached frames on a settings event remain incomplete after a setter
acknowledgment; only independent AX notifications supply landing evidence.
Repeated cancellation and late setter callbacks publish a single terminal
result. A real hermetic input routing release advances its atomic generation
while the default-mode notification is held: the production per-write guard
rejects the already issued request and a delayed command from the old generation
before authority mode delivery, retaining committed/unlanded failed evidence
with zero external writes. No synthetic source generation stamp is used.

Recovery restores committed checkpoints and advances their high-water mark;
it never replays recorded mutations. Incomplete observation and journal failure
must cause no external effect. These checks are hermetic and establish no
physical visibility or live latency claim.
