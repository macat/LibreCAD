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

## Integration protocol (coordinator-owned)
- Coordinator (main session) owns merging worktree outputs onto `native-macos`, running the full
  build+test, and committing. Builders return their changes; they do not push to the branch directly.
- After integration: full build + test must be green before the commit lands.
