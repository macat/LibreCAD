//
//  PrintLayout.swift
//  LibreCADmacOS
//
//  The PURE, unit-testable plot-scale + page-setup model that drives professional
//  CAD plotting (print AND PDF export). It answers ONE question with no graphics
//  context and no print dialog:
//
//      given the drawing's world bounds + its drawing UNIT (imperial/metric) +
//      a chosen plot scale + a fixed paper rect + margins,
//      → the world→page transform (an `ExportTransform`) and whether the drawing
//        OVERFLOWS one page at that scale.
//
//  ## Why a separate file (and why it lives on engine types only)
//  The macOS print panel (`NSPrintOperation`) is reachable only from the View layer,
//  so the scale math can't be unit-tested through it. We split the math out here as
//  free functions over plain value types (`AABB`/`SizePt`/`DrawingUnit`/
//  `ExportTransform` — all from `CADEngine`), with NO AppKit/CoreGraphics and NO
//  reference to other app-target types (e.g. the app's `PaperSize` enum). That lets
//  the test target compile THIS file directly via a symlink (the established
//  `_Shared*.swift` zero-drift pattern) and assert the CTM/rect without a printer.
//
//  ## The unit-correct 1:1 contract
//  "1:1" means one drawing-inch prints as one paper-inch (this drawing set is
//  imperial/metric-aware). A page point is 1/72 inch, so:
//
//      pointsPerWorldUnit(unit) = unit.factorToMM · 72 / 25.4
//
//  i.e. how many page points one world unit occupies at 1:1. For an inch drawing
//  that is 72 (1 inch → 72 pt); for a millimeter drawing ≈ 2.8346 (1 mm → 2.8346 pt).
//  A custom ratio `drawingUnits : paperUnits` (e.g. 1:50 or 4:1) divides that scale
//  by `drawingUnits / paperUnits` (1:50 ⇒ ×1/50 = shrink 50×; 4:1 ⇒ ×4 = enlarge).
//
//  ## What flows downstream
//  `makeTransform(...)` returns an `ExportTransform` built for the FIXED paper rect
//  (page does NOT grow to the drawing, unlike `ExportOptions.oneToOne`), anchored in
//  the imageable area, plus an `overflows` flag. The SAME math also produces an
//  `ExportOptions` (`makeExportOptions`) so the PDF/PNG/SVG export path renders at
//  the identical scale — a 1:1 PDF measures correctly with a ruler.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CADEngine

// MARK: - Plot scale

/// The plot scale a user can choose for printing / scale-aware export.
///
/// - `.fit`        — scale the bounding box to fill the page (the legacy default;
///                   nothing regresses).
/// - `.oneToOne`   — 1 drawing unit prints at its true physical size (1 inch → 1
///                   paper inch), honoring the drawing's `DrawingUnit`.
/// - `.custom`     — an explicit `drawingUnits : paperUnits` ratio, e.g. 1:50
///                   (`drawingUnits = 50, paperUnits = 1`) or 4:1 (`drawingUnits = 1,
///                   paperUnits = 4`). Both sides are in the SAME unit, so the ratio
///                   is a pure number; the drawing unit still sets the physical base.
public enum PlotScale: Sendable, Equatable, Hashable {
    case fit
    case oneToOne
    case custom(drawingUnits: Double, paperUnits: Double)

    /// The drawing-units : paper-units ratio as a single multiplier applied to the
    /// 1:1 scale (paperUnits / drawingUnits). `.fit` has no fixed ratio (`nil`);
    /// `.oneToOne` is 1. A non-positive / non-finite custom ratio clamps to 1:1 so a
    /// stray field can never make the drawing vanish or invert.
    public var ratioMultiplier: Double? {
        switch self {
        case .fit:
            return nil
        case .oneToOne:
            return 1
        case .custom(let drawingUnits, let paperUnits):
            guard drawingUnits.isFinite, paperUnits.isFinite,
                  drawingUnits > 0, paperUnits > 0 else { return 1 }
            return paperUnits / drawingUnits
        }
    }

    /// A short label for the print/page-setup UI ("Fit", "1:1", "1:50", "4:1").
    public var label: String {
        switch self {
        case .fit:
            return "Fit"
        case .oneToOne:
            return "1:1"
        case .custom(let drawingUnits, let paperUnits):
            return "\(PlotScale.trim(drawingUnits)):\(PlotScale.trim(paperUnits))"
        }
    }

