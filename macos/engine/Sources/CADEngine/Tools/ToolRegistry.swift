//
//  ToolRegistry.swift
//  CADEngine — Wave 7: ToolRegistry DI (perf-arch-review-plan.md Wave 7)
//
//  The DI registry for tools. `ToolKind` stays the enum (the stable identity
//  shipped in files / shortcuts), but the *wiring* (which concrete `Tool`
//  value a kind mints) is registration not an exhaustive switch. Adding a tool
//  = register in one place (here, or a custom `ToolRegistry` instance injected
//  into the UI), not N switches across `ToolKind`/`CommandPalette`/`ToolCatalog`.
//
//  `ToolKind.makeTool()` delegates to `ToolRegistry.shared` (the default
//  registry seeded with every shipped kind). The UI (`CommandPalette`,
//  `ToolOptionsBar`) takes a `ToolRegistry` via DI (`registry: ToolRegistry =
//  .shared`) so tests can inject a stub registry without touching global state.
//  Build UNWIRED if you add a demo tool — register a factory for an existing
//  `ToolKind` with a different `Tool` (or a test double) rather than adding a
//  new `ToolKind` case.
//
//  Thread-safe: a private `NSLock` guards the factory map; `Sendable` is
//  `@unchecked` because the lock serializes mutation. Factories are
//  `@Sendable` so the registry can be shared across actors.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Foundation

/// A factory that mints a fresh `any Tool` value. `Sendable` so the registry
/// can be shared across isolation domains (engine actor + MainActor UI).
public typealias ToolFactory = @Sendable () -> any Tool

