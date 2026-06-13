//
//  Layer.swift
//  CADEngine
//
//  The layer table — the document's named layer registry. Mirrors LibreCAD's
//  RS_Layer + RS_LayerList (librecad/src/lib/engine/document/layers/), but layers
//  are value records keyed by name; entities reference them by `LayerID`, never
//  pointer (ADR-001). Where LibreCAD threads layer state through pointer-shared
//  `RS_Layer*` objects + listener fan-out, we expose a value `struct` table with
//  ordered iteration and an active-layer cursor; the SwiftUI sidebar observes the
//  enclosing `CADDrawing` instead of registering RS_LayerListListeners.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Layer / RS_LayerList).
//

import Foundation

/// A single layer's defining record — the value-type port of `RS_LayerData`.
///
/// Field map to `RS_LayerData`:
/// - `name`            → `name`
/// - `color/lineType/lineWidth` → the layer's default `RS_Pen`
/// - `isFrozen`        → `frozen` (the DXF freeze/visibility flag)
/// - `isLocked`        → `locked`
/// - `isPrintable`     → `print`
/// - `isConstruction`  → `construction` (infinite-length helper layer; never printed)
///
/// `isVisible` is the inverse of `isFrozen` (LibreCAD's `toggle()` flips `frozen`);
/// we keep the storage as `isFrozen` and expose `isVisible` as a derived accessor
/// so call sites can read whichever reads more naturally.
public struct Layer: Sendable, Hashable, Codable, Identifiable {
    public var id: LayerID { LayerID(name) }
    public var name: String
    public var color: RGBAColor
    public var lineType: PenLineType
    public var lineWidth: PenLineWidth

    /// `RS_LayerData::frozen` — a frozen layer is invisible / not drawn.
    public var isFrozen: Bool
    /// `RS_LayerData::locked` — entities on a locked layer cannot be edited.
    public var isLocked: Bool
    /// `RS_LayerData::print` — whether the layer is included on plotted output.
    public var isPrintable: Bool
    /// `RS_LayerData::construction` — a construction layer holds infinite-length
    /// helper geometry and is never printed.
    public var isConstruction: Bool

    public init(
        name: String,
        color: RGBAColor = .librecadGreen,
        lineType: PenLineType = .solid,
        lineWidth: PenLineWidth = .default,
        isFrozen: Bool = false,
        isLocked: Bool = false,
        isPrintable: Bool = true,
        isConstruction: Bool = false
    ) {
        self.name = name
        self.color = color
        self.lineType = lineType
        self.lineWidth = lineWidth
        self.isFrozen = isFrozen
        self.isLocked = isLocked
        self.isPrintable = isPrintable
        self.isConstruction = isConstruction
    }

    /// Visibility — the inverse of `isFrozen` (LibreCAD freezes layers to hide
    /// them). Setting `isVisible = false` freezes; `true` thaws.
    public var isVisible: Bool {
        get { !isFrozen }
        set { isFrozen = !newValue }
    }

    /// The pen attributes an entity inherits when its pen is `.byLayer`.
    public var resolvedPen: ResolvedPen {
        ResolvedPen(color: color, lineType: lineType, lineWidth: lineWidth)
    }
}

// MARK: - Decodable (back-compat default for the newer flags)

extension Layer {
    private enum CodingKeys: String, CodingKey {
        case name, color, lineType, lineWidth
        case isFrozen, isLocked, isPrintable, isConstruction
        // Legacy key (older skeleton stored visibility directly).
        case isVisible
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decode(RGBAColor.self, forKey: .color)
        lineType = try c.decode(PenLineType.self, forKey: .lineType)
        lineWidth = try c.decode(PenLineWidth.self, forKey: .lineWidth)
        // Prefer the new `isFrozen`; fall back to legacy `isVisible`; default thawed.
        if let frozen = try c.decodeIfPresent(Bool.self, forKey: .isFrozen) {
            isFrozen = frozen
        } else if let visible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) {
            isFrozen = !visible
        } else {
            isFrozen = false
        }
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isPrintable = try c.decodeIfPresent(Bool.self, forKey: .isPrintable) ?? true
        isConstruction = try c.decodeIfPresent(Bool.self, forKey: .isConstruction) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encode(lineType, forKey: .lineType)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(isFrozen, forKey: .isFrozen)
        try c.encode(isLocked, forKey: .isLocked)
        try c.encode(isPrintable, forKey: .isPrintable)
        try c.encode(isConstruction, forKey: .isConstruction)
    }
}

