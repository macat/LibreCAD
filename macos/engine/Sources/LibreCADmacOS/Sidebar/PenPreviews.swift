//
//  PenPreviews.swift
//  LibreCADmacOS
//
//  Two SMALL, pure SwiftUI previews that draw a pen attribute the way it READS in the
//  drawing — so the sidebar / property bars can show what a line TYPE or line WIDTH
//  actually looks like instead of a cryptic glyph (`line.diagonal`, a bare "0.25 mm"):
//
//   • `LinetypePreview` — a short horizontal line stroked with the dash pattern for a
//     `PenLineType` (solid → continuous; dashed/dotted/dashDot/center/border/divide →
//     distinct dash arrays; `.byLayer`/`.byBlock` → solid, the "inherit" baseline).
//   • `LineweightPreview` — a short horizontal bar whose THICKNESS reflects a
//     `PenLineWidth` (heavier mm → thicker bar, clamped to a legible px range;
//     `.byLayer`/`.byBlock`/`.default` → a thin hairline).
//
//  ## Why a separate pure mapping type
//  The dash-array and thickness derivations live on `PenPreviewGeometry` (pure value
//  math, NO SwiftUI shapes), so they unit-test headlessly through the established
//  `_Shared*` symlink convention (see `PenPreviewTests`). The two `View`s are thin
//  wrappers that feed those arrays into `Path` + `StrokeStyle`. This mirrors the project
//  pattern where `CGSceneRenderer.dashLengths` / `RendererGeometry.dashParamsPx` keep
//  the math testable apart from the draw call.
//
//  Engine-pure in spirit: these speak only `CADEngine` value types (`PenLineType` /
//  `PenLineWidth`) — no document, model, or undo knowledge. Wave 2 (sidebar) consumes
//  them in the layer row; Wave 3 (property bars / pen pickers) will reuse them, so they
//  are kept general (caller-supplied color, length, and a documented px clamp).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

// MARK: - Pure geometry (testable apart from the SwiftUI draw)

/// The pure value math behind the pen previews — dash arrays for a line TYPE and a px
/// thickness for a line WIDTH. No SwiftUI shapes here, so it unit-tests headlessly via
/// the `_SharedPenPreviews.swift` symlink (mirrors `CGSceneRenderer.dashLengths`).
enum PenPreviewGeometry {

    // MARK: Line TYPE → dash array

    /// The SwiftUI `StrokeStyle.dash` array for a `PenLineType`, sized to a preview of
    /// total `length` points. Returns `[]` for `.solid` and the inherit sentinels
    /// (`.byLayer`/`.byBlock`) ⇒ a continuous stroke; otherwise an even-count,
    /// strictly-positive alternating ON/OFF pattern (the shape SwiftUI's dasher wants).
    ///
    /// The unit is derived from `length` so the pattern reads well at ANY preview size
    /// (the sidebar's ~22pt chip and a future larger bar both look right): one base dash
    /// is ~`length * 0.32`, a gap ~`length * 0.18`, a dot a short pip. Each style mirrors
    /// the rhythm `CGSceneRenderer.dashLengths` uses for the actual export, so the chip
    /// matches what gets drawn.
    ///
    /// - Returns: `[]` for solid/inherit; else a non-empty even-count positive array.
    static func dashArray(for lineType: PenLineType, length: CGFloat = 22) -> [CGFloat] {
        // Guard a degenerate length so we never emit a 0-length stall (which would
        // freeze the dasher) — fall back to a sane minimum the patterns scale off.
        let u = max(length, 8) * 0.32        // one base ON dash
        let gap = max(length, 8) * 0.18      // OFF gap
        let dot = max(1.5, u * 0.22)         // short ON pip (a "dot")

        switch lineType {
        case .solid, .byLayer, .byBlock:
            return []
        case .dashed:
            // ─ ─ ─ : dash, gap.
            return [u, gap]
        case .dotted:
            // · · · : dot, gap.
            return [dot, gap]
        case .dashDot:
            // ─ · ─ · : dash, gap, dot, gap.
            return [u, gap, dot, gap]
        case .center:
            // ─── · ─── : long dash, gap, short dash, gap.
            return [u * 1.6, gap, u * 0.5, gap]
        case .border:
            // ── ── · : two dashes then a dot.
            return [u, gap, u, gap, dot, gap]
        case .divide:
            // ─── · · : long dash then two dots.
            return [u * 1.4, gap, dot, gap, dot, gap]
        }
    }

