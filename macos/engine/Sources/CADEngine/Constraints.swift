//
//  Constraints.swift
//  CADEngine
//
//  Parametric-constraint VALUE MODEL (Wave 1 — engine, UNWIRED). Mirrors the
//  geometric / dimensional constraints of a 2D parametric sketcher (the same
//  family AutoCAD's GEOMCONSTRAINT / DIMCONSTRAINT, FreeCAD's Sketcher, and
//  SolveSpace expose), but as PURE value types in the project's ADR-001 style:
//  a `Constraint` references entities by stable `EntityID` (and, where a
//  constraint pins one END of a line/segment, which `EntityPoint` of it) — never
//  an object pointer. The table that stores them + the numeric solver that
//  satisfies them live in `ConstraintTable.swift` / `ConstraintSolver.swift`.
//
//  ## Design (additive, value-type, undoable — the project pattern)
//  Constraints are ADDITIVE document state, NOT a new `EntityKind` case (adding a
//  case is a serialized critical section across ~28 files; the constraint set is
//  a separate list on `CADDrawing`, exactly like `Layout.viewports` lives outside
//  `EntityKind`). Every type here is `Sendable, Hashable, Codable` so the whole
//  table snapshots cheaply for value-snapshot undo (ADR-002) and round-trips
//  through the Codable document payload, with `decodeIfPresent` back-compat so a
//  payload written before a field existed still loads.
//
//  ## MVP vs declared (de-risking the XL solver — see the plan's "MVP scope")
//  The full constraint enums are DECLARED here (cheap, forward-compatible) but the
//  solver IMPLEMENTS only the MVP subset:
//    geometric    {coincident, horizontal, vertical, parallel, perpendicular, fix}
//    dimensional  {distance, radius}
//  The rest ({collinear, tangent, equal, concentric, symmetric} and
//  {horizontalDistance, verticalDistance, diameter, angle}) are declared so the UI
//  / DXF / table code is forward-compatible, but the solver returns `.failed(
//  .unsupported)` for a component that needs one (`Constraint.isSolverSupported`).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

// MARK: - Which point of an entity a constraint references

/// WHICH characteristic point of an entity a constraint binds to. A coincident
/// constraint, for instance, pins ONE end of a line to ONE end of another — so it
/// needs to name the endpoint, not just the entity. For entities with a single
/// canonical point (a `point`, or the *center* of a circle) `.start`/`.center`
/// name it; `.start`/`.end` name a line's two endpoints.
///
/// Carried by value (no entity pointer); the solver maps `(EntityID, EntityPoint)`
/// to a coordinate in its variable vector via `ConstraintSolver`'s point resolver.
public enum EntityPoint: String, Sendable, Hashable, Codable, CaseIterable {
    /// A line's START endpoint, or the sole point of a `.point` entity.
    case start
    /// A line's END endpoint.
    case end
    /// A circle's / arc's CENTER (also a point entity's position, interchangeable
    /// with `.start` there).
    case center
}

/// A reference to ONE characteristic point of ONE entity — `(entityID, point)`.
/// The atom a point-level constraint (coincident, symmetric, …) is built from.
public struct ConstraintPoint: Sendable, Hashable, Codable {
    /// The referenced entity.
    public var entityID: EntityID
    /// Which characteristic point of that entity.
    public var point: EntityPoint

    public init(entityID: EntityID, point: EntityPoint = .start) {
        self.entityID = entityID
        self.point = point
    }
}

// MARK: - Constraint kinds (FULL set declared; MVP subset implemented)

/// The GEOMETRIC constraint kinds — relationships with NO numeric value (the shape
/// is pinned by topology, not a measurement). The full set is declared for
/// forward-compatibility; the solver implements only the MVP subset (see
/// `GeometricConstraintKind.isSolverSupported`).
public enum GeometricConstraintKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Two points are made equal (the points referenced by the constraint's two
    /// `points`). MVP. Also the "merge endpoints" primitive.
    case coincident
    /// A line is made horizontal (its two endpoints share a Y). MVP.
    case horizontal
    /// A line is made vertical (its two endpoints share an X). MVP.
    case vertical
    /// Two lines are made parallel (their direction vectors' cross == 0). MVP.
    case parallel
    /// Two lines are made perpendicular (their direction vectors' dot == 0). MVP.
    case perpendicular
    /// A point/segment is fixed (its DOFs are anchored / removed). MVP.
    case fix

    // --- Declared, NOT yet implemented (vNext) ---
    /// Three+ points / two lines made collinear. TODO: vNext.
    case collinear
    /// A line/circle made tangent to a circle/arc. TODO: vNext.
    case tangent
    /// Two segments/circles made equal length/radius. TODO: vNext.
    case equal
    /// Two circles/arcs made concentric (shared center). TODO: vNext.
    case concentric
    /// Two points made symmetric about a line/point. TODO: vNext.
    case symmetric

    /// Whether the solver implements this kind in the MVP. `false` ⇒ a component
    /// containing it returns `.failed(.unsupported)` from the solver.
    public var isSolverSupported: Bool {
        switch self {
        case .coincident, .horizontal, .vertical, .parallel, .perpendicular, .fix:
            return true
        case .collinear, .tangent, .equal, .concentric, .symmetric:
            return false
        }
    }
}