/// The ordered, name-keyed layer registry with a notion of an active layer.
///
/// Ported from `RS_LayerList`. Differences from the C++ original:
/// - Value `struct`, not a pointer-owning container; copying it is a full snapshot
///   (used by undo / document load).
/// - The active layer is tracked by name (`activeLayerName`), not by raw pointer.
/// - LibreCAD's listener fan-out (`RS_LayerListListener`) is replaced by SwiftUI
///   observation of the owning `CADDrawing`; callers mutate the table and views
///   recompute.
///
/// ## Removal policy (matches `RS_LayerList::remove`)
/// `remove` drops the layer record only; it does NOT touch entities that reference
/// it. In LibreCAD the surrounding command (e.g. `RS_Graphic::removeLayer`)
/// separately deletes or reassigns the layer's entities. Here that policy is the
/// caller's: `CADDrawing.removeLayer(_:reassigningEntitiesTo:)` performs the
/// entity step. Removing the layer record alone leaves any referencing entity
/// pointing at a now-missing `LayerID`; `resolve()` falls back to the default pen
/// for an unknown layer, so this never crashes — but callers SHOULD reassign or
/// delete those entities. The default layer `"0"` is never removed (DXF requires it).
public struct LayerTable: Sendable, Hashable, Codable {
    /// Layers in creation order; first match by name wins (DXF allows only one).
    public private(set) var layers: [Layer]
    /// The currently active layer's name (where new entities land by default).
    public private(set) var activeLayerName: String

    /// A fresh table holding only the default layer "0".
    public init() {
        let zero = Layer(name: "0")
        self.layers = [zero]
        self.activeLayerName = zero.name
    }

    public init(layers: [Layer], activeLayerName: String) {
        let normalized = layers.isEmpty ? [Layer(name: "0")] : layers
        self.layers = normalized
        // Clamp the active name to an existing layer (fall back to the first).
        self.activeLayerName = normalized.contains { $0.name == activeLayerName }
            ? activeLayerName
            : normalized[0].name
    }

    // MARK: - Reads

    /// Number of layers.
    public var count: Int { layers.count }

    /// Looks up a layer by id/name.
    public func layer(_ id: LayerID) -> Layer? {
        layers.first { $0.name == id.name }
    }

    /// Looks up a layer by name.
    public func layer(named name: String) -> Layer? {
        layers.first { $0.name == name }
    }

    /// Whether a layer with this name exists.
    public func contains(_ name: String) -> Bool {
        layers.contains { $0.name == name }
    }

    /// The position of a layer in the ordered list (`RS_LayerList::getIndex`).
    public func index(of name: String) -> Int? {
        layers.firstIndex { $0.name == name }
    }

    /// The active layer (falls back to "0", then the first layer, if missing).
    public var activeLayer: Layer {
        layer(LayerID(activeLayerName)) ?? layer(.zero) ?? layers[0]
    }

    // MARK: - Active layer (RS_LayerList::activate / getActive)

    /// Activates a layer by name. No-op if the name is unknown (matches LibreCAD,
    /// which keeps the prior active layer when asked to activate a missing one).
    public mutating func activate(_ name: String) {
        guard contains(name) else { return }
        activeLayerName = name
    }

    /// Activates a layer by id.
    public mutating func activate(_ id: LayerID) { activate(id.name) }

    // MARK: - Add / edit (RS_LayerList::add / edit)

    /// Adds a new layer, or replaces the existing one with the same name (DXF
    /// layer names are unique). Returns nothing — query via `layer(named:)`.
    public mutating func upsert(_ layer: Layer) {
        if let idx = layers.firstIndex(where: { $0.name == layer.name }) {
            layers[idx] = layer
        } else {
            layers.append(layer)
        }
    }

    /// Adds a layer only if its name is free; returns `true` if added.
    @discardableResult
    public mutating func add(_ layer: Layer) -> Bool {
        guard !contains(layer.name) else { return false }
        layers.append(layer)
        return true
    }

    /// Replaces the layer record at `oldName` with `edited` (whose name may differ
    /// — this is the rename path). Returns `true` on success. If `edited.name`
    /// collides with a *different* existing layer, the edit is rejected.
    @discardableResult
    public mutating func edit(_ oldName: String, to edited: Layer) -> Bool {
        guard let idx = index(of: oldName) else { return false }
        if edited.name != oldName, contains(edited.name) { return false }
        let wasActive = activeLayerName == oldName
        layers[idx] = edited
        if wasActive { activeLayerName = edited.name }
        return true
    }

