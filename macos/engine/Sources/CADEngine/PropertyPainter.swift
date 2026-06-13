//
//  PropertyPainter.swift
//  CADEngine
//
//  The pure property-painter ("match properties" / eyedropper) transfer logic —
//  the value-only core behind feature-catalog F20. Ported in spirit from
//  LibreCAD's `RS_ActionModifyAttributes` + the "paint format" affordance
//  (librecad/src/actions/modify/...): pick the pen + layer from one source entity,
//  then stamp those attributes onto other target entities; or reset a target's pen
//  back to `.byLayer` (so it inherits its layer's pen again).
//
//  This is GUI-free + drawing-free: it operates purely on `EntityRecord` value
//  copies and returns NEW records the caller commits through the undoable
//  `.replace` path (the app's `applyInspectorEdits`). Geometry (`kind`) and id are
//  always preserved — only the common attributes (`pen` + `layer`) change. Pure
//  (ADR-001), so it is fully unit-testable without a `CADDrawing` / renderer.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyAttributes).
//

import Foundation

/// The set of attributes the property-painter copies from a source entity. A small
/// value snapshot so the canvas-tool "loaded brush" can hold it between picks.
public struct PaintAttributes: Sendable, Hashable, Codable {
    /// The source entity's pen (color / line type / line width — including the
    /// `.byLayer` / `.byBlock` sentinels, copied verbatim).
    public var pen: Pen
    /// The source entity's layer.
    public var layer: LayerID

    public init(pen: Pen, layer: LayerID) {
        self.pen = pen
        self.layer = layer
    }

    /// Captures the paintable attributes of `record`.
    public init(from record: EntityRecord) {
        self.pen = record.pen
        self.layer = record.layer
    }
}

/// Pure property-painter operations. All methods return NEW `EntityRecord` value
/// copies (id + geometry preserved) for the caller to commit undoably.
public enum PropertyPainter {

    /// What an `apply` transfers — independently togglable so the UI can paint pen
    /// only, layer only, or both (AutoCAD MATCHPROP "settings"). Defaults to both.
    public struct Options: Sendable, Hashable, Codable {
        public var copyPen: Bool
        public var copyLayer: Bool

        public init(copyPen: Bool = true, copyLayer: Bool = true) {
            self.copyPen = copyPen
            self.copyLayer = copyLayer
        }

        /// Copy everything (the default brush).
        public static let all = Options(copyPen: true, copyLayer: true)
    }

    /// Returns `target` with `source`'s attributes stamped on per `options`. The
    /// geometry (`kind`), id, and flags are preserved; only pen and/or layer change.
    /// A target whose pen+layer already match is returned UNCHANGED (so the caller
    /// can drop a no-op replace and not pollute undo).
    public static func apply(_ source: PaintAttributes,
                             to target: EntityRecord,
                             options: Options = .all) -> EntityRecord {
        var out = target
        if options.copyPen { out.pen = source.pen }
        if options.copyLayer { out.layer = source.layer }
        return out
    }

    /// Applies `source`'s attributes to every record in `targets`, returning only
    /// the records that actually CHANGED (so the caller commits a minimal undo
    /// group). The source record itself is excluded if it appears in `targets`
    /// (painting onto yourself is a no-op).
    public static func apply(_ source: PaintAttributes,
                             to targets: [EntityRecord],
                             options: Options = .all) -> [EntityRecord] {
        targets.compactMap { target in
            let painted = apply(source, to: target, options: options)
            return painted == target ? nil : painted
        }
    }

    /// Returns `target` with its pen reset to `.byLayer` (so it inherits its
    /// layer's pen again — AutoCAD "ByLayer" / LibreCAD reset-to-layer). The layer
    /// is kept; only the pen changes. Returns `nil` (unchanged) if the pen is
    /// already fully `.byLayer`, so the caller drops a no-op.
    public static func resetPenToLayer(_ target: EntityRecord) -> EntityRecord? {
        guard target.pen != .byLayer else { return nil }
        var out = target
        out.pen = .byLayer
        return out
    }

    /// Resets the pen of every record in `targets` to `.byLayer`, returning only the
    /// records that actually changed.
    public static func resetPenToLayer(_ targets: [EntityRecord]) -> [EntityRecord] {
        targets.compactMap { resetPenToLayer($0) }
    }
}
