# Decision Log — autonomous decision points (for owner traceability)

This log records judgment calls made while the owner (macatt) is away, so they can be
traced/reversed later. Each entry: date, decision, the options considered, why, and how to revisit.
Newest first. (Reversible code lives behind small diffs on `native-macos`; cite the commit/wave.)

---

## 2026-06-12 — v4 EXECUTION PROGRESS (autonomous; owner away)

Merged so far (native-macos @ 55f9f7b65, **1113 tests, 246 commits**): DocumentGroup (passed launch gate) · U1 coordinate/command input line · spline-DXF-write + layer-visibility fixes (data-loss closed) · Stretch/Lengthen/Break tools · Document Settings sheet · U2 tool-options bar · U3 status bar + crosshair · **INSERT block-reference entity (keystone)**.

Minor execution calls (best-guess, reversible):
- **U2**: kept the Inspector's tool-config section AND added the options bar (both bind the same `CanvasModel` state → stay in sync; lower risk than removing one).
- **PointTool** marker-style param is surfaced in the options bar but full render-honoring is gated on a future `PointData.style` field — logged follow-up.
- **U3** replaced the transient corner HUD chips with the persistent status bar (coords/snap/zoom/step).
- **INSERT**: named blocks read into a block table + emitted in the BLOCKS section; anonymous `*`-blocks stay inline (preserves dim_sample entity counts); `InsertTool` built UNWIRED (wired in wire-wave-C). Block recursion depth-guarded at 32.
- New tools are built UNWIRED and surfaced together in periodic **wire-waves** (avoids N agents fighting over ToolKind/ContentView).

Next: **wire-wave-C** (surface Stretch/Lengthen/Break/Insert) + **snap-modes-2** (perpendicular/tangent/nearest) in parallel; then select-all/ortho, full dim styles, DWG (revisit DC.2).

---

## 2026-06-12 — v4 PLANNING DECISIONS RESOLVED (best-guess; owner away)

Planning docs landed: `feature-catalog.md` (~99 gaps, prioritized) + `ux-plan.md` (HIG audit + settings spec).

### From feature-catalog.md (owner-flagged forks)
- **DC.1 DocumentGroup** — ✅ DONE: built off-main-safe (Sendable `DXFPayload`, no `MainActor.assumeIsolated`), merged `0d0c17331`, **passed the launch gate** (bare binary alive, no new crash). Owner: please GUI-confirm Open Recent / autosave / dirty-dot when back.
- **DC.2 DWG read/write** — **DEFER.** The C bridge gained DWG (upstream `5315f0ce8`/`47972ec25`) but it's unsurfaced in Swift. High-value but NOT the stated pain (usability) and needs real-file testing. Schedule AFTER P0 usability + core-feature waves. Revisit once U1–U3 + INSERT land.
- **DC.3 Hatch patterns** — **Ship SOLID now**; a real `.pat` pattern generator is a later P2. Solid covers the common case.
- **DC.4 Dimension model scope (ordinate/arc/angular3p)** — **STAGE.** Add a `DimKind` case only when a tool/feature needs it; don't churn the cross-cutting enum + all switches without demand. Existing 5 cover the vast majority.

### From ux-plan.md (D1–D8) — ACCEPT the recommended defaults (HIG-aligned, reversible)
- **D1** command line: always-present field, focus on Space/click, Esc→canvas. **D2** empty-space drag = marquee select in select mode (Space/middle-drag pans). **D3** settings: live-apply + Done, one undo step per field. **D4** dim style: per-entity wins, document default fills via the resolve hook. **D5** persist snap modes via private `$LC_SNAPMODE` header var. **D6** default toolbar Select/Line/Circle/Arc/Rectangle/Move/Trim/Linear-Dim + Draw▾/Modify▾/Annotate▾, rest via menu+⌘K, customizable. **D7** extend `ToolInput` append-only with `.value(Vector)`. **D8** Document Settings = ⌥⌘, (reserve ⌘, for future app Preferences).

### v4 execution order (best-guess)
1. **U1 coordinate/command input line** (the #1 usability fix) + **P0 bug fixes** (spline DXF write = data loss; layer-visibility render filter) — parallel, disjoint files.
2. **Document Settings sheet** + **U2 tool options bar** (after U1 frees ContentView).
3. **INSERT entity + block insert/sidebar** (keystone gap) + **U3 status bar / crosshair**.
4. Catalog long tail: select-all/ortho/relative-zero (some fold into U1), stretch/lengthen/break, dim styles; then DWG (revisit DC.2), hatch patterns (DC.3).

---

## 2026-06-12 — V4 PHASE KICKOFF (owner directive)

**Owner directive (verbatim intent):** After DocumentGroup, start the next phase:
(1) polish the UI — tools are currently difficult to use; follow modern macOS HIG;
(2) add a **document settings page**; (3) **catalog the missing features from LibreCAD and tackle the list**.
"Keep going, I won't be here for a while. If you have questions, pick your best guess and proceed,
and note decision points so I can trace them."

### D-V4.1 — Run v4 planning in parallel with DocumentGroup
- **Decision:** Kick off the two v4 planning agents (feature-catalog, UX+settings plan) NOW, in parallel
  with the in-flight DocumentGroup build. Execute v4 build waves only AFTER DocumentGroup merges + is launch-verified.
- **Why:** Planning is read-only on code + writes docs → zero conflict with DocumentGroup's code. Maximizes
  autonomous progress per "keep going." Owner said "after this is done, schedule the next phase" — scheduling now, executing after.
- **Revisit:** if DocumentGroup needs a re-plan, the v4 plans are still valid (independent surface).

### D-V4.2 — v4 sub-streams + sequencing (best guess)
- **Decision:** Three workstreams: **(A) UX polish** (HIG audit → fix tool usability: contextual options bar,
  numeric input during drawing, clearer mode/affordance feedback, toolbar/menubar organization, etc.),
  **(B) Document settings page** (units, precision, grid/snap defaults, dimension style, layer defaults…),
  **(C) Missing-feature catalog → prioritized implementation**. Order: land planning docs → tackle (A)+(B)
  first (directly address the stated pain), then (C) in priority order.
- **Why:** The owner led with usability ("tools are difficult to use") → prioritize A/B; C is the long tail.
- **Revisit:** owner can reprioritize C's list (see feature-catalog.md once written).

### D-V4.3 — Autonomy guardrails while away
- **Decision:** Proceed without check-ins; on any fork, pick the most HIG-aligned / least-risky / most-reversible
  option and log it here. Keep the merge discipline used in v3 (isolated worktree per agent, merge-by-reported-hash,
  verify test count + green build before deleting branches, ≤~4 concurrent agents). No `jf`/external publish; no
  `git push` (network blocked — owner pushes). Don't repeat the launch-path risk class without a verify gate.
- **Why:** matches owner's "best guess + proceed + trace" + the v3 process that worked.

### D-V4.4 — Decision-log location
- **Decision:** This file, `macos/docs/decision-log.md`. Also cross-referenced from DEVLOG.md.
- **Why:** discoverable next to the other living docs.
