//
//  CADDrawing.swift
//  CADEngine
//
//  The document model (ADR-001 / ADR-002): an ordered store of value-type
//  entities keyed by stable `EntityID`, plus the layer table, the block table,
//  graphic variables, drawing units, and the id-minting counter. Mirrors
//  LibreCAD's RS_Graphic / RS_EntityContainer, but holds value records by id (NO
//  object pointers, NO child graph) and registers undo as value snapshots of the
//  touched state (ADR-002) — not LibreCAD's flag-based RS_Undo scheme.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Graphic / RS_Undo / RS_Units).
//

import Foundation
import Observation

// MARK: - Drawing units (RS2::Unit + RS_Units conversion)

/// The drawing's measurement unit — the value-type port of `RS2::Unit`
/// (librecad/src/lib/engine/rs.h). Raw values match the DXF `$INSUNITS` integer
/// codes so `init(dxf:)` / `dxfCode` round-trip a parsed header.
public enum DrawingUnit: Int, Sendable, Hashable, Codable, CaseIterable {
    case none = 0
    case inch = 1
    case foot = 2
    case mile = 3
    case millimeter = 4
    case centimeter = 5
    case meter = 6
    case kilometer = 7
    case microinch = 8
    case mil = 9
    case yard = 10
    case angstrom = 11
    case nanometer = 12
    case micron = 13
    case decimeter = 14
    case decameter = 15
    case hectometer = 16
    case gigameter = 17
    case astro = 18
    case lightyear = 19
    case parsec = 20

    /// The DXF `$INSUNITS` integer code for this unit.
    public var dxfCode: Int { rawValue }

    /// Builds a unit from a DXF `$INSUNITS` code, falling back to `.none` for an
    /// unknown code (`RS_Units::dxfint2unit` clamps the same way).
    public init(dxf code: Int) {
        self = DrawingUnit(rawValue: code) ?? .none
    }

    /// Multiplicative factor to convert a value in this unit into **millimeters**
    /// (`RS_Units::getFactorToMM`). `.none` is treated as millimeters (factor 1).
    public var factorToMM: Double {
        switch self {
        case .none, .millimeter: return 1.0
        case .inch:        return 25.4
        case .foot:        return 304.8
        case .mile:        return 1.609344e6   // international mile
        case .centimeter:  return 10
        case .meter:       return 1e3
        case .kilometer:   return 1e6
        case .microinch:   return 2.54e-5
        case .mil:         return 0.0254
        case .yard:        return 914.4
        case .angstrom:    return 1e-7
        case .nanometer:   return 1e-6
        case .micron:      return 1e-3
        case .decimeter:   return 100.0
        case .decameter:   return 1e4
        case .hectometer:  return 1e5
        case .gigameter:   return 1e9
        case .astro:       return 1.495978707e14
        case .lightyear:   return 9.4607304725808e18
        case .parsec:      return 3.0856776e19
        }
    }

    /// Whether this unit is metric (`RS_Units::isMetric`).
    public var isMetric: Bool {
        switch self {
        case .millimeter, .centimeter, .meter, .kilometer, .angstrom, .nanometer,
             .micron, .decimeter, .decameter, .hectometer, .gigameter, .astro,
             .lightyear, .parsec:
            return true
        default:
            return false
        }
    }

    /// The short display sign for this unit (`RS_Units::unitToSign`).
    public var sign: String {
        switch self {
        case .none:        return ""
        case .inch:        return "\""
        case .foot:        return "'"
        case .mile:        return "mi"
        case .millimeter:  return "mm"
        case .centimeter:  return "cm"
        case .meter:       return "m"
        case .kilometer:   return "km"
        case .microinch:   return "µ\""
        case .mil:         return "mil"
        case .yard:        return "yd"
        case .angstrom:    return "A"
        case .nanometer:   return "nm"
        case .micron:      return "µm"
        case .decimeter:   return "dm"
        case .decameter:   return "dam"
        case .hectometer:  return "hm"
        case .gigameter:   return "Gm"
        case .astro:       return "astro"
        case .lightyear:   return "ly"
        case .parsec:      return "pc"
        }
    }

