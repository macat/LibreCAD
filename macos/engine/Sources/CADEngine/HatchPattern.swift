//
//  HatchPattern.swift
//  CADEngine
//
//  Real hatch-pattern support (v5 WAVE-4a, feature F6): a `.pat` pattern-line
//  generator. Parses bundled AutoCAD-format `.pat` pattern definitions and, for
//  a non-solid hatch, generates the pattern's parallel/dashed line families
//  CLIPPED to the boundary loops — emitted as `ResolvedPolyline`s (the resolve
//  hatch arm calls `HatchPatternGenerator.lines`). Honors per-hatch scale +
//  angle. Unknown patterns are reported absent so the resolve arm falls back to
//  the solid fill (the prior behavior). Pure geometry (ADR-001): nothing here is
//  stored on an entity.
//
//  Mirrors the role of LibreCAD's RS_Pattern / pattern hatch generation
//  (librecad/src/lib/engine/document/entities/rs_hatch.cpp), though LibreCAD
//  ships DXF-based patterns while this port ships standard `.pat` files.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original hatch/pattern math).
//

import Foundation

// MARK: - Parsed `.pat` model

/// One line-family definition from a `.pat` pattern: a family of parallel lines
/// at `angle` (radians), the first passing through `origin`, the next offset by
/// `delta` (`delta.x` shifts each successive line ALONG its own direction so the
/// dashes stagger; `delta.y` is the PERPENDICULAR spacing between the parallel
/// lines). `dashes` are run lengths along the line: positive == pen-down,
/// negative == gap; empty == a continuous (solid) line.
///
/// This is exactly the AutoCAD `.pat` line record
/// `angle, x-origin,y-origin, delta-x,delta-y [, dash...]`, with `angle`/`delta`
/// already in the line's own rotated frame.
public struct HatchPatternLine: Sendable, Hashable {
    /// Family angle in radians (parsed from the `.pat` degrees value).
    public var angle: Double
    /// A point the first line of the family passes through (pattern space).
    public var origin: Vector
    /// `(along, perpendicular)` step between successive parallel lines.
    public var delta: Vector
    /// Dash run lengths (pen-down > 0, gap < 0); empty ⇒ continuous.
    public var dashes: [Double]

    public init(angle: Double, origin: Vector, delta: Vector, dashes: [Double] = []) {
        self.angle = angle
        self.origin = origin
        self.delta = delta
        self.dashes = dashes
    }

    /// Total cycle length of the dash pattern (sum of |dash|); 0 ⇒ continuous.
    var dashCycle: Double { dashes.reduce(0) { $0 + abs($1) } }
}

/// A complete `.pat` pattern: a name plus its line families. `SOLID`/`nil` is
/// represented by the *absence* of a pattern (the resolve arm fills solid).
public struct HatchPattern: Sendable, Hashable {
    public var name: String
    public var description: String
    public var lines: [HatchPatternLine]

    public init(name: String, description: String = "", lines: [HatchPatternLine]) {
        self.name = name
        self.description = description
        self.lines = lines
    }
}

// MARK: - `.pat` parser

/// Parses AutoCAD-format `.pat` text into `HatchPattern`s. The format:
///
///     ; comment
///     *NAME, optional description
///     angle, x-origin,y-origin, delta-x,delta-y [, dash1, dash2, ...]
///     ... (more line records belong to the most recent *NAME)
///
/// Lenient: blank/comment lines (`;`) are skipped; a malformed line record is
/// skipped (not fatal) so one bad entry never loses the whole library. Angles in
/// the file are DEGREES and are converted to radians here.
public enum HatchPatternParser {

