# Release Process

This document describes how releases of the Convert iOS SDK are produced and
what needs to be configured before the release pipeline can run.

The short version: **a release is cut by pushing a SemVer git tag (`vX.Y.Z`)
to `origin`.** Pushing the tag fires the **Release** workflow
(`.github/workflows/release.yml`), which validates the build, creates a GitHub
Release with auto-generated notes, and — if the CocoaPods token is configured —
publishes both pods to the CocoaPods Trunk.

The **git tag is the single source of truth for the version.** There is no
semantic-release driving `main`, no automated version-bump commit, and no
committed `CHANGELOG.md`. The one manual step is bumping `s.version` in both
podspecs on `main` *before* you push the tag (the workflow fails fast if you
forget).

## The two distribution channels

| Channel | How a version becomes available | Needs publishing infra? |
|---|---|---|
| **Swift Package Manager** (primary) | The moment the `vX.Y.Z` tag exists on `origin`. SPM resolves package versions directly from git tags — no registry, no upload. | **No.** Pushing the tag *is* the SPM publish. |
| **CocoaPods** (courtesy) | When `pod trunk push` uploads each podspec to the public CocoaPods Trunk. | Yes — a CocoaPods Trunk session token (`COCOAPODS_TRUNK_TOKEN`). |

Because SPM publishes on the tag itself, the GitHub Release and the CocoaPods
push are *additive*: the Release adds human-readable notes, and the trunk push
makes the version installable via `pod`. A failure in the CocoaPods step never
retracts the SPM release — SPM consumers already have the tag.

---

## One-Time Setup (Repo Admin)