    /// Converts `value` from `src` to `dst` units via millimeters
    /// (`RS_Units::convert(val, src, dest)`).
    public static func convert(_ value: Double, from src: DrawingUnit, to dst: DrawingUnit) -> Double {
        let dstFactor = dst.factorToMM
        guard dstFactor > 0 else { return value }
        return value * src.factorToMM / dstFactor
    }

    /// Convenience: convert `value` in `self` into millimeters.
    public func toMM(_ value: Double) -> Double { value * factorToMM }

    /// Convenience: convert `value` (millimeters) into `self`.
    public func fromMM(_ valueMM: Double) -> Double {
        factorToMM > 0 ? valueMM / factorToMM : valueMM
    }
}

// MARK: - Linear / angle format (RS2::LinearFormat / AngleFormat)

/// How linear measurements are displayed (`RS2::LinearFormat`).
public enum LinearFormat: Int, Sendable, Hashable, Codable, CaseIterable {
    case scientific = 0
    case decimal = 1
    case engineering = 2
    case architectural = 3
    case fractional = 4
    case architecturalMetric = 5
}

/// How angles are displayed (`RS2::AngleFormat`).
public enum AngleFormat: Int, Sendable, Hashable, Codable, CaseIterable {
    case degreesDecimal = 0
    case degreesMinutesSeconds = 1
    case gradians = 2
    case radians = 3
    case surveyors = 4
}

// MARK: - Graphic variables (RS_Variable / RS_VariableDict / LC_GraphicVariables)

/// A typed graphic-variable value — the value-type port of `RS_Variable`'s
/// tagged contents (string / int / double / vector). Carries the DXF group code
/// so a parsed header variable round-trips (`RS_Variable::getCode`).
public enum GraphicVariable: Sendable, Hashable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case vector(Vector)

    /// The value as a string, if it is one.
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    /// The value as an int, if it is one.
    public var intValue: Int? { if case .int(let i) = self { return i } else { return nil } }
    /// The value as a double, if it is one.
    public var doubleValue: Double? { if case .double(let d) = self { return d } else { return nil } }
    /// The value as a vector, if it is one.
    public var vectorValue: Vector? { if case .vector(let v) = self { return v } else { return nil } }
}

/// The drawing's variable bag — the value-type port of `RS_VariableDict` plus the
/// typed accessors `LC_GraphicVariables` exposes over the essential DXF header
/// variables (`$INSUNITS`, `$LUNITS`, `$LUPREC`, `$AUNITS`, `$AUPREC`,
/// `$ANGBASE`, `$ANGDIR`, `$GRIDMODE`, ...).
///
/// Variables are stored by DXF name (the `$`-prefixed key). The typed accessors
/// read/write those well-known keys; `set`/`get` cover everything else.
public struct GraphicVariables: Sendable, Hashable, Codable {
    /// Raw variable storage keyed by DXF variable name.
    public private(set) var values: [String: GraphicVariable]

    public init(values: [String: GraphicVariable] = [:]) {
        self.values = values
    }

    // MARK: Raw access (RS_VariableDict::add / get* / remove / has)

    public var count: Int { values.count }
    public func has(_ key: String) -> Bool { values[key] != nil }
    public func get(_ key: String) -> GraphicVariable? { values[key] }

    public mutating func set(_ key: String, _ value: GraphicVariable) { values[key] = value }
    public mutating func setString(_ key: String, _ v: String) { values[key] = .string(v) }
    public mutating func setInt(_ key: String, _ v: Int) { values[key] = .int(v) }
    public mutating func setDouble(_ key: String, _ v: Double) { values[key] = .double(v) }
    public mutating func setVector(_ key: String, _ v: Vector) { values[key] = .vector(v) }
    public mutating func remove(_ key: String) { values.removeValue(forKey: key) }

