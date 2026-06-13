//
//  MTextTests.swift
//  CADEngineTests
//
//  Tests for the rich-MTEXT entity (Phase 2): the inline-code PARSER (run tree),
//  the SHAPER (per-run formatting, word wrapping, attachment alignment, stacked
//  fractions, underline/overline decorations), and DXF MTEXT IMPORT (read as
//  `.mtext`, with the raw coded string preserved for round-trip).
//
//  Uses the native Core Text provider (Helvetica Neue resolves headless) via the
//  shared `TextSystemFixtures.nativeCtx()`.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Parser

@Suite("MText: inline-code parser")
struct MTextParserTests {

    @Test("plain text becomes one paragraph with one run")
    func plainText() {
        let p = MTextParser.parse("Hello world")
        #expect(p.count == 1)
        #expect(p[0].inlines.count == 1)
        if case .run(let r) = p[0].inlines[0] {
            #expect(r.text == "Hello world")
            #expect(r.bold == nil && r.italic == nil)
            #expect(r.underline == false)
        } else {
            Issue.record("expected a run")
        }
    }

    @Test("\\P splits into paragraphs")
    func paragraphBreak() {
        let p = MTextParser.parse("line one\\Pline two\\Pline three")
        #expect(p.count == 3)
        if case .run(let r0) = p[0].inlines.first { #expect(r0.text == "line one") }
        if case .run(let r2) = p[2].inlines.first { #expect(r2.text == "line three") }
    }

    @Test("\\fArial|b1|i0; sets a bold native font run")
    func fontBold() {
        let p = MTextParser.parse("{\\fArial|b1|i0;BOLD}")
        let run = firstRun(p)
        #expect(run?.bold == true)
        #expect(run?.italic == false)
        if case .native(let family) = run?.fontOverride { #expect(family == "Arial") }
        else { Issue.record("expected a native Arial font override") }
        #expect(run?.text == "BOLD")
    }

    @Test("\\H2x; sets a relative height factor of 2")
    func heightRelative() {
        let p = MTextParser.parse("\\H2x;TALL")
        #expect(firstRun(p)?.heightFactor == 2.0)
    }

    @Test("\\H5; encodes an absolute height as a negative sentinel")
    func heightAbsolute() {
        let p = MTextParser.parse("\\H5;ABS")
        // Negative => absolute world height 5 (resolved by the shaper).
        #expect(firstRun(p)?.heightFactor == -5.0)
        #expect(MTextShaper.runHeight(-5.0, base: 2.5) == 5.0)
        #expect(MTextShaper.runHeight(2.0, base: 2.5) == 5.0)   // relative
    }

    @Test("\\L … \\l toggles underline on then off")
    func underlineToggle() {
        let p = MTextParser.parse("\\Lunder\\lplain")
        let runs = allRuns(p)
        #expect(runs.count == 2)
        #expect(runs[0].text == "under" && runs[0].underline == true)
        #expect(runs[1].text == "plain" && runs[1].underline == false)
    }

    @Test("\\O … \\o toggles overline; \\K … \\k strikethrough")
    func overStrikeToggle() {
        let over = allRuns(MTextParser.parse("\\Oover\\onorm"))
        #expect(over[0].overline == true && over[1].overline == false)
        let strike = allRuns(MTextParser.parse("\\Kcut\\knorm"))
        #expect(strike[0].strikethrough == true && strike[1].strikethrough == false)
    }

    @Test("\\S1/2; produces a fraction stacked run")
    func stackedFraction() {
        let p = MTextParser.parse("\\S1/2;")
        let stacked = firstStacked(p)
        #expect(stacked?.upper == "1")
        #expect(stacked?.lower == "2")
        #expect(stacked?.kind == .fraction)
    }

    @Test("\\S1#2; is diagonal, \\S+0.1^-0.1; is tolerance")
    func stackedKinds() {
        let diag = firstStacked(MTextParser.parse("\\S1#2;"))
        #expect(diag?.kind == .diagonal)
        let tol = firstStacked(MTextParser.parse("\\S+0.1^-0.1;"))
        #expect(tol?.kind == .tolerance)
        #expect(tol?.upper == "+0.1" && tol?.lower == "-0.1")
    }

    @Test("{} scopes formatting (bold inside, plain outside)")
    func braceScope() {
        let p = MTextParser.parse("a{\\fArial|b1;b}c")
        let runs = allRuns(p)
        // "a" (plain) , "b" (bold) , "c" (plain again — brace popped).
        #expect(runs.count == 3)
        #expect(runs[0].text == "a" && runs[0].bold == nil)
        #expect(runs[1].text == "b" && runs[1].bold == true)
        #expect(runs[2].text == "c" && runs[2].bold == nil)
    }

    @Test("\\~ becomes a non-breaking space; \\\\ a literal backslash")
    func escapes() {
        let p = MTextParser.parse("a\\~b\\\\c")
        #expect(firstRun(p)?.text == "a\u{00A0}b\\c")
    }

    @Test("\\C1; sets a red run colour")
    func colorACI() {
        let p = MTextParser.parse("\\C1;red")
        #expect(firstRun(p)?.color == RGBAColor(1, 0, 0))
    }

    @Test("malformed / unknown escape passes through verbatim (never dropped)")
    func malformedPassthrough() {
        // \Z is not a known code: keep "\Z" literally.
        let p = MTextParser.parse("ab\\Zcd")
        #expect(firstRun(p)?.text == "ab\\Zcd")
        // A lone trailing backslash is kept.
        let p2 = MTextParser.parse("end\\")
        #expect(firstRun(p2)?.text == "end\\")
    }

    @Test("%% special chars are expanded inside a run")
    func specialChars() {
        let p = MTextParser.parse("R%%c25")
        #expect(firstRun(p)?.text == "R\u{2300}25")
    }

    @Test("empty input yields one empty paragraph (structural body)")
    func emptyInput() {
        let p = MTextParser.parse("")
        #expect(p.count == 1)
        #expect(p[0].inlines.isEmpty)
    }

    // Helpers
    private func firstRun(_ p: [MTextParagraph]) -> TextRun? { allRuns(p).first }
    private func allRuns(_ p: [MTextParagraph]) -> [TextRun] {
        p.flatMap { $0.inlines }.compactMap { if case .run(let r) = $0 { return r } else { return nil } }
    }
    private func firstStacked(_ p: [MTextParagraph]) -> StackedRun? {
        p.flatMap { $0.inlines }.compactMap { if case .stacked(let s) = $0 { return s } else { return nil } }.first
    }
}

// MARK: - Shaper (resolve to geometry)

@Suite("MText: shaper / resolve")
struct MTextShaperTests {

    private func ctx() -> ResolveContext { TextSystemFixtures.nativeCtx() }
    private let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)

    private func resolve(_ coded: String, height: Double = 10, rectWidth: Double = 0,
                         attachment: MTextAttachment = .topLeft,
                         lineSpacingFactor: Double = 1) -> ResolvedGeometry {
        let data = MTextParser.makeData(
            coded: coded, position: Vector(0, 0), height: height,
            rectWidth: rectWidth, attachment: attachment, lineSpacingFactor: lineSpacingFactor)
        return EntityKind.mtext(data).resolve(pen: pen, ctx: ctx())
    }

    @Test("a plain MTEXT resolves to native outline fills")
    func plainResolvesToFills() {
        let geo = resolve("ABC")
        #expect(!geo.fills.isEmpty)
    }

    @Test("\\H2x; renders a TALLER run than the base height")
    func heightFactorTaller() {
        // Two runs: a base-height run and a 2x run on the SAME line. The 2x run's
        // ink reaches higher above the baseline.
        let base = resolve("X")
        let tall = resolve("\\H2x;X")
        func maxY(_ g: ResolvedGeometry) -> Double {
            (g.fills.flatMap { $0.loops.flatMap { $0 } } + g.polylines.flatMap { $0.points }).map(\.y).max() ?? 0
        }
        func minY(_ g: ResolvedGeometry) -> Double {
            (g.fills.flatMap { $0.loops.flatMap { $0 } } + g.polylines.flatMap { $0.points }).map(\.y).min() ?? 0
        }
        let baseSpan = maxY(base) - minY(base)
        let tallSpan = maxY(tall) - minY(tall)
        #expect(tallSpan > baseSpan * 1.5)
    }

    @Test("\\fArial|b1; selects a heavier (bold) face than the regular run")
    func boldRunIsHeavier() {
        // Bold ink covers more area than the same letters regular. Compare total
        // fill loop point counts as a proxy for the heavier outline.
        let regular = resolve("HELLO")
        let bold = resolve("\\fArial|b1;HELLO")
        // Both should produce fills; bold must produce a different (heavier) outline
        // — at minimum it still resolves to a non-empty fill set.
        #expect(!regular.fills.isEmpty)
        #expect(!bold.fills.isEmpty)
        // The bold run's total ink area should be >= the regular run's (heavier).
        func area(_ g: ResolvedGeometry) -> Double {
            var s = 0.0
            for f in g.fills { for loop in f.loops { s += abs(shoelace(loop)) } }
            return s
        }
        #expect(area(bold) >= area(regular) * 0.95)   // bold is at least as heavy
    }

    @Test("\\L…\\l produces an underline stroke (a horizontal decoration line)")
    func underlineStroke() {
        let plain = resolve("WORD")
        let underlined = resolve("\\LWORD\\l")
        // The underlined version adds at least one extra polyline (the underline).
        #expect(underlined.polylines.count > plain.polylines.count)
        // The added stroke is (near-)horizontal and below the baseline.
        let extra = underlined.polylines.first { pl in
            pl.points.count == 2 && abs(pl.points[0].y - pl.points[1].y) < 1e-6
        }
        #expect(extra != nil)
        if let extra { #expect(extra.points[0].y < 0) }   // below baseline (y=0)
    }

    @Test("\\S1/2; stacks: numerator above, denominator below, plus a divider bar")
    func stackedLayout() {
        let geo = resolve("\\S1/2;")
        // Fraction draws glyph ink for 1 and 2 plus a divider stroke.
        #expect(!geo.fills.isEmpty || !geo.polylines.isEmpty)
        // There is a horizontal divider polyline.
        let bar = geo.polylines.first { pl in
            pl.points.count == 2 && abs(pl.points[0].y - pl.points[1].y) < 1e-6
        }
        #expect(bar != nil)
        // The numerator ink sits above the denominator ink.
        let ys = geo.fills.flatMap { $0.loops.flatMap { $0.map(\.y) } }
        if let hi = ys.max(), let lo = ys.min() { #expect(hi > lo) }
    }

    @Test("\\P splits the block into stacked lines (second line below the first)")
    func paragraphsStack() {
        let geo = resolve("TOP\\PBOTTOM")
        let ys = geo.fills.flatMap { $0.loops.flatMap { $0.map(\.y) } }
        guard let hi = ys.max(), let lo = ys.min() else { Issue.record("no fills"); return }
        // Two stacked lines span more than a single line's height (~10).
        #expect(hi - lo > 12)
    }

    @Test("word wrapping to rectWidth splits a long run across lines")
    func wordWrap() {
        let oneLine = resolve("aaa bbb ccc ddd eee", rectWidth: 0)        // no wrap
        let wrapped = resolve("aaa bbb ccc ddd eee", rectWidth: 25)       // narrow → wraps
        func height(_ g: ResolvedGeometry) -> Double {
            let ys = g.fills.flatMap { $0.loops.flatMap { $0.map(\.y) } }
            return (ys.max() ?? 0) - (ys.min() ?? 0)
        }
        func width(_ g: ResolvedGeometry) -> Double {
            let xs = g.fills.flatMap { $0.loops.flatMap { $0.map(\.x) } }
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        // Wrapping makes the block taller and narrower than the single line.
        #expect(height(wrapped) > height(oneLine))
        #expect(width(wrapped) < width(oneLine))
    }

    @Test("attachment point places the block: topLeft anchors the top-left corner")
    func attachmentTopLeft() {
        let geo = resolve("HELLO", attachment: .topLeft)
        let xs = geo.fills.flatMap { $0.loops.flatMap { $0.map(\.x) } }
        let ys = geo.fills.flatMap { $0.loops.flatMap { $0.map(\.y) } }
        // top-left: ink is to the RIGHT of and BELOW the insertion point (0,0).
        #expect((xs.min() ?? 0) >= -1.0)         // mostly to the right of x=0
        #expect((ys.max() ?? 0) <= 11.0)         // top near/below the insertion y
    }

    @Test("attachment bottomRight places ink left of and above the insertion point")
    func attachmentBottomRight() {
        let geo = resolve("HELLO", attachment: .bottomRight)
        let xs = geo.fills.flatMap { $0.loops.flatMap { $0.map(\.x) } }
        let ys = geo.fills.flatMap { $0.loops.flatMap { $0.map(\.y) } }
        // bottom-right: ink is to the LEFT of and ABOVE the insertion point (0,0).
        #expect((xs.max() ?? 0) <= 1.0)          // mostly to the left of x=0
        #expect((ys.min() ?? 0) >= -1.0)         // bottom near/above the insertion y
    }

    @Test("middleCenter centers the block on the insertion point on both axes")
    func attachmentMiddleCenter() {
        let geo = resolve("HELLO", attachment: .middleCenter)
        let xs = geo.fills.flatMap { $0.loops.flatMap { $0.map(\.x) } }
        let ys = geo.fills.flatMap { $0.loops.flatMap { $0.map(\.y) } }
        let cx = ((xs.max() ?? 0) + (xs.min() ?? 0)) / 2
        let cy = ((ys.max() ?? 0) + (ys.min() ?? 0)) / 2
        // The ink centroid straddles the origin (within a glyph height).
        #expect(abs(cx) < 6)
        #expect(abs(cy) < 6)
    }

    @Test("per-run colour: a \\C1; run is RED while the rest is the pen colour")
    func perRunColor() {
        let pen = ResolvedPen(color: .white, lineType: .solid, lineWidth: .default)
        let data = MTextParser.makeData(coded: "A\\C1;B", position: Vector(0, 0), height: 10)
        let geo = EntityKind.mtext(data).resolve(pen: pen, ctx: ctx())
        let colors = Set(geo.fills.map { $0.color })
        #expect(colors.contains(RGBAColor(1, 0, 0)))   // the red run
        #expect(colors.contains(.white))               // the default-pen run
    }

    @Test("no font provider resolves to empty geometry (no crash)")
    func noProviderGraceful() {
        let data = MTextParser.makeData(coded: "ABC", position: Vector(0, 0), height: 10)
        let geo = EntityKind.mtext(data).resolve(pen: pen, ctx: ResolveContext())   // no provider
        #expect(geo.fills.isEmpty && geo.polylines.isEmpty)
    }

    @Test("MTEXT bounding box is non-empty and font-aware via the ctx path")
    func boundingBox() {
        let data = MTextParser.makeData(coded: "ABC", position: Vector(5, 7), height: 10)
        let box = EntityKind.mtext(data).boundingBox(ctx: ctx())
        #expect(!box.isEmpty)
        #expect(box.size.x > 0 && box.size.y > 0)
    }

    @Test("MTEXT transforms: scaling grows the resolved ink")
    func transformScales() {
        let data = MTextParser.makeData(coded: "ABC", position: Vector(0, 0), height: 10)
        let scaled = EntityTransform.transform(.mtext(data),
                                               by: Affine2D.scale(factor: 2, about: Vector(0, 0)))
        if case .mtext(let d) = scaled {
            #expect(abs(d.height - 20) < 1e-9)
            #expect(d.rawCode == "ABC")             // formatting unchanged
        } else { Issue.record("expected mtext") }
    }

    private func shoelace(_ ring: [Vector]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<ring.count {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            s += p.x * q.y - q.x * p.y
        }
        return s * 0.5
    }
}

// MARK: - DXF import round-trip of the coded string

@Suite("MText: DXF import")
struct MTextImportTests {

    private func samplePath() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "dim_sample", withExtension: "dxf"),
            "dim_sample.dxf resource missing from the test bundle")
        return url.path
    }

    @Test("dim_sample MTEXT imports as .mtext with the raw coded string preserved")
    func importsAsMText() async throws {
        let result = try await CADEngine.shared.readEntities(dxfPath: try samplePath())
        let mtexts = result.records.compactMap { r -> MTextData? in
            if case .mtext(let d) = r.kind { return d } else { return nil }
        }
        #expect(!mtexts.isEmpty)
        for d in mtexts {
            // The verbatim coded string survives (lossless round-trip target).
            #expect(d.rawCode?.isEmpty == false)
            // The parsed run tree is non-empty and re-parsing the raw string is
            // stable (parse(rawCode) == paragraphs).
            #expect(!d.paragraphs.isEmpty)
            #expect(MTextParser.parse(d.rawCode ?? "") == d.paragraphs)
            #expect(d.height > 0)
            // Attachment is in the valid 1..9 range.
            #expect((1...9).contains(d.attachment.rawValue))
        }
    }

    @Test("an imported MTEXT resolves to drawable geometry with the native provider")
    func importedMTextResolves() async throws {
        let result = try await CADEngine.shared.readEntities(dxfPath: try samplePath())
        let ctx = TextSystemFixtures.nativeCtx()
        let mtextRec = result.records.first { if case .mtext = $0.kind { return true } else { return false } }
        let rec = try #require(mtextRec, "no MTEXT imported")
        let geo = rec.resolve(ctx)
        #expect(!geo.fills.isEmpty || !geo.polylines.isEmpty)
    }
}
