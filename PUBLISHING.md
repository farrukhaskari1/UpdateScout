# Publishing checklist

Use this checklist before making the repository public or creating a release.

## Before the first push

- Run `./scripts/check-public.sh` and `swift test`.
- Review `git status` and every file in the first public commit.
- Confirm commit authors use a GitHub noreply email if they do not want a
  personal address exposed in Git history.
- Do not add `.build`, `dist`, `.env` files, local JSON configuration, signing
  certificates, provisioning profiles, notarization credentials, or diagnostic
  output.
- Create the GitHub repository as private first, push, verify its contents, then
  change visibility to public.

## GitHub repository settings

- Enable secret scanning and push protection.
- Enable private vulnerability reporting.
- Protect the default branch and require the CI workflow to pass.
- Restrict workflow permissions to read-only by default. The included workflow
  already declares `contents: read`.

## Releases

- Keep Developer ID certificates and notarization credentials in the maintainer's
  keychain or encrypted CI secrets, never in repository files.
- Publish only the signed, notarized app archive and release notes.
- Verify the final archive with `codesign`, `spctl`, and notarization before
  attaching it to a GitHub release.
- Check the archive contents independently; do not upload an entire local working
  directory.

Secret scanners reduce risk but cannot prove that a repository is free of every
kind of sensitive information. A manual review is still required before changing
repository visibility.