    public func string(_ key: String, default def: String = "") -> String { values[key]?.stringValue ?? def }
    public func int(_ key: String, default def: Int = 0) -> Int { values[key]?.intValue ?? def }
    public func double(_ key: String, default def: Double = 0) -> Double { values[key]?.doubleValue ?? def }
    public func vector(_ key: String, default def: Vector = .invalid) -> Vector { values[key]?.vectorValue ?? def }
    public func bool(_ key: String, default def: Bool = false) -> Bool {
        if let i = values[key]?.intValue { return i != 0 }
        return def
    }

    // MARK: Typed header accessors (LC_GraphicVariables)

    /// `$INSUNITS` — the drawing unit. Defaults to millimeter (LibreCAD default).
    public var unit: DrawingUnit {
        get { DrawingUnit(dxf: int("$INSUNITS", default: DrawingUnit.millimeter.dxfCode)) }
        set { setInt("$INSUNITS", newValue.dxfCode) }
    }

    /// `$LUNITS` — linear display format. DXF `$LUNITS` codes: 1=Scientific,
    /// 2=Decimal, 3=Engineering, 4=Architectural, 5=Fractional. Defaults Decimal.
    public var linearFormat: LinearFormat {
        get { Self.linearFormat(fromDXF: int("$LUNITS", default: 2)) }
        set { setInt("$LUNITS", Self.dxfLUNITS(for: newValue)) }
    }

    /// `$LUPREC` — linear precision (decimal places). Defaults 4.
    public var linearPrecision: Int {
        get { int("$LUPREC", default: 4) }
        set { setInt("$LUPREC", newValue) }
    }

    /// `$AUNITS` — angle display format. DXF codes: 0=Decimal degrees,
    /// 1=Deg/Min/Sec, 2=Gradians, 3=Radians, 4=Surveyor's. Defaults decimal.
    public var angleFormat: AngleFormat {
        get { Self.angleFormat(fromDXF: int("$AUNITS", default: 0)) }
        set { setInt("$AUNITS", newValue.rawValue) }
    }

    /// `$AUPREC` — angle precision (decimal places). Defaults 4.
    public var anglePrecision: Int {
        get { int("$AUPREC", default: 4) }
        set { setInt("$AUPREC", newValue) }
    }

    /// `$ANGBASE` — base angle (radians) measurements are taken from. Defaults 0.
    public var anglesBase: Double {
        get { double("$ANGBASE", default: 0) }
        set { setDouble("$ANGBASE", newValue) }
    }

    /// `$ANGDIR` — angle direction. DXF: 0 == counter-clockwise, 1 == clockwise.
    /// LibreCAD's `areAnglesCounterClockWise()`.
    public var anglesCounterClockwise: Bool {
        get { int("$ANGDIR", default: 0) == 0 }
        set { setInt("$ANGDIR", newValue ? 0 : 1) }
    }

    /// `$GRIDMODE` — whether the grid is shown (`isGridOn`). Defaults on.
    public var gridOn: Bool {
        get { bool("$GRIDMODE", default: true) }
        set { setInt("$GRIDMODE", newValue ? 1 : 0) }
    }

    /// `$PINSBASE` — paper-space insertion base point. Defaults (0,0).
    public var paperInsertionBase: Vector {
        get { vector("$PINSBASE", default: Vector(0, 0)) }
        set { setVector("$PINSBASE", newValue) }
    }

    // MARK: DXF code ↔ enum (LC_GraphicVariables::convertLinearFormatDXF2LC etc.)

    /// Maps a DXF `$LUNITS` code to a `LinearFormat`
    /// (`LC_GraphicVariables::convertLinearFormatDXF2LC`).
    public static func linearFormat(fromDXF f: Int) -> LinearFormat {
        switch f {
        case 1: return .scientific
        case 3: return .engineering
        case 4: return .architectural
        case 5: return .fractional
        default: return .decimal      // 2 (and unknown) → Decimal
        }
    }

