//
//  InspectorView.swift
//  LibreCADmacOS
//
//  The modern-Mac Inspector — a trailing pane (the NavigationSplitView
//  `.inspector`) that shows the SELECTED entity's properties and lets the user
//  edit them, plus snap/grid controls and the active tool's options.
//
//  It binds DIRECTLY to the live `CanvasModel` the canvas renders (and through it
//  the `@Observable CADDrawing`), so:
//    - geometry / common-attribute edits flow through `model.applyInspectorEdits`
//      (a full-record `.replace`, undoable via the window `UndoManager` — ADR-002),
//    - text font/style edits flow through `model.applyTextStyleEdit` (upserts a
//      `TextStyle` + repoints the entity, one undo step), so bold/italic actually
//      render through the resolve path,
//    - snap-mode toggles drive `model.snapModes` (read by `updateSnap`),
//    - tool-option edits store into `model.*` and re-apply onto the live tool.
//
//  Every edit then nudges the on-demand Metal renderer to redraw (the same
//  render-sync dance `LayersSidebar` documents): an inspector edit may not be seen
//  by the renderer until its model buffer is rebuilt, so we mark the model dirty,
//  bump the version, and ask the canvas controller to redraw.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import AppKit
import CADEngine

// MARK: - Inspector pane

/// The trailing inspector: an entity property editor (when a selection exists),
/// snap/grid controls, and the active tool's options. Bound to the same
/// `CanvasModel` the canvas renders so edits reflect live and undo via ⌘Z.
struct InspectorView: View {
    /// The live canvas state — the SAME instance the detail-pane canvas renders.
    @Bindable var model: CanvasModel

    /// Bridge to the canvas controller so an edit can request a redraw (the Metal
    /// renderer is on-demand; an inspector edit must nudge it).
    let controllerBox: CADCanvasView.ControllerBox

    var body: some View {
        Form {
            selectionSection
            propertyPainterSection
            snapGridSection
            toolOptionsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 260, idealWidth: 300)
    }

    // MARK: Selection-driven editors

    /// The selected ids, resolved against the live drawing (dropping any that have
    /// since been removed). Recomputed each render so it tracks selection + edits.
    private var selectedRecords: [EntityRecord] {
        model.selection.ids.compactMap { model.drawing.entity($0) }
    }

