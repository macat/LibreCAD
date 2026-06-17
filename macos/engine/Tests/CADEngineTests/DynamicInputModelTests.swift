//
//  DynamicInputModelTests.swift
//  CADEngineTests
//
//  Wave M — the MODEL layer of EDITABLE live dimensions (dynamic input) on
//  `CanvasModel`. Covers the typed-buffer state machine + the synthetic-cursor live
//  preview + the `currentLiveDimensions()` re-stamp, all headlessly:
//
//   • `beginDynInput(firstChar:)` / `dynAppend` build the active field's buffer and
//     turn editing ON; `parsedDynValues()` only surfaces buffers that parse to a Double.
//   • `effectiveCursor()` reflects a TYPED (locked) field while the untyped field still
//     follows the live cursor (the AutoCAD "type the length, the angle tracks the mouse").
//   • `dynCycleField(reverse:)` moves the active field (Line length↔angle; no-op for a
//     one-field tool like Circle), and `clampDynActiveField` keeps it valid.
//   • `dynCommit()` places a point at the typed values via the `.value` seam (asserted on
//     the committed entity geometry + the advanced `relativeZero`), and `resetDynInput`
//     clears state.
//   • `cancelDynInput()` clears state + reverts the preview to cursor tracking WITHOUT
//     cancelling the tool (the in-progress operation survives).
//   • `currentLiveDimensions()` re-stamps `.active` / `.locked` + `typedString` on the
//     editable dims while editing, and leaves them untouched when not.
//   • The reset hooks fire on tool change (`activateTool`) and on commit/finish.
//   • Rectangle's two-field (width / height) Tab flow.
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the existing
//  `_SharedCanvasModel.swift` symlink (mirrors `LiveDimensionWiringTests`). The suite is
//  `@MainActor`; NO SwiftUI body / NSView mount / NSMenu / modal is rendered — only the
//  pure model surface (headless-safe). Snapping is OFF so a `.move(p)` lands the tool
//  cursor at EXACTLY `p`, making the resolved geometry deterministic.
//
//  Uniquely namespaced so it does not collide with the other suites in the shared target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@MainActor
@Suite("editable-dims Wave M — CanvasModel dynamic-input model")
struct DynamicInputModelTests {

    // MARK: - Helpers

    /// A fresh model with snapping OFF (so a `.move(p)` lands the cursor at EXACTLY `p`)
    /// and dynamic input ON (the AppSettings default). The cursor must be threaded
    /// explicitly via `cursorWorld` because `effectiveCursor()` reads it (in the app it
    /// is set by `updateSnap`; headless we set it directly).
    private func model() -> CanvasModel {
        let m = CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        m.snapModes = []
        m.gridVisible = false
        m.dynamicInputEnabled = true
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    /// Drives a Line into the editable `.settingEnd` state: fix the start, set the cursor
    /// (both the model's `cursorWorld` HUD field AND the tool's rubber-band cursor).
    private func lineInProgress(from a: Vector, to b: Vector) -> CanvasModel {
        let m = model()
        m.activateTool(.line)
        _ = m.handleToolInput(.click(a))   // → `.settingEnd(last: a)`
        m.cursorWorld = b
        _ = m.handleToolInput(.move(b))    // tool rubber-band cursor = b
        return m
    }

    /// Drives a Rectangle into the editable `.settingSecond` state.
    private func rectInProgress(first: Vector, cursor c: Vector) -> CanvasModel {
        let m = model()
        m.activateTool(.rectangle)
        _ = m.handleToolInput(.click(first))   // → `.settingSecond(first:)`
        m.cursorWorld = c
        _ = m.handleToolInput(.move(c))
        return m
    }

    /// Drives a Circle into the editable `.settingRadius` state.
    private func circleInProgress(center: Vector, cursor c: Vector) -> CanvasModel {
        let m = model()
        m.activateTool(.circle)
        _ = m.handleToolInput(.click(center))  // → `.settingRadius(center:)`
        m.cursorWorld = c
        _ = m.handleToolInput(.move(c))
        return m
    }

    private func near(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9,
                      sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(a.x - b.x) <= tol, "x: \(a.x) vs \(b.x)", sourceLocation: sourceLocation)
        #expect(abs(a.y - b.y) <= tol, "y: \(a.y) vs \(b.y)", sourceLocation: sourceLocation)
    }

