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

    // MARK: Document Settings additions (V4 — Document Settings sheet)
    //
    // The settings sheet (Units / Grid & Snap / Dimensions / Paper) surfaces these
    // as editable, DXF-round-tripping document state. Each is a standard AutoCAD
    // header var EXCEPT `$LC_SNAPMODE`, a LibreCAD-private var for the app-only snap
    // mode set (decision D5). All follow the same one-line typed-accessor pattern as
    // the accessors above, so they persist + round-trip through the `values` bag for
    // free (set → read in memory, and via the DXF header bridge when it carries
    // them — other CAD apps ignore unknown `$`-vars gracefully).

    /// `$GRIDUNIT` — the user's preferred grid spacing in world units (the X
    /// component; LibreCAD stores grid spacing as a vector but the app uses a single
    /// uniform spacing). Defaults to 1. Mirrors `model.preferredGridSpacing`.
    public var gridSpacing: Double {
        get {
            // Stored as a vector ($GRIDUNIT is DXF code 10/20); read the X. Fall back
            // to a scalar double if a prior write used one, then the default.
            if let v = values["$GRIDUNIT"]?.vectorValue { return v.x }
            return double("$GRIDUNIT", default: 1.0)
        }
        set { setVector("$GRIDUNIT", Vector(newValue, newValue)) }
    }

    /// `$DIMTXT` — the document-default dimension measurement-text height (world
    /// units). New dimensions are born with this; existing dims without an explicit
    /// per-entity height fall back to it via the resolve hook (D4). Defaults 2.5.
    public var dimTextHeight: Double {
        get { double("$DIMTXT", default: 2.5) }
        set { setDouble("$DIMTXT", newValue) }
    }

    /// `$DIMASZ` — the document-default dimension arrowhead size (world units).
    /// Defaults 2.5.
    public var dimArrowSize: Double {
        get { double("$DIMASZ", default: 2.5) }
        set { setDouble("$DIMASZ", newValue) }
    }

    /// `$DIMSCALE` — the overall dimension scale factor (multiplies text + arrow at
    /// draw time; pairs with `ResolveContext.annotationScale`). Defaults 1.
    public var dimScale: Double {
        get { double("$DIMSCALE", default: 1.0) }
        set { setDouble("$DIMSCALE", newValue) }
    }

    /// `$DIMLUNIT` — the dimension-text linear unit format. DXF codes match
    /// `$LUNITS` (1=Scientific, 2=Decimal, 3=Engineering, 4=Architectural,
    /// 5=Fractional). Defaults Decimal (mirrors the drawing's linear format).
    public var dimLinearFormat: LinearFormat {
        get { Self.linearFormat(fromDXF: int("$DIMLUNIT", default: 2)) }
        set { setInt("$DIMLUNIT", Self.dxfLUNITS(for: newValue)) }
    }

    /// `$DIMDEC` — the dimension-text linear precision (decimal places). Defaults 4
    /// (mirrors `$LUPREC`).
    public var dimLinearPrecision: Int {
        get { int("$DIMDEC", default: 4) }
        set { setInt("$DIMDEC", newValue) }
    }

    /// `$DIMEXO` — the extension-line ORIGIN offset (gap between the measured
    /// feature and where the drawn extension line starts), world units. `0`
    /// (unset) ⇒ the resolve uses its arrow-fraction default. Round-trips through
    /// the header bridge.
    public var dimExtensionOffset: Double {
        get { double("$DIMEXO", default: 0) }
        set { setDouble("$DIMEXO", newValue) }
    }

    /// `$DIMEXE` — how far an extension line runs PAST the dimension line, world
    /// units. `0` (unset) ⇒ the arrow-fraction default.
    public var dimExtensionBeyond: Double {
        get { double("$DIMEXE", default: 0) }
        set { setDouble("$DIMEXE", newValue) }
    }

    /// `$DIMGAP` — the gap between the dimension line and the measurement text,
    /// world units. `0` (unset) ⇒ the text-height-fraction default.
    public var dimTextGap: Double {
        get { double("$DIMGAP", default: 0) }
        set { setDouble("$DIMGAP", newValue) }
    }

    /// `$PDMODE` — the document-default point display mode (the AutoCAD point-marker
    /// encoding; see `PointDisplayMode`). New points and points left at the `.dot`
    /// inherit sentinel render with this. Defaults `0` (a dot). Round-trips through
    /// the header bridge (other CAD apps honor `$PDMODE` natively).
    public var pointDisplayMode: PointDisplayMode {
        get { PointDisplayMode(rawMode: int("$PDMODE", default: 0)) }
        set { setInt("$PDMODE", newValue.rawMode) }
    }

    /// `$PDSIZE` — the document-default point marker size (world units). The marker
    /// glyph is drawn at this half-extent. `<= 0` (unset / "auto") ⇒ the resolve
    /// step uses its built-in default half-extent (AutoCAD's `0` means "5% of the
    /// viewport", which the viewport-free resolve approximates with a fixed size).
    /// Defaults `0`. Round-trips through the header bridge.
    public var pointSize: Double {
        get { double("$PDSIZE", default: 0) }
        set { setDouble("$PDSIZE", newValue) }
    }

    /// `$LC_SNAPMODE` — a LibreCAD-PRIVATE header var persisting the app's enabled
    /// snap-mode set (`SnapMode.rawValue`, decision D5). It has no standard DXF
    /// header var; we store it as a custom `$`-var so it travels with the document
    /// and round-trips (other CAD apps ignore unknown header vars). `nil` (unset) ⇒
    /// the app keeps its built-in interactive default.
    public var snapModeRaw: Int? {
        get { values["$LC_SNAPMODE"]?.intValue }
        set {
            if let newValue { setInt("$LC_SNAPMODE", newValue) }
            else { remove("$LC_SNAPMODE") }
        }
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

// MARK: - Named dimension styles (the DXF DIMSTYLE table)

/// One named dimension style — the value-type port of a `DRW_Dimstyle` table
/// entry (the renderer-relevant subset). A `DimData.styleName` (DXF code 3)
/// references one of these by name; the resolve step looks it up via
/// `ResolveContext.namedDimStyleProvider` so a dimension inherits its named
/// style's text height / arrow size / scale / format / ext-line offsets.
///
/// The carried values mirror `ResolvedDimStyle` (the resolved form a dimension
/// inherits) plus the style's `name`. `style` is the `ResolvedDimStyle` a
/// referencing dimension falls back to (per-entity override still wins, ADR
/// decision D4). Pure value type (ADR-001) — round-trips through the DIMSTYLE
/// reader/writer.
public struct NamedDimStyle: Sendable, Hashable, Codable {
    /// The style's name (DXF code 2), e.g. "Standard" / "ISO-25". Case-insensitive
    /// match on lookup (AutoCAD style names are case-insensitive).
    public var name: String
    /// The resolved values dimensions referencing this style inherit
    /// ($DIMTXT/$DIMASZ/$DIMSCALE/$DIMLUNIT/$DIMDEC + $DIMEXO/$DIMEXE/$DIMGAP).
    public var style: ResolvedDimStyle

    public init(name: String, style: ResolvedDimStyle) {
        self.name = name
        self.style = style
    }
}

/// The drawing's DIMSTYLE table — the value-type port of the DXF DIMSTYLE table
/// (`RS_BlockList`-style registry but for dim styles). Named styles a dimension
/// references by `styleName` (DXF code 3) plus the document-active style name
/// ($DIMSTYLE, usually "Standard"). The resolve precedence (decision D4,
/// extended) is: per-entity field override > the referenced named style > the
/// document header default (`$DIM*` graphic vars via `dimensionStyle`).
///
/// Lookup is case-insensitive (AutoCAD table names). Pure value type so the whole
/// table snapshots cheaply for `makeResolveContext`'s `@Sendable` closure and for
/// value-snapshot undo (ADR-002), and round-trips through the DIMSTYLE
/// reader/writer.
public struct DimStyleTable: Sendable, Hashable, Codable {
    /// The named styles, in stable insertion order.
    public private(set) var styles: [NamedDimStyle]
    /// The document-active style name ($DIMSTYLE). `nil` ⇒ "Standard"/first.
    public var activeName: String?

    public init(styles: [NamedDimStyle] = [], activeName: String? = nil) {
        self.styles = styles
        self.activeName = activeName
    }

    public var count: Int { styles.count }
    public var isEmpty: Bool { styles.isEmpty }

    /// The named style matching `name` (case-insensitive), or `nil`.
    public func style(named name: String) -> NamedDimStyle? {
        styles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether a style with `name` (case-insensitive) is present.
    public func contains(_ name: String) -> Bool { style(named: name) != nil }

    /// Adds (or replaces, on a case-insensitive name clash) a named style.
    public mutating func upsert(_ s: NamedDimStyle) {
        if let i = styles.firstIndex(where: {
            $0.name.caseInsensitiveCompare(s.name) == .orderedSame
        }) {
            styles[i] = s
        } else {
            styles.append(s)
        }
    }

    /// Removes a named style by name (case-insensitive). "Standard" is kept (the
    /// table always retains a fallback style, matching the DXF requirement).
    public mutating func remove(named name: String) {
        guard name.caseInsensitiveCompare("Standard") != .orderedSame else { return }
        styles.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The active (document) named style — the one `activeName` names, else
    /// "Standard", else the first defined — or `nil` when the table is empty.
    public func active() -> NamedDimStyle? {
        if let n = activeName, let s = style(named: n) { return s }
        if let std = style(named: "Standard") { return std }
        return styles.first
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

    /// The named DIMSTYLE table (the DXF DIMSTYLE table). A dimension references a
    /// style by `styleName` (DXF code 3); `makeResolveContext` wires this into the
    /// `namedDimStyleProvider` so the referenced style fills any value the
    /// dimension does not carry per-entity (precedence D4: per-entity > named style
    /// > header default). Populated on load (from the bridge's `lc_dimstyles`) and
    /// emitted on write so save preserves named styles + their ext-line offsets.
    public var dimStyles = DimStyleTable()

    /// The named layer-state registry (feature-catalog F17 / AutoCAD LAYERSTATE).
    /// Each entry is a snapshot of every layer's display/edit flags the user saved;
    /// `restoreLayerState` re-applies one onto the live `layers` table through the
    /// undoable funnel. App-local SESSION state: DXF has no LAYERSTATE table, so this
    /// is not serialized into the .dxf payload, but every mutation IS undoable (the
    /// value-snapshot funnel below) so save/restore + ⌘Z behave consistently within
    /// a session.
    public private(set) var layerStates = LayerStateTable()

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

    // MARK: - Draw order (F16 — raise / lower / to-front / to-back)
    //
    // The renderer draws entities in `entities` storage order (front-most last),
    // so the draw-order Z-stack IS the order of the `entities` array: later index
    // == painted on top. Re-ordering is therefore a permutation of `entities` +
    // an `indexByID` rebuild, registered as ONE value-snapshot undo (ADR-002) so a
    // single ⌘Z restores the prior order. We snapshot the WHOLE order (a cheap
    // `[EntityID]` array) rather than the records, because only the sequence
    // changes — the records themselves are untouched (`Arrange` never edits
    // geometry/pen/layer).

    /// The storage (draw-order) index of an entity, or `nil` if it is not present.
    /// Front-most == the highest index (drawn last → on top). The renderer reads
    /// this to honor draw order when it iterates the spatially-culled set, which is
    /// not otherwise in storage order. O(1).
    public func storageIndex(of id: EntityID) -> Int? { indexByID[id] }

    /// Re-applies a full draw-order permutation (a `[EntityID]` listing every
    /// current entity exactly once, front-most last) as ONE undoable step. The
    /// `Arrange` ops below all funnel through this so each is a single ⌘Z. A request
    /// that is not a valid permutation of the current id set (missing/extra/dup ids)
    /// is rejected as a no-op (returns `false`) so a stale caller can never corrupt
    /// the store. A no-op permutation (already in this order) registers no undo.
    @discardableResult
    public func reorderEntities(_ order: [EntityID]) -> Bool {
        guard order.count == entities.count,
              Set(order).count == order.count,
              Set(order) == Set(indexByID.keys) else { return false }
        let prior = entities.map(\.id)
        guard order != prior else { return true }   // no-op order: nothing to do
        applyOrder(order)
        registerUndo { drawing in
            drawing.reorderEntities(prior)           // undo restores the prior order
        }
        return true
    }

    /// Permutes `entities` to match `order` and rebuilds `indexByID`. No undo here —
    /// the public `reorderEntities` owns the undo registration.
    private func applyOrder(_ order: [EntityID]) {
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
        entities = order.compactMap { byID[$0] }
        indexByID.removeAll(keepingCapacity: true)
        for (i, e) in entities.enumerated() { indexByID[e.id] = i }
    }

    /// Brings `ids` to the FRONT of the draw order (painted last → on top), keeping
    /// their relative order, as ONE undoable step. Ids not in the drawing are
    /// ignored. Used by Arrange ▸ Bring to Front. Returns whether the order changed.
    @discardableResult
    public func bringToFront(_ ids: [EntityID]) -> Bool {
        let moving = orderedSubset(ids)
        guard !moving.isEmpty else { return false }
        let movingSet = Set(moving)
        let rest = entities.map(\.id).filter { !movingSet.contains($0) }
        return reorderEntities(rest + moving)
    }

    /// Sends `ids` to the BACK of the draw order (painted first → underneath),
    /// keeping their relative order, as ONE undoable step. Arrange ▸ Send to Back.
    @discardableResult
    public func sendToBack(_ ids: [EntityID]) -> Bool {
        let moving = orderedSubset(ids)
        guard !moving.isEmpty else { return false }
        let movingSet = Set(moving)
        let rest = entities.map(\.id).filter { !movingSet.contains($0) }
        return reorderEntities(moving + rest)
    }

    /// Raises `ids` one step toward the front (each swaps with the next non-moving
    /// entity above it), as ONE undoable step. Arrange ▸ Bring Forward. The set
    /// moves as a block: contiguous runs slide up by one past the first entity above
    /// them that is not itself moving. Returns whether the order ACTUALLY changed
    /// (already-frontmost / empty set → `false`, no undo step).
    @discardableResult
    public func raise(_ ids: [EntityID]) -> Bool {
        stepReorder(DrawOrder.raised(entities.map(\.id), moving: Set(ids)))
    }

    /// Lowers `ids` one step toward the back (mirror of `raise`), as ONE undoable
    /// step. Arrange ▸ Send Backward. Returns whether the order actually changed.
    @discardableResult
    public func lower(_ ids: [EntityID]) -> Bool {
        stepReorder(DrawOrder.lowered(entities.map(\.id), moving: Set(ids)))
    }

    /// Applies a one-step (raise/lower) order ONLY if it differs from the current
    /// order, returning whether it changed — so a no-effect step (empty set, or the
    /// selection already at the extreme) reports `false` and registers no undo.
    @discardableResult
    private func stepReorder(_ order: [EntityID]) -> Bool {
        guard order != entities.map(\.id) else { return false }
        return reorderEntities(order)
    }

    /// The subset of `ids` that are present in the drawing, returned in the CURRENT
    /// draw order (so a Bring-to-Front of a multi-selection keeps the visible
    /// stacking among the moved entities). Drops absent/duplicate ids.
    private func orderedSubset(_ ids: [EntityID]) -> [EntityID] {
        let want = Set(ids)
        return entities.map(\.id).filter { want.contains($0) }
    }

    // MARK: - Revert direction (F16 — flip an entity's start/end / vertex order)

    /// Flips the geometric direction of the entity with `id` (its start/end swap,
    /// or its vertex/control-point order reverses) as ONE undoable `replace`
    /// (ADR-002). The DRAWN shape is unchanged — only the entity's *direction* (the
    /// order it is defined / traversed) flips — which matters for offset side,
    /// arrow/leader orientation, hatch boundary winding, and trim/extend "from"
    /// ends (LibreCAD's "Revert direction"). Kinds with no meaningful direction
    /// (point/circle/text/insert/…) are a no-op (returns `false`). Returns whether
    /// anything changed.
    @discardableResult
    public func revertDirection(of id: EntityID) -> Bool {
        guard var record = entity(id),
              let flipped = EntityDirection.reversed(record.kind) else { return false }
        record.kind = flipped
        replace(record)             // undoable; preserves id/layer/pen/flags
        return true
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

    /// Freezes (`true`) or thaws (`false`) EVERY layer in one undoable step
    /// (`RS_LayerList::freezeAll`). Used by the sidebar's freeze-all affordance.
    public func freezeAllLayers(_ frozen: Bool) {
        mutateLayers { $0.freezeAll(frozen) }
    }

    /// Locks (`true`) or unlocks (`false`) EVERY layer in one undoable step
    /// (`RS_LayerList::lockAll`). Used by the sidebar's lock-all affordance.
    public func lockAllLayers(_ locked: Bool) {
        mutateLayers { $0.lockAll(locked) }
    }

    // MARK: - Layer states (value-snapshot undo of the whole LayerStateTable)

    /// Whole-table layer-state mutation with undo (the same value-snapshot scheme as
    /// `mutateLayers`/`mutateBlocks`; `LayerStateTable` is a value type so the undo
    /// snapshot is one struct copy, ADR-002). No-op edits don't pollute undo.
    public func mutateLayerStates(_ body: (inout LayerStateTable) -> Void) {
        let prior = layerStates
        body(&layerStates)
        guard layerStates != prior else { return }
        registerUndo { drawing in
            drawing.mutateLayerStates { $0 = prior }
        }
    }

    /// Saves the CURRENT layer flags as a named state (overwriting any same-named
    /// state — AutoCAD LAYERSTATE Save). Undoable. Returns the name it was saved
    /// under (the requested name, trimmed; empty falls back to a fresh `State-N`).
    @discardableResult
    public func saveLayerState(named requestedName: String) -> String {
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? layerStates.newName() : trimmed
        let snapshot = LayerState(name: name, capturing: layers)
        mutateLayerStates { $0.upsert(snapshot) }
        return name
    }

    /// Restores a named layer state onto the live layer table as ONE undoable step
    /// (so ⌘Z reverts the whole flag restore). Each captured layer that still exists
    /// gets its frozen/lock/print/construction flags re-applied; layers added since
    /// the snapshot are untouched, captured-but-deleted layers skipped. No-op if the
    /// state is unknown. Returns `true` if a state was found + applied.
    @discardableResult
    public func restoreLayerState(named name: String) -> Bool {
        guard let state = layerStates.state(named: name) else { return false }
        mutateLayers { state.apply(to: &$0) }
        return true
    }

    /// Removes a named layer state (undoable). No-op if absent.
    public func removeLayerState(named name: String) {
        mutateLayerStates { $0.remove(named: name) }
    }

    /// Renames a layer state (undoable). Returns `true` on success.
    @discardableResult
    public func renameLayerState(_ oldName: String, to newName: String) -> Bool {
        var ok = false
        mutateLayerStates { ok = $0.rename(oldName, to: newName) }
        return ok
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

    // MARK: - Create block from a selection (CreateBlockTool's model op)

    /// The outcome of a `makeBlockFromEntities` call: the (possibly de-duplicated)
    /// name the block was registered under, and the id of the `.insert` entity that
    /// replaced the originals.
    public struct BlockCreation: Sendable, Hashable {
        /// The name the new block was registered under (may differ from the request
        /// if a clash forced `BlockTable.newName`).
        public let blockName: String
        /// The id of the `.insert` entity now standing in for the selection.
        public let insertID: EntityID
    }

    /// Creates a named block from a set of existing entities and replaces those
    /// entities with a single `.insert` that references the new block — the engine
    /// op behind `CreateBlockTool` (feature-catalog F9). Mirrors LibreCAD's
    /// "create block" command (`RS_ActionBlocksCreate` / `RS_Graphic::addBlock`):
    /// the selection's records become the block's members (re-authored RELATIVE to
    /// the chosen `basePoint`, so the block's local frame has its base at the
    /// origin), and one INSERT placed AT `basePoint` re-draws them in their original
    /// world positions.
    ///
    /// ## Why this is a direct model op (NOT a `ToolEdit`)
    /// `ToolEdit` only expresses entity-level `.add`/`.replace`/`.remove`; it cannot
    /// touch the `BlockTable`. Block creation must register a `Block` AND re-author
    /// the member records AND drop an INSERT, so `CreateBlockTool` calls this
    /// undoable mutator directly (decision documented in the tool's header). Every
    /// step is registered against `undoManager`, so the whole creation is undoable
    /// (the `UndoManager` groups the calls made within one event loop turn, matching
    /// how `applyCommit` groups a tool's edits).
    ///
    /// Behavior:
    ///   - `ids` not present in the drawing are skipped; an EMPTY effective set
    ///     (no valid ids) is a no-op returning `nil` (nothing to block).
    ///   - the block name is de-duplicated via `BlockTable.newName(suggestion:)` so a
    ///     clash never silently fails; the actual name is returned.
    ///   - each member is RE-AUTHORED relative to `basePoint` (its geometry is
    ///     translated by `-basePoint`) and re-minted a fresh id, so the block owns
    ///     private member records (the `.selected` flag is stripped — members are not
    ///     top-level selectable). The originals are removed.
    ///   - one INSERT (`blockName` at `basePoint`, unit scale, no rotation) is added,
    ///     inheriting the layer/pen of the FIRST selected entity (LibreCAD places the
    ///     block reference on the active layer; we keep it coherent with the source).
    ///
    /// - Returns: the registered name + the new insert's id, or `nil` for an empty
    ///   effective selection / blank name.
    @discardableResult
    public func makeBlockFromEntities(
        name requestedName: String,
        basePoint: Vector,
        ids: [EntityID]
    ) -> BlockCreation? {
        // Resolve the requested ids to live records, preserving order + dropping
        // any that are no longer in the drawing (and de-duplicating repeats).
        var seen = Set<EntityID>()
        let sources: [EntityRecord] = ids.compactMap { id in
            guard seen.insert(id).inserted, let rec = entity(id) else { return nil }
            return rec
        }
        guard !sources.isEmpty else { return nil }

        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let blockName = blocks.newName(suggestion: trimmed)

        // The translation that re-authors world geometry into the block's local
        // frame (base point → origin). The placing INSERT undoes it (insertionPoint
        // == basePoint) so the geometry re-draws exactly where it was.
        let toLocal = Affine2D.translation(Vector(-basePoint.x, -basePoint.y))

        // Mint the member ids up front so the Block record and the added records
        // agree (add() honors a non-placeholder id; these are freshly minted so they
        // cannot collide).
        var memberIDs: [EntityID] = []
        memberIDs.reserveCapacity(sources.count)
        var memberRecords: [EntityRecord] = []
        memberRecords.reserveCapacity(sources.count)
        for src in sources {
            let mid = mintID()
            memberIDs.append(mid)
            var member = src
            member.id = mid
            member.kind = src.kind.transformed(by: toLocal)
            member.isSelected = false            // members are not top-level selectable
            memberRecords.append(member)
        }

        // Remove the originals, add the re-authored members, register the block, and
        // drop the INSERT — each call is undoable, so the whole op reverses as a unit.
        for src in sources { remove(src.id) }
        for member in memberRecords { _ = add(member) }
        addBlock(Block(name: blockName, basePoint: Vector(0, 0), entityIDs: memberIDs))

        let template = sources[0]
        let insertRecord = EntityRecord(
            id: .placeholder,
            layer: template.layer,
            pen: template.pen,
            flags: .default,
            kind: .insert(InsertData(blockName: blockName, insertionPoint: basePoint))
        )
        let insertID = add(insertRecord)
        return BlockCreation(blockName: blockName, insertID: insertID)
    }

    // MARK: - Graphic-variable mutations (value-snapshot undo of the whole bag)

    /// Whole-bag graphic-variable mutation with undo — the same value-snapshot
    /// scheme as `mutateLayers`/`mutateBlocks` (`GraphicVariables` is a value type,
    /// so the undo snapshot is one struct copy, ADR-002). The Document Settings
    /// sheet funnels EVERY header-var edit (units, precision, grid spacing, dim
    /// defaults, snap modes…) through this so each change is undoable and SwiftUI
    /// sees the `graphicVariables` mutation. No-op edits don't pollute undo (D3:
    /// live-apply, one undo step per field).
    public func mutateGraphicVariables(_ body: (inout GraphicVariables) -> Void) {
        let prior = graphicVariables
        body(&graphicVariables)
        guard graphicVariables != prior else { return }   // no-op edits skip undo
        registerUndo { drawing in
            drawing.mutateGraphicVariables { $0 = prior }
        }
    }

    // MARK: - DIMSTYLE-table mutations (value-snapshot undo of the whole table)

    /// Whole-table DIMSTYLE mutation with undo — the same value-snapshot scheme as
    /// `mutateLayers`/`mutateBlocks` (`DimStyleTable` is a value type, so the undo
    /// snapshot is one struct copy, ADR-002). No-op edits don't pollute undo.
    public func mutateDimStyles(_ body: (inout DimStyleTable) -> Void) {
        let prior = dimStyles
        body(&dimStyles)
        guard dimStyles != prior else { return }
        registerUndo { drawing in
            drawing.mutateDimStyles { $0 = prior }
        }
    }

    /// Adds or replaces a named dimension style (undoable). Returns the name added.
    @discardableResult
    public func upsertDimStyle(_ style: NamedDimStyle) -> String {
        mutateDimStyles { $0.upsert(style) }
        return style.name
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
        graphicVariables newVariables: GraphicVariables = GraphicVariables(),
        dimStyles newDimStyles: DimStyleTable = DimStyleTable()
    ) {
        entities = newEntities
        layers = newLayers
        blocks = newBlocks
        graphicVariables = newVariables
        dimStyles = newDimStyles
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
        // Snapshot the document dimension style from the header vars (value copy) so
        // the resolve hook fills document defaults for dims without per-entity
        // overrides (decision D4). These are the Document Settings sheet's `$DIM*`.
        let docDimStyle = dimensionStyle
        // Snapshot the named DIMSTYLE table (value copy) so a dimension that
        // references a style by name resolves through it (the D4 middle rung,
        // per-entity > named style > header default).
        let dimStyleTable = dimStyles
        // Snapshot the document-default point style ($PDMODE) + size ($PDSIZE) so a
        // point left at the `.dot` inherit sentinel picks up the drawing-wide point
        // style (the Document Settings Points tab writes these header vars).
        let docPointMode = graphicVariables.pointDisplayMode
        let docPointSize = graphicVariables.pointSize
        // Snapshot the block table → member records map (value copies) so an
        // `.insert` can resolve a referenced block's geometry. Building the
        // name→[EntityRecord] map once here keeps the per-insert lookup O(1) and
        // the closure `@Sendable` (it captures only value types, no `self`).
        let blockMembers = blockMembersSnapshot()
        return ResolveContext(
            tessellationTolerance: tessellationTolerance,
            layerAttributes: { layerID in
                table.layer(layerID)?.resolvedPen
                    ?? ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
            },
            fontProvider: CADFonts.provider,
            textStyleProvider: { name in styleTable.style(named: name) },
            annotationScale: annotationScale,
            dimStyleProvider: { docDimStyle },
            namedDimStyleProvider: { name in dimStyleTable.style(named: name)?.style },
            pointStyleProvider: { (mode: docPointMode, size: docPointSize) },
            blockProvider: { name in blockMembers[name] }
        )
    }

    /// Builds a `blockName → [member EntityRecord]` snapshot (value copies) from the
    /// block table: each block's `entityIDs` resolved against `entities`. Backs the
    /// resolve context's `blockProvider` so an `.insert` can expand its block. A
    /// referenced id no longer in the drawing is skipped (the block keeps its other
    /// members). Returns an empty map for a drawing with no blocks.
    func blockMembersSnapshot() -> [String: [EntityRecord]] {
        var map: [String: [EntityRecord]] = [:]
        for block in blocks.blocks where !block.isFrozen {
            let members = block.entityIDs.compactMap { entity($0) }
            map[block.name] = members
        }
        return map
    }

    /// The document-default dimension style assembled from the `$DIM*` header vars
    /// (the Document Settings sheet writes these). Fed to `ResolveContext.
    /// dimStyleProvider` so dimensions without per-entity overrides pick up the
    /// document defaults (decision D4).
    public var dimensionStyle: ResolvedDimStyle {
        ResolvedDimStyle(
            textHeight: graphicVariables.dimTextHeight,
            arrowSize: graphicVariables.dimArrowSize,
            scale: graphicVariables.dimScale,
            linearFormat: graphicVariables.dimLinearFormat,
            linearPrecision: graphicVariables.dimLinearPrecision,
            extensionOffset: graphicVariables.dimExtensionOffset,
            extensionBeyond: graphicVariables.dimExtensionBeyond,
            textGap: graphicVariables.dimTextGap
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
/// outline fonts (Core Text, the default), `.lff` stroke fonts, AND AutoCAD
/// `.shx` shape fonts, all behind ONE abstraction. `resolveFont(.native(...))`
/// goes to Core Text; `.stroke(...)` goes to the `.lff` registry; `.shx(...)`
/// goes to the SHX registry (when one is wired). A source that no provider can
/// satisfy returns `nil` so the resolve arm (`TextShaper.resolveShaper`) walks
/// the substitution chain.
public final class CompositeFontProvider: FontProvider, @unchecked Sendable {
    public let native: CoreTextFontProvider
    public let stroke: StrokeFontProvider
    /// AutoCAD `.shx` shape-font registry. Optional so callers that never touch
    /// SHX (most) pay nothing; when `nil`, `.shx` sources fall to substitution.
    public let shx: SHXFontProvider?

    public init(native: CoreTextFontProvider,
                stroke: StrokeFontProvider,
                shx: SHXFontProvider? = nil) {
        self.native = native
        self.stroke = stroke
        self.shx = shx
    }

    public func resolveFont(_ source: FontSource) -> ShapedFont? {
        switch source {
        case .native:
            return native.resolveFont(source)
        case .stroke:
            return stroke.resolveFont(source)
        case .shx:
            // True-font path: serve the compiled `.shx` shapes when available;
            // otherwise `nil` ⇒ the resolve arm walks the substitution chain.
            return shx?.resolveFont(source)
        }
    }

    /// Traits-aware resolution: forward the style's bold/italic to the native
    /// provider so a `TextStyle(bold:true)` selects a heavier face (stroke/SHX
    /// ignore traits — the formats have no faces). Without this forwarding the
    /// protocol default would drop the traits and bold/italic native styles would
    /// render Regular.
    public func resolveFont(_ source: FontSource, bold: Bool, italic: Bool) -> ShapedFont? {
        switch source {
        case .native:
            return native.resolveFont(source, bold: bold, italic: italic)
        case .stroke:
            return stroke.resolveFont(source)
        case .shx:
            return shx?.resolveFont(source)
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

    /// The shared AutoCAD `.shx` shape-font provider. Searches the SAME font
    /// directories as `.lff` (a drawing's `.shx` fonts sit alongside `.lff` ones in
    /// the user's font path). We do NOT ship any `.shx` (they are licensed), so this
    /// is empty until the user adds `.shx` fonts to a search directory; a referenced
    /// `.shx` that isn't found falls through to the substitution chain.
    public static let shxProvider: SHXFontProvider = {
        let p = SHXFontProvider()
        for dir in fontSearchDirectories() {
            p.registerSearchDirectory(dir)
        }
        return p
    }()

    /// The unified provider handed to `ResolveContext.fontProvider`.
    public static let provider: CompositeFontProvider =
        CompositeFontProvider(native: nativeProvider, stroke: strokeProvider,
                              shx: shxProvider)

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