    /// The DXF `$LUNITS` code for a `LinearFormat`.
    public static func dxfLUNITS(for f: LinearFormat) -> Int {
        switch f {
        case .scientific:          return 1
        case .decimal:             return 2
        case .engineering:         return 3
        case .architectural:       return 4
        case .fractional:          return 5
        case .architecturalMetric: return 4   // no distinct DXF code; map to architectural
        }
    }

    /// Maps a DXF `$AUNITS` code to an `AngleFormat`
    /// (`LC_GraphicVariables::angleUnitsDXF2LC`).
    public static func angleFormat(fromDXF a: Int) -> AngleFormat {
        AngleFormat(rawValue: a) ?? .degreesDecimal
    }
}

// MARK: - The drawing

/// The drawing — entities, layers, blocks, graphic variables, units, and the
/// metadata the engine/render/tools all read. `@MainActor` so it integrates
/// cleanly with SwiftUI's `@Observable` document machinery and `UndoManager`
/// (which runs on the main thread for document apps); `@Observable` so views
/// update on mutation.
///
/// ## Threading
/// All mutation/read of `CADDrawing` happens on the main actor. Heavy, off-thread
/// work (DXF parsing, geometry kernels) runs through the single shared
/// `CADEngine` actor (see `CADEngine.swift`) and returns value types that are then
/// applied here on the main actor.
@MainActor
@Observable
public final class CADDrawing {

    // MARK: - Stored state

    /// Entities in stable insertion/draw order.
    public private(set) var entities: [EntityRecord] = []

    /// Fast id → index lookup, kept in sync with `entities`.
    private var indexByID: [EntityID: Int] = [:]

    /// The layer registry (`RS_LayerList`).
    public private(set) var layers = LayerTable()

    /// The block-definition registry (`RS_BlockList`). Block contents are id-refs
    /// into `entities` (ADR-001); this table holds the definitions, not objects.
    public private(set) var blocks = BlockTable()

    /// The text-style registry (the DXF STYLE table). TEXT/MTEXT reference a style
    /// by name (DXF code 7); resolve()-time indirection re-flows every entity that
    /// uses a style when it is edited (text-system-design §1.1). Always contains
    /// "Standard" (native default font). The DXF reader/writer STYLE round-trip is
    /// a Phase-3 bridge pass; until then this defaults to a native "Standard".
    public var textStyles = TextStyleTable()

    /// The drawing's graphic variables (`RS_VariableDict` + `LC_GraphicVariables`).
    /// Use the typed accessors (`graphicVariables.unit`, `.linearFormat`, ...) or
    /// `convenience` `drawingUnit` below.
    public var graphicVariables = GraphicVariables()

    /// The `UndoManager` mutations register with. Injected by the document layer
    /// (SwiftUI hands one in from `DocumentGroup`); nil == undo disabled.
    public weak var undoManager: UndoManager?

    /// Monotonic id source. Never reused within this drawing's lifetime.
    private var nextRawID: UInt64 = 1

    public init() {}

    // MARK: - ID minting

    /// Mints a fresh, never-before-used `EntityID`.
    public func mintID() -> EntityID {
        defer { nextRawID += 1 }
        return EntityID(nextRawID)
    }

    // MARK: - Reads

    public var count: Int { entities.count }
    public var isEmpty: Bool { entities.isEmpty }

    public func entity(_ id: EntityID) -> EntityRecord? {
        guard let i = indexByID[id] else { return nil }
        return entities[i]
    }

    public func contains(_ id: EntityID) -> Bool { indexByID[id] != nil }

    // MARK: - Units convenience

    /// The drawing unit (`$INSUNITS` via `graphicVariables.unit`). Shorthand for
    /// the most-read header variable.
    public var drawingUnit: DrawingUnit {
        get { graphicVariables.unit }
        set { graphicVariables.unit = newValue }
    }