    /// Parses every `*pattern` block in `text`. Names are upper-cased (the lookup
    /// key) so `ANSI31`/`ansi31` resolve identically.
    public static func parse(_ text: String) -> [HatchPattern] {
        var patterns: [HatchPattern] = []
        var currentName: String?
        var currentDesc = ""
        var currentLines: [HatchPatternLine] = []

        func flush() {
            if let name = currentName {
                patterns.append(HatchPattern(
                    name: name, description: currentDesc, lines: currentLines))
            }
            currentName = nil
            currentDesc = ""
            currentLines = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }

            if line.hasPrefix("*") {
                // New pattern header — close out the previous one.
                flush()
                // `*NAME, description` (description optional, may contain commas).
                let body = line.dropFirst()
                if let comma = body.firstIndex(of: ",") {
                    currentName = body[..<comma].trimmingCharacters(in: .whitespaces).uppercased()
                    currentDesc = String(body[body.index(after: comma)...])
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    currentName = body.trimmingCharacters(in: .whitespaces).uppercased()
                    currentDesc = ""
                }
                continue
            }

            // A line record only counts inside a pattern.
            guard currentName != nil else { continue }
            if let rec = parseLineRecord(line) { currentLines.append(rec) }
        }
        flush()
        return patterns
    }

    /// Parses one `angle, x,y, dx,dy [, dash...]` record. Returns `nil` if it
    /// doesn't have the 5 mandatory fields or they aren't numbers.
    static func parseLineRecord(_ line: String) -> HatchPatternLine? {
        let fields = line.split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard fields.count >= 5,
              let angDeg = fields[0],
              let ox = fields[1], let oy = fields[2],
              let dx = fields[3], let dy = fields[4]
        else { return nil }

        var dashes: [Double] = []
        if fields.count > 5 {
            for f in fields[5...] {
                guard let d = f else { return nil }   // a non-numeric dash ⇒ bad record
                dashes.append(d)
            }
        }
        return HatchPatternLine(
            angle: angDeg * .pi / 180.0,
            origin: Vector(ox, oy),
            delta: Vector(dx, dy),
            dashes: dashes)
    }
}

// MARK: - Bundled pattern library (the resolve arm's source of patterns)

/// Process-wide registry of the bundled `.pat` patterns, keyed by upper-cased
/// name. Loaded lazily (and once) from the bundled `hatchpatterns/*.pat`
/// resources, with the SAME bundle-then-repo fallback `CADFonts` uses for `.lff`
/// stroke fonts:
///
/// - The bundled app: `LibreCADmacOS.app/Contents/Resources/hatchpatterns/*.pat`
///   (copied by `macos/scripts/make-app.sh`), found via `Bundle.main`.
/// - The bare SwiftPM binary / dev / tests: the in-repo
///   `macos/assets/hatchpatterns/`, derived from this file's `#filePath`.
///
/// `SOLID` is intentionally NOT a pattern — a solid hatch fills, it has no lines.
public enum HatchPatternLibrary {

    /// The loaded patterns, keyed by upper-cased name. Computed once.
    public static let patterns: [String: HatchPattern] = loadBundled()

    /// Looks up a pattern by name (case-insensitive). `nil`/`"SOLID"` ⇒ `nil`
    /// (no pattern ⇒ the resolve arm fills solid). An unknown name ⇒ `nil` ⇒
    /// solid fallback (the brief's "unknown pattern → solid").
    public static func pattern(named name: String?) -> HatchPattern? {
        guard let name, !name.isEmpty else { return nil }
        let key = name.uppercased()
        if key == "SOLID" { return nil }
        return patterns[key]
    }

    /// Parses every bundled `.pat` file into the name→pattern map.
    static func loadBundled() -> [String: HatchPattern] {
        var map: [String: HatchPattern] = [:]
        for url in patternFileURLs() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for pat in HatchPatternParser.parse(text) where !pat.lines.isEmpty {
                // First definition wins (bundle precedes repo); don't clobber.
                if map[pat.name] == nil { map[pat.name] = pat }
            }
        }
        return map
    }

    /// Every bundled `.pat` URL, bundle dir first then the in-repo asset dir.
    static func patternFileURLs() -> [URL] {
        var urls: [URL] = []
        let fm = FileManager.default
        for dir in searchDirectories() {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for e in entries where e.pathExtension.lowercased() == "pat" {
                urls.append(e)
            }
        }
        return urls
    }

    /// Directories searched for `*.pat`, in priority order: the app bundle's
    /// `Resources/hatchpatterns`, then the in-repo `macos/assets/hatchpatterns`.
    static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("hatchpatterns"),
           FileManager.default.fileExists(atPath: bundled.path) {
            dirs.append(bundled)
        }
        if let repo = repoPatternsDirectory() {
            dirs.append(repo)
        }
        return dirs
    }

    /// The in-repo `macos/assets/hatchpatterns` directory, derived from this
    /// file's source path (dev fallback for the bare binary / tests).
    static func repoPatternsDirectory() -> URL? {
        // <repo>/macos/engine/Sources/CADEngine/HatchPattern.swift
        //   -> drop the filename + 3 dirs (CADEngine, Sources, engine) -> macos
        let thisFile = URL(fileURLWithPath: #filePath)
        let macosDir = thisFile
            .deletingLastPathComponent()   // .../CADEngine        (drop filename)
            .deletingLastPathComponent()   // .../Sources
            .deletingLastPathComponent()   // .../engine
            .deletingLastPathComponent()   // .../macos
        let dir = macosDir.appendingPathComponent("assets/hatchpatterns")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }
}

