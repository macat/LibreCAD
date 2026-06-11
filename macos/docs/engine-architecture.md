# LibreCAD Engine Architecture — Reference for the Swift Port

This maps the LibreCAD C++/Qt 2D CAD engine (`librecad/src/lib/`) so it can be
re-implemented cleanly in Swift (macOS 26 SDK, Swift 6.2). It is a *design*
reference, not a transpile guide: it describes the concepts, the class
hierarchy, the data each type carries, and the key operations. "Swift mapping
note" callouts suggest idiomatic Swift shapes.

Source root: `/Users/macatt/w/LibreCAD/librecad/src/lib/`
Subsystems: `engine/` (model + types), `math/`, `creation/`, `modification/`,
`fileio/`, `filters/`, `gui/` (view + painter), `printing/`, `information/`
(intersections, area), `actions/` (interactive tools), `generators/`,
`scripting/`.

Naming: `RS_*` = original RibbonSoft/LibreCAD classes; `LC_*` = newer LibreCAD
additions. The `RS2::` C++ namespace holds all engine enums.

---

## 1. 2D Math Core

### RS_Vector (`engine/rs_vector.h`)
Despite the 2D-CAD framing, `RS_Vector` is a **3D point/vector** (x/y/z) plus a
`valid` flag. z is largely unused in the 2D workflow but is carried everywhere.
There is **no separate `RS_Vector3D`** — `RS_Vector` *is* the 3D type.

Fields: `double x=0, y=0, z=0; bool valid=false;`

The `valid` flag is the engine's pervasive "optional" idiom — an invalid vector
(`RS_Vector(false)`) is returned to mean "no result" from snapping, nearest-point,
and intersection queries. `explicit operator bool()` tests validity.

Key operations (member + free):
- Construction: `(x,y,z)`, `(angle)` → unit vector, `(bool valid)`, `(QPointF)`,
  static `polar(rho, theta)`, `setPolar(radius, angle)`.
- Arithmetic operators: `+ - * /` (vector & scalar), compound assigns, unary `-`,
  `friend operator*(double, RS_Vector)`. `*`/`/` with another vector are
  component-wise.
- Geometry: `magnitude()`, `squared()`, `distanceTo()`, `squaredTo()`,
  `angle()`, `angleTo()`, `angleBetween()`, `dotP()`, `crossP()` (3D),
  `normalized()/normalize()`, `lerp(v,t)`, `relative(distance, angle)`.
- Transforms (mutating `&` and value-returning variants): `move`, `rotate`
  (by angle, by angle-vector, around a center), `scale` (uniform/per-axis/about
  center), `mirror(axisP1, axisP2)`, `shear(k)`, `flipXY()`.
- Window tests: `isInWindow`, `isInWindowOrdered`. Bounds helpers: static
  `minimum`, `maximum`. `posInLine(start,end,pos)` = projection parameter.

### RS_VectorSolutions (`engine/rs_vector.h`)
A small ordered collection of `RS_Vector` (1–4 typical) used to return multiple
geometric solutions (intersections, tangent points, foci). Carries a `tangent`
flag. Has `getClosest(coord)`, `hasValid()`, and batch transforms (rotate/move/
scale) applied to all members. This is the universal "geometry returns N points"
type.

> **Swift mapping note.** Make `RS_Vector` a `struct Vector2D` (or `Point2D`)
> conforming to `Equatable`, `Hashable`, `Sendable`, with value semantics and
> operator overloads. Drop the `valid` flag and the z coordinate from the public
> 2D surface; model "no result" with Swift `Optional` (`Vector2D?`) and 3D needs
> with a distinct `Vector3D` only where DXF Z actually matters. Replace
> `RS_VectorSolutions` with `[Vector2D]` plus a small wrapper or tuple carrying
> the `isTangent` flag. Keep mutating/non-mutating pairs idiomatic
> (`rotated(by:)` returns; `rotate(by:)` mutates `mutating func`).

### RS_Math (`math/rs_math.h`)
Free-function math namespace. Highlights:
- Angle utilities: `deg2rad/rad2deg/rad2gra/gra2rad`, `correctAngle` ([0,2π)),
  `correctAnglePlusMinusPi`, `correctAngle0ToPi`, `isAngleBetween(a,min,max,
  reversed)`, `getAngleDifference[U]`, `makeAngleReadable`.
