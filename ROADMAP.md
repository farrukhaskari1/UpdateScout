# UpdateScout roadmap

UpdateScout's durable position is a local-first, transparent update inbox for
the whole Mac: native applications and developer tools in one place, without
silently executing privileged changes.

## Delivered in this hardening release

- Swift 6 language mode and concurrency-safe shared caches.
- Real subprocess cancellation and bounded parallel provider scans.
- Honest incomplete-scan states and explicit parser/command failures.
- Fixture-backed tests for the highest-risk built-in parsers.
- User-declared providers through `sources.json`, making new ecosystems possible
  without recompiling the app.
- Keyboard and VoiceOver-friendly row and toolbar actions.
- A quieter single-list interface: all sources remain visible, scope tabs are
  gone, and occasional search expands from the header action row.
- Explicit per-item Update and Update All actions, with confirmation, in-app
  execution state, macOS authorization, and a copy fallback.
- CI plus Developer ID signing and notarization scaffolding.

## Next: trust and observability

- Persist successful scan snapshots so results remain visible while a refresh is
  running and maintain a short, user-controlled history.
- Add per-provider duration, last-success, and failure details.
- Add a privacy panel listing every executable, registry, and appcast endpoint a
  scan may contact.
- Capture anonymized diagnostics only as an explicit opt-in; local operation stays
  the default.

## Later: useful intelligence

- Optional OSV or vendor-advisory matching to distinguish routine updates from
  security-sensitive ones.
- Release-note summaries generated locally or through a user-selected service.
- Maintenance windows and command export profiles, while preserving explicit
  confirmation and visible in-app state for every update run.
- A documented provider schema and community-maintained source catalog built on
  the existing `sources.json` format.

## Later: interaction polish

- Add a Command-F shortcut and recent-query suggestions if real usage shows that
  search warrants faster keyboard access.
- Let people pin the few sources they care about most without hiding the rest.
- Offer an optional compact density and a richer details popover while preserving
  the fast, glanceable default list.

## Longer-term product paths

- A polished free/open-source power-user edition.
- A signed team edition that exports fleet status without sending installed-app
  inventories to a central service by default.
- Optional policy reporting for managed Macs: required versions, ignored updates,
  and compliance exports. This should remain reporting-first rather than becoming
  another opaque remote installer.

## Constraints requiring external decisions

- Public distribution needs an Apple Developer ID certificate and notarization
  credentials; `release.sh` is ready to use once those exist.
- Self-update requires choosing a release host and update framework. No third-party
  runtime was added without that decision.
- Security-advisory and team features need an explicit privacy model before any
  network or account infrastructure is introduced.