    /// Renames a layer (a focused `edit`). The default layer "0" cannot be renamed
    /// away (DXF requires "0"); renaming *to* an existing name is rejected.
    /// Returns `true` on success.
    @discardableResult
    public mutating func rename(_ oldName: String, to newName: String) -> Bool {
        guard oldName != "0" else { return false }
        guard oldName != newName else { return true }
        guard let idx = index(of: oldName), !contains(newName) else { return false }
        var l = layers[idx]
        l.name = newName
        layers[idx] = l
        if activeLayerName == oldName { activeLayerName = newName }
        return true
    }

    // MARK: - Remove (RS_LayerList::remove)

    /// Removes a layer record by id. The default layer "0" is never removed.
    /// Entities referencing the layer are NOT touched here (see the type's
    /// removal-policy note); if the active layer is removed, "0" becomes active.
    public mutating func remove(_ id: LayerID) {
        guard id.name != "0" else { return }
        layers.removeAll { $0.name == id.name }
        if activeLayerName == id.name { activeLayerName = "0" }
    }

    /// Removes a layer record by name.
    public mutating func remove(named name: String) { remove(LayerID(name)) }

    // MARK: - Flag mutators (RS_Layer::freeze/lock/setPrint/setConstruction)

    /// Sets a layer's frozen flag (frozen == invisible). No-op if unknown.
    public mutating func setFrozen(_ name: String, _ frozen: Bool) {
        mutate(name) { $0.isFrozen = frozen }
    }

    /// Sets a layer's visibility (the inverse of frozen). No-op if unknown.
    public mutating func setVisible(_ name: String, _ visible: Bool) {
        mutate(name) { $0.isVisible = visible }
    }

    /// Toggles a layer's visibility (`RS_Layer::toggle`).
    public mutating func toggleVisible(_ name: String) {
        mutate(name) { $0.isFrozen.toggle() }
    }

    /// Sets a layer's locked flag. No-op if unknown.
    public mutating func setLocked(_ name: String, _ locked: Bool) {
        mutate(name) { $0.isLocked = locked }
    }

    /// Sets a layer's printable flag (`RS_Layer::setPrint`). No-op if unknown.
    public mutating func setPrintable(_ name: String, _ printable: Bool) {
        mutate(name) { $0.isPrintable = printable }
    }

    /// Sets a layer's construction flag (`RS_Layer::setConstruction`). No-op if unknown.
    public mutating func setConstruction(_ name: String, _ construction: Bool) {
        mutate(name) { $0.isConstruction = construction }
    }

    // MARK: - Pen mutators (RS_Layer::setPen pieces)

    /// Sets a layer's default color. No-op if unknown.
    public mutating func setColor(_ name: String, _ color: RGBAColor) {
        mutate(name) { $0.color = color }
    }

    /// Sets a layer's default line type. No-op if unknown.
    public mutating func setLineType(_ name: String, _ lineType: PenLineType) {
        mutate(name) { $0.lineType = lineType }
    }

    /// Sets a layer's default line width. No-op if unknown.
    public mutating func setLineWidth(_ name: String, _ width: PenLineWidth) {
        mutate(name) { $0.lineWidth = width }
    }

    /// Sets a layer's whole default pen at once.
    public mutating func setPen(_ name: String, color: RGBAColor, lineType: PenLineType, lineWidth: PenLineWidth) {
        mutate(name) {
            $0.color = color
            $0.lineType = lineType
            $0.lineWidth = lineWidth
        }
    }

    // MARK: - Bulk flag ops (RS_LayerList::freezeAll / lockAll)

    /// Freezes or thaws every layer.
    public mutating func freezeAll(_ frozen: Bool) {
        for i in layers.indices { layers[i].isFrozen = frozen }
    }

    /// Locks or unlocks every layer.
    public mutating func lockAll(_ locked: Bool) {
        for i in layers.indices { layers[i].isLocked = locked }
    }

    // MARK: - Private

    /// Applies an in-place edit to the named layer if present.
    private mutating func mutate(_ name: String, _ body: (inout Layer) -> Void) {
        guard let idx = index(of: name) else { return }
        body(&layers[idx])
    }
}
