//
//  CoreTextFontProvider.swift
//  CADEngine
//
//  The DEFAULT native-outline font provider (ADR-004 REVISION; text-system-design
//  §2.2). Shapes runs with Core Text (`CTLine`/`CTRun` → real kerning, ligatures,
//  full Unicode) and turns glyph paths (`CTFontCreatePathForGlyph`) into FILLS
//  (closed loops), flattened to a tolerance and cached scale-independently. The
//  renderer needs NO change — outline glyphs flow through the existing
//  `ResolvedFill` → `FillTriangulation` pipeline.
//
//  NOT an SDF atlas: outlines are vector → crisp at any zoom and export to
//  PDF/SVG perfectly. This is the ADR-004-revision rationale.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation
import CoreText
import CoreGraphics

// MARK: - Provider

/// Resolves native macOS font families (via Core Text) into `CoreTextFont`
/// shapers, caching by family + traits. Thread-safe (an internal lock guards the
/// cache) so it can be shared and is `@unchecked Sendable` (the established
/// `StrokeFontProvider` pattern).
public final class CoreTextFontProvider: FontProvider, @unchecked Sendable {

    private struct Key: Hashable { var family: String; var bold: Bool; var italic: Bool }
    private var cache: [Key: CoreTextFont?] = [:]
    private let lock = NSLock()

    public init() {}

    /// Resolves a `FontSource` to a native shaper. Only `.native` is served here;
    /// `.stroke`/`.shx` return `nil` so the resolve arm walks the substitution
    /// chain to the stroke provider.
    public func resolveFont(_ source: FontSource) -> ShapedFont? {
        guard case let .native(family) = source else { return nil }
        return font(family: family, bold: false, italic: false)
    }

    /// Resolves a native family + bold/italic traits. Public so the resolve arm
    /// (which knows the run attributes) can pick the right face directly.
    public func font(family: String, bold: Bool, italic: Bool) -> CoreTextFont? {
        let key = Key(family: family, bold: bold, italic: italic)
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        let resolved = CoreTextFont(family: family, bold: bold, italic: italic)
        lock.lock(); cache[key] = .some(resolved); lock.unlock()
        return resolved
    }
}

// MARK: - Resolved native font (one face, unit em)

/// A resolved Core Text face at unit em (`CTFontCreateWithName(..., 1.0, nil)`).
/// Immutable; the glyph-geometry cache is internal and lock-guarded so the type
/// is `@unchecked Sendable` (it holds a `CTFont`, which is itself thread-safe).
public final class CoreTextFont: ShapedFont, @unchecked Sendable {

    /// The unit-em CTFont (point size 1.0 → glyph paths come back in em units).
    let ctFont: CTFont
    public let metrics: FontMetrics

    /// Cache of flattened glyph outlines keyed by (glyphID, toleranceBucket).
    private struct CacheKey: Hashable { var glyph: UInt32; var bucket: Double }
    private var glyphCache: [CacheKey: GlyphGeometry] = [:]
    private let lock = NSLock()

    /// Builds a face for a family + traits, or `nil` if Core Text can't resolve it.
    init?(family: String, bold: Bool, italic: Bool) {
        // Unit em so CTFontCreatePathForGlyph returns em-space coordinates.
        let base = CTFontCreateWithName(family as CFString, 1.0, nil)

        // Verify the family actually resolved (Core Text substitutes silently for
        // unknown names; reject so the caller falls back deliberately).
        let resolvedFamily = (CTFontCopyFamilyName(base) as String?) ?? ""
        // Accept if the resolved family contains the request or vice-versa
        // (handles "Helvetica Neue" vs a PostScript face name); also accept the
        // generic ".AppleSystemUIFont" only when the family was explicitly empty.
        let wantLower = family.lowercased()
        let gotLower = resolvedFamily.lowercased()
        if !family.isEmpty,
           !gotLower.contains(wantLower), !wantLower.contains(gotLower),
           !wantLower.hasPrefix(gotLower) {
            // Could still be a PostScript name; check the PostScript name too.
            let psName = (CTFontCopyPostScriptName(base) as String?)?.lowercased() ?? ""
            if !psName.contains(wantLower) && !wantLower.contains(psName) {
                return nil
            }
        }

        // Apply bold/italic symbolic traits if requested.
        var font = base
        if bold || italic {
            var traits: CTFontSymbolicTraits = []
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            if let withTraits = CTFontCreateCopyWithSymbolicTraits(base, 1.0, nil, traits, traits) {
                font = withTraits
            }
        }
        self.ctFont = font

        let upem = Double(CTFontGetUnitsPerEm(font))
        let ascent = Double(CTFontGetAscent(font))
        let descent = Double(CTFontGetDescent(font))
        let leading = Double(CTFontGetLeading(font))
        var cap = Double(CTFontGetCapHeight(font))
        // Some faces report a zero cap height; fall back to a sensible fraction.
        if !(cap > 0) { cap = ascent * 0.7 }
        // At point size 1.0 these are already in em units (point size / upem · upem).
        self.metrics = FontMetrics(
            ascent: ascent,
            descent: descent,
            capHeight: cap,
            lineGap: leading,
            unitsPerEm: upem
        )
    }