- Float comparison: `equal/notEqual(tolerance)`, ULP-based `ulp/less/inBetween`
  templates. Tolerances are macros in `rs.h`: `RS_TOLERANCE 1e-10`,
  `RS_TOLERANCE_ANGLE 1e-8`, `RS_MAXDOUBLE 1e10`.
- Polynomial solvers: `quadraticSolver`, `cubicSolver`, `quarticSolver[Full]`,
  `linearSolver` (matrix), `simultaneousQuadraticSolver*` (conic intersection
  engine), `ellipticIntegral_2` (ellipse arc length).
- Expression evaluation: `eval(QString)` — the command-line lets users type
  `2*pi`, fractions, unit-bearing strings (`derationalize`, `convert_unit`).
- Supporting math: `lc_quadratic.h` (LC_Quadratic conic `m0..m5`), `lc_linemath.h`
  (line helpers), `lc_quadraticutils.h`.

> **Swift mapping note.** A `enum Math` namespace of `static func`s, or free
> functions in a module. Most operate on `Double`/`Vector2D`. The conic/polynomial
> solvers are the hardest, highest-value pieces to port carefully (used by
> ellipse intersection, tangents, fillets) — port with their unit tests
> (`math/tests/`). Use Swift's `Double.ulp` for the ULP comparisons.

### Units & constants
- `RS2::Unit` (`rs.h`): None, Inch, Foot, Mile, mm, cm, m, km, … Parsec
  (`LastUnit=21`). `RS2::LinearFormat` (Scientific/Decimal/Engineering/
  Architectural/Fractional/ArchitecturalMetric), `RS2::AngleUnit`,
  `RS2::AngleFormat`.
- `RS_Units` (`engine/rs_units.h`): static-only. `convert(val, src, dest)`,
  `getFactorToMM`, `isMetric`, plus `formatLinear/Scientific/Engineering/
  Architectural/Fractional` and `formatAngle` — the display-formatting layer.
  `paperFormatToSize`, `dpiToScale`. Holds a global
  `currentDrawingUnits`.

> **Swift mapping note.** `enum Unit: Int` (raw values match DXF for round-trip).
> Units conversion = pure functions. Formatting belongs in a separate
> `LengthFormatter`/`AngleFormatter` (do NOT mix display formatting into the
> geometry core). Replace the global `currentDrawingUnits` with per-document
> state.

### rs.h enums (the type vocabulary)
All in `namespace RS2`. The ones the port must mirror:
- `EntityType` (the rtti tag — drives all dynamic dispatch; see entity table).
- `Flags` (bitset: Undone, Visible, ByLayer, ByBlock, Frozen, Locked, Selected,
  Closed, Highlighted, Transparent, HatchChild, Selected1/2 for endpoints…).
- `Ending` (Start/End/None), `UpdateMode`, `DrawingMode` (Full/Auto/Preview/BW/WB),
  `ResolveLevel` (how deep to recurse containers), `LineType` (28 dash patterns,
  ByLayer=-1/ByBlock=-2), `LineWidth` (named mm widths, ByLayer/ByBlock/Default),
  `SnapMode`, `SnapRestriction`, `ActionType` (the giant tool enum, ~400 entries),
  `PaperFormat`, `CursorType`, `OverlayGraphics`, `RedrawMethod`.
- `namespace Text`: VAlign/HAlign, MTextDrawingDirection, line-spacing styles.

> **Swift mapping note.** `EntityType`/`ActionType` → Swift `enum`. But prefer
> modeling the entity hierarchy with a `protocol`/`enum Entity` and reserve a
> `kind` tag only where you genuinely need a discriminator (serialization,
> tool filtering). `Flags` → `OptionSet`. `LineType`/`LineWidth` → `enum` with
> the DXF raw values preserved.

---

## 2. Entity Model

### Hierarchy
```
LC_Drawable (interface: draw(painter), rtti())
RS_Undoable (undo participation, flag storage)
  └─ RS_Entity            (abstract base; multiply-inherits both above)
       ├─ RS_AtomicEntity (single primitive)
       │    ├─ RS_Line, RS_Point, RS_Circle, RS_Arc, RS_Ellipse
       │    ├─ RS_Constructionline, LC_Parabola, LC_Hyperbola
       │    ├─ LC_CachedLengthEntity (caches getLength) → RS_Line, LC_SplinePoints
       │    └─ RS_Solid
       └─ RS_EntityContainer (owns a list of child RS_Entity*)
            ├─ RS_Polyline, RS_Spline
            ├─ RS_Text, RS_MText, RS_Insert, RS_Hatch, RS_Image
            ├─ RS_Leader, LC_MLeader, LC_Wipeout
            ├─ RS_Dimension (abstract) → RS_DimAligned, RS_DimLinear,
            │     RS_DimRadial, RS_DimDiametric, RS_DimAngular, LC_DimArc,
            │     LC_DimOrdinate, RS_Tolerance
            └─ RS_Document → RS_Graphic, RS_Block
```
Container-ness is decided by `isContainer()/isAtomic()`, not C++ type alone —
polylines, text, inserts, hatches, dimensions are all *containers* that build
themselves out of atomic sub-entities in `update()`.