/// The DIMENSIONAL constraint kinds — relationships DRIVEN by a numeric `value`
/// (a measurement the user dials in). The full set is declared; the solver
/// implements only `distance` + `radius` in the MVP (see `isSolverSupported`).
public enum DimensionalConstraintKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// The straight-line distance between two points equals `value`. MVP.
    case distance
    /// The radius of a circle equals `value`. MVP.
    case radius

    // --- Declared, NOT yet implemented (vNext) ---
    /// The X-distance (Δx) between two points equals `value`. TODO: vNext.
    case horizontalDistance
    /// The Y-distance (Δy) between two points equals `value`. TODO: vNext.
    case verticalDistance
    /// The diameter of a circle equals `value`. TODO: vNext.
    case diameter
    /// The angle (radians) between two lines equals `value`. TODO: vNext.
    case angle

    /// Whether the solver implements this kind in the MVP.
    public var isSolverSupported: Bool {
        switch self {
        case .distance, .radius:
            return true
        case .horizontalDistance, .verticalDistance, .diameter, .angle:
            return false
        }
    }
}

// MARK: - The constraint value type

/// One parametric constraint — a value type referencing entities by id (ADR-001).
///
/// A constraint is EITHER `.geometric` (no value) OR `.dimensional` (a driven
/// `value`); the `kind` enum carries which, and `points` lists the
/// `ConstraintPoint`s it binds in a kind-specific order. The `entityIDs` it
/// touches (for table queries / dangling-drop) is derived from `points` — a
/// constraint never stores a redundant id list.
///
/// ## `points` ordering per kind (the solver relies on this)
///  - coincident:        [pA, pB]                (the two points made equal)
///  - horizontal/vertical: [lineStart, lineEnd]  (the SAME line's two endpoints)
///  - parallel/perpendicular: [l1Start, l1End, l2Start, l2End]  (two lines)
///  - fix:               [p]                      (the anchored point) — for a
///                       whole-segment fix, pass both endpoints [start, end]
///  - distance:          [pA, pB]                 (the measured pair)
///  - radius/diameter:   [c]  where `c.point == .center` of the circle
public struct Constraint: Sendable, Hashable, Codable, Identifiable {

    /// A constraint's discriminator — geometric (valueless) or dimensional (driven).
    public enum Kind: Sendable, Hashable, Codable {
        case geometric(GeometricConstraintKind)
        case dimensional(DimensionalConstraintKind)

        /// Whether the SOLVER implements this kind in the MVP.
        public var isSolverSupported: Bool {
            switch self {
            case .geometric(let g):   return g.isSolverSupported
            case .dimensional(let d): return d.isSolverSupported
            }
        }

        /// Whether this is a dimensional (value-driven) kind.
        public var isDimensional: Bool {
            if case .dimensional = self { return true }
            return false
        }
    }

