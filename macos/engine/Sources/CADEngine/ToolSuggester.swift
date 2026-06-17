//
//  ToolSuggester.swift
//  CADEngine
//
//  The pure, GUI-free brain behind the bottom COMMAND BAR's tool chips (the
//  AutoCAD-style launcher that replaces the old ~50-button toolbar). It answers
//  one question — "given what the user has typed, what is selected, and which
//  tools they used recently, which ~8-10 tools should the chip row show?" — with
//  no SwiftUI, no globals, and no side effects, so it is fully unit-testable.
//
//  Two behaviors, both deterministic:
//    • EMPTY query → an ADAPTIVE default set: a curated CORE (Select, Line,
//      Circle, Arc, Rectangle, Polyline) blended with the most-recently-used
//      tools and a SELECTION-CONTEXT bias — when something is selected we surface
//      Modify tools (Move, Copy, Trim, …) first, otherwise Draw tools. Deduped,
//      stable, capped (~10).
//    • NON-EMPTY query → fuzzy-filter EVERY `ToolKind` (matching the title AND a
//      table of sensible aliases — "rect"→Rectangle, "dim"→a dimension tool)
//      using the shared `CommandMatcher`, returning the ranked matches capped.
//
//  The roster (core / draw / modify lists + aliases) lives in `ToolSuggestionCatalog`
//  so the app can supply its own, but the built-in `.default` mirrors the app's
//  `ToolCatalog` grouping and is what the tests pin. Because `ToolKind` lives in
//  CADEngine, this whole file is engine-visible and the tests reach it directly via
//  `@testable import CADEngine` (no app-module symlink needed).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// The data the suggester ranks over: the curated CORE set, the DRAW and MODIFY
/// rosters (for the selection-context bias), and a per-tool alias table (extra
/// search terms beyond the title). Pure value type; the app passes one in (or uses
/// `.default`, which mirrors `ToolCatalog`).
public struct ToolSuggestionCatalog: Sendable {
    /// The always-relevant curated core, in display order. Shown first in the empty
    /// (adaptive) set regardless of selection.
    public let core: [ToolKind]
    /// Geometry-creating tools, in display order. Surfaced (after the core) when
    /// nothing is selected — the user is about to draw.
    public let draw: [ToolKind]
    /// Selection-transform tools, in display order. Surfaced (after the core) when
    /// something IS selected — the user is about to modify it.
    public let modify: [ToolKind]
    /// Extra search terms per tool (lowercased), matched alongside the title so
    /// "rect"→Rectangle, "dim"→the dimension tools, "poly"→Polyline, etc.
    public let aliases: [ToolKind: [String]]

    public init(core: [ToolKind],
                draw: [ToolKind],
                modify: [ToolKind],
                aliases: [ToolKind: [String]]) {
        self.core = core
        self.draw = draw
        self.modify = modify
        self.aliases = aliases
    }

    /// The built-in catalog, mirroring the app's `ToolCatalog` grouping. The CORE is
    /// the brief's curated launcher set; the MODIFY bias list is the brief's
    /// selection-context set (Move, Copy, Trim, Offset, Fillet, Mirror, Rotate,
    /// Scale); the DRAW bias list is the everyday geometry tools. Aliases cover the
    /// short words users actually type.
    public static let `default` = ToolSuggestionCatalog(
        core: [.select, .line, .circle, .arc, .rectangle, .polyline],
        draw: [.line, .circle, .arc, .rectangle, .polyline, .ellipse, .polygon, .point, .spline, .hatch],
        modify: [.move, .copy, .trim, .offset, .fillet, .mirror, .rotate, .scale],
        aliases: defaultAliases
    )