    // MARK: - Mutations (each registers a value-snapshot undo per ADR-002)

    /// Appends an entity. Undo removes it; redo re-adds it.
    ///
    /// If the entity's id is the placeholder `EntityID(0)` it is minted a fresh
    /// id here; otherwise its id is honored (used by document load).
    ///
    /// - Important: Callers MUST use `mintID()` for new entities (or leave the id
    ///   as the placeholder `EntityID(0)` to have one minted here). Only
    ///   `load(...)` supplies external ids (from a parsed file). Supplying a
    ///   hand-picked, non-minted id risks colliding with a minted or loaded id;
    ///   the `precondition` below aborts on a duplicate id as a programmer-error
    ///   guard — it is NOT a recoverable runtime path.
    @discardableResult
    public func add(_ entity: EntityRecord) -> EntityID {
        var e = entity
        if e.id.rawValue == 0 { e.id = mintID() }
        precondition(indexByID[e.id] == nil, "duplicate EntityID \(e.id) on add")

        indexByID[e.id] = entities.count
        entities.append(e)

        let id = e.id
        registerUndo { drawing in
            // Undo of add == remove (which itself registers the redo).
            drawing.remove(id)
        }
        return id
    }

    /// Removes an entity by id (no-op if absent). Undo restores it at its
    /// original draw order; redo removes it again.
    public func remove(_ id: EntityID) {
        guard let idx = indexByID[id] else { return }
        let removed = entities[idx]

        entities.remove(at: idx)
        indexByID.removeValue(forKey: id)
        // Reindex the tail that shifted down.
        for i in idx..<entities.count { indexByID[entities[i].id] = i }

        registerUndo { drawing in
            // Undo of remove == reinsert at the original position.
            drawing.reinsert(removed, at: idx)
        }
    }

    /// Replaces an existing entity's full record (same id). Undo restores the
    /// prior value; redo restores the new value. This is the path single-entity
    /// edits go through — the snapshot is one value copy (ADR-002).
    public func replace(_ entity: EntityRecord) {
        guard let idx = indexByID[entity.id] else {
            // Replacing something that isn't there falls back to add.
            _ = add(entity)
            return
        }
        let prior = entities[idx]
        entities[idx] = entity

        registerUndo { drawing in
            drawing.replace(prior)
        }
    }

    // MARK: - Internal reinsert (undo of remove, preserves draw order)

    private func reinsert(_ entity: EntityRecord, at index: Int) {
        let clamped = Swift.min(index, entities.count)
        entities.insert(entity, at: clamped)
        for i in clamped..<entities.count { indexByID[entities[i].id] = i }

        let id = entity.id
        registerUndo { drawing in
            drawing.remove(id)
        }
    }

    // MARK: - Layer mutations (value-snapshot undo of the whole LayerTable)

    /// Whole-table layer mutation with undo. Because `LayerTable` is a value type,
    /// the undo snapshot is one struct copy (ADR-002) — cheap, and the redo comes
    /// for free via the standard `UndoManager` re-registration pattern.
    ///
    /// All the `*Layer*` helpers below funnel through this, so any layer edit is
    /// undoable and SwiftUI sees the `layers` mutation.
    public func mutateLayers(_ body: (inout LayerTable) -> Void) {
        let prior = layers
        body(&layers)
        guard layers != prior else { return }   // no-op edits don't pollute undo
        registerUndo { drawing in
            drawing.mutateLayers { $0 = prior }
        }
    }

    /// Adds a layer (no-op + no undo if the name is taken). Returns `true` if added.
    @discardableResult
    public func addLayer(_ layer: Layer) -> Bool {
        guard !layers.contains(layer.name) else { return false }
        mutateLayers { _ = $0.add(layer) }
        return true
    }

