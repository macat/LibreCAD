# CI & Release — Native macOS port

How the macOS port is built/tested in CI, and how to produce a signed +
notarized `.app` for distribution.

This doc covers ONLY the `macos/` SwiftPM project. The upstream C++/Qt LibreCAD
has its own workflows (`.github/workflows/build-all.yml`, `run_pixi.yml`); the
macOS-port CI is intentionally scoped away from them.

---

## 1. Continuous integration

Workflow: `.github/workflows/macos-ci.yml`.

**Triggers.** Push / PR that touches `macos/**` or the workflow itself, plus
manual `workflow_dispatch`. Path-scoped so unrelated Qt/C++ changes don't spin
up the macOS runner.

**Runner.** `macos-latest` (GitHub-hosted), which provides the Swift toolchain.
The project pins **Swift 6.2 / macOS 26 SDK** in `macos/engine/Package.swift`.

**Jobs.**

| Job | What it does |
|-----|--------------|
| `build-and-test` | Matrix over `[debug, release]`. Runs `swift build` then `swift test` on `macos/engine` for each config. A test failure fails the job. |
| `assemble-app`   | Runs only after `build-and-test` is green (`needs:`). Runs `CONFIG=release bash macos/scripts/make-app.sh` to assemble `LibreCADmacOS.app` (default **ad-hoc** signing — no Developer ID in CI), then uploads it as an artifact. |

**Caching.** SwiftPM build products (`macos/engine/.build`) and the SwiftPM
cache (`~/Library/Caches/org.swift.swiftpm`) are cached per config, keyed on the
`Package.swift` hash (so a manifest change busts the cache).

**Commands (identical to local dev).**

```sh
swift build --package-path macos/engine --disable-sandbox -c debug
swift test  --package-path macos/engine --disable-sandbox -c debug
swift build --package-path macos/engine --disable-sandbox -c release
swift test  --package-path macos/engine --disable-sandbox -c release
CONFIG=release bash macos/scripts/make-app.sh
```

> CI does NOT sign with a Developer ID and does NOT notarize. GitHub-hosted
> runners have no access to the project's Apple Developer credentials, and the
> notary service requires them (see the constraint below). CI's job is to prove
> the project builds, tests pass, and the bundle assembles.

---

## 2. Signing & notarization

Two scripts are involved:

- `macos/scripts/make-app.sh` — assembles the `.app` and **ad-hoc** signs it.
  This is the default, credential-free path used by CI and by everyday local
  builds. **Unchanged behavior:** without any extra env vars it behaves exactly
  as before.
- `macos/scripts/sign-and-notarize.sh` — the release/distribution path:
  Developer ID signing (hardened runtime + entitlements) → notarize → staple.
  It **gracefully no-ops** (warns + ad-hoc signs, exit 0) when credentials are
  absent, so running it without an Apple Developer account never fails.

Hardened-runtime entitlements live in
`macos/App/LibreCADmacOS.entitlements` (applied only by the Developer ID path).

### 2.1 Required credentials

A signed + notarized build needs an **Apple Developer ID** (paid Apple
Developer Program membership). Provide these via env vars:

| Env var | Meaning | Example |
|---------|---------|---------|
| `SIGN_IDENTITY`    | Developer ID Application codesign identity (must be in the login keychain). | `Developer ID Application: Jane Dev (ABCDE12345)` |
| `TEAM_ID`          | Apple Developer Team ID. | `ABCDE12345` |
| `KEYCHAIN_PROFILE` | Name of a stored `notarytool` credential profile. | `librecad-notary` |

Optional:

| Env var | Effect |
|---------|--------|
| `ENTITLEMENTS`  | Override the entitlements plist path (default `macos/App/LibreCADmacOS.entitlements`). |
| `SKIP_NOTARIZE` | `1` = Developer ID sign + hardened runtime, but skip notarize/staple (quick local Developer ID test). |

**One-time: create the notary credential profile.** Generate an
app-specific password at <https://appleid.apple.com>, then:

```sh
xcrun notarytool store-credentials "librecad-notary" \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345" \
  --password "abcd-efgh-ijkl-mnop"   # app-specific password
```

This stores the credential in the keychain under the profile name you then pass
as `KEYCHAIN_PROFILE`.

### 2.2 Produce a signed + notarized build locally

```sh
# 1. Assemble the .app (release).
CONFIG=release bash macos/scripts/make-app.sh

# 2. Sign with Developer ID + hardened runtime, notarize, and staple.
export SIGN_IDENTITY="Developer ID Application: Jane Dev (ABCDE12345)"
export TEAM_ID="ABCDE12345"
export KEYCHAIN_PROFILE="librecad-notary"
bash macos/scripts/sign-and-notarize.sh
```

Or do it in one shot via the env-gated hook in `make-app.sh`:

```sh
export SIGN_IDENTITY="Developer ID Application: Jane Dev (ABCDE12345)"
export TEAM_ID="ABCDE12345"
export KEYCHAIN_PROFILE="librecad-notary"
SIGN_RELEASE=1 CONFIG=release bash macos/scripts/make-app.sh
```

`SIGN_RELEASE=1` makes `make-app.sh` call `sign-and-notarize.sh` after its
normal ad-hoc step. Leaving `SIGN_RELEASE` unset (the default) keeps the
original behavior — ad-hoc only.

### 2.3 Behavior without credentials

| Situation | What happens |
|-----------|--------------|
| `SIGN_IDENTITY` unset | `sign-and-notarize.sh` warns, ad-hoc signs the bundle, exits 0. (Same as `make-app.sh`.) |
| `SIGN_IDENTITY` set, `KEYCHAIN_PROFILE` unset | Developer ID signs + hardened runtime, warns that it cannot notarize, exits 0. |
| `SKIP_NOTARIZE=1` | Developer ID signs + hardened runtime, skips notarize/staple, exits 0. |
| All set | Developer ID signs → notarizes (waits for Apple) → staples → validates. |

This is why CI stays green: with no credentials, the worst case is an ad-hoc
signed bundle, never a failure.

---

## 3. Known constraint — notarization needs an Apple Developer ID

Apple's notary service and Developer ID signing require a **paid Apple Developer
Program account**. There is no offline / credential-free way to notarize.
Consequently:

- GitHub-hosted CI cannot notarize (no credentials on the runner) — it ad-hoc
  signs only. A notarized build is produced **locally** (or on a self-hosted
  runner with the credentials provisioned) by a maintainer who holds the
  Developer ID.
- Ad-hoc signed builds run on the building machine but Gatekeeper will warn /
  block them on other Macs. Distribution to other users requires the notarized
  path above.
- To wire notarization into CI later: provision `SIGN_IDENTITY`, `TEAM_ID`, and
  the `KEYCHAIN_PROFILE` (imported certificate + stored notary credential) as
  encrypted GitHub secrets on a runner that can hold a keychain, then add a
  signing step that calls `sign-and-notarize.sh`. The scaffolding (script +
  entitlements + env contract) is already in place; only the secrets are
  missing.
