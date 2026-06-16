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
//      • Divide    → pieces
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
            HStack(spacing: 14) {
                // A leading label so the bar reads as "<Tool> options".
                Label(model.activeToolKind.title, systemImage: "slider.horizontal.3")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)

                Divider().frame(height: 16)

                optionControls

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
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
             // Wire-wave-3 configurable tools.
             .align, .arrayPath, .leader, .baselineDim,
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
            stepperField("Sides", value: $model.polygonSides, range: 3...64, width: 56)
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
                numberField("Ratio", value: $model.polygonStarRatio, width: 60)
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
                            value: $model.rectCornerSize, width: 64)
            }
            Divider().frame(height: 16)
            numberField("Width", value: $model.rectWidth, width: 70)
            numberField("Height", value: $model.rectHeight, width: 70)
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
                numberField("Amount", value: $model.trimAmount, width: 70)
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
            // Construction mode: Center+Radius (the original two-click flow), 2-Point
            // (diameter endpoints), or 3-Point (circumcircle). Fixed at construction, so
            // applyToolConfig RE-MINTS on change.
            Picker("Mode", selection: $model.circleConstructionMode) {
                Text("Center, Radius").tag(CircleConstructionMode.centerRadius)
                Text("2 Points").tag(CircleConstructionMode.twoPoint)
                Text("3 Points").tag(CircleConstructionMode.threePoint)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.circleConstructionMode) { _, _ in apply() }
            // The size mode + exact-size entry only label/scale the NUMERIC entry on the
            // center+radius path (orthogonal to the construction mode), so show them only
            // for that mode (the 2-/3-point modes are pick-defined, no numeric size).
            if model.circleConstructionMode == .centerRadius {
                Divider().frame(height: 16)
                Picker("Size", selection: $model.circleSizeMode) {
                    Text("Radius").tag(CircleSizeMode.radius)
                    Text("Diameter").tag(CircleSizeMode.diameter)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                .onChange(of: model.circleSizeMode) { _, _ in apply() }
                numberField(model.circleSizeMode == .diameter ? "Diameter" : "Radius",
                            value: $model.circleFixedSize, width: 70)
                Text("0 = drag radius")
                    .font(.caption).foregroundStyle(.tertiary)
            }

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
                numberField("Angle°", value: degreesBinding($model.lineAngle), width: 70)
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
            numberField("Height", value: $model.textHeight, width: 70)

        // MARK: Edit / modify tools (mirrored from the Inspector)

        case .fillet:
            numberField("Radius", value: $model.filletRadius, width: 70)

        case .chamfer:
            numberField("Distance 1", value: $model.chamferDistance1, width: 70)
            numberField("Distance 2", value: $model.chamferDistance2, width: 70)

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
                stepperField("Count", value: $model.arrayPolarCount, range: 2...360, width: 56)
                numberField("Angle°", value: degreesBinding($model.arrayPolarTotalAngle), width: 64)
                Toggle("Rotate", isOn: $model.arrayPolarRotateItems)
                    .toggleStyle(.checkbox)
                    .onChange(of: model.arrayPolarRotateItems) { _, _ in apply() }
            } else {
                stepperField("Rows", value: $model.arrayRows, range: 1...1000, width: 52)
                stepperField("Cols", value: $model.arrayCols, range: 1...1000, width: 52)
                numberField("Row sp.", value: $model.arraySpacingY, width: 64)
                numberField("Col sp.", value: $model.arraySpacingX, width: 64)
            }

        case .divide:
            stepperField("Pieces", value: $model.divideCount, range: 2...1000, width: 56)

        // MARK: Wire-wave-3 configurable tools

        case .align:
            Toggle("Scale to fit", isOn: $model.alignScaleToFit)
                .toggleStyle(.checkbox)
                .onChange(of: model.alignScaleToFit) { _, _ in apply() }

        case .arrayPath:
            stepperField("Count", value: $model.arrayPathCount, range: 1...1000, width: 56)
            Toggle("Align to path", isOn: $model.arrayPathAlignToTangent)
                .toggleStyle(.checkbox)
                .onChange(of: model.arrayPathAlignToTangent) { _, _ in apply() }

        case .leader:
            textField("Text", value: $model.leaderText, width: 160)
            numberField("Height", value: $model.leaderTextHeight, width: 64)

        case .baselineDim:
            numberField("Spacing", value: $model.baselineSpacing, width: 70)

        // MARK: Block Insert — scale / rotation / MINSERT array
        case .insert:
            insertScaleControls
            Divider().frame(height: 16)
            numberField("Rotation°", value: degreesBinding($model.insertRotation), width: 70)
            Divider().frame(height: 16)
            insertArrayControls

        default:
            EmptyView()
        }
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
                    value: $model.insertScaleX, width: 64)
        if !model.insertScaleUniform {
            numberField("Scale Y", value: $model.insertScaleY, width: 64)
        }
    }

    /// The Insert tool's MINSERT ARRAY controls: rows × cols and their world-unit
    /// spacing. Default 1×1 / zero spacing ⇒ a plain single insert.
    @ViewBuilder
    private var insertArrayControls: some View {
        stepperField("Rows", value: $model.insertRows, range: 1...1000, width: 52)
        stepperField("Cols", value: $model.insertCols, range: 1...1000, width: 52)
        numberField("Row sp.", value: $model.insertRowSpacing, width: 64)
        numberField("Col sp.", value: $model.insertColSpacing, width: 64)
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