### RS_Entity base (`document/entities/rs_entity.h`)
Common state: `RS_EntityContainer* parent`, `RS_Vector minV, maxV` (bounding
box), `RS_Layer* m_layer`, `bool updateEnabled`, unique `unsigned long long id`,
and (in a pImpl) the pen, flags, user-defined vars, and DXF/DWG round-trip
sidecars (`DRW_Variant` XDATA, material/plotstyle/visual-style handles).

Key virtuals (the protocol every entity implements):
- Identity/structure: `clone()`, `rtti()`, `isContainer/isAtomic/isEdge`,
  `count()/countDeep()`, `getLength()`.
- Attributes: `getPen/setPen` (with ByLayer/ByBlock resolution via `getPenResolved`),
  `getLayer/setLayer`, `isSelected/setSelected/toggleSelected`, `isVisible`,
  `isHighlighted`, `isLocked`, `isConstruction`.
- Bounds: `calculateBorders()` (recompute minV/maxV), `getMin/getMax/getSize`,
  `moveBorders/scaleBorders/resetBorders`.
- Geometry queries (all return `RS_Vector`, invalid = none): `getNearestEndpoint`,
  `getNearestPointOnEntity`, `getNearestCenter`, `getNearestMiddle`,
  `getNearestDist`, `getNearestRef`, `getNearestOrthTan`, `getRefPoints`,
  `getStartpoint/getEndpoint`, `getCenter/getRadius`, `getTangentPoint/
  getTangentDirection`, `getDistanceToPoint`, `isPointOnEntity`.
- Transforms (pure-virtual core): `move`, `rotate(center,angle | center,vector)`,
  `scale(center,factor)`, `mirror(p1,p2)`, plus default `stretch`, `shear`,
  `offset`/`createOffset`/`offsetTwoSides`, `moveRef/moveSelectedRef`,
  `revertDirection`.
- Rendering: `draw(painter)`, `drawAsChild`, `drawDraft`, `update()`.
- Analysis: `getQuadratic()` (conic equation), `areaLineIntegral()`,
  `firstMomentLineIntegral()`, `secondMomentLineIntegral()` (Green's-theorem
  area/centroid/moments).

> **Swift mapping note.** This is the single most important porting decision.
> The C++ base is a deep abstract class with ~60 virtuals. In Swift prefer a
> **layered protocol** approach:
> - `protocol Entity` with associated common stored props pulled into a shared
>   `EntityAttributes` value (layer ref, pen, flags, id, bounds).
> - Split the geometry-query methods (`nearestPoint`, `intersect`, `tangent`)
>   into a `protocol GeometricEntity`, and transforms into `protocol Transformable`.
> - Concrete primitives (`Line`, `Arc`, `Circle`, `Ellipse`) can be **value
>   structs** (their data is small & copyable, matching the `RS_*Data` structs).
>   Containers (`Polyline`, `Insert`, `Dimension`, `Graphic`) likely need
>   **reference (`final class`)** semantics because of parent pointers, shared
>   child ownership, and identity-based undo.
> - Consider an `enum Entity` with associated values as an alternative to the
>   class hierarchy for the *atomic* primitives — gives exhaustive switch and
>   value semantics; use protocols/classes for the recursive containers.
> - Replace raw `parent` back-pointers with weak references or an explicit tree
>   model to avoid retain cycles.

### Data-struct pattern
Every concrete entity separates a plain `RS_*Data` POD struct (the geometry)
from the entity class (behavior). This is already very Swift-friendly — the
`Data` structs become Swift `struct`s directly.

### Concrete entity catalog
(All carry the common base state above; "Defining data" = the `*Data` struct.)

