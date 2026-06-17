//
//  CommandTranscriptTests.swift
//  CADEngineTests
//
//  The COMMAND TRANSCRIPT — the AutoCAD-style command-history scrollback that records
//  every line submitted through the merged command line. This suite proves the MODEL
//  contract the scrollback view (`CommandTranscriptView`) renders:
//
//   • `CanvasModel.appendTranscript` — appends in order, caps the ring buffer at
//     `maxTranscriptEntries` (drops the OLDEST), and `clearTranscript` empties it.
//   • `CanvasModel.interpretCommandLine` appends the expected entries at its single
//     choke point: input echo (`> …`) for every non-empty line, a `.tool` line for a
//     recognized command name, a `.error` line for a bad command / coordinate-without-a-
//     tool, and an `.input` (+ optional `.output` readout) for a coordinate fed to a tool.
//   • the pure `CanvasModel.transcriptPoint` formatter trims trailing zeros.
//   • `TranscriptPresentation` / `CommandTranscriptView` pure presentation helpers
//     (row id, color-by-kind) — no SwiftUI body / NSView / modal is rendered.
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the existing
//  `_SharedCanvasModel.swift` symlink; the model suite is `@MainActor`, mirroring
//  `SmartCommandLineDispatchTests`. No modal / NSOpenPanel is reachable (it would hang
//  the headless suite forever).
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
import SwiftUI
@testable import CADEngine

// MARK: - Pure formatter + presentation helpers (no model / GUI)

@Suite("Command transcript — pure helpers")
struct CommandTranscriptHelperTests {

    @Test("transcriptPoint trims trailing zeros on whole / fractional coordinates")
    func transcriptPointTrimsZeros() {
        #expect(CanvasModel.transcriptPoint(Vector(10, 20)) == "10, 20")
        #expect(CanvasModel.transcriptPoint(Vector(1.5, 2.25)) == "1.5, 2.25")
        // 4-dp cap, trailing zeros trimmed.
        #expect(CanvasModel.transcriptPoint(Vector(3.10000, 0)) == "3.1, 0")
    }

    @Test("transcriptPoint normalizes a signed zero to a plain 0")
    func transcriptPointNormalizesSignedZero() {
        #expect(CanvasModel.transcriptPoint(Vector(-0.0, -0.0)) == "0, 0")
    }

    @Test("rowID is the index (stable, monotonic for the scroller)")
    func rowIDIsIndex() {
        #expect(TranscriptPresentation.rowID(0) == 0)
        #expect(TranscriptPresentation.rowID(42) == 42)
    }

    @Test("color maps each transcript kind to its role color")
    func colorByKind() {
        #expect(TranscriptPresentation.color(for: .input) == .primary)
        #expect(TranscriptPresentation.color(for: .output) == .secondary)
        #expect(TranscriptPresentation.color(for: .tool) == DS.Palette.accent)
        #expect(TranscriptPresentation.color(for: .error) == .red)
    }
}

// MARK: - Model: append / cap / clear + interpretCommandLine hooks

@MainActor
@Suite("Command transcript — model buffer + append hooks")
struct CommandTranscriptModelTests {

