# Contributing to UpdateScout

Thanks for helping improve UpdateScout.

## Before opening a change

1. Check existing issues and the roadmap to avoid duplicate work.
2. Keep the product boundary intact: scans are read-only. Upgrade commands may
   run only after explicit confirmation and must remain visible in Terminal.
3. For a new provider, explain which executable or public registry it contacts
   and how failures are presented to the user.

## Development

Requirements:

- macOS 13 or later
- Xcode with a Swift 6.2-or-newer toolchain

Run the checks before submitting a pull request:

```bash
./scripts/check-public.sh
swift test
swift build -c release
./build.sh
codesign --verify --deep --strict --verbose=2 dist/UpdateScout.app
plutil -lint dist/UpdateScout.app/Contents/Info.plist
```

Tests must work offline. Add synthetic fixtures for parser changes and include
failure cases when practical.

## Protect private information

Never commit real credentials, API tokens, signing certificates, provisioning
profiles, private registry URLs, personal application inventories, usernames,
home-directory paths, or unredacted diagnostic output. Use `example.com`, fake
package names, and clearly synthetic tokens in tests and documentation.

If a secret reaches Git history, removing it from the latest commit is not
enough. Revoke the secret first, then clean the repository history before any
push or release.

## Pull requests

Keep each pull request focused. Describe user-visible behavior, privacy or
network changes, and the verification performed. Security vulnerabilities
should follow the private process in [SECURITY.md](SECURITY.md), not a public
issue or pull request.
