//
//  PenPickers.swift
//  LibreCADmacOS
//
//  Reusable SwiftUI pickers for the two pen attributes that have a small fixed
//  vocabulary — line TYPE (the dash pattern) and line WIDTH (the lineweight) —
//  shared by every surface that SETS them: the per-layer defaults in the Layers
//  sidebar (`LayerRow`) and the top-bar current-properties control
//  (`CurrentPropertiesBar`). Keeping one pair of pickers means the two surfaces
//  offer the exact same vocabulary and stay in sync.
//
//  These views are engine-pure in spirit: they speak only `CADEngine` value types
//  (`PenLineType` / `PenLineWidth`) through plain SwiftUI `Binding`s, so they carry
//  no knowledge of the document, the model, or undo. The owner wires the binding to
//  whatever it wants mutated (a layer's default via `mutateLayers`, or the model's
//  `currentPen`).
//
//  The `.byLayer` / `.byBlock` sentinels are CONTEXT-DEPENDENT, so each picker takes
//  flags for which sentinels to offer:
//   - the per-layer pickers EXCLUDE `.byLayer`/`.byBlock` (a layer can't defer its
//     own default to itself), and the width picker offers `.default` (the drawing's
//     default lineweight) plus the concrete millimetre steps;
//   - the current-pen pickers INCLUDE `.byLayer` (the AutoCAD CELTYPE/CELWEIGHT
//     default — new geometry inherits from its layer) and a concrete set.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

// MARK: - Line TYPE picker

/// A `Picker` over the `PenLineType` dash patterns. `selection` is a plain binding
/// to a `PenLineType`; the owner decides where the chosen value goes. The displayed
/// option set is controlled by `includeByLayer` / `includeByBlock` so the same view
/// serves both a layer default (no sentinels) and the current pen (ByLayer).
struct LineTypePicker: View {
    @Binding var selection: PenLineType
    /// Offer the "By Layer" sentinel (current-pen surface). Default: yes.
    var includeByLayer: Bool = true
    /// Offer the "By Block" sentinel. Default: no (rarely set interactively).
    var includeByBlock: Bool = false
    /// The picker's leading label; pass "" for a labels-hidden compact placement.
    var label: String = "Line type"

    var body: some View {
        Picker(label, selection: $selection) {
            if includeByLayer {
                Text("By Layer").tag(PenLineType.byLayer)
            }
            if includeByBlock {
                Text("By Block").tag(PenLineType.byBlock)
            }
            ForEach(Self.concreteCases, id: \.self) { lt in
                Text(Self.displayName(lt)).tag(lt)
            }
        }
    }

    /// The concrete (non-sentinel) dash patterns, in the order LibreCAD lists them.
    static let concreteCases: [PenLineType] = [
        .solid, .dashed, .dotted, .dashDot, .center, .border, .divide,
    ]

    /// A user-facing name for a `PenLineType`.
    static func displayName(_ lt: PenLineType) -> String {
        switch lt {
        case .byLayer:  return "By Layer"
        case .byBlock:  return "By Block"
        case .solid:    return "Solid"
        case .dashed:   return "Dashed"
        case .dotted:   return "Dotted"
        case .dashDot:  return "Dash-Dot"
        case .center:   return "Center"
        case .border:   return "Border"
        case .divide:   return "Divide"
        }
    }
}

// MARK: - Line WIDTH picker

/// A `Picker` over the standard lineweights (millimetres) plus the context
/// sentinels. `selection` is a plain binding to a `PenLineWidth`. The width vocabulary
/// is the ISO/DXF lineweight ladder LibreCAD ships; the owner controls whether the
/// `.byLayer` sentinel is offered.
struct LineWidthPicker: View {
    @Binding var selection: PenLineWidth
    /// Offer the "By Layer" sentinel (current-pen surface). Default: yes.
    var includeByLayer: Bool = true
    /// Offer the "By Block" sentinel. Default: no.
    var includeByBlock: Bool = false
    /// Offer the drawing-default lineweight option. Default: yes.
    var includeDefault: Bool = true
    /// The picker's leading label; pass "" for a labels-hidden compact placement.
    var label: String = "Line width"

    var body: some View {
        Picker(label, selection: $selection) {
            if includeByLayer {
                Text("By Layer").tag(PenLineWidth.byLayer)
            }
            if includeByBlock {
                Text("By Block").tag(PenLineWidth.byBlock)
            }
            if includeDefault {
                Text("Default").tag(PenLineWidth.default)
            }
            ForEach(Self.standardMillimeters, id: \.self) { mm in
                Text(Self.millimeterLabel(mm)).tag(PenLineWidth.millimeters(mm))
            }
        }
    }

    /// The standard lineweight ladder (mm) — the ISO/DXF set LibreCAD offers.
    static let standardMillimeters: [Double] = [
        0.00, 0.05, 0.09, 0.13, 0.15, 0.18, 0.20, 0.25, 0.30, 0.35,
        0.40, 0.50, 0.53, 0.60, 0.70, 0.80, 0.90, 1.00, 1.06, 1.20,
        1.40, 1.58, 2.00, 2.11,
    ]

    /// A user-facing label for a millimetre width (e.g. "0.25 mm").
    static func millimeterLabel(_ mm: Double) -> String {
        String(format: "%.2f mm", mm)
    }

    /// A user-facing name for any `PenLineWidth` (used by surfaces that show the
    /// current value as text rather than re-deriving it).
    static func displayName(_ w: PenLineWidth) -> String {
        switch w {
        case .byLayer:            return "By Layer"
        case .byBlock:            return "By Block"
        case .default:            return "Default"
        case .millimeters(let m): return millimeterLabel(m)
        }
    }
}