    // MARK: - hasEditableLiveField / editableFields gating

    @Test("hasEditableLiveField: false in select mode and before the first point; true mid-draw")
    func editableGate() {
        let m = model()
        #expect(!m.hasEditableLiveField)                // select mode
        m.activateTool(.line)
        #expect(!m.hasEditableLiveField)                // no point fixed yet
        let mid = lineInProgress(from: .init(0, 0), to: .init(10, 0))
        #expect(mid.hasEditableLiveField)               // mid-draw, editable
        #expect(mid.editableFields() == [.length, .angle])
    }

    @Test("editableFields is empty when dynamic input is OFF (the gate)")
    func editableFieldsRespectsToggle() {
        let m = lineInProgress(from: .init(0, 0), to: .init(10, 0))
        #expect(!m.editableFields().isEmpty)
        m.dynamicInputEnabled = false
        #expect(m.editableFields().isEmpty)
        #expect(!m.hasEditableLiveField)
    }

    // MARK: - begin / append / buffers / parse

    @Test("beginDynInput turns editing on, focuses the first field, seeds the buffer")
    func beginSeedsBuffer() {
        let m = lineInProgress(from: .init(0, 0), to: .init(10, 0))
        m.beginDynInput(firstChar: "1")
        #expect(m.dynEditing)
        #expect(m.dynActiveField == .length)            // Line's first editable field
        #expect(m.dynBuffers[.length] == "1")
        m.dynAppend("2")
        m.dynAppend(".")
        m.dynAppend("5")
        #expect(m.dynBuffers[.length] == "12.5")
        #expect(m.parsedDynValues()[.length] == 12.5)
    }

    @Test("parsedDynValues omits empty / partial (unparseable) buffers")
    func parsedOmitsPartial() {
        let m = lineInProgress(from: .init(0, 0), to: .init(10, 0))
        m.beginDynInput(firstChar: "-")                 // "-" alone does not parse
        #expect(m.dynBuffers[.length] == "-")
        #expect(m.parsedDynValues()[.length] == nil)
        m.dynAppend("3")                                // "-3" now parses
        #expect(m.parsedDynValues()[.length] == -3)
    }

    @Test("dynBackspace drops the last char and stays editing even when empty")
    func backspace() {
        let m = lineInProgress(from: .init(0, 0), to: .init(10, 0))
        m.beginDynInput(firstChar: "4")
        m.dynAppend("2")
        #expect(m.dynBuffers[.length] == "42")
        m.dynBackspace()
        #expect(m.dynBuffers[.length] == "4")
        m.dynBackspace()
        #expect(m.dynBuffers[.length] == "")
        #expect(m.dynEditing)                           // still editing on an empty buffer
        m.dynBackspace()                                // no-op on empty
        #expect(m.dynBuffers[.length] == "")
    }

    // MARK: - effectiveCursor: typed length locks, angle tracks the cursor

    @Test("effectiveCursor: a typed length locks the reach while the angle follows the cursor")
    func effectiveCursorTypedLength() {
        // Anchor at origin, cursor on +X. Type length 20 → reach 20 along the live angle.
        let m = lineInProgress(from: .init(0, 0), to: .init(5, 0))
        m.beginDynInput(firstChar: "2")
        m.dynAppend("0")
        near(m.effectiveCursor(), .init(20, 0))         // length 20, angle 0 (live)

        // Move the mouse up to 45° (same model, still editing): the LENGTH stays 20, the
        // angle now follows the cursor → point on the 45° ray at radius 20.
        m.cursorWorld = .init(3, 3)
        _ = m.handleToolMove(.init(3, 3))
        let r = 20.0 / 2.0.squareRoot()
        near(m.effectiveCursor(), .init(r, r))
    }

