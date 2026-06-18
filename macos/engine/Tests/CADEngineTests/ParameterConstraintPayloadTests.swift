//
//  ParameterConstraintPayloadTests.swift
//  CADEngineTests
//
//  Lane L3 — PARAMETERS + CONSTRAINTS persistence through the IN-SESSION document
//  payload (`DXFPayload`). `CADDrawing.constraints` / `.parameters` ride the live
//  model + undo, but were DROPPED on a `payloadSnapshot` → `make(from:)` round-trip,
//  so a constraint / parameter was LOST across a document snapshot/restore (undo,
//  autosave-via-payload). Lane L3 threads both tables through the payload, closing
//  that in-session gap. The document source is compiled into the test target via the
//  `_SharedLibreCADDocument.swift` symlink (the same zero-drift pattern the renderer /
//  document-state / table-payload tests use).
//
//  These tests pin four things:
//    1. The in-session payload threading: a PARAMETER and an EXPRESSION-BOUND
//       CONSTRAINT both survive `payloadSnapshot` ↔ `make(from:)` (the live-drawing
//       round-trip undo / autosave-via-payload use), VERBATIM.
//    2. Codable round-trip WITH the new keys: a payload carrying constraints +
//       parameters encodes + decodes them back (the keys are actually serialized).
//    3. Codable BACK-COMPAT: a payload encoded WITHOUT the new keys (an old serialized
//       snapshot) decodes to EMPTY tables via `decodeIfPresent` — never a decode error.
//    4. The DOCUMENTED PURE-DXF LIMIT: a real DXF codec round-trip
//       (`DXFDocumentCodec.data` → `.payload`) DROPS constraints + parameters (DXF
//       can't carry them — the read path has no source), so a pure-`.dxf` reopen comes
//       back with EMPTY tables. Identical to the `tables` caveat; pinned so the limit
//       is an asserted contract, not an accident.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Parameter + constraint payload persistence")
struct ParameterConstraintPayloadTests {

    // MARK: - Fixtures

    /// A named parameter `width = 22` (the source expression is the bare literal "22",
    /// the value its evaluated cache). The reference key a constraint expression uses.
    private func widthParameter() -> Parameter {
        Parameter(name: "width", expression: "22", value: 22, unit: "mm")
    }

    /// A distance constraint between two entities DRIVEN by the expression "width" (so
    /// it references the `width` parameter), with `value` the last-evaluated cache. The
    /// expression is what makes this a parameter-BOUND constraint (vs a pure literal).
    private func widthBoundConstraint(a: EntityID, b: EntityID) -> Constraint {
        Constraint.distance(
            ConstraintPoint(entityID: a, point: .start),
            ConstraintPoint(entityID: b, point: .start),
            expression: "width",
            value: 22)
    }

