//
//  StatusBar.swift
//  LibreCADmacOS
//
//  The persistent bottom STATUS BAR (UX-plan U3, gaps G3 / G4 / G6) — a slim,
//  always-on strip that tells the user, at a glance: what mode/tool they are in and
//  what step it expects (the verb prompt), where the cursor is (unit-aware absolute
//  X/Y + the relative offset + the live distance/angle while drawing), what the
//  cursor is snapped to, the current zoom, and (Wave 4) the live CAD drafting modes
//  as a right-aligned cluster of CLICKABLE toggles (GRID / SNAP / ORTHO) that mirror
//  the F-keys. It replaces the transient corner HUD chips (`coordinateHUD` /
//  `toolPromptHUD`) with a single persistent readout.
//
//  ## Layout
//    [ Tool: step — ⮐ Finish · ⌫ Undo point · esc Cancel ] … [ X / Y · @Δx,Δy · ⟂d ∠a ] | [ Snap ] | [ ⊕ zoom% ] [ GRID SNAP ORTHO ]
//  Left  = `model.toolStepReadout` + always-on verb hints (so the keyboard verbs
//          are discoverable — gap G4).
//  Center= the unit-aware coordinate readouts (`model.cursorReadout` /
//          `relativeReadout` / `distanceAngleReadout`), formatted by the engine's
//          pure `CoordinateFormatter` from the document's units/precision (G6).
//  Right = the active snap mode (`model.snapReadout`) · zoom % (`model.zoomPercent`)
//          · the clickable mode toggles. Segments are separated by fixed-height
//          `Divider`s (`DS.Size.barDivider`) so the readout never runs together.
//
//  ## The clickable mode toggles (Wave 4, plan §3d)
//  A right-aligned cluster of borderless toggles that fill `DS.Palette.accent` when ON,
//  each wired to the EXISTING model state + its F-key handler — they SURFACE existing
//  state, they do NOT invent new snap logic:
//    • GRID  (F7)  → `model.gridVisible`       via `model.toggleGrid()`
//    • SNAP  (F9)  → grid-snap (`.grid` bit)   via `model.toggleGridSnap()`
//    • ORTHO (F8)  → `model.orthoEnabled`      via `model.toggleOrtho()`
//    • OSNAP (F3)  → `model.objectSnapEnabled` via `model.setObjectSnapEnabled(!…)`
//    • POLAR (F10) → `model.polarEnabled`      via `model.togglePolar()`
//  (OSNAP + POLAR became real status flags in backlog Phase 0 — #7.) Ortho/polar
//  mutual exclusion is handled in the model; the chips just reflect state. The
//  detailed per-osnap list also lives in the Inspector's Snap & Grid section and in
//  this bar's gear `.popover` (`SnapGridPopover`, backlog #3) — the chips are the
//  at-a-glance/F-key surface; the gear is the full quick-settings surface.
//
//  ## Coexistence with U1's command line
//  This bar is hosted by ContentView ABOVE the U1 command-line `safeAreaInset`
//  (added with a higher z-order / stacked inset), so the two stack cleanly: the
//  status readout sits just over the command field. The toggle buttons are the only
//  focusable controls; the readouts are read-only.
//
//  ## Styling (HIG, light + dark)
//  Routed through the shared `.barStrip(dividerEdge:.top)` primitive (so its padding /
//  material / divider match the command line + every other `.bar` strip), with the
//  `.bar` material + semantic foreground styles so it inverts correctly in both
//  appearances. Monospaced digits (`DS.Font.rowValue`) keep the coordinate + zoom
//  readouts from jittering as values change.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The persistent bottom status bar. Reads the live `CanvasModel` derived readouts
/// (all pure, engine-formatted) and lays them out left / center / right, ending in
/// the clickable GRID / SNAP / ORTHO toggle cluster.
struct StatusBar: View {
    /// The live canvas state (cursor, snap, tool, viewport, drafting modes). Bindable
    /// so the toggle cluster can both reflect and drive the model's mode flags.
    @Bindable var model: CanvasModel

    /// Repaint the Metal canvas after a mode toggle. The canvas does NOT auto-repaint
    /// from `modelVersion` — every sibling control explicitly asks the controller to
    /// redraw (the F-key/menu paths call `redraw()`, the LayoutTabStrip calls back into
    /// `requestRedraw`). The status chips mirror that: a GRID click must hide/show the
    /// grid immediately, not on the next mouse nudge. The host wires this to
    /// `controllerBox.controller?.requestRedraw`; defaults to a no-op (e.g. previews).
    var requestRedraw: () -> Void = {}