    @Test("effectiveCursor falls back to the live cursor when nothing parses")
    func effectiveCursorFallsBack() {
        let m = lineInProgress(from: .init(0, 0), to: .init(6, 8))
        m.beginDynInput(firstChar: "-")                 // un-parseable buffer
        near(m.effectiveCursor(), .init(6, 8))          // → the live cursor reach
    }

    // MARK: - cycle field (Line two-field Tab)

    @Test("dynCycleField advances Line length → angle → length (Tab) and back (Shift-Tab)")
    func cycleLine() {
        let m = lineInProgress(from: .init(0, 0), to: .init(10, 0))
        m.beginDynInput(firstChar: "5")
        #expect(m.dynActiveField == .length)
        m.dynCycleField(reverse: false)
        #expect(m.dynActiveField == .angle)
        m.dynCycleField(reverse: false)
        #expect(m.dynActiveField == .length)            // wraps
        m.dynCycleField(reverse: true)
        #expect(m.dynActiveField == .angle)             // Shift-Tab back
    }

    @Test("dynCycleField is a no-op for a one-field tool (Circle radius)")
    func cycleCircleNoOp() {
        let m = circleInProgress(center: .init(0, 0), cursor: .init(5, 0))
        #expect(m.editableFields() == [.radius])
        m.beginDynInput(firstChar: "7")
        #expect(m.dynActiveField == .radius)
        m.dynCycleField(reverse: false)
        #expect(m.dynActiveField == .radius)            // unchanged (only one field)
    }

    // MARK: - currentLiveDimensions re-stamp

    @Test("currentLiveDimensions re-stamps .active + typedString on the focused field")
    func restampActive() throws {
        let m = lineInProgress(from: .init(0, 0), to: .init(10, 0))
        m.beginDynInput(firstChar: "1")
        m.dynAppend("5")
        let dims = m.currentLiveDimensions()
        let lengthDim = try #require(dims.first { $0.field == .length })
        #expect(lengthDim.editState == .active)
        #expect(lengthDim.typedString == "15")
        // The non-active, un-typed angle field stays idle (overlay draws its live label).
        let angleDim = try #require(dims.first { $0.field == .angle })
        #expect(angleDim.editState == .idle)
        #expect(angleDim.typedString == nil)
    }

    @Test("currentLiveDimensions marks a non-active, parsed field as .locked")
    func restampLocked() throws {
        let m = lineInProgress(from: .init(0, 0), to: .init(10, 0))
        m.beginDynInput(firstChar: "1")
        m.dynAppend("2")                                // length buffer = "12"
        m.dynCycleField(reverse: false)                 // focus → angle, length LOCKS
        let dims = m.currentLiveDimensions()
        let lengthDim = try #require(dims.first { $0.field == .length })
        #expect(lengthDim.editState == .locked)         // parsed + non-active
        #expect(lengthDim.typedString == "12")
        let angleDim = try #require(dims.first { $0.field == .angle })
        #expect(angleDim.editState == .active)          // now focused
    }

    @Test("currentLiveDimensions leaves dims untouched when NOT editing")
    func restampOnlyWhileEditing() throws {
        let m = lineInProgress(from: .init(0, 0), to: .init(10, 0))
        #expect(!m.dynEditing)
        let dims = m.currentLiveDimensions()
        for d in dims where d.isEditable {
            #expect(d.editState == .idle)
            #expect(d.typedString == nil)
        }
    }

    // MARK: - commit places a point at the typed values

