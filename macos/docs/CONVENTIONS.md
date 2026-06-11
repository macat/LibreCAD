# Project Conventions — LibreCAD Native macOS

Standing rules for **every** agent and every change on this project. Briefs reference this file.
Source: user directives (2026-06-11).

## Workflow rules (non-negotiable)
1. **Parallelize aggressively.** Independent work runs concurrently with as many agents as the
   dependency graph allows. Only serialize where there's a real dependency.
2. **Git worktrees for all write-agents.** Every agent that creates/edits code works in its own
   git worktree (harness `isolation: "worktree"`), never directly in the user's checkout.
   Non-overlapping file ownership per agent so parallel work doesn't collide.
3. **Review every change.** No code reaches the branch without a code-review pass
   (correctness + conventions + performance). Reviewer is separate from the builder.
4. **Test & validate before committing.** A change is only committable when it *builds green*
   (`xcodebuild` / `swift build`), its **tests pass** (`swift test`), and — where it's user-facing —
   it has been *run* and observed to work. No "should build" commits.
5. **Commit incrementally** to the `native-macos` branch after each green, reviewed unit of work,
   and push. Small, frequent, tested commits.
6. **Docs live in the repo** under `macos/docs/` (architecture, plans, dev log, decisions) and are
   committed alongside the code they describe.
7. **Performance is first-class.** Metal canvas must stay smooth at scale (target: fluid pan/zoom
   on drawings with 100k+ entities). Profile hot paths with a dedicated performance agent; treat
   frame-time regressions as bugs. Prefer batching, culling, and level-of-detail over brute force.

## Engineering standards
- **Swift 6.2**, strict concurrency; **macOS 26 SDK**; **Mac-only** (no cross-platform abstractions).
- Latest APIs: SwiftUI `DocumentGroup`/`ReferenceFileDocument`, Observation (`@Observable`),
  MetalKit. Avoid deprecated AppKit patterns unless required for a capability SwiftUI lacks.
- Engine is **pure Swift** and unit-testable without the app or GPU. C++ only at the libdxfrw seam.
- Clear module boundaries; no circular deps. (Concrete target layout: see `scaffold-plan.md` once finalized.)
- License: LibreCAD/libdxfrw are **GPLv2-or-later**; this fork inherits GPL. Keep headers/attribution.

## GUI verification (learned the hard way)
- **"Binary stays alive headlessly" ≠ "the GUI works."** This sandbox can't reach the window server
  (`open` → LSError -54; a SwiftUI scene/Metal never initializes when run as a bare process), so a
  GUI app can pass every build/test/headless-launch check and still crash instantly on a real
  `open`. **A GUI deliverable is only "verified" when an actual windowed launch is confirmed** — by
  the USER or a non-sandboxed runner. Never report a GUI app as "working" on headless evidence alone;
  state explicitly what was NOT verified and ask the user to launch it. (2026-06-11: shipped a
  "working viewer" that crashed on launch — `MainActor.assumeIsolated` in `CADDocument.init` called
  off-main by `NSDocumentController`. Crash report: `~/Library/Logs/DiagnosticReports/`.)
- **Never `MainActor.assumeIsolated` in a code path the OS/framework may invoke off-main** (NSDocument
  init/snapshot/fileWrapper, delegate callbacks). It traps (SIGTRAP) instead of corrupting — loud, but
  a hard crash. Make such entry points genuinely off-main-safe (Sendable data) and hop to the actor explicitly.

## Parallel fan-out hazards (learned)
- **Namespace test-suite type names by domain.** Parallel builders add test files to the SAME test
  target, so two `struct EllipseTests` (one in intersection tests, one in entity tests) = "invalid
  redeclaration" only visible when both merge. Name suites by domain: `EllipseEntityTests`,
  `EllipseIntersectionTests`, etc. Source-level reviews can't see this — it's a test-target namespace
  clash. (Caught + fixed at Phase 1 A/B integration, 2026-06-11.) Put this rule in every fan-out brief.
- Source symbols: same hazard at module scope — keep new helpers as `static` members of a namespaced
  type (enum/struct), never module-scope free functions, so parallel modules don't redeclare.

## Integration protocol (coordinator-owned)
- Coordinator (main session) owns merging worktree outputs onto `native-macos`, running the full
  build+test, and committing. Builders return their changes; they do not push to the branch directly.
- After integration: full build + test must be green before the commit lands.
