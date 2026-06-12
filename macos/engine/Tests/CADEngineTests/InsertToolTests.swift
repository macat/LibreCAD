//
//  InsertToolTests.swift
//  CADEngineTests
//
//  Tests for the (UNWIRED) Insert tool: with a chosen block name, a click commits
//  one `.add(.insert(...))` at the snapped point; with no block it is inert; a move
//  drives the rubber-band preview when preview members are supplied.
//
//  Uniquely namespaced (`@Suite("InsertTool")`) so it does not collide with the
//  existing tool-test suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("InsertTool")
struct InsertToolTests {

    @Test("a click commits one .add(.insert) at the clicked point")
    func clickCommitsInsert() {
        var tool = InsertTool(blockName: "WIDGET")
        let outcome = tool.handle(.click(Vector(7, 3)), context: .empty)
        guard case .commit(let edits) = outcome else {
            Issue.record("expected a commit, got \(outcome)"); return
        }
        #expect(edits.count == 1)
        guard case .add(let record) = edits[0],
              case .insert(let d) = record.kind else {
            Issue.record("expected an .add(.insert)"); return
        }
        #expect(d.blockName == "WIDGET")
        #expect(d.insertionPoint == Vector(7, 3))
        #expect(record.id == .placeholder)   // app re-mints
    }

    @Test("a typed coordinate (.value) places an insert exactly like a click")
    func valuePlacesInsert() {
        var tool = InsertTool(blockName: "B")
        guard case .commit(let edits) = tool.handle(.value(Vector(1, 2)), context: .empty),
              case .add(let r) = edits[0], case .insert(let d) = r.kind else {
            Issue.record("expected an .add(.insert) from .value"); return
        }
        #expect(d.insertionPoint == Vector(1, 2))
    }

    @Test("the tool stays active after a click (chains placements)")
    func chainsPlacements() {
        var tool = InsertTool(blockName: "B")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        // A second click still commits (not .finished).
        guard case .commit = tool.handle(.click(Vector(5, 5)), context: .empty) else {
            Issue.record("second click should also commit"); return
        }
    }

    @Test("with no block chosen the tool is inert")
    func inertWithoutBlock() {
        var tool = InsertTool()   // no block name
        #expect(tool.handle(.click(Vector(1, 1)), context: .empty) == .none)
        #expect(tool.status == "Choose a block to insert")
    }

    @Test("scale + rotation flow into the committed insert")
    func appliesScaleAndRotation() {
        var tool = InsertTool(blockName: "B", scale: Vector(2, 3), rotation: .pi / 4)
        guard case .commit(let edits) = tool.handle(.click(Vector(0, 0)), context: .empty),
              case .add(let r) = edits[0], case .insert(let d) = r.kind else {
            Issue.record("expected commit"); return
        }
        #expect(d.scale == Vector(2, 3))
        #expect(abs(d.rotation - .pi / 4) < 1e-9)
    }

    @Test("a move with preview members yields a non-empty rubber-band")
    func previewWithMembers() {
        let members = [EntityRecord(id: EntityID(1),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))]
        var tool = InsertTool(blockName: "L", previewMembers: members)
        let outcome = tool.handle(.move(Vector(50, 50)), context: .empty)
        #expect(outcome == .preview)
        #expect(!tool.preview.isEmpty)
        // The preview line endpoint is shifted to (60,50).
        let pts = tool.preview.flatMap { $0.points }
        #expect(pts.contains { abs($0.x - 60) < 1e-6 && abs($0.y - 50) < 1e-6 })
    }

    @Test("a move with no preview members is a no-op")
    func moveNoMembersNoOp() {
        var tool = InsertTool(blockName: "L")   // no preview members
        #expect(tool.handle(.move(Vector(1, 1)), context: .empty) == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("cancel finishes the run")
    func cancelFinishes() {
        var tool = InsertTool(blockName: "B")
        #expect(tool.handle(.cancel, context: .empty) == .finished)
    }
}