    private func model() -> CanvasModel {
        let m = CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    // MARK: appendTranscript — order + cap

    @Test("appendTranscript preserves order and starts empty")
    func appendPreservesOrder() {
        let m = model()
        #expect(m.commandTranscript.isEmpty)
        m.appendTranscript(.input, "> a")
        m.appendTranscript(.tool, "Line")
        m.appendTranscript(.error, "boom")
        #expect(m.commandTranscript == [
            .init(kind: .input, text: "> a"),
            .init(kind: .tool, text: "Line"),
            .init(kind: .error, text: "boom"),
        ])
    }

    @Test("appendTranscript caps at 200, dropping the OLDEST and keeping the newest in order")
    func appendCapsAtTwoHundred() {
        let m = model()
        #expect(m.maxTranscriptEntries == 200)
        // Append 250 distinct lines.
        for i in 0..<250 {
            m.appendTranscript(.input, "line \(i)")
        }
        #expect(m.commandTranscript.count == 200)
        // The oldest 50 (0..<50) were dropped; the buffer is 50..<250 in order.
        #expect(m.commandTranscript.first == .init(kind: .input, text: "line 50"))
        #expect(m.commandTranscript.last == .init(kind: .input, text: "line 249"))
    }

    @Test("appendTranscript bumps modelVersion so the scrollback refreshes")
    func appendBumpsModelVersion() {
        let m = model()
        let before = m.modelVersion
        m.appendTranscript(.input, "> x")
        #expect(m.modelVersion != before)
    }

    @Test("clearTranscript empties the buffer")
    func clearEmpties() {
        let m = model()
        m.appendTranscript(.input, "> a")
        m.appendTranscript(.tool, "Line")
        #expect(!m.commandTranscript.isEmpty)
        m.clearTranscript()
        #expect(m.commandTranscript.isEmpty)
    }

    // MARK: interpretCommandLine — append hooks at the choke point

    @Test("a blank line is NOT recorded in the transcript")
    func blankNotRecorded() {
        let m = model()
        _ = m.interpretCommandLine("")
        _ = m.interpretCommandLine("   ")
        #expect(m.commandTranscript.isEmpty)
    }

    @Test("a recognized command name records input echo + a .tool line")
    func commandNameRecordsInputAndTool() {
        let m = model()
        let r = m.interpretCommandLine("L")
        #expect(r == .activateTool(.line))
        #expect(m.commandTranscript == [
            .init(kind: .input, text: "> L"),
            .init(kind: .tool, text: ToolKind.line.title),
        ])
    }

    @Test("an unknown command records input echo + an .error line")
    func unknownCommandRecordsInputAndError() {
        let m = model()
        let r = m.interpretCommandLine("xyzzy")
        if case .error = r {} else { Issue.record("expected .error, got \(r)") }
        #expect(m.commandTranscript.count == 2)
        #expect(m.commandTranscript[0] == .init(kind: .input, text: "> xyzzy"))
        #expect(m.commandTranscript[1].kind == .error)
        #expect(m.commandTranscript[1].text.contains("xyzzy"))
    }

    @Test("a coordinate with a tool active records input echo + an .output readout")
    func coordinateWithToolRecordsInputAndOutput() {
        let m = model()
        m.activateTool(.line)
        let r = m.interpretCommandLine("10,20")
        #expect(r == .handled)
        // The activation's transcript is independent of interpretCommandLine (activateTool
        // is not a command-line submission), so only the coordinate echo + readout land.
        #expect(m.commandTranscript == [
            .init(kind: .input, text: "> 10,20"),
            .init(kind: .output, text: "→ 10, 20"),
        ])
    }

    @Test("a coordinate with NO tool active records input echo + a .error line")
    func coordinateNoToolRecordsInputAndError() {
        let m = model()
        let r = m.interpretCommandLine("10,20")
        if case .error = r {} else { Issue.record("expected .error, got \(r)") }
        #expect(m.commandTranscript.count == 2)
        #expect(m.commandTranscript[0] == .init(kind: .input, text: "> 10,20"))
        #expect(m.commandTranscript[1].kind == .error)
    }

    @Test("a matching tool keyword records the input echo (handled, no error/tool line)")
    func keywordRecordsInputOnly() {
        let m = model()
        m.activateTool(.polyline)
        m.handleToolInput(.click(Vector(0, 0)))
        m.handleToolInput(.click(Vector(10, 0)))
        m.handleToolInput(.click(Vector(10, 10)))
        let before = m.commandTranscript.count

        let r = m.interpretCommandLine("close")
        #expect(r == .handled)
        // Exactly one new line — the input echo (the keyword route is .handled, which
        // emits no extra transcript line beyond the echo).
        #expect(m.commandTranscript.count == before + 1)
        #expect(m.commandTranscript.last == .init(kind: .input, text: "> close"))
    }
}
