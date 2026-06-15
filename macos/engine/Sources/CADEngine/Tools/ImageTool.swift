//
//  ImageTool.swift
//  CADEngine
//
//  The IMAGE (raster image) draw tool — place a reference to an image FILE by
//  clicking a lower-left corner and then a corner that sets the size + rotation.
//  Ported in spirit from LibreCAD's `RS_ActionDrawImage`
//  (librecad/src/actions/draw/rs_actiondrawimage.cpp): with an image file chosen
//  up front, two clicks (insertion point + scale/rotation handle) drop one IMAGE
//  entity referencing that file.
//
//  Behavior (an image file path is chosen up front — see `init`):
//    - no file chosen → status nudges the user to pick an image; every input is a
//                        no-op (nothing to place).
//    - 1st `.click`/`.value` → the LOWER-LEFT (insertion) corner. The tool then
//                        rubber-bands the placed quad as the cursor moves.
//    - `.move` (after the 1st click) → preview the quad at the cursor (the bottom
//                        edge runs insertion → cursor; the height follows the
//                        image's pixel aspect, perpendicular to that edge).
//    - 2nd `.click`/`.value` → the corner that sets WIDTH + ROTATION (the bottom
//                        edge insertion → this point). Commit ONE `.add(.image(...))`
//                        and end the run (`.finished`) — a single placement, like
//                        LibreCAD's image action.
//    - `.cancel` (Esc) → abort.
//    - `.backspace`    → step back the 1st click (re-prompt for the insertion).
//    - `.commit` (Ret) before the 2nd click → no-op (need the size handle).
//
//  ## Size / rotation from two clicks (the placement gesture)
//  Click 1 is the lower-left corner. Click 2 lies along the image's BOTTOM edge, so
//  `bottom = click2 - click1` gives the width (`|bottom|`) AND the rotation
//  (`bottom.angle`). The HEIGHT keeps the source image's pixel aspect: the left
//  edge is `bottom` rotated +90° and scaled by `pixelHeight / pixelWidth`. This
//  drops an undistorted image whose size + angle the user dialed in with two
//  clicks. The resulting `ImageData` stores the per-pixel u/v vectors (the edge
//  vectors ÷ the pixel size), matching the DXF IMAGE model exactly.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It is handed the image FILE PATH + the source pixel size at construction (the
//  future file-picker provides them; the pixel size is read from the file there).
//  It reads only the snapped world points in `ToolInput` and emits
//  `.add(.image(...))`. The app re-mints the id on commit. This tool is
//  intentionally UNWIRED until a later wire-wave adds a `ToolKind` case + a
//  file-picker; it is fully usable + testable as a value type.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawImage).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Image tool. With a target image file path + its source pixel
/// size set, two clicks (lower-left insertion corner + a bottom-edge corner that
/// sets width + rotation) drop one raster image (`.image`) keeping the source
/// pixel aspect. UNWIRED for now (no `ToolKind` case yet — the file-picker UI is a
/// later wave); it is fully usable + testable as a value type.
public struct ImageTool: Tool {

    // MARK: - State

    private enum State: Sendable, Equatable {
        /// Waiting for the lower-left (insertion) corner.
        case awaitingInsertion
        /// Insertion placed; waiting for the bottom-edge corner (size + rotation).
        case awaitingSize(insertion: Vector)
    }

    // MARK: - Configuration (set at construction by the caller / future picker)

    /// The image file to place. `nil`/empty ⇒ "no file chosen yet" — the tool is a
    /// no-op until one is set (the picker provides it).
    private let path: String?

    /// The source image's pixel width (read from the file by the picker). Drives the
    /// per-pixel u vector + the aspect ratio. Defaults to 1 when unknown (the
    /// placement then uses the click distances directly as the edge lengths).
    private let pixelWidth: Double

    /// The source image's pixel height. Drives the per-pixel v vector + aspect.
    private let pixelHeight: Double

    /// Display adjustments to stamp on the placed image (brightness/contrast/fade/
    /// show/clip). Default neutral.
    private let display: ImageDisplay

    private var state: State = .awaitingInsertion