    @Test("dynCommit places a Line endpoint at the typed length along the live angle")
    func commitLine() throws {
        let m = lineInProgress(from: .init(0, 0), to: .init(5, 0))   // live angle 0
        m.beginDynInput(firstChar: "2")
        m.dynAppend("0")                                              // length 20
        let before = m.drawing.entities.count
        m.dynCommit()
        // One line was committed: (0,0) → (20,0).
        #expect(m.drawing.entities.count == before + 1)
        let last = try #require(m.drawing.entities.last)
        guard case .line(let ld) = last.kind else {
            Issue.record("expected a committed .line"); return
        }
        near(ld.start, .init(0, 0))
        near(ld.end, .init(20, 0))
        // The relative-zero advanced to the placed point (the chaining anchor).
        near(m.relativeZero ?? .invalid, .init(20, 0))
        // Dyn state is cleared after the commit.
        #expect(!m.dynEditing)
        #expect(m.dynActiveField == nil)
        #expect(m.dynBuffers.isEmpty)
    }

    @Test("dynCommit on a Line with typed length + angle fixes the exact endpoint")
    func commitLineBoth() throws {
        let m = lineInProgress(from: .init(0, 0), to: .init(1, 1))
        m.beginDynInput(firstChar: "1")
        m.dynAppend("0")                                // length 10
        m.dynCycleField(reverse: false)                 // → angle
        // 90° in degrees-decimal is the default angle format the buffer is parsed as a
        // RAW double of RADIANS by the tool (`applyDynamicInput` treats values as radians),
        // so type π/2 directly to land straight up.
        for ch in String(Double.pi / 2) { m.dynAppend(ch) }
        m.dynCommit()
        let last = try #require(m.drawing.entities.last)
        guard case .line(let ld) = last.kind else {
            Issue.record("expected a committed .line"); return
        }
        near(ld.end, .init(0, 10), 1e-6)
    }

    // MARK: - cancel reverts preview, keeps the tool

    @Test("cancelDynInput clears typed state but does NOT cancel the in-progress tool")
    func cancelKeepsTool() {
        let m = lineInProgress(from: .init(0, 0), to: .init(5, 0))
        m.beginDynInput(firstChar: "9")
        m.dynAppend("9")
        #expect(m.dynEditing)
        let entitiesBefore = m.drawing.entities.count
        m.cancelDynInput()
        #expect(!m.dynEditing)
        #expect(m.dynActiveField == nil)
        #expect(m.dynBuffers.isEmpty)
        // The tool is STILL active and STILL mid-draw (no entity committed, dims editable).
        #expect(m.isToolActive)
        #expect(m.drawing.entities.count == entitiesBefore)
        #expect(m.hasEditableLiveField)
        // Preview reverted to the live cursor: effectiveCursor (no buffers) == cursor.
        near(m.effectiveCursor(), .init(5, 0))
    }

    // MARK: - reset hooks (tool change / commit)

    @Test("activateTool resets dyn state (tool change abandons the typed entry)")
    func toolChangeResets() {
        let m = lineInProgress(from: .init(0, 0), to: .init(5, 0))
        m.beginDynInput(firstChar: "3")
        #expect(m.dynEditing)
        m.activateTool(.circle)                         // switch tools mid-type
        #expect(!m.dynEditing)
        #expect(m.dynActiveField == nil)
        #expect(m.dynBuffers.isEmpty)
    }

    @Test("a plain click while mid-type clears dyn state (the .commit reset hook)")
    func clickWhileTypingResets() {
        let m = lineInProgress(from: .init(0, 0), to: .init(5, 0))
        m.beginDynInput(firstChar: "1")
        #expect(m.dynEditing)
        // A real click commits the segment (Line .commit arm) → dyn state must clear.
        _ = m.handleToolInput(.click(.init(5, 0)))
        #expect(!m.dynEditing)
        #expect(m.dynBuffers.isEmpty)
    }

    // MARK: - Rectangle two-field (width / height) Tab flow + commit