// MARK: - Boundary tessellation (bulged hatch edges → straight rings)

/// Tessellates a hatch boundary loop (a ring of `PolylineVertex`, each carrying
/// the bulge of the segment that FOLLOWS it — including the implicit closing
/// edge last→first) into a flat ring of points. A zero-bulge segment contributes
/// just its straight endpoints; a bulged segment is expanded into arc samples by
/// the same DXF bulge math the polyline resolve arm uses (`tan(includedAngle/4)`,
/// sagitta-bounded). The returned ring does NOT repeat the first vertex (the
/// `ResolvedFill` loop contract — the closing edge is implicit).
public enum HatchBoundary {

    /// Expand one loop's bulged edges, including the closing edge. `tolerance` is
    /// the chord (sagitta) bound, as elsewhere in resolve.
    public static func tessellate(_ ring: [PolylineVertex], tolerance: Double) -> [Vector] {
        guard ring.count >= 2 else { return ring.map(\.point) }
        var out: [Vector] = []
        out.reserveCapacity(ring.count)
        let n = ring.count
        for i in 0..<n {
            let a = ring[i]
            let b = ring[(i + 1) % n]   // wraps to first for the closing edge
            if i == 0 { out.append(a.point) }
            let isLast = (i == n - 1)
            let arc = expandedArc(a: a, bPoint: b.point, tolerance: tolerance)
            if let arc {
                // Drop the start point (already present); for the closing edge
                // also drop the end point (it IS the first vertex — implicit).
                var samples = Array(arc.dropFirst())
                if isLast, samples.last == ring[0].point { samples.removeLast() }
                out.append(contentsOf: samples)
            } else if !isLast {
                out.append(b.point)
            }
            // A straight closing edge contributes nothing (first vertex implicit).
        }
        return out
    }

    /// Arc samples for one bulged segment `a → bPoint` (both endpoints included),
    /// or `nil` for a straight/degenerate segment. Same geometry as
    /// `Resolve.expandPolyline`'s bulge arm.
    static func expandedArc(a: PolylineVertex, bPoint: Vector, tolerance: Double) -> [Vector]? {
        guard abs(a.bulge) >= Tolerance.distance else { return nil }
        let included = 4 * atan(a.bulge)          // signed sweep
        let chord = bPoint - a.point
        let chordLen = chord.magnitude
        guard chordLen >= Tolerance.distance else { return nil }
        let radius = abs(chordLen / (2 * sin(included / 2)))
        let mid = (a.point + bPoint) * 0.5
        let half = chordLen / 2
        let apothem = (Swift.max(0, radius * radius - half * half)).squareRoot()
        let dir = chord / chordLen
        let leftNormal = Vector(-dir.y, dir.x)
        let apexSide = (a.bulge >= 0 ? 1.0 : -1.0)
        let centerSign = -copysign(1.0, cos(included / 2))
        let center = mid + leftNormal * (apexSide * centerSign * apothem)
        let startA = (a.point - center).angle
        let pts = Tessellation.arcPointsBySweep(
            center: center, radius: radius,
            startAngle: startA, sweep: -included, tolerance: tolerance)
        return pts.count > 1 ? pts : nil
    }
}

// MARK: - Pattern-line generation (clipped to the loops)

/// Generates a hatch pattern's lines, clipped to the (already tessellated)
/// boundary loops, as world-space segments. Each pattern line family is swept
/// across the boundary's bounding box; every infinite line is intersected with
/// the boundary polygon (even-odd: outer minus holes) to get the inside spans,
/// then dash runs are applied. The result is an array of `(start, end)` world
/// segments the resolve arm wraps in 2-point `ResolvedPolyline`s.
public enum HatchPatternGenerator {

    /// A guard so a tiny scale / huge boundary can't generate an unbounded number
    /// of lines (protects resolve time). If a family would exceed this many
    /// parallel lines, generation bails (the resolve arm then falls back to
    /// solid). Generous — real drawings never approach it.
    static let maxLinesPerFamily = 20_000

