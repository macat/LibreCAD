//
//  QuickSelectPanel.swift
//  LibreCADmacOS
//
//  The "Quick Select" sidebar panel — the GUI surface over the engine-pure
//  `QuickSelect` predicate (CADEngine/QuickSelect.swift). It lets the user build a
//  property FILTER — entity kind, layer, optional color / line width — choose how it
//  COMBINES with the current selection (Replace / Add / Remove / Intersect), preview the
//  resulting match COUNT, and Apply it. This is AutoCAD's QSELECT / LibreCAD's
//  "Select by attributes", surfaced as a modern source-list panel.
//
//  Like the other sidebar panels it is rendered as the BODY of a `SidebarPanel` in the
//  rearrangeable `SidebarPanelStack` (the stack supplies the header; this view supplies
//  the panel's content + a compact header control). It binds to the SAME live
//  `CanvasModel` the canvas renders, so Apply updates the selection live and the canvas
//  repaints the highlight overlay.
//
//  Purity / modal discipline: there is NO modal anywhere here — the filter is built
//  entirely from value-type pickers, and Apply funnels through `model.applyQuickSelect`
//  (a pure, undo-free selection op). Nothing in this view is reachable from the headless
//  test suite (the model method + the engine predicate ARE unit-tested directly).
//
//  Type-check discipline (project gotcha #2): the body is decomposed into many small
//  `@ViewBuilder` / `private var` subviews so SwiftUI never trips the "unable to
//  type-check in reasonable time" trap on the mixed-control form.
//
//  GPLv2-or-later (LibreCAD derivative). Quick-select semantics port AutoCAD QSELECT /
//  LibreCAD select-by-attributes.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

// MARK: - Quick Select header control (Reset)

/// The Quick Select panel's header control: a compact "Reset filter" button that clears
/// the panel's filter back to "match anything". A small reusable view so the panel HEADER
/// can host it; the host supplies the closure so this view stays model-agnostic.
struct QuickSelectHeaderControls: View {
    let onReset: () -> Void

    var body: some View {
        Button(action: onReset) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .help("Reset the Quick Select filter")
    }
}

// MARK: - User-facing kind option (Picker)

/// A Picker option for the Quick Select KIND control: either "Any kind" (no constraint)
/// or one concrete `QuickSelectKind`. `Identifiable`/`Hashable` so it drives a SwiftUI
/// `Picker` cleanly; the user-facing label is a friendly title-cased name.
enum QuickSelectKindOption: Hashable, Identifiable {
    case any
    case kind(QuickSelectKind)

    var id: String {
        switch self {
        case .any:            return "__any__"
        case .kind(let k):    return k.rawValue
        }
    }

    /// The friendly, title-cased label shown in the Picker.
    var label: String {
        switch self {
        case .any:                  return "Any kind"
        case .kind(let k):          return QuickSelectKindOption.displayName(k)
        }
    }

    /// All options in a stable order: "Any" first, then every kind alphabetically by
    /// display name (so the Picker reads predictably).
    static var allOptions: [QuickSelectKindOption] {
        let kinds = QuickSelectKind.allCases
            .sorted { displayName($0) < displayName($1) }
            .map { QuickSelectKindOption.kind($0) }
        return [.any] + kinds
    }

    /// A friendly, title-cased name for a kind tag (e.g. `.mtext` → "MText",
    /// `.splinePoints` → "Spline (Points)").
    static func displayName(_ k: QuickSelectKind) -> String {
        switch k {
        case .point:         return "Point"
        case .line:          return "Line"
        case .circle:        return "Circle"
        case .arc:           return "Arc"
        case .polyline:      return "Polyline"
        case .ellipse:       return "Ellipse"
        case .spline:        return "Spline"
        case .splinePoints:  return "Spline (Points)"
        case .text:          return "Text"
        case .mtext:         return "MText"
        case .hatch:         return "Hatch"
        case .solid:         return "Solid"
        case .dimension:     return "Dimension"
        case .insert:        return "Block Insert"
        case .xline:         return "Construction Line"
        case .ray:           return "Ray"
        case .leader:        return "Leader"
        case .image:         return "Image"
        }
    }
}

// MARK: - The Quick Select panel content (live)

/// The live Quick Select content: kind / layer pickers, an apply-mode control, a match
/// count, and an Apply button. Bound to the live `CanvasModel` so Apply updates the
/// selection immediately and the canvas repaints the highlight overlay.
struct QuickSelectSectionContent: View {
    @Bindable var model: CanvasModel
    /// Bridge to the canvas controller so Apply can request a redraw (the renderer is
    /// on-demand; a selection change must nudge the highlight overlay).
    let controllerBox: CADCanvasView.ControllerBox
    /// A "tick" the panel HEADER's Reset button flips to ask THIS body to clear its
    /// filter. The value is meaningless — only its CHANGE triggers a reset.
    let resetTick: Bool

