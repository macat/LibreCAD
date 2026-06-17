//
//  ToolOptionsBar.swift
//  LibreCADmacOS
//
//  The contextual TOOL OPTIONS bar (UX-plan U2 — "tools are difficult to use").
//  A slim horizontal strip pinned directly UNDER the toolbar (above the canvas)
//  that shows ONLY the active tool's parameters, always visible while that tool is
//  running. It is the modern macOS "settings for what you're doing right now"
//  pattern (cf. the formatting bar in Pages/Keynote), replacing the old model where
//  tool parameters were buried in the Inspector and most tools had none.
//
//  ## One source of truth: CanvasModel
//  Every control is two-way bound to a `CanvasModel` config field (the SAME fields
//  the Inspector's tool-options section reads). On change the bar calls
//  `model.reapplyActiveToolConfig()`, which pushes the values onto the live tool via
//  `applyToolConfig()` — so a value set in the bar flows into the tool no matter how
//  the tool was activated (toolbar, menu, ⌘K, or keyboard shortcut), and a live
//  preview that depends on the option (e.g. fillet radius) updates immediately.
//
//  ## Which tools expose which options
//  - DRAW (NEW — UX-plan U2):
//      • Polygon   → sides (≥3) + inscribed/circumscribed
//      • Rectangle → optional exact width × height (single-click exact-size box)
//      • Circle    → radius/diameter input mode + optional exact size
//      • Arc       → creation mode (center→start→end / 3-point)
//      • Point     → marker style
//      • Text      → default cap height
//  - EDIT/MODIFY (mirrored from the Inspector):
//      • Fillet    → radius
//      • Chamfer   → distance 1 / distance 2
//      • Array     → rectangular (rows/cols/spacing) or polar (count/angle/rotate)
//      • Divide    → mode {By number → pieces, By length → spacing}
//  - WAVE-3B parameterized tools (mode + per-mode params on the live tool):
//      • Spline    → mode {Fit, Control points}
//      • Scale     → mode {Uniform, Non-uniform → X / Y factors}
//      • Hatch     → pattern {Solid sentinel + bundled .pat names} + scale + angle
//  Tools without options render NOTHING (the bar collapses), so it never adds chrome
//  for Select/Line/etc.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The contextual tool-options bar. Renders the active tool's parameters as a
/// single horizontal row; empty (zero-height) for tools that have no options.
struct ToolOptionsBar: View {
    /// The live canvas model — the single source of truth for every tool option.
    /// The bar binds to its config fields and re-applies them onto the live tool.
    @Bindable var model: CanvasModel
    /// The host controller box, so an option change can nudge the canvas to redraw
    /// (an option-dependent preview, e.g. the fillet radius, updates live).
    let controllerBox: CADCanvasView.ControllerBox