    /// Stable identity (minted by `ConstraintTable.add`). Lets the table edit /
    /// remove a specific constraint and lets the UI track selection.
    public var id: UUID
    /// Geometric or dimensional kind.
    public var kind: Kind
    /// The characteristic points this constraint binds, in the kind-specific order
    /// documented above.
    public var points: [ConstraintPoint]
    /// The DRIVEN value for a `.dimensional` constraint (distance/radius/… in world
    /// units, or radians for `.angle`). Ignored — and conventionally `0` — for a
    /// `.geometric` constraint.
    public var value: Double
    /// Whether this constraint was AUTO-INFERRED (hidden) rather than explicitly added
    /// by the user. AutoCAD's "inferred coincidence": applying a perpendicular/parallel
    /// constraint to two lines sharing a corner auto-adds a coincident at that endpoint
    /// pair so the corner stays joined while the angle constraint rotates the lines. An
    /// inferred constraint solves EXACTLY like its explicit twin (the solver is unaware
    /// of this flag) — it is purely a DISPLAY hint: the glyph overlay skips inferred
    /// constraints (no badge). Default `false` (an explicit, user-visible constraint).
    public var inferred: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        points: [ConstraintPoint],
        value: Double = 0,
        inferred: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.value = value
        self.inferred = inferred
    }

    // MARK: Derived

    /// The DISTINCT entity ids this constraint references (derived from `points`).
    /// Order-preserving + de-duplicated. Backs the table's `referencing` query and
    /// the dangling-drop (`dropDangling`).
    public var entityIDs: [EntityID] {
        var seen = Set<EntityID>()
        var out: [EntityID] = []
        for p in points where seen.insert(p.entityID).inserted {
            out.append(p.entityID)
        }
        return out
    }

    /// Whether this constraint references `id`.
    public func references(_ id: EntityID) -> Bool {
        points.contains { $0.entityID == id }
    }

    /// Whether the solver implements this constraint's kind in the MVP.
    public var isSolverSupported: Bool { kind.isSolverSupported }

    // MARK: Codable (additive back-compat)

    private enum CodingKeys: String, CodingKey { case id, kind, points, value, inferred }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is additive-tolerant: a payload written without it mints a fresh one
        // (a constraint with no id is still a valid constraint; identity is local).
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        points = try c.decodeIfPresent([ConstraintPoint].self, forKey: .points) ?? []
        // A geometric constraint born without a `value` decodes to 0.
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        // `inferred` is additive-tolerant: a payload written before the flag existed
        // (an old file) decodes to `false` — every prior constraint was user-explicit.
        inferred = try c.decodeIfPresent(Bool.self, forKey: .inferred) ?? false
    }

    // MARK: Convenience constructors (the MVP set the tools/tests build through)

    /// A coincident constraint pinning point `a` to point `b`.
    public static func coincident(_ a: ConstraintPoint, _ b: ConstraintPoint) -> Constraint {
        Constraint(kind: .geometric(.coincident), points: [a, b])
    }

    /// A HIDDEN, auto-inferred coincident constraint pinning point `a` to point `b` —
    /// the AutoCAD "inferred coincidence" companion auto-added at a shared CORNER when
    /// the user applies a perpendicular/parallel constraint to two lines, so the corner
    /// stays joined as the angle constraint rotates them. Identical to `coincident`
    /// (the solver treats it the same) except `inferred == true`, which the glyph
    /// overlay uses to SKIP it (no badge — it is invisible to the user).
    public static func coincidentInferred(_ a: ConstraintPoint, _ b: ConstraintPoint) -> Constraint {
        Constraint(kind: .geometric(.coincident), points: [a, b], inferred: true)
    }

    /// A horizontal constraint on the line `id` (its two endpoints share a Y).
    public static func horizontal(line id: EntityID) -> Constraint {
        Constraint(kind: .geometric(.horizontal),
                   points: [ConstraintPoint(entityID: id, point: .start),
                            ConstraintPoint(entityID: id, point: .end)])
    }

    /// A vertical constraint on the line `id` (its two endpoints share an X).
    public static func vertical(line id: EntityID) -> Constraint {
        Constraint(kind: .geometric(.vertical),
                   points: [ConstraintPoint(entityID: id, point: .start),
                            ConstraintPoint(entityID: id, point: .end)])
    }

    /// A parallel constraint between lines `a` and `b`.
    public static func parallel(line a: EntityID, line b: EntityID) -> Constraint {
        Constraint(kind: .geometric(.parallel), points: lineEndpoints(a) + lineEndpoints(b))
    }

    /// A perpendicular constraint between lines `a` and `b`.
    public static func perpendicular(line a: EntityID, line b: EntityID) -> Constraint {
        Constraint(kind: .geometric(.perpendicular), points: lineEndpoints(a) + lineEndpoints(b))
    }

    /// A fix constraint anchoring `point` (a single point / one endpoint).
    public static func fix(_ point: ConstraintPoint) -> Constraint {
        Constraint(kind: .geometric(.fix), points: [point])
    }

    /// A fix constraint anchoring BOTH endpoints of a line (the whole segment).
    public static func fix(line id: EntityID) -> Constraint {
        Constraint(kind: .geometric(.fix), points: lineEndpoints(id))
    }

    /// A distance constraint driving the gap between points `a` and `b` to `value`.
    public static func distance(_ a: ConstraintPoint, _ b: ConstraintPoint, value: Double) -> Constraint {
        Constraint(kind: .dimensional(.distance), points: [a, b], value: value)
    }

    /// A radius constraint driving circle `id`'s radius to `value`.
    public static func radius(circle id: EntityID, value: Double) -> Constraint {
        Constraint(kind: .dimensional(.radius),
                   points: [ConstraintPoint(entityID: id, point: .center)],
                   value: value)
    }

    /// The `[start, end]` constraint-point pair for a line entity.
    static func lineEndpoints(_ id: EntityID) -> [ConstraintPoint] {
        [ConstraintPoint(entityID: id, point: .start),
         ConstraintPoint(entityID: id, point: .end)]
    }
}
