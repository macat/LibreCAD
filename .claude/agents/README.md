# Agents — LibreCAD macOS port

Swift + C++ DXF bridge. SwiftPM at `macos/engine/`.

## Team

| Agent | Role |
|---|---|
| **coordinator** | Main session. Owns git/worktree/merge, dispatches specialists. Not dispatchable — it's you. |
| **planner** | Read-only. Produces phased plan with owned files + deps. |
| **critic** | Gating review of a plan. Verdict: APPROVE / REVISE / REJECT. |
| **builder** | Writes code + tests under `macos/engine`. Builds + tests serial. |
| **code-reviewer** | Reviews diff. Verdict + classified findings. No code writes. |
| **investigator** | Read-only research. Code, git, DXF/DWG. |
| **acceptance-tester** | Real-file + .app smoke + LCShot screenshot validation. |

`standards/quality-gates.md` — shared gates for all roles.

## Flow

Multi-step: `planner` → resolve open questions → `critic` → `builder` loop → `code-reviewer` → `acceptance-tester` → done.

Focused: dispatch the one specialist directly.

Rules: ≤4 concurrent agents, disjoint files. UNWIRED tools; batch wiring. `EntityKind` = solo.

## Must-know

- Build: `swift build --package-path macos/engine --disable-sandbox`
- Test: `swift test --package-path macos/engine --disable-sandbox --no-parallel`  (always serial)
- Worktree: branch off `master` → `git reset --hard native-macos`; never touch `native-macos`/`master`; never `cd` to main checkout
- `CADEngine` must not import `LibreCADmacOS`
- Views: decompose `body`; modals only in View layer
- Done = on `native-macos` + suite green + `.app` rebuilt (if user-facing)
