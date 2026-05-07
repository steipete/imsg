---
title: Releasing
description: "Cutting an imsg release: changelog, version bump, signed/notarized build, tag, GitHub release, Homebrew tap update."
---

## Release notes source
- GitHub Release notes come from `CHANGELOG.md` for the matching version section (`## X.Y.Z - YYYY-MM-DD`).
- Keep `## Unreleased` at the top (empty is fine).

## Steps
1. Update `CHANGELOG.md` and version
   - Move entries from `Unreleased` into a new `## X.Y.Z - YYYY-MM-DD` section.
   - Credit contributors (e.g. `thanks @user`).
   - Update `version.env` to `X.Y.Z`.
   - Run `scripts/generate-version.sh` (also refreshes `Sources/imsg/Resources/Info.plist`).
2. Ensure CI is green on `main`
   - `make lint`
   - `make test`
   - GitHub Actions `linux-read-core`
   - `make format` (optional, if formatting changes are expected)
3. Build, sign, and notarize
   - Requires `APP_STORE_CONNECT_API_KEY_P8`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`.
   - `scripts/sign-and-notarize.sh` (outputs `/tmp/imsg-macos.zip` by default)
   - Linux release archives are built by `.github/workflows/release.yml` with
     `scripts/build-linux.sh` and uploaded as `imsg-linux-x86_64.tar.gz`.
   - Verify the zip contains required SwiftPM bundles (e.g. `PhoneNumberKit_PhoneNumberKit.bundle`).
   - Verify entitlements/signing:
     - `unzip -q /tmp/imsg-macos.zip -d /tmp/imsg-check`
     - `codesign -d --entitlements :- /tmp/imsg-check/imsg`
     - `spctl -a -t exec -vv /tmp/imsg-check/imsg`
4. Tag, push, and publish
   - `git tag -a vX.Y.Z -m "vX.Y.Z"`
   - `git push origin vX.Y.Z`
   - `gh release create vX.Y.Z /tmp/imsg-macos.zip -t "vX.Y.Z" -F /tmp/release-notes.txt`
   - Run `.github/workflows/release.yml` for the tag to upload the Linux archive
     (`imsg-linux-x86_64.tar.gz`). Leave `include_macos` off unless you
     intentionally want a manual macOS rebuild.
   - `gh release edit vX.Y.Z --notes-file /tmp/release-notes.txt` (if needed)
5. Update Homebrew tap
   - Run `scripts/update-homebrew.sh vX.Y.Z` to trigger the centralized formula updater.
   - Requires a GitHub token with workflow dispatch access to `steipete/homebrew-tap`.

## What happens in CI
- Release signing + notarization are done locally via `scripts/sign-and-notarize.sh`.
- `.github/workflows/release.yml` is only for manual rebuilds, not the primary release path.

## Linux support schedule
- The next patch release may include an experimental Linux `x86_64` archive,
  but the user-facing docs should still describe Linux as read-only preview
  support until install and packaging are proven on a tagged release.
- Linux work is staged as a read-only core pass: SwiftPM build, Linux-only tests,
  release archive generation, and CI coverage for reading a copied Messages
  database fixture.
- Promote Linux to full user docs only after the read-only command set is green
  in CI, Crabbox has verified the same gate on Linux, and install instructions
  exist for the published archive.
