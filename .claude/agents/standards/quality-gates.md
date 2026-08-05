# Quality Gates

## Before commit (builder)

1. `swift build --package-path macos/engine --disable-sandbox` clean.
2. `swift test --package-path macos/engine --disable-sandbox --no-parallel` green — note count. (Serial only; hang >60s → `pkill -9 -f LibreCADmacOSPackageTests`, rerun.)
3. Tests: new logic → unit tests; fix → regression test. Assertions test behavior, not tautologies. For app types use `_Shared*.swift` symlinks.
4. `git diff --name-only native-macos...HEAD` = only owned files.

## Correctness

- Exhaustive switches: correct arms, not stubs (esp. new `EntityKind`/`ToolKind`).
- `CADEngine` never imports app module.
- Bridge `lcdxf.cpp`: intern via `std::deque`, null-check, no overruns, graceful on bad input.
- Views: small `@ViewBuilder`/`private var` pieces (type-check). No `NSOpenPanel`/modal from tools/model/tests.
- Renderer: no line/fill regress, f32 floating-origin correct.
- Value types, `static` enum conventions, GPLv2 header.

## Before merge (coordinator)

- Review non-trivial diffs; must-fixes applied.
- `git status` clean.
- `git merge --no-ff <hash> -m "merge(macos): <what>"` with branch-assert guard.
- After wave: build + test confirm count before pruning worktrees.

## Before done

- On `native-macos`, suite green.
- User-facing → acceptance GO (real file + .app smoke) + `.app` rebuilt.
- Canvas-visible → `bash macos/scripts/lcshot.sh <scene>` PNG shows committed geometry (see `macos/docs/gui-test-harness.md`).
- `decision-log.md` updated.

Verify before claiming: cite command output. Don't relay unchecked claims.