    /// Removes a layer record by name. Entities on the layer are handled per
    /// `reassignTo`: if non-nil, every entity on `name` is moved to that layer
    /// (registered as part of the same undo group); if nil, entity layer refs are
    /// left as-is (they'll resolve with the default pen — see `LayerTable`'s
    /// removal-policy note). The default layer "0" is never removed.
    public func removeLayer(_ name: String, reassignTo: String? = nil) {
        guard name != "0", layers.contains(name) else { return }
        if let target = reassignTo {
            for e in entities where e.layer.name == name {
                var moved = e
                moved.layer = LayerID(target)
                replace(moved)
            }
        }
        mutateLayers { $0.remove(named: name) }
    }

    /// Renames a layer; referencing entities are re-pointed to the new name so
    /// they keep their layer (registered in the same undo group). Returns `true`
    /// on success.
    @discardableResult
    public func renameLayer(_ oldName: String, to newName: String) -> Bool {
        guard layers.contains(oldName), !layers.contains(newName) else { return false }
        // Re-point entities first (each undoable), then rename the record.
        for e in entities where e.layer.name == oldName {
            var moved = e
            moved.layer = LayerID(newName)
            replace(moved)
        }
        var ok = false
        mutateLayers { ok = $0.rename(oldName, to: newName) }
        return ok
    }

    /// Sets the active layer (where new entities land). Undoable.
    public func setActiveLayer(_ name: String) {
        mutateLayers { $0.activate(name) }
    }

    /// Sets a layer's visibility (frozen == hidden). Undoable.
    public func setLayerVisible(_ name: String, _ visible: Bool) {
        mutateLayers { $0.setVisible(name, visible) }
    }

    /// Sets a layer's locked flag. Undoable.
    public func setLayerLocked(_ name: String, _ locked: Bool) {
        mutateLayers { $0.setLocked(name, locked) }
    }

    /// Sets a layer's printable flag. Undoable.
    public func setLayerPrintable(_ name: String, _ printable: Bool) {
        mutateLayers { $0.setPrintable(name, printable) }
    }

    /// Sets a layer's construction flag. Undoable.
    public func setLayerConstruction(_ name: String, _ construction: Bool) {
        mutateLayers { $0.setConstruction(name, construction) }
    }

    // MARK: - Block mutations (value-snapshot undo of the whole BlockTable)

    /// Whole-table block mutation with undo (same value-snapshot scheme as
    /// `mutateLayers`).
    public func mutateBlocks(_ body: (inout BlockTable) -> Void) {
        let prior = blocks
        body(&blocks)
        guard blocks != prior else { return }
        registerUndo { drawing in
            drawing.mutateBlocks { $0 = prior }
        }
    }

    /// Adds a block definition (no-op + no undo if the name is taken). Returns
    /// `true` if added. Member entities (referenced by `block.entityIDs`) must
    /// already be added to the drawing via `add(_:)`.
    @discardableResult
    public func addBlock(_ block: Block) -> Bool {
        guard !blocks.contains(block.name) else { return false }
        mutateBlocks { _ = $0.add(block) }
        return true
    }

    /// Removes a block *definition* by name. If `deletingContents` is true, the
    /// block's member entities are also removed from the drawing (same undo group);
    /// otherwise they remain as ordinary top-level entities. The active block, if
    /// removed, is cleared.
    public func removeBlock(_ name: String, deletingContents: Bool = false) {
        guard let block = blocks.block(named: name) else { return }
        if deletingContents {
            for id in block.entityIDs { remove(id) }
        }
        mutateBlocks { $0.remove(named: name) }
    }

    /// Renames a block definition. Returns `true` on success.
    @discardableResult
    public func renameBlock(_ oldName: String, to newName: String) -> Bool {
        var ok = false
        mutateBlocks { ok = $0.rename(oldName, to: newName) }
        return ok
    }

    /// Sets the active block (`nil` clears). Undoable.
    public func setActiveBlock(_ name: String?) {
        mutateBlocks { $0.activate(name) }
    }

    // MARK: - Undo plumbing

