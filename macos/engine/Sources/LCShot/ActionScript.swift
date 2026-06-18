//
//  ActionScript.swift
//  LCShot
//
//  The JSON action DSL the harness interprets. A scene file is a JSON object with an
//  optional header (space / layout / dpi / background) and an `actions` array; each
//  action maps to a VERIFIED `CanvasModel` method. The runner drives a headless
//  `CanvasModel` action-by-action and ends by rendering a PNG (an explicit `render`
//  action, or an implicit final render if none was given).
//
//  ## Allow-list (land-blocking safety)
//  Only the verbs in `ActionOp` are accepted. Any tool / verb that would need an
//  `NSOpenPanel` / `NSSavePanel` / sheet or out-of-band file config (image-insert,
//  create-block, table, file-open, print) is EXCLUDED — a modal reached from this
//  headless path HANGS FOREVER. An unknown / excluded verb prints an error and the
//  process EXITS NON-ZERO (it never hangs and never silently no-ops).
//
//  Bool-returning model methods (selection, constraints, parameters) are SURFACED:
//  a `false` return prints a "no-op" / "unsupported" line so a silent failure is
//  visible in the harness log rather than a mysteriously empty PNG.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics
import CADEngine

// MARK: - Scene header

/// A decoded scene: the optional header + the ordered action list.
struct ActionScene {
    var space: String?          // "model" | "paper" (default model)
    var layout: String?         // the paper layout name to activate/render
    var dpi: Double?            // default 150
    var background: String?     // "#RRGGBB" (default = CAD canvas dark bg)
    var actions: [ActionStep]

    // MARK: Decoding (hand-rolled over JSONSerialization so each action object can
    // carry verb-specific keys without a giant Codable enum).

    static func decode(_ data: Data) throws -> ActionScene {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw LCShotError(message: "scene root must be a JSON object")
        }
        guard let rawActions = root["actions"] as? [Any] else {
            throw LCShotError(message: "scene must have an 'actions' array")
        }
        var steps: [ActionStep] = []
        for (i, raw) in rawActions.enumerated() {
            guard let dict = raw as? [String: Any] else {
                throw LCShotError(message: "action #\(i) must be an object")
            }
            guard let op = dict["op"] as? String else {
                throw LCShotError(message: "action #\(i) is missing an 'op' string")
            }
            steps.append(ActionStep(op: op, fields: dict))
        }
        return ActionScene(space: root["space"] as? String,
                           layout: root["layout"] as? String,
                           dpi: (root["dpi"] as? NSNumber)?.doubleValue,
                           background: root["background"] as? String,
                           actions: steps)
    }
}

/// One raw action object: the verb plus its parameter dictionary.
struct ActionStep {
    let op: String
    let fields: [String: Any]
}

// MARK: - Execution

extension ActionScene {

    /// Drive a fresh headless `CanvasModel` through every action, then render the
    /// PNG. `sourcePath` is used to derive the default output path (alongside the
    /// scene); `outOverride` (CLI arg 2) wins when present.
    @MainActor
    static func execute(_ scene: ActionScene,
                        sourcePath: String,
                        outOverride: String?) throws {
        let model = CanvasModel(drawing: CADDrawing(),
                                viewSize: CGSize(width: 1000, height: 750))

        // The header's `space`/`layout` only pre-selects MODEL space (a fresh model
        // is already in model space, so this is effectively a no-op kept for clarity).
        // A `space:"paper"` header is deliberately NOT honored here: the layout does
        // not exist yet at header time (it is created by an `addLayout` action), so a
        // pre-action paper switch would silently degrade to model space. Scenes switch
        // INTO paper space via the `addLayout` + `layout`/`space` ACTIONS instead —
        // those run after the layout is created and are the correct, working path.
        if scene.space == "model" || scene.space == nil {
            model.activateModel()
        }

        let dpi = scene.dpi ?? DrawingExporter.defaultRasterDPI
        let background = scene.background.flatMap(parseHexColor) ?? Capture.canvasBackground

        var rendered = false
        let defaultOut = outOverride
            ?? URL(fileURLWithPath: sourcePath)
                .deletingPathExtension()
                .appendingPathExtension("png").path

        for (i, step) in scene.actions.enumerated() {
            if step.op == "render" {
                let out = (step.fields["path"] as? String) ?? defaultOut
                let doAssert = (step.fields["assert"] as? Bool) ?? false
                try Capture.render(model: model, to: out, dpi: dpi,
                                   background: background, writeAssert: doAssert)
                print("LCShot: rendered action #\(i) -> \(out)")
                rendered = true
            } else {
                try apply(step, index: i, to: model)
            }
        }

        // If the scene never asked to render, render once at the end to the default
        // path (so a header-only / no-render scene still produces a screenshot).
        if !rendered {
            try Capture.render(model: model, to: defaultOut, dpi: dpi,
                               background: background, writeAssert: false)
            print("LCShot: implicit final render -> \(defaultOut)")
        }
    }

