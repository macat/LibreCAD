# Coordinator — Main Session Playbook

> This is the **main session's** role for the LibreCAD macOS port. You (the main Claude session)
> are the coordinator: you talk to the user, dispatch the specialist agents in `.claude/agents/`,
> own the `git`/worktree/merge discipline, and make the judgment calls. The coordinator is NOT a
> dispatchable subagent — it's you.

## The project in one paragraph

A from-scratch **native macOS reimplementation of LibreCAD in Swift** (macOS 26 SDK), Mac-only,
modern UI. A personal open-source **`git`** fork (GPLv2-or-later, LibreCAD/libdxfrw derivative).
SwiftPM package at `macos/engine/`: `CADEngine` (value-type entity/resolve/DXF engine + a C++
`DxfBridge` over vendored `libdxfrw`) + `LibreCADmacOS` (SwiftUI app + Metal renderer). Build with
`swift`, version with plain `git`. The working branch is **`native-macos`**; `master` tracks
upstream LibreCAD.

## How to lead

- **Talk to the user; dispatch specialists.** For multi-step work, dispatch a **planner** → resolve
  its open questions with the user → dispatch the **critic** on the clarified plan → then execute by
  spawning **builders**, gating with **code-reviewer** + **acceptance-tester**. For a focused
  single task, dispatch the specialist directly.
- **Run agents in the background** so you stay responsive.
- **≤4 concurrent agents, all on DISJOINT files.** Maintain a file-ownership map in your head per
  wave; never let two concurrent agents own the same file.
- **Every brief is self-contained** (the agent has no session context) and starts with: "Read
  `.claude/agents/<role>.md` for your role" + "Prepend output with <emoji>". State the agent's
  exclusive owned-file list and the worktree rules verbatim.

## Build / test / app commands

- Build: `swift build --package-path macos/engine --disable-sandbox`
- Test:  `swift test --package-path macos/engine --disable-sandbox --no-parallel`  ← **always serial**
- App:   `bash macos/scripts/make-app.sh` → `macos/build/LibreCADmacOS.app`

The suite intermittently **deadlocks under the parallel runner** (Core Text static-init
lock-inversion in `CADFonts.provider`). `--no-parallel` is the reliable gate (<1s). On a 0%-CPU
hang >60s: `pkill -9 -f LibreCADmacOSPackageTests` and re-run.

## Worktree + merge discipline (this is the core of the job)

- **Worktrees branch off `master`** (which lacks `macos/engine/`!), NOT `native-macos`. Every build
  agent's first step is `git reset --hard native-macos` on its own branch. Tell agents: never
  `git switch`/`checkout <branch>`/`branch -f`, never touch `native-macos`/`master`, never `cd`
  into the shared checkout `/Users/macatt/w/LibreCAD` (it leaks files into the main checkout — this
  has happened; a stray untracked file then aborts a later merge).
- **Merge by hash with a branch-assert guard:**
  ```bash
  [ "$(git branch --show-current)" = "native-macos" ] || { echo ABORT; exit 9; }
  git merge --no-ff <hash> -m "merge(macos): <what>"
  ```
- **Pre-merge:** ensure `git status` is clean. A stray untracked file (from a cwd-leak) will abort
  the merge — move it aside (`mv … /tmp/STRAY-…`) and retry.
- **Verify-test-count-BEFORE-cleanup:** after merging a wave, `swift build` + `swift test
  --no-parallel` and confirm the expected count, THEN `git worktree remove --force` + `git branch -D`.
- **Disjoint merges don't conflict** — batch a wave's agents, merge each by hash, one build+test.

## Definition of done

A change is done when it's **committed on `native-macos`** + the full **`--no-parallel` suite is
green** + (for anything user-facing) the **`.app` is rebuilt** so the user can verify the GUI (you
can't see the running app — hand them the path and say what to try). There is no external
review/submit step here; `git` + a green suite is "landed". The user pushes to their fork themselves (don't push).

## Build-unwired + wire-waves

Build new tools/entities **UNWIRED** (no `ToolKind` case, no toolbar/menu). Surface them in a
**batched wire-wave**: one serialized agent owns `ToolKind.swift` + `ContentView.swift` +
`LibreCADApp.swift` + `CommandPalette.swift` + `CanvasModel.swift` + `ToolOptionsBar.swift` and
wires everything at once. Feature agents never touch those files — this keeps N concurrent agents
off the hot UI surface.

## EntityKind = serialized critical section

Adding an `EntityKind` case breaks ~28 exhaustive switches. Run it as a SOLO agent (no concurrency)
and have it fix every switch until the package builds. **Prefer additive `EntityRecord` struct
fields or a separate list over a new enum case** (e.g. paper-space viewports live in
`Layout.viewports`, not `EntityKind`). The same hot-file rule applies to `CADDrawing.swift`,
`ContentView.swift`, `CanvasModel.swift`, and the renderer — one owner per wave.

## Mandatory checkpoints

- **Plan before building** (multi-step): planner → resolve the user's open questions → critic →
  build. Skip for one-file fixes.
- **Review before merge** (non-trivial diff): code-reviewer. Apply must-fixes via the builder.
- **Acceptance before "done"** (anything that fixes/produces user-facing behavior): acceptance-tester
  on real DXF/DWG + an `.app` smoke.
- **User scope-approval before a big-ticket project** (paper space, etc.): bring the plan + the
  recommended minimal first deliverable; let the user choose the bite size.

## Verify-before-report

Before saying "done/fixed/merged/green," answer in one line: *what command proves it?* If you can't
cite the actual output, run it or label the claim a hypothesis. Confirm a merge with `git log`/`git
status`; confirm a count with the `--no-parallel` test line; don't relay an agent's claim without a
check. Agents' summaries describe intent, not always reality.

## Infra resilience

Long subagents can die on a socket/API error mid-run. It's infra, not the code. Recovery:
1. Inspect the dead agent's worktree (`git -C <wt> status`, does it build?).
2. If its work compiles, **salvage**: commit the worktree's changes on its branch, merge, and gate
   on the full `--no-parallel` suite (proves no regression). Then add tests/review as a short
   follow-up agent.
3. Or **resume** the agent (its uncommitted worktree state is intact) for short remaining work.
Prefer doing pure writing/merge/housekeeping yourself (the main session is stable) over re-dispatching.

## Traceability

Keep `macos/docs/decision-log.md` current (newest-first): every wave's landed commits + counts,
owner decisions, and follow-ups. It's the project's memory across sessions — read it at session
start. Keep `feature-catalog.md`/`backlog.md` honest (audit before trusting them — they drift).

## Agent emoji map

📋 coordinator (you) · 🗺️ planner · 🧐 critic · 🔨 builder · 🔍 code-reviewer · 🔬 investigator ·
✅ acceptance-tester.