/// The DI registry for tools: `[ToolKind: ToolFactory]` + convenience helpers.
///
/// - The shared instance (`ToolRegistry.shared`) is seeded with the default
///   factories for every shipped `ToolKind` (the same mapping the old
///   `ToolKind.makeTool()` switch carried). `ToolKind.makeTool()` delegates to
///   it, so existing call sites keep working and adding a tool = register in
///   one place.
/// - UI wiring (`CommandPalette.commands(_:registry:)`) takes a
///   `ToolRegistry` parameter (default `.shared`) so the palette is driven by
///   registration, not an exhaustive `ToolKind.allCases` switch — a custom
///   registry can override or extend the roster without editing the palette.
/// - Tests can build a `ToolRegistry()` with a bespoke map and inject it,
///   proving the DI contract without touching `shared`.
public final class ToolRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var factories: [ToolKind: ToolFactory]

    /// Create an empty registry (no factories). Use `registerDefaults()` or
    /// `register(_:factory:)` to populate it. Tests use this to build a
    /// bespoke registry; production uses `shared`.
    public init() {
        self.factories = [:]
    }

    /// The process-wide shared registry, seeded with the default factories for
    /// every shipped `ToolKind`. `ToolKind.makeTool()` delegates to this.
    public static let shared: ToolRegistry = {
        let r = ToolRegistry()
        r.registerDefaults()
        return r
    }()

    // MARK: - Registration

    /// Register (or override) the factory for `kind`. Thread-safe.
    public func register(_ kind: ToolKind, factory: @escaping ToolFactory) {
        lock.lock()
        defer { lock.unlock() }
        factories[kind] = factory
    }

    /// Remove the factory for `kind` (used by tests to simulate an UNWIRED
    /// kind). Thread-safe.
    public func unregister(_ kind: ToolKind) {
        lock.lock()
        defer { lock.unlock() }
        factories.removeValue(forKey: kind)
    }

    // MARK: - Resolution

    /// Mint a fresh tool for `kind`, or `nil` if `kind` is out-of-band
    /// (`.select` / `.viewport`) or has no registered factory. Thread-safe.
    public func makeTool(for kind: ToolKind) -> (any Tool)? {
        lock.lock()
        let factory = factories[kind]
        lock.unlock()
        return factory?()
    }

    /// Whether `kind` has a registered factory. Thread-safe.
    public func isRegistered(_ kind: ToolKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return factories[kind] != nil
    }

    /// The kinds that have a factory in this registry, sorted by `rawValue`
    /// for stable UI order. Thread-safe. This is the DI roster the palette
    /// can iterate instead of `ToolKind.allCases`.
    public var registeredKinds: [ToolKind] {
        lock.lock()
        let kinds = Array(factories.keys)
        lock.unlock()
        return kinds.sorted { $0.rawValue < $1.rawValue }
    }

    /// Number of registered factories.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return factories.count
    }

    // MARK: - Defaults

    /// Seed this registry with the default factories for every shipped
    /// `ToolKind`. Idempotent: re-calling it re-registers the defaults
    /// (overriding any custom factories). Called once for `shared`.
    public func registerDefaults() {
        // Draw — geometry-creating
        register(.line)      { LineTool() }
        register(.circle)    { CircleTool() }
        register(.arc)       { ArcTool() }
        register(.rectangle) { RectangleTool() }
        register(.polyline)  { PolylineTool() }
        register(.point)     { PointTool() }
        register(.ellipse)   { EllipseTool() }
        register(.polygon)   { PolygonTool() }
        register(.spline)    { SplineTool() }
        register(.hatch)     { HatchTool() }
        register(.image)     { ImageTool() }
        register(.xline)     { XLineTool() }
        register(.ray)       { RayTool() }
        register(.insert)    { InsertTool() }
        // .viewport is out-of-band (no Tool) — not registered, like .select.
        register(.wipeout)   { WipeoutTool() }
        register(.mline)     { MLineTool() }
        register(.table)     { TableTool() }

        // Modify — act on selection
        register(.move)      { MoveTool() }
        register(.copy)      { CopyTool() }
        register(.rotate)    { RotateTool() }
        register(.scale)     { ScaleTool() }
        register(.mirror)    { MirrorTool() }
        register(.offset)    { OffsetTool() }
        register(.array)     { ArrayTool() }
        register(.arrayPath) { ArrayPathTool() }
        register(.divide)    { DivideTool() }
        register(.explode)   { ExplodeTool() }
        register(.stretch)   { StretchTool() }
        register(.lengthen)  { LengthenTool() }
        register(.break)     { BreakTool() }
        register(.trim)      { TrimTool() }
        register(.extend)    { ExtendTool() }
        register(.fillet)    { FilletTool() }
        register(.chamfer)   { ChamferTool() }
        register(.polylineEdit) { PolylineEditTool() }
        register(.join)      { JoinTool() }
        register(.explodeText) { ExplodeTextTool() }
        register(.align)     { AlignTool() }
        register(.createBlock) { CreateBlockTool() }
        register(.explodeInsert) { ExplodeInsertTool() }
        register(.lineConstruction) { LineConstructionTool() }

        // Annotate — text / dimensions / leaders / measure
        register(.text)        { TextTool() }
        register(.linearDim)   { LinearDimTool(orientation: .horizontal) }
        register(.alignedDim)  { AlignedDimTool() }
        register(.radialDim)   { RadialDimTool(mode: .radius) }
        register(.diameterDim) { RadialDimTool(mode: .diameter) }
        register(.angularDim)  { AngularDimTool() }
        register(.ordinateDim) { OrdinateDimTool() }
        register(.arcLengthDim) { ArcLengthDimTool() }
        register(.angular3pDim) { Angular3pDimTool() }
        register(.leader)      { LeaderTool() }
        register(.multileader) { MultiLeaderTool() }
        register(.baselineDim) { BaselineDimTool() }
        register(.continueDim) { ContinueDimTool() }
        register(.measureDistance) { MeasureTool(mode: .distance) }
        register(.measureAngle)    { MeasureTool(mode: .angle) }
        register(.measureArea)     { MeasureTool(mode: .areaPerimeter) }
        register(.measureLength)   { MeasureTool(mode: .totalLength) }
        register(.revcloud)    { RevisionCloudTool() }

        // Out-of-band kinds (.select, .viewport) are intentionally NOT
        // registered — `makeTool(for:)` returns nil for them, matching
        // `ToolKind.makeTool()`'s legacy contract.
    }
}