    @ViewBuilder
    private var selectionSection: some View {
        let records = selectedRecords
        switch records.count {
        case 0:
            Section("Selection") {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "cursorarrow.rays",
                    description: Text("Select an entity on the canvas to edit its properties.")
                )
                .frame(maxWidth: .infinity)
            }
        case 1:
            singleSelectionEditor(records[0])
        default:
            multiSelectionEditor(records)
        }
    }

    // MARK: Single selection

    @ViewBuilder
    private func singleSelectionEditor(_ record: EntityRecord) -> some View {
        Section("Entity") {
            LabeledContent("Kind", value: kindTitle(record.kind))
            LabeledContent("ID", value: "\(record.id.rawValue)")
        }

        EntityCommonEditor(
            record: record,
            layerNames: model.drawing.layers.layers.map(\.name),
            onCommit: commit
        )

        GeometryEditor(record: record, onCommit: commit)

        // The font/style editor — the user-facing payoff of the font system.
        switch record.kind {
        case .text, .mtext:
            TextStyleEditor(
                record: record,
                strokeFontNames: strokeFontNames(),
                resolvedStyle: resolvedStyle(for: record),
                onStyleCommit: commitTextStyle,
                onKindCommit: { id, kind in commit([replacingKind(record, kind)]) }
            )
        default:
            EmptyView()
        }
    }

    // MARK: Multi selection (common fields only)

    @ViewBuilder
    private func multiSelectionEditor(_ records: [EntityRecord]) -> some View {
        Section("Selection") {
            LabeledContent("Entities", value: "\(records.count) selected")
        }
        // Common fields that apply to ALL: layer + pen color/mode/type/width. Each
        // picker writes the chosen value onto every selected record in one undo step;
        // a "Reset Pen to Layer" action routes through the painter path.
        MultiCommonEditor(
            records: records,
            layerNames: model.drawing.layers.layers.map(\.name),
            onCommitAll: commit,
            onResetPenToLayer: {
                if model.resetSelectionPenToLayer() { requestRedraw() }
            }
        )
    }

    // MARK: Property painter (F20 — match properties / eyedropper)

    /// The property-painter controls: pick up pen + layer from the current single
    /// selection (the brush), then apply it to a later selection. Always visible so
    /// the affordance is discoverable; the buttons enable/disable on context (one
    /// entity to pick up; a brush loaded + a selection to apply). Routes entirely
    /// through `CanvasModel`'s undoable painter ops.
    @ViewBuilder
    private var propertyPainterSection: some View {
        Section("Property Painter") {
            LabeledContent("Brush") {
                Text(model.hasPaintBrush ? "Loaded" : "Empty")
                    .foregroundStyle(model.hasPaintBrush ? .primary : .secondary)
            }
            Button("Pick Up Properties") {
                _ = model.loadPaintBrushFromSelection()
            }
            .disabled(model.selection.ids.count != 1)
            .help("Copy the selected entity's pen + layer into the brush")

            Button("Apply to Selection") {
                if model.applyPaintBrushToSelection() { requestRedraw() }
            }
            .disabled(!model.hasPaintBrush || model.selection.isEmpty)
            .help("Stamp the brush's pen + layer onto every selected entity")

            Button("Reset Pen to Layer") {
                if model.resetSelectionPenToLayer() { requestRedraw() }
            }
            .disabled(model.selection.isEmpty)
            .help("Make the selection inherit each layer's pen again")
        }
    }

    // MARK: Snap & grid

    @ViewBuilder
    private var snapGridSection: some View {
        Section("Snap & Grid") {
            Toggle("Show grid", isOn: $model.gridVisible)
                .onChange(of: model.gridVisible) { _, _ in requestRedraw() }

            LabeledContent("Grid spacing") {
                TextField("Spacing",
                          value: $model.preferredGridSpacing,
                          format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            ForEach(SnapModeOption.all, id: \.label) { option in
                Toggle(option.label, isOn: snapBinding(option.mode))
            }
        }
    }

    /// A two-way binding into a single snap-mode bit on the model.
    private func snapBinding(_ mode: SnapMode) -> Binding<Bool> {
        Binding(
            get: { model.isSnapModeOn(mode) },
            set: { model.setSnapMode(mode, $0) }
        )
    }

    // MARK: Active tool options

    @ViewBuilder
    private var toolOptionsSection: some View {
        switch model.activeToolKind {
        case .fillet:
            Section("Fillet Options") {
                numberRow("Radius", $model.filletRadius) { reapplyTool() }
            }
        case .chamfer:
            Section("Chamfer Options") {
                numberRow("Distance 1", $model.chamferDistance1) { reapplyTool() }
                numberRow("Distance 2", $model.chamferDistance2) { reapplyTool() }
            }
        case .array:
            Section("Array Options") {
                Picker("Type", selection: $model.arrayPolar) {
                    Text("Rectangular").tag(false)
                    Text("Polar").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.arrayPolar) { _, _ in reapplyTool() }

                if model.arrayPolar {
                    intRow("Count", $model.arrayPolarCount) { reapplyTool() }
                    LabeledContent("Total angle") {
                        TextField("Degrees", value: degreesBinding($model.arrayPolarTotalAngle),
                                  format: .number)
                            .frame(width: 80).multilineTextAlignment(.trailing)
                            .onSubmit { reapplyTool() }
                    }
                    Toggle("Rotate items", isOn: $model.arrayPolarRotateItems)
                        .onChange(of: model.arrayPolarRotateItems) { _, _ in reapplyTool() }
                } else {
                    intRow("Rows", $model.arrayRows) { reapplyTool() }
                    intRow("Columns", $model.arrayCols) { reapplyTool() }
                    numberRow("Row spacing", $model.arraySpacingY) { reapplyTool() }
                    numberRow("Column spacing", $model.arraySpacingX) { reapplyTool() }
                }
            }
        case .divide:
            Section("Divide Options") {
                intRow("Pieces", $model.divideCount) { reapplyTool() }
            }

        // MARK: Wire-wave-3 configurable tools

        case .align:
            Section("Align Options") {
                Toggle("Scale to fit", isOn: $model.alignScaleToFit)
                    .onChange(of: model.alignScaleToFit) { _, _ in reapplyTool() }
            }
        case .arrayPath:
            Section("Array Along Path Options") {
                intRow("Count", $model.arrayPathCount) { reapplyTool() }
                Toggle("Align to path", isOn: $model.arrayPathAlignToTangent)
                    .onChange(of: model.arrayPathAlignToTangent) { _, _ in reapplyTool() }
            }
        case .leader:
            Section("Leader Options") {
                LabeledContent("Text") {
                    TextField("Annotation", text: $model.leaderText)
                        .frame(width: 140)
                        .onSubmit { reapplyTool() }
                        .onChange(of: model.leaderText) { _, _ in reapplyTool() }
                }
                numberRow("Text height", $model.leaderTextHeight) { reapplyTool() }
            }
        case .baselineDim:
            Section("Baseline Dimension Options") {
                numberRow("Spacing", $model.baselineSpacing) { reapplyTool() }
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Small row builders

    @ViewBuilder
    private func numberRow(_ label: String, _ value: Binding<Double>,
                           onCommit: @escaping () -> Void) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .number)
                .frame(width: 90).multilineTextAlignment(.trailing)
                .onSubmit(onCommit)
                .onChange(of: value.wrappedValue) { _, _ in onCommit() }
        }
    }

    @ViewBuilder
    private func intRow(_ label: String, _ value: Binding<Int>,
                        onCommit: @escaping () -> Void) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .number)
                .frame(width: 90).multilineTextAlignment(.trailing)
                .onSubmit(onCommit)
                .onChange(of: value.wrappedValue) { _, _ in onCommit() }
        }
    }

    /// A degrees view over a radians-backed binding (UI is friendlier in degrees).
    private func degreesBinding(_ radians: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { radians.wrappedValue * 180 / .pi },
            set: { radians.wrappedValue = $0 * .pi / 180 }
        )
    }

    // MARK: - Commit helpers (route through CanvasModel + nudge the renderer)

    /// Applies full-record inspector edits as one undoable group, then redraws.
    private func commit(_ records: [EntityRecord]) {
        model.applyInspectorEdits(records)
        requestRedraw()
    }

    /// Applies a text font/style edit (style upsert + entity repoint), then redraws.
    private func commitTextStyle(_ id: EntityID, _ kind: EntityKind, _ style: TextStyle?) {
        model.applyTextStyleEdit(id, kind: kind, upserting: style)
        requestRedraw()
    }

    /// Re-applies the active tool's options onto the live tool, then redraws (so a
    /// preview that depends on the option, e.g. fillet radius, updates).
    private func reapplyTool() {
        model.reapplyActiveToolConfig()
        requestRedraw()
    }

    /// Marks the model dirty + bumps the version so the renderer re-resolves and
    /// repacks, then asks the on-demand canvas to redraw (see the file header /
    /// the same dance in `LayersSidebar`).
    private func requestRedraw() {
        model.modelDirty = true
        model.modelVersion &+= 1
        controllerBox.controller?.requestRedraw()
    }

    /// A copy of `record` with its geometry swapped to `kind` (id/layer/pen kept).
    private func replacingKind(_ record: EntityRecord, _ kind: EntityKind) -> EntityRecord {
        var r = record
        r.kind = kind
        return r
    }

    // MARK: - Read helpers

    /// The text style a TEXT/MTEXT entity currently resolves to (its `styleName`
    /// against the document STYLE table, falling back to "Standard"). Drives the
    /// font picker's current selection + the bold/italic toggles.
    private func resolvedStyle(for record: EntityRecord) -> TextStyle {
        let name: String?
        switch record.kind {
        case .text(let d):  name = d.styleName
        case .mtext(let d): name = d.styleName
        default:            name = nil
        }
        let key = name ?? TextStyleTable.standardName
        return model.drawing.textStyles.style(named: key) ?? model.drawing.textStyles.standard
    }

    /// The `.lff` stroke font base names the document already knows about (the
    /// STYLE table's stroke entries) plus the always-present "standard".
    private func strokeFontNames() -> [String] {
        var names = Set<String>(["standard"])
        for style in model.drawing.textStyles.styles.values {
            if case .stroke(let lff) = style.primaryFont, !lff.isEmpty {
                names.insert(lff)
            }
        }
        return names.sorted()
    }

    /// A short, human-readable kind name for the read-only "Kind" row.
    private func kindTitle(_ kind: EntityKind) -> String {
        switch kind {
        case .point:        return "Point"
        case .line:         return "Line"
        case .circle:       return "Circle"
        case .arc:          return "Arc"
        case .polyline:     return "Polyline"
        case .ellipse:      return "Ellipse"
        case .spline:       return "Spline"
        case .splinePoints: return "Spline (points)"
        case .text:         return "Text"
        case .mtext:        return "MText"
        case .hatch:        return "Hatch"
        case .solid:        return "Solid"
        case .dimension:    return "Dimension"
        case .insert:       return "Block reference"
        case .xline:        return "Construction line"
        case .ray:          return "Ray"
        case .leader:       return "Leader"
        case .image:        return "Image"
        }
    }
}

// MARK: - Snap-mode option list

/// The snap modes the Inspector exposes as toggles (label + the `SnapMode` bit).
private struct SnapModeOption {
    let label: String
    let mode: SnapMode

    static let all: [SnapModeOption] = [
        SnapModeOption(label: "Endpoint", mode: .endpoint),
        SnapModeOption(label: "Midpoint", mode: .middle),
        SnapModeOption(label: "Center", mode: .center),
        SnapModeOption(label: "Intersection", mode: .intersection),
        SnapModeOption(label: "On entity", mode: .onEntity),
        SnapModeOption(label: "Nearest point", mode: .nearest),
        SnapModeOption(label: "Perpendicular", mode: .perpendicular),
        SnapModeOption(label: "Tangent", mode: .tangent),
        SnapModeOption(label: "Parallel", mode: .parallel),
        SnapModeOption(label: "Grid", mode: .grid),
        SnapModeOption(label: "Free (no snap)", mode: .free),
    ]
}