    /// A drawing payload carrying ONE parameter + ONE expression-bound constraint over
    /// two loose lines (the entities the constraint references), on the default layer.
    private func parametricPayload() -> (payload: DXFPayload,
                                         param: Parameter,
                                         constraint: Constraint) {
        let lineA = EntityRecord(
            id: EntityID(1), layer: LayerID("0"),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let lineB = EntityRecord(
            id: EntityID(2), layer: LayerID("0"),
            kind: .line(LineData(start: Vector(0, 5), end: Vector(10, 5))))
        let param = widthParameter()
        let constraint = widthBoundConstraint(a: lineA.id, b: lineB.id)
        let payload = DXFPayload(
            entities: [lineA, lineB],
            layers: LayerTable(layers: [Layer(name: "0")], activeLayerName: "0"),
            constraints: ConstraintTable(constraints: [constraint]),
            parameters: ParameterTable(parameters: [param]))
        return (payload, param, constraint)
    }

    // MARK: - 1. In-session payload threading (undo / autosave keep the parametric model)

    @Test("DXFPayload threads parameters + an expression-bound constraint through the live-drawing snapshot round-trip")
    @MainActor
    func payloadThreadsParametricStateThroughLiveDrawing() {
        let (payload, param, constraint) = parametricPayload()

        // payload → live @MainActor CADDrawing → payload snapshot. This is the in-session
        // path undo / autosave-via-payload uses; the parameter + constraint must survive.
        let drawing = CADDrawing.make(from: payload)

        // The PARAMETER survives `make(from:)` verbatim (id, name, expression, value, unit).
        #expect(drawing.parameters.count == 1, "make(from:) dropped the parameter")
        let restoredParam = drawing.parameters.parameter(named: "width")
        #expect(restoredParam?.id == param.id)
        #expect(restoredParam?.name == "width")
        #expect(restoredParam?.expression == "22")
        #expect(restoredParam?.value == 22)
        #expect(restoredParam?.unit == "mm")

        // The EXPRESSION-BOUND CONSTRAINT survives `make(from:)` verbatim — crucially its
        // `expression` (the parameter binding), the field this lane exists to preserve.
        #expect(drawing.constraints.count == 1, "make(from:) dropped the constraint")
        let restoredConstraint = drawing.constraints.constraint(constraint.id)
        #expect(restoredConstraint?.id == constraint.id)
        #expect(restoredConstraint?.expression == "width",
                "the constraint's parameter-binding expression was lost across the snapshot")
        #expect(restoredConstraint?.value == 22)
        #expect(restoredConstraint?.kind.isDimensional == true)

        // Snapshot back OUT (the document's `payloadSnapshot`): both tables ride it verbatim,
        // so the whole parametric model round-trips snapshot → live → snapshot unchanged.
        let snapshot = drawing.payloadSnapshot
        #expect(snapshot.parameters == payload.parameters,
                "payloadSnapshot did not carry the live drawing's parameters verbatim")
        #expect(snapshot.constraints == payload.constraints,
                "payloadSnapshot did not carry the live drawing's constraints verbatim")
    }

    @Test("a parameter-free / constraint-free payload threads empty tables (additive: no regression)")
    @MainActor
    func payloadThreadsEmptyParametricTables() {
        // A payload built WITHOUT constraints/parameters (the historical case) carries none,
        // and the live-drawing round-trip keeps them empty — existing drawings are unaffected.
        let payload = DXFPayload(entities: [])
        #expect(payload.constraints.isEmpty)
        #expect(payload.parameters.isEmpty)

        let drawing = CADDrawing.make(from: payload)
        #expect(drawing.constraints.isEmpty, "make(from:) invented constraints")
        #expect(drawing.parameters.isEmpty, "make(from:) invented parameters")

        let snapshot = drawing.payloadSnapshot
        #expect(snapshot.constraints.isEmpty)
        #expect(snapshot.parameters.isEmpty)
    }

    // MARK: - 2. Codable round-trip WITH the new keys (they are actually serialized)

    @Test("a payload with parameters + constraints round-trips through Codable")
    func payloadCodableRoundTripWithParametricState() throws {
        let (payload, param, constraint) = parametricPayload()

        let data = try JSONEncoder().encode(payload)
        let back = try JSONDecoder().decode(DXFPayload.self, from: data)

        // The parametric tables come back through Codable verbatim ...
        #expect(back.parameters == payload.parameters)
        #expect(back.constraints == payload.constraints)
        #expect(back.parameters.parameter(named: "width")?.id == param.id)
        #expect(back.constraints.constraint(constraint.id)?.expression == "width")
        // ... and the pre-existing fields are unaffected by the new keys.
        #expect(back.entities.count == payload.entities.count)
        #expect(back.layers.contains("0"))
    }

    // MARK: - 3. Codable BACK-COMPAT (an old payload → empty tables via decodeIfPresent)

    @Test("a payload encoded WITHOUT the new keys decodes to empty parametric tables (back-compat)")
    func payloadDecodeIfPresentBackCompat() throws {
        // Simulate an OLD serialized snapshot: a JSON object that carries the pre-L3 keys
        // but OMITS `constraints` and `parameters` entirely. The custom `init(from:)` must
        // decode those missing keys forgivingly to EMPTY tables (decodeIfPresent), never throw.
        let legacyJSON = """
        {
          "entities": [],
          "layers": \(try jsonString(for: LayerTable(layers: [Layer(name: "0")], activeLayerName: "0"))),
          "blocks": \(try jsonString(for: BlockTable())),
          "graphicVariables": \(try jsonString(for: GraphicVariables())),
          "dimStyles": \(try jsonString(for: DimStyleTable())),
          "layouts": [],
          "tables": []
        }
        """
        let data = Data(legacyJSON.utf8)

        // Decodes cleanly (no throw) despite the absent constraints/parameters keys ...
        let back = try JSONDecoder().decode(DXFPayload.self, from: data)

        // ... and the two new tables default to EMPTY (the back-compat contract).
        #expect(back.constraints.isEmpty,
                "an old payload (no constraints key) must decode to an empty ConstraintTable")
        #expect(back.parameters.isEmpty,
                "an old payload (no parameters key) must decode to an empty ParameterTable")
        // The pre-existing fields still decode normally.
        #expect(back.entities.isEmpty)
        #expect(back.layers.contains("0"))
    }

    // MARK: - 4. The DOCUMENTED PURE-DXF LIMIT (constraints/params dropped on a real reopen)

    @Test("a pure-DXF save → reopen DROPS constraints + parameters (documented limit, not a regression)")
    func pureDXFReopenDropsParametricState() throws {
        let (payload, _, _) = parametricPayload()
        #expect(!payload.constraints.isEmpty)   // present going in ...
        #expect(!payload.parameters.isEmpty)

        // The REAL production save/open path: payload → DXF bytes → payload. DXF cannot
        // carry a native constraint / parameter, so the read path has NO source for them.
        let dxf = try DXFDocumentCodec.data(from: payload, format: .dxf)
        let back = try DXFDocumentCodec.payload(from: dxf, format: .dxf)

        // The two loose lines (real geometry) survive to disk + reopen ...
        let lineCount = back.entities.reduce(into: 0) { n, r in
            if case .line = r.kind { n += 1 }
        }
        #expect(lineCount == 2, "the loose line geometry should round-trip through DXF")

        // ... but the constraint + parameter tables come back EMPTY — the documented limit
        // (identical to `tables`): they ride ONLY the in-session payload, not the DXF bytes.
        #expect(back.constraints.isEmpty,
                "a pure-DXF reopen must NOT reconstruct constraints (DXF has no source) — caveat regression")
        #expect(back.parameters.isEmpty,
                "a pure-DXF reopen must NOT reconstruct parameters (DXF has no source) — caveat regression")
    }

    // MARK: - Helpers

    /// JSON-encodes a `Codable` value to its STRING form, for splicing a real encoded
    /// sub-object into the hand-built legacy JSON above (so the legacy fixture's pre-L3
    /// fields decode exactly as the production encoder writes them).
    private func jsonString<T: Encodable>(for value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