    // MARK: - One action → one verified CanvasModel call

    @MainActor
    private static func apply(_ step: ActionStep, index i: Int, to model: CanvasModel) throws {
        let op = step.op
        func req<T>(_ key: String, _ cast: (Any?) -> T?) throws -> T {
            guard let v = cast(step.fields[key]) else {
                throw LCShotError(message: "action #\(i) '\(op)': missing/invalid '\(key)'")
            }
            return v
        }

        switch op {

        // MARK: geometry helpers (direct entity add — no tool/modal needed)
        // An optional "space":"paper" + "layout":"<name>" places the entity in a
        // paper layout (the layout must already exist — create it with `addLayout`),
        // so a layout-switch scene can put distinct geometry on the sheet.
        case "addLine":
            let a = try req("from", vector)
            let b = try req("to", vector)
            model.drawing.add(EntityRecord(id: EntityID(0),
                kind: .line(LineData(start: a, end: b)),
                space: entitySpace(step), layoutName: step.fields["layout"] as? String))
        case "addCircle":
            let c = try req("center", vector)
            let r = try req("radius", number)
            model.drawing.add(EntityRecord(id: EntityID(0),
                kind: .circle(CircleData(center: c, radius: r)),
                space: entitySpace(step), layoutName: step.fields["layout"] as? String))

        case "addLayout":
            // Create a paper-space layout (pure value; no modal). No-op if it exists.
            let name = try req("name", string)
            let order = number(step.fields["tabOrder"]).map { Int($0) } ?? 0
            let created = model.drawing.addLayout(Layout(name: name, tabOrder: order))
            print("LCShot: addLayout '\(name)' -> \(created ? "created" : "already exists")")

        // MARK: tools
        case "activateTool":
            let name = try req("tool", string)
            guard let kind = ToolKind(rawValue: name) else {
                throw LCShotError(message: "action #\(i): unknown tool '\(name)'")
            }
            try guardToolAllowed(kind, index: i)
            model.activateTool(kind)

        case "click":
            let p = try req("at", vector)
            model.handleToolInput(.click(p))
        case "value":
            let p = try req("at", vector)
            model.handleToolInput(.value(p))
        case "move":
            let p = try req("at", vector)
            model.handleToolMove(p)
        case "commit":
            model.handleToolInput(.commit)
        case "cancel":
            model.handleToolInput(.cancel)
        case "backspace":
            model.handleToolInput(.backspace)

        // MARK: selection (Bool surfaced)
        case "select":
            let ids = try req("ids", uint64Array).map { EntityID($0) }
            let changed = model.setSelection(Set(ids))
            print("LCShot: select \(ids.count) ids -> changed=\(changed)")
        case "selectAll":
            let changed = model.selectAll()
            print("LCShot: selectAll -> changed=\(changed), count=\(model.selection.ids.count)")

        // MARK: constraints (Bool surfaced; unsupported kinds printed honestly)
        case "constrain":
            let kindName = try req("kind", string)
            let ids = try req("ids", uint64Array).map { EntityID($0) }
            guard let kind = GeometricConstraintKind(rawValue: kindName) else {
                throw LCShotError(message: "action #\(i): unknown geometric constraint '\(kindName)'")
            }
            let ok = model.addConstraint(kind, entities: ids)
            if !ok {
                // No-op (unsupported kind / wrong arity). Exit stays 0; the `WARN:`
                // prefix lets a coordinator grep stdout for silent constraint no-ops.
                print("WARN: constraint '\(kindName)' returned false " +
                      "(unsupported by the solver, or wrong entity arity) — no-op")
            } else {
                print("LCShot: constraint '\(kindName)' applied to \(ids.count) entities")
            }
        case "dimConstrain":
            // Either a literal `value` (the value: overload) OR an `expr` that binds
            // the dimension to a named parameter (the expression: overload) — the
            // latter is how a parametric scene drives geometry from `param`/`cmd a=…`.
            let kindName = try req("kind", string)
            let ids = try req("ids", uint64Array).map { EntityID($0) }
            guard let kind = DimensionalConstraintKind(rawValue: kindName) else {
                throw LCShotError(message: "action #\(i): unknown dimensional constraint '\(kindName)'")
            }
            // A false return is a no-op (unsupported kind / wrong arity); exit stays 0
            // and the line is prefixed `WARN:` so a coordinator can grep for no-ops.
            if let expr = step.fields["expr"] as? String {
                let ok = model.addConstraint(kind, entities: ids, expression: expr)
                print("\(ok ? "LCShot" : "WARN"): dimConstrain '\(kindName)' expr=\(expr) -> \(ok ? "applied" : "false (unsupported / wrong arity) — no-op")")
            } else {
                let value = try req("value", number)
                let ok = model.addConstraint(kind, entities: ids, value: value)
                print("\(ok ? "LCShot" : "WARN"): dimConstrain '\(kindName)' value=\(value) -> \(ok ? "applied" : "false (unsupported / wrong arity) — no-op")")
            }

        // MARK: parameters
        case "param":
            let name = try req("name", string)
            let expr = try req("expr", string)
            let ok = model.setParameterExpression(name: name, expression: expr)
            print("LCShot: param \(name)=\(expr) -> \(ok ? "set" : "false")")
        case "cmd":
            let text = try req("text", string)
            let result = model.interpretCommandLine(text)
            // interpretCommandLine does NOT activate tools — it returns the request.
            if case .activateTool(let kind) = result {
                try guardToolAllowed(kind, index: i)
                model.activateTool(kind)
                print("LCShot: cmd '\(text)' -> activateTool(\(kind.rawValue))")
            } else {
                print("LCShot: cmd '\(text)' -> \(result)")
            }

        // MARK: space / layout
        case "model":
            model.activateModel()
        case "layout":
            let name = try req("name", string)
            model.activateLayout(name: name)
        case "space":
            let s = try req("space", string)
            switch s {
            case "model": model.setActiveSpace(.model)
            case "paper": model.setActiveSpace(.paper, layoutName: step.fields["layout"] as? String)
            default: throw LCShotError(message: "action #\(i): space must be 'model' or 'paper'")
            }

        case "zoomToFit":
            model.zoomToFit()

        // MARK: tool-config (set the published field, then re-push onto the tool)
        case "setOption":
            try applySetOption(step, index: i, to: model)

        default:
            throw LCShotError(
                message: "unknown or excluded action '\(op)' (action #\(i)). " +
                         "Allowed verbs: addLine, addCircle, addLayout, activateTool, " +
                         "click, value, move, commit, cancel, backspace, select, " +
                         "selectAll, constrain, dimConstrain, param, cmd, model, layout, " +
                         "space, zoomToFit, setOption, render. Verbs needing a file/" +
                         "open/save panel are deliberately excluded (they would hang " +
                         "the headless harness).",
                exitCode: 3)
        }
    }

