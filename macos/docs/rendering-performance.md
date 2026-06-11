# Metal Rendering Architecture for the LibreCAD 2D Canvas

Target: fluid pan/zoom at **120 Hz ProMotion** on Apple Silicon (macOS 26, Swift
6.2), drawings of **100k–1M primitives**, crisp anti-aliased vectors at any zoom,
accurate CPU hit-testing/snapping. This is the rendering counterpart to
`engine-architecture.md` (which establishes world-coordinate geometry, a headless
viewport transform, and three-layer compositing).

> **Research note.** Live web retrieval was largely unavailable in the authoring
> session (WebSearch/WebFetch gated; the external-search MCP returned results
> only intermittently). The recommendations below are built on the *stable,
> widely-cited* canonical references for each technique (these are not
> fast-moving areas — instanced line expansion, SDF text, quadtree culling, and
> orthographic transform matrices have been settled best practice for years).
> Source URLs are cited inline; the two that were live-confirmed this session are
> marked ✅. Re-verify the rest opportunistically when internet mode is on.

---

## 0. TL;DR — the recommended architecture

- **Geometry lives in world coordinates in persistent GPU buffers.** Pan/zoom is a
  single `world→clip` matrix in a uniform — buffers are **not** rebuilt on
  pan/zoom. Buffers are rebuilt only when the *model* changes (and then only the
  dirty regions).
- **Lines/polylines/curves** → expanded to **instanced quads** (one instance per
  segment) with **screen-space width** computed in the vertex shader, plus
  analytic edge anti-aliasing in the fragment shader. Curves (arcs, ellipses,
  splines) are **tessellated into polylines on the CPU with zoom-bucketed LOD**,
  then fed through the same line pipeline.
- **Filled hatches / solids** → **CPU triangulation** (earcut-style) into a
  triangle buffer; solid fills and SOLID/hatch loops both use one triangle
  pipeline. Stencil even-odd is the fallback for pathological concave loops.
- **Text & dimensions** → **single-channel SDF glyph atlas** built from Core Text
  outlines; glyphs drawn as instanced textured quads, alpha from the distance
  field. Stays crisp across zoom with one atlas.
- **Scaling** → a **loose quadtree** over world bounds drives both **viewport
  culling** (only visible primitives are drawn) and **CPU hit-testing/snapping**.
  Draw calls are **batched by pen+pipeline**; one indirect/instanced draw per
  batch. A persistent CPU geometry cache (tessellated polylines + triangles) is
  kept and incrementally updated — never regenerated per frame.
- **Render loop** → `MTKView` with `enableSetNeedsDisplay = true`,
  `isPaused = true` (on-demand draw); flip to continuous only during active
  pan/zoom/drag. Triple-buffered uniforms; `pixelFormat = .bgra8Unorm_srgb`,
  geometry/color in linear, GPU does sRGB encode on write.

---

## 1. 2D vector rendering on the GPU

### 1.1 Lines & polylines — instanced screen-space quads (RECOMMENDED)

Native GPU line primitives (`MTLPrimitiveType.line`) are width-1, jaggy, and have
no joins — unusable for CAD. The settled best-practice is **CPU/GPU line
expansion**: turn each segment into a screen-space-oriented quad (2 triangles)
and run analytic AA in the fragment shader.

