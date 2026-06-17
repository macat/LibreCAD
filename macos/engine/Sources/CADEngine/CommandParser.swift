//
//  CommandParser.swift
//  CADEngine
//
//  The pure, GUI-free parser behind the command / coordinate input line (UX-plan
//  U1, decision D7). It turns the string the user types on the bottom command
//  field into a single resolved WORLD point, given the current drawing reference
//  (the relative-zero / last committed-or-picked point) and the live cursor
//  bearing. The SwiftUI command field feeds the result to the active tool as a
//  `ToolInput.value(point)` (which a draw/dimension tool treats like a click at
//  that exact coordinate — no snap drift).
//
//  ## Grammar (ported from LibreCAD's coordinate entry — see
//  ## RS_CommandEvent / the `@`/`<` coordinate syntax users know from AutoCAD):
//
//    x,y            ABSOLUTE point. e.g. `100,50` → (100, 50).
//    @dx,dy         RELATIVE to the reference (relative-zero). e.g. `@10,0` from
//                   (5,5) → (15, 5). Needs a reference (a point already placed).
//    dist<angle     POLAR from the reference: a vector of length `dist` at `angle`
//                   (degrees, CCW from +X by default). e.g. `5<90` from (0,0) →
//                   (0, 5). Polar is inherently relative, so `@dist<angle` is
//                   accepted as the same thing. Needs a reference.
//    dist           A BARE distance → `dist` along the current bearing (the
//                   reference→cursor direction, i.e. the rubber-band direction).
//                   The common "type the length" flow. Needs a reference AND a
//                   live cursor that is not coincident with the reference.
//
//  Whitespace around tokens and the separators is ignored. Numbers accept a
//  leading sign and a decimal point (`-3.5`, `+2`, `.25`). A negative bare
//  distance steps backward along the bearing.
//
//  This type is intentionally in CADEngine (not the SwiftUI app target) so it is
//  unit-testable as plain logic with NO GUI: a test passes a string + reference +
//  cursor and asserts the resolved point (or the parse error).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original coordinate-entry syntax).
//

import Foundation

/// A pure parser for the command/coordinate input line (U1). All methods are
/// `static` — it holds no state; the caller supplies the reference + cursor.
public enum CommandParser {

    // MARK: - Result

    /// The outcome of parsing one command string.
    public enum Result: Equatable, Sendable {
        /// A successfully resolved WORLD point to feed the tool as `.value(point)`.
        case point(Vector)
        /// The input could not be parsed; `message` is a short, user-facing reason
        /// suitable for the command field's error echo (e.g. "Expected x,y").
        case error(String)
    }

    // MARK: - Parse