    /// Generate clipped pattern segments for one hatch.
    ///
    /// - `loops`: the tessellated boundary rings (loops[0] outer, loops[1...]
    ///   holes), each WITHOUT a repeated closing vertex.
    /// - `pattern`: the resolved `HatchPattern`.
    /// - `scale`/`angleOffset`: the per-hatch `patternScale` (code 41) and extra
    ///   `patternAngle` (code 52, radians).
    ///
    /// Returns world-space `(start, end)` segments, or an empty array if the
    /// boundary is degenerate / generation bailed (caller falls back to solid).
    public static func segments(
        loops: [[Vector]], pattern: HatchPattern,
        scale: Double, angleOffset: Double
    ) -> [(Vector, Vector)] {
        let rings = loops.filter { $0.count >= 3 }
        guard !rings.isEmpty else { return [] }
        let s = (scale.isFinite && scale > 0) ? scale : 1.0

        // Boundary bounding box (world space) — the sweep extent.
        var box = AABB.empty
        for ring in rings { for p in ring { box.expand(toInclude: p) } }
        guard !box.isEmpty else { return [] }
        // Pad so grazing lines at the very edge still get sampled.
        let diag = (box.max - box.min).magnitude
        guard diag.isFinite, diag > Tolerance.distance else { return [] }

        var out: [(Vector, Vector)] = []
        for fam in pattern.lines {
            guard generateFamily(fam, rings: rings, box: box, diag: diag,
                                 scale: s, angleOffset: angleOffset, into: &out)
            else { return [] }   // a family bailed ⇒ solid fallback
        }
        return out
    }

    /// Sweep one line family across the boundary box, clip each line to the
    /// polygon, apply dashes, append the resulting world segments. Returns
    /// `false` if the family would exceed `maxLinesPerFamily` (bail to solid).
    static func generateFamily(
        _ fam: HatchPatternLine, rings: [[Vector]], box: AABB, diag: Double,
        scale: Double, angleOffset: Double, into out: inout [(Vector, Vector)]
    ) -> Bool {
        let ang = fam.angle + angleOffset
        let dir = Vector(angle: ang)               // along the line
        let nrm = Vector(-dir.y, dir.x)            // perpendicular (line stepping)

        // Perpendicular spacing between parallel lines (scaled). A zero/!finite
        // spacing would loop forever — skip this family (contributes nothing).
        let spacing = abs(fam.delta.y) * scale
        guard spacing.isFinite, spacing > Tolerance.distance else { return true }

        // The family's origin in world space (scaled + rotated by angleOffset).
        let origin = (fam.origin * scale).rotated(by: angleOffset)

        // Signed perpendicular distance of the box corners from the origin line;
        // the family spans the [min,max] band of those distances.
        let corners = [
            box.min, box.max,
            Vector(box.min.x, box.max.y), Vector(box.max.x, box.min.y),
        ]
        var dMin = Double.greatestFiniteMagnitude
        var dMax = -Double.greatestFiniteMagnitude
        for c in corners {
            let d = (c - origin).dot(nrm)
            dMin = Swift.min(dMin, d)
            dMax = Swift.max(dMax, d)
        }
        // Snap to the family lattice so successive hatches tile coherently and
        // pad one spacing on each side.
        let kStart = Int(floor(dMin / spacing)) - 1
        let kEnd = Int(ceil(dMax / spacing)) + 1
        guard kEnd >= kStart else { return true }
        if (kEnd - kStart) > maxLinesPerFamily { return false }

        // Each line is long enough to cross the whole box (use the diagonal,
        // doubled, centered on the box center's projection along the line).
        let halfLen = diag
        let centerAlong = (box.center - origin).dot(dir)

        for k in kStart...kEnd {
            // The along-direction stagger (delta.x) shifts each successive line.
            let alongShift = fam.delta.x * scale * Double(k)
            let base = origin + nrm * (spacing * Double(k)) + dir * alongShift
            let a = base + dir * (centerAlong - halfLen)
            let b = base + dir * (centerAlong + halfLen)

            // Clip this infinite-ish segment to the boundary polygon → inside
            // spans (parametric t along a→b), then dash + emit.
            let spans = insideSpans(a: a, b: b, rings: rings)
            for (t0, t1) in spans {
                let p0 = a + (b - a) * t0
                let p1 = a + (b - a) * t1
                emitDashed(from: p0, to: p1, dir: dir, dashes: fam.dashes,
                           scale: scale, phase: alongShift, into: &out)
            }
        }
        return true
    }

