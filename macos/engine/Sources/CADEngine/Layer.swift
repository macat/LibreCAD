//
//  Layer.swift
//  CADEngine
//
//  The layer table — the document's named layer registry. Mirrors LibreCAD's
//  RS_Layer + RS_LayerList (librecad/src/lib/engine/), but layers are value
//  records keyed by name; entities reference them by `LayerID`, never pointer
//  (ADR-001).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Layer / RS_LayerList).
//

import Foundation

/// A single layer's defining record.
public struct Layer: Sendable, Hashable, Codable, Identifiable {
    public var id: LayerID { LayerID(name) }
    public var name: String
    public var color: RGBAColor
    public var lineType: PenLineType
    public var lineWidth: PenLineWidth
    public var isVisible: Bool
    public var isLocked: Bool

    public init(
        name: String,
        color: RGBAColor = .librecadGreen,
        lineType: PenLineType = .solid,
        lineWidth: PenLineWidth = .default,
        isVisible: Bool = true,
        isLocked: Bool = false
    ) {
        self.name = name
        self.color = color
        self.lineType = lineType
        self.lineWidth = lineWidth
        self.isVisible = isVisible
        self.isLocked = isLocked
    }

    /// The pen attributes an entity inherits when its pen is `.byLayer`.
    public var resolvedPen: ResolvedPen {
        ResolvedPen(color: color, lineType: lineType, lineWidth: lineWidth)
    }
}

/// The ordered, name-keyed layer registry with a notion of an active layer.
public struct LayerTable: Sendable, Hashable, Codable {
    /// Layers in creation order; first match by name wins (DXF allows only one).
    public private(set) var layers: [Layer]
    /// The currently active layer's name (where new entities land by default).
    public var activeLayerName: String

    /// A fresh table holding only the default layer "0".
    public init() {
        let zero = Layer(name: "0")
        self.layers = [zero]
        self.activeLayerName = zero.name
    }

    public init(layers: [Layer], activeLayerName: String) {
        self.layers = layers.isEmpty ? [Layer(name: "0")] : layers
        self.activeLayerName = activeLayerName
    }

    /// Looks up a layer by id/name.
    public func layer(_ id: LayerID) -> Layer? {
        layers.first { $0.name == id.name }
    }

    /// The active layer (falls back to "0" if the active name is missing).
    public var activeLayer: Layer {
        layer(LayerID(activeLayerName)) ?? layers[0]
    }

    /// Adds (or replaces, by name) a layer.
    public mutating func upsert(_ layer: Layer) {
        if let idx = layers.firstIndex(where: { $0.name == layer.name }) {
            layers[idx] = layer
        } else {
            layers.append(layer)
        }
    }

    /// Removes a layer by id. The default layer "0" is never removed.
    public mutating func remove(_ id: LayerID) {
        guard id.name != "0" else { return }
        layers.removeAll { $0.name == id.name }
        if activeLayerName == id.name { activeLayerName = "0" }
    }
}
