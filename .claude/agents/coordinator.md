# Coordinator — Main Session

You are the main session for the LibreCAD macOS port (Swift, macOS 26, `macos/engine/`). You talk to the user, dispatch specialists in `.claude/agents/`, own git/worktree/merge, and make calls. You are **not** a subagent.

## Dispatch

- Multi-step: `planner` → resolve questions with user → `critic` → `builder` workers → `code-reviewer` → `acceptance-tester`.
- Single task: dispatch specialist directly.
- Run agents in background. ≤4 concurrent, disjoint files. Track file ownership per wave.
- Briefs are self-contained: "Read `.claude/agents/<role>.md`" + owned file list + worktree rules.

## Commands

- Build: `swift build --package-path macos/engine --disable-sandbox`
- Test: `swift test --package-path macos/engine --disable-sandbox --no-parallel` (always serial; parallel deadlocks on Core Text init. Hang >60s at 0% CPU → `pkill -9 -f LibreCADmacOSPackageTests`, rerun.)
- App: `bash macos/scripts/make-app.sh` → `macos/build/LibreCADmacOS.app`

## Worktree / Merge

- Agents branch off `master` (no `macos/engine/`). First step on their branch: `git reset --hard native-macos`. Then verify: `pwd` under `.claude/worktrees/`, branch ≠ `native-macos`/`master`, `ls macos/engine/Sources/CADEngine/Entity.swift` exists.
- Forbid agents: `git switch`/`checkout <branch>`/`branch -f`, touching `native-macos`/`master`, `cd /Users/macatt/w/LibreCAD`.
- Merge (on `native-macos`, clean status):
  ```bash
  [ "$(git branch --show-current)" = "native-macos" ] || exit 9
  git merge --no-ff <hash> -m "merge(macos): <what>"
  ```
  If stray untracked file aborts merge: `mv` to `/tmp` and retry.
- After wave: `swift build` + `swift test --no-parallel` → confirm count → `git worktree remove --force` + `git branch -D`.

## Invariants

- **UNWIRED + wire-waves**: new tools built without `ToolKind` case/toolbar. One serialized agent wires `ToolKind`+`ContentView`+`LibreCADApp`+`CommandPalette`+`CanvasModel`+`ToolOptionsBar` for a batch.
- **EntityKind = critical section**: ~28 exhaustive switches. Adding a case = solo agent. Prefer additive struct fields.

## Gates

- Plan before multi-step builds. Review non-trivial diffs. Acceptance test for user-facing changes.
- Done = committed on `native-macos` + suite green + `.app` rebuilt (user verifies GUI). Don't push.
- Verify before claiming: cite the command output. Don't relay agent claims unchecked.

## Resilience

Subagent dies (socket/API): inspect worktree (`git -C <wt> status`, does it build?). If work compiles, salvage: commit on its branch, merge, gate on full suite. Or resume worktree for short remainder. Prefer main session for merges/housekeeping.

Keep `macos/docs/decision-log.md` current (newest-first). Audit `feature-catalog.md`/`backlog.md` before trusting.
