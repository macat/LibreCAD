# LibreCAD — native macOS port

A from-scratch **reimplementation of LibreCAD in Swift** for macOS (macOS 26 SDK), Mac-only, with a
modernized UI. Personal open-source **`git`** fork (GPLv2-or-later; LibreCAD/libdxfrw derivative).
This is a normal `git` + `swift` project — there is no external code-review/submit tooling.

## Start here

You (the main session) act as the **coordinator**. Read **`.claude/agents/coordinator.md`** for how
to lead, dispatch specialists, and run the `git`/worktree/merge discipline. The specialist agents
live in `.claude/agents/` (auto-discovered) — see `.claude/agents/README.md` for the team and
`.claude/agents/standards/quality-gates.md` for the bar.

At session start, also skim **`macos/docs/decision-log.md`** (newest-first) — it's the project's
running memory of decisions, what landed, and open follow-ups.

## Layout

- **`macos/engine/`** — SwiftPM package: `CADEngine` (value-type entity/resolve/DXF engine + the
  C++ `DxfBridge` over vendored `libdxfrw`) + `LibreCADmacOS` (SwiftUI app + Metal renderer) +
  tests in `Tests/CADEngineTests`.
- **`macos/scripts/make-app.sh`** — assembles `macos/build/LibreCADmacOS.app`.
- **`macos/docs/`** — `decision-log.md`, `feature-catalog.md`, `backlog.md`, plans, ADRs.

## Commands

- Build: `swift build --package-path macos/engine --disable-sandbox`
- Test:  `swift test --package-path macos/engine --disable-sandbox --no-parallel`
- App:   `bash macos/scripts/make-app.sh`

## Critical conventions (the ones that bite)

- **Always test serially** (`--no-parallel`): the parallel runner intermittently deadlocks on a
  Core Text static-init lock-inversion. On a 0%-CPU hang >60s: `pkill -9 -f LibreCADmacOSPackageTests`.
- **Worktrees branch off `master`** (which has no `macos/engine/`). An agent's first step is
  `git reset --hard native-macos`. Never `git switch`/`branch -f`; never touch `native-macos`/`master`;
  never `cd` into the shared main checkout from a worktree.
- **Working branch is `native-macos`**; `master` tracks upstream LibreCAD. Sync:
  `git fetch upstream master && git rebase upstream/master native-macos` (our work is all under
  `macos/`, disjoint from upstream's `src/`).
- **`CADEngine` must not depend on the app module** (`LibreCADmacOS`).
- **`EntityKind` is switched exhaustively in ~28 files** — adding a case is a serialized critical
  section; prefer additive struct fields or separate lists. New tools are built **UNWIRED** and
  surfaced in batched **wire-waves**.
- **SwiftUI:** decompose large view bodies (type-check); keep `NSOpenPanel`/modals in the View layer
  only (a modal reached from a test hangs the headless suite forever).
- **Done** = committed on `native-macos` + serial suite green + (user-facing) `.app` rebuilt for the
  user to verify the GUI. Don't `git push` — the user pushes to their fork.