    /// The last cursor seen via `.move`, used to rubber-band the quad after the
    /// insertion corner is placed. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// Creates an Image tool that places references to the file at `path`.
    ///
    /// - Parameters:
    ///   - path: the image file to place (`nil`/empty ⇒ inert until set by a picker).
    ///   - pixelWidth/pixelHeight: the source image's pixel dimensions (the picker
    ///     reads them from the file; default 1×1 ⇒ the click distances become the
    ///     edge lengths directly).
    ///   - display: display adjustments for the placed image (default neutral).
    public init(path: String? = nil,
                pixelWidth: Double = 1,
                pixelHeight: Double = 1,
                display: ImageDisplay = .default) {
        self.path = (path?.isEmpty == true) ? nil : path
        self.pixelWidth = pixelWidth > 0 ? pixelWidth : 1
        self.pixelHeight = pixelHeight > 0 ? pixelHeight : 1
        self.display = display
    }

    // MARK: - Tool

    public var title: String { "Image" }

    public var status: String {
        guard path != nil else { return "Choose an image file to place" }
        switch state {
        case .awaitingInsertion: return "Specify the image's lower-left corner"
        case .awaitingSize:      return "Specify the opposite corner (size + rotation)"
        }
    }

    /// The live rubber-band: the placed image's frame quad (a closed polyline over
    /// the four corners) at the cursor. Empty before a file is chosen or before the
    /// insertion corner is placed / the cursor has moved. (The texture itself is not
    /// previewed — only the frame, like LibreCAD's image rubber-band.)
    public var preview: [ResolvedPolyline] {
        guard path != nil, case .awaitingSize(let insertion) = state, cursor.valid else { return [] }
        let data = makeImageData(insertion: insertion, sizeHandle: cursor)
        let corners = data.corners
        guard corners.count == 4, corners.allSatisfy(\.valid) else { return [] }
        return [ResolvedPolyline(points: corners, closed: true, pen: .toolPreview)]
    }

    /// A DRAW tool: it IGNORES `context` (the file path + pixel size come from the
    /// picker at construction) and emits new geometry as an `.add` edit.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        guard path != nil else { return .none }   // no file chosen → inert.

        switch input {
        case .move(let p):
            cursor = p
            // Only meaningful once the insertion is placed (the size rubber-band).
            if case .awaitingSize = state { return preview.isEmpty ? .none : .preview }
            return .none

        case .click(let p), .value(let p):
            guard p.valid else { return .none }
            switch state {
            case .awaitingInsertion:
                state = .awaitingSize(insertion: p)
                return .none
            case .awaitingSize(let insertion):
                // Degenerate (size handle == insertion): ignore so we don't drop a
                // zero-size image; keep waiting for a real size click.
                guard (p - insertion).magnitude > Tolerance.distance else { return .none }
                let record = EntityRecord(
                    id: .placeholder,
                    kind: .image(makeImageData(insertion: insertion, sizeHandle: p))
                )
                return .commit([.add(record)])
            }

        case .backspace:
            // Step back the insertion corner (re-prompt) if one is placed.
            if case .awaitingSize = state {
                state = .awaitingInsertion
                return .preview
            }
            return .none

        case .cancel:
            return .finished

        case .commit:
            // Return before the size handle is meaningless (need two corners); after
            // the second click the tool already finished on `.commit([.add])`.
            return .none
        }
    }

    // MARK: - Helpers

    /// Builds the `ImageData` for a placement whose lower-left corner is `insertion`
    /// and whose bottom-edge corner (width + rotation handle) is `sizeHandle`. The
    /// bottom edge is `sizeHandle - insertion`; the left edge keeps the source pixel
    /// aspect (the bottom edge rotated +90° and scaled by `pixelHeight/pixelWidth`).
    private func makeImageData(insertion: Vector, sizeHandle: Vector) -> ImageData {
        let bottom = sizeHandle - insertion                 // width vector (+ rotation)
        // Left edge = bottom rotated +90° (CCW), scaled to keep the pixel aspect.
        let aspect = pixelHeight / pixelWidth               // height / width in pixels
        let left = bottom.rotated(by: Double.pi / 2) * aspect
        return ImageData(
            path: path ?? "",
            lowerLeft: insertion,
            widthVector: bottom,
            heightVector: left,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            display: display
        )
    }
}
