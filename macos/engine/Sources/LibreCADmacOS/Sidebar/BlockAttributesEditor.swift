//
//  BlockAttributesEditor.swift
//  LibreCADmacOS
//
//  Block-ATTRIBUTE editors the Inspector composes (block-features §14):
//
//    • `BlockAttributeValuesEditor` — the EATTEDIT core. When a SINGLE `.insert`
//      whose referenced block declares `attributeDefs` is selected, this lists each
//      def's prompt/tag with an editable value field bound to the insert's ATTRIB
//      VALUE. A typed value builds an updated `.insert` record and commits it through
//      the same undoable record-replace funnel every Inspector edit uses
//      (`onCommit`, wired to `CanvasModel.applyInspectorEdits`). Constant-mode defs
//      (flag bit 2) are read-only; invisible-mode defs (flag bit 1) are still editable
//      here (matching AutoCAD's EATTEDIT, which edits hidden values too).
//
//    • `BlockAttributeDefsEditor` — the ATTDEF authoring panel for the Block Editor.
//      Surfaced when a block is being edited; lets the user add / edit / remove the
//      editing block's `attributeDefs` (tag, prompt, default, visible flag) through the
//      undoable def-CRUD ops on `CADDrawing` (`addBlockAttributeDef` /
//      `updateBlockAttributeDef` / `removeBlockAttributeDef`), each routed back to the
//      host via the closures the Inspector passes (so this view never touches the
//      drawing directly and stays unit-test-friendly).
//
//  Both keep LOCAL draft state seeded from the model and re-seeded when the source
//  changes (id / def list) — the same pattern as `EntityCommonEditor` / `GeometryEditor`.
//  View-layer only: no modal, no `NSOpenPanel`, nothing a headless test can hang on.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

// MARK: - Attribute flag bits (DXF ATTDEF/ATTRIB code 70)

/// The DXF code-70 attribute flag bits (block-features §14.2). Defined here (not on
/// the engine `BlockAttributeDef`/`BlockAttributeValue`, which carry the raw `flags`
/// integer for round-trip) so the UI can read/compose them without touching the
/// engine model types.
enum AttributeFlag {
    static let invisible = 1   // value not displayed/printed (ATTDISP can override)
    static let constant  = 2   // fixed value — not editable per reference
    static let verify    = 4   // prompt to verify on insert
    static let preset     = 8  // set to default without prompting

    static func isSet(_ bit: Int, in flags: Int) -> Bool { (flags & bit) != 0 }

    /// `flags` with `bit` set or cleared.
    static func set(_ bit: Int, _ on: Bool, in flags: Int) -> Int {
        on ? (flags | bit) : (flags & ~bit)
    }
}

// MARK: - Insert ATTRIB VALUE editor (EATTEDIT core)

/// Lists a selected attributed insert's ATTRIB values — one editable field per the
/// block's `attributeDefs` — and commits a typed value as an undoable record-replace.
/// Shown by the Inspector only when a SINGLE `.insert` whose block has `attributeDefs`
/// is selected.
struct BlockAttributeValuesEditor: View {
    /// The selected block-reference record (`record.kind` is `.insert`).
    let record: EntityRecord
    /// The block's ATTDEF templates (drive the rows: prompt/tag/flags + the order).
    let defs: [BlockAttributeDef]
    /// Commits a modified record list (always a single `.insert`) — undoable.
    let onCommit: ([EntityRecord]) -> Void

    /// Per-tag draft text, keyed by the (upper-cased) tag so the field tracks the
    /// def even as the record changes under it (undo / external edit).
    @State private var drafts: [String: String] = [:]

    var body: some View {
        Section("Attributes") {
            if defs.isEmpty {
                Text("This block declares no attributes.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(defs, id: \.tag) { def in
                    attributeRow(def)
                }
            }
        }
        .onAppear(perform: seed)
        .onChange(of: record.id) { _, _ in seed() }
        .onChange(of: defs.map(\.tag)) { _, _ in seed() }
        // Re-seed when the underlying VALUES change (undo / sync) so the field shows
        // the live value rather than a stale draft.
        .onChange(of: currentValuesSignature) { _, _ in seed() }
    }

    // MARK: Rows

