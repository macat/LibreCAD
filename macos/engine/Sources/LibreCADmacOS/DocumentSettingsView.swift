//
//  DocumentSettingsView.swift
//  LibreCADmacOS
//
//  The per-document Document Settings sheet (V4 — owner directive: "add a document
//  settings page"). Presented via File ▸ Document Settings… (⌥⌘, — decision D8;
//  plain ⌘, is reserved for a future app-level Preferences). Built to the spec in
//  macos/docs/ux-plan.md Part 3 and decisions D3/D4/D5/D8 in the decision log.
//
//  These are PER-DOCUMENT values that belong to the drawing (units, precision,
//  grid/snap, dimension defaults, layer defaults, paper), NOT app preferences. They
//  are stored on `CADDrawing.graphicVariables` (the DXF-round-tripping header-var
//  bag) so they travel with the file (Save→Open). Snap modes — which have no
//  standard DXF header var — persist via the private `$LC_SNAPMODE` var (D5).
//
//  ## Apply model (D3 — live-apply + Done)
//  Every control writes IMMEDIATELY to the model (like macOS System Settings and the
//  app's own Inspector), and each edit is ONE undoable step (the value-snapshot
//  pattern, via `CanvasModel`'s settings setters → `CADDrawing.mutateGraphicVariables`).
//  The sheet's "Done" button just dismisses — there is no Apply/Cancel transaction.
//
//  ## Dimension defaults (D4)
//  The Dimensions tab edits the document dimension style (`$DIMTXT`/`$DIMASZ`/
//  `$DIMSCALE`/`$DIMLUNIT`/`$DIMDEC`). At resolve time these feed the
//  `ResolveContext.dimStyleProvider` hook so a dimension WITHOUT a per-entity
//  override picks them up; per-entity values still win when set (>0).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The Document Settings sheet — a tabbed editor over the focused window's
/// `CanvasModel`/`CADDrawing`. Bindings route every edit through the model's
/// live-apply + undoable setters (D3), so closing the sheet keeps every change and
/// each field is independently undoable with ⌘Z.
struct DocumentSettingsView: View {
    /// The live canvas model (model + drawing + viewport). Owned by the window; the
    /// sheet binds to it so edits apply immediately and round-trip via the document.
    let model: CanvasModel
    /// The host controller box, so a setting that changes what the canvas draws
    /// (grid on/off + spacing) can request an immediate redraw.
    let controllerBox: CADCanvasView.ControllerBox
    /// Dismiss action for the Done button.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                UnitsSettingsTab(model: model)
                    .tabItem { Label("Units", systemImage: "ruler") }
                GridSnapSettingsTab(model: model, controllerBox: controllerBox)
                    .tabItem { Label("Grid & Snap", systemImage: "grid") }
                DimensionsSettingsTab(model: model, controllerBox: controllerBox)
                    .tabItem { Label("Dimensions", systemImage: "arrow.left.and.right") }
                LayersSettingsTab(model: model)
                    .tabItem { Label("Layers", systemImage: "square.3.layers.3d") }
                PaperSettingsTab(model: model)
                    .tabItem { Label("Paper", systemImage: "doc") }
            }
            .padding(.top, 8)

            Divider()
            HStack {
                Spacer()
                // D3: live-apply, so Done just dismisses (no Apply/Cancel).
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 420)
    }
}

// MARK: - Units tab (P0)

/// Drawing unit, linear format + precision, angle format + precision, angle
/// base/direction. All write to the `$INSUNITS`/`$LUNITS`/`$LUPREC`/`$AUNITS`/
/// `$AUPREC`/`$ANGBASE`/`$ANGDIR` header vars (live-apply + undoable).
private struct UnitsSettingsTab: View {
    let model: CanvasModel