    /// Compact number formatting for the label (drops a trailing ".0").
    private static func trim(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e12 { return String(Int(v.rounded())) }
        return String(v)
    }
}

// MARK: - Page setup (pure value model)

/// The fixed-paper page setup that drives a scale-aware print / export. Carries the
/// paper rect in POINTS (already orientation-applied) plus the uniform margin and
/// the chosen plot scale — all plain values so this model is `Codable`/testable and
/// free of AppKit. The drawing `unit` is passed alongside (it lives on the drawing,
/// not the setup) when the transform is built.
public struct PageSetup: Sendable, Equatable {
    /// The paper rectangle in points (72 pt == 1 inch), already in the chosen
    /// orientation (portrait vs landscape applied by the caller).
    public var paperSize: SizePt
    /// Uniform margin (points) kept clear on every edge.
    public var margin: Double
    /// The chosen plot scale.
    public var scale: PlotScale

    public init(paperSize: SizePt = .a4, margin: Double = 18, scale: PlotScale = .fit) {
        self.paperSize = paperSize
        self.margin = margin
        self.scale = scale
    }

    /// The imageable (printable) rectangle in points: the paper minus the margin on
    /// every edge (never smaller than 1×1 so downstream math stays finite).
    public var imageableSize: SizePt {
        SizePt(width: Swift.max(paperSize.width - 2 * margin, 1),
               height: Swift.max(paperSize.height - 2 * margin, 1))
    }
}

// MARK: - The pure scale → page transform

/// The result of laying a drawing onto a page at a chosen scale: the world→page
/// `ExportTransform` (consumed by the CG renderer AND the SVG emitter) plus whether
/// the scaled drawing exceeds one page (so the print/export flow can warn / tile).
public struct PlotLayout: Sendable, Equatable {
    /// The world→page transform (page space is y-down, matching the renderer).
    public var transform: ExportTransform
    /// World-units → page-points scale actually used (1:1 ⇒ `pointsPerWorldUnit`).
    public var scale: Double
    /// Whether the scaled drawing is larger than the imageable area in either axis.
    public var overflows: Bool
    /// The scaled drawing extent in points (width, height) — handy for the UI and
    /// for tiling decisions.
    public var drawingPagePt: SizePt

    public init(transform: ExportTransform, scale: Double, overflows: Bool,
                drawingPagePt: SizePt) {
        self.transform = transform
        self.scale = scale
        self.overflows = overflows
        self.drawingPagePt = drawingPagePt
    }
}

/// Pure plot-scale math. No graphics context, no print dialog — every function is a
/// referentially-transparent transform over value types, so the test target can
/// assert the CTM/rect directly.
public enum PrintLayout {

    /// Page points per ONE world unit at 1:1 for `unit`. A page point is 1/72 inch
    /// (25.4/72 mm), so `factorToMM` (mm per unit) maps to points by ×72/25.4. For
    /// `.none` (treated as mm) this is ≈ 2.8346; for inches it is exactly 72.
    public static func pointsPerWorldUnit(_ unit: DrawingUnit) -> Double {
        unit.factorToMM * 72.0 / 25.4
    }

    /// The world→page-points scale for `unit` under `scale`. For `.fit` returns the
    /// fit-to-imageable scale for `bounds`; for `.oneToOne`/`.custom` returns the
    /// unit-correct physical scale (× the ratio multiplier). Bounds only matter for
    /// `.fit`.
    public static func pageScale(bounds: AABB,
                                 unit: DrawingUnit,
                                 setup: PageSetup) -> Double {
        let imageable = setup.imageableSize
        switch setup.scale {
        case .fit:
            // Same fit math the SVG/CG `.fitToPage` path uses: largest uniform scale
            // that keeps the bbox inside the imageable area. An empty/degenerate
            // bbox falls back to 1 (no geometry to frame).
            guard !bounds.isEmpty else { return 1 }
            let w = Swift.max(bounds.size.x, Tolerance.distance)
            let h = Swift.max(bounds.size.y, Tolerance.distance)
            return Swift.min(imageable.width / w, imageable.height / h)
        case .oneToOne, .custom:
            let base = pointsPerWorldUnit(unit)
            let mult = setup.scale.ratioMultiplier ?? 1
            let s = base * mult
            return s > 0 && s.isFinite ? s : 1
        }
    }

