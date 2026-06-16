# Quality Gates — LibreCAD macOS port

Shared bar for every agent. Reference this from any role.

## Before committing (builder) — the change must

1. **Build clean:** `swift build --package-path macos/engine --disable-sandbox`.
2. **Pass the full suite, serially:** `swift test --package-path macos/engine --disable-sandbox
   --no-parallel` — all green; note the exact count. (Serial is mandatory: the parallel runner
   intermittently deadlocks on a Core Text static-init lock-inversion. On a 0%-CPU hang >60s:
   `pkill -9 -f LibreCADmacOSPackageTests` + re-run.)
3. **Carry tests:** new logic → unit tests; bug fix → a regression test. Assertions must be
   meaningful (test behavior, not tautologies). Pure logic is tested without a GUI/GPU; app-module
   types are reached from tests via the `_Shared*.swift` symlink convention.
4. **Stay in your lane:** `git diff --name-only native-macos...HEAD` shows ONLY your brief's owned files.

## Code-correctness bar

- Exhaustive switches get *correct* arms, not stubs (especially when an `EntityKind`/`ToolKind` case
  is added — every switch needs a sensible, not just compiling, arm).
- `CADEngine` never imports the app module (`LibreCADmacOS`).
- C-ABI bridge (`lcdxf.cpp`): no dangling pointers (intern via the `std::deque`), null-checks, no
  overruns, graceful on malformed input.
- SwiftUI view bodies decomposed into small `@ViewBuilder`/`private var` subviews (type-check).
- No `NSOpenPanel`/modal reachable from non-View code or tests (headless-hang trap).
- Renderer changes don't regress existing line/fill drawing and respect the f32 floating-origin scheme.
- Match project conventions: value types, namespaced enums of `static` members (no module-scope free
  functions), file-header comment + GPLv2-or-later notice.

## Before merge (coordinator)

- Diff reviewed (code-reviewer) for any non-trivial change; must-fixes applied.
- `git status` clean (no stray untracked files) before merging.
- Merge by hash with the branch-assert guard, `--no-ff`.
- After the wave: build + `--no-parallel` test confirm the expected count BEFORE pruning worktrees.

## Before "done" (coordinator)

- Committed on `native-macos`, full suite green.
- User-facing change → acceptance-tester GO (real DXF/DWG round-trip + `.app` smoke) + the `.app`
  rebuilt for the user to verify the GUI.
- decision-log.md updated.

## Verify-before-report

No "done/fixed/green" without a command that proves it. Confirm merges with `git log`/`git status`,
counts with the `--no-parallel` test line. Don't relay a subagent's claim unchecked.