    var body: some View {
        Form {
            Section("Drawing unit") {
                Picker("Unit", selection: Binding(
                    get: { model.drawing.graphicVariables.unit },
                    set: { model.setDrawingUnit($0) }
                )) {
                    ForEach(DrawingUnit.allCases, id: \.self) { u in
                        Text(u.settingsLabel).tag(u)
                    }
                }
            }

            Section("Linear") {
                Picker("Format", selection: Binding(
                    get: { model.drawing.graphicVariables.linearFormat },
                    set: { model.setLinearFormat($0) }
                )) {
                    ForEach(LinearFormat.allCases, id: \.self) { f in
                        Text(f.settingsLabel).tag(f)
                    }
                }
                Stepper(value: Binding(
                    get: { model.drawing.graphicVariables.linearPrecision },
                    set: { model.setLinearPrecision($0) }
                ), in: 0...8) {
                    Text("Precision: \(model.drawing.graphicVariables.linearPrecision)")
                }
            }

            Section("Angle") {
                Picker("Format", selection: Binding(
                    get: { model.drawing.graphicVariables.angleFormat },
                    set: { model.setAngleFormat($0) }
                )) {
                    ForEach(AngleFormat.allCases, id: \.self) { f in
                        Text(f.settingsLabel).tag(f)
                    }
                }
                Stepper(value: Binding(
                    get: { model.drawing.graphicVariables.anglePrecision },
                    set: { model.setAnglePrecision($0) }
                ), in: 0...8) {
                    Text("Precision: \(model.drawing.graphicVariables.anglePrecision)")
                }
                // $ANGBASE is stored in radians; edit in degrees for the user.
                LabeledContent("Base angle") {
                    TextField("degrees", value: Binding(
                        get: { model.drawing.graphicVariables.anglesBase * 180 / .pi },
                        set: { model.setAngleBaseDegrees($0) }
                    ), format: .number)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                }
                Picker("Direction", selection: Binding(
                    get: { model.drawing.graphicVariables.anglesCounterClockwise },
                    set: { model.setAnglesCounterClockwise($0) }
                )) {
                    Text("Counter-clockwise").tag(true)
                    Text("Clockwise").tag(false)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Grid & Snap tab (P0)

/// Grid on/off (`$GRIDMODE` ↔ `gridVisible`), grid spacing (`$GRIDUNIT` ↔
/// `preferredGridSpacing`), and the default snap-mode set (persisted via
/// `$LC_SNAPMODE`, D5). Changing the grid requests a canvas redraw.
private struct GridSnapSettingsTab: View {
    let model: CanvasModel
    let controllerBox: CADCanvasView.ControllerBox

    var body: some View {
        Form {
            Section("Grid") {
                Toggle("Show grid", isOn: Binding(
                    get: { model.gridVisible },
                    set: { model.setGridOn($0); controllerBox.controller?.requestRedraw() }
                ))
                LabeledContent("Spacing") {
                    TextField("world units", value: Binding(
                        get: { model.preferredGridSpacing },
                        set: { model.setGridSpacing($0); controllerBox.controller?.requestRedraw() }
                    ), format: .number)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                }
            }

            Section("Snap modes") {
                ForEach(SnapSettingOption.all, id: \.label) { option in
                    Toggle(option.label, isOn: Binding(
                        get: { model.isSnapModeOn(option.mode) },
                        set: { model.setSnapMode(option.mode, $0) }
                    ))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dimensions tab (P0)

/// Document-default dimension style: text height (`$DIMTXT`), arrow size
/// (`$DIMASZ`), overall scale (`$DIMSCALE`), and the measurement-text linear unit
/// (`$DIMLUNIT`) + precision (`$DIMDEC`). These feed the `dimStyleProvider` hook so
/// dimensions without per-entity overrides use them (D4).
private struct DimensionsSettingsTab: View {
    let model: CanvasModel
    let controllerBox: CADCanvasView.ControllerBox

    var body: some View {
        Form {
            Section("Default dimension style") {
                numberRow("Text height",
                          value: model.drawing.graphicVariables.dimTextHeight) { model.setDimTextHeight($0) }
                numberRow("Arrow size",
                          value: model.drawing.graphicVariables.dimArrowSize) { model.setDimArrowSize($0) }
                numberRow("Overall scale",
                          value: model.drawing.graphicVariables.dimScale) { model.setDimScale($0) }
            }

            Section("Measurement text") {
                Picker("Linear format", selection: Binding(
                    get: { model.drawing.graphicVariables.dimLinearFormat },
                    set: { model.setDimLinearFormat($0) }
                )) {
                    ForEach(LinearFormat.allCases, id: \.self) { f in
                        Text(f.settingsLabel).tag(f)
                    }
                }
                Stepper(value: Binding(
                    get: { model.drawing.graphicVariables.dimLinearPrecision },
                    set: { model.setDimLinearPrecision($0) }
                ), in: 0...8) {
                    Text("Precision: \(model.drawing.graphicVariables.dimLinearPrecision)")
                }
            }
        }
        .formStyle(.grouped)
        // A dimension's drawn size depends on these defaults, so redraw on change.
        .onDisappear { controllerBox.controller?.requestRedraw() }
    }

    /// A right-aligned numeric field row (world-unit values) that live-applies. The
    /// current `value` is read by the caller (so the get side stays on the main
    /// actor in the view body); `set` writes it and requests a canvas redraw.
    @ViewBuilder
    private func numberRow(_ title: String, value: Double,
                           set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(
                get: { value },
                set: { set($0); controllerBox.controller?.requestRedraw() }
            ), format: .number)
            .frame(width: 90)
            .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Layers tab (lighter)

/// Defaults a NEW layer is born with (color / line width / line type — app policy,
/// consumed by `LayersSidebar.addLayer`). The active layer is shown read-only for
/// orientation (it is set in the sidebar).
private struct LayersSettingsTab: View {
    let model: CanvasModel
    @State private var color: Color = .green

    var body: some View {
        Form {
            Section("New-layer defaults") {
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                    .onChange(of: color) { _, newValue in
                        model.defaultLayerColor = newValue.rgbaColor
                    }
                Picker("Line width", selection: Binding(
                    get: { LineWidthChoice(model.defaultLineWidth) },
                    set: { model.defaultLineWidth = $0.penLineWidth }
                )) {
                    ForEach(LineWidthChoice.all, id: \.self) { w in
                        Text(w.label).tag(w)
                    }
                }
                Picker("Line type", selection: Binding(
                    get: { model.defaultLineType },
                    set: { model.defaultLineType = $0 }
                )) {
                    Text("Solid").tag(PenLineType.solid)
                    Text("Dashed").tag(PenLineType.dashed)
                    Text("Dotted").tag(PenLineType.dotted)
                    Text("Dash-dot").tag(PenLineType.dashDot)
                    Text("Center").tag(PenLineType.center)
                    Text("Border").tag(PenLineType.border)
                    Text("Divide").tag(PenLineType.divide)
                }
            }
            Section("Current") {
                LabeledContent("Active layer", value: model.drawing.layers.activeLayerName)
            }
        }
        .formStyle(.grouped)
        .onAppear { color = Color(rgba: model.defaultLayerColor) }
    }
}

// MARK: - Paper tab (lighter)

/// Paper size + orientation (used to pre-fill Print/Export) and the paper insertion
/// base (`$PINSBASE`). Paper size/orientation are app-side print defaults stored on
/// the model; the insertion base round-trips via the header var.
private struct PaperSettingsTab: View {
    let model: CanvasModel

    var body: some View {
        Form {
            Section("Paper") {
                Picker("Size", selection: Binding(
                    get: { model.paperSize },
                    set: { model.paperSize = $0 }
                )) {
                    ForEach(PaperSize.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                Picker("Orientation", selection: Binding(
                    get: { model.paperLandscape },
                    set: { model.paperLandscape = $0 }
                )) {
                    Text("Portrait").tag(false)
                    Text("Landscape").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Section("Insertion base") {
                LabeledContent("X") {
                    TextField("x", value: Binding(
                        get: { model.drawing.graphicVariables.paperInsertionBase.x },
                        set: { model.setPaperInsertionBase(
                            Vector($0, model.drawing.graphicVariables.paperInsertionBase.y)) }
                    ), format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
                }
                LabeledContent("Y") {
                    TextField("y", value: Binding(
                        get: { model.drawing.graphicVariables.paperInsertionBase.y },
                        set: { model.setPaperInsertionBase(
                            Vector(model.drawing.graphicVariables.paperInsertionBase.x, $0)) }
                    ), format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Paper size (app-side print/export default)

/// The preferred paper size for Print/Export (a Document Settings default stored on
/// the `CanvasModel`). Carries the millimeter dimensions so the printer/exporter can
/// pre-fill the page; LibreCAD's standard ISO/US sheet sizes.
enum PaperSize: String, Sendable, CaseIterable, Hashable {
    case a4, a3, a2, a1, a0, letter, legal, tabloid

    /// (width, height) in millimeters, portrait.
    var sizeMM: (width: Double, height: Double) {
        switch self {
        case .a4:      return (210, 297)
        case .a3:      return (297, 420)
        case .a2:      return (420, 594)
        case .a1:      return (594, 841)
        case .a0:      return (841, 1189)
        case .letter:  return (215.9, 279.4)
        case .legal:   return (215.9, 355.6)
        case .tabloid: return (279.4, 431.8)
        }
    }

    var label: String {
        switch self {
        case .a4: return "A4"
        case .a3: return "A3"
        case .a2: return "A2"
        case .a1: return "A1"
        case .a0: return "A0"
        case .letter: return "Letter"
        case .legal: return "Legal"
        case .tabloid: return "Tabloid"
        }
    }
}

// MARK: - Snap-mode option list (sheet-local; mirrors the Inspector's set)

/// The snap modes the settings sheet exposes (label + the `SnapMode` bit). A local
/// copy of the Inspector's list so the two surfaces stay decoupled.
private struct SnapSettingOption {
    let label: String
    let mode: SnapMode

    static let all: [SnapSettingOption] = [
        SnapSettingOption(label: "Endpoint", mode: .endpoint),
        SnapSettingOption(label: "Midpoint", mode: .middle),
        SnapSettingOption(label: "Center", mode: .center),
        SnapSettingOption(label: "Intersection", mode: .intersection),
        SnapSettingOption(label: "On entity", mode: .onEntity),
        SnapSettingOption(label: "Nearest point", mode: .nearest),
        SnapSettingOption(label: "Perpendicular", mode: .perpendicular),
        SnapSettingOption(label: "Tangent", mode: .tangent),
        SnapSettingOption(label: "Parallel", mode: .parallel),
        SnapSettingOption(label: "Grid", mode: .grid),
        SnapSettingOption(label: "Free (no snap)", mode: .free),
    ]
}

// MARK: - Line-width choice (a Hashable picker proxy over PenLineWidth)

/// A small, `Hashable` proxy over `PenLineWidth` for the layer-defaults picker
/// (the engine enum has an associated value, so it needs a discrete choice set).
private enum LineWidthChoice: Hashable {
    case byDefault
    case mm(Double)

    init(_ w: PenLineWidth) {
        if case .millimeters(let v) = w { self = .mm(v) } else { self = .byDefault }
    }

    var penLineWidth: PenLineWidth {
        switch self {
        case .byDefault: return .default
        case .mm(let v): return .millimeters(v)
        }
    }

    var label: String {
        switch self {
        case .byDefault: return "Default"
        case .mm(let v): return String(format: "%.2g mm", v)
        }
    }

    /// The common line-width choices the picker offers (LibreCAD's standard widths).
    static let all: [LineWidthChoice] = [
        .byDefault, .mm(0.13), .mm(0.18), .mm(0.25), .mm(0.35),
        .mm(0.50), .mm(0.70), .mm(1.00), .mm(2.00),
    ]
}

// MARK: - Display-name helpers (sheet-local labels for the engine enums)

private extension DrawingUnit {
    /// A friendly settings label, e.g. "Millimeter (mm)".
    var settingsLabel: String {
        let name: String
        switch self {
        case .none: name = "None"
        case .inch: name = "Inch"
        case .foot: name = "Foot"
        case .mile: name = "Mile"
        case .millimeter: name = "Millimeter"
        case .centimeter: name = "Centimeter"
        case .meter: name = "Meter"
        case .kilometer: name = "Kilometer"
        case .microinch: name = "Microinch"
        case .mil: name = "Mil"
        case .yard: name = "Yard"
        case .angstrom: name = "Angstrom"
        case .nanometer: name = "Nanometer"
        case .micron: name = "Micron"
        case .decimeter: name = "Decimeter"
        case .decameter: name = "Decameter"
        case .hectometer: name = "Hectometer"
        case .gigameter: name = "Gigameter"
        case .astro: name = "Astronomical unit"
        case .lightyear: name = "Lightyear"
        case .parsec: name = "Parsec"
        }
        let s = sign
        return s.isEmpty ? name : "\(name) (\(s))"
    }
}

private extension LinearFormat {
    var settingsLabel: String {
        switch self {
        case .scientific: return "Scientific"
        case .decimal: return "Decimal"
        case .engineering: return "Engineering"
        case .architectural: return "Architectural"
        case .fractional: return "Fractional"
        case .architecturalMetric: return "Architectural (metric)"
        }
    }
}

private extension AngleFormat {
    var settingsLabel: String {
        switch self {
        case .degreesDecimal: return "Decimal degrees"
        case .degreesMinutesSeconds: return "Degrees / minutes / seconds"
        case .gradians: return "Gradians"
        case .radians: return "Radians"
        case .surveyors: return "Surveyor's units"
        }
    }
}
