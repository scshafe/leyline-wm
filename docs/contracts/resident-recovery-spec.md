# Independent resident recovery

`Leyline Recovery.app` is an on-demand Finder app outside the resident process.
It needs neither Accessibility nor Input Monitoring. It invokes `/bin/launchctl`
directly for `org.leyline.leylined`, using the installed direct-binary LaunchAgent.
It does not require the resident socket, its menu or the CLI dispatcher.

| Operation | Effect |
|---|---|
| Bounce | Grant-preserving `kickstart -k` of the registered job |
| Disable | `bootout`, then bounded verification that the job is deregistered |
| Re-enable | Bootstrap the installed plist, or recognize an already registered job |

Only launchctl's absent-service result 113 proves deregistration. Spawn/read/domain
failure is not successful Disable. A still-registered job fails after bounded
verification and one retry. Restarted PID or accepted launchctl command does not
prove resident readiness; health must report current observation/input capability.

Global **Stop Leyline** stops management while retaining the process and menu.
Recovery **Disable** removes the entire job from the current login session when
those controls are unreachable. The job uses `KeepAlive=true` and a one-second
crash throttle. Recovery never clears user configuration, deletes the journal or
sends a respawn-triggering kill to a registered job.

Hard reset is a separate native maintenance request. The resident's exclusive
owner quarantines the journal after bounded participant acknowledgments and
reconciles a fresh observation baseline. Recovery cannot fabricate that evidence.

Optional external keyboard-driver rules may invoke the Finder artifact below the
resident tap. They are user-managed and are not installed into a keyboard-remapper
profile automatically. Without such a driver, Finder remains the independent
recovery entry point.

The Recovery executable provides `--bounce --plan`, `--disable --plan` and
`--enable --plan` for non-actuating inspection; the test build adds `--self-test-core`.
`ley test recovery` checks direct routing, verified-down results, failures,
bootstrap and planning through hermetic executors. Live crash/wedge, trust and
grant behavior require genuine observations under [the responsiveness requirements](event-driven-responsiveness.md).
