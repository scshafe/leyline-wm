# Responsiveness evidence fixtures

`inventory.json` records current native actions, interaction scenarios, event
sources, invalidation rules, endpoint budgets and purpose-specific deadlines.
Removing a discovered path fails validation. Budget, deadline and scene digests
prevent edits from silently weakening acceptance requirements.

Border receipt to render submission p95 is 16 ms; receipt to independently
observed physical visibility p95 is 125 ms. These are acceptance targets requiring
real refresh-rate/load and independent endpoint evidence. Setter acknowledgment,
AppKit submission and this fixture suite cannot certify physical visibility.

The runtime cache integrity audit samples complete worlds outside interaction.
Socket request frames are capped at 64 KiB and a 2-second whole-frame deadline;
accepted connections are bounded at 128. Subscription writes have their own
backlog and send deadline. Fifteen timer purposes and 16 latency budgets are
recorded; changing the frame-read deadline fails a dedicated mutation check. No
socket wait polls keyboard or layout.

Developer readers: `bin/leylined-tests self-test responsiveness --list-scenarios`
and `bin/leylined-tests self-test responsiveness`. The production runtime reports
actual bounded facts through `ley resident trace`.
