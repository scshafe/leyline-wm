# Developer signing identity

A stable local code-signing identity can preserve the resident's macOS permission
identity across development builds. Builds sign ad hoc unless
`LEYLINE_CODESIGN_IDENTITY` names the intended certificate; creating the certificate
alone does not change how builds are signed. Signing failure is a build failure.

Use Keychain Access → Certificate Assistant → Create a Certificate to create a
local Code Signing identity, or inspect `bin/leyline-setup-signing-cert --help`
before using its setup helper. Keep its private key in the login keychain rather
than committing it. Inspect the built resident's signature with `codesign -dv
--verbose=4` and designated requirement with `codesign -dr -`.

A stable designated requirement binds the executable identifier and certificate.
Grant Accessibility and Input Monitoring to the installed resident identity.
Changing that identity may require new grants. Ad-hoc signing is suitable for
local source builds but does not promise grant continuity across different bytes.
Recovery needs neither permission; sign its complete bundle for its intended
Finder distribution.

A local certificate is not a Developer ID certificate and does not establish
Gatekeeper approval for downloads. A Developer ID signature identifies its
publisher. See [release preparation](../releasing.md) and
[Apple's notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Build/signature inspection does not prove selected grants, real keyboard delivery
or unprompted Finder launch. Preserve existing local grants and verify the actual
installed process rather than attributing permissions to a parent terminal.