    var body: some View {
        // Only build the bar when the active tool actually has options; otherwise
        // render nothing so the inset collapses (no empty strip for Select/Line/…).
        if hasOptions {
            HStack(spacing: DS.Space.lg) {
                // A leading label so the bar reads as "<Tool> options" — the glyph is
                // the ACTIVE tool's OWN symbol (from ToolCatalog), so the bar's icon
                // matches the toolbar button the user just clicked (§3b).
                Label(model.activeToolKind.title,
                      systemImage: ToolCatalog.metadata(for: model.activeToolKind).symbol)
                    .font(DS.Font.barLabel)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)

                Divider().frame(height: DS.Size.barDivider)

                optionControls

                Spacer(minLength: 0)
            }
            .barStrip()
        }
    }

    /// Whether the active tool exposes any options (drives whether the bar shows).
    private var hasOptions: Bool {
        switch model.activeToolKind {
        case .polygon, .rectangle, .circle, .arc, .point, .text,
             // NEW modes surfaced this wave: Ellipse construction mode, Trim mode,
             // and the Image tool's chosen-file readout.
             .ellipse, .trim, .image,
             // Wire-wave-1 draw-variant modes: Line angle constraint (the Circle
             // construction mode + Arc tangential mode ride the existing .circle/.arc
             // arms below).
             .line,
             .fillet, .chamfer, .array, .divide,
             // Wave-3B parameterized tools (mode + per-mode params on the live tool).
             .spline, .scale, .hatch,
             // Wire-wave-3 configurable tools.
             .align, .arrayPath, .leader, .multileader, .baselineDim,
             // Wire-wave-4 configurable tools: Offset modes, Rotate/Mirror copy,
             // Line-construction method.
             .offset, .rotate, .mirror, .lineConstruction,
             // Lane-M surfaced tool modes: Polyline-Edit action + XLine direction lock.
             .polylineEdit, .xline,
             // Block INSERT placement options: scale / rotation / MINSERT array.
             .insert:
            return true
        default:
            return false
        }
    }

    // MARK: - Per-tool controls

    @ViewBuilder
    private var optionControls: some View {
        switch model.activeToolKind {

        // MARK: Draw tools (NEW — UX-plan U2)

        case .polygon:
            stepperField("Sides", value: $model.polygonSides, range: 3...64, width: DS.Field.xy)
            // Construction mode: Center→corner / Edge / Star. (case index 0/1/2 →
            // PolygonMode in applyToolConfig.)
            Picker("Mode", selection: $model.polygonModeStyle) {
                Text("Center").tag(0)
                Text("Edge").tag(1)
                Text("Star").tag(2)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.polygonModeStyle) { _, _ in apply() }
            // The star ratio (inner/outer radius), only meaningful in Star mode.
            if model.polygonModeStyle == 2 {
                numberField("Ratio", value: $model.polygonStarRatio, width: DS.Field.xy)
            }
            // Inscribed/circumscribed applies to Center & Star (ignored by Edge).
            Picker("Fit", selection: $model.polygonFit) {
                Text("Inscribed").tag(PolygonFit.inscribed)
                Text("Circumscribed").tag(PolygonFit.circumscribed)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.polygonFit) { _, _ in apply() }

        case .rectangle:
            // Corner treatment: Square / Rounded / Chamfer (case index 0/1/2 →
            // RectangleCorner in applyToolConfig). A radius/distance field shows for
            // the non-square modes.
            Picker("Corner", selection: $model.rectCornerStyle) {
                Text("Square").tag(0)
                Text("Rounded").tag(1)
                Text("Chamfer").tag(2)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.rectCornerStyle) { _, _ in apply() }
            if model.rectCornerStyle != 0 {
                numberField(model.rectCornerStyle == 1 ? "Radius" : "Distance",
                            value: $model.rectCornerSize, width: DS.Field.xy)
            }
            Divider().frame(height: DS.Size.barDivider)
            numberField("Width", value: $model.rectWidth, width: DS.Field.narrow)
            numberField("Height", value: $model.rectHeight, width: DS.Field.narrow)
            Text("0 = drag two corners")
                .font(.caption).foregroundStyle(.tertiary)

        case .ellipse:
            // Construction mode: Axis / Foci / 4-Point / Inscribe / Arc (case index
            // 0…4 → EllipseTool.Mode in applyToolConfig). EllipseTool's mode is fixed at
            // construction, so applyToolConfig RE-MINTS on change. (Bound to an Int index
            // because EllipseTool.Mode isn't Hashable — can't be a Picker tag.)
            Picker("Mode", selection: $model.ellipseModeIndex) {
                Text("Axis").tag(0)
                Text("Foci").tag(1)
                Text("4-Point").tag(2)
                Text("Inscribe").tag(3)
                Text("Arc").tag(4)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.ellipseModeIndex) { _, _ in apply() }

        case .trim:
            // Trim mode: Boundary (single-click cut) / Amount (signed distance) /
            // Mutual (trim two to their intersection) — case index 0/1/2. NOTE: only
            // `.boundary` is driven end-to-end by TrimTool.handle today; `.amount` /
            // `.mutual` are pure static entry points not yet dispatched from `handle`
            // (engine gap — see report). (Bound to an Int index because TrimTool.Mode
            // isn't Hashable — can't be a Picker tag.)
            Picker("Mode", selection: $model.trimModeIndex) {
                Text("Boundary").tag(0)
                Text("Amount").tag(1)
                Text("Mutual").tag(2)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.trimModeIndex) { _, _ in apply() }
            if model.trimModeIndex == 1 {
                numberField("Amount", value: $model.trimAmount, width: DS.Field.narrow)
            }

        case .image:
            // Show the chosen file name (the picker set it on activation); empty when
            // none is chosen yet (the tool is then a no-op until a file is picked).
            if let name = model.imageFileName {
                Label(name, systemImage: "photo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Click lower-left, then a bottom-edge corner")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("No image chosen")
                    .font(.callout).foregroundStyle(.tertiary)
            }

        case .circle:
            circleOptionControls

        case .arc:
            Picker("Mode", selection: $model.arcMode) {
                Text("Center, Start, End").tag(ArcCreationMode.centerStartEnd)
                Text("3 Points").tag(ArcCreationMode.threePoint)
                Text("Tangential").tag(ArcCreationMode.tangential)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.arcMode) { _, _ in apply() }

        case .line:
            // Angle constraint: Free (the original behavior), Absolute (a fixed angle
            // from +X), or Relative (an angle measured from the previous segment). The
            // angle field shows only for the two constrained modes. Fixed at
            // construction (it seeds the per-segment constraint), so applyToolConfig
            // RE-MINTS on change.
            Picker("Angle", selection: $model.lineAngleModeIndex) {
                Text("Free").tag(0)
                Text("Absolute").tag(1)
                Text("Relative").tag(2)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.lineAngleModeIndex) { _, _ in apply() }
            if model.lineAngleModeIndex != 0 {
                numberField("Angle°", value: degreesBinding($model.lineAngle), width: DS.Field.narrow)
            }

        case .point:
            Picker("Style", selection: $model.pointStyle) {
                ForEach(PointStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .fixedSize()
            .onChange(of: model.pointStyle) { _, _ in apply() }

        case .text:
            numberField("Height", value: $model.textHeight, width: DS.Field.narrow)

        // MARK: Edit / modify tools (mirrored from the Inspector)

        case .fillet:
            numberField("Radius", value: $model.filletRadius, width: DS.Field.narrow)

        case .chamfer:
            numberField("Distance 1", value: $model.chamferDistance1, width: DS.Field.narrow)
            numberField("Distance 2", value: $model.chamferDistance2, width: DS.Field.narrow)

        case .array:
            Picker("Type", selection: $model.arrayPolar) {
                Text("Rectangular").tag(false)
                Text("Polar").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.arrayPolar) { _, _ in apply() }

            if model.arrayPolar {
                stepperField("Count", value: $model.arrayPolarCount, range: 2...360, width: DS.Field.xy)
                numberField("Angle°", value: degreesBinding($model.arrayPolarTotalAngle), width: DS.Field.xy)
                Toggle("Rotate", isOn: $model.arrayPolarRotateItems)
                    .toggleStyle(.checkbox)
                    .onChange(of: model.arrayPolarRotateItems) { _, _ in apply() }
            } else {
                stepperField("Rows", value: $model.arrayRows, range: 1...1000, width: DS.Field.xy)
                stepperField("Cols", value: $model.arrayCols, range: 1...1000, width: DS.Field.xy)
                numberField("Row sp.", value: $model.arraySpacingY, width: DS.Field.xy)
                numberField("Col sp.", value: $model.arraySpacingX, width: DS.Field.xy)
            }

        case .divide:
            // Mode: DIVIDE-by-NUMBER (`divideModeStyle == 0`, the default — drop n−1
            // interior points) vs MEASURE-by-LENGTH (`== 1` — a node every `divideSpacing`
            // world units). DivideTool's mode is fixed at construction, so applyToolConfig
            // RE-MINTS it from the assembled `divideMode`. (Index-bound: `DivideMode`
            // carries an associated value, so it can't be a Picker tag.)
            Picker("Mode", selection: $model.divideModeStyle) {
                Text("By number").tag(0)
                Text("By length").tag(1)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.divideModeStyle) { _, _ in apply() }
            if model.divideModeStyle == 1 {
                // Length mode: the spacing (world units along the curve) between nodes.
                numberField("Spacing", value: $model.divideSpacing, width: DS.Field.narrow)
            } else {
                // Number mode: the count of equal pieces (drops count − 1 interior points).
                stepperField("Pieces", value: $model.divideCount, range: 2...1000, width: DS.Field.xy)
            }

        // MARK: Wave-3B parameterized tools (Spline / Scale / Hatch)

        case .spline:
            // How the picks are interpreted on commit: FIT points (the default
            // `.splinePoints` interpolation curve) vs NURBS CONTROL points (`.spline`
            // B-spline whose control polygon IS the picks). SplineTool's `mode` is a `let`
            // fixed at construction, so applyToolConfig RE-MINTS the tool on change.
            Picker("Mode", selection: $model.splineMode) {
                Text("Fit").tag(SplineMode.fit)
                Text("Control points").tag(SplineMode.controlPoints)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.splineMode) { _, _ in apply() }

        case .scale:
            // Mode: UNIFORM (`.factor`, the original distance-ratio scale — the default)
            // vs NON-UNIFORM (independent per-axis `(sx, sy)` about one base). ScaleTool
            // carries `mode` + `nonUniformFactors` as settable `var`s, so applyToolConfig
            // sets them IN PLACE. (Index-bound: `ScaleMode` is Equatable but not Hashable,
            // so it can't be a Picker tag — bind a computed Int index over it.)
            Picker("Mode", selection: scaleModeIndex) {
                Text("Uniform").tag(0)
                Text("Non-uniform").tag(1)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.scaleMode) { _, _ in apply() }
            if model.scaleMode == .nonUniform {
                Divider().frame(height: DS.Size.barDivider)
                numberField("Scale X", value: $model.scaleX, width: DS.Field.xy)
                numberField("Scale Y", value: $model.scaleY, width: DS.Field.xy)
            }

        case .hatch:
            // Pattern dropdown: a "Solid" sentinel (no pattern ⇒ a solid fill, the
            // back-compatible default) plus every bundled `.pat` pattern name. Bound to
            // `currentHatchPattern` (nil ⇒ Solid); applyToolConfig assembles the
            // `HatchTool.Fill` (solid for nil/"SOLID", else a named pattern + scale/angle).
            Picker("Pattern", selection: hatchPatternSelection) {
                Text("Solid").tag(Self.hatchSolidTag)
                ForEach(hatchPatternNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.currentHatchPattern) { _, _ in apply() }
            // Scale + angle apply only to a NAMED pattern (a solid fill ignores them).
            if model.currentHatchPattern != nil {
                Divider().frame(height: DS.Size.barDivider)
                numberField("Scale", value: $model.hatchPatternScale, width: DS.Field.narrow)
                numberField("Angle°", value: degreesBinding($model.hatchPatternAngle), width: DS.Field.narrow)
            }

        // MARK: Wire-wave-3 configurable tools

        case .align:
            Toggle("Scale to fit", isOn: $model.alignScaleToFit)
                .toggleStyle(.checkbox)
                .onChange(of: model.alignScaleToFit) { _, _ in apply() }

        case .arrayPath:
            stepperField("Count", value: $model.arrayPathCount, range: 1...1000, width: DS.Field.xy)
            Toggle("Align to path", isOn: $model.arrayPathAlignToTangent)
                .toggleStyle(.checkbox)
                .onChange(of: model.arrayPathAlignToTangent) { _, _ in apply() }

        case .leader:
            textField("Text", value: $model.leaderText, width: DS.Field.wide)
            numberField("Height", value: $model.leaderTextHeight, width: DS.Field.xy)

        case .multileader:
            textField("Text", value: $model.multiLeaderText, width: DS.Field.wide)
            numberField("Height", value: $model.multiLeaderTextHeight, width: DS.Field.xy)
            numberField("Landing", value: $model.multiLeaderLandingDistance, width: DS.Field.narrow)
            Toggle("Dogleg", isOn: $model.multiLeaderDoglegEnabled)
                .toggleStyle(.checkbox)
                .onChange(of: model.multiLeaderDoglegEnabled) { _, _ in apply() }

        case .baselineDim:
            numberField("Spacing", value: $model.baselineSpacing, width: DS.Field.narrow)

        // MARK: Wire-wave-4 configurable tools (Offset / Rotate / Mirror / Line construction)

        case .offset:
            offsetOptionControls

        case .rotate:
            // ROTATE "Copy": keep the originals and add rotated copies. Off (the
            // default) rotates in place. In-place var, so applyToolConfig applies it
            // without a re-mint.
            Toggle("Copy (keep original)", isOn: $model.rotateKeepOriginal)
                .toggleStyle(.checkbox)
                .onChange(of: model.rotateKeepOriginal) { _, _ in apply() }

        case .mirror:
            // MIRROR "keep source": keep the originals and add mirrored copies. Off
            // (the default) mirrors in place. In-place var (no re-mint).
            Toggle("Copy (keep original)", isOn: $model.mirrorKeepOriginal)
                .toggleStyle(.checkbox)
                .onChange(of: model.mirrorKeepOriginal) { _, _ in apply() }

        case .lineConstruction:
            // Construction method: perpendicular-foot / parallel-through / bisector /
            // tangent-1 / tangent-2 / orth-tangent. LineConstructionTool.Mode is a
            // String-raw CaseIterable, so it binds directly as a Picker tag. Fixed at
            // construction, so applyToolConfig RE-MINTS on change.
            Picker("Method", selection: $model.lineConstructionMode) {
                Text("Perpendicular").tag(LineConstructionTool.Mode.perpendicularFoot)
                Text("Parallel").tag(LineConstructionTool.Mode.parallelThrough)
                Text("Bisector").tag(LineConstructionTool.Mode.angleBisector)
                Text("Tangent 1").tag(LineConstructionTool.Mode.tangent1)
                Text("Tangent 2").tag(LineConstructionTool.Mode.tangent2)
                Text("Orthogonal tangent").tag(LineConstructionTool.Mode.orthTangent)
            }
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.lineConstructionMode) { _, _ in apply() }

        // MARK: Lane-M surfaced tool modes (Polyline-Edit / XLine)

        case .polylineEdit:
            // Vertex/segment edit action: Move / Add / Remove a vertex, or toggle a
            // segment straight↔arc (case index 0/1/2/3 → PolylineEditTool.Mode in
            // applyToolConfig). PolylineEditTool.Mode is Equatable-not-Hashable, so the
            // picker binds the Int index. Applied IN PLACE (the tool keeps its picked
            // polyline target across a mode switch).
            Picker("Action", selection: $model.polylineEditModeIndex) {
                Text("Move").tag(0)
                Text("Add").tag(1)
                Text("Remove").tag(2)
                Text("Arc").tag(3)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.polylineEditModeIndex) { _, _ in apply() }

        case .xline:
            // Construction-line direction lock: Free (two-point) / Horizontal / Vertical /
            // fixed Angle (case index 0/1/2/3 → XLineTool.Mode in applyToolConfig). The
            // angle field shows only for the Angle mode. XLineTool.Mode carries an
            // associated value, so the picker binds the Int index; the tool is RE-MINTED on
            // change (the mode is fixed at construction).
            Picker("Direction", selection: $model.xlineModeIndex) {
                Text("Free").tag(0)
                Text("Horizontal").tag(1)
                Text("Vertical").tag(2)
                Text("Angle").tag(3)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.xlineModeIndex) { _, _ in apply() }
            if model.xlineModeIndex == 3 {
                numberField("Angle°", value: degreesBinding($model.xlineAngle), width: DS.Field.narrow)
            }

        // MARK: Block Insert — scale / rotation / MINSERT array
        case .insert:
            insertScaleControls
            Divider().frame(height: DS.Size.barDivider)
            numberField("Rotation°", value: degreesBinding($model.insertRotation), width: DS.Field.narrow)
            Divider().frame(height: DS.Size.barDivider)
            insertArrayControls

        default:
            EmptyView()
        }
    }

    // MARK: - Circle option group (decomposed to keep the body type-checkable)

    /// The Circle tool's CONSTRUCTION-MODE picker + the size controls. The size mode +
    /// exact-size entry are shown for the center+radius path (orthogonal to the
    /// construction mode); the TTR (tan-tan-radius) mode REQUIRES a radius, so its
    /// numeric entry is shown there too. The 2-/3-point and TTT/from-arc modes are
    /// pick-defined (no numeric size). Construction mode is fixed at construction, so
    /// applyToolConfig RE-MINTS on change; the size mode + size are settable vars.
    @ViewBuilder
    private var circleOptionControls: some View {
        Picker("Mode", selection: $model.circleConstructionMode) {
            Text("Center, Radius").tag(CircleConstructionMode.centerRadius)
            Text("2 Points").tag(CircleConstructionMode.twoPoint)
            Text("3 Points").tag(CircleConstructionMode.threePoint)
            Text("Tan, Tan, Radius").tag(CircleConstructionMode.tanTanRadius)
            Text("Tan, Tan, Tan").tag(CircleConstructionMode.tanTanTan)
            Text("From Arc").tag(CircleConstructionMode.fromArc)
        }
        .fixedSize()
        .labelsHidden()
        .onChange(of: model.circleConstructionMode) { _, _ in apply() }
        // Center+Radius: size mode + an optional exact size (0 ⇒ drag radius).
        if model.circleConstructionMode == .centerRadius {
            Divider().frame(height: DS.Size.barDivider)
            Picker("Size", selection: $model.circleSizeMode) {
                Text("Radius").tag(CircleSizeMode.radius)
                Text("Diameter").tag(CircleSizeMode.diameter)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.circleSizeMode) { _, _ in apply() }
            numberField(model.circleSizeMode == .diameter ? "Diameter" : "Radius",
                        value: $model.circleFixedSize, width: DS.Field.narrow)
            Text("0 = drag radius")
                .font(.caption).foregroundStyle(.tertiary)
        } else if model.circleConstructionMode == .tanTanRadius {
            // TTR requires a positive radius (reuses the same circleSizeMode /
            // circleFixedSize field the tool resolves into the TTR radius). With no
            // size set the picks are no-ops, so prompt for one.
            Divider().frame(height: DS.Size.barDivider)
            Picker("Size", selection: $model.circleSizeMode) {
                Text("Radius").tag(CircleSizeMode.radius)
                Text("Diameter").tag(CircleSizeMode.diameter)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.circleSizeMode) { _, _ in apply() }
            numberField(model.circleSizeMode == .diameter ? "Diameter" : "Radius",
                        value: $model.circleFixedSize, width: DS.Field.narrow)
            Text("required")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Offset option group (decomposed to keep the body type-checkable)

    /// The Offset tool's MODE segmented control + a Distance field (shown only in the
    /// fixed-distance mode) + the Both-sides and Erase-source toggles. The mode is
    /// bound to an Int index (OffsetMode is Equatable-not-Hashable, so no Picker tag);
    /// every var is settable in place, so applyToolConfig applies without a re-mint.
    @ViewBuilder
    private var offsetOptionControls: some View {
        Picker("Mode", selection: $model.offsetModeIndex) {
            Text("Through point").tag(0)
            Text("Distance").tag(1)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
        .onChange(of: model.offsetModeIndex) { _, _ in apply() }
        if model.offsetModeIndex == 1 {
            numberField("Distance", value: $model.offsetDistance, width: DS.Field.narrow)
        }
        Divider().frame(height: DS.Size.barDivider)
        Toggle("Both sides", isOn: $model.offsetBothSides)
            .toggleStyle(.checkbox)
            .onChange(of: model.offsetBothSides) { _, _ in apply() }
        Toggle("Erase source", isOn: $model.offsetEraseSource)
            .toggleStyle(.checkbox)
            .onChange(of: model.offsetEraseSource) { _, _ in apply() }
    }

    // MARK: - Insert tool option groups (decomposed to keep the body type-checkable)

    /// The Insert tool's SCALE controls: a uniform toggle plus the X (and, when
    /// per-axis, Y) scale field. Uniform hides the Y field (one factor for both axes).
    @ViewBuilder
    private var insertScaleControls: some View {
        Toggle("Uniform scale", isOn: $model.insertScaleUniform)
            .toggleStyle(.checkbox)
            .onChange(of: model.insertScaleUniform) { _, _ in apply() }
        numberField(model.insertScaleUniform ? "Scale" : "Scale X",
                    value: $model.insertScaleX, width: DS.Field.xy)
        if !model.insertScaleUniform {
            numberField("Scale Y", value: $model.insertScaleY, width: DS.Field.xy)
        }
    }

    /// The Insert tool's MINSERT ARRAY controls: rows × cols and their world-unit
    /// spacing. Default 1×1 / zero spacing ⇒ a plain single insert.
    @ViewBuilder
    private var insertArrayControls: some View {
        stepperField("Rows", value: $model.insertRows, range: 1...1000, width: DS.Field.xy)
        stepperField("Cols", value: $model.insertCols, range: 1...1000, width: DS.Field.xy)
        numberField("Row sp.", value: $model.insertRowSpacing, width: DS.Field.xy)
        numberField("Col sp.", value: $model.insertColSpacing, width: DS.Field.xy)
    }

    // MARK: - Small control builders (compact, inline — sized for a single row)

    /// A labeled plain-text `String` field (e.g. the Leader annotation text).
    /// Re-applies the tool config on every change so the live tool tracks the value.
    @ViewBuilder
    private func textField(_ label: String, value: Binding<String>, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            TextField(label, text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in apply() }
                .onSubmit { apply() }
        }
    }

    /// A labeled numeric `Double` field. Re-applies the tool config on every change
    /// so the live tool / preview tracks the value as it is typed.
    @ViewBuilder
    private func numberField(_ label: String, value: Binding<Double>, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in apply() }
                .onSubmit { apply() }
        }
    }

    /// A labeled integer field with a stepper, clamped to `range`.
    @ViewBuilder
    private func stepperField(_ label: String, value: Binding<Int>,
                              range: ClosedRange<Int>, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in apply() }
                .onSubmit { apply() }
            Stepper(label, value: value, in: range)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in apply() }
        }
    }

    // MARK: - Scale mode (Int index ↔ ScaleTool.ScaleMode — not Hashable, so no tag)

    /// A 0/1 index view over `model.scaleMode` for the {Uniform, Non-uniform} segmented
    /// control. `ScaleMode` is `Equatable` (not `Hashable`), so it can't be a Picker tag
    /// — this maps the index the segmented control needs to the engine mode the model
    /// stores. 0 ⇒ `.factor` (uniform / original behavior), 1 ⇒ `.nonUniform`.
    /// (`.reference` is a third engine mode not exposed by this 2-way control; selecting
    /// "Uniform" while in `.reference` leaves it as `.factor`, matching the brief.)
    private var scaleModeIndex: Binding<Int> {
        Binding(
            get: { model.scaleMode == .nonUniform ? 1 : 0 },
            set: { model.scaleMode = ($0 == 1) ? .nonUniform : .factor }
        )
    }

    // MARK: - Hatch pattern dropdown (Solid sentinel + the bundled library names)

    /// The Picker tag standing in for "Solid" (no pattern). A real pattern name is its
    /// own tag; this sentinel maps to/from `currentHatchPattern == nil`. Empty-string
    /// can never collide with a parsed pattern name (names are non-empty, upper-cased).
    private static let hatchSolidTag = ""

    /// Every bundled hatch-pattern name, sorted for a stable dropdown order.
    private var hatchPatternNames: [String] {
        HatchPatternLibrary.patterns.keys.sorted()
    }

    /// A selection view over `model.currentHatchPattern` for the pattern dropdown: maps
    /// `nil` (solid) ↔ the `hatchSolidTag` sentinel, and any real name to/from itself.
    private var hatchPatternSelection: Binding<String> {
        Binding(
            get: { model.currentHatchPattern ?? Self.hatchSolidTag },
            set: { model.currentHatchPattern = ($0 == Self.hatchSolidTag) ? nil : $0 }
        )
    }

    /// A degrees view over a radians-backed binding (the UI edits friendlier degrees;
    /// the model stores radians — mirrors the Inspector's `degreesBinding`).
    private func degreesBinding(_ radians: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { radians.wrappedValue * 180 / .pi },
            set: { radians.wrappedValue = $0 * .pi / 180 }
        )
    }

    /// Pushes the bar's config values onto the live tool (so a chained run / preview
    /// honors them) and asks the canvas to redraw. The single side-effect hook every
    /// control calls on change — the one place options flow into behavior.
    private func apply() {
        model.reapplyActiveToolConfig()
        controllerBox.controller?.requestRedraw()
    }
}