    /// Registers a value-snapshot undo closure. The closure captures the prior
    /// value(s) and, when invoked, re-mutates the drawing — which re-registers
    /// the inverse, giving redo for free (the standard `UndoManager` pattern).
    private func registerUndo(_ action: @escaping @MainActor (CADDrawing) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { drawing in
            // UndoManager invokes the handler on the main thread for document
            // apps; assert the main-actor contract that makes this sound.
            MainActor.assumeIsolated {
                action(drawing)
            }
        }
    }

    // MARK: - Bulk load (no undo — used by document open)

    /// Replaces all content without registering undo (used when loading a file).
    /// Blocks/variables default to empty/fresh so existing two-arg callers keep
    /// working; pass them when loading a parsed DXF header + block table.
    public func load(
        entities newEntities: [EntityRecord],
        layers newLayers: LayerTable,
        blocks newBlocks: BlockTable = BlockTable(),
        graphicVariables newVariables: GraphicVariables = GraphicVariables()
    ) {
        entities = newEntities
        layers = newLayers
        blocks = newBlocks
        graphicVariables = newVariables
        indexByID.removeAll(keepingCapacity: true)
        for (i, e) in entities.enumerated() { indexByID[e.id] = i }
        // Advance the id counter past the highest loaded id.
        let maxID = entities.map(\.id.rawValue).max() ?? 0
        nextRawID = maxID + 1
        undoManager?.removeAllActions()
    }

    // MARK: - Derived geometry

    /// The union bounding box of all entities (empty if the drawing is empty).
    public func boundingBox() -> AABB {
        var box = AABB.empty
        for e in entities { box = box.union(e.boundingBox()) }
        return box
    }

    /// A `ResolveContext` backed by this drawing's real `LayerTable`, so
    /// `.byLayer` pens resolve against actual layer attributes (not the stub
    /// default). The block hook still defers to `currentBlockPen` (the Insert/
    /// Block-resolve owner sets that when recursing). The text hook is the shared
    /// `.lff` font provider (ADR-004) so text entities resolve to stroked glyphs.
    public func makeResolveContext(tessellationTolerance: Double = 0.05,
                                   annotationScale: Double = 1.0) -> ResolveContext {
        // Snapshot the layer table into a Sendable closure (value type copy).
        let table = layers
        // Snapshot the STYLE table into a Sendable closure (value type copy).
        let styleTable = textStyles
        return ResolveContext(
            tessellationTolerance: tessellationTolerance,
            layerAttributes: { layerID in
                table.layer(layerID)?.resolvedPen
                    ?? ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
            },
            fontProvider: CADFonts.provider,
            textStyleProvider: { name in styleTable.style(named: name) },
            annotationScale: annotationScale
        )
    }

    /// Resolves every entity to renderable geometry against this drawing's layer
    /// table. Convenience for the renderer seam; production rendering caches
    /// per-entity by id + version.
    public func resolveAll(_ ctx: ResolveContext? = nil) -> [ResolvedGeometry] {
        let context = ctx ?? makeResolveContext()
        return entities.map { $0.resolve(context) }
    }
}

// MARK: - Composite font provider (native Core Text + .lff stroke, ADR-004)

/// The unified `FontProvider` feeding `ResolveContext.fontProvider`: native
/// outline fonts (Core Text, the default) AND `.lff` stroke fonts behind ONE
/// abstraction. `resolveFont(.native(...))` goes to Core Text; `.stroke(...)`
/// goes to the `.lff` registry; `.shx(...)` is unsupported (Phase 3) and returns
/// `nil` so the resolve arm walks the substitution chain.
public final class CompositeFontProvider: FontProvider, @unchecked Sendable {
    public let native: CoreTextFontProvider
    public let stroke: StrokeFontProvider

    public init(native: CoreTextFontProvider, stroke: StrokeFontProvider) {
        self.native = native
        self.stroke = stroke
    }