| Entity | rtti | Kind | Defining data | Notable methods / notes |
|---|---|---|---|---|
| **RS_Point** | EntityPoint | atomic | `pos` | Simplest entity. Draw style via PDMODE/PDSIZE graphic vars. |
| **RS_Line** | EntityLine | atomic (cached len) | `startpoint, endpoint` | `getAngle1/2`, `getNormalVector`, `getMiddlePoint`, `trim/moveStart/EndPoint`, `getQuadratic` (linear), exact area/moment integrals. Edge entity. |
| **RS_Constructionline** | EntityConstructionLine | atomic | two points | Infinite line (on construction layer). |
| **RS_Circle** | EntityCircle | atomic | `center, radius` | `getFoci`-style tangents, `offsetTwoSides`, conic `getQuadratic`. Edge. |
| **RS_Arc** | EntityArc | atomic | `center, radius, angle1, angle2, reversed` (+ cached degree fields) | CCW/CW via `reversed`. `getAngleLength`, `getBulge`, trim. Edge. |
| **RS_Ellipse** | EntityEllipse | atomic | `center, majorP` (major-axis endpoint rel. center), `ratio` (minor/major), `angle1, angle2, reversed` | Full ellipse or elliptic arc. `getMajor/MinorRadius`, `getRatio`, `getFoci`, `getEllipseAngle`, `getTangentPoint`, `createFrom4P/Center3Points/Inscribe`. Conic `getQuadratic`. Edge. |
| **LC_Parabola** | EntityParabola | atomic | 3 control points (focus/axis/vertex derived) | `From4Points`, `FromEndPointsTangents`, `GetFocus/Axis/Directrix`. |
| **LC_Hyperbola** | EntityHyperbola | atomic | `center, majorP, ratio (b/a), angle1, angle2, reversed` | Two-branch; `getFocus1/2`. |
| **RS_Polyline** | EntityPolyline | container | `RS_PolylineData{startpoint, endpoint}` + `RS_Flags` (Closed); children are RS_Line/RS_Arc segments; per-vertex **bulge** | `addVertex(v, bulge)`, `appendVertexs`, `isClosed/setClosed`, `getClosingBulge`, segment trim/offset. Bulge = arc tangent factor (DXF convention). |
| **RS_Spline** | EntitySpline | container | `controlPoints, knotslist, weights, fitPoints, degree(1–3), type{Standard/ClampedOpen/WrappedClosed}` | True NURBS-ish. Builds rendered segments in update(). |
| **LC_SplinePoints** | EntitySplinePoints | atomic (cached len) | `splinePoints, controlPoints, closed, cut, useControlPoints` | Interpolation (through-points) quadratic spline; supports trimming via "cut" state. |
| **RS_Text** | EntityText | container | `RS_TextData{insertionPoint, secondPoint, height, widthRel, V/HAlign, textGeneration, angle, text, style, bidi dir}` | Single-line text. `update()` lays out glyphs as RS_Insert refs into a font block. |
| **RS_MText** | EntityMText | container | `RS_MTextData{insertionPoint, height, width, V/HAlign, drawingDirection, lineSpacingStyle/Factor, text, style, angle}` | Multi-line/paragraph text. |
| **RS_Insert** | EntityInsert | container | `RS_InsertData{name, insertionPoint, scaleFactor(xyz), angle, cols, rows, spacing, blockSource}` | Block *reference*; can be a rectangular array (cols×rows). Resolves to the named RS_Block from the block list. |
| **RS_Hatch** | EntityHatch | container | `RS_HatchData{solid, scale, angle, pattern}` + boundary-loop child containers | Solid fill or named pattern; builds fill geometry from boundary loops via `getLoops()`. |
| **RS_Image** | EntityImage | container | `RS_ImageData{handle, insertionPoint, uVector, vVector, size(px), file, brightness, contrast, fade}` | Raster image placed by u/v basis vectors. |
| **RS_Solid** | EntitySolid | atomic | `corner[3 or 4]` (`std::array<RS_Vector,4>`) | Filled triangle/quad (DXF SOLID). |
| **RS_Leader** | EntityDimLeader | container | `RS_LeaderData{arrowHead, styleName}` + vertex children | Polyline-with-arrow callout. |
| **LC_MLeader** | EntityMLeader | container | `LC_MLeaderData` (roots, content base/insert points, text OR block content, style, leaderType, dogleg/landing, arrow size) | Modern multileader; text or block content. |
| **LC_Wipeout** | EntityWipeout | container | `LC_WipeoutData{vertices}` | Background-masking polygon (paints in viewport bg color). |
| **RS_Dimension** (abstract) | — | container | `RS_DimensionData{definitionPoint, middleOfText, V/HAlign, lineSpacing*, text("<>"=measured), style, angle, horizontalAxisDirection, autoText, dimStyleOverride, flipArrow1/2}` | Base for all dims; builds arrows/extension/dimension lines + MText in update() using a resolved `LC_DimStyle`. |
| **RS_DimAligned** | EntityDimAligned | dim | `extensionPoint1, extensionPoint2` | Distance parallel to the two ext points. |
| **RS_DimLinear** | EntityDimLinear | dim | `extensionPoint1/2, angle, oblique` | Rotated/horizontal/vertical linear. |
| **RS_DimRadial** | EntityDimRadial | dim | `definitionPoint, leader` | Radius of arc/circle. |
| **RS_DimDiametric** | EntityDimDiametric | dim | `definitionPoint, leader` | Diameter. |
| **RS_DimAngular** | EntityDimAngular | dim | `definitionPoint1..4` (two lines + arc point) | Angle between two lines. |
| **LC_DimArc** | EntityDimArc | dim | `radius, arcLength, centre, start/endAngle` | Arc-length dimension. |
| **LC_DimOrdinate** | EntityDimOrdinate | dim | `featurePoint, leaderEndPoint, ordinateForX` | X/Y ordinate dimension. |
| **RS_Tolerance** | EntityTolerance | dim | GD&T feature-control frame | |

