//
//  CommandMatcher.swift
//  CADEngine
//
//  The pure, GUI-free fuzzy matcher behind the ⌘K command palette. It takes a
//  user query and a list of candidate titles and returns the candidates whose
//  title contains the query as a (case-insensitive) subsequence, ranked so that
//  the most "obvious" hits float to the top:
//
//    1. an exact title match,
//    2. a title that *starts with* the query (prefix),
//    3. a match that begins on a word boundary (start of a word in the title),
//    4. a contiguous run of the query inside the title (substring),
//    5. a scattered subsequence (letters in order but not adjacent).
//
//  Within the same tier ties break on a compactness penalty (how spread out the
//  matched letters are) and then on the shorter title — so "lin" ranks "Line"
//  above "Linear Dimension" while still surfacing both.
//
//  This type is intentionally in CADEngine (not the SwiftUI app target) so it is
//  unit-testable as plain logic: the palette view in LibreCADmacOS feeds it the
//  registry titles and renders whatever it returns.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// A pure fuzzy subsequence matcher + ranker for the command palette.
///
/// All scoring is deterministic and side-effect-free; the SwiftUI layer owns no
/// matching logic, it only asks `CommandMatcher` for the filtered/ranked order.
public enum CommandMatcher {

    /// One scored hit: the candidate's index in the input array, its rank score
    /// (higher is better), and the indices (into the candidate title) of the
    /// characters that matched — handy for highlighting in the UI.
    public struct Match: Sendable, Equatable {
        /// Index of the matched candidate in the array passed to `rank`.
        public let index: Int
        /// Composite rank score; larger means a better/closer match.
        public let score: Double
        /// Offsets into the candidate string where the query characters landed.
        public let matchedIndices: [Int]

        public init(index: Int, score: Double, matchedIndices: [Int]) {
            self.index = index
            self.score = score
            self.matchedIndices = matchedIndices
        }
    }

    /// Returns whether `query` is a case-insensitive subsequence of `candidate`
    /// (every query character appears, in order, somewhere in the candidate).
    /// An empty query trivially matches.
    public static func matches(_ query: String, _ candidate: String) -> Bool {
        score(query: query, candidate: candidate) != nil
    }

    /// Filters `candidates` to those matching `query` and returns them sorted
    /// best-first. An empty/whitespace-only query returns ALL candidates in their
    /// original order (score 0), so the palette shows the full list before typing.
    ///
    /// - Parameters:
    ///   - query: the user's search text.
    ///   - candidates: the candidate titles, indexed positionally.
    /// - Returns: ranked `Match` values, best (highest score) first. Ties break
    ///   deterministically by original index so the order is stable.
    public static func rank(query: String, candidates: [String]) -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty query: everything matches, original order preserved.
            return candidates.indices.map { Match(index: $0, score: 0, matchedIndices: []) }
        }

        var hits: [Match] = []
        hits.reserveCapacity(candidates.count)
        for (i, candidate) in candidates.enumerated() {
            if let (s, idx) = score(query: trimmed, candidate: candidate) {
                hits.append(Match(index: i, score: s, matchedIndices: idx))
            }
        }

        // Best score first; ties → shorter title first; final tie → original
        // index (stable, deterministic).
        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let la = candidates[a.index].count
            let lb = candidates[b.index].count
            if la != lb { return la < lb }
            return a.index < b.index
        }
        return hits
    }

    // MARK: - Scoring

    /// Scores one candidate against the query, or returns `nil` when the query is
    /// not a subsequence of the candidate. Higher scores are better matches.
    ///
    /// The score is built from tiered base bonuses (exact / prefix / word-boundary
    /// / contiguous) plus a per-character word-boundary bonus, minus a compactness
    /// penalty for spread-out matches. Length is used only as a final tie-break in
    /// `rank`, not folded into the score, so tiers never invert on long titles.
    static func score(query: String, candidate: String) -> (score: Double, indices: [Int])? {
        let q = Array(query.lowercased())
        let cOriginal = Array(candidate)
        let c = Array(candidate.lowercased())
        guard !q.isEmpty else { return (0, []) }
        guard q.count <= c.count else { return nil }

        // Greedy left-to-right subsequence walk, recording where each query
        // character matched.
        var matched: [Int] = []
        matched.reserveCapacity(q.count)
        var qi = 0
        for ci in c.indices where qi < q.count {
            if c[ci] == q[qi] {
                matched.append(ci)
                qi += 1
            }
        }
        guard qi == q.count else { return nil } // not a subsequence

        var score = 0.0

        // Tier 1: exact (case-insensitive) full-string match.
        if q.count == c.count {
            score += 1000
        }
        // Tier 2: prefix — the candidate starts with the query.
        else if matched.first == 0 && isContiguous(matched) {
            score += 500
        }
        // Tier 3: a contiguous run beginning on a word boundary.
        else if isContiguous(matched), let first = matched.first,
                isWordBoundary(at: first, in: cOriginal) {
            score += 300
        }
        // Tier 4: any contiguous run (substring) inside the title.
        else if isContiguous(matched) {
            score += 150
        }
        // Tier 5: scattered subsequence — implicit base of 0.

        // Per-character word-boundary bonus: reward matches that begin words even
        // when the overall run is scattered (e.g. "ld" → "Linear Dimension").
        for idx in matched where isWordBoundary(at: idx, in: cOriginal) {
            score += 12
        }

        // Compactness: penalize gaps between consecutive matched characters so a
        // tight run beats a spread-out one within the same tier.
        if let first = matched.first, let last = matched.last {
            let span = last - first + 1
            let gaps = span - matched.count    // 0 when fully contiguous
            score -= Double(gaps) * 3
        }

        // A small bonus for matching earlier in the string (closer to the front
        // reads as more relevant), capped so it never crosses a tier.
        if let first = matched.first {
            score += max(0, 10 - Double(first))
        }

        return (score, matched)
    }

    /// Whether the matched indices form a contiguous run (no gaps).
    private static func isContiguous(_ indices: [Int]) -> Bool {
        guard let first = indices.first, let last = indices.last else { return true }
        return last - first + 1 == indices.count
    }

    /// Whether position `i` starts a "word" in `chars`: index 0, or the first
    /// alphanumeric after a separator (space / punctuation), or a lowercase→
    /// uppercase camelCase boundary.
    private static func isWordBoundary(at i: Int, in chars: [Character]) -> Bool {
        guard i > 0 else { return true }
        let prev = chars[i - 1]
        let cur = chars[i]
        if !prev.isLetter && !prev.isNumber { return true }            // after a separator
        if prev.isLowercase && cur.isUppercase { return true }         // camelCase hump
        return false
    }
}
