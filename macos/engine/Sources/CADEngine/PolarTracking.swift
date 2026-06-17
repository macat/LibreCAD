//
//  PolarTracking.swift
//  CADEngine
//
//  The pure polar-TRACKING kernel — the *visual* sibling of `PolarConstraint`.
//
//  Polar tracking radiates dotted "tracking rays" from a reference point
//  (LibreCAD's relative-zero / the tool's last placed point) at fixed angular
//  increments (e.g. every 15°). As the cursor moves, this kernel reports which
//  ray the cursor has ENGAGED (the nearest increment), the angle-locked point on
//  that ray, the reference→cursor distance (for the on-canvas readout), and — the
//  reason this exists separately from `PolarConstraint` — whether the cursor is
//  currently *near enough* the ray to DRAW the dotted guide + readout.
//
//  ──────────────────────────────────────────────────────────────────────────
//  CRITICAL (design contract for the model wave, W2):
//
//    `withinAperture` is for DRAW-GATING + readout ONLY. This kernel does NOT,
//    and must NOT, change how the cursor is LOCKED. The existing always-on angle
//    lock (`CanvasModel.polarConstrained`, built on `PolarConstraint.constrain`)
//    keeps doing the locking exactly as today. Callers use `withinAperture`
//    solely to decide whether to SHOW the dotted ray / distance readout — not
//    whether to snap. `snappedPoint` here is provided as a *cross-checked copy*
//    of the constraint result (it is computed with the identical rounding /
//    placement formula as `PolarConstraint.constrain`, so the drawn ray always
//    agrees with the existing lock) and is purely informational for rendering;
//    it is NOT a new or competing lock.
//  ──────────────────────────────────────────────────────────────────────────
//
//  Like `PolarConstraint` this is a stateless f64 geometry kernel (ADR-003)
//  taking primitive points, so it is trivially unit-testable from the engine
//  test target with no NSView / GPU / modal. Static member of a namespaced
//  `enum` per CONVENTIONS.md (no module-scope free functions in a fan-out
//  target). `z` is carried through from the cursor, matching the 2D workflow.
//
//  The angle rounding here is INTENTIONALLY identical to
//  `PolarConstraint.constrain(_:relativeTo:incrementRadians:)`
//  (PolarConstraint.swift:60) — it uses `atan2(dy, dx)` (range (-π, π]) and the
//  `(rawAngle / increment).rounded()` nearest-multiple step — so `engagedAngle`
//  and `snappedPoint` match the existing lock bit-for-bit. Do not "improve" the
//  rounding here without changing `PolarConstraint` in lock-step.
//
//  GPLv2-or-later (LibreCAD derivative). Polar tracking semantics port the
//  visual tracking-ray behaviour layered over RS_Snapper's angular restriction.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Snapper angular restriction).
//

import Foundation

/// Namespaced static helper for polar TRACKING — the dotted-ray / readout layer
/// over the polar angle lock. See the file header for the draw-gating-only
/// contract: this never changes how the cursor is locked.
public enum PolarTracking {

    /// The engaged polar ray plus everything a renderer / readout needs.
    public struct Result: Equatable {
        /// The angle-locked point at the SAME distance as the cursor — identical
        /// to `PolarConstraint.constrain(cursor, relativeTo: reference,
        /// incrementRadians:)`. Provided for rendering / cross-check only; it is
        /// NOT a new lock (the model keeps its existing always-on lock).
        public let snappedPoint: Vector
        /// The nearest ray angle, in radians, in the same un-normalized domain as
        /// `PolarConstraint`'s rounding (a multiple of `incrementRadians`, derived
        /// from `atan2`'s (-π, π] range).
        public let engagedAngle: Double
        /// reference → cursor straight-line distance (for the on-canvas readout).
        public let distance: Double
        /// Whether the cursor lies within ±`apertureRadians` of the engaged ray.
        /// DRAW-GATING + readout ONLY — see the file header. Does not gate the lock.
        public let withinAperture: Bool
        /// Far endpoint of the dotted ray: `reference + polar(rayLengthWorld,
        /// engagedAngle)`. Used to draw the guide; the near end is `reference`.
        public let rayFar: Vector

        public init(
            snappedPoint: Vector,
            engagedAngle: Double,
            distance: Double,
            withinAperture: Bool,
            rayFar: Vector
        ) {
            self.snappedPoint = snappedPoint
            self.engagedAngle = engagedAngle
            self.distance = distance
            self.withinAperture = withinAperture
            self.rayFar = rayFar
        }
    }