    /// The parametric `[t0,t1]` spans of segment `a→b` that lie INSIDE the
    /// boundary (even-odd across all rings). Computes every ring-edge crossing's
    /// `t`, sorts them, and keeps alternate intervals starting from the first
    /// crossing (a hatch line enters/exits the region at each boundary crossing).
    static func insideSpans(a: Vector, b: Vector, rings: [[Vector]]) -> [(Double, Double)] {
        let ab = b - a
        let len2 = ab.squared
        guard len2 > Tolerance.distanceSquared else { return [] }

        var ts: [Double] = []
        for ring in rings {
            let n = ring.count
            for i in 0..<n {
                let p = ring[i]
                let q = ring[(i + 1) % n]
                if let t = segmentCrossingT(a: a, ab: ab, p: p, q: q) {
                    ts.append(t)
                }
            }
        }
        guard ts.count >= 2 else { return [] }
        ts.sort()

        // Pair consecutive crossings into inside spans. Dedupe near-coincident
        // crossings (a line through a vertex) so we don't emit zero/odd spans.
        var spans: [(Double, Double)] = []
        var i = 0
        while i + 1 < ts.count {
            let t0 = ts[i]
            var j = i + 1
            // Skip a crossing coincident with t0 (vertex / overlapping edges).
            while j < ts.count && ts[j] - t0 < 1e-9 { j += 1 }
            guard j < ts.count else { break }
            let t1 = ts[j]
            if t1 - t0 > 1e-9 { spans.append((t0, t1)) }
            i = j + 1
        }
        return spans
    }

    /// The parameter `t ∈ [0,1]` at which segment `a + t·ab` crosses ring edge
    /// `p→q`, or `nil` if they don't cross in range. Half-open on the edge
    /// (`[p,q)`) so a shared ring vertex is counted once, keeping the even-odd
    /// crossing count consistent.
    static func segmentCrossingT(a: Vector, ab: Vector, p: Vector, q: Vector) -> Double? {
        let pq = q - p
        let denom = ab.x * pq.y - ab.y * pq.x
        if abs(denom) < 1e-12 { return nil }      // parallel / collinear
        let ap = p - a
        let t = (ap.x * pq.y - ap.y * pq.x) / denom   // along a→b
        let u = (ap.x * ab.y - ap.y * ab.x) / denom   // along p→q
        guard t >= -1e-9, t <= 1 + 1e-9 else { return nil }
        guard u >= 0, u < 1 else { return nil }       // half-open edge
        return Swift.min(Swift.max(t, 0), 1)
    }

    /// Emit one inside span as either a single solid segment (no dashes) or a
    /// sequence of pen-down dash sub-segments. `phase` (the along-direction
    /// origin shift) keeps successive lines' dashes registered.
    static func emitDashed(
        from p0: Vector, to p1: Vector, dir: Vector, dashes: [Double],
        scale: Double, phase: Double, into out: inout [(Vector, Vector)]
    ) {
        let span = p1 - p0
        let spanLen = span.magnitude
        guard spanLen > Tolerance.distance else { return }

        let cycle = dashes.reduce(0) { $0 + abs($1) } * scale
        if dashes.isEmpty || cycle <= Tolerance.distance {
            out.append((p0, p1))                  // continuous line
            return
        }

        // Distance from the family origin to p0 along the line, so dashes phase
        // consistently across every inside span of every line in the family.
        let startDist = p0.dot(dir) - phase
        // Position within the dash cycle at p0.
        var cyclePos = startDist.truncatingRemainder(dividingBy: cycle)
        if cyclePos < 0 { cyclePos += cycle }

        // Walk the scaled dashes, emitting pen-down runs intersected with [0,spanLen].
        var distInSpan = 0.0
        // Find which dash we're inside at cyclePos, and how far into it.
        var idx = 0
        var acc = 0.0
        while idx < dashes.count {
            let dl = abs(dashes[idx]) * scale
            if cyclePos < acc + dl { break }
            acc += dl
            idx += 1
        }
        var offsetInDash = cyclePos - acc

        var guardCount = 0
        let guardMax = 200_000
        while distInSpan < spanLen - Tolerance.distance && guardCount < guardMax {
            guardCount += 1
            let dl = abs(dashes[idx % dashes.count]) * scale
            let penDown = dashes[idx % dashes.count] > 0
            let remainingInDash = dl - offsetInDash
            let take = Swift.min(remainingInDash, spanLen - distInSpan)
            if penDown && take > Tolerance.distance {
                let s = p0 + dir * distInSpan
                let e = p0 + dir * (distInSpan + take)
                out.append((s, e))
            }
            distInSpan += take
            offsetInDash += take
            if offsetInDash >= dl - Tolerance.distance {
                idx += 1
                offsetInDash = 0
            }
        }
    }
}
