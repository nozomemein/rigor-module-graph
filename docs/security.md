# Security

Supply-chain controls for this gem, in one place. Each layer
is independent — a single one being bypassed doesn't void the
others — and each has a re-runnable command you can verify on
the spot.

## Layered controls

| layer | what it guards | gate |
|---|---|---|
| Bundler cooldown | dependency versions less than 7 days old never enter `Gemfile.lock` | `.bundle/config` `BUNDLE_COOLDOWN: "7"` |
| Dependabot cooldown | bump PRs are never proposed for sub-7-day versions | `.github/dependabot.yml` `cooldown.default-days: 7` |
| Vendored JS sha256 | `lib/.../templates/vendor/*` bytes match what was recorded at commit time | `rake vendor:verify` (pre-commit + CI) |
| Vendored JS 4-source audit | the bytes were the bytes upstream actually published | `rake vendor:audit` (bump PR only) |
| Workflow lint | GitHub Actions security pitfalls (mutable refs, missing `persist-credentials`, …) | `zizmor` (pre-commit + CI workflow-lint job) |
| Secret scan | accidentally-staged credentials | `betterleaks` (pre-commit) |
| Action SHA pinning | a `@v4` tag can't get silently retargeted underneath us | `zizmor`'s `unpinned-uses` audit, blanket policy |
| Trusted publishing | `gem push` runs without a long-lived API key on disk | `release.yml` uses OIDC; no `RUBYGEMS_API_KEY` secret exists |

## Bundler cooldown (7 days)

`.bundle/config` carries:

```yaml
---
BUNDLE_COOLDOWN: "7"
```

`bundle install` / `bundle update` refuse to pick up a
dependency version that's been live on rubygems.org for less
than seven days. The supply-chain-attack mitigation Bundler
2.6+ ships: a malicious gem yanked within hours of
publication never enters the lockfile in the first place.

The file is committed; the rest of `.bundle/` stays in
`.gitignore` via the `/.bundle/*` + `!/.bundle/config`
pattern. To opt out for a single install, pass
`BUNDLE_COOLDOWN=0 bundle install`.

`.github/dependabot.yml` applies the same 7-day window to the
*proposing* side — Dependabot never opens a bump PR for a
version yanked within seven days of publication. The two
layers compose: a bad version that slips Dependabot's gate
still has to pass `bundle install`'s.

## Vendored third-party JavaScript

`lib/rigor/module_graph/templates/vendor/` carries third-party
JS the interactive viewer is built on (currently
`cytoscape.min.js`). The directory is treated as a sealed
boundary:

- Each file is pinned to a specific upstream release; the
  sha256 lives in `vendor/CHECKSUMS` alongside it.
- Per-file provenance (npm package name, `dist.integrity`
  sha512, GitHub raw URL, CDN mirrors, license, release date)
  lives in `vendor/MANIFEST.yml`. `rake vendor:audit` reads
  it; `rake vendor:verify` doesn't.
- No CDN reference: the gem ships the bytes, the HTML embeds
  them inline, the user's HTML opens offline.
- Dependabot is configured to ignore this directory entirely
  (`.github/dependabot.yml`); bumps are manual PRs only.

### `rake vendor:verify` — local integrity gate

Runs on every commit (pre-commit hook) and on every CI run
(`lint` job in `.github/workflows/ci.yml`). Recomputes sha256
for each file pinned in `CHECKSUMS`; mismatch fails the gate.

What this catches: bytes on disk no longer matching what was
committed.

What this does NOT catch on its own: bytes that were silently
wrong at commit time. For that, see `vendor:audit`.

### `rake vendor:audit` — bump-PR cross-check

Network-using; not part of the regular CI pipeline. For each
file in `MANIFEST.yml`, asserts the local sha256 matches:

1. **npm tarball integrity** — sha512 over the published
   tarball, compared against the registry's `dist.integrity`
   field (signed by npm).
2. **The tarball-internal copy** — sha256 over
   `package/dist/<filename>` inside the unpacked tarball.
3. **The GitHub raw URL** — sha256 over the file at the
   pinned release tag's raw blob.
4. **Every CDN mirror** listed under `cdns:` (currently
   jsDelivr + unpkg).

Single-point compromise of any one of {npm publish, GitHub
release, jsDelivr edge, unpkg edge} surfaces as a mismatch
on one row instead of being invisible.

Sample output (current cytoscape pin):

```
$ bundle exec rake vendor:audit
==> cytoscape.min.js
  local                  sha256 OK
  npm tarball            integrity OK
  npm tarball:package/dist/cytoscape.min.js  sha256 OK
  github (raw)           sha256 OK
  cdn[0]                 sha256 OK
  cdn[1]                 sha256 OK
vendor:audit: all sources agree
```

### Bumping a vendored asset — SOP

Documented in full in
[`vendor/CHECKSUMS`](../lib/rigor/module_graph/templates/vendor/CHECKSUMS)
so future-maintainer-you can follow the recipe without
re-reading this doc. Compressed version:

1. Update `MANIFEST.yml` with the new version (release tag,
   release date, npm version, `dist.integrity`, tarball URL,
   GitHub raw URL, CDN URLs).
2. Replace the file under `templates/vendor/`. Update its
   sha256 row in `CHECKSUMS`.
3. `bundle exec rake vendor:audit` — must show "all sources
   agree" before the PR is mergeable. Paste the output into
   the PR description.
4. Update `last_audited:` in `MANIFEST.yml` to today's date.

Reviewer checklist: diff scope (only the three vendor files),
metadata fields match the new version, audit output present,
`npm audit signatures cytoscape@<new>` clean when npm is
available locally.

## CI / release hardening

- **All GitHub Actions are SHA-pinned**, enforced by `zizmor`'s
  `unpinned-uses` audit (default blanket policy in
  `.github/zizmor.yml`). The trailing comment beside each SHA
  records the tag so the diff is reviewable in one pass.
- **`workflow-lint` job** runs `zizmor` over the workflow
  files themselves on every push and PR, with
  `security-events: write` so findings surface in the
  repository's Security tab.
- **Release workflow uses RubyGems Trusted Publishing (OIDC)**
  via `rubygems/release-gem`. No long-lived API key is stored
  as a secret. Only `id-token: write` and `contents: write`
  permissions are granted, and both are scoped to the
  `release` job rather than the workflow.
- **README image cache purge** (`.github/workflows/purge-readme.yml`)
  asks `camo.githubusercontent.com` to drop its cached copies
  whenever `main` updates. Mostly a freshness concern, but
  it's also the only way to flush a cached image that was
  hosting an out-of-date or compromised asset.

## Pre-commit / pre-push hook layers

See [`development.md`](development.md) for the full lefthook
table. The security-relevant subset:

| hook | scope | what it gates |
|---|---|---|
| `betterleaks` (pre-commit, `--staged`) | staged content | accidentally-staged credentials / API keys |
| `zizmor` (pre-commit, `glob` on `.github/workflows/*.yml`) | staged workflow files | mutable action refs, missing `persist-credentials`, overbroad permissions |
| `vendor-verify` (pre-commit, `glob` on `lib/**/templates/vendor/**`) | staged vendor files | sha256 manifest drift |

Skip a hook ad-hoc with `LEFTHOOK_EXCLUDE=<name>`; the same
checks run independently in CI so the gate is preserved
across-the-board.
