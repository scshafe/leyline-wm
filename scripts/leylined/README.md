# Resident installation development seam

The installed resident's native launchd interface owns installation, inspection,
update and removal of the direct `org.leyline.leylined` user job. A downloaded
package requires no Python or compiler. The job uses `KeepAlive=true` and a
one-second crash throttle. Installer operations preserve configuration/journals.

Any script retained in this directory is a source-development or test seam, not
an alternate runtime owner. Finder Recovery invokes launchctl directly without the
resident socket, CLI dispatcher, Accessibility or Input Monitoring. See
[installation](../../docs/installation.md) and [recovery](../../docs/contracts/resident-recovery-spec.md).