    /// Sensible short aliases per tool (lowercased). Only the non-obvious ones are
    /// listed; the title is always matched in addition to these.
    ///
    /// Many entries carry the canonical short **AutoCAD command aliases** (e.g. `l`→Line,
    /// `c`→Circle, `a`→Arc, `o`→Offset, `tr`→Trim) so a muscle-memory user can type the
    /// classic single/two-letter command and `resolve(command:)` jumps straight to the
    /// tool. These are deliberately exact-match-only winners: `resolve` checks aliases
    /// before any fuzzy fallback, so `"a"` resolves to Arc rather than fuzz-matching some
    /// other title. Every alias here is unique across kinds (see `noDuplicateAliases`).
    static let defaultAliases: [ToolKind: [String]] = [
        .select: ["pan", "cursor", "pick"],
        .line: ["l", "ln"],
        .circle: ["c", "circ"],
        .arc: ["a"],
        .rectangle: ["r", "rec", "rect", "box"],
        .polyline: ["poly", "pline", "pl"],
        .point: ["pt", "node"],
        .ellipse: ["el", "oval"],
        .polygon: ["poly", "ngon"],
        .move: ["m", "mv"],
        .copy: ["co", "cp", "duplicate"],
        .rotate: ["ro", "rot", "turn"],
        .scale: ["resize"],
        .offset: ["o", "off"],
        .trim: ["tr", "cut"],
        .extend: ["ex", "ext"],
        .fillet: ["round", "corner"],
        .chamfer: ["bevel"],
        .mirror: ["mi"],
        .text: ["t", "dt", "mt", "txt", "label", "mtext"],
        .linearDim: ["dim", "dimension", "measure"],
        .alignedDim: ["dim", "dimension"],
        .radialDim: ["dim", "radius"],
        .diameterDim: ["dim", "dia"],
        .angularDim: ["dim", "angle"],
        .ordinateDim: ["dim", "coordinate"],
        .arcLengthDim: ["dim"],
        .angular3pDim: ["dim", "angle"],
        .baselineDim: ["dim"],
        .continueDim: ["dim"],
        .leader: ["callout", "annotation"],
        .measureDistance: ["dist", "measure"],
        .measureAngle: ["measure", "angle"],
        .measureArea: ["measure", "area"],
        .measureLength: ["measure", "length"],
        .hatch: ["fill", "pattern"],
        .image: ["img", "raster", "picture", "photo"],
        .insert: ["block", "blk"],
        .createBlock: ["block", "group"],
        .explodeInsert: ["block"],
        .xline: ["construction", "infinite"],
        .ray: ["construction"],
        .array: ["arr", "grid"],
        .arrayPath: ["array", "path"],
    ]
}

/// The pure suggester: maps (query, selection state, recently-used) → the ordered
/// `ToolKind`s the command bar should show as chips. No SwiftUI, no globals.
public enum ToolSuggester {

    /// The default chip cap (~10) the brief calls for.
    public static let defaultCap = 10