    /// The chosen kind option ("Any" or a concrete kind).
    @State private var kindOption: QuickSelectKindOption = .any
    /// The chosen layer name, or `nil` for "Any layer".
    @State private var layerName: String?
    /// How the result combines with the existing selection.
    @State private var mode: QuickSelect.ApplyMode = .replace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            kindRow
            layerRow
            Divider()
            modeRow
            matchCountRow
            applyRow
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        // The header's Reset button flips `resetTick`; clear the filter when it changes.
        .onChange(of: resetTick) { _, _ in resetFilter() }
        // If the active layer disappears (undo / external edit) while it was selected,
        // fall back to "Any layer" so the picker never dangles on a removed name.
        .onChange(of: model.modelVersion) { _, _ in pruneLayerSelectionIfStale() }
    }

    // MARK: Filter controls

    /// The KIND picker row: "Any kind" + every selectable kind.
    @ViewBuilder
    private var kindRow: some View {
        labeledRow("Kind") {
            Picker("Kind", selection: $kindOption) {
                ForEach(QuickSelectKindOption.allOptions) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    /// The LAYER picker row: "Any layer" + every layer in the drawing (by name).
    @ViewBuilder
    private var layerRow: some View {
        labeledRow("Layer") {
            Picker("Layer", selection: $layerName) {
                Text("Any layer").tag(String?.none)
                ForEach(model.drawing.layers.layers) { layer in
                    Text(layer.name).tag(String?.some(layer.name))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    // MARK: Mode + count + apply

    /// The APPLY-MODE control (Replace / Add / Remove / Intersect) — a segmented picker.
    @ViewBuilder
    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How to apply")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("How to apply", selection: $mode) {
                Text("Replace").tag(QuickSelect.ApplyMode.replace)
                Text("Add").tag(QuickSelect.ApplyMode.add)
                Text("Remove").tag(QuickSelect.ApplyMode.remove)
                Text("Intersect").tag(QuickSelect.ApplyMode.intersect)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    /// A live "N matching" readout for the current filter (computed against the active
    /// space — the same set Apply would touch). Updates as the pickers change.
    @ViewBuilder
    private var matchCountRow: some View {
        let count = matchCount
        Text(count == 1 ? "1 entity matches" : "\(count) entities match")
            .font(.callout)
            .foregroundStyle(count == 0 ? .secondary : .primary)
    }

    /// The Apply button: funnels the built filter through `model.applyQuickSelect` and
    /// nudges the canvas to repaint the highlight overlay.
    @ViewBuilder
    private var applyRow: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Apply") { apply() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Layout helper

    /// A two-column "label : control" row used by the kind / layer pickers.
    @ViewBuilder
    private func labeledRow<Control: View>(_ label: String,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    // MARK: Derived state

    /// The current filter built from the panel controls. `kinds` is `nil` ("any") unless a
    /// concrete kind is chosen; `layer` is `nil` ("any") unless one is chosen. Color/width
    /// are not exposed in v1 (kind + layer cover the common select-by-attributes case);
    /// they are documented follow-ups (the engine + the model funnel already support them).
    private var currentFilter: QuickSelectFilter {
        var filter = QuickSelectFilter()
        if case .kind(let k) = kindOption { filter.kinds = [k] }
        filter.layer = layerName
        return filter
    }

    /// How many entities the current filter would match (pre-apply preview).
    private var matchCount: Int {
        model.quickSelectMatchIDs(currentFilter).count
    }

    // MARK: Actions

    /// Applies the current filter + mode to the live selection, then asks the canvas to
    /// redraw (the renderer is on-demand; a selection change must nudge the overlay).
    private func apply() {
        if model.applyQuickSelect(currentFilter, mode: mode) {
            controllerBox.controller?.requestRedraw()
        }
    }

    /// Resets the filter to "match anything" (Any kind / Any layer, Replace mode).
    private func resetFilter() {
        kindOption = .any
        layerName = nil
        mode = .replace
    }

    /// Drops a chosen layer name that no longer exists in the drawing (so the Picker never
    /// dangles on a removed layer after an undo / external edit).
    private func pruneLayerSelectionIfStale() {
        if let name = layerName, !model.drawing.layers.contains(name) {
            layerName = nil
        }
    }
}