> **Swift mapping note.** The `*Data` structs map 1:1 to Swift `struct`s and are
> the natural unit of equality, serialization, and undo snapshots. Dimensions,
> text, inserts and hatches are "computed containers": their child geometry is
> *derived* from `Data` + a style by `update()`. In Swift model these as a value
> `Data` + a `func render(style:) -> [Primitive]` rather than persisting a mutable
> child list, so the source of truth stays the small data struct. Bulge-based
> polylines: keep the `[(point, bulge)]` vertex list as the model; expand to
> line/arc segments lazily for rendering and geometry queries.

---

## 3. Document Model

### RS_Document (`engine/document/rs_document.h`)
Abstract base for things shown in a view; an `RS_EntityContainer` that also
inherits `RS_Undo`. Holds `activePen`, `modified` flag, current filename
(via subclass), and accessors for the sub-lists (layers, blocks, dim styles,
text styles, views, UCSs). Two concrete docs: `RS_Graphic` and `RS_Block`.

### RS_Graphic (`engine/document/rs_graphic.h`)
The top-level drawing. Owns:
- `RS_LayerList layerList` — all layers + active layer.
- `RS_BlockList blockList` — all block definitions.
- `RS_VariableDict m_variableDict` + `m_customVariablesDict` — DXF header
  variables and custom properties.
- `LC_ViewList namedViewsList`, `LC_UCSList ucsList`, `LC_DimStylesList
  dimstyleList`, `LC_TextStyleList textStyleList`.
- Drawing-wide settings: unit, linear/angle format & precision, grid on/iso,
  paper size/format/scale/margins/pages, anglesBase + CCW, `FormatType`,
  save time/modified state, modification listener.

`RS_Block`: a named group of entities with a `basePoint`; also an `RS_Document`
(so it can be edited in its own view). Referenced by `RS_Insert` entities. Blocks
live in the graphic's block list, **not** in the main entity tree.

### RS_Layer + RS_LayerList (`engine/document/layers/`)
`RS_LayerData{name, RS_Pen pen, frozen, locked, print, converted, construction,
visibleInLayerList, selectedInLayerList}`. Layer carries a default pen; entities
with ByLayer attributes resolve through it. `RS_LayerList` = ordered layers +
active layer + listener notifications (`RS_LayerListListener`).

### RS_BlockList (`engine/document/blocks/`)
Owns `RS_Block`s, tracks active block, unique-name generation (`newName`),
freeze/visibility, listeners.

### RS_Pen (`engine/rs_pen.h`)
`{RS2::LineType lineType, RS2::LineWidth width, RS_Color color, float alpha,
double dashOffset}` + flags (inherits `RS_Flags`). Encodes ByLayer/ByBlock via
the width/linetype sentinel values and color flags. `RS_Color`
(`engine/rs_color.h`) wraps RGB + ByLayer/ByBlock flags.