    // MARK: - setOption

    @MainActor
    private static func applySetOption(_ step: ActionStep, index i: Int,
                                       to model: CanvasModel) throws {
        guard let field = step.fields["field"] as? String else {
            throw LCShotError(message: "action #\(i) 'setOption': missing 'field'")
        }
        switch field {
        case "mirrorKeepOriginal":
            guard let v = boolValue(step.fields["value"]) else {
                throw LCShotError(message: "action #\(i) setOption mirrorKeepOriginal: need a bool 'value'")
            }
            model.mirrorKeepOriginal = v
        case "currentHatchPattern":
            // A string pattern name, or null/"" for SOLID.
            if step.fields["value"] is NSNull {
                model.currentHatchPattern = nil
            } else if let s = step.fields["value"] as? String {
                model.currentHatchPattern = s.isEmpty ? nil : s
            } else {
                throw LCShotError(message: "action #\(i) setOption currentHatchPattern: need a string or null 'value'")
            }
        case "hatchPatternScale":
            guard let v = number(step.fields["value"]) else {
                throw LCShotError(message: "action #\(i) setOption hatchPatternScale: need a number 'value'")
            }
            model.hatchPatternScale = v
        default:
            throw LCShotError(
                message: "action #\(i) setOption: unsupported field '\(field)' " +
                         "(supported: mirrorKeepOriginal, currentHatchPattern, hatchPatternScale)",
                exitCode: 3)
        }
        // Re-push the model's option fields onto the (possibly already-active) tool.
        model.applyToolConfig()
        print("LCShot: setOption \(field) applied")
    }

