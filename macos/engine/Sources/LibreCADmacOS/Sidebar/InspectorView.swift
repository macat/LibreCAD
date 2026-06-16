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
            // §14 ATTDEF authoring — only while a block is being edited (Block Editor).
            attributeDefsSection
            propertyPainterSection
            snapGridSection
            toolOptionsSection
        }
        .formStyle(.grouped)
        // The host inspector column owns the width (ContentView's
        // `.inspectorColumnWidth`); a self `.frame(minWidth:)` here only fought it.
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
            // Nothing selected: instead of a big decorative empty state, put the prime
            // real estate to work with DRAWING-LEVEL properties (units / counts /
            // extents — §3c "No Selection → drawing-level properties"). The bare
            // "select something" hint only shows when there is genuinely no document.
            drawingPropertiesSection
        case 1:
            singleSelectionEditor(records[0])
        default:
            multiSelectionEditor(records)
        }
    }

    // MARK: Drawing-level properties (shown when nothing is selected)

    /// The drawing-level summary the Inspector shows when no entity is selected — units,
    /// dimension scale, entity + layer counts, and the drawing extents — read from the
    /// live `CADDrawing` via the pure `DrawingSummary`. When the drawing is genuinely
    /// empty (no entities AND only the default layer) we add a tiny one-line hint so a
    /// blank document still tells the user the next move.
    @ViewBuilder
    private var drawingPropertiesSection: some View {
        let summary = DrawingSummary(drawing: model.drawing)
        Section("Drawing") {
            LabeledContent("Units") {
                Text(unitsValue(summary))
                    .font(DS.Font.rowValue)
            }
            .lineLimit(1)

            LabeledContent("Scale") {
                Text("1 : \(formatted(summary.dimScale))")
                    .font(DS.Font.rowValue)
            }
            .lineLimit(1)
            .help("Overall dimension scale ($DIMSCALE) — LibreCAD's only drawing-wide scale")

            LabeledContent("Entities", value: "\(summary.entityCount)")
                .lineLimit(1)

            LabeledContent("Layers", value: "\(summary.layerCount)")
                .lineLimit(1)

            LabeledContent("Extents") {
                Text(extentsValue(summary))
                    .font(DS.Font.rowValue)
            }
            .lineLimit(1)
            .help("Bounding box of all geometry (width × height)")

            if summary.entityCount == 0 {
                Label("Select an entity on the canvas to edit its properties.",
                      systemImage: "cursorarrow")
                    .font(DS.Font.hint)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The "Units" row value — the long name plus the sign in parens (e.g.
    /// "Millimeters (mm)"), or just the name when there is no sign (`.none`).
    private func unitsValue(_ summary: DrawingSummary) -> String {
        summary.unitSign.isEmpty ? summary.unitName
                                 : "\(summary.unitName) (\(summary.unitSign))"
    }

    /// The "Extents" row value: `W × H` in the drawing's unit sign, or "—" when the
    /// drawing has no geometry (`DrawingSummary.extents == nil`).
    private func extentsValue(_ summary: DrawingSummary) -> String {
        guard let e = summary.extents else { return "—" }
        let sign = summary.unitSign.isEmpty ? "" : " \(summary.unitSign)"
        return "\(formatted(e.width)) × \(formatted(e.height))\(sign)"
    }

    /// A compact numeric format for the drawing summary rows (up to 3 fractional
    /// digits, trailing zeros trimmed).
    private func formatted(_ value: Double) -> String {
        let s = String(format: "%.3f", value)
        // Trim trailing zeros (and a dangling dot) so "10.000" reads as "10".
        if s.contains(".") {
            var t = s
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return t
        }
        return s
    }

    // MARK: Single selection

    @ViewBuilder
    private func singleSelectionEditor(_ record: EntityRecord) -> some View {
        Section("Entity") {
            LabeledContent("Kind", value: kindTitle(record.kind)).lineLimit(1)
            LabeledContent("ID", value: "\(record.id.rawValue)").lineLimit(1)
        }

        EntityCommonEditor(
            record: record,
            layerNames: model.drawing.layers.layers.map(\.name),
            onCommit: commit
        )

        GeometryEditor(record: record, onCommit: commit)

        // DB-1W: dynamic-block VISIBILITY STATE picker (block-features §9.4) — a reliable,
        // redundant control alongside the on-canvas dropdown grip. Shown only when the
        // selected entity is an `.insert` whose block carries visibility states; switches
        // the insert's active state through the undoable `setInsertVisibilityState` funnel.
        dynamicInsertSection(record)

        // §14 ATTRIBUTES — the EATTEDIT core. When the selected entity is an `.insert`
        // whose block declares ATTDEF templates, list each attribute's editable VALUE.
        // Values commit through the same undoable record-replace funnel (`commit`).
        attributeValuesSection(record)

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

    // MARK: Dynamic-block visibility state (instance side, §9.4)

    /// The Inspector's dynamic-block visibility-state picker — rendered only when `record`
    /// is an `.insert` whose referenced block declares visibility states. Lets the user pick
    /// the active state (the same thing the on-canvas dropdown grip does, surfaced as a
    /// reliable fallback control). Selecting a state writes the insert's
    /// `activeVisibilityState` through the undoable funnel and repaints.
    @ViewBuilder
    private func dynamicInsertSection(_ record: EntityRecord) -> some View {
        if case .insert(let data) = record.kind,
           let block = model.drawing.blocks.block(named: data.blockName),
           let def = block.dynamic, !def.visibilityStates.isEmpty {
            Section("Dynamic Block") {
                Picker("Visibility State", selection: activeStateBinding(record, def: def)) {
                    ForEach(def.visibilityStates) { state in
                        Text(state.name).tag(state.name)
                    }
                }
                LabeledContent("Block", value: data.blockName).lineLimit(1)
            }
        }
    }

    /// A two-way binding over the selected insert's active visibility state NAME. The GET
    /// resolves `nil` (no explicit state) to the block's DEFAULT (first) state so the picker
    /// always reflects what is drawn (§9.5); the SET routes through the undoable
    /// `setInsertVisibilityState` funnel + a redraw. The SET always writes an EXPLICIT state
    /// name (every picker tag is a `state.name`), so this control never takes the funnel's
    /// `nil`→default-reset branch — writing the default state's name resolves identically.
    /// (The `nil` reset path stays reachable from the engine / future grip affordances.)
    private func activeStateBinding(_ record: EntityRecord, def: DynamicBlockDef) -> Binding<String> {
        Binding(
            get: {
                if case .insert(let d) = record.kind,
                   let active = d.dynamic?.activeVisibilityState,
                   def.visibilityState(named: active) != nil {
                    return active
                }
                return def.defaultVisibilityState?.name ?? ""
            },
            set: { newName in
                if model.setInsertVisibilityState(record.id, to: newName) {
                    requestRedraw()
                }
            }
        )
    }

    // MARK: Block attributes — VALUE editor (§14, EATTEDIT core)

    /// The Inspector's block-attribute VALUE editor — rendered only when `record` is an
    /// `.insert` whose referenced block declares `attributeDefs`. Each def's value is
    /// editable (constant-mode defs are read-only); a typed value commits an updated
    /// `.insert` record through the undoable `commit` funnel + a redraw.
    @ViewBuilder
    private func attributeValuesSection(_ record: EntityRecord) -> some View {
        if case .insert(let data) = record.kind,
           let block = model.drawing.blocks.block(named: data.blockName),
           !block.attributeDefs.isEmpty {
            BlockAttributeValuesEditor(
                record: record,
                defs: block.attributeDefs,
                onCommit: commit)
            .id(record.id)   // re-seed the editor's drafts when the selection changes
        }
    }

    // MARK: Block attributes — ATTDEF authoring (§14, Block Editor)

    /// The ATTDEF authoring panel — rendered only while a block is being edited
    /// (`model.isEditingBlock`). Lets the user add / edit / remove the EDITING block's
    /// attribute definitions through the undoable def-CRUD ops on the drawing, then
    /// redraws (placeholder ATTDEF text re-resolves; existing inserts pick the defs up
    /// via the user's "Sync Attributes" action / next ATTSYNC).
    @ViewBuilder
    private var attributeDefsSection: some View {
        if let blockName = model.editingBlock,
           let block = model.drawing.blocks.block(named: blockName) {
            BlockAttributeDefsEditor(
                defs: block.attributeDefs,
                onAdd: { def in
                    let ok = model.drawing.addBlockAttributeDef(block: blockName, def)
                    if ok { requestRedraw() }
                    return ok
                },
                onUpdate: { def in
                    if model.drawing.updateBlockAttributeDef(block: blockName, def) {
                        requestRedraw()
                    }
                },
                onRemove: { tag in
                    model.drawing.removeBlockAttributeDef(block: blockName, tag: tag)
                    requestRedraw()
                })
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

            LabeledContent {
                TextField("",
                          value: $model.preferredGridSpacing,
                          format: .number)
                    .frame(width: DS.Field.narrow)
                    .multilineTextAlignment(.trailing)
            } label: {
                // The wrap-to-"Spaci\nng" bug: keep the label on ONE line and let it
                // size to its content so it never folds (§3c confirmed bug).
                Text("Grid spacing")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
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
                    LabeledContent {
                        TextField("", value: degreesBinding($model.arrayPolarTotalAngle),
                                  format: .number)
                            .frame(width: DS.Field.narrow).multilineTextAlignment(.trailing)
                            .onSubmit { reapplyTool() }
                    } label: {
                        Text("Total angle (°)").lineLimit(1)
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
                LabeledContent {
                    TextField("Annotation", text: $model.leaderText)
                        .frame(width: DS.Field.wide)
                        .onSubmit { reapplyTool() }
                        .onChange(of: model.leaderText) { _, _ in reapplyTool() }
                } label: {
                    Text("Text").lineLimit(1)
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
        LabeledContent {
            TextField(label, value: value, format: .number)
                .frame(width: DS.Field.std).multilineTextAlignment(.trailing)
                .onSubmit(onCommit)
                .onChange(of: value.wrappedValue) { _, _ in onCommit() }
        } label: {
            Text(label).lineLimit(1)
        }
    }

    @ViewBuilder
    private func intRow(_ label: String, _ value: Binding<Int>,
                        onCommit: @escaping () -> Void) -> some View {
        LabeledContent {
            TextField(label, value: value, format: .number)
                .frame(width: DS.Field.std).multilineTextAlignment(.trailing)
                .onSubmit(onCommit)
                .onChange(of: value.wrappedValue) { _, _ in onCommit() }
        } label: {
            Text(label).lineLimit(1)
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