### Graphic variables (`engine/document/lc_graphicvariables.h`, `variables/`)
`RS_VariableDict` = `QHash<QString, RS_Variable>`; `RS_Variable` is a tagged
union (`RS2::VariableType`: String/Int/Double/Vector/Void) plus a DXF group code.
`LC_GraphicVariables` is a typed facade over the dict (gridOn, isoGrid,
anglesBase, dimStyle name, precision, unit, format) — the bridge between raw DXF
header vars and typed app state.

### Undo system (`engine/undo/`)
- `RS_Undoable` — mix-in giving every entity/layer an "undone" flag.
- `RS_Undo` — owns `vector<shared_ptr<RS_UndoCycle>>` + a redo pointer. API:
  `startUndoCycle()`, `addUndoable()`, `endUndoCycle()`, `undo()/redo()`,
  `removeUndoable()` (subclass deletes truly-discarded entities).
- `RS_UndoCycle` — a batch of undoables = one atomic user operation.
- `LC_UndoSection` (RAII) brackets a cycle; `lc_undoablerelzero` makes the
  relative-zero point undoable.
The scheme is **mark-don't-delete**: undone entities stay in the container with
the `Undone` flag set, removed only when they fall off the undo buffer.

> **Swift mapping note.** Document = `final class Drawing` (`ObservableObject`/
> `@Observable` for SwiftUI). Layers/blocks/styles = arrays + an `active` index;
> wrap in small managers. Pen = `struct Pen` (value type). For undo, prefer the
> macOS-native `UndoManager` *or* a command/snapshot stack over porting the
> flag-based mark scheme — the LibreCAD approach is tightly coupled to in-place
> mutation and shared pointers. If you keep value-type entity data, undo can be
> a stack of document snapshots/diffs, which is far simpler and Swift-idiomatic.
> Resolve the ByLayer/ByBlock pen cascade in one explicit `resolvedPen(for:)`
> function rather than the implicit flag checks scattered through `RS_Pen`.

---

## 4. Coordinate System, View & Rendering

### LC_GraphicViewport (`gui/lc_graphicviewport.h`)
The headless heart of the view: owns the **world↔screen transform**, zoom/pan,
grid, UCS, relative-zero, and named views. (`RS_GraphicView` and the Qt widget
`QG_GraphicView` are the UI wrappers on top — the port replaces these with an
`NSView`/Metal/Core Graphics layer.)

Transform (UCS → device pixels), with `factor` (per-axis scale), `offsetX/Y`,
`m_height`:
```
toGuiX = ucsX * factor.x + offsetX
toGuiY = -ucsY * factor.y + (height - offsetY)   // Y flips: world up = screen up
toUcsX = (uiX - offsetX) / factor.x
toUcsY = -(uiY - height + offsetY) / factor.y
```
Plus a UCS layer: world (WCS) ↔ user coordinate system, via the inherited
`LC_CoordinatesMapper` (`toWorld/toUCS`, angle bases). So the full pipeline is
**WCS → UCS → GUI pixels**.

Zoom/pan API: `zoomIn/Out`, `zoomAuto`, `zoomWindow`, `zoomPage`, `zoomPrevious`
(circular buffer of saved views), `zoomPan`, `zoomScroll`, `setOffsetAndFactor`,
`centerOffsetX/Y`. Relative-zero: `setRelativeZero/moveRelativeZero/lock`.
Grid: owns `RS_Grid` (`gui/grid/`), iso-grid modes (`RS2::IsoGridViewType`).
Overlays: `LC_OverlaysManager` keyed by `RS2::OverlayGraphics` (effects, action
preview, snapper, info cursor) — drawn on top of the entity layer.

### RS_Painter (`gui/render/rs_painter.h`)
Thin drawing facade subclassing `QPainter` and `LC_CoordinatesMapper`. Entities
call back into it. Key surface:
- Coordinate translation helpers (`toGui`, `toGuiPointF`, `toGuiDX/DY`) — entities
  hand it **world** coordinates and the painter projects.
- `drawEntity(entity)` / `drawAsChild(entity)` — the dispatch the draw loop uses.
- WCS draw primitives: `drawLineWCS`, `drawCircleWCS`, `drawEllipse[Arc]WCS`,
  `drawSplineWCS`, `drawSolidWCS`, `drawPolylineWCS`, `drawImgWCS`,
  `drawPointEntityWCS`, plus UI-space variants for overlays.