    @ViewBuilder
    private func attributeRow(_ def: BlockAttributeDef) -> some View {
        let key = def.tag.uppercased()
        let isConstant = AttributeFlag.isSet(AttributeFlag.constant, in: def.flags)
        LabeledContent {
            if isConstant {
                // Constant-mode: the value is fixed by the definition — read-only.
                Text(def.defaultText.isEmpty ? "—" : def.defaultText)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .trailing)
            } else {
                TextField(def.defaultText, text: draftBinding(key))
                    .frame(width: 160)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { commit(tag: def.tag, key: key) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(rowTitle(def))
                if AttributeFlag.isSet(AttributeFlag.invisible, in: def.flags) {
                    Text("invisible")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The row's label — the prompt if present, otherwise the tag (the tag is shown in
    /// parentheses when a distinct prompt exists, so the user sees both).
    private func rowTitle(_ def: BlockAttributeDef) -> String {
        let prompt = def.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty { return def.tag }
        return "\(prompt) (\(def.tag))"
    }

    // MARK: Draft state

    /// A binding into the per-tag draft. The GET falls back to the live value; the SET
    /// stores the draft and commits on every keystroke (matching the other inspector
    /// editors' `onChange` commit cadence — undo collapses a typing burst per turn).
    private func draftBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { drafts[key] ?? "" },
            set: { newValue in
                drafts[key] = newValue
                commit(tag: tagForKey(key), key: key)
            }
        )
    }

    /// Seeds each draft from the insert's current ATTRIB value for that tag (empty if
    /// the insert carries no value yet — the field shows the def's default as placeholder).
    private func seed() {
        guard case .insert(let data) = record.kind else { drafts = [:]; return }
        var next: [String: String] = [:]
        for def in defs {
            let key = def.tag.uppercased()
            let existing = data.attributes.first {
                $0.tag.caseInsensitiveCompare(def.tag) == .orderedSame
            }
            next[key] = existing?.text ?? ""
        }
        drafts = next
    }

    /// The original-case tag for an upper-cased key (defs are the source of truth).
    private func tagForKey(_ key: String) -> String {
        defs.first { $0.tag.uppercased() == key }?.tag ?? key
    }

    /// A stable signature of the insert's current values so a model-side change
    /// (undo / ATTSYNC) re-seeds the drafts.
    private var currentValuesSignature: String {
        guard case .insert(let data) = record.kind else { return "" }
        return data.attributes
            .map { "\($0.tag.uppercased())=\($0.text)" }
            .sorted()
            .joined(separator: "\u{1f}")
    }

    // MARK: Commit (build the updated insert + hand to the undoable funnel)

    /// Writes the draft value for `tag` onto the insert and commits via `onCommit`.
    /// Mirrors `CADDrawing.setInsertAttributeValue`: replace in place when the tag
    /// exists, else append seeded from the matching def. A no-op (value unchanged) is
    /// skipped so it never pollutes undo.
    private func commit(tag: String, key: String) {
        guard case .insert(var data) = record.kind else { return }
        let text = drafts[key] ?? ""

        if let idx = data.attributes.firstIndex(where: {
            $0.tag.caseInsensitiveCompare(tag) == .orderedSame
        }) {
            guard data.attributes[idx].text != text else { return }   // no-op
            data.attributes[idx].text = text
        } else {
            let def = defs.first { $0.tag.caseInsensitiveCompare(tag) == .orderedSame }
            data.attributes.append(BlockAttributeValue(
                tag: def?.tag ?? tag,
                text: text,
                position: def?.position ?? Vector(0, 0),
                height: def?.height ?? 2.5,
                rotation: def?.rotation ?? 0,
                flags: def?.flags ?? 0))
        }

        var updated = record
        updated.kind = .insert(data)
        onCommit([updated])
    }
}

// MARK: - Block-Editor ATTDEF authoring panel

/// The ATTDEF authoring panel (block-features §14.2 — "Define Attributes"). Lists the
/// editing block's `attributeDefs` with edit + remove affordances, plus an add row.
/// Each mutation is reported via a closure (wired to the undoable def-CRUD ops on
/// `CADDrawing`) so the view stays drawing-agnostic and headless-testable.
struct BlockAttributeDefsEditor: View {
    /// The current defs of the block being edited (the source of truth for the list).
    let defs: [BlockAttributeDef]
    /// Adds a new def — returns whether it was accepted (tag free).
    let onAdd: (BlockAttributeDef) -> Bool
    /// Updates an existing def (matched by tag).
    let onUpdate: (BlockAttributeDef) -> Void
    /// Removes the def with this tag.
    let onRemove: (String) -> Void

    // Draft for the "add" row.
    @State private var newTag = ""
    @State private var newPrompt = ""
    @State private var newDefault = ""
    @State private var newVisible = true

    var body: some View {
        Section("Attribute Definitions") {
            if defs.isEmpty {
                Text("No attribute definitions. Add one below.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(defs, id: \.tag) { def in
                    DefRow(def: def, onUpdate: onUpdate, onRemove: onRemove)
                }
            }

            Divider()

            addRow
        }
    }

    // MARK: Add row

    @ViewBuilder
    private var addRow: some View {
        LabeledContent("Tag") {
            TextField("TAG", text: $newTag)
                .frame(width: 160).multilineTextAlignment(.trailing)
        }
        LabeledContent("Prompt") {
            TextField("Prompt", text: $newPrompt)
                .frame(width: 160).multilineTextAlignment(.trailing)
        }
        LabeledContent("Default") {
            TextField("Default value", text: $newDefault)
                .frame(width: 160).multilineTextAlignment(.trailing)
        }
        Toggle("Visible", isOn: $newVisible)
        Button("Add Attribute", action: addNew)
            .disabled(trimmedNewTag.isEmpty)
    }

    private var trimmedNewTag: String {
        newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addNew() {
        let tag = trimmedNewTag
        guard !tag.isEmpty else { return }
        let flags = AttributeFlag.set(AttributeFlag.invisible, !newVisible, in: 0)
        let def = BlockAttributeDef(
            tag: tag,
            prompt: newPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultText: newDefault,
            flags: flags)
        if onAdd(def) {
            newTag = ""; newPrompt = ""; newDefault = ""; newVisible = true
        }
    }
}

// MARK: - One editable def row

/// One row of `BlockAttributeDefsEditor`: prompt + default + visible-flag fields that
/// commit edits (matched by the immutable tag) plus a remove button. Keeps local
/// drafts seeded from the def, re-seeded when the def changes under it (undo / sync).
private struct DefRow: View {
    let def: BlockAttributeDef
    let onUpdate: (BlockAttributeDef) -> Void
    let onRemove: (String) -> Void

    @State private var prompt = ""
    @State private var defaultText = ""
    @State private var visible = true

    var body: some View {
        DisclosureGroup(def.tag) {
            LabeledContent("Prompt") {
                TextField("Prompt", text: $prompt)
                    .frame(width: 150).multilineTextAlignment(.trailing)
                    .onSubmit(commit)
                    .onChange(of: prompt) { _, _ in commit() }
            }
            LabeledContent("Default") {
                TextField("Default value", text: $defaultText)
                    .frame(width: 150).multilineTextAlignment(.trailing)
                    .onSubmit(commit)
                    .onChange(of: defaultText) { _, _ in commit() }
            }
            Toggle("Visible", isOn: $visible)
                .onChange(of: visible) { _, _ in commit() }
            Button("Remove", role: .destructive) { onRemove(def.tag) }
        }
        .onAppear(perform: seed)
        .onChange(of: def.tag) { _, _ in seed() }
        .onChange(of: def.prompt) { _, _ in seed() }
        .onChange(of: def.defaultText) { _, _ in seed() }
        .onChange(of: def.flags) { _, _ in seed() }
    }

    private func seed() {
        prompt = def.prompt
        defaultText = def.defaultText
        visible = !AttributeFlag.isSet(AttributeFlag.invisible, in: def.flags)
    }

    /// Builds the edited def (tag preserved — the match key) and commits if changed.
    private func commit() {
        var updated = def
        updated.prompt = prompt
        updated.defaultText = defaultText
        updated.flags = AttributeFlag.set(AttributeFlag.invisible, !visible, in: def.flags)
        guard updated != def else { return }   // no-op
        onUpdate(updated)
    }
}
