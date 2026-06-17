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
    // as editable document state. Each is a standard AutoCAD header var EXCEPT
    // `$LC_SNAPMODE`, a LibreCAD-private var for the app-only snap-mode set
    // (decision D5). All follow the same one-line typed-accessor pattern as the
    // accessors above, so they persist + read back in memory (and through the
    // Codable `DXFPayload` / `CADDrawing.load` path) for free.
    //
    // DXF FILE round-trip: as of the R4b "generic $VAR pass-through" wave, the DXF
    // header bridge carries an extra-var bag, so the STANDARD header vars below
    // ($GRIDUNIT, $PDMODE, $PDSIZE, plus the units/dim vars handled by the fixed
    // header POD) survive a Save → reopen on a .dxf file (other CAD apps ignore
    // unknown `$`-vars gracefully). The PRIVATE `$LC_SNAPMODE` is the exception —
    // libdxfrw's writer only emits its curated var list (and never `customVars`),
    // so `$LC_SNAPMODE` would be silently dropped on a .dxf write; it is persisted
    // ONLY in memory / the Codable payload (it is an app-local preference). DWG: the
    // header-var pass-through follows whatever the DWG writer honors (see DXFWriter).

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

    /// `$LTSCALE` — the drawing-wide LINETYPE SCALE: a global multiplier on every
    /// dashed entity's dash pattern period (AutoCAD's `LTSCALE` system variable).
    /// `resolve()` multiplies it by the per-entity `Pen.linetypeScale` (DXF code 48)
    /// to produce `ResolvedPen.linetypeScale`, which the renderer scales the dash
    /// period by. Defaults `1`. It is a STANDARD AutoCAD header var in libdxfrw's
    /// curated emit list (it always writes the `$LTSCALE` group, code 40), so it
    /// round-trips through the R4b header extra-var bag on a .dxf Save → reopen.
    public var linetypeScale: Double {
        get { double("$LTSCALE", default: 1.0) }
        set { setDouble("$LTSCALE", newValue) }
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
    /// inherit sentinel render with this. Defaults `0` (a dot). It is a standard
    /// AutoCAD header var, so it survives a .dxf Save → reopen via the header
    /// extra-var bag (R4b), and other CAD apps honor `$PDMODE` natively.
    public var pointDisplayMode: PointDisplayMode {
        get { PointDisplayMode(rawMode: int("$PDMODE", default: 0)) }
        set { setInt("$PDMODE", newValue.rawMode) }
    }

    /// `$PDSIZE` — the document-default point marker size (world units). The marker
    /// glyph is drawn at this half-extent. `<= 0` (unset / "auto") ⇒ the resolve
    /// step uses its built-in default half-extent (AutoCAD's `0` means "5% of the
    /// viewport", which the viewport-free resolve approximates with a fixed size).
    /// Defaults `0`. A standard AutoCAD header var: survives a .dxf Save → reopen
    /// via the header extra-var bag (R4b).
    public var pointSize: Double {
        get { double("$PDSIZE", default: 0) }
        set { setDouble("$PDSIZE", newValue) }
    }

    /// `$LC_SNAPMODE` — a LibreCAD-PRIVATE header var persisting the app's enabled
    /// snap-mode set (`SnapMode.rawValue`, decision D5). It has no standard DXF
    /// header var; we store it as a custom `$`-var so it travels with the document
    /// IN MEMORY and through the Codable `DXFPayload` / `CADDrawing.load` path.
    /// LIMITATION: it does NOT survive a .dxf FILE round-trip — libdxfrw's writer
    /// emits only its curated standard-var list (and never `customVars`), so a
    /// non-standard `$`-var like this is silently dropped on a .dxf write (R4b
    /// chose not to patch libdxfrw for an app-local preference). `nil` (unset) ⇒
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

    /// The drawing's paper-space LAYOUT table — the named printed sheets (paper-
    /// space P0, paperspace-plan §2). Each `Layout` is a named sheet plus its page
    /// descriptor; the entities painted on it carry `space == .paper` +
    /// `layoutName == layout.name`. **Model space is IMPLICIT — never an entry
    /// here** (it is the entities with `space == .model`). Names are unique
    /// (case-insensitive) and the table stays ordered by `tabOrder`. Mutated only
    /// through the undoable funnel (`mutateLayouts` and its `addLayout` /
    /// `removeLayout` / `renameLayout` helpers), mirroring the block table. Carried
    /// through the document payload so layouts survive save/load; the DXF/DWG
    /// serialization of layouts is a later phase.
    public private(set) var layouts: [Layout] = []

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

    /// Re-points a block's ordered member-entity id list (undoable, one ⌘Z reverts).
    ///
    /// Because a block's contents are id-refs into `entities` (ADR-001) and
    /// `blockMembersSnapshot()` resolves those ids live at every `makeResolveContext`
    /// call, swapping the member list immediately changes what EVERY `.insert` of the
    /// block resolves to. The block-editor's Save&Close / Discard path uses this to
    /// restore the entry-state member list (the member *records* themselves are
    /// restored via `replace(_:)`). Routed through the `mutateBlocks` value-snapshot
    /// funnel, so it is one coherent undoable step; a no-op (same ids, or an unknown
    /// block) registers nothing. The supplied ids are NOT validated against `entities`
    /// here — a stale id is simply skipped at resolve time (matches `blockMembersSnapshot`).
    public func setBlockMembers(name: String, ids: [EntityID]) {
        mutateBlocks { $0.setEntityIDs(name, ids) }
    }

    /// Appends a single member-entity id to a block's ordered member list (undoable,
    /// one ⌘Z reverts; a duplicate id or an unknown block registers nothing). This is
    /// the explicit seam the Block Editor's `.add` path uses: after `add(_:)` mints a
    /// new entity inside an editing session, the entity's id is threaded into the
    /// editing block via this call (ideally in the SAME undo group as the add), so the
    /// newly-drawn geometry becomes a real BLOCK MEMBER — excluded from model space via
    /// `blockMemberIDs`, drawn only through the block's inserts — rather than leaking as
    /// a loose top-level entity. Wraps `BlockTable.addEntityID(_:to:)`; routed through
    /// the `mutateBlocks` value-snapshot funnel.
    public func addEntityToBlock(name: String, entityID: EntityID) {
        mutateBlocks { $0.addEntityID(entityID, to: name) }
    }

    /// Drops a single member-entity id from a block's member list (undoable; a missing
    /// id or unknown block registers nothing). The companion to `addEntityToBlock`: when
    /// a member is deleted inside the Block Editor, its id is removed from the editing
    /// block's `entityIDs` (ideally in the same undo group as the entity removal) so the
    /// block's membership stays in sync. Does NOT remove the underlying entity record —
    /// the caller's delete path handles that. Wraps `BlockTable.removeEntityID(_:from:)`.
    public func removeEntityFromBlock(name: String, entityID: EntityID) {
        mutateBlocks { $0.removeEntityID(entityID, from: name) }
    }

    // MARK: - Block freeze / visibility (RS_Block::freeze / toggle; undoable via mutateBlocks)
    //
    // A frozen block is invisible: `blockMembersSnapshot()` excludes `where !isFrozen`,
    // so every `.insert` of a frozen block resolves to EMPTY geometry (it doesn't draw
    // or snap). These wrappers mirror the existing block wrappers — each routes through
    // the `mutateBlocks` value-snapshot funnel, so it is exactly ONE undoable step and a
    // genuine no-op (no flag change) registers nothing. The model-version bump that drives
    // re-resolve follows `mutateBlocks` like every other block edit; no view code here
    // (the sidebar eye-toggle + Freeze-all menu are a later wire-wave). Engine-pure.

    /// Sets a block's frozen flag (`RS_Block::freeze`). Undoable. No-op (no undo) if the
    /// block is unknown or already at `frozen` (`BlockTable.setFrozen` is itself a no-op
    /// for an unknown name, and `mutateBlocks` skips the undo when the table is unchanged).
    public func setBlockFrozen(_ name: String, _ frozen: Bool) {
        mutateBlocks { $0.setFrozen(name, frozen) }
    }

    /// Flips a block's frozen flag (`RS_Block::toggle`). Undoable. No-op (no undo) if the
    /// block is unknown (nothing to toggle).
    public func toggleBlockFrozen(_ name: String) {
        mutateBlocks { table in
            guard let block = table.block(named: name) else { return }
            table.setFrozen(name, !block.isFrozen)
        }
    }

    /// Freezes every NAMED block in one undoable step (`RS_BlockList::freezeAll(true)` —
    /// the sidebar's "Freeze all" affordance). Anonymous `*`-blocks (dimension / hatch
    /// regeneration geometry, matching the `DXFWriter`'s `!hasPrefix("*")` author filter)
    /// are skipped — they're system blocks the user can't toggle. A no-op (every named
    /// block already frozen, or no named blocks) registers no undo.
    public func freezeAllBlocks() {
        setAllNamedBlocksFrozen(true)
    }

    /// Thaws every NAMED block in one undoable step (`RS_BlockList::freezeAll(false)` —
    /// the "Defreeze all" affordance). Anonymous `*`-blocks are skipped (see
    /// `freezeAllBlocks`). A no-op (every named block already thawed) registers no undo.
    public func thawAllBlocks() {
        setAllNamedBlocksFrozen(false)
    }

    /// Sets the frozen flag on every named (non-`*`) block as ONE undoable step via the
    /// `mutateBlocks` value-snapshot funnel — a single ⌘Z reverts the whole batch, and a
    /// batch that changes nothing registers no undo.
    private func setAllNamedBlocksFrozen(_ frozen: Bool) {
        mutateBlocks { table in
            for block in table.blocks where !block.name.hasPrefix("*") {
                table.setFrozen(block.name, frozen)
            }
        }
    }

    // MARK: - Dynamic-block mutations (visibility states; undoable via mutateBlocks)

    /// Replaces a block's entire DYNAMIC bundle (`Block.dynamic` — visibility states
    /// this wave). Pass `nil` to clear it back to a plain block. Undoable through the
    /// `mutateBlocks` value-snapshot funnel — one ⌘Z reverts it; a no-op (same value,
    /// or an unknown block) registers nothing. Because `blockDynamicSnapshot()` reads
    /// `Block.dynamic` live at every `makeResolveContext` call, this immediately
    /// changes how every dynamic `.insert` of the block evaluates. Engine-pure (no UI).
    public func setBlockDynamic(name: String, _ def: DynamicBlockDef?) {
        mutateBlocks { table in
            guard var block = table.block(named: name) else { return }
            guard block.dynamic != def else { return }
            block.dynamic = def
            table.upsert(block)
        }
    }

    /// Appends a new EMPTY visibility state (no visible members) to a block,
    /// creating the block's dynamic bundle if absent. Undoable. No-op (no undo) if
    /// the block is unknown or already has a state with this name (state names are
    /// the per-instance key, so they must be unique within a block — §9.4).
    /// Returns the created state's id, or `nil` if it was a no-op.
    @discardableResult
    public func addVisibilityState(toBlock name: String, named stateName: String) -> UUID? {
        var created: UUID?
        mutateBlocks { table in
            guard var block = table.block(named: name) else { return }
            var def = block.dynamic ?? DynamicBlockDef()
            guard def.visibilityState(named: stateName) == nil else { return }
            let state = BlockVisibilityState(name: stateName)
            def.visibilityStates.append(state)
            block.dynamic = def
            table.upsert(block)
            created = state.id
        }
        return created
    }

    /// Adds (`visible == true`) or removes (`false`) a member id from a block's
    /// named visibility state's visible set. Undoable. No-op (no undo) if the block,
    /// its dynamic bundle, or the named state is absent, or the change is redundant
    /// (already present / already absent).
    public func setMemberVisibility(block name: String, state stateName: String,
                                    memberID: EntityID, visible: Bool) {
        mutateBlocks { table in
            guard var block = table.block(named: name), var def = block.dynamic,
                  let idx = def.visibilityStates.firstIndex(where: { $0.name == stateName })
            else { return }
            var state = def.visibilityStates[idx]
            let contained = state.visibleMemberIDs.contains(memberID)
            guard contained != visible else { return } // redundant → no-op, no undo
            if visible { state.visibleMemberIDs.insert(memberID) }
            else { state.visibleMemberIDs.remove(memberID) }
            def.visibilityStates[idx] = state
            block.dynamic = def
            table.upsert(block)
        }
    }

    /// Removes a block's named visibility state. Undoable. No-op (no undo) if the
    /// block, its dynamic bundle, or the named state is absent.
    public func removeVisibilityState(block name: String, named stateName: String) {
        mutateBlocks { table in
            guard var block = table.block(named: name), var def = block.dynamic,
                  let idx = def.visibilityStates.firstIndex(where: { $0.name == stateName })
            else { return }
            def.visibilityStates.remove(at: idx)
            block.dynamic = def
            table.upsert(block)
        }
    }

    // MARK: - Dynamic-block PARAMETER + ACTION authoring (DB-2; undoable via mutateBlocks)
    //
    // Block-DEFINITION authoring of the DB-2 linear/flip parameters + stretch/flip
    // actions. Per-INSTANCE state (`parameterValues`/`flipStates`) is NOT written
    // here — the wire-wave drives it through the entity-edit funnel by replacing the
    // `.insert` record's `InsertData.dynamic` (which is reachable: see the additive
    // `InsertData.dynamic` field). These mutators only touch the `Block.dynamic`
    // definition bundle, routed through the same `mutateBlocks` value-snapshot funnel
    // as the visibility mutators — one ⌘Z reverts each.

    /// Adds a LINEAR parameter (§5.2.2) to a block, creating its dynamic bundle if
    /// absent. The parameter's base distance is `|end - base|` and its direction is
    /// `(end - base)`. Undoable. No-op (no undo) if the block is unknown or already
    /// has a parameter with this id (ids are the per-instance value key, so they must
    /// be unique within a block). Returns `true` if added.
    @discardableResult
    public func addLinearParameter(toBlock name: String, id: BlockParameterID,
                                   label: String, base: Vector, end: Vector) -> Bool {
        addParameter(toBlock: name,
                     .linear(id: id, label: label, base: base, end: end))
    }

    /// Adds a FLIP parameter (§5.2.7) to a block, creating its dynamic bundle if
    /// absent. `lineStart`→`lineEnd` is the reflection line a flip action mirrors
    /// across. Undoable. No-op if the block is unknown or already has a parameter with
    /// this id. Returns `true` if added.
    @discardableResult
    public func addFlipParameter(toBlock name: String, id: BlockParameterID,
                                 label: String, lineStart: Vector, lineEnd: Vector) -> Bool {
        addParameter(toBlock: name,
                     .flip(id: id, label: label, lineStart: lineStart, lineEnd: lineEnd))
    }

    /// Shared parameter-append funnel: appends `param` to the block's dynamic bundle
    /// unless its id is already present. Returns `true` if added.
    @discardableResult
    private func addParameter(toBlock name: String, _ param: BlockParameter) -> Bool {
        var added = false
        mutateBlocks { table in
            guard var block = table.block(named: name) else { return }
            var def = block.dynamic ?? DynamicBlockDef()
            guard def.parameter(param.id) == nil else { return }
            def.parameters.append(param)
            block.dynamic = def
            table.upsert(block)
            added = true
        }
        return added
    }

    /// Adds a STRETCH action (§6.2.3) to a block, associated with `parameterID` (a
    /// linear parameter) and transforming `memberIDs` whose defining points fall
    /// inside `frame`. `distanceMultiplier`/`angleOffset` are the §13.4 overrides
    /// (defaults 1 / 0). Undoable. No-op if the block is unknown or already has an
    /// action with this id. Returns `true` if added.
    @discardableResult
    public func addStretchAction(toBlock name: String, id: BlockActionID,
                                 parameterID: BlockParameterID, frame: AABB,
                                 memberIDs: Set<EntityID>,
                                 distanceMultiplier: Double = 1,
                                 angleOffset: Double = 0) -> Bool {
        addAction(toBlock: name,
                  .stretch(id: id, parameterID: parameterID, stretchFrame: frame,
                           memberIDs: memberIDs,
                           distanceMultiplier: distanceMultiplier,
                           angleOffset: angleOffset))
    }

    /// Adds a FLIP action (§6.2.6) to a block, associated with `parameterID` (a flip
    /// parameter) and mirroring `memberIDs` when the instance flip state is `true`.
    /// Undoable. No-op if the block is unknown or already has an action with this id.
    /// Returns `true` if added.
    @discardableResult
    public func addFlipAction(toBlock name: String, id: BlockActionID,
                              parameterID: BlockParameterID,
                              memberIDs: Set<EntityID>) -> Bool {
        addAction(toBlock: name,
                  .flip(id: id, parameterID: parameterID, memberIDs: memberIDs))
    }

    /// Shared action-append funnel: appends `action` to the block's dynamic bundle
    /// unless its id is already present. Returns `true` if added.
    @discardableResult
    private func addAction(toBlock name: String, _ action: BlockAction) -> Bool {
        var added = false
        mutateBlocks { table in
            guard var block = table.block(named: name) else { return }
            var def = block.dynamic ?? DynamicBlockDef()
            guard !def.actions.contains(where: { $0.id == action.id }) else { return }
            def.actions.append(action)
            block.dynamic = def
            table.upsert(block)
            added = true
        }
        return added
    }

    /// Removes the parameter with `id` from a block's dynamic bundle. Undoable.
    /// No-op (no undo) if the block, its dynamic bundle, or the parameter is absent.
    /// NOTE: actions still referencing the removed parameter become inert (the
    /// evaluator treats a missing parameter as a no-op) rather than being cascaded —
    /// the wire-wave/authoring UI prunes orphaned actions explicitly.
    public func removeParameter(fromBlock name: String, id: BlockParameterID) {
        mutateBlocks { table in
            guard var block = table.block(named: name), var def = block.dynamic,
                  let idx = def.parameters.firstIndex(where: { $0.id == id })
            else { return }
            def.parameters.remove(at: idx)
            block.dynamic = def
            table.upsert(block)
        }
    }

    /// Removes the action with `id` from a block's dynamic bundle. Undoable. No-op
    /// (no undo) if the block, its dynamic bundle, or the action is absent.
    public func removeAction(fromBlock name: String, id: BlockActionID) {
        mutateBlocks { table in
            guard var block = table.block(named: name), var def = block.dynamic,
                  let idx = def.actions.firstIndex(where: { $0.id == id })
            else { return }
            def.actions.remove(at: idx)
            block.dynamic = def
            table.upsert(block)
        }
    }

    // MARK: - Block attributes (ATTDEF defs + ATTRIB values; undoable)
    //
    // Block ATTRIBUTES are split across two stores, mirroring DXF: a block declares
    // ATTDEF *templates* (`Block.attributeDefs` — tag/prompt/default/placement) and
    // every `INSERT` of that block carries one ATTRIB *value* per tag
    // (`InsertData.attributes`). The MODEL + resolve + DXF round-trip already exist;
    // these are the undoable EDIT ops that were missing:
    //   • set/replace an insert's ATTRIB value (EATTEDIT core) — entity-replace funnel.
    //   • CRUD a block's ATTDEF defs (BATTMAN/Define-Attribute) — `mutateBlocks` funnel.
    //   • reconcile every insert to a block's defs (ATTSYNC) — one undo group.
    // Each routes through the SAME value-snapshot undo funnels every other edit uses,
    // so each is exactly one ⌘Z and a genuine no-op registers nothing.

    /// Sets (or appends) the ATTRIB **value** for `tag` on the `.insert` entity `id`
    /// (the EATTEDIT core — the value editor a user types into in the Inspector).
    /// Undoable via the entity-replace funnel (one ⌘Z reverts).
    ///
    /// Behavior:
    ///   - No-op (no undo) if `id` is absent or not an `.insert`.
    ///   - If the insert already has an ATTRIB with this `tag` (case-insensitive,
    ///     matching the DXF round-trip's tag comparison), its `text` is replaced in
    ///     place (position/height/rotation/flags preserved).
    ///   - Otherwise a new `BlockAttributeValue` is APPENDED, seeded from the block's
    ///     matching `attributeDef` (so it inherits the def's placement/height/rotation/
    ///     flags); if the block declares no such def, a plain value at the origin is
    ///     appended so the edit is never silently dropped.
    ///   - A genuine no-op (the value already equals `text` for an existing tag)
    ///     registers nothing (the entity-replace funnel skips an unchanged record).
    public func setInsertAttributeValue(insertID id: EntityID, tag: String, text: String) {
        guard let record = entity(id), case .insert(var data) = record.kind else { return }

        if let idx = data.attributes.firstIndex(where: {
            $0.tag.caseInsensitiveCompare(tag) == .orderedSame
        }) {
            guard data.attributes[idx].text != text else { return }  // no-op
            data.attributes[idx].text = text
        } else {
            // New value — seed placement/height/rotation/flags from the block's def
            // (so an authored ATTDEF lands where it was designed), else a plain value.
            let def = blocks.block(named: data.blockName)?.attributeDefs.first {
                $0.tag.caseInsensitiveCompare(tag) == .orderedSame
            }
            let value = BlockAttributeValue(
                tag: def?.tag ?? tag,
                text: text,
                position: def?.position ?? Vector(0, 0),
                height: def?.height ?? 2.5,
                rotation: def?.rotation ?? 0,
                flags: def?.flags ?? 0)
            data.attributes.append(value)
        }

        var updated = record
        updated.kind = .insert(data)
        replace(updated)
    }

    /// Adds a new ATTDEF **definition** to a block (the Define-Attribute authoring op).
    /// Undoable via `mutateBlocks`. No-op (no undo) if the block is unknown or already
    /// declares a def with this tag (case-insensitive — ATTDEF tags are unique within a
    /// block). Returns `true` if added.
    @discardableResult
    public func addBlockAttributeDef(block name: String, _ def: BlockAttributeDef) -> Bool {
        var added = false
        mutateBlocks { table in
            guard var block = table.block(named: name) else { return }
            guard !block.attributeDefs.contains(where: {
                $0.tag.caseInsensitiveCompare(def.tag) == .orderedSame
            }) else { return }
            block.attributeDefs.append(def)
            table.upsert(block)
            added = true
        }
        return added
    }

    /// Updates an existing ATTDEF **definition** on a block, matched by `def.tag`
    /// (case-insensitive). Undoable via `mutateBlocks`. No-op (no undo) if the block is
    /// unknown, no def with that tag exists, or the def is unchanged. Returns `true` if
    /// updated. (To rename a tag, remove the old + add the new.)
    @discardableResult
    public func updateBlockAttributeDef(block name: String, _ def: BlockAttributeDef) -> Bool {
        var updated = false
        mutateBlocks { table in
            guard var block = table.block(named: name),
                  let idx = block.attributeDefs.firstIndex(where: {
                      $0.tag.caseInsensitiveCompare(def.tag) == .orderedSame
                  }) else { return }
            guard block.attributeDefs[idx] != def else { return }   // no-op
            block.attributeDefs[idx] = def
            table.upsert(block)
            updated = true
        }
        return updated
    }

    /// Removes the ATTDEF **definition** with `tag` (case-insensitive) from a block.
    /// Undoable via `mutateBlocks`. No-op (no undo) if the block is unknown or has no
    /// def with that tag. (Existing inserts keep their ATTRIB values until `syncBlockAttributes`.)
    public func removeBlockAttributeDef(block name: String, tag: String) {
        mutateBlocks { table in
            guard var block = table.block(named: name) else { return }
            let before = block.attributeDefs.count
            block.attributeDefs.removeAll { $0.tag.caseInsensitiveCompare(tag) == .orderedSame }
            guard block.attributeDefs.count != before else { return }   // no-op
            table.upsert(block)
        }
    }

    /// Reconciles every `.insert` of `name` to that block's current `attributeDefs`
    /// (the ATTSYNC op). For each insert of the block:
    ///   - tags present in the defs but MISSING on the insert are added with the def's
    ///     default text + the def's placement/height/rotation/flags,
    ///   - tags on the insert that are NO LONGER defined are dropped,
    ///   - tags present in both keep their existing VALUE (the user's typed text), but
    ///     adopt the def's placement/height/rotation/flags (so a def-edit propagates),
    ///   - the reconciled list is ORDERED to match the defs' order.
    /// Undoable as ONE group: every changed insert is one entity-replace, all of which
    /// reverse together within a single undo grouping (the UndoManager groups the calls
    /// made in one turn, exactly like `makeBlockFromEntities`). Unchanged inserts are
    /// not touched (the entity-replace funnel skips identical records), so a sync that
    /// changes nothing registers no undo.
    public func syncBlockAttributes(block name: String) {
        guard let block = blocks.block(named: name) else { return }
        let defs = block.attributeDefs

        // Snapshot the matching insert ids first (we mutate records as we go).
        let insertIDs: [EntityID] = entities.compactMap { rec in
            guard case .insert(let d) = rec.kind,
                  d.blockName.caseInsensitiveCompare(name) == .orderedSame else { return nil }
            return rec.id
        }

        for id in insertIDs {
            guard let record = entity(id), case .insert(var data) = record.kind else { continue }

            // Build the reconciled, def-ordered attribute list, preserving each tag's
            // existing value where it matches a def.
            var reconciled: [BlockAttributeValue] = []
            reconciled.reserveCapacity(defs.count)
            for def in defs {
                let existing = data.attributes.first {
                    $0.tag.caseInsensitiveCompare(def.tag) == .orderedSame
                }
                reconciled.append(BlockAttributeValue(
                    tag: def.tag,
                    text: existing?.text ?? def.defaultText,
                    position: def.position,
                    height: def.height,
                    rotation: def.rotation,
                    flags: def.flags))
            }

            guard data.attributes != reconciled else { continue }   // unchanged insert
            data.attributes = reconciled
            var updated = record
            updated.kind = .insert(data)
            replace(updated)
        }
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

    // MARK: - Layout mutations (value-snapshot undo of the whole layout table)
    //
    // Paper-space P0 (paperspace-plan §2). The layout table mirrors the block table:
    // a whole-array value-snapshot undo funnel (`mutateLayouts`) plus name-unique,
    // ordered add/remove/rename helpers. Model space stays IMPLICIT — it is NEVER a
    // `Layout` entry. Lookup + uniqueness are case-insensitive (AutoCAD LAYOUT names
    // are case-insensitive); the array is kept sorted by `tabOrder` so the (later)
    // tab strip reads it in order directly.

    /// The layout with `name` (case-insensitive), or `nil`.
    public func layout(named name: String) -> Layout? {
        layouts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether a layout with `name` (case-insensitive) is present.
    public func hasLayout(_ name: String) -> Bool { layout(named: name) != nil }

    /// Whole-table layout mutation with undo (the same value-snapshot scheme as
    /// `mutateBlocks`; `[Layout]` is a value type, so the undo snapshot is one array
    /// copy, ADR-002). The body mutates the layout array; afterwards it is re-sorted
    /// by `tabOrder` (stable on ties) so the table is always ordered. No-op edits
    /// (the array unchanged after sorting) don't pollute undo.
    public func mutateLayouts(_ body: (inout [Layout]) -> Void) {
        let prior = layouts
        var working = layouts
        body(&working)
        working.sort { $0.tabOrder < $1.tabOrder }   // keep ordered by tab position
        guard working != prior else { return }
        layouts = working
        registerUndo { drawing in
            drawing.mutateLayouts { $0 = prior }
        }
    }

    /// Adds a layout (no-op + no undo if the name is taken, case-insensitive).
    /// Returns `true` if added. Mirrors `addBlock`.
    @discardableResult
    public func addLayout(_ layout: Layout) -> Bool {
        guard !hasLayout(layout.name) else { return false }
        mutateLayouts { $0.append(layout) }
        return true
    }

    /// Removes a layout by name (case-insensitive). Entities still tagged for the
    /// removed sheet are LEFT as-is (their `layoutName` simply no longer resolves —
    /// the table never silently rewrites entity records); a higher layer decides
    /// whether to delete or re-home them. No-op (no undo) if absent. Returns `true`
    /// if a layout was removed.
    @discardableResult
    public func removeLayout(name: String) -> Bool {
        guard hasLayout(name) else { return false }
        mutateLayouts {
            $0.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        return true
    }

    /// Renames a layout (case-insensitive match on the old name). Re-points every
    /// paper-space entity whose `layoutName` matches `from` to `to` (each an
    /// undoable `replace`, in the same undo group) so the entities keep their sheet.
    /// No-op (returns `false`) if `from` is absent or `to` is already taken (and is
    /// not just a case-change of `from`). Returns `true` on success.
    @discardableResult
    public func renameLayout(from oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, hasLayout(oldName) else { return false }
        let isCaseChange = trimmed.caseInsensitiveCompare(oldName) == .orderedSame
        guard isCaseChange || !hasLayout(trimmed) else { return false }
        // Re-point referencing paper-space entities first (each undoable), then the
        // layout record itself — so the whole rename reverses as one undo group.
        for e in entities where e.layoutName?.caseInsensitiveCompare(oldName) == .orderedSame {
            var moved = e
            moved.layoutName = trimmed
            replace(moved)
        }
        mutateLayouts {
            if let i = $0.firstIndex(where: {
                $0.name.caseInsensitiveCompare(oldName) == .orderedSame
            }) {
                $0[i].name = trimmed
            }
        }
        return true
    }

    /// Duplicates the layout named `name` (case-insensitive) into a fresh, fully
    /// INDEPENDENT sheet — backlog #4c's "Duplicate" layout op. The copy gets:
    ///
    ///  • a unique name derived as `"<name> (2)"`, bumping the suffix (`(3)`, `(4)`,
    ///    …) until it does not clash (case-insensitively) with an existing layout;
    ///  • `tabOrder = (max existing tabOrder) + 1` so it lands at the end of the strip;
    ///  • a deep copy of the source layout's `page` AND its `viewports` (both pure
    ///    value types, so the `Layout` value copy carries them by value);
    ///  • its OWN copy of every paper-space entity painted on the source sheet
    ///    (`space == .paper`, `layoutName == name`), re-tagged with the new layout
    ///    name and given freshly-minted ids — so the duplicate owns independent
    ///    geometry, exactly like the source (not a shared/aliased reference).
    ///
    /// The whole operation is ONE undo group: every entity `add` plus the single
    /// `mutateLayouts` register their undo within the same user action, so one ⌘Z
    /// reverts the entire duplicate (the new sheet AND its copied geometry), matching
    /// `renameLayout`'s multi-registration pattern. No-op (returns `false`) if `name`
    /// does not name a layout.
    @discardableResult
    public func duplicateLayout(name: String) -> Bool {
        guard let source = layout(named: name) else { return false }

        // A unique "<name> (N)" — bump N until it doesn't clash (case-insensitive).
        var copyIndex = 2
        var newName = "\(source.name) (\(copyIndex))"
        while hasLayout(newName) {
            copyIndex += 1
            newName = "\(source.name) (\(copyIndex))"
        }

        // Land at the end of the tab strip: max existing tabOrder + 1.
        let newTabOrder = (layouts.map(\.tabOrder).max() ?? source.tabOrder) + 1

        // Re-tag a COPY of every paper-space entity on the source sheet to the new
        // layout (fresh ids via `add`) so the duplicate owns independent geometry.
        // Done first (each undoable) so they reverse together with the layout add.
        for e in entities where e.space == .paper
            && e.layoutName?.caseInsensitiveCompare(source.name) == .orderedSame {
            var copy = e
            copy.id = .placeholder      // mint a fresh id in `add` (independent record)
            copy.layoutName = newName
            _ = add(copy)
        }

        // The new sheet: a deep copy of the source value (page + viewports ride along
        // by value) under the unique name + end-of-strip tab position.
        var duplicate = source
        duplicate.name = newName
        duplicate.tabOrder = newTabOrder
        mutateLayouts { $0.append(duplicate) }
        return true
    }

    /// Replaces the `page` descriptor of the layout named `name` (case-insensitive)
    /// with `page` — backlog #4c's per-layout "Page Setup" engine op. Routed through
    /// `mutateLayouts`, so it is one undoable value-snapshot step (one ⌘Z restores the
    /// prior page). No-op (returns `false`, no undo) if `name` is absent or the page
    /// is already equal (the funnel's no-op guard). Returns `true` if the page changed.
    @discardableResult
    public func setLayoutPage(name: String, _ page: PageDescriptor) -> Bool {
        guard let current = layout(named: name), current.page != page else { return false }
        mutateLayouts {
            if let i = $0.firstIndex(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                $0[i].page = page
            }
        }
        return true
    }

    // MARK: - Viewport mutations (paper-space P3 — undoable via the layout funnel)
    //
    // Paper-space viewports (paperspace-plan §3 row P3) live in `Layout.viewports`
    // (a per-layout list, NOT an `EntityKind` case). Because they ride inside the
    // `Layout` value, every viewport edit routes through `mutateLayouts` and so
    // inherits the layout table's value-snapshot undo for FREE: one ⌘Z reverts a
    // viewport add/remove/update, and rename-/remove-layout keep working (the
    // viewports travel with the `Layout` value). Lookup of the host layout is
    // case-insensitive (matching the engine's case-insensitive LAYOUT names).

    /// Adds `viewport` to the named layout (case-insensitive). No-op (no undo) if no
    /// such layout exists. Undoable (one ⌘Z removes it). Returns `true` if added.
    @discardableResult
    public func addViewport(_ viewport: LayoutViewport, toLayout layoutName: String) -> Bool {
        guard hasLayout(layoutName) else { return false }
        var added = false
        mutateLayouts {
            if let i = $0.firstIndex(where: {
                $0.name.caseInsensitiveCompare(layoutName) == .orderedSame
            }) {
                $0[i].viewports.append(viewport)
                added = true
            }
        }
        return added
    }

    /// Removes the viewport with `id` from the named layout (case-insensitive). No-op
    /// (no undo) if the layout or the viewport is absent. Undoable. Returns `true` if
    /// a viewport was removed.
    @discardableResult
    public func removeViewport(id: UUID, fromLayout layoutName: String) -> Bool {
        guard hasLayout(layoutName) else { return false }
        var removed = false
        mutateLayouts {
            if let i = $0.firstIndex(where: {
                $0.name.caseInsensitiveCompare(layoutName) == .orderedSame
            }) {
                let before = $0[i].viewports.count
                $0[i].viewports.removeAll { $0.id == id }
                removed = $0[i].viewports.count != before
            }
        }
        return removed
    }

    /// Replaces the viewport with the same `id` in the named layout (case-
    /// insensitive) with `viewport` (an in-place edit — move/reframe/rescale). No-op
    /// (no undo) if the layout or a viewport with that id is absent. Undoable.
    /// Returns `true` if a viewport was updated.
    @discardableResult
    public func updateViewport(_ viewport: LayoutViewport, inLayout layoutName: String) -> Bool {
        guard hasLayout(layoutName) else { return false }
        var updated = false
        mutateLayouts {
            if let i = $0.firstIndex(where: {
                $0.name.caseInsensitiveCompare(layoutName) == .orderedSame
            }),
               let j = $0[i].viewports.firstIndex(where: { $0.id == viewport.id }) {
                $0[i].viewports[j] = viewport
                updated = true
            }
        }
        return updated
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
        dimStyles newDimStyles: DimStyleTable = DimStyleTable(),
        layouts newLayouts: [Layout] = []
    ) {
        entities = newEntities
        layers = newLayers
        blocks = newBlocks
        graphicVariables = newVariables
        dimStyles = newDimStyles
        // Carry the paper-space layout table (paperspace-plan P0), kept ordered by
        // tab position — symmetric to the block/dim-style tables. Defaults empty so
        // existing callers (and a model-space-only drawing) are unchanged.
        layouts = newLayouts.sorted { $0.tabOrder < $1.tabOrder }
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
        // Snapshot the drawing-wide LINETYPE SCALE ($LTSCALE) so the resolve hook
        // multiplies it onto every entity's per-entity dash scale (DXF code 48) →
        // ResolvedPen.linetypeScale (the renderer scales the dash period by it).
        let docLinetypeScale = graphicVariables.linetypeScale
        // Snapshot the block table → member records map (value copies) so an
        // `.insert` can resolve a referenced block's geometry. Building the
        // name→[EntityRecord] map once here keeps the per-insert lookup O(1) and
        // the closure `@Sendable` (it captures only value types, no `self`).
        let blockMembers = blockMembersSnapshot()
        // Snapshot the block table → DYNAMIC-bundle map (value copies) so an
        // `.insert` can evaluate its block's visibility states (dynamic-blocks-plan
        // §3). Only blocks that actually carry a dynamic bundle appear; a plain
        // block has no entry and `BlockEvaluator.evaluate(nil, …)` returns its
        // members unchanged. `DynamicBlockDef` is a value type, so the closure stays
        // `@Sendable` (captures values, no `self`).
        let blockDynamics = blockDynamicSnapshot()
        return ResolveContext(
            tessellationTolerance: tessellationTolerance,
            layerAttributes: { layerID in
                table.layer(layerID)?.resolvedPen
                    ?? ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
            },
            fontProvider: CADFonts.provider,
            textStyleProvider: { name in styleTable.style(named: name) },
            annotationScale: annotationScale,
            globalLinetypeScale: docLinetypeScale,
            dimStyleProvider: { docDimStyle },
            namedDimStyleProvider: { name in dimStyleTable.style(named: name)?.style },
            pointStyleProvider: { (mode: docPointMode, size: docPointSize) },
            blockProvider: { name in blockMembers[name] },
            blockDynamic: { name in blockDynamics[name] }
        )
    }

    /// The union of EVERY block definition's `entityIDs` — the single source-of-truth
    /// "is this entity a block member?" predicate for the model-space consumers.
    ///
    /// A block member is geometry the block OWNS (it draws only via an `.insert` of the
    /// block, or while its block is open in the Block Editor) — it must NOT be treated
    /// as loose top-level model-space geometry. Without this exclusion, members
    /// (`space == .model`, `.visible`, referenced by some `Block.entityIDs`) get picked
    /// up by render, selection, marquee, hit-test, ⌘A / Invert, and snap — and drawn
    /// TWICE (directly AND via the insert).
    ///
    /// FROZEN blocks are included too: a frozen block's members are still owned by the
    /// block (just not currently drawn) — they are not loose geometry either, so
    /// excluding them keeps the membership truth stable across freeze/thaw.
    ///
    /// Computed inline over the (few) block definitions; cheap enough to recompute on
    /// demand (blocks are sparse relative to entities). The model-space consumers
    /// (`activeSpaceEntities`, the render pack, `SelectionPolicy`) subtract this set so
    /// every membership decision keys off ONE truth.
    public var blockMemberIDs: Set<EntityID> {
        var ids = Set<EntityID>()
        for block in blocks.blocks {
            ids.formUnion(block.entityIDs)
        }
        return ids
    }

    /// Builds a `blockName → DynamicBlockDef` snapshot (value copies) from the block
    /// table — only the blocks that carry a dynamic bundle (`Block.dynamic != nil`).
    /// Backs the resolve context's `blockDynamic` so an `.insert` can evaluate its
    /// block's visibility states. A plain block has no entry (the evaluator returns
    /// its members unchanged). Returns an empty map when no block is dynamic.
    func blockDynamicSnapshot() -> [String: DynamicBlockDef] {
        var map: [String: DynamicBlockDef] = [:]
        for block in blocks.blocks {
            if let dyn = block.dynamic { map[block.name] = dyn }
        }
        return map
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
