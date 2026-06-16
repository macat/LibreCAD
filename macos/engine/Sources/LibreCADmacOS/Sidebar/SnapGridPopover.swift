//
//  SnapGridPopover.swift
//  LibreCADmacOS
//
//  A compact, status-bar-anchored popover (backlog #3) that surfaces the SAME
//  Snap & Grid controls the Inspector hosts, so the drafting modes are reachable
//  WITHOUT opening the inspector: the master object-snap switch, the per-mode
//  object-snap checkboxes, "Show grid", and the grid-spacing field. It binds to
//  the EXISTING `CanvasModel` setters (it invents no snap logic) and intentionally
//  DUPLICATES the inspector's `snapGridSection` bindings — the inspector keeps its
//  own section; a later cleanup can dedupe (see backlog-wave-plan §"InspectorView
//  is touched by NO wave").
//
//  View-layer ONLY: every control is a toggle or a numeric field — there is NO
//  `NSOpenPanel`/`runModal()`/sheet here, so nothing a headless test can reach
//  blocks. The host StatusBar presents it from a gear `Button` via
//  `.popover(isPresented:)`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The Snap & Grid quick-settings popover anchored to the status-bar gear button.
/// Mirrors the inspector's Snap & Grid section: object-snap master + per-mode
/// object-snap toggles + show-grid + grid-spacing, bound to the same model setters.
struct SnapGridPopover: View {
    /// The live canvas state. Bindable so the toggles/field can both reflect and
    /// drive the model's snap/grid flags.
    @Bindable var model: CanvasModel

    /// Repaint the Metal canvas after a grid change (show/hide grid, spacing) —
    /// the canvas does not auto-repaint from `modelVersion`, so we explicitly ask
    /// the controller to redraw, exactly as the inspector's section does. Defaults
    /// to a no-op (previews / tests).
    var requestRedraw: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            objectSnapControls
            Divider()
            gridControls
        }
        .padding(DS.Space.lg)
        .frame(width: 260)
    }

    // MARK: - Object snap

    /// Master OBJECT-snap switch + the per-mode object-snap checkboxes (the same
    /// `gridModes` set the inspector shows), in a 2-column grid so the long labels
    /// (Endpoint…Parallel) don't clip.
    @ViewBuilder
    private var objectSnapControls: some View {
        Text("Object Snap")
            .font(DS.Font.panelTitle)

        Toggle("Object Snap", isOn: objectSnapEnabledBinding)
            .help("Master object-snap toggle (F3) — off = free cursor (no object snap)")

        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: DS.Space.xs) {
            ForEach(Self.snapOptions, id: \.label) { option in
                Toggle(option.label, isOn: snapBinding(option.mode))
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Grid

    /// "Show grid" + the grid-spacing field. Both request a canvas redraw on change
    /// (mirroring the inspector + Document Settings grid tab).
    @ViewBuilder
    private var gridControls: some View {
        Text("Grid")
            .font(DS.Font.panelTitle)

        Toggle("Show grid", isOn: Binding(
            get: { model.gridVisible },
            set: { model.setGridOn($0); requestRedraw() }
        ))

        LabeledContent {
            TextField("", value: Binding(
                get: { model.preferredGridSpacing },
                set: { model.setGridSpacing($0); requestRedraw() }
            ), format: .number)
                .frame(width: DS.Field.narrow)
                .multilineTextAlignment(.trailing)
        } label: {
            Text("Grid spacing")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Bindings (duplicated from InspectorView.snapGridSection by design)

    /// A two-way binding into a single snap-mode bit on the model.
    private func snapBinding(_ mode: SnapMode) -> Binding<Bool> {
        Binding(
            get: { model.isSnapModeOn(mode) },
            set: { model.setSnapMode(mode, $0) }
        )
    }

    /// The master "Object Snap" toggle (AutoCAD OSNAP / F3): GET reports whether any
    /// positive object-snap bit is set; SET stashes+clears them (off) or restores the
    /// stashed/default set (on) via `CanvasModel.setObjectSnapEnabled`.
    private var objectSnapEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.objectSnapEnabled },
            set: { model.setObjectSnapEnabled($0) }
        )
    }

    // MARK: - Snap-mode option list

    /// (label, `SnapMode` bit) pairs for the per-mode object-snap checkboxes. Mirrors
    /// the Inspector's `SnapModeOption.gridModes` (every mode EXCEPT `.free`, the
    /// master), duplicated here because that type is `private` to `InspectorView.swift`
    /// (this popover is its own owned file). The set must stay in sync by convention.
    private struct Option { let label: String; let mode: SnapMode }

    private static let snapOptions: [Option] = [
        Option(label: "Endpoint", mode: .endpoint),
        Option(label: "Midpoint", mode: .middle),
        Option(label: "Center", mode: .center),
        Option(label: "Intersection", mode: .intersection),
        Option(label: "On entity", mode: .onEntity),
        Option(label: "Nearest point", mode: .nearest),
        Option(label: "Perpendicular", mode: .perpendicular),
        Option(label: "Tangent", mode: .tangent),
        Option(label: "Parallel", mode: .parallel),
        Option(label: "Grid", mode: .grid),
    ]
}