    // MARK: - Tool allow-list

    /// Tools that need an NSOpenPanel / NSSavePanel / sheet or out-of-band file
    /// config — a modal from this headless path HANGS FOREVER, so they are refused.
    private static let excludedTools: Set<ToolKind> = {
        var s: Set<ToolKind> = []
        // Reference each by raw value so a renamed/removed case fails loudly at the
        // ToolKind(rawValue:) site rather than silently dropping an exclusion.
        // NOTE: block-insert's ToolKind case is `insert` (there is NO `insertBlock`).
        for raw in ["image", "createBlock", "insert", "table"] {
            if let k = ToolKind(rawValue: raw) { s.insert(k) }
        }
        return s
    }()

    private static func guardToolAllowed(_ kind: ToolKind, index i: Int) throws {
        if excludedTools.contains(kind) {
            throw LCShotError(
                message: "action #\(i): tool '\(kind.rawValue)' is EXCLUDED from the " +
                         "headless harness (it needs a file/open/save panel that would " +
                         "hang the process). Build that geometry via direct add verbs " +
                         "or a different tool.",
                exitCode: 3)
        }
    }

    // MARK: - Tiny typed accessors

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }
    private static func string(_ v: Any?) -> String? { v as? String }
    /// The `EntitySpace` a direct-add verb targets: `"space":"paper"` ⇒ `.paper`,
    /// anything else (incl. absent) ⇒ `.model`.
    private static func entitySpace(_ step: ActionStep) -> EntitySpace {
        (step.fields["space"] as? String) == "paper" ? .paper : .model
    }
    private static func boolValue(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }
    /// `[x, y]` (z optional) → Vector.
    private static func vector(_ v: Any?) -> Vector? {
        guard let arr = v as? [Any], arr.count >= 2,
              let x = number(arr[0]), let y = number(arr[1]) else { return nil }
        let z = arr.count >= 3 ? (number(arr[2]) ?? 0) : 0
        return Vector(x, y, z)
    }
    private static func uint64Array(_ v: Any?) -> [UInt64]? {
        guard let arr = v as? [Any] else { return nil }
        var out: [UInt64] = []
        for e in arr {
            if let n = e as? NSNumber { out.append(n.uint64Value) }
            else if let i = e as? Int, i >= 0 { out.append(UInt64(i)) }
            else { return nil }
        }
        return out
    }
}

// MARK: - Hex color

/// Parse `#RRGGBB` / `RRGGBB` into an opaque `RGBAColor` (alpha 1), or `nil` for
/// empty/malformed (so the caller keeps the canvas default). Mirrors the shape of
/// `CanvasTheme.rgba(fromAppHex:)`.
func parseHexColor(_ hex: String) -> RGBAColor? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return nil }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    return RGBAColor(Float((v >> 16) & 0xFF) / 255.0,
                     Float((v >> 8) & 0xFF) / 255.0,
                     Float(v & 0xFF) / 255.0,
                     1.0)
}
