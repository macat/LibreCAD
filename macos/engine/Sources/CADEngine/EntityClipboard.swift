//
//  EntityClipboard.swift
//  CADEngine
//
//  A small, pure, value-only in-app clipboard for ENTITIES (UX-plan U5 — the
//  context-menu Cut/Copy/Paste/Duplicate verbs). It holds a snapshot of copied
//  `EntityRecord`s and produces fresh records — id RE-MINTED, geometry OFFSET — for
//  a paste/duplicate, so a paste never collides with a live id and lands at a
//  visible offset from (or a cursor-anchored position relative to) the originals.
//
//  ## Why a pure engine type (not an app singleton)
//  Copy/paste is geometry math, not UI: "snapshot these records", "translate each
//  by Δ and clear its id so `CADDrawing.add` mints a new one". Keeping it in the
//  engine makes the re-mint + offset rules unit-testable WITHOUT the SwiftUI/Metal
//  executable target (which can't be imported by the test bundle). `CanvasModel`
//  owns ONE instance and drives it from the canvas context menu; the records it
//  emits go straight through the existing undoable `applyCommit(.add(...))` path
//  (which already strips the persisted `.selected` flag and mints ids).
//
//  ## System pasteboard?
//  This is deliberately an IN-APP clipboard (a value snapshot held in memory), not
//  the macOS `NSPasteboard`. Cross-app / cross-document DXF-on-the-pasteboard is a
//  later task; the U5 scope is in-app Cut/Copy/Paste/Duplicate of the selection,
//  which this covers with no AppKit dependency (so it stays in the pure engine).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it under
//  the terms of the GNU General Public License version 2 or (at your option) any
//  later version.
//

import Foundation

/// An in-memory, value-type clipboard for copied entities. `Sendable` (a plain
/// array of `Sendable` records) so it crosses actor boundaries freely and can be
/// snapshotted. Empty until something is copied/cut.
public struct EntityClipboard: Sendable, Equatable {

    /// The copied entity records, captured at copy/cut time (a value snapshot — the
    /// originals can be moved or deleted afterward without affecting the clipboard).
    /// Each retains its layer / pen / flags / geometry; only the id + position are
    /// changed at paste time.
    public private(set) var records: [EntityRecord]

    /// The default paste/duplicate offset (world units) applied when the caller does
    /// not anchor the paste to a cursor point. A small positive Δ on both axes so a
    /// pasted/duplicated copy is visibly offset from the original (the AutoCAD/
    /// LibreCAD "+Δ" duplicate convention) rather than landing exactly on top.
    public static let defaultOffset = Vector(10, 10)

    /// An empty clipboard.
    public init(records: [EntityRecord] = []) {
        self.records = records
    }

    /// Whether anything is on the clipboard (drives Paste's enabled state).
    public var isEmpty: Bool { records.isEmpty }

    /// How many records are held.
    public var count: Int { records.count }

    // MARK: - Copy

    /// Replaces the clipboard contents with a value snapshot of `entities` (Copy /
    /// Cut). The records are stored verbatim except the persisted `.selected` flag is
    /// cleared, so a later paste never arrives pre-selected from a stale bit. Copying
    /// an empty sequence clears the clipboard.
    public mutating func copy<S: Sequence>(_ entities: S) where S.Element == EntityRecord {
        records = entities.map { record in
            var r = record
            r.flags.remove(.selected)
            return r
        }
    }

    /// The world-space lower-left of the copied records' combined bounding box, or
    /// `nil` when the clipboard is empty. Used to anchor a cursor-targeted paste so
    /// the geometry's reference corner lands at the cursor (rather than offset by the
    /// box's own position). Uses the analytic bbox (no `ResolveContext` needed for
    /// the corner anchor — the analytic box is exact for the common kinds and a safe
    /// over-estimate for the hull kinds).
    public var anchor: Vector? {
        guard !records.isEmpty else { return nil }
        var box = AABB.empty
        for r in records { box = box.union(r.boundingBox()) }
        return box.isEmpty ? nil : box.min
    }

    // MARK: - Paste / Duplicate

    /// The records to ADD for a paste/duplicate, with ids RE-MINTED (set to the
    /// placeholder `EntityID(0)` so `CADDrawing.add` mints a fresh id) and geometry
    /// translated by `offset`. Returns an empty array for an empty clipboard.
    ///
    /// The id is zeroed rather than copied so two pastes of the same clipboard never
    /// collide (each `add` mints a distinct id); the `.selected` flag stays cleared
    /// (it was cleared at copy time). The caller routes the result through the
    /// undoable `add` path.
    public func pasteRecords(offset: Vector = EntityClipboard.defaultOffset) -> [EntityRecord] {
        guard !records.isEmpty else { return [] }
        let t = Affine2D.translation(offset)
        return records.map { record in
            var r = record
            r.id = EntityID(0)              // re-mint on add
            r.kind = r.kind.transformed(by: t)
            return r
        }
    }

    /// The records to ADD for a paste anchored so the copied geometry's reference
    /// corner (its combined bbox lower-left) lands at `target` (a cursor-targeted
    /// paste). Falls back to the plain `defaultOffset` paste when the clipboard has
    /// no anchor (empty). Ids are re-minted exactly as `pasteRecords`.
    public func pasteRecords(at target: Vector) -> [EntityRecord] {
        guard let anchor else { return pasteRecords() }
        return pasteRecords(offset: target - anchor)
    }
}