    // MARK: Shaping

    public func shape(_ text: String, attributes: RunAttributes) -> [PositionedGlyph] {
        guard !text.isEmpty else { return [] }
        // Build a CFAttributedString with the Core Text font attribute (no AppKit
        // dependency — CADEngine stays GUI-light). Core Text applies kerning +
        // ligatures + full Unicode/complex shaping when it builds the CTLine.
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: ctFont,
            kCTLigatureAttributeName: 1
        ]
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        var out: [PositionedGlyph] = []
        out.reserveCapacity(text.count)

        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            CTRunGetAdvances(run, CFRangeMake(0, count), &advances)
            for k in 0..<count {
                out.append(PositionedGlyph(
                    glyph: GlyphID(UInt32(glyphs[k])),
                    advance: Vector(Double(advances[k].width) + attributes.tracking,
                                    Double(advances[k].height)),
                    offset: Vector(0, 0)
                ))
            }
        }
        return out
    }

    // MARK: Glyph geometry (outline → flattened closed loops)

    public func glyphGeometry(_ glyph: GlyphID, tolerance: Double) -> GlyphGeometry {
        let bucket = GlyphToleranceBucket.bucket(tolerance)
        let key = CacheKey(glyph: glyph.rawValue, bucket: bucket)

        lock.lock()
        if let hit = glyphCache[key] { lock.unlock(); return hit }
        lock.unlock()

        let geo = Self.flattenGlyph(ctFont, CGGlyph(glyph.rawValue), tolerance: bucket)

        lock.lock(); glyphCache[key] = geo; lock.unlock()
        return geo
    }

    /// Flattens one glyph's `CGPath` into closed loops in em space. Quadratics →
    /// reuse the existing `QuadSpline.point`; cubics → de Casteljau. Subdivides
    /// until the chord (sagitta) error is below `tolerance`. Loops are emitted
    /// outer-CCW / holes-CW (the `ResolvedFill` loop contract) by ordering the
    /// outer boundary first and reversing any sub-loop with the same winding.
    static func flattenGlyph(_ font: CTFont, _ glyph: CGGlyph, tolerance: Double) -> GlyphGeometry {
        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
            return GlyphGeometry()   // e.g. space — no drawable path
        }

        let tol = tolerance.isFinite && tolerance > 0 ? tolerance : 0.005

        // Walk the path, flattening curves. The path-apply block captures `acc`
        // (a reference type) so it can mutate the running contour state.
        let acc = Accum(tol: tol)

        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            let pts = element.points
            switch element.type {
            case .moveToPoint:
                acc.finish()
                let p = Vector(Double(pts[0].x), Double(pts[0].y))
                acc.start = p
                acc.pen = p
                acc.current = [p]
            case .addLineToPoint:
                let p = Vector(Double(pts[0].x), Double(pts[0].y))
                acc.current.append(p)
                acc.pen = p
            case .addQuadCurveToPoint:
                let ctrl = Vector(Double(pts[0].x), Double(pts[0].y))
                let end = Vector(Double(pts[1].x), Double(pts[1].y))
                Self.flattenQuad(acc.pen, ctrl, end, tol: acc.tol, into: &acc.current)
                acc.pen = end
            case .addCurveToPoint:
                let c1 = Vector(Double(pts[0].x), Double(pts[0].y))
                let c2 = Vector(Double(pts[1].x), Double(pts[1].y))
                let end = Vector(Double(pts[2].x), Double(pts[2].y))
                Self.flattenCubic(acc.pen, c1, c2, end, tol: acc.tol, into: &acc.current)
                acc.pen = end
            case .closeSubpath:
                acc.finish()
            @unknown default:
                break
            }
        }
        acc.finish()

        // Normalize winding: outer (largest |area|) CCW, the rest are holes (CW).
        let normalized = normalizeWinding(acc.contours)
        return GlyphGeometry(fills: normalized)
    }

    /// Mutable accumulator for the `CGPath` walk. The path-apply block is a
    /// non-capturing C callback in spirit, but `applyWithBlock` is a Swift closure,
    /// so we capture this reference type and mutate its running contour state.
    private final class Accum {
        var contours: [[Vector]] = []
        var current: [Vector] = []
        var pen = Vector(0, 0)
        var start = Vector(0, 0)
        let tol: Double
        init(tol: Double) { self.tol = tol }

        /// Closes the running contour (dropping a duplicated start point) and
        /// commits it if it has at least 3 distinct points.
        func finish() {
            if current.count >= 3 {
                if let f = current.first, let l = current.last,
                   (f.x - l.x) * (f.x - l.x) + (f.y - l.y) * (f.y - l.y) < 1e-18 {
                    current.removeLast()
                }
                if current.count >= 3 { contours.append(current) }
            }
            current = []
        }
    }

    /// Adaptive flatten of a quadratic Bézier (de Casteljau), appending interior +
    /// end points to `out` (the start is assumed already present).
    static func flattenQuad(_ p0: Vector, _ c: Vector, _ p1: Vector,
                            tol: Double, into out: inout [Vector]) {
        // Sagitta of a quad: distance of the control point off the chord midpoint
        // proxy. Recurse until flat enough.
        func recurse(_ a: Vector, _ ctrl: Vector, _ b: Vector, depth: Int) {
            // Flatness: control-point deviation from the chord.
            let dev = pointLineDistance(ctrl, a, b)
            if dev <= tol || depth >= 12 {
                out.append(b)
                return
            }
            // Subdivide at t = 0.5.
            let ab = (a + ctrl) * 0.5
            let bc = (ctrl + b) * 0.5
            let mid = (ab + bc) * 0.5
            recurse(a, ab, mid, depth: depth + 1)
            recurse(mid, bc, b, depth: depth + 1)
        }
        recurse(p0, c, p1, depth: 0)
    }

    /// Adaptive flatten of a cubic Bézier (de Casteljau).
    static func flattenCubic(_ p0: Vector, _ c1: Vector, _ c2: Vector, _ p1: Vector,
                             tol: Double, into out: inout [Vector]) {
        func recurse(_ a: Vector, _ k1: Vector, _ k2: Vector, _ b: Vector, depth: Int) {
            let dev = max(pointLineDistance(k1, a, b), pointLineDistance(k2, a, b))
            if dev <= tol || depth >= 14 {
                out.append(b)
                return
            }
            let ab = (a + k1) * 0.5
            let bc = (k1 + k2) * 0.5
            let cd = (k2 + b) * 0.5
            let abc = (ab + bc) * 0.5
            let bcd = (bc + cd) * 0.5
            let mid = (abc + bcd) * 0.5
            recurse(a, ab, abc, mid, depth: depth + 1)
            recurse(mid, bcd, cd, b, depth: depth + 1)
        }
        recurse(p0, c1, c2, p1, depth: 0)
    }

    /// Perpendicular distance from point `p` to the line segment a→b (used as the
    /// Bézier flatness criterion).
    static func pointLineDistance(_ p: Vector, _ a: Vector, _ b: Vector) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 < 1e-18 {
            let ex = p.x - a.x, ey = p.y - a.y
            return (ex * ex + ey * ey).squareRoot()
        }
        let cross = abs((p.x - a.x) * dy - (p.y - a.y) * dx)
        return cross / len2.squareRoot()
    }

    /// Signed area (shoelace); positive == CCW.
    static func signedArea(_ ring: [Vector]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<ring.count {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            sum += p.x * q.y - q.x * p.y
        }
        return sum * 0.5
    }

    /// Orders contours so `[0]` is the outer boundary (largest area, CCW) and the
    /// rest are holes (CW). Glyph counters (the inside of O/e/A) come back from
    /// Core Text already wound opposite to the outer; we make that explicit so the
    /// triangulator's hole-bridge cuts them out.
    static func normalizeWinding(_ contours: [[Vector]]) -> [[Vector]] {
        guard !contours.isEmpty else { return [] }
        // Find the outer boundary: the contour with the largest absolute area.
        var areas = contours.map { signedArea($0) }
        var outerIdx = 0
        var maxAbs = 0.0
        for (i, a) in areas.enumerated() where abs(a) > maxAbs {
            maxAbs = abs(a); outerIdx = i
        }
        var result: [[Vector]] = []
        result.reserveCapacity(contours.count)
        // Outer first, forced CCW.
        var outer = contours[outerIdx]
        if areas[outerIdx] < 0 { outer.reverse(); areas[outerIdx] = -areas[outerIdx] }
        result.append(outer)
        // The rest as holes, forced CW.
        for (i, c) in contours.enumerated() where i != outerIdx {
            var hole = c
            if areas[i] > 0 { hole.reverse() }   // make CW
            result.append(hole)
        }
        return result
    }
}