- Quality/perf: adaptive arc/ellipse tessellation (sagitta-based,
  `pathForParametricCurve`), min-radius/length culling, dash-pattern offset
  tracking, `DrawingMode` (Full/Preview/BW/WB), draw-selected-only, world
  bounding-rect clipping (`isFullyWithinBoundingRect`).

### Draw loop & overlay/preview
- The view renders the document tree top-down: `RS_EntityContainer::draw()`
  iterates children calling `painter->drawEntity`/`drawAsChild`. Visibility,
  layer-frozen, and selection state gate each entity.
- Overlays (`engine/overlays/`): separate containers for crosshair, snap
  indicator, info cursor, references (drag handles), highlight (hover glow),
  and **preview** (`engine/overlays/preview/rs_preview.h`) — the rubber-band
  geometry an in-progress tool shows before commit. Overlays are redrawn
  independently of the (cached) drawing layer via `RS2::RedrawMethod` bits
  (RedrawGrid/Overlay/Drawing/All).

> **Swift mapping note.** Keep the **viewport transform headless** (a
> `struct ViewportTransform` with `worldToScreen`/`screenToWorld` and a UCS
> stage), exactly as `LC_GraphicViewport` separates from the widget. On macOS,
> note AppKit's coordinate system is already Y-up (unlike Qt's Y-down) — you may
> not need the Y flip, simplifying the transform. Replace `RS_Painter`'s
> QPainter inheritance with a protocol `Renderer` backed by Core Graphics /
> Metal; entities draw against that protocol in world coords. Adopt the
> three-layer compositing (cached drawing layer + overlay layer + grid) — it is
> the key to interactive performance. The adaptive curve tessellation
> (`pathForParametricCurve`) is worth porting faithfully for visual fidelity.

---

## 5. Tool/Action & Snapping System

### RS_ActionInterface (`actions/rs_actioninterface.h`)
The interactive-tool **state machine**. Inherits `RS_Snapper` (so every tool is
snap-aware — the header itself flags this as questionable design) and `QObject`.

Core contract:
- An integer `m_status` is the state-machine state (e.g. line tool: status 0 =
  pick start, status 1 = pick end). `init(status)`, `setStatus`, `getStatus`.
- Input events: `mouseMoveEvent`, `mousePressEvent/Release`, `keyPress/Release`,
  `coordinateEvent` (typed coordinate), `commandEvent` (command line).
  `onMouseLeft/RightButtonPress/Release(status, e)` are the override points.
- Lifecycle: `trigger()` (commit the operation), `finish()`, `isFinished()`,
  `suspend()/resume()`, predecessor chaining (`setPredecessor`) for tool nesting.
- UX: `updateMouseButtonHints`, `updateMouseWidget*`, `getAvailableCommands`,
  options widget (`createOptionsWidget`), cursor (`doGetMouseCursor`).
- Undo helpers baked in: `undoCycleStart/End`, `undoableAdd`, `undoCycleAdd`,
  `undoCycleReplace`, `undoableDeleteEntity`, `setPenAndLayerToActive`.
- `switchToAction(actionType)` transfers control to another tool.

`RS_PreviewActionInterface` adds the rubber-band preview container for drawing
tools. Concrete actions live under `actions/drawing/{draw,modify,snap,zoom,
selection,info,pen,...}` — each is one tool subclass.

### RS_Snapper + RS_SnapMode (`actions/rs_snapper.h`)
`RS_SnapMode` is a set of booleans (modeled as a bitset `SnapModes`):
`snapFree, snapGrid, snapEndpoint, snapMiddle, snapCenter, snapOnEntity,
snapDistance, snapIntersection, snapAngle` + a `restriction`
(Nothing/Horizontal/Vertical/Orthogonal). `toInt/fromInt` persist it.

`RS_Snapper` turns a raw mouse position into a snapped world point:
- Per-mode snappers: `snapFree`, `snapGrid`, `snapEndpoint`, `snapOnEntity`,
  `snapCenter`, `snapMiddle`, `snapDist`, `snapIntersection`, plus `snapToAngle`/
  `snapToRelativeAngle` and `restrictOrthogonal/Horizontal/Vertical`.
- `snapPoint(coord)` = the dispatcher: tries enabled modes, picks the closest
  within `m_catchEntityGuiRange` (GUI pixels), updates the snap indicator overlay.
- `catchEntity(pos[, type/typeList], resolveLevel)` — hit-test the nearest entity
  (optionally filtered by `EntityType`); `getKeyEntity()` is the entity the snap
  locked onto.