    /// Whether the Snap & Grid quick-settings popover (the gear button, backlog #3)
    /// is shown. View-local presentation state only.
    @State private var showSnapGridPopover = false

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            // Left-most: the relocated document status (name + unit) — backlog #4a.
            docStatusSegment

            Divider().frame(height: DS.Size.barDivider)

            // Left: active tool + step prompt + verb hints (gap G3 / G4).
            toolSegment

            Spacer(minLength: DS.Space.md)

            // Center: the unit-aware coordinate readouts (gap G6).
            coordinateSegment

            Divider().frame(height: DS.Size.barDivider)

            // Right: snap mode · zoom · the clickable mode toggles.
            snapSegment
            Divider().frame(height: DS.Size.barDivider)
            zoomSegment
            Divider().frame(height: DS.Size.barDivider)
            modeToggles
            snapGridGear
        }
        .font(DS.Font.rowLabel)
        .lineLimit(1)
        .barStrip(dividerEdge: .top)
        // The readouts are read-only telemetry; the toggle buttons are the only
        // focusable controls. Contain so VoiceOver can reach the buttons while the
        // readouts read as combined elements.
        .accessibilityElement(children: .contain)
    }

    // MARK: - Segments

    /// The relocated document status (backlog #4a) — the old canvas "New drawing (mm)"
    /// label, moved to the status bar's left edge. There is no model-level document
    /// DISPLAY NAME available here (the file title lives in the document/window chrome,
    /// not on `CanvasModel`), so this surfaces what the model DOES expose: the drawing's
    /// unit, as `<short> · <long-name>` (e.g. "mm · Millimeters"), falling back to
    /// "Unitless" for the `.none` unit. The window title bar already shows the file name.
    private var docStatusSegment: some View {
        Label {
            Text(docStatusText)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Document units \(docStatusText)")
    }

    /// The unit description shown in the doc-status segment: `"mm · Millimeters"` when a
    /// sign exists, else just the long name (e.g. "Unitless" for `.none`).
    private var docStatusText: String {
        let unit = model.drawing.graphicVariables.unit
        let name = DrawingSummary.displayName(for: unit)
        return unit.sign.isEmpty ? name : "\(unit.sign) \u{00B7} \(name)"
    }

    /// Active tool + current step, plus the always-on keyboard verb hints (only while
    /// a tool is active — in select mode the verbs don't apply).
    private var toolSegment: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: model.isToolActive ? "pencil.tip" : "cursorarrow")
                .foregroundStyle(model.isToolActive ? DS.Palette.accent : .secondary)
            Text(model.toolStepReadout)
                .foregroundStyle(.primary)
            if model.isToolActive {
                Text("\u{23CE} Finish \u{00B7} \u{232B} Undo point \u{00B7} esc Cancel")
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Absolute X/Y (unit-aware) + the relative `@Δx,Δy` and live distance/angle
    /// while a tool has placed a reference point. A neutral placeholder when the
    /// cursor is outside the canvas, so the segment never collapses to nothing.
    ///
    /// Click-to-toggle (backlog #5): the readout was read-only telemetry; it is now a
    /// borderless `Button` that cycles the coordinate display mode
    /// (absolute → relative → polar) via the model's existing
    /// `cycleCoordinateDisplayMode()`, then repaints. The visible text already switches
    /// (the model's `cursorReadout` reflects `coordinateDisplayMode`); the a11y
    /// label/value name the ACTIVE mode so the (formerly silent) readout stays legible
    /// to VoiceOver.
    private var coordinateSegment: some View {
        Button {
            model.cycleCoordinateDisplayMode()
            requestRedraw()
        } label: {
            coordinateReadout
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Coordinate mode: \(coordinateModeName) — click to cycle (absolute / relative / polar)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coordinate display mode")
        .accessibilityValue("\(coordinateModeName). \(model.cursorReadout ?? "no coordinate")")
        .accessibilityHint("Cycles absolute, relative, polar")
        .accessibilityAddTraits(.isButton)
    }

    /// The bare coordinate text content (absolute / relative / distance-angle), shared
    /// by the click-to-cycle button label. A neutral placeholder when the cursor is
    /// outside the canvas, so the segment never collapses to nothing.
    @ViewBuilder
    private var coordinateReadout: some View {
        HStack(spacing: DS.Space.lg) {
            if let abs = model.cursorReadout {
                Text(abs)
                    .font(DS.Font.rowValue)
                    .foregroundStyle(.primary)
                if let rel = model.relativeReadout {
                    Text(rel)
                        .font(DS.Font.rowValue)
                        .foregroundStyle(.secondary)
                }
                if let da = model.distanceAngleReadout {
                    Text(da)
                        .font(DS.Font.rowValue)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\u{2014}")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Human-readable name of the active coordinate display mode (for a11y + help).
    private var coordinateModeName: String {
        switch model.coordinateDisplayMode {
        case .absolute: return "Absolute"
        case .relative: return "Relative"
        case .polar:    return "Polar"
        }
    }

    /// The active snap mode (what the cursor is bound to right now).
    private var snapSegment: some View {
        Label(model.snapReadout, systemImage: "scope")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Snap \(model.snapReadout)")
    }

    /// The zoom percentage, with a leading SF Symbol so it labels consistently with
    /// the snap segment (both readouts carry a glyph — plan §3d StatusBar labeling).
    private var zoomSegment: some View {
        Label {
            Text("\(model.zoomPercent)%")
                .font(DS.Font.rowValue)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityLabel("Zoom \(model.zoomPercent) percent")
    }

    // MARK: - Clickable mode toggles (GRID / SNAP / ORTHO)

    /// The right-aligned cluster of borderless mode toggles. Each fills
    /// `DS.Palette.accent` when ON and calls the model's existing toggle (the same one
    /// the F-key / menu fires) THEN asks the canvas to repaint (the canvas does not
    /// auto-repaint from `modelVersion`), so clicking here is identical to pressing the
    /// F-key — including the immediate visual update.
    private var modeToggles: some View {
        HStack(spacing: DS.Space.xs) {
            modeToggle(title: "GRID", isOn: model.gridVisible,
                       help: "Grid (F7)") { model.toggleGrid(); requestRedraw() }
            modeToggle(title: "SNAP", isOn: model.gridSnapEnabled,
                       help: "Grid snap (F9)") { model.toggleGridSnap(); requestRedraw() }
            modeToggle(title: "ORTHO", isOn: model.orthoEnabled,
                       help: "Ortho (F8)") { model.toggleOrtho(); requestRedraw() }
            // OSNAP (F3) — master object-snap, now a real status flag (backlog #7).
            modeToggle(title: "OSNAP", isOn: model.objectSnapEnabled,
                       help: "Object snap (F3)") {
                model.setObjectSnapEnabled(!model.objectSnapEnabled); requestRedraw()
            }
            // POLAR (F10) — polar tracking; ortho/polar mutual exclusion is handled in
            // the model's `togglePolar` (the chip just reflects state) (backlog #7).
            modeToggle(title: "POLAR", isOn: model.polarEnabled,
                       help: "Polar tracking (F10)") { model.togglePolar(); requestRedraw() }
            // DYN (F12) — dynamic input (live dimensional feedback while drawing). Mirrors
            // the AutoCAD DYNMODE toggle; `toggleDynamicInput` flips + persists the pref and
            // the canvas mount reads `dynamicInputEnabled` to show/suppress the overlay.
            modeToggle(title: "DYN", isOn: model.dynamicInputEnabled,
                       help: "Dynamic input — live dimensions (F12)") {
                model.toggleDynamicInput(); requestRedraw()
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// One borderless mode toggle: a short uppercase label in a `DS.Radius.selection`
    /// pill, filled with solid `accent` (`onAccent` text) when ON and transparent
    /// (secondary text) when OFF.
    @ViewBuilder
    private func modeToggle(title: String,
                            isOn: Bool,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Font.secondaryLabel.weight(.medium))
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, DS.Space.xxs)
                .foregroundStyle(isOn ? DS.Palette.onAccent : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.selection)
                        .fill(isOn ? DS.Palette.accent : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.selection))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Snap & Grid gear popover (backlog #3)

    /// A gear button that presents the `SnapGridPopover` — the same object-snap /
    /// per-mode / show-grid / grid-spacing controls the inspector hosts, reachable
    /// without opening the sidebar. View-layer presentation only (no modal in logic).
    private var snapGridGear: some View {
        Button {
            showSnapGridPopover.toggle()
        } label: {
            Image(systemName: "gearshape")
                .foregroundStyle(showSnapGridPopover ? DS.Palette.accent : Color.secondary)
                .padding(.horizontal, DS.Space.xs)
                .padding(.vertical, DS.Space.xxs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Snap & grid settings")
        .accessibilityLabel("Snap and grid settings")
        .popover(isPresented: $showSnapGridPopover, arrowEdge: .top) {
            SnapGridPopover(model: model, requestRedraw: requestRedraw)
        }
    }
}
