# Agent suite — LibreCAD macOS port

A small team of specialist agents for building the **native macOS reimplementation of LibreCAD**
(Swift + a C++ DXF bridge, plain `git`, SwiftPM at `macos/engine/`). Claude Code auto-discovers the
specialists in this directory as dispatchable subagents.

## The team

| Agent | Emoji | Role |
|---|---|---|
| **coordinator** (`coordinator.md`) | 📋 | The main session. Talks to the user, dispatches specialists, owns `git`/worktree/merge discipline. *(A playbook, not a dispatchable subagent — it's you.)* |
| **planner** | 🗺️ | Analyzes a problem → a phased, file-grounded execution plan (disjoint owned files, serialize-flags). Read-only. |
| **critic** | 🧐 | Pressure-tests a plan before building — scope, methodology, file-ownership collisions, project traps. Gating verdict. |
| **builder** | 🔨 | Writes Swift/C++ code + tests under `macos/engine`. Builds + runs the serial suite. Reports an evidence bundle. |
| **code-reviewer** | 🔍 | Reviews a diff before merge (correctness, C-ABI safety, SwiftUI/render, tests). Verdict; never writes code. |
| **investigator** | 🔬 | Read-only research: where/how X works, true status of Y, design passes, root-causing. |
| **acceptance-tester** | ✅ | Validates a finished change on REAL DXF/DWG + an `.app` smoke before "done". |

`standards/quality-gates.md` — the shared bar all roles reference.

## How the team works

1. Multi-step work: **planner** → coordinator resolves the user's open questions → **critic** →
   build loop (**builder** → **code-reviewer** → fix) → **acceptance-tester** → done.
2. Focused work: dispatch the one specialist directly.
3. **≤4 concurrent agents, disjoint files.** Build new tools/entities UNWIRED; batch UI wiring into
   a wire-wave. `EntityKind` additions run solo (they break ~28 exhaustive switches).
4. The coordinator merges by hash into `native-macos` with a branch-assert guard, gates on the
   serial test suite, then prunes worktrees. "Done" = on `native-macos`, suite green, `.app` rebuilt.

## Non-negotiable project facts (every agent must know)

- **Build:** `swift build --package-path macos/engine --disable-sandbox`
- **Test:** `swift test --package-path macos/engine --disable-sandbox --no-parallel` (ALWAYS serial
  — the parallel runner deadlocks).
- **GUI screenshot (headless):** `bash macos/scripts/lcshot.sh <scene>` renders a JSON-scripted
  `CanvasModel` to `macos/build/harness-shots/<scene>.png` — open it to *visually verify how a feature
  behaves* without launching the app. Authorable verbs + the coverage ceiling (committed geometry
  only; no overlays/chrome) are in `macos/docs/gui-test-harness.md`. Use it to self-check visual
  changes (builder) and to prove behavior end-to-end (acceptance-tester).
- **Worktrees branch off `master`** (no `macos/engine/`!) → first step `git reset --hard native-macos`;
  never touch `native-macos`/`master`; never `cd` to the shared checkout.
- **`CADEngine` ⊥ app module** (no app-type references from the engine).
- **SwiftUI** view bodies must be decomposed; **modals** stay in the View layer only.
- Plain `git` only — no external review/submit tooling. The user pushes to their own fork.
