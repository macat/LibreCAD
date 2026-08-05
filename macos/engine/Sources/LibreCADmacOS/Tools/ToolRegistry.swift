//
//  ToolRegistry.swift
//  LibreCADmacOS — Wave 7: app-side ToolRegistry DI wrapper
//
//  The app's DI seam for the engine `ToolRegistry`. The engine owns the
//  factory map (`CADEngine.ToolRegistry` — registration not switch); this file
//  re-exports it into the app module and adds the app-specific palette wiring
//  so `CommandPalette`/`ToolOptionsBar` can take a `ToolRegistry` via DI
//  without importing engine internals directly. `CADEngine` remains ⊥
//  `LibreCADmacOS` (engine never imports app; app imports engine).
//
//  The app's registry IS the engine's `shared` by default (same factories,
//  same roster). A custom registry can be built (`ToolRegistry()`) and injected
//  into `CommandRegistry.commands(_:registry:)` for tests or for UNWIRED
//  tools — no `ToolKind` case addition needed, just
//  `registry.register(.line) { MyCustomLineTool() }` and pass that registry to
//  the palette. This satisfies the “add a tool = register in one place”
//
//  contract: the palette iterates `registry.registeredKinds` (registration),
//  not a hard-coded `ToolKind` switch.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Foundation
import CADEngine

// MARK: - App palette helpers (Wave 7 — DI)

// The engine owns the factory map (`CADEngine.ToolRegistry` — registration not
// switch) and `ToolKind.makeTool()` delegates to it. `import CADEngine` already
// brings `ToolRegistry` + `ToolKind` into this module, so this file just adds
// the app-specific palette convenience. No re-definition (that would shadow the
// engine type and break `CommandRegistry.commands(_:registry:)`).

extension ToolRegistry {
    /// The palette entries this registry drives: one per registered kind,
    /// sorted by `rawValue` (canonical `allCases` order). Lets the palette do
    /// `for kind in registry.paletteKinds` instead of `allCases` + switch.
    public var paletteKinds: [ToolKind] { registeredKinds }
}
