//
//  LayerIsolationTests.swift
//  CADEngineTests
//
//  LAYER ISOLATE / UNISOLATE — pure-engine semantics (`LayerIsolation`):
//   - isolate(keep: {A}) over {A,B,C} hides (freezes) B,C and keeps A visible.
//   - the restore snapshot returns EXACTLY the prior state — isolate→unisolate is
//     an identity round-trip.
//   - keeping an already-only-visible layer is a no-op (empty plan).
//   - an empty keep-set is safe (freezes everything; restore still round-trips).
//   - a frozen-before layer stays frozen after restore (flags are preserved).
//   - isolate reveals a kept layer that was hidden before (thaw).
//
//  These are pure value-type tests — `LayerIsolation` never mutates and never
//  touches the app module / AppKit, so no `@MainActor`, no `CADDrawing`, no
//  symlink is needed. The test mutates a local `LayerTable` to simulate the
//  wire-wave's `mutateLayers` step.
//
//  Uniquely namespaced (`@Suite("layer isolation")`) so it does not collide with
//  the other suites in the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
@testable import CADEngine

@Suite("layer isolation")
struct LayerIsolationTests {

    /// A fresh table with layers A, B, C (all default flags: thawed, unlocked,
    /// printable, non-construction) and a default active layer "A".
    private func abcTable() -> LayerTable {
        LayerTable(
            layers: [Layer(name: "A"), Layer(name: "B"), Layer(name: "C")],
            activeLayerName: "A")
    }

    /// The set of frozen layer names in a table (the hidden set).
    private func frozenNames(_ t: LayerTable) -> Set<String> {
        Set(t.layers.filter { $0.isFrozen }.map { $0.name })
    }

    /// The set of visible layer names in a table.
    private func visibleNames(_ t: LayerTable) -> Set<String> {
        Set(t.layers.filter { $0.isVisible }.map { $0.name })
    }

    // MARK: - Forward isolate

    @Test("isolate(keep:{A}) over {A,B,C} freezes B,C and keeps A visible")
    func isolateHidesOthers() {
        var t = abcTable()
        let result = LayerIsolation.isolate(keep: ["A"], in: t)

        // Plan freezes exactly the non-kept layers; nothing needs thawing.
        #expect(result.isolated.freeze == ["B", "C"])
        #expect(result.isolated.thaw.isEmpty)
        #expect(!result.isNoOp)

        result.isolated.apply(to: &t)
        #expect(visibleNames(t) == ["A"])
        #expect(frozenNames(t) == ["B", "C"])
    }

    @Test("isolate(keep:{A,B}) keeps both visible, hides only C")
    func isolateMultipleKept() {
        var t = abcTable()
        let result = LayerIsolation.isolate(keep: ["A", "B"], in: t)
        #expect(result.isolated.freeze == ["C"])

        result.isolated.apply(to: &t)
        #expect(visibleNames(t) == ["A", "B"])
        #expect(frozenNames(t) == ["C"])
    }

    @Test("isolate reveals a kept layer that was frozen before")
    func isolateThawsHiddenKept() {
        // A is frozen before isolating it: isolate must reveal it.
        var t = LayerTable(
            layers: [Layer(name: "A", isFrozen: true),
                     Layer(name: "B"),
                     Layer(name: "C")],
            activeLayerName: "B")
        let result = LayerIsolation.isolate(keep: ["A"], in: t)
        #expect(result.isolated.thaw == ["A"])
        #expect(result.isolated.freeze == ["B", "C"])

        result.isolated.apply(to: &t)
        #expect(visibleNames(t) == ["A"])
        #expect(frozenNames(t) == ["B", "C"])
    }

    @Test("keep names not in the table are ignored")
    func isolateIgnoresUnknownKeep() {
        var t = abcTable()
        // "Z" doesn't exist; A is the only real kept layer.
        let result = LayerIsolation.isolate(keep: ["A", "Z"], in: t)
        #expect(result.isolated.freeze == ["B", "C"])

        result.isolated.apply(to: &t)
        #expect(visibleNames(t) == ["A"])
    }

    // MARK: - No-op cases

    @Test("keeping an already-only-visible layer is a no-op")
    func isolateNoOpWhenAlreadyIsolated() {
        // A visible, B & C already frozen — isolating A changes nothing.
        let t = LayerTable(
            layers: [Layer(name: "A"),
                     Layer(name: "B", isFrozen: true),
                     Layer(name: "C", isFrozen: true)],
            activeLayerName: "A")
        let result = LayerIsolation.isolate(keep: ["A"], in: t)
        #expect(result.isolated.isEmpty)
        #expect(result.isNoOp)

        // Applying a no-op plan leaves the table identical.
        var t2 = t
        result.isolated.apply(to: &t2)
        #expect(t2 == t)
    }

