# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for this repository.
Do not open a public issue containing exploit details, credentials, private URLs,
application inventories, or other sensitive information.

Include the affected version or commit, expected and observed behavior, impact,
and minimal reproduction steps. Remove tokens, usernames, machine paths, and
unrelated system information before attaching logs or screenshots.

## Scope

Security reports are especially useful for command construction, subprocess
handling, unsafe URL handling, credential exposure, update-feed parsing, and
privilege-boundary mistakes. UpdateScout must never run an update during a scan,
in the background, or without an explicit confirmation. Confirmed commands run
visibly in Terminal so password prompts and failures are not hidden.

## Supported versions

Until the first signed public release, security fixes are made on the latest
commit of the default branch.
