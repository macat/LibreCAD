//
//  InspectorSummaries.swift
//  LibreCADmacOS
//
//  Pure value summaries the Inspector renders when there is NO entity selection,
//  plus the Match-Properties availability predicate. Kept here as side-effect-free
//  value types over `CADEngine` types (a `CADDrawing` in, a struct out) so they
//  unit-test headlessly — no SwiftUI, no GPU, no live view — through the
//  `_SharedInspectorSummaries.swift` symlink (mirrors the project's
//  `_Shared*.swift` convention; see `InspectorSummaryTests`).
//
//  ## Why these live apart from the view
//  Wave 3 of the UI redesign (see `macos/docs/ui-redesign-plan.md` §3c) replaces the
//  Inspector's big "No Selection" empty state with DRAWING-LEVEL properties (units,
//  entity count, layer count, extents) and renames the Property-Painter section to
//  "Match Properties", collapsing it to one hint when no action is available. The
//  arithmetic behind both (which counts to show, which buttons to enable, the status
//  word) is the part a regression would actually break, so it is extracted into pure
//  functions the view merely formats.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CADEngine

// MARK: - Drawing-level summary (the "No Selection" → "Drawing" section)

/// A compact, read-only summary of the WHOLE drawing — what the Inspector shows when
/// nothing is selected, so the prime real estate of the empty pane carries useful
/// document facts instead of a decorative placeholder. Pure value: derived once from a
/// `CADDrawing` snapshot via `init(drawing:)`; the view just reads its fields.
///
/// `extents` is `nil` when the drawing has no geometry (an empty `AABB`), so the view
/// can show "—" rather than the `±∞` sentinel `CADDrawing.boundingBox()` returns.
struct DrawingSummary: Equatable {
    /// Short unit sign, e.g. `"mm"` / `"\""`. Empty for the `.none` unit.
    let unitSign: String
    /// A longer human name for the unit, e.g. `"Millimeters"` — for the row VALUE.
    let unitName: String
    /// The `$DIMSCALE` overall dimension scale (LibreCAD's only drawing-wide scale).
    let dimScale: Double
    /// Total entity count across all spaces (model + paper).
    let entityCount: Int
    /// Model-space-only entity count (what a plain drawing's "entities" means).
    let modelEntityCount: Int
    /// Number of layers in the layer table.
    let layerCount: Int
    /// The drawing's overall bounding box, or `nil` when there is no geometry.
    let extents: Extents?

    /// A drawing's overall extent, in world units (min/max corners + size). A flat
    /// value mirror of `CADEngine.AABB` so the summary stays a plain `Equatable` value
    /// the view formats without touching engine geometry types.
    struct Extents: Equatable {
        let minX, minY, maxX, maxY: Double
        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
    }

    /// Summarize a drawing for the empty-selection inspector. Reads only public
    /// `CADDrawing` accessors; performs no mutation. `@MainActor` because `CADDrawing`
    /// is main-actor-isolated (the inspector view + tests already run there).
    @MainActor
    init(drawing: CADDrawing) {
        let unit = drawing.graphicVariables.unit
        self.unitSign = unit.sign
        self.unitName = DrawingSummary.displayName(for: unit)
        self.dimScale = drawing.graphicVariables.dimScale
        self.entityCount = drawing.count
        self.modelEntityCount = drawing.entities.lazy.filter { $0.space == .model }.count
        self.layerCount = drawing.layers.layers.count

        let box = drawing.boundingBox()
        if box.isEmpty {
            self.extents = nil
        } else {
            self.extents = Extents(minX: box.min.x, minY: box.min.y,
                                   maxX: box.max.x, maxY: box.max.y)
        }
    }

    /// A human-readable name for a `DrawingUnit` (the engine exposes only `.sign` and
    /// the Swift case name; this app-layer map supplies the long form for the inspector
    /// value, falling back to "Unitless" for `.none`).
    static func displayName(for unit: DrawingUnit) -> String {
        switch unit {
        case .none:        return "Unitless"
        case .inch:        return "Inches"
        case .foot:        return "Feet"
        case .mile:        return "Miles"
        case .millimeter:  return "Millimeters"
        case .centimeter:  return "Centimeters"
        case .meter:       return "Meters"
        case .kilometer:   return "Kilometers"
        case .microinch:   return "Microinches"
        case .mil:         return "Mils"
        case .yard:        return "Yards"
        case .angstrom:    return "Angstroms"
        case .nanometer:   return "Nanometers"
        case .micron:      return "Microns"
        case .decimeter:   return "Decimeters"
        case .decameter:   return "Decameters"
        case .hectometer:  return "Hectometers"
        case .gigameter:   return "Gigameters"
        case .astro:       return "Astronomical units"
        case .lightyear:   return "Light-years"
        case .parsec:      return "Parsecs"
        }
    }
}

// MARK: - Match Properties availability (the renamed Property Painter)

/// The enable/disable + status state of the Inspector's "Match Properties" section,
/// derived purely from whether a brush is loaded and how many entities are selected.
/// Keeping it a value lets the view stay declarative (enable each button off a flag,
/// collapse to one hint when nothing is actionable) and lets a test assert the exact
/// truth table without a live model.
///
/// Mirrors AutoCAD's MATCHPROP: PICK UP needs exactly one source entity; APPLY needs a
/// loaded brush AND at least one target; RESET needs at least one target.
struct MatchPropertiesAvailability: Equatable {
    /// Whether a brush (a picked-up pen + layer) is currently loaded.
    let hasBrush: Bool
    /// Number of currently selected entities.
    let selectionCount: Int

    init(hasBrush: Bool, selectionCount: Int) {
        self.hasBrush = hasBrush
        self.selectionCount = selectionCount
    }

    /// "Pick Up" is enabled only with EXACTLY one source entity (the brush copies one
    /// entity's pen + layer).
    var canPickUp: Bool { selectionCount == 1 }

    /// "Apply" is enabled when a brush is loaded AND at least one target is selected.
    var canApply: Bool { hasBrush && selectionCount > 0 }

    /// "Reset Pen to Layer" is enabled when at least one target is selected.
    var canReset: Bool { selectionCount > 0 }

    /// True when NO action is available — the view collapses to a single hint line
    /// instead of three greyed-out buttons.
    var isAllUnavailable: Bool { !canPickUp && !canApply && !canReset }

    /// The brush status word for the "Source:" line — "Loaded" once a brush is picked
    /// up, "Empty" before that.
    var statusWord: String { hasBrush ? "Loaded" : "Empty" }

    /// The single hint shown when nothing is actionable — tells the user the one move
    /// that unlocks the section (select a source entity to pick up from).
    var unavailableHint: String {
        "Select one entity to pick up its properties, then select others to apply."
    }
}