    @Test("keeping all layers is a no-op")
    func isolateKeepAllNoOp() {
        let t = abcTable()
        let result = LayerIsolation.isolate(keep: ["A", "B", "C"], in: t)
        #expect(result.isNoOp)
    }

    // MARK: - Empty keep-set

    @Test("empty keep-set is safe and freezes everything")
    func isolateEmptyKeepFreezesAll() {
        var t = abcTable()
        let result = LayerIsolation.isolate(keep: Set<String>(), in: t)
        #expect(result.isolated.freeze == ["A", "B", "C"])
        #expect(result.isolated.thaw.isEmpty)

        result.isolated.apply(to: &t)
        #expect(visibleNames(t).isEmpty)
        #expect(frozenNames(t) == ["A", "B", "C"])
    }

    // MARK: - Round-trip (isolate → unisolate == identity)

    @Test("isolate then restore is an exact identity round-trip")
    func roundTripIdentity() {
        let original = abcTable()
        var t = original
        let result = LayerIsolation.isolate(keep: ["A"], in: t)

        // Enter the isolated view.
        result.isolated.apply(to: &t)
        #expect(t != original)            // it really changed something

        // Unisolate via the captured restore snapshot.
        result.restore.apply(to: &t)
        #expect(t == original)            // exactly back to where we started
    }

    @Test("round-trip preserves a frozen-before layer (stays frozen after restore)")
    func roundTripPreservesPriorFrozen() {
        // B is frozen before we ever isolate. After isolate→restore it must be
        // frozen again — restore returns EXACTLY the prior state.
        let original = LayerTable(
            layers: [Layer(name: "A"),
                     Layer(name: "B", isFrozen: true),
                     Layer(name: "C")],
            activeLayerName: "A")
        var t = original
        let result = LayerIsolation.isolate(keep: ["A"], in: t)

        result.isolated.apply(to: &t)
        #expect(frozenNames(t) == ["B", "C"])   // A isolated; B stays hidden, C hidden

        result.restore.apply(to: &t)
        #expect(t == original)
        // The before-frozen B is frozen again, C is thawed again.
        #expect(t.layer(named: "B")?.isFrozen == true)
        #expect(t.layer(named: "C")?.isFrozen == false)
    }

    @Test("round-trip preserves lock/print/construction flags untouched")
    func roundTripPreservesOtherFlags() {
        // Non-frozen flags must survive isolate→restore (isolate only flips
        // freeze; restore must not disturb the others).
        let original = LayerTable(
            layers: [Layer(name: "A", isLocked: true),
                     Layer(name: "B", isPrintable: false),
                     Layer(name: "C", isConstruction: true)],
            activeLayerName: "A")
        var t = original
        let result = LayerIsolation.isolate(keep: ["B"], in: t)

        result.isolated.apply(to: &t)
        result.restore.apply(to: &t)
        #expect(t == original)
        #expect(t.layer(named: "A")?.isLocked == true)
        #expect(t.layer(named: "B")?.isPrintable == false)
        #expect(t.layer(named: "C")?.isConstruction == true)
    }

    @Test("round-trip with an empty keep-set still restores exactly")
    func roundTripEmptyKeep() {
        let original = abcTable()
        var t = original
        let result = LayerIsolation.isolate(keep: Set<String>(), in: t)
        result.isolated.apply(to: &t)
        #expect(visibleNames(t).isEmpty)
        result.restore.apply(to: &t)
        #expect(t == original)
    }

    // MARK: - Sequence overload

    @Test("array keep overload matches the set overload")
    func sequenceOverloadMatches() {
        let t = abcTable()
        let fromArray = LayerIsolation.isolate(keep: ["A", "B"], in: t)
        let fromSet = LayerIsolation.isolate(keep: Set(["A", "B"]), in: t)
        #expect(fromArray.isolated == fromSet.isolated)
        #expect(fromArray.restore == fromSet.restore)
    }

    @Test("duplicate names in the keep sequence collapse correctly")
    func sequenceDuplicatesCollapse() {
        let t = abcTable()
        let result = LayerIsolation.isolate(keep: ["A", "A", "A"], in: t)
        #expect(result.isolated.freeze == ["B", "C"])
    }
}
