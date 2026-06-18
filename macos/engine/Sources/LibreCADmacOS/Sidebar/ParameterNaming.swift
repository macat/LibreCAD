//
//  ParameterNaming.swift
//  LibreCADmacOS
//
//  The PURE naming/validation logic for the Parameters Manager (Lane L4), extracted
//  into its own SwiftUI-free / model-free file so it unit-tests WITHOUT presenting the
//  sheet (the View layer is the headless-modal trap) AND without dragging the SwiftUI
//  view into the test target. A test symlinks THIS file (a self-contained source that
//  imports only Foundation + CADEngine) — mirroring every other `_Shared*.swift`
//  sibling, which symlinks a self-contained file and imports CADEngine. The view
//  (`ParametersManagerView`) references `ParameterNaming` directly (same module).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CADEngine

/// Side-effect-free naming + validation helpers for the parameters manager, extracted
/// so they unit-test WITHOUT presenting the sheet (the View layer is the headless-modal
/// trap). Pure value logic shared by the manager and its tests — mirrors `DimStyleNaming`.
///
/// A parameter NAME is an identifier the expression evaluator can reference: it must
/// START with a letter or underscore and contain only letters, digits, and underscores
/// (no spaces, no leading digit, no operators). Names are CASE-INSENSITIVE (the
/// reference key), so a duplicate check folds case. These rules mirror the evaluator's
/// identifier definition (`lowercasedIdentifiers(in:)`: an identifier char is a
/// letter / digit / `_`).
enum ParameterNaming {

    /// Whether `name` is a syntactically valid parameter identifier (after trimming):
    /// non-empty, starts with a letter or `_`, and is all identifier chars (letter /
    /// digit / `_`). Pure — no UI, no model.
    static func isValidIdentifier(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The classification of a typed parameter name when ADDING.
    enum Validation: Equatable {
        /// Blank / whitespace-only → add disabled.
        case empty
        /// Not a valid identifier (leading digit, a space, an operator char) → disabled.
        case invalid
        /// Collides with an existing parameter (case-insensitive) → disabled.
        case duplicate
        /// A fresh, valid, unique name → add allowed.
        case ok

        /// Whether the Add button is enabled for this classification.
        var isAddable: Bool { self == .ok }

        /// A short, user-facing message for the inline (red) error, or `nil` for `.ok`.
        var message: String? {
            switch self {
            case .empty:     return "Enter a name for the parameter."
            case .invalid:   return "Invalid name — start with a letter or underscore; use only letters, digits, and underscores (no spaces)."
            case .duplicate: return "A parameter with this name already exists."
            case .ok:        return nil
            }
        }
    }

    /// Classifies `name` for an ADD against the existing parameter names (case-insensitive,
    /// whitespace-trimmed). Pure value logic the sheet and the tests share.
    static func classify(name: String, existingNames: [String]) -> Validation {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .empty }
        guard isValidIdentifier(t) else { return .invalid }
        let lower = t.lowercased()
        let collides = existingNames.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lower
        }
        return collides ? .duplicate : .ok
    }

    /// A readable label for a constraint kind in the constraint-parameter list (the
    /// human name, not the overlay glyph). Pure — used by the row and unit-testable.
    static func constraintLabel(for kind: Constraint.Kind) -> String {
        switch kind {
        case .dimensional(let d):
            switch d {
            case .distance:           return "Distance"
            case .radius:             return "Radius"
            case .horizontalDistance: return "Horizontal distance"
            case .verticalDistance:   return "Vertical distance"
            case .diameter:           return "Diameter"
            case .angle:              return "Angle"
            }
        case .geometric:
            // Geometric constraints carry no driven value, so they never appear in the
            // parameter list; a defensive label keeps the switch exhaustive.
            return "Geometric"
        }
    }
}
