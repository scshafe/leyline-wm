# Preparing a release

The official baseline is **1.0.0**. Keep the root version, resident version output,
app bundle version and generated package names consistent. Build/export tooling
must reject inconsistent versions rather than silently choosing one.

## Validate the source

Run the production build, isolated developer runner and complete checks described
in [development](development.md). Review dependency closure, unused routes,
production/test boundaries, package resources, install/update/uninstall behavior
and public documentation links. Check the artifact's actual version and signature.
A registered job is not proof of input/observation readiness.

Use the release packager's authoritative interface:

```sh
python3 scripts/release/package_release.py --help
python3 scripts/release/package_release.py --output dist --arch universal --anonymous-history
```

It prepares versioned source/app archives and integrity metadata. The package
contains `Leyline.app`, `Leyline Recovery.app` and `install.sh`, with production
resources independent of the checkout. An extracted archive must install and
operate from a path containing spaces, without Python/Command Line Tools.
The universal package must contain `arm64` and `x86_64` slices for both resident
and Recovery; inspecting those slices does not establish Intel runtime testing.

## Anonymous public source

Export tracked source only. Exclude `.git`, private history/remotes, local handoffs,
user configuration/state, unrelated untracked files, signing material, build
caches, logs and generated private artifacts. Scan text and binaries for personal
names, email addresses, home/checkout paths, private endpoints and owner labels.
Use neutral `org.leyline` identifiers. Compile release artifacts from the clean
export so compiler diagnostics or embedded paths cannot retain the private checkout.

With `--anonymous-history`, the freshly exported public folder contains exactly
one generic baseline commit, the `v1.0.0` tag and no configured remote until the
publisher attaches the public origin. The source tarball contains no `.git`
directory. The original private history remains separate.
Do not publish the private repository's history or change its remote as an
anonymization shortcut. Inspect every file and metadata in the exact
public archive rather than relying on `.gitignore` alone.

Later releases omit `--anonymous-history`. Clone the public repository, replace
its tracked tree with the new export, and add one commit per release with the same
generic author, committer and fixed date, tagged `v<version>`. Public history is
appended, never rewritten; existing tags stay valid.

The project uses the [MIT License](../LICENSE), included in source and app
packages. Version1 uses the [public source repository](https://github.com/scshafe/leyline-wm)
and [Homebrew tap](https://github.com/scshafe/homebrew-tap). Ownership under this
GitHub account is deliberately disclosed. The privacy audit permits these exact
declared project URLs and tap commands while still rejecting personal paths,
emails, credentials and arbitrary identifying text.
Pass `--repository` with the chosen GitHub HTTPS repository to bind the Homebrew
formula to its versioned release URL and actual source checksum:

```sh
python3 scripts/release/package_release.py --output release-output --arch universal --anonymous-history --repository https://github.com/scshafe/leyline-wm
```

Without it, the packager generates `leyline.rb.in` with `OWNER/REPOSITORY`
placeholders and records `homebrew_repository_required`; it does not invent a tap.
Do not distribute that template as a working formula.

## Signing and publication

The prepared 1.0.1 universal app is ad-hoc signed and unnotarized. Source and
Homebrew builds can remain anonymous with this local signing profile. Developer ID
signatures expose the certificate's publisher identity. For normal direct-download
Gatekeeper distribution, use the intended Developer ID certificate, hardened
runtime and Apple's notarization workflow; verify the accepted result and staple
the ticket where applicable. See [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
Keep credentials in the publisher's secure environment, never source or artifacts.

Check `release-report.json`, `SHA256SUMS`, the actual Mach-O slices and complete
bundle signatures. State each artifact's actual architecture, signing/notarization
status and tested scope. Publish the matching checksums, license and [release notes](release-notes.md).
Do not describe a local build as notarized or a source-only formula as an available
public tap. Preparing assets does not publish them automatically.

Automated regression success is separate from physical keyboard, scanout, Space
persistence and induced-wedge recovery evidence. Report those limits honestly;
[responsiveness budgets](contracts/event-driven-responsiveness.md) remain engineering
requirements rather than achievements manufactured by packaging.