    /// Parses `text` into a resolved world point.
    ///
    /// - Parameters:
    ///   - text: the raw string the user typed (leading/trailing whitespace ok).
    ///   - reference: the relative-zero — the last committed/picked point that
    ///     `@`, polar, and bare-distance input are measured from. `nil` when no
    ///     point has been placed yet (only absolute `x,y` is then valid).
    ///   - cursor: the live cursor world point, used for the bearing of a bare
    ///     distance. `nil`/coincident-with-reference makes a bare distance an error.
    ///   - angleInDegrees: whether the polar `<angle` is degrees (default) or
    ///     radians. Defaults to degrees (the LibreCAD/AutoCAD convention).
    /// - Returns: `.point` on success, `.error(message)` otherwise.
    public static func parse(
        _ text: String,
        reference: Vector?,
        cursor: Vector? = nil,
        angleInDegrees: Bool = true
    ) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .error("Empty input") }

        // Polar — `dist<angle` (optionally `@dist<angle`). The `<` separator is the
        // unambiguous polar marker, so check it before the comma/bare forms.
        if let ltIndex = trimmed.firstIndex(of: "<") {
            return parsePolar(trimmed, ltIndex: ltIndex, reference: reference,
                              angleInDegrees: angleInDegrees)
        }

        // Relative — `@dx,dy` (the `@` marks "from the reference").
        if trimmed.hasPrefix("@") {
            let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return parsePair(body, reference: reference, relative: true)
        }

        // Absolute pair — `x,y`.
        if trimmed.contains(",") {
            return parsePair(trimmed, reference: nil, relative: false)
        }

        // Bare distance — a single scalar along the current bearing.
        return parseBareDistance(trimmed, reference: reference, cursor: cursor)
    }

    // MARK: - Classifier (coordinate vs command word)

    /// A cheap, allocation-light heuristic the MERGED command line uses to decide
    /// whether the text the user typed is a COORDINATE / DISTANCE token (which it
    /// should feed to `parse(_:reference:cursor:)` and the active tool as
    /// `.value(point)`) versus a COMMAND WORD like `LINE` / `L` / `rect` (which it
    /// should route to the command matcher instead).
    ///
    /// It is intentionally a *quick classifier*, not a full validator: it only
    /// inspects the leading character and the presence of the coordinate
    /// separators. The View / CanvasModel that owns the merged line uses this to
    /// pick a route, then the chosen route does the real parsing/matching.
    ///
    /// Returns `true` iff the trimmed text looks like a coordinate/distance:
    /// - empty (after trimming) → `false`.
    /// - first non-space char is a digit, `+`, `-`, `.`, or `@` → `true`
    ///   (the start of a number, a signed/decimal number, or the relative `@`).
    /// - otherwise, contains `,` or `<` (the absolute / relative / polar
    ///   separators) → `true`.
    /// - otherwise (an alphabetic command word like `LINE` / `L` / `line` /
    ///   `rect`) → `false`.
    ///
    /// Note: a malformed pair such as `"x,y"` returns `true` because it contains a
    /// comma; that is acceptable — this classifier only chooses the ROUTE, and the
    /// coordinate route's `parse` then rejects it as an error. The merged line is
    /// expected to surface that error rather than silently fall back to a command.
    public static func looksLikeCoordinate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        if (first.isASCII && first.isNumber) || first == "+" || first == "-" || first == "." || first == "@" {
            return true
        }
        return trimmed.contains(",") || trimmed.contains("<")
    }

    // MARK: - Pair (absolute / relative)

    /// Parses `"x,y"` into a point. When `relative` the components are added to
    /// `reference`; otherwise they are absolute. Exactly two comma-separated
    /// numbers are required.
    private static func parsePair(_ body: String, reference: Vector?, relative: Bool) -> Result {
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .error(relative ? "Expected @dx,dy" : "Expected x,y")
        }
        guard let x = number(parts[0]), let y = number(parts[1]) else {
            return .error(relative ? "Expected @dx,dy" : "Expected x,y")
        }
        if relative {
            guard let base = reference, base.valid else {
                return .error("No reference point for relative input")
            }
            return .point(Vector(base.x + x, base.y + y))
        }
        return .point(Vector(x, y))
    }

    // MARK: - Polar (dist<angle)

    /// Parses `"dist<angle"` (or `"@dist<angle"`) into a point: a vector of length
    /// `dist` at `angle` from the `reference`. Polar input is inherently relative,
    /// so it always needs a reference; a leading `@` is accepted and ignored.
    private static func parsePolar(
        _ body: String,
        ltIndex: String.Index,
        reference: Vector?,
        angleInDegrees: Bool
    ) -> Result {
        var distPart = body[body.startIndex..<ltIndex].trimmingCharacters(in: .whitespaces)
        let anglePart = body[body.index(after: ltIndex)...].trimmingCharacters(in: .whitespaces)
        if distPart.hasPrefix("@") {
            distPart = String(distPart.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard let dist = number(distPart[...]), let rawAngle = number(anglePart[...]) else {
            return .error("Expected dist<angle")
        }
        guard let base = reference, base.valid else {
            return .error("No reference point for polar input")
        }
        let radians = angleInDegrees ? rawAngle * .pi / 180.0 : rawAngle
        let offset = Vector.polar(radius: dist, angle: radians)
        return .point(Vector(base.x + offset.x, base.y + offset.y))
    }

    // MARK: - Bare distance

    /// Parses a single scalar `"dist"` into a point `dist` along the current
    /// bearing (the `reference → cursor` direction — the rubber-band direction).
    /// Needs a reference AND a cursor that is not coincident with it (no bearing
    /// otherwise). A negative `dist` steps backward along the bearing.
    private static func parseBareDistance(_ body: String, reference: Vector?, cursor: Vector?) -> Result {
        guard let dist = number(body[...]) else {
            return .error("Expected a number, x,y, @dx,dy, or dist<angle")
        }
        guard let base = reference, base.valid else {
            return .error("No reference point for a distance")
        }
        guard let to = cursor, to.valid else {
            return .error("Move the cursor to set a direction for the distance")
        }
        let dir = to - base
        let len = dir.magnitude
        guard len > Tolerance.distance else {
            return .error("No direction — move the cursor away from the last point")
        }
        let unit = dir / len
        return .point(Vector(base.x + unit.x * dist, base.y + unit.y * dist))
    }

    // MARK: - Number scanning

    /// Parses a numeric token (trimmed), accepting a leading sign and a decimal
    /// point. Returns `nil` for anything that is not a single finite number.
    private static func number<S: StringProtocol>(_ token: S) -> Double? {
        let t = token.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        guard let v = Double(t), v.isFinite else { return nil }
        return v
    }
}