    @Test("Rectangle: two editable fields, Tab cycles width ↔ height")
    func rectTwoFields() {
        let m = rectInProgress(first: .init(0, 0), cursor: .init(4, 9))
        #expect(m.editableFields() == [.width, .height])
        m.beginDynInput(firstChar: "1")
        #expect(m.dynActiveField == .width)
        m.dynCycleField(reverse: false)
        #expect(m.dynActiveField == .height)
        m.dynCycleField(reverse: false)
        #expect(m.dynActiveField == .width)             // wraps
    }

    @Test("Rectangle: typed width (height live) resolves the opposite corner toward the cursor")
    func rectEffectiveCursor() {
        let m = rectInProgress(first: .init(0, 0), cursor: .init(4, 9))  // up-right quadrant
        m.beginDynInput(firstChar: "1")
        m.dynAppend("0")                                // width 10, height live (9)
        near(m.effectiveCursor(), .init(10, 9))
    }

    @Test("Rectangle: dynCommit drops a closed polyline of the typed width × height")
    func rectCommit() throws {
        let m = rectInProgress(first: .init(0, 0), cursor: .init(4, 9))
        m.beginDynInput(firstChar: "1")
        m.dynAppend("0")                                // width 10
        m.dynCycleField(reverse: false)                 // → height
        m.dynAppend("2")
        m.dynAppend("0")                                // height 20
        let before = m.drawing.entities.count
        m.dynCommit()
        #expect(m.drawing.entities.count == before + 1)
        let last = try #require(m.drawing.entities.last)
        guard case .polyline(let pd) = last.kind else {
            Issue.record("expected a committed .polyline rectangle"); return
        }
        let xs = pd.vertices.map(\.point.x)
        let ys = pd.vertices.map(\.point.y)
        let w = (xs.max() ?? 0) - (xs.min() ?? 0)
        let h = (ys.max() ?? 0) - (ys.min() ?? 0)
        #expect(abs(w - 10) < 1e-9)
        #expect(abs(h - 20) < 1e-9)
        #expect(pd.closed)
        #expect(!m.dynEditing)                          // reset after commit
    }

    // MARK: - Circle single-field commit

    @Test("Circle: dynCommit places the on-circle point at the typed radius along the cursor")
    func circleCommit() throws {
        let m = circleInProgress(center: .init(0, 0), cursor: .init(3, 4))   // dir (0.6,0.8)
        m.beginDynInput(firstChar: "1")
        m.dynAppend("0")                                // radius 10
        // Synthetic cursor lands on the unit dir × 10 = (6, 8).
        near(m.effectiveCursor(), .init(6, 8))
        let before = m.drawing.entities.count
        m.dynCommit()
        #expect(m.drawing.entities.count == before + 1)
        #expect(!m.dynEditing)
    }

    // MARK: - handleToolMove substitution (the funnel)

    @Test("handleToolMove uses the synthetic cursor while editing, the raw point otherwise")
    func funnelSubstitution() throws {
        let m = lineInProgress(from: .init(0, 0), to: .init(5, 0))
        // Not editing → the tool's cursor follows the raw move (a fresh length readout).
        m.cursorWorld = .init(7, 0)
        _ = m.handleToolMove(.init(7, 0))
        let lenIdle = try #require(m.currentLiveDimensions().first { $0.field == .length })
        guard case .linear(let l0) = lenIdle.kind else { Issue.record("no linear"); return }
        #expect(abs(l0 - 7) < 1e-9)

        // Now editing with a locked length 20: moving the mouse must NOT change the length
        // (the synthetic cursor pins it), only the angle.
        m.beginDynInput(firstChar: "2")
        m.dynAppend("0")
        m.cursorWorld = .init(0, 3)                      // mouse straight up now
        _ = m.handleToolMove(.init(0, 3))
        let lenLocked = try #require(m.currentLiveDimensions().first { $0.field == .length })
        guard case .linear(let l1) = lenLocked.kind else { Issue.record("no linear"); return }
        #expect(abs(l1 - 20) < 1e-6)                     // still 20, the typed value
    }
}