    /// The full layout: the world→page `ExportTransform` for `bounds`/`unit`/`setup`
    /// onto the FIXED paper rect, anchored (centered) in the imageable area, plus an
    /// `overflows` flag.
    ///
    /// Unlike `ExportOptions.oneToOne` (which grows the page to the drawing), this
    /// keeps the paper FIXED — the right behavior for printing on real sheets — so a
    /// drawing bigger than the page at the chosen scale is reported via `overflows`
    /// (the renderer then clips to the page; tiling is a follow-up). The drawing is
    /// centered so the visible portion is the middle of the sheet.
    public static func makeLayout(bounds: AABB,
                                  unit: DrawingUnit,
                                  setup: PageSetup) -> PlotLayout {
        let page = setup.paperSize
        let margin = setup.margin
        let imageable = setup.imageableSize

        // Degenerate / empty drawing: a unit transform at the margin, no overflow.
        guard !bounds.isEmpty else {
            let xform = ExportTransform(bounds: .empty,
                                        options: ExportOptions(pageSize: page,
                                                               margin: margin,
                                                               scaling: .fitToPage))
            return PlotLayout(transform: xform, scale: 1, overflows: false,
                              drawingPagePt: SizePt(width: 0, height: 0))
        }

        let s = pageScale(bounds: bounds, unit: unit, setup: setup)
        let w = Swift.max(bounds.size.x, Tolerance.distance)
        let h = Swift.max(bounds.size.y, Tolerance.distance)
        let drawnW = w * s
        let drawnH = h * s

        // Center the scaled drawing inside the imageable area. When it overflows, the
        // offset goes negative on that axis so the drawing stays CENTERED (the page
        // shows the middle slice) and the renderer clips the rest.
        let offsetX = margin + (imageable.width - drawnW) / 2
        let offsetY = margin + (imageable.height - drawnH) / 2

        // Build the transform by hand on the FIXED page (do NOT reuse
        // ExportOptions.oneToOne, which resizes the page). `ExportTransform` is a
        // plain value type, so we set its fields directly. For `.fit` this reproduces
        // the legacy centered fit exactly.
        var xform = ExportTransform(bounds: bounds,
                                    options: ExportOptions(pageSize: page,
                                                           margin: margin,
                                                           scaling: .fitToPage))
        xform.pageSize = page
        xform.scale = s
        xform.worldOrigin = Vector(bounds.min.x, bounds.min.y)
        xform.offsetX = offsetX
        xform.offsetY = offsetY

        // Overflow: scaled drawing larger than the imageable area in either axis
        // (a tiny epsilon avoids a false positive when it exactly fills the page).
        let eps = 1e-6
        let overflows = drawnW > imageable.width + eps || drawnH > imageable.height + eps

        return PlotLayout(transform: xform, scale: s, overflows: overflows,
                          drawingPagePt: SizePt(width: drawnW, height: drawnH))
    }

    /// The `ExportOptions` that reproduces this page setup for the file-export path
    /// (PDF/PNG/SVG). `.fit` maps to `.fitToPage` on the paper rect (legacy default);
    /// a fixed scale maps to `.oneToOne(unitsPerPoint:)` so `DrawingExporter`/
    /// `SVGExporter` render at the SAME physical scale (a 1:1 PDF measures correctly).
    ///
    /// Note: `ExportOptions.oneToOne` SIZES the page to the drawing (so the whole
    /// drawing fits the file at scale — the natural thing for a vector PDF/SVG),
    /// whereas the PRINT path (`makeLayout`) keeps the paper fixed and clips. Both
    /// honor the identical world→point scale, which is what "1:1 measures correctly"
    /// requires.
    public static func makeExportOptions(unit: DrawingUnit,
                                         setup: PageSetup,
                                         background: RGBAColor? = nil) -> ExportOptions {
        switch setup.scale {
        case .fit:
            return ExportOptions(pageSize: setup.paperSize,
                                 margin: setup.margin,
                                 scaling: .fitToPage,
                                 background: background)
        case .oneToOne, .custom:
            let s = pageScale(bounds: .empty, unit: unit, setup: setup)
            let unitsPerPoint = s > 0 ? 1.0 / s : 1.0
            return ExportOptions(pageSize: setup.paperSize,
                                 margin: setup.margin,
                                 scaling: .oneToOne(unitsPerPoint: unitsPerPoint),
                                 background: background)
        }
    }
}

// MARK: - Unit conversion helpers (paper geometry)

/// Millimeters → page points (72 pt / inch). Used to turn a paper size in mm into
/// the points `PageSetup`/`ExportOptions` speak.
public func pointsFromMM(_ mm: Double) -> Double { mm * 72.0 / 25.4 }