    /// Resolves the engaged polar tracking ray for `cursor` measured from
    /// `reference`.
    ///
    /// The vector `reference → cursor` is measured; its angle (`atan2`) is rounded
    /// to the nearest multiple of `incrementRadians` (identical to
    /// `PolarConstraint`). The angle-locked point is placed at that snapped angle
    /// at the cursor's distance, the distance is reported for the readout, and the
    /// cursor's nearness to the engaged ray is tested against `apertureRadians` for
    /// draw-gating.
    ///
    /// Returns `nil` on degenerate input, mirroring `PolarConstraint`'s guards:
    ///   • an invalid `reference` or `cursor`,
    ///   • a non-positive or non-finite `incrementRadians`,
    ///   • a `cursor` coincident with `reference` (zero direction — no angle).
    /// A non-finite `apertureRadians` is treated as "never within aperture"
    /// (draw-gating off) rather than a hard failure, and a non-finite
    /// `rayLengthWorld` falls back to a zero-length ray (`rayFar == reference`);
    /// neither aborts the result, since both only affect rendering, not geometry.
    ///
    /// - Parameters:
    ///   - reference: the relative-zero the ray radiates from (the tool's last
    ///     placed point). With no reference the caller should skip tracking.
    ///   - cursor: the raw (already-in-world) cursor point.
    ///   - incrementRadians: the angular step between rays (e.g. `.pi/12` for 15°).
    ///     Must be positive and finite.
    ///   - apertureRadians: half-width of the engagement wedge for draw-gating.
    ///   - rayLengthWorld: length of the drawn dotted ray, in world units.
    /// - Returns: the engaged-ray `Result`, or `nil` when an input is degenerate.
    public static func resolve(
        reference: Vector,
        cursor: Vector,
        incrementRadians: Double,
        apertureRadians: Double,
        rayLengthWorld: Double
    ) -> Result? {
        guard reference.valid, cursor.valid else { return nil }
        guard incrementRadians.isFinite, incrementRadians > 0 else { return nil }

        let dx = cursor.x - reference.x
        let dy = cursor.y - reference.y

        // Coincident cursor: no direction to engage. Mirror PolarConstraint.
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else { return nil }

        // Identical rounding to PolarConstraint.constrain — engagedAngle stays in
        // the same un-normalized domain so snappedPoint matches the lock exactly.
        let rawAngle = atan2(dy, dx)
        let steps = (rawAngle / incrementRadians).rounded()   // nearest multiple
        let engagedAngle = steps * incrementRadians

        // Same placement formula as PolarConstraint (z carried from cursor).
        let snappedPoint = Vector(
            reference.x + distance * cos(engagedAngle),
            reference.y + distance * sin(engagedAngle),
            cursor.z
        )

        // Draw-gating: cursor within ±aperture of the engaged ray. Normalize the
        // signed angular difference into [-π, π] before comparing (so a cursor at
        // e.g. raw -179° vs an engaged +180° ray reads as ~1° apart, not ~359°).
        let withinAperture: Bool
        if apertureRadians.isFinite {
            let delta = normalizedDelta(rawAngle - engagedAngle)
            withinAperture = abs(delta) <= apertureRadians
        } else {
            withinAperture = false
        }

        // Far endpoint of the dotted ray. A non-finite length degrades to a
        // zero-length ray (rayFar == reference) — rendering-only, never aborts.
        let length = rayLengthWorld.isFinite ? rayLengthWorld : 0
        let rayOffset = Vector.polar(radius: length, angle: engagedAngle)
        let rayFar = Vector(
            reference.x + rayOffset.x,
            reference.y + rayOffset.y,
            reference.z
        )

        return Result(
            snappedPoint: snappedPoint,
            engagedAngle: engagedAngle,
            distance: distance,
            withinAperture: withinAperture,
            rayFar: rayFar
        )
    }

    // MARK: - Internal math

    /// Normalizes a signed angle into `[-π, π]`, so the aperture test wraps
    /// correctly across the ±180° boundary. (`remainder(dividingBy: 2π)` already
    /// returns a value in `[-π, π]`; this is a thin, intention-revealing wrapper
    /// kept local to the kernel per the no-free-function convention.)
    static func normalizedDelta(_ a: Double) -> Double {
        a.remainder(dividingBy: 2 * Double.pi)
    }
}
