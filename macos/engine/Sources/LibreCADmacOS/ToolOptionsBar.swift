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
             .fillet, .chamfer, .array, .divide:
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
            Picker("Fit", selection: $model.polygonFit) {
                Text("Inscribed").tag(PolygonFit.inscribed)
                Text("Circumscribed").tag(PolygonFit.circumscribed)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.polygonFit) { _, _ in apply() }

        case .rectangle:
            numberField("Width", value: $model.rectWidth, width: 70)
            numberField("Height", value: $model.rectHeight, width: 70)
            Text("0 = drag two corners")
                .font(.caption).foregroundStyle(.tertiary)

        case .circle:
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

        case .arc:
            Picker("Mode", selection: $model.arcMode) {
                Text("Center, Start, End").tag(ArcCreationMode.centerStartEnd)
                Text("3 Points").tag(ArcCreationMode.threePoint)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: model.arcMode) { _, _ in apply() }

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

        default:
            EmptyView()
        }
    }

    // MARK: - Small control builders (compact, inline — sized for a single row)

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
