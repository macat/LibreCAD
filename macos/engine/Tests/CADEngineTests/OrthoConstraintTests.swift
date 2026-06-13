//
//  OrthoConstraintTests.swift
//  CADEngineTests
//
//  Unit tests for the pure ortho (orthogonal) point constraint -- the kernel the
//  app's canvas (CanvasModel.orthoConstrained / CADCanvasView) calls on the
//  point-input path while a draw tool is active. The constraint axis-locks the
//  candidate point to the H or V line through the reference (last) point: it keeps
//  the dominant offset and zeroes the other.
//
//  Asserts: horizontal lock when abs(dx) > abs(dy), vertical lock otherwise, the
//  diagonal tie resolves horizontal, an already-axis-aligned point is unchanged, and
//  invalid inputs pass through (no manufactured coordinate).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("CADEngine ortho-constraint kernel")
struct OrthoConstraintTests {

    private let eps = 1e-12

    @Test("dx greater than dy locks to the horizontal (keep x, snap y to reference)")
    func horizontalLock() {
        let ref = Vector(10, 5)
        let raw = Vector(30, 8)        // dx = 20, dy = 3 -> horizontal
        let out = OrthoConstraint.constrain(raw, relativeTo: ref)
        #expect(abs(out.x - 30) < eps)   // x kept
        #expect(abs(out.y - 5) < eps)    // y snapped to reference row
    }

    @Test("dy greater than dx locks to the vertical (keep y, snap x to reference)")
    func verticalLock() {
        let ref = Vector(10, 5)
        let raw = Vector(13, 40)       // dx = 3, dy = 35 -> vertical
        let out = OrthoConstraint.constrain(raw, relativeTo: ref)
        #expect(abs(out.x - 10) < eps)   // x snapped to reference column
        #expect(abs(out.y - 40) < eps)   // y kept
    }

    @Test("exact diagonal (dx == dy) resolves to horizontal (stable tie-break)")
    func diagonalTieIsHorizontal() {
        let ref = Vector(0, 0)
        let raw = Vector(7, 7)         // dx == dy
        let out = OrthoConstraint.constrain(raw, relativeTo: ref)
        #expect(abs(out.x - 7) < eps)    // x kept (horizontal)
        #expect(abs(out.y - 0) < eps)    // y snapped to reference
    }

    @Test("negative offsets are handled by magnitude (down-left vertical lock)")
    func negativeOffsets() {
        let ref = Vector(0, 0)
        let raw = Vector(-2, -9)       // abs(dy) > abs(dx) -> vertical
        let out = OrthoConstraint.constrain(raw, relativeTo: ref)
        #expect(abs(out.x - 0) < eps)    // x snapped
        #expect(abs(out.y - (-9)) < eps) // y kept
    }

    @Test("an already-horizontal point is returned unchanged")
    func alreadyHorizontal() {
        let ref = Vector(4, 4)
        let raw = Vector(20, 4)        // already on the H line
        let out = OrthoConstraint.constrain(raw, relativeTo: ref)
        #expect(abs(out.x - 20) < eps)
        #expect(abs(out.y - 4) < eps)
    }

    @Test("coincident point (zero offset) collapses onto the reference")
    func coincident() {
        let ref = Vector(3, 3)
        let out = OrthoConstraint.constrain(ref, relativeTo: ref)
        #expect(abs(out.x - 3) < eps)
        #expect(abs(out.y - 3) < eps)
    }

    @Test("invalid inputs pass through unchanged (no manufactured coordinate)")
    func invalidPassThrough() {
        let ref = Vector(1, 1)
        let invalidRaw = OrthoConstraint.constrain(.invalid, relativeTo: ref)
        #expect(!invalidRaw.valid)
        let validRaw = Vector(5, 9)
        let invalidRef = OrthoConstraint.constrain(validRaw, relativeTo: .invalid)
        #expect(invalidRef.x == 5 && invalidRef.y == 9)   // unchanged
    }
}