    public func resolveFont(_ source: FontSource) -> ShapedFont? {
        switch source {
        case .native:
            return native.resolveFont(source)
        case .stroke:
            return stroke.resolveFont(source)
        case .shx:
            // Phase 3: SHX is read via the substitution chain until a parser lands.
            return nil
        }
    }

    /// Traits-aware resolution: forward the style's bold/italic to the native
    /// provider so a `TextStyle(bold:true)` selects a heavier face (stroke/SHX
    /// ignore traits). Without this forwarding the protocol default would drop the
    /// traits and bold/italic native styles would render Regular.
    public func resolveFont(_ source: FontSource, bold: Bool, italic: Bool) -> ShapedFont? {
        switch source {
        case .native:
            return native.resolveFont(source, bold: bold, italic: italic)
        case .stroke:
            return stroke.resolveFont(source)
        case .shx:
            return nil
        }
    }
}

/// Process-wide font registry feeding `ResolveContext.fontProvider`. Combines the
/// native Core Text provider (the default for new text) with the `.lff` stroke
/// registry (retained for DXF fidelity), behind ONE `FontProvider` (ADR-004).
///
/// ## Font lookup (stroke fonts)
/// - The bundled app: `LibreCADmacOS.app/Contents/Resources/fonts/*.lff`
///   (copied by `macos/scripts/make-app.sh`), found via `Bundle.main`.
/// - The bare SwiftPM binary / dev: the in-repo `librecad/support/fonts/`,
///   derived from this file's `#filePath` (stable absolute path), so the
///   provider works without a bundle.
///
/// An empty/`nil` `.lff` style name resolves to the default stroke font, which is
/// also registered under the empty key.
public enum CADFonts {

    /// The default stroke-font base name (LibreCAD's ISO 3098-2 "standard").
    public static let defaultFontName = "standard"

    /// The shared native provider (Core Text outlines → fills, the default).
    public static let nativeProvider = CoreTextFontProvider()

    /// The shared `.lff` stroke provider (retained for DXF fidelity).
    public static let strokeProvider: StrokeFontProvider = {
        let p = StrokeFontProvider()
        for dir in fontSearchDirectories() {
            p.registerSearchDirectory(dir)
        }
        // Register the default font under both its name and the empty key so a
        // text entity with no explicit style ("") resolves to it.
        if let url = defaultFontURL() {
            p.registerFont(at: url, name: defaultFontName)
            p.registerFont(at: url, name: "")
        }
        return p
    }()

    /// The unified provider handed to `ResolveContext.fontProvider`.
    public static let provider: CompositeFontProvider =
        CompositeFontProvider(native: nativeProvider, stroke: strokeProvider)

    /// Directories searched for `<name>.lff`, in priority order: the app bundle's
    /// `Resources/fonts`, then the in-repo `librecad/support/fonts`.
    static func fontSearchDirectories() -> [URL] {
        var dirs: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("fonts"),
           FileManager.default.fileExists(atPath: bundled.path) {
            dirs.append(bundled)
        }
        if let repo = repoFontsDirectory() {
            dirs.append(repo)
        }
        return dirs
    }

    /// The default font's URL (bundle first, then repo). `nil` if neither exists.
    static func defaultFontURL() -> URL? {
        if let bundled = Bundle.main.url(
            forResource: defaultFontName, withExtension: "lff", subdirectory: "fonts"
        ) {
            return bundled
        }
        if let repo = repoFontsDirectory()?
            .appendingPathComponent("\(defaultFontName).lff"),
           FileManager.default.fileExists(atPath: repo.path) {
            return repo
        }
        return nil
    }

    /// The in-repo `librecad/support/fonts` directory, derived from this file's
    /// source path (dev fallback for the bare binary / tests). `nil` if absent.
    static func repoFontsDirectory() -> URL? {
        // <repo>/macos/engine/Sources/CADEngine/CADDrawing.swift -> up 4 -> <repo>
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // CADEngine
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // engine
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // <repo>
        let dir = repoRoot.appendingPathComponent("librecad/support/fonts")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }
}