SPM needs **no** setup — the public GitHub repo plus a tag is the entire
mechanism. Everything below exists only to enable the optional CocoaPods
channel. Until it is done, releases still succeed; the CocoaPods push step is
skipped (see the [`COCOAPODS_TRUNK_TOKEN` guard](#safeguards-do-not-remove)).

### 1. Register a CocoaPods Trunk session

CocoaPods Trunk accounts have **no passwords — only per-computer session
tokens**. Register once from a maintainer machine:

```bash
gem install cocoapods --no-document
pod trunk register support@convert.com 'Convert.com' --description='convert release machine'
```

Trunk emails a verification link to `support@convert.com`. **Click it** — the
session is inert until you do. After verification the session token is written
to `~/.netrc` under `machine trunk.cocoapods.org`.

### 2. Claim the pod names

Pod-name ownership is claimed by the **first push** of each podspec — the
account that first pushes `ConvertSDK` / `ConvertSDKCore` becomes its owner.
The first real release (step "Triggering a Release" below) performs that first
push automatically. No separate claim step is required, but be aware the
**first** `v1.0.0` release is also what locks in ownership of both pod names on
Trunk. Add co-maintainers afterwards with:

```bash
pod trunk add-owner ConvertSDK    second-maintainer@convert.com
pod trunk add-owner ConvertSDKCore second-maintainer@convert.com
```

### 3. Extract the token and add it as a repository secret

CI authenticates with the token via the `COCOAPODS_TRUNK_TOKEN` environment
variable (read by the `cocoapods-trunk` plugin). Pull it out of `~/.netrc`:

```bash
grep -A2 'trunk.cocoapods.org' ~/.netrc
# machine trunk.cocoapods.org
#   login support@convert.com
#   password <THIS-IS-THE-TOKEN>
```

Add the `password` value as a GitHub repository secret named
`COCOAPODS_TRUNK_TOKEN`:

**GitHub → repo → Settings → Secrets and variables → Actions → New repository secret**

Best practice (per the CocoaPods CI guidance): after copying the token into the
CI secret, run `pod trunk register …` **again** on your local machine so your
laptop and CI hold *separate* tokens. Then a leaked or rotated CI token never
locks you out locally.

> Trunk session tokens can expire (community-reported lifetime ~128 days). If a
> previously-working release suddenly fails the CocoaPods push with an auth
> error, the token has almost certainly expired — re-register and update the
> secret (see [Troubleshooting](#troubleshooting)).

### 4. Repository secrets summary

| Secret | Required | Source |
|---|---|---|
| `GITHUB_TOKEN` | yes (auto) | Provided automatically by GitHub Actions to every workflow run — nothing to configure. Used by `gh release create`. |
| `COCOAPODS_TRUNK_TOKEN` | optional | CocoaPods Trunk session token from `~/.netrc` (steps 1–3). **If absent, the release still succeeds** and only the CocoaPods push is skipped. |

There is **no** GPG signing key, no Maven Central / Sonatype namespace, and no
publisher login to configure — none of those apply to SPM or CocoaPods Trunk.

---

## Triggering a Release

A release is a **tag push**. The steps:

1. **Bump `s.version` in BOTH podspecs on `main`.** Edit `ConvertSDK.podspec`
   and `ConvertSDKCore.podspec` so each `s.version` equals the version you are
   about to release (e.g. `1.2.0`). Open this as a normal PR and merge it to
   `main`. Both files must carry the *same* version — `ConvertSDK` depends on
   `ConvertSDKCore` at an exact version (`s.dependency 'ConvertSDKCore', s.version.to_s`).

   > For the very first release the podspecs already ship `1.0.0`, so v1.0.0
   > needs no bump — just tag.

2. **Pull `main` and push the tag** at the commit that contains the bumped
   podspecs:

   ```bash
   git checkout main
   git pull origin main
   git tag v1.2.0          # tag must be vX.Y.Z — no v1.2, no -beta suffix
   git push origin v1.2.0
   ```

3. The tag push fires **`.github/workflows/release.yml`** on a `macos-26`
   runner. It runs, in order:

   1. **Extract version from the tag** — `VERSION=v1.2.0`,
      `VERSION_NUMBER=1.2.0`. The version comes *only* from the tag.
   2. **Assert podspec versions match the tag** — greps `s.version` from both
      podspecs and fails immediately if either ≠ `1.2.0`. This is the guard
      that catches a forgotten step 1.
   3. **Dry-run gate A — `swift build`.** A publish must never ship a broken
      build.
   4. **Dry-run gate B — consumer smoke build.** A throwaway SPM package is
      generated under `$RUNNER_TEMP` (outside the repo tree), depends on this
      SDK by path, and does `import ConvertSDK` + `swift build` — proving the
      tagged SDK resolves and compiles for an external consumer.
   5. **Create the GitHub Release** — `gh release create "$VERSION" --title
      "$VERSION" --generate-notes`. Notes are GitHub-native, grouped from the
      Conventional-Commit messages since the previous tag. **No** commit, **no**
      push to any branch, **no** `CHANGELOG.md` — the only mutation is the
      Release object.
   6. **Publish to CocoaPods Trunk** *(only if `COCOAPODS_TRUNK_TOKEN` is set)* —
      installs CocoaPods, then pushes **core first**. The `ConvertSDK` push adds
      `--synchronous` so its dependency validation finds the `ConvertSDKCore`
      version published seconds earlier, before Trunk's ~5-min CDN propagation:

      ```bash
      pod trunk push ConvertSDKCore.podspec --allow-warnings
      pod trunk push ConvertSDK.podspec     --allow-warnings --synchronous
      ```

4. **Verify.** SPM consumers can resolve `v1.2.0` as soon as the tag is on
   `origin`. For CocoaPods, the new version appears on the CDN within minutes:

   ```bash
   pod trunk info ConvertSDK        # lists published versions
   pod repo update && pod search ConvertSDK
   ```

### Version Numbering

- The first release (no prior tag) is **v1.0.0**; the repo's podspecs already
  ship `1.0.0`.
- Every subsequent version is chosen by the maintainer and encoded in the tag —
  follow [SemVer](https://semver.org): `fix:`-level → patch, `feat:`-level →
  minor, breaking → major. (The commit *prefixes* shape the auto-generated
  release notes; they do **not** compute the number — you do, via the tag.)
- The tag glob `v[0-9]+.[0-9]+.[0-9]+` is strict: `v1`, `v1.2`, `vtest`, and
  pre-release tags like `v1.0.0-beta.1` are **ignored** and trigger nothing.

---

## Previewing a Release: Dry Run

There is no `semantic-release --dry-run`. Instead, reproduce the workflow's two
gates locally before tagging — they are exactly what CI runs:

```bash
# Gate A + the rest of the CI suite (matches ci.yml):
swift build
swift test                                   # incl. the seed-9999 parity suite
swiftlint lint --strict                      # CI runs this with --strict

# Gate B — the external-consumer smoke (what release.yml does under $RUNNER_TEMP):
#   create a throwaway SPM package that depends on this repo by path and
#   `import ConvertSDK`, then `swift build` it. See release.yml "Dry-run gate B"
#   for the exact snippet.
```

To validate the **CocoaPods** side locally before the tag (CocoaPods is the only
channel that can fail *after* the GitHub Release is already live, so it is worth
pre-checking), lint both podspecs — core first, and lint the umbrella pod
against the *unpublished* local core with `--include-podspecs`:

```bash
pod lib lint ConvertSDKCore.podspec --allow-warnings
pod lib lint ConvertSDK.podspec     --allow-warnings --include-podspecs='ConvertSDKCore.podspec'
```

`--allow-warnings` matches the flag the workflow's `pod trunk push` uses;
`--include-podspecs` lets `ConvertSDK` resolve `ConvertSDKCore` from the working
tree instead of from Trunk (where it does not exist until the release pushes it).

---

## Why tag-driven, not semantic-release

The Android SDK releases via semantic-release on every merge to `main`. The iOS
SDK deliberately does **not** — and the reasoning is documented at the top of
`release.yml`. In short: semantic-release **hard-requires push-to-branch
credentials** (it runs `verifyAuth` and pushes the tag + notes itself) and
*computes* its own version, so it cannot create a Release for a **pre-pushed**
tag without also pushing to protected `main`. The tag-driven model sidesteps
that entirely: the human pushes the tag, and CI only *reacts* to it with
`gh release create … --generate-notes`.

An isolated semantic-release manifest is **kept** at `Scripts/release/`
(`.releaserc.json` + its own `package.json`) as a reference/tooling artifact.
It is **not part of the SPM product graph and is not invoked by the release
workflow.** Do not wire it into `release.yml` expecting it to publish — see the
deviation block at the top of that file for the empirical evidence on why it
cannot satisfy the "no push to protected `main`" invariant.

---

## Safeguards (DO NOT REMOVE)

`release.yml` encodes four invariants. Each prevents a specific failure mode;
removing one re-opens that hole.

1. **Tag-only trigger.** The workflow has `on: push: tags: 'v[0-9]+.[0-9]+.[0-9]+'`
   and deliberately **no `branches:` key and no `workflow_dispatch:`**. A branch
   merge therefore can never trigger a spurious release. If you are tempted to
   add a branch trigger "for convenience," don't — it would publish on every
   merge.

2. **Podspec-version assertion.** The "Assert podspec versions match tag" step
   fails the release *before* anything is published if either podspec's
   `s.version` ≠ the tag. This is what makes the manual bump safe: forgetting it
   is loud and harmless, not silent and shipped.

3. **`COCOAPODS_TRUNK_TOKEN` guard.** The CocoaPods step is gated on
   `if: env.COCOAPODS_TRUNK_TOKEN != ''`. In a fork (or any environment without
   the secret) the push is **skipped silently** instead of failing red with a
   missing-credential error. This keeps fork CI green and keeps the secret out
   of fork-triggered runs. Keep the guard.

4. **Core-pushed-first ordering + `--synchronous`.** `ConvertSDK.podspec` declares
   `s.dependency 'ConvertSDKCore', s.version.to_s`. Trunk validates dependencies
   at push time, so `ConvertSDKCore` **must** be pushed before `ConvertSDK` —
   otherwise the umbrella push fails because Trunk can't resolve the core pod. The
   `ConvertSDK` push also carries `--synchronous` so its validation reads the master
   Specs repo instead of the ~5-min-lagged CDN and finds the just-pushed core. Do
   not reorder the two pushes or drop `--synchronous`.

---

## Rollback Procedure

**Published versions are effectively immutable on both channels** — plan to roll
*forward*, not back.

**CocoaPods.** `pod trunk delete ConvertSDK X.Y.Z` exists, but the CocoaPods
guidance is explicit: *"It is generally considered bad behavior to remove
versions others depend on,"* and **once a version is deleted it can never be
pushed again** (the name+version is burned). Do not delete a released version.

**Swift Package Manager.** SPM resolves from git tags. Deleting or moving a
published tag is technically possible but **breaks every consumer who already
resolved it** and is equally discouraged.

When a release is bad:

1. Do **not** delete the tag, the GitHub Release, or the pod version.
2. Push a `fix:` commit that addresses the problem.
3. Bump both podspecs to the next patch (e.g. `1.2.3` → `1.2.4`), merge to
   `main`, and push the `v1.2.4` tag — the normal release flow.
4. Reference the superseded version in the new release's notes.

If a release is catastrophically broken (e.g. it shipped a security issue),
additionally mark the old pod as deprecated so consumers are nudged forward:

```bash
pod trunk deprecate ConvertSDK --in-favor-of=ConvertSDK   # or point elsewhere
```

(SPM has no deprecation mechanism — the roll-forward patch is the remedy there.)

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Release workflow didn't run after pushing a tag | Tag didn't match `v[0-9]+.[0-9]+.[0-9]+` (e.g. `v1.2`, `1.2.0` with no `v`, or a `-beta` suffix). | Delete the bad local/remote tag and push a strictly-`vX.Y.Z` tag. |
| Workflow fails at "Assert podspec versions match tag" | One or both podspecs' `s.version` ≠ the tag — the manual bump was skipped or only applied to one file. | Bump **both** `ConvertSDK.podspec` and `ConvertSDKCore.podspec` to match, merge to `main`, delete the tag, re-tag the new commit. |
| Workflow fails at "Dry-run gate A/B" | The tagged commit doesn't build, or a consumer can't `import ConvertSDK`. | Reproduce locally with `swift build` and the gate-B smoke (see [Dry Run](#previewing-a-release-dry-run)); fix on `main`, re-tag. |
| GitHub Release created but CocoaPods push **skipped** | `COCOAPODS_TRUNK_TOKEN` is not set on the repo. | Expected if CocoaPods isn't configured. To enable, complete [One-Time Setup](#one-time-setup-repo-admin). The SPM release is already live. |
| `pod trunk push` fails with an authentication error | Trunk session token expired, invalid, or the secret is stale. | Re-register (`pod trunk register …`), re-extract from `~/.netrc`, update the `COCOAPODS_TRUNK_TOKEN` secret. The GitHub/SPM release is unaffected — re-run only the release job, or push the pods manually. |
| `pod trunk push ConvertSDK.podspec` fails to resolve `ConvertSDKCore` | `ConvertSDKCore` wasn't pushed first, or it was pushed seconds earlier and Trunk's CDN hasn't propagated it yet. | Push `ConvertSDKCore` first, and use `--synchronous` on the `ConvertSDK` push (validates against the master Specs repo, not the lagged CDN). The workflow already does both. |
| `pod lib lint ConvertSDK.podspec` fails locally on a missing `ConvertSDKCore` | You linted the umbrella pod before core is on Trunk. | Add `--include-podspecs='ConvertSDKCore.podspec'` so the local core podspec resolves the dependency. |
| New version not installable via `pod install` yet | CocoaPods CDN sync lag after the trunk push. | Wait a few minutes, then `pod repo update`. Confirm with `pod trunk info ConvertSDK`. |