    // MARK: Line WIDTH → preview thickness (px)

    /// The drawn THICKNESS (points) of the lineweight preview bar for a `PenLineWidth`,
    /// clamped to a legible on-screen range so a 0 mm pen still reads as a hairline and a
    /// heavy pen never blows out the row. The context sentinels (`.byLayer`/`.byBlock`)
    /// and the drawing `.default` show the thin baseline (the "inherit / default" look).
    ///
    /// The mm→px map is intentionally NON-physical (a preview, not a plot): it compresses
    /// the wide ISO ladder (0…2.11 mm) into a small px band via a gentle scale so the
    /// steps stay distinguishable in a ~22pt chip without any becoming invisibly thin or
    /// comically thick.
    ///
    /// - Parameters:
    ///   - minPx: the thinnest bar (hairline / inherit / default). Default 1.
    ///   - maxPx: the thickest bar (clamp ceiling). Default 6.
    /// - Returns: a thickness in `[minPx, maxPx]`.
    static func thicknessPx(for width: PenLineWidth,
                            minPx: CGFloat = 1,
                            maxPx: CGFloat = 6) -> CGFloat {
        switch width {
        case .byLayer, .byBlock, .default:
            return minPx
        case .millimeters(let mm):
            guard mm > 0 else { return minPx }
            // Compress the mm ladder: 0.25 mm ≈ thin-default, ~2 mm ≈ near-ceiling.
            // ~2.5 px per mm reaches maxPx around the top of the ISO ladder.
            let px = minPx + CGFloat(mm) * 2.5
            return min(max(px, minPx), maxPx)
        }
    }
}

// MARK: - Line TYPE preview

/// A short horizontal line drawn with the dash pattern for a `PenLineType` — the visual
/// replacement for the cryptic `line.diagonal` linetype glyph. Solid (and the inherit
/// sentinels) render continuous; the dashed family renders its pattern. Pure value types
/// only (a `CADEngine` `PenLineType` in, a `Path` out).
struct LinetypePreview: View {
    /// The line type whose dash pattern to draw.
    let lineType: PenLineType
    /// The stroke color (default: the primary label color so it reads on any surface).
    var color: Color = .primary
    /// The preview width (points). The dash unit scales off this so it reads at any size.
    var length: CGFloat = 22

    var body: some View {
        Path { path in
            // A single horizontal segment, vertically centered in a `length × 1` box; the
            // overlaid frame + alignment place it. Drawn left→right at y = 0.5 so a 1pt
            // hairline sits crisply on the pixel center.
            path.move(to: CGPoint(x: 0, y: 0.5))
            path.addLine(to: CGPoint(x: length, y: 0.5))
        }
        .stroke(style: StrokeStyle(
            lineWidth: 1,
            lineCap: .round,
            dash: PenPreviewGeometry.dashArray(for: lineType, length: length)
        ))
        .foregroundStyle(color)
        .frame(width: length, height: 1)
    }
}

// MARK: - Line WIDTH preview

/// A short horizontal BAR whose thickness reflects a `PenLineWidth` — the visual
/// companion to `LinetypePreview` for the lineweight. Heavier mm ⇒ thicker bar (clamped
/// to a legible px band); the inherit/default cases show a thin hairline. Pure value
/// types only.
struct LineweightPreview: View {
    /// The line width whose thickness to draw.
    let width: PenLineWidth
    /// The stroke color (default: primary label color).
    var color: Color = .primary
    /// The preview width (points).
    var length: CGFloat = 22

    var body: some View {
        let t = PenPreviewGeometry.thicknessPx(for: width)
        Capsule()
            .fill(color)
            .frame(width: length, height: t)
            // Reserve a stable row height so bars of different thickness all align on the
            // same centerline (the capsule is centered within the reserved box).
            .frame(height: 6, alignment: .center)
    }
}
