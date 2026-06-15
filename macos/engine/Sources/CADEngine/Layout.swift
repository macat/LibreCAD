//
//  Layout.swift
//  CADEngine
//
//  Paper space / layouts — Phase 0 data model (macos/docs/paperspace-plan.md §2).
//
//  The app is model-space-implicit end to end; paper space is ADDITIVE. This file
//  carries the two engine-side foundations:
//
//   • `EntitySpace` — the per-entity "which space" tag (model vs paper). Maps 1:1
//     to the DXF code 67 / `*Paper_Space` block / LAYOUT (the DXF round-trip is a
//     later phase). An `EntityRecord` carries this as an additive struct field
//     (NOT an `EntityKind` case — viewports come later as a separate list — so the
//     ~28 exhaustive `EntityKind` switches are untouched).
//
//   • `Layout` — one named paper sheet in the drawing's layout table
//     (`CADDrawing.layouts`). Model space stays IMPLICIT (it is never an entry in
//     `layouts`). Each layout owns an engine-level page descriptor (paper size /
//     margin / plot scale) expressed in PLAIN engine values: `CADEngine` must NOT
//     depend on the app module, so this deliberately does NOT reference the app's
//     `PrintLayout.PageSetup` / `PaperSize` (those live in `LibreCADmacOS`). The
//     app layer converts to/from `PrintLayout` in a later phase (P4).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

// MARK: - Per-entity space (DXF code 67 / *Paper_Space / LAYOUT)

/// Which "space" an entity lives in — model space (the implicit world drawing) or
/// paper space (a printed sheet / layout). The value-type port of the DXF code-67
/// "in paper space" flag. Defaulting to `.model` keeps every existing drawing
/// unchanged: a record with no explicit space (and every old saved file, which has
/// no space key at all) is model-space.
///
/// `RawRepresentable` over `UInt8` (0 == model, 1 == paper) so it serializes
/// compactly and maps directly to the DXF flag (0/1) when the DXF bridge learns to
/// read/write it (a later phase). NOT an `EntityKind` case — see the file header.
public enum EntitySpace: UInt8, Sendable, Hashable, Codable, CaseIterable {
    /// The implicit world drawing (DXF code 67 == 0). The default for every entity.
    case model = 0
    /// A printed sheet / layout (DXF code 67 == 1). The entity also names WHICH
    /// sheet via `EntityRecord.layoutName`.
    case paper = 1
}

// MARK: - Per-layout plot scale (engine-level)

/// How a layout's model geometry is scaled onto its paper sheet — the engine-level
/// plot-scale descriptor.
///
/// Named `LayoutPlotScale` (NOT `PlotScale`) on purpose: the app module already has
/// its own `PrintLayout.PlotScale` (`.fit` / `.oneToOne` / `.custom`), and the
/// engine must stay app-independent (it cannot reference that type). Keeping a
/// DISTINCT name avoids a cross-module collision; the app layer converts between
/// the two in a later phase (P4).
///
/// - `.fit`: scale-to-fit the printable area (AutoCAD "Fit to paper" / "Scaled to
///   Fit"). The concrete factor is computed at plot time against the sheet — it is
///   not stored.
/// - `.ratio(Double)`: a fixed drawing-units-per-paper-unit plot scale (e.g. `1`
///   for 1:1, `0.01` for 1:100, `50` for 50:1). Must be finite and positive;
///   `fixed(_:)` clamps a non-positive / non-finite value to `1` so a corrupt
///   stored value can never produce a degenerate scale.
public enum LayoutPlotScale: Sendable, Hashable, Codable {
    /// Scale-to-fit the printable area; the factor is derived at plot time.
    case fit
    /// A fixed plot scale (drawing units per paper unit). Always finite + positive.
    case ratio(Double)

    /// Builds a fixed-ratio scale, clamping a non-positive / non-finite `value` to
    /// `1` (1:1). Use `.fit` directly for scale-to-fit.
    public static func fixed(_ value: Double) -> LayoutPlotScale {
        .ratio((value.isFinite && value > 0) ? value : 1)
    }

    /// The concrete factor for a `.ratio`, or `nil` for `.fit` (which has no stored
    /// factor — it is computed against the sheet at plot time).
    public var ratioValue: Double? {
        if case .ratio(let v) = self { return v } else { return nil }
    }
}

// MARK: - The engine-level page descriptor

/// A layout's paper geometry — the engine-level page descriptor (the app's
/// `PrintLayout.PageSetup` analogue, kept here as plain engine values so
/// `CADEngine` does not depend on the app module). All linear values are in
/// MILLIMETERS (Doubles); the app layer converts to/from `PrintLayout` /
/// `PaperSize` later (P4).
///
/// Defaults describe an ISO A4 portrait sheet with a 10 mm margin, scaled to fit —
/// a sensible "new layout" page that needs no DXF/PLOTSETTINGS to be valid.
public struct PageDescriptor: Sendable, Hashable, Codable {
    /// Paper width in millimeters (the printable medium's width). A4 == 210.
    public var widthMM: Double
    /// Paper height in millimeters. A4 portrait == 297.
    public var heightMM: Double
    /// Uniform page margin in millimeters (the unprintable border inset on all
    /// sides). The plotted area is the paper inset by this on each edge.
    public var marginMM: Double
    /// How model geometry is scaled onto the sheet (fit, or a fixed ratio).
    public var plotScale: LayoutPlotScale

    public init(
        widthMM: Double = 210,
        heightMM: Double = 297,
        marginMM: Double = 10,
        plotScale: LayoutPlotScale = .fit
    ) {
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.marginMM = marginMM
        self.plotScale = plotScale
    }

    /// An ISO A4 portrait page (210 × 297 mm), 10 mm margin, scaled to fit — the
    /// default "new layout" sheet.
    public static let a4Portrait = PageDescriptor()
}

// MARK: - A named layout (paper sheet)

/// One named paper sheet in the drawing's layout table — the value-type port of an
/// AutoCAD LAYOUT (DXF ACAD_LAYOUT dictionary entry). A layout is a NAMED sheet
/// plus its page descriptor; the entities painted on it carry `space == .paper`
/// and `layoutName == this.name` (so a paper-space entity knows WHICH sheet it is
/// on). Model space is NEVER a `Layout` — it is implicit, the entities with
/// `space == .model`.
///
/// `tabOrder` is the left-to-right position of the layout's tab in the (later) UI
/// strip; the layout table keeps entries sorted/queried by this. Pure value type
/// (ADR-001) so the whole `layouts` array snapshots cheaply for value-snapshot
/// undo (ADR-002) and round-trips through the document payload.
public struct Layout: Sendable, Hashable, Codable, Identifiable {
    /// The layout's name (the tab label / DXF LAYOUT name), e.g. "Layout1". Unique
    /// within the drawing (case-insensitive, enforced by `CADDrawing`'s mutators).
    public var name: String
    /// The left-to-right tab position (0-based). Lower comes first.
    public var tabOrder: Int
    /// The sheet's paper size / margin / plot scale (engine-level values, mm).
    public var page: PageDescriptor

    /// `Identifiable` by name (names are unique within the drawing), so SwiftUI tab
    /// lists key on a stable id without a separate uuid.
    public var id: String { name }

    public init(
        name: String,
        tabOrder: Int = 0,
        page: PageDescriptor = PageDescriptor()
    ) {
        self.name = name
        self.tabOrder = tabOrder
        self.page = page
    }
}