- Background: *"Drawing Lines is Hard"* — survey of why GL lines fail and the
  triangle-expansion family of solutions
  (https://mattdesl.svbtle.com/drawing-lines-is-hard).
- **Instanced expansion** (the implementation we adopt): one *instance* per
  segment; a unit quad's 4 vertices are positioned in the vertex shader from the
  segment's two world endpoints + the line half-width, expanded **perpendicular in
  screen space** so width is constant in pixels regardless of zoom. Reference
  with full vertex-shader math and join handling:
  https://wwwtyro.net/2019/11/18/instanced-lines.html . This avoids per-frame CPU
  vertex generation: the segment endpoints are static world data in a buffer; only
  the uniform matrix and viewport size change on zoom.

**Why instanced quads over triangle-strip ribbons:** a strip needs CPU work to
emit join geometry and degenerate triangles, and re-emits on topology change;
instancing keeps geometry static (endpoints only) and moves all width/join math to
the GPU. For 1M segments, instancing also keeps the vertex buffer tiny
(2 floats × 2 endpoints per instance vs 6 expanded verts).

**Joins & caps.** For CAD line weights (usually thin), the cheap and good-enough
default is:
- **Round caps & round joins** via a 1-instance "round" quad at each vertex (a
  small instanced disc / SDF circle), or simply by extending each segment quad and
  letting AA round it. Round joins read well and avoid miter-spike artifacts.
- **Miter joins** when sharp corners matter (polyline outlines): compute the miter
  vector from adjacent segment directions in the vertex shader; clamp miter length
  to fall back to **bevel** past a limit (standard miter-limit, ~the SVG default).
- For the common CAD case (hairline-to-few-px strokes) we ship **round join+cap**
  first; add miter/bevel as an LOD-gated upgrade for thick strokes.

**Anti-aliasing.** Do **analytic edge AA in the fragment shader**: pass the
signed distance from the quad's centerline (interpolated), and `smoothstep` the
alpha over a 1-pixel feather band at the edge. This is resolution-independent,
cheaper than MSAA, and gives crisp 1px lines at any zoom. Keep 1× MSAA (off) for
the line pipeline; reserve MSAA only if triangle-fill edges need it. (Apple's
guidance on choosing AA: prefer shader AA over MSAA when geometry is
edge-dominated — https://developer.apple.com/documentation/metal.)

**Dash patterns** (LibreCAD `LineType`, 28 patterns): carry a per-vertex
cumulative **arc-length** attribute; the fragment shader discards (or alpha-zeros)
fragments where `fract(arcLength/patternPeriod)` lands in a gap. Dash period is in
*world* units, scaled by zoom in the shader (CAD dashes scale with the drawing).

### 1.2 Curves — CPU tessellation with zoom-bucketed LOD (RECOMMENDED)

Arcs, circles, ellipses, splines: **tessellate to polylines on the CPU**, then
render via the §1.1 line pipeline. This reuses one pipeline for all stroked
geometry and keeps the GPU side trivial.

- **Sagitta/flatness criterion.** Pick segment count so the chord-to-arc deviation
  (sagitta) is ≤ ~0.25–0.5 px *at the current zoom*. LibreCAD already does this
  (`pathForParametricCurve`, sagitta-based) — port it. Classic adaptive-subdivision
  / flatness references: https://www.antigrain.com/research/adaptive_bezier/ and
  De Casteljau flatness testing in standard rasterizer literature.
- **Zoom-bucketed LOD instead of per-frame retessellation.** Don't retessellate
  every frame as the user zooms. Quantize zoom into **LOD buckets** (e.g.
  powers-of-two of pixels-per-world-unit). Cache the tessellated polyline per
  curve per bucket; regenerate only when a curve crosses a bucket boundary. Within
  a bucket the world geometry is static → buffers don't churn during a smooth
  zoom. A coarse global LOD (e.g. 8–16 buckets spanning the zoom range) is plenty.
- **Analytic/SDF arcs (considered, deferred).** You *can* render a circle/arc
  analytically from center+radius in a fragment shader (SDF of a circle), giving
  perfect curves with zero tessellation. This is attractive for circles/arcs
  specifically. **Decision: defer.** Mixing an analytic-arc pipeline with the
  tessellated-everything-else pipeline complicates batching, joins where arcs meet
  lines (polyline-with-bulge), and dash continuity. Start with uniform
  tessellation; revisit analytic arcs only if profiling shows curve tessellation
  is a bottleneck (it generally is not at sane LOD). SDF-shape background:
  https://iquilezles.org/articles/distfunctions2d/.

### 1.3 Fills & hatches — CPU triangulation (RECOMMENDED), stencil fallback

- **Solid fills, SOLID entities, hatch solid fills, hatch pattern fills:**
  triangulate boundary loops on the CPU with an **earcut-style** ear-clipping
  triangulator (handles holes via the standard bridge technique), upload triangles
  to a triangle buffer, draw with a flat-color fragment shader. Earcut is fast,
  robust enough for CAD loops, and simple: https://github.com/mapbox/earcut (the
  algorithm; port to Swift or use the C++ at the libdxfrw seam). Heavier but more
  robust alternative for self-intersecting/degenerate loops: libtess2
  (https://github.com/memononen/libtess2).
- **Stencil even-odd as a fallback.** For pathological concave/self-intersecting
  loops where ear-clipping is fragile, the classic **stencil-buffer even-odd
  fill** (render loop edges to stencil, then a full-screen/bbox quad masked by
  stencil) is robust and triangulation-free. Two passes, but correct for any
  polygon. Use it only for loops the triangulator rejects. Reference: NV_path /
  classic stencil-then-cover (https://developer.nvidia.com/gpu-accelerated-path-rendering).
- **Hatch line patterns** (non-solid): expand each hatch line into the §1.1 line
  pipeline; clip to the boundary via stencil (boundary loop in stencil, hatch
  lines drawn where stencil set). Generate hatch line set on the CPU, cached like
  curves.

**Recommendation:** earcut triangulation for the 99% case (one triangle pipeline
shared by solids/hatches/dimension arrowheads), stencil even-odd reserved as the
robustness fallback. Avoid making stencil the default — it costs a pass and serializes.

---

## 2. Scaling to 100k–1M primitives

The enemy is **per-frame CPU work** (vertex generation, full-tree walks). The plan
is: static GPU buffers + a spatial index + batched draws + on-demand redraw.

### 2.1 Persistent buffers + CPU geometry cache (don't regenerate per frame)

- Keep a **persistent CPU geometry cache**: for each entity, its tessellated
  polyline (per active LOD bucket) and/or triangles. This is the "render model"
  derived from the engine model. Build it once; **incrementally update** on edits.
- Mirror it in **persistent `MTLBuffer`s** (one large interleaved vertex/instance
  buffer per pipeline class, plus index buffers). Use a free-list allocator inside
  the buffer so edits patch sub-ranges without realloc. For 1M segments at ~16–32
  B/instance this is ~16–32 MB — fits comfortably in unified memory.
- **`MTLStorageMode`:** on Apple Silicon use `.shared` (unified memory, zero-copy,
  no blit) for buffers the CPU patches; the GPU reads the same pages. (Apple
  unified-memory guidance: https://developer.apple.com/documentation/metal/resource_fundamentals.)
- **Never** rebuild buffers on pan/zoom — that's the whole point of world-coords +
  matrix uniform.

### 2.2 Spatial index — loose quadtree (RECOMMENDED) for culling AND hit-testing

Use **one spatial index** to serve both viewport culling and CPU snapping.

- **Choice: a loose quadtree** keyed on entity world AABBs. Rationale: CAD
  drawings are 2D and often non-uniformly clustered; a quadtree is simple to build
  incrementally (insert/remove on edit), cheap to query by rectangle (the
  viewport), and "loose" variants avoid the boundary-straddling problem for
  spanning entities. An **R-tree** (bulk-loaded, e.g. RBush/STR) is the
  alternative and is excellent for mostly-static large sets and range queries
  (https://github.com/mourner/rbush, STR bulk load); pick R-tree if the drawing is
  static and huge, quadtree if it's edited interactively. **Recommendation:
  loose quadtree** for the interactive editor (cheap incremental updates win), with
  the index abstracted behind a protocol so an R-tree can be swapped in for
  read-mostly huge files.
- **Build cost:** O(n log n) once; incremental insert/remove is O(log n) per edit.

### 2.3 Viewport (frustum) culling

- Each frame (only when the view changed), query the index with the **visible
  world rect** (the inverse of the matrix applied to the viewport) → the set of
  potentially-visible entities. Only these contribute draw instances.
- At extreme zoom-out, **small-feature culling**: skip entities whose screen AABB
  is < ~1 px (LibreCAD already does min-radius/length culling). Optionally collapse
  dense clusters to a single representative at very low LOD.
- Culling turns the per-frame cost from O(total) to O(visible). With viewport
  culling, a 1M-primitive drawing typically has only **tens of thousands visible**
  at working zoom — well within a 120 Hz budget.

### 2.4 Batching & draw calls

- **Batch by (pipeline, pen state).** Group visible instances by pipeline class
  (lines / triangles / glyphs) and by pen attributes that can't be per-instanced
  (rarely any — color/width can be per-instance attributes). Goal: a handful of
  draw calls per frame, each instanced over thousands of primitives.
- **Per-instance attributes**: color (resolved ByLayer/ByBlock once, cached),
  width, dash phase, LOD — packed into the instance struct so layers/pens don't
  fragment draws. This collapses "batch by layer/pen" into ideally **one instanced
  draw per pipeline**.
- **Indirect / GPU-driven (later):** `MTLIndirectCommandBuffer` or compute-based
  culling can move culling onto the GPU for the largest files. Defer; CPU
  quadtree culling + a few instanced draws is plenty for the foundation.

### 2.5 Dirty-region updates

- On model edit, recompute only the touched entities' cache entries, patch their
  buffer sub-ranges, update their quadtree nodes, and `setNeedsDisplay`. No global
  rebuild. Block-insert edits dirty all instances of that block (see §6).

---

## 3. Text & dimensions

CAD text must stay legible from full-page zoom-out to extreme zoom-in, at any
rotation, with leaders/arrows — and there can be a lot of it (dimension strings
everywhere).

### 3.1 SDF glyph atlas (RECOMMENDED)

- **Build an SDF atlas from Core Text outlines.** Get each glyph's path via
  `CTFontCreatePathForGlyph`, rasterize its **signed distance field** into a
  single-channel atlas texture (one entry per glyph at a fixed em size). Render
  text as **instanced textured quads**, one per glyph; the fragment shader
  `smoothstep`s the distance value to alpha. One atlas serves **all zoom levels** —
  scaling the quad scales the crisp glyph. Canonical guide (✅ live-confirmed this
  session): https://www.redblobgames.com/articles/sdf-fonts/ ; implementation
  walkthrough (✅): https://chikin.net/site/other/posts/sdftextrendering/ ; origin:
  Valve's *"Improved Alpha-Tested Magnification"* (Green 2007,
  https://steamcdn-a.akamaihd.net/apps/valve/2007/SIGGRAPH2007_AlphaTestedMagnification.pdf).
- **MSDF (multi-channel SDF)** preserves sharp corners better than single-channel
  at small sizes (https://github.com/Chlumsky/msdfgen). **Decision:** start with
  single-channel SDF (simpler, one channel, good enough for CAD san-serif at
  typical sizes); upgrade to MSDF only if corner rounding on small text is
  objectionable.

### 3.2 Why not CTLine rasterization

`CTLine`/Core Graphics rasterization to a texture is crisp **at one size** but
must **re-rasterize on every zoom change** to stay sharp — exactly the per-frame
CPU work we're avoiding, and it doesn't batch (one texture per text run). SDF
amortizes glyph rasterization once and scales for free on the GPU. **Use CTLine
only** for a static, non-zooming UI overlay (e.g. fixed-size HUD labels), not for
in-drawing text.

### 3.3 Dimensions & leaders

Dimensions are *computed containers* (engine doc §2): their lines/arrows/extension
lines are derived geometry → feed through the §1.1 line + §1.3 triangle (arrowhead)
pipelines like any other stroked/filled geometry. The dimension **text** goes
through the SDF path. Because dimension geometry is derived from a small `Data`
struct + style, cache it like curves and only regenerate on edit or DimStyle
change.

---

## 4. MTKView integration, transforms & color

### 4.1 World→clip transform (matrix uniform — geometry stays in world coords)

- Maintain the headless `ViewportTransform` from the engine doc
  (`worldToScreen`/`screenToWorld`, plus the UCS stage). For the GPU, compose a
  single **`world→clip` `float4x4`** = `(NDC-from-pixels) · (pixels-from-world)`:
  an orthographic projection mapping the visible world rect to clip space
  `[-1,1]`. Pan = translation, zoom = scale within this matrix.
- **Pan/zoom changes only the uniform** — vertex buffers (world coords) are
  untouched. This is the single most important decision for fluid pan/zoom: no
  buffer rebuild, no CPU re-tessellation within an LOD bucket.
- **Y axis:** AppKit/Metal NDC is Y-up; the engine doc notes you can likely **drop
  the Qt Y-flip**. Bake the (no-)flip into the projection matrix, not the geometry.
- **Precision:** at extreme zoom on large drawings, `float32` world coords lose
  precision. Mitigate by storing world coords relative to a **per-view origin**
  (subtract a `double` camera origin on the CPU, upload `float` offsets) so the
  matrix never multiplies huge magnitudes by huge zoom. (Standard
  "floating-origin" technique.)

### 4.2 drawableSize / Retina

- Set `view.drawableSize` from `bounds.size × backingScaleFactor` (or let MTKView
  manage it and read it). Compute **screen-space line widths and AA feather in
  *device pixels*** using `drawableSize`, so 1px-logical lines are crisp on Retina.
  The pixels-from-world stage must use device pixels.

### 4.3 On-demand vs continuous draw (power)

- Default **`enableSetNeedsDisplay = true`, `isPaused = true`**: redraw only on
  `setNeedsDisplay()` (model edit, selection, view change). A static drawing draws
  **0 frames** — zero GPU/power.
- During **active pan/zoom/drag**, switch to continuous (`isPaused = false`) for
  smooth 120 Hz, then back to on-demand on gesture end. This is the documented
  power-saving pattern for MTKView
  (https://developer.apple.com/documentation/metalkit/mtkview).
- `preferredFramesPerSecond` — leave at the display max (120 on ProMotion); the
  on-demand mode means you only pay for frames you actually draw.

### 4.4 Color / sRGB correctness

- Use **`pixelFormat = .bgra8Unorm_srgb`** for the drawable. Keep colors/blending
  math in **linear** space; the GPU encodes to sRGB on write automatically. Supply
  pen colors converted to linear (or use a color space that matches). This avoids
  the classic too-dark/too-bright AA fringing from blending in non-linear space.
  (Apple color-management guidance:
  https://developer.apple.com/documentation/metal/onscreen_presentation.)

### 4.5 Swift 6 concurrency for the render loop

- The render loop touches `MTLCommandQueue`, drawables, and the shared geometry
  cache. Under Swift 6 strict concurrency, isolate renderer state on a single
  actor or the **main actor** (MTKView delegate callbacks are main-thread). Make
  the per-frame uniform/instance structs `Sendable` value types.
- **Triple-buffered dynamic data:** maintain N=3 uniform/instance ring buffers
  guarded by a `DispatchSemaphore(value: 3)` (or an `actor` gate) so the CPU can
  prepare frame N+1 while the GPU renders frame N without stalling — Apple's
  standard "in-flight frames" pattern
  (https://developer.apple.com/documentation/metal/synchronizing_cpu_and_gpu_work).
  Heavy cache rebuilds (tessellation on edit) run **off** the main actor on a
  background executor, then hand `Sendable` buffers back to the renderer.

---

## 5. Hit-testing & snapping precision (CPU, decoupled from GPU)

- **All snapping runs on the CPU against the engine model via the spatial index** —
  never read back from the GPU. The renderer and the snapper share the **same
  quadtree** but the snapper queries exact analytic geometry (the engine's
  `getNearestEndpoint`, `getNearestPointOnEntity`, `getNearestCenter`,
  intersection kernels from `RS_Information`), not tessellated approximations. This
  keeps snapping **exact** (true arc centers, true intersections) regardless of
  render LOD.
- **Flow:** mouse pixel → `screenToWorld` → query quadtree with a small world-space
  box sized from `m_catchEntityGuiRange` (GUI pixels → world) → candidate entities
  → run each enabled snap mode's exact geometry query → pick closest within range →
  update the snap-indicator **overlay** (separate layer, §0/engine doc
  three-layer compositing). Endpoint/center/middle are exact from `Data`;
  intersections use the conic/polynomial kernels.
- **Decoupling:** snapping has its own cheap path and does **not** trigger a full
  redraw — only the overlay layer repaints. This keeps the cursor responsive even
  on huge drawings.

---

## 6. Block inserts (RS_Insert)

- A block reference = a sub-tree drawn with an extra local transform (insertion
  point, scale, rotation, array cols×rows). Two strategies:
  - **Flatten (foundation):** expand each insert's resolved geometry into the
    instance buffers at build time with the composed transform baked in. Simple,
    fast to draw; costs buffer space for repeated blocks. Fine to start.
  - **GPU instancing of block geometry (later):** upload the block's geometry once
    and draw it per-insert with a per-instance transform matrix (true GPU
    instancing). Big win for drawings with thousands of identical inserts (e.g.
    fasteners, symbols). Defer until a block-heavy file demands it.
- Editing a block definition dirties all its inserts (§2.5).

---

## 7. Foundation vs later (phased plan)

### Phase 0 — Foundation (build first)
1. **MTKView + transform + on-demand draw.** Orthographic `world→clip` matrix
   uniform, drawableSize/Retina, `enableSetNeedsDisplay`+`isPaused`, sRGB drawable,
   triple-buffered uniforms, Swift-6 main-actor renderer. *Pan/zoom must already be
   matrix-only.*
2. **Instanced line pipeline** (§1.1): segment→quad expansion, screen-space width,
   analytic AA, round cap/join. This single pipeline renders lines, polylines, and
   **tessellated** arcs/circles/ellipses/splines.
3. **CPU tessellation + zoom-bucketed LOD cache** (§1.2): port LibreCAD's
   sagitta tessellation; cache per LOD bucket.
4. **Persistent world-coord buffers + CPU geometry cache** (§2.1) with sub-range
   patching; **dirty-region** edit updates (§2.5).
5. **Loose quadtree + viewport culling** (§2.2–2.3) shared with snapping.
6. **CPU hit-testing/snapping via the quadtree + exact engine kernels** (§5);
   overlay layer for snap/crosshair/preview.
7. **Triangle pipeline + earcut fills** (§1.3) for solids/hatches/arrowheads.
8. **SDF glyph atlas + instanced text** (§3) for text & dimension strings.
9. **Block inserts flattened** (§6).

### Phase 1 — Optimize later (when profiling demands)
- Per-instance color/width/dash so it's **one instanced draw per pipeline** (§2.4).
- Miter/bevel joins for thick strokes; dash patterns in-shader (§1.1).
- GPU instancing of block geometry (§6); stencil even-odd fill fallback (§1.3).
- GPU-driven culling via `MTLIndirectCommandBuffer`/compute (§2.4); small-feature
  cluster collapse at extreme zoom-out (§2.3).
- Floating-origin precision for extreme zoom on large drawings (§4.1).
- MSDF text upgrade if small-text corners suffer (§3.1).
- R-tree (STR bulk-load) backend for read-mostly huge files (§2.2).

---

## 8. Rough performance budgets

At **120 Hz the frame budget is ~8.3 ms** (target ≤ ~6 ms of work to leave
headroom). Apple-Silicon unified memory; numbers are order-of-magnitude planning
targets, to be confirmed by profiling.

| Stage (per frame, during pan/zoom) | Budget | Notes |
|---|---|---|
| Quadtree visible-set query | < 0.3 ms | rectangle query; only on view change |
| Build instance list (visible only) | < 1.5 ms | iterate visible (~tens of thousands), pack instance structs; skip if view+model unchanged |
| Uniform/upload | < 0.1 ms | one matrix + ring-buffer copy (.shared) |
| GPU lines (instanced) | < 2 ms | tens of thousands of visible segments |
| GPU triangles (fills) | < 1 ms | visible hatch/solid triangles |
| GPU text (SDF glyphs) | < 1 ms | visible glyph instances |
| Overlay (snap/crosshair/preview) | < 0.3 ms | tiny |
| **Total visible-frame** | **~6 ms** | leaves ProMotion headroom |

Non-per-frame budgets:
- **Initial cache+index build** of a 1M-primitive file: target a few seconds, off
  the main actor, with progressive display (draw what's built).
- **Single-entity edit**: cache patch + buffer sub-range + quadtree update + one
  redraw — target < 1 ms (imperceptible).
- **LOD bucket crossing on zoom**: retessellate only entities that crossed —
  amortized, off-main-actor for large batches; within a bucket, **zero**
  retessellation (matrix-only zoom).

Key invariant that makes the budget hold: **per-frame CPU cost is O(visible), not
O(total)**, and **pan/zoom within an LOD bucket is matrix-only (no CPU geometry
work)**.

---

## 9. Sources

Live-confirmed this session (✅):
- redblobgames — Guide to SDF + MSDF Fonts: https://www.redblobgames.com/articles/sdf-fonts/
- chikin.net — Rendering Text: Signed Distance Fields: https://chikin.net/site/other/posts/sdftextrendering/

Canonical references (stable best-practice; re-verify when internet mode is on):
- mattdesl — Drawing Lines is Hard: https://mattdesl.svbtle.com/drawing-lines-is-hard
- wwwtyro — Instanced Line Rendering: https://wwwtyro.net/2019/11/18/instanced-lines.html
- Inigo Quilez — 2D distance functions (SDF shapes/arcs): https://iquilezles.org/articles/distfunctions2d/
- Anti-Grain Geometry — Adaptive subdivision of Bézier curves: https://www.antigrain.com/research/adaptive_bezier/
- Mapbox earcut (ear-clipping triangulation): https://github.com/mapbox/earcut
- libtess2 (robust tessellation): https://github.com/memononen/libtess2
- NVIDIA — GPU-accelerated path rendering (stencil-then-cover): https://developer.nvidia.com/gpu-accelerated-path-rendering
- Valve — Improved Alpha-Tested Magnification (SDF text origin): https://steamcdn-a.akamaihd.net/apps/valve/2007/SIGGRAPH2007_AlphaTestedMagnification.pdf
- Chlumsky — msdfgen (MSDF): https://github.com/Chlumsky/msdfgen
- RBush — R-tree spatial index (STR bulk load): https://github.com/mourner/rbush
- Apple — Metal documentation hub: https://developer.apple.com/documentation/metal
- Apple — MTKView (on-demand drawing): https://developer.apple.com/documentation/metalkit/mtkview
- Apple — Synchronizing CPU and GPU work (in-flight frames / triple buffering): https://developer.apple.com/documentation/metal/synchronizing_cpu_and_gpu_work
- Apple — Resource fundamentals (storage modes / unified memory): https://developer.apple.com/documentation/metal/resource_fundamentals
- Apple — On-screen presentation (color/sRGB): https://developer.apple.com/documentation/metal/onscreen_presentation
