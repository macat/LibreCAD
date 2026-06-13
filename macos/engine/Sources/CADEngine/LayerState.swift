//
//  LayerState.swift
//  CADEngine
//
//  Named layer states — a saved snapshot of every layer's display/edit flags
//  (visibility / lock / print / construction) that the user can restore later.
//  The value-type port of LibreCAD's Layer-State plugin / AutoCAD's LAYERSTATE
//  (`LC_LayerStateList` in the upstream LibreCAD plugin):
//  `librecad/plugins/...` — but rather than a pointer-shared listener model, the
//  whole table is a `Codable` value `struct` that snapshots/restores into the
//  `LayerTable` through the drawing's undoable funnel.
//
//  A `LayerState` captures only the *flags* (not the layer set / pens), so it is a
//  small per-layer bitfield map keyed by layer name. Restoring it re-applies each
//  captured flag to the matching live layer; layers added since the snapshot are
//  left untouched, and captured layers no longer present are skipped. This matches
//  AutoCAD LAYERSTATE "restore states, don't recreate deleted layers".
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// The flag set captured for a single layer in a `LayerState` snapshot — the four
/// per-layer display/edit flags the sidebar surfaces (`isFrozen` is stored as the
/// raw freeze flag, the inverse of "visible", matching `Layer.isFrozen`).
public struct LayerFlags: Sendable, Hashable, Codable {
    /// Frozen (== not visible). Mirrors `Layer.isFrozen`.
    public var isFrozen: Bool
    /// Locked (entities not editable). Mirrors `Layer.isLocked`.
    public var isLocked: Bool
    /// Printable (included on plotted output). Mirrors `Layer.isPrintable`.
    public var isPrintable: Bool
    /// Construction (helper layer; never printed). Mirrors `Layer.isConstruction`.
    public var isConstruction: Bool

    public init(isFrozen: Bool = false,
                isLocked: Bool = false,
                isPrintable: Bool = true,
                isConstruction: Bool = false) {
        self.isFrozen = isFrozen
        self.isLocked = isLocked
        self.isPrintable = isPrintable
        self.isConstruction = isConstruction
    }

    /// Captures the flags of a live layer.
    public init(of layer: Layer) {
        self.isFrozen = layer.isFrozen
        self.isLocked = layer.isLocked
        self.isPrintable = layer.isPrintable
        self.isConstruction = layer.isConstruction
    }
}

/// A named snapshot of every layer's flags at the moment it was captured. Keyed by
/// layer NAME (the stable layer identity) so it survives layer reordering and is
/// applied by name on restore. Pure value type (ADR-001) so it round-trips through
/// the document payload and snapshots cheaply for undo (ADR-002).
public struct LayerState: Sendable, Hashable, Codable, Identifiable {
    /// The state's user-visible name (the table's key).
    public var name: String
    /// Per-layer-name captured flags.
    public var flags: [String: LayerFlags]

    public var id: String { name }

    public init(name: String, flags: [String: LayerFlags]) {
        self.name = name
        self.flags = flags
    }

    /// Captures the current flags of every layer in `table` under `name`.
    public init(name: String, capturing table: LayerTable) {
        self.name = name
        var captured: [String: LayerFlags] = [:]
        for layer in table.layers {
            captured[layer.name] = LayerFlags(of: layer)
        }
        self.flags = captured
    }

    /// Applies this state's captured flags onto `table` — for each captured layer
    /// that still exists, restore its frozen/lock/print/construction flags. Layers
    /// not in the snapshot are left untouched; captured layers no longer present are
    /// skipped (AutoCAD LAYERSTATE behavior — restore, don't recreate).
    public func apply(to table: inout LayerTable) {
        for (name, f) in flags {
            guard table.contains(name) else { continue }
            table.setFrozen(name, f.isFrozen)
            table.setLocked(name, f.isLocked)
            table.setPrintable(name, f.isPrintable)
            table.setConstruction(name, f.isConstruction)
        }
    }
}

/// The drawing's named layer-state registry — the value-type port of the LibreCAD
/// layer-state list. Ordered for stable iteration; lookup/replace is by name.
public struct LayerStateTable: Sendable, Hashable, Codable {
    /// The saved states, in insertion order.
    public private(set) var states: [LayerState]

    public init(states: [LayerState] = []) {
        self.states = states
    }

    public var count: Int { states.count }
    public var isEmpty: Bool { states.isEmpty }

    /// The state named `name`, or `nil`.
    public func state(named name: String) -> LayerState? {
        states.first { $0.name == name }
    }

    /// Whether a state with `name` exists.
    public func contains(_ name: String) -> Bool {
        states.contains { $0.name == name }
    }

    /// Adds, or replaces the existing same-named state (Save Layer State overwrites
    /// a state of the same name, like AutoCAD LAYERSTATE Save).
    public mutating func upsert(_ state: LayerState) {
        if let i = states.firstIndex(where: { $0.name == state.name }) {
            states[i] = state
        } else {
            states.append(state)
        }
    }

    /// Removes the state named `name` (no-op if absent).
    public mutating func remove(named name: String) {
        states.removeAll { $0.name == name }
    }

    /// Renames a state. Rejects an empty new name or a clash with a different
    /// existing state. Returns `true` on success.
    @discardableResult
    public mutating func rename(_ oldName: String, to newName: String) -> Bool {
        guard !newName.isEmpty, oldName != newName else { return oldName == newName }
        guard let i = states.firstIndex(where: { $0.name == oldName }),
              !contains(newName) else { return false }
        states[i].name = newName
        return true
    }

    /// A fresh unused state name from `suggestion` (`State`, `State-1`, …).
    public func newName(suggestion: String = "State") -> String {
        let base = suggestion.isEmpty ? "State" : suggestion
        if !contains(base) { return base }
        var i = 1
        while contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }
}
