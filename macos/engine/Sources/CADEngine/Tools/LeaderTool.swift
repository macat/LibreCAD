//
//  LeaderTool.swift
//  CADEngine
//
//  The LEADER (annotation callout) draw tool. Ported in spirit from LibreCAD's
//  `RS_ActionDrawLeader` (librecad/src/lib/actions/...), reduced to the engine's
//  pure-value `Tool` contract: click successive VERTICES to build the leader's
//  polyline path (the arrowhead lands at the FIRST vertex), then `.commit` to
//  finalize — the committed entity is a `.leader` whose path is those vertices and
//  whose optional attached text/mtext annotation anchors at the LAST vertex.
//
//  Interactive TEXT ENTRY is a GUI concern (a field/popover in the wire-wave); the
//  pure tool takes the annotation as an optional preset (`annotationText`) supplied
//  by the app when the user finishes typing. A `nil`/empty preset commits a bare
//  leader (path + arrow only). The annotation is built as a standalone `.text`
//  `EntityKind` so it resolves through the SAME shared text path (no second text
//  path) — LeaderData stores it inline.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit.
//  UNWIRED — registered into `ToolKind` + the toolbar/menu in a later wire-wave.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawLeader construction).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive LEADER tool. Click vertices to build the callout path (arrow at
/// the first click), then `.commit` to finalize a `.leader`. With a non-empty
/// `annotationText` an attached `.text` annotation is anchored at the last vertex
/// (its height = `textHeight`); otherwise a bare leader (path + arrow). The tool
/// resets after a commit so the next leader starts fresh.
public struct LeaderTool: Tool {

    // MARK: - Config (funneled from the options bar / GUI in the wire-wave)

    /// The arrowhead length in world units (the dim style arrow size); `<= 0` lets
    /// the resolve fall back to the document/engine default at draw time.
    public var arrowSize: Double
    /// Whether to draw an arrowhead at the first vertex.
    public var hasArrow: Bool
    /// The optional attached annotation text. Empty/`nil` ⇒ a bare leader. The GUI
    /// fills this from a text field before issuing the finalizing `.commit`.
    public var annotationText: String?
    /// The annotation cap height in world units (used only when `annotationText`
    /// is non-empty).
    public var textHeight: Double

    public init(
        arrowSize: Double = 2.5,
        hasArrow: Bool = true,
        annotationText: String? = nil,
        textHeight: Double = 2.5
    ) {
        self.arrowSize = arrowSize
        self.hasArrow = hasArrow
        self.annotationText = annotationText
        self.textHeight = textHeight
    }

    // MARK: - Private state

    /// The clicked path vertices so far (the arrowhead is at `vertices.first`).
    private var vertices: [Vector] = []
    /// The live cursor (for the rubber-band to the next vertex).
    private var cursor: Vector = .invalid

    // MARK: - Tool

    public var title: String { "Leader" }

    public var status: String {
        if vertices.isEmpty { return "Specify leader start (arrow) point" }
        return "Specify next point — Enter to finish"
    }

    /// The live rubber-band: the committed path so far plus a segment to the cursor.
    public var preview: [ResolvedPolyline] {
        var pts = vertices
        if cursor.valid, (pts.last.map { ($0 - cursor).magnitude > Tolerance.distance } ?? true) {
            pts.append(cursor)
        }
        guard pts.count >= 2 else { return [] }
        return [ResolvedPolyline(points: pts, closed: false, pen: .toolPreview)]
    }

    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview

        case .click(let p), .value(let p):
            return handleClick(p)

        case .backspace:
            return handleBackspace()

        case .cancel:
            reset()
            return .finished

        case .commit:
            // Enter / double-click finalizes the leader from the clicked vertices.
            return finish()
        }
    }

    // MARK: - Click / backspace / finish

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        guard p.valid else { return .none }
        // Ignore a duplicate click on the last vertex (no zero-length segment).
        if let last = vertices.last, (last - p).magnitude <= Tolerance.distance {
            return .none
        }
        vertices.append(p)
        cursor = p
        return vertices.count >= 1 ? .preview : .none
    }

    private mutating func handleBackspace() -> ToolOutcome {
        guard !vertices.isEmpty else { return .none }
        vertices.removeLast()
        return .preview
    }

    /// Finalizes the leader: commits a `.leader` of the clicked vertices (with the
    /// optional annotation at the last) and resets. A path with fewer than 2
    /// vertices is not a usable leader, so it finishes WITHOUT committing.
    private mutating func finish() -> ToolOutcome {
        guard vertices.count >= 2 else {
            reset()
            return .finished
        }
        let data = LeaderData(
            vertices: vertices,
            hasArrow: hasArrow,
            arrowSize: arrowSize,
            annotation: makeAnnotation(at: vertices[vertices.count - 1]),
            styleName: nil
        )
        let record = EntityRecord(id: .placeholder, kind: .leader(data))
        reset()
        return .commit([.add(record)])
    }

    /// Builds the attached `.text` annotation anchored at `anchor` (the last
    /// vertex), or `nil` when there is no annotation text. Reuses the standalone
    /// `.text` kind so it resolves through the shared text path. The run offsets a
    /// little along +X from the anchor so the text does not sit on the leader knee.
    private func makeAnnotation(at anchor: Vector) -> EntityKind? {
        guard let text = annotationText, !text.isEmpty, textHeight > 0 else { return nil }
        let offset = Vector(textHeight * 0.5, 0)
        return .text(TextData(
            position: anchor + offset,
            height: textHeight,
            rotation: 0,
            text: text,
            hAlign: .left,
            vAlign: .middle))
    }

    private mutating func reset() {
        vertices.removeAll(keepingCapacity: true)
        cursor = .invalid
    }
}