- Carries the WCS↔UCS conversion helpers, coordinate-widget/info-cursor updates,
  and relative-zero access. Range tuning via `m_distanceBeforeSwitchToFreeSnap`,
  `m_minGridCellSnapFactor`, `m_SnapDistance`, `m_middlePoints`.

### Creation tools (`creation/rs_creation.cpp`)
`RS_Creation` — *non-interactive* geometry factory bound to a container.
Produces parallels (line/arc/circle/spline), bisectors, tangents
(`createTangent1/2`, `createLineOrthTan`, `createLineRelAngle`), polygons
(by center/corner/tangent), `createInsert`, `createImage`, `createBlock`,
`createLibraryInsert`. Interactive draw actions call into this to build the
actual entity, then add it via an undo cycle.

### Modification tools (`modification/rs_modification.h`)
`RS_Modification` — *non-interactive* edit API on a container (+ viewport +
undo). Each op has a `*Data` struct (all extend `LC_ModifyOperationFlags`:
keepOriginals, useCurrentLayer/Attributes, number, multipleCopies):
- Transform copies: `move`, `rotate`, `scale`, `mirror`, `moveRotate`,
  `rotate2` (two-center), `alignRef` — all support preview-only and multi-copy.
- `trim` / `trimAmount` / `cut` / `stretch`.
- `bevel` (chamfer, `RS_BevelData{length1,length2,trim}`) / `round` (fillet,
  `RS_RoundData{radius,trim}`) — return rich result structs with the new
  segment + which endpoints were trimmed.
- `offset` (`RS_OffsetData{coord,distance}`), `explode`,
  `explodeTextIntoLetters`, `changeAttributes`, `remove`, `revertDirection`,
  `copy`/`paste` (clipboard), `moveRef`.
- Polyline editing: `splitPolyline`, `addPolylineNode`, `deletePolylineNode[s
  Between]`, `polylineTrim`.
`lc_align.cpp` (align) and `lc_division.cpp` (divide/slice) are companion
modification helpers; `rs_selection.cpp` handles selection ops.

### Intersections & information (`information/rs_information.h`)
`RS_Information` is the geometry-relations engine used by snapping, trim, and
fillet: `getIntersection(e1, e2, onEntities)` dispatches to typed kernels
(`getIntersectionLineLine`, `LineArc`, `ArcArc`, `EllipseEllipse`,
`ArcEllipse`, `CircleEllipse`, `EllipseLine`) returning `RS_VectorSolutions`.
Also `isPointInsideContour`, `isTrimmable`, nearest-point helpers.
`rs_infoarea.cpp` computes polygon/contour areas.

> **Swift mapping note.** The action state machine ports well to Swift:
> model each tool as a type conforming to `protocol Tool` with an associated
> `enum State` (instead of a magic `Int status`) — exhaustive `switch` on state
> in the event handlers is clearer and safer. Decouple snapping from the tool
> base (the C++ comment admits the inheritance is wrong): make `Snapper` a
> *collaborator* the tool owns, not a superclass. `SnapMode` → an `OptionSet`.
> Keep `Creation`/`Modification` as **pure functions over value data returning
> new entities** — they already avoid interaction, so they become clean,
> testable Swift functions (`func fillet(_:_:radius:) -> FilletResult`). The
> intersection kernels (`RS_Information`) are pure geometry — port them as a
> standalone, heavily unit-tested module; they are the backbone of snapping and
> editing and where most subtle bugs live.

---

## Porting Priority & Decisions (summary)

1. **Value-type geometry core first.** `Vector2D`, `Matrix`/transform,
   `Math` solvers, the conic/intersection kernels (`RS_Math` +
   `RS_Information`). Pure, testable, no UI. Port LibreCAD's existing tests.
2. **Entity model as protocol + value `Data` structs.** Atomic primitives as
   `struct`s; recursive containers (polyline/insert/dimension/hatch/graphic) as
   `final class`. The `*Data` structs transfer almost verbatim.
3. **Headless viewport transform + renderer protocol**, separate from the
   AppKit view (mirror the `LC_GraphicViewport` vs widget split; exploit
   AppKit's Y-up to drop the flip). Three-layer compositing for interactivity.
4. **Snapping/Information as a standalone module**; tools as state-machine types
   with explicit `enum State`, owning (not inheriting) a `Snapper`.
5. **Undo: prefer snapshot/command stack** (or `UndoManager`) over the
   flag-based mark-don't-delete scheme, enabled by value-type entity data.