    /// The ordered tools the command bar should display AS CHIPS.
    ///
    /// Wave 4 de-mirror (plan §3d): the command bar is now a true command LINE, not a
    /// static mirror of a default tool set. So:
    /// - When `query` is empty (or whitespace) → **NO chips** (`[]`). The bar shows a
    ///   prompt hint instead, with the most-recently-used tools surfaced separately as
    ///   a clearly-labeled "Recent" row (see `recents(mru:excluding:cap:)`).
    /// - Otherwise → a fuzzy filter of EVERY `ToolKind` (title + aliases) ranked by
    ///   the shared `CommandMatcher`, capped at `cap`. These are the only chips.
    ///
    /// - Parameters:
    ///   - query: the user's typed text.
    ///   - hasSelection: retained for source compatibility; no longer affects the
    ///     result now that the empty-query adaptive mirror is gone (the fuzzy path is
    ///     query-only, the empty path is empty).
    ///   - mru: most-recently-used tools — surfaced via `recents`, NOT as chips here.
    ///   - catalog: the roster + aliases to rank over (defaults to `.default`).
    ///   - cap: the maximum number of chips (defaults to ~10).
    public static func suggestions(query: String,
                                   hasSelection: Bool,
                                   mru: [ToolKind],
                                   catalog: ToolSuggestionCatalog = .default,
                                   cap: Int = defaultCap) -> [ToolKind] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // De-mirror: an empty query shows no chips at all (a prompt hint + Recent row
        // take their place). Chips/results appear ONLY while typing.
        if trimmed.isEmpty { return [] }
        return fuzzySet(query: trimmed, catalog: catalog, cap: cap)
    }

    // MARK: - Empty query → labeled "Recent" row (NOT chips)

    /// The most-recently-used tools to surface as a clearly-labeled "Recent" row when
    /// the query is empty — the replacement for the dropped static chip mirror. Most-
    /// recent first, with any `excluding` tools (e.g. the ones already PINNED to the
    /// toolbar) removed so the row never duplicates a button the user already has, and
    /// capped at `cap`. Pure — no SwiftUI, fully unit-testable.
    ///
    /// - Parameters:
    ///   - mru: most-recently-used tools, most-recent FIRST.
    ///   - excluding: tools to omit (typically the pinned toolbar set).
    ///   - cap: the maximum number of recent chips.
    public static func recents(mru: [ToolKind],
                               excluding: Set<ToolKind> = [],
                               cap: Int = defaultCap) -> [ToolKind] {
        var seen = Set<ToolKind>()
        var ordered: [ToolKind] = []
        for kind in mru where !excluding.contains(kind) && !seen.contains(kind) {
            seen.insert(kind)
            ordered.append(kind)
        }
        return Array(ordered.prefix(Swift.max(0, cap)))
    }

    // MARK: - Adaptive default set (LEGACY — retained for API stability)
    //
    // The empty-query path no longer calls `adaptiveSet` (Wave 4 dropped the static
    // mirror). It is kept (with its catalog rosters) so the public `ToolSuggestionCatalog`
    // shape and any external callers stay source-compatible; the command bar uses
    // `recents` for the empty state instead.

    /// The pre-typing chip set: curated core, then MRU, then the context roster
    /// (Modify when something is selected, else Draw). Dedup keeps the FIRST
    /// occurrence so the curated order is stable and the cap is respected.
    static func adaptiveSet(hasSelection: Bool,
                            mru: [ToolKind],
                            catalog: ToolSuggestionCatalog,
                            cap: Int) -> [ToolKind] {
        var ordered: [ToolKind] = []
        var seen = Set<ToolKind>()

        func append(_ kinds: [ToolKind]) {
            for k in kinds where !seen.contains(k) {
                seen.insert(k)
                ordered.append(k)
            }
        }

        // 1) The curated core is always first (Select stays reachable as a chip).
        append(catalog.core)
        // 2) Then the user's recently-used tools (most-recent first), so the bar
        //    learns the user's habits without ever dropping the core.
        append(mru)
        // 3) Then fill with the context roster: Modify tools when something is
        //    selected (the user is about to act on it), else Draw tools.
        append(hasSelection ? catalog.modify : catalog.draw)

        return Array(ordered.prefix(Swift.max(0, cap)))
    }

    // MARK: - Non-empty query → fuzzy filter

    /// Every `ToolKind` whose title OR an alias fuzzy-matches `query`, ranked by the
    /// shared `CommandMatcher` (the same matcher the ⌘K palette uses), capped. A tool
    /// is scored on the BEST of its title + each alias, so "rect" surfaces Rectangle
    /// via its alias even though the title doesn't start with "rect".
    static func fuzzySet(query: String,
                         catalog: ToolSuggestionCatalog,
                         cap: Int) -> [ToolKind] {
        // Score every kind on the best of {title} ∪ {aliases}. We keep the kind's
        // own index so ties break deterministically on the canonical `ToolKind` order.
        var scored: [(kind: ToolKind, order: Int, score: Double)] = []
        for (order, kind) in ToolKind.allCases.enumerated() {
            var terms = [kind.title]
            if let aliases = catalog.aliases[kind] { terms.append(contentsOf: aliases) }
            // The best score across the tool's search terms (nil ⇒ no term matched).
            var best: Double?
            for term in terms {
                if let (s, _) = CommandMatcher.score(query: query, candidate: term) {
                    best = Swift.max(best ?? -.greatestFiniteMagnitude, s)
                }
            }
            if let best { scored.append((kind, order, best)) }
        }

        // Best score first; ties → the canonical `ToolKind` order (stable). This
        // mirrors `CommandMatcher.rank`'s tie discipline so the chips read sensibly.
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.order < b.order
        }
        return scored.prefix(Swift.max(0, cap)).map(\.kind)
    }

    // MARK: - Command-word → tool resolution (pure)

    /// The minimum `CommandMatcher.score` a FUZZY (non-exact) match must clear for
    /// `resolve` to return it. Below this, `resolve` returns `nil` rather than guessing,
    /// so clear garbage (`"xyzzy"`) launches nothing.
    ///
    /// Rationale, tied to `CommandMatcher`'s tiers: an exact full-string match scores
    /// 1000 and a *prefix* match scores 500 (`"rectang"` → "Rectangle" is a prefix, so
    /// it clears this easily). A pure scattered subsequence has a base tier of 0 plus
    /// only small per-character / proximity bonuses — exactly the "letters happen to
    /// appear in order" noise we want to reject. Requiring at least a contiguous run
    /// inside the title (tier 4 = 150) keeps `resolve` from firing a tool just because
    /// the typed letters are sprinkled through some unrelated title. `suggestions`/`fuzzySet`
    /// intentionally show *all* subsequence hits (it's a chooser); `resolve` commits to
    /// ONE tool, so it holds a higher bar.
    public static let resolveFuzzyThreshold: Double = 150

    /// Resolves a typed command word to a single `ToolKind`, or `nil` when nothing is a
    /// confident match. Pure — no SwiftUI, no globals; the command LINE calls this when
    /// the user presses ↵ on free text.
    ///
    /// Resolution order (first win returns):
    ///   1. **Exact match wins.** After trim + lowercase, if the input equals a kind's
    ///      `title` (case-insensitive) OR any of its aliases, return that kind. Ties on a
    ///      shared alias (e.g. several dimension tools answer to `"dim"`) break on the
    ///      canonical `ToolKind.allCases` order — deterministic, never random.
    ///   2. **Fuzzy fallback.** Otherwise rank every kind's {title ∪ aliases} with the
    ///      shared `CommandMatcher` (exactly as `fuzzySet`), and return the single best
    ///      kind — but ONLY if its score clears `resolveFuzzyThreshold`. Below the bar →
    ///      `nil` (so `"xyzzy"` resolves to nothing rather than a random tool).
    ///
    /// - Parameters:
    ///   - command: the user's typed word (any case / surrounding whitespace).
    ///   - catalog: the roster + aliases to resolve against (defaults to `.default`).
    /// - Returns: the matched `ToolKind`, or `nil` for empty / unrecognized input.
    public static func resolve(command: String,
                               catalog: ToolSuggestionCatalog = .default) -> ToolKind? {
        let needle = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }

        // 1) Exact match (title or alias). Scan in canonical order so a needle shared by
        //    several kinds (e.g. "dim") deterministically resolves to the FIRST kind.
        for kind in ToolKind.allCases {
            if kind.title.lowercased() == needle { return kind }
            if let aliases = catalog.aliases[kind], aliases.contains(needle) { return kind }
        }

        // 2) Fuzzy fallback — best CommandMatcher score across {title ∪ aliases}, gated
        //    by the threshold. Mirrors `fuzzySet`'s scoring + tie discipline but commits
        //    to exactly one tool (or none).
        var best: (kind: ToolKind, order: Int, score: Double)?
        for (order, kind) in ToolKind.allCases.enumerated() {
            var terms = [kind.title]
            if let aliases = catalog.aliases[kind] { terms.append(contentsOf: aliases) }
            var kindBest: Double?
            for term in terms {
                if let (s, _) = CommandMatcher.score(query: needle, candidate: term) {
                    kindBest = Swift.max(kindBest ?? -.greatestFiniteMagnitude, s)
                }
            }
            guard let kindBest else { continue }
            if let cur = best {
                // Higher score wins; ties → canonical order (stable, deterministic).
                if kindBest > cur.score || (kindBest == cur.score && order < cur.order) {
                    best = (kind, order, kindBest)
                }
            } else {
                best = (kind, order, kindBest)
            }
        }

        guard let best, best.score >= resolveFuzzyThreshold else { return nil }
        return best.kind
    }

    // MARK: - Alias hygiene (pure, for tests)

    /// Aliases that are *intentionally* shared across kinds — broad fuzzy SEARCH terms
    /// (not command aliases) that several related tools all answer to. `resolve` handles
    /// the ambiguity deterministically (canonical-order first wins); the duplicate-alias
    /// hygiene check ignores these on purpose.
    static let intentionallySharedAliases: Set<String> = [
        "poly", "dim", "dimension", "angle", "measure", "block", "construction", "array",
    ]

    /// Diagnostic: alias strings claimed by MORE THAN ONE kind in `catalog.aliases`,
    /// EXCLUDING the deliberately-shared fuzzy terms in `intentionallySharedAliases`.
    /// Pure helper so tests can assert the short command aliases stay collision-free
    /// without re-implementing the scan. Returns each offending alias mapped to the kinds
    /// that claim it.
    static func duplicateCommandAliases(
        catalog: ToolSuggestionCatalog = .default
    ) -> [String: [ToolKind]] {
        var owners: [String: [ToolKind]] = [:]
        // Canonical order so the reported owner lists are deterministic.
        for kind in ToolKind.allCases {
            guard let aliases = catalog.aliases[kind] else { continue }
            for alias in aliases where !intentionallySharedAliases.contains(alias) {
                owners[alias, default: []].append(kind)
            }
        }
        return owners.filter { $0.value.count > 1 }
    }

    // MARK: - MRU maintenance (pure)

    /// Returns a new MRU list with `kind` promoted to the FRONT (most-recent), any
    /// prior occurrence removed (no duplicates), and the list capped at `limit`. Pure
    /// — the caller (the view's `@AppStorage`-backed list) stores the result. Keeping
    /// it here makes the "activation updates MRU" rule unit-testable.
    public static func updatedMRU(_ mru: [ToolKind],
                                  used kind: ToolKind,
                                  limit: Int = 12) -> [ToolKind] {
        var next = mru.filter { $0 != kind }
        next.insert(kind, at: 0)
        if next.count > limit { next.removeLast(next.count - limit) }
        return next
    }
}
