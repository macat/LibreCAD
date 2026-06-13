//
//  BlocksSidebar.swift
//  LibreCADmacOS
//
//  The live Blocks section of the leading-pane sidebar (feature-catalog F9, UI
//  half): turns the old read-only Blocks stub into a working panel. Lists the
//  document's block definitions and offers per-block INSERT (place an `.insert` of
//  the block), inline RENAME, and DELETE — plus drag-to-place onto the canvas.
//
//  Like `LayersSidebar`, it binds DIRECTLY to the live `CanvasModel` so every
//  mutation flows through the drawing's UNDOABLE block mutators
//  (`CanvasModel.insertBlock` / `renameBlock` / `deleteBlock`, which funnel into
//  `CADDrawing`'s `addBlock`/`renameBlock`/`removeBlock` + the entity `.add`/`.remove`
//  path). The model is observable, so the panel AND the canvas recompute on every
//  edit, and ⌘Z reverts a block op like any geometry edit.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import UniformTypeIdentifiers
import CADEngine

/// A drag payload carrying a block name from the Blocks list to the canvas (so a
/// drop can place that block at the drop point). A trivial `Transferable` string
/// wrapper — the canvas-side drop target is owned by the canvas agent; the sidebar
/// provides the source so drag-to-place is wired from this side.
struct BlockDragItem: Codable, Transferable {
    let blockName: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .blockDragItem)
    }
}

extension UTType {
    /// A private UTI for the block-name drag payload (drag-to-place, F9).
    static let blockDragItem = UTType(exportedAs: "org.librecad.macos.block-drag-item")
}

// MARK: - Blocks section (live)

/// The live Blocks section: a list of block definitions with insert / rename /
/// delete affordances, embedded by `LayersSidebar` in its `List`. Bound to the same
/// `CanvasModel` the canvas renders so edits reflect live and undo via ⌘Z.
struct BlocksSection: View {
    @Bindable var model: CanvasModel
    /// Bridge to the canvas controller so a block op can request a redraw (the
    /// renderer is on-demand; an insert/delete must nudge it).
    let controllerBox: CADCanvasView.ControllerBox

    var body: some View {
        Section("Blocks") {
            let blocks = model.drawing.blocks.blocks
            if blocks.isEmpty {
                Text("No blocks")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(blocks) { block in
                    BlockRow(
                        block: block,
                        onInsert: { insert(block.name) },
                        onRename: { rename(block.name, to: $0) },
                        onDelete: { delete(block.name) }
                    )
                    // Drag-to-place: the canvas drop target (owned by the canvas
                    // agent) decodes this and calls `model.insertBlock(at:)`.
                    .draggable(BlockDragItem(blockName: block.name))
                    .contextMenu {
                        Button("Insert at View Center") { insert(block.name) }
                        Divider()
                        Button("Delete Block", role: .destructive) { delete(block.name) }
                    }
                }
            }
        }
    }

    // MARK: Ops (all undoable, then nudge the renderer)

    private func insert(_ name: String) {
        if model.insertBlockAtViewCenter(named: name) {
            controllerBox.controller?.requestRedraw()
        }
    }

    private func rename(_ oldName: String, to newName: String) {
        if model.renameBlock(oldName, to: newName) {
            controllerBox.controller?.requestRedraw()
        }
    }

    private func delete(_ name: String) {
        if model.deleteBlock(named: name) {
            controllerBox.controller?.requestRedraw()
        }
    }
}

// MARK: - One block row

/// A single block row: name (inline-editable), an Insert button, and a Delete
/// button. Mirrors `LayerRow`'s callback style — actions route back to the section,
/// which calls the model's undoable mutators.
private struct BlockRow: View {
    let block: Block
    let onInsert: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var draftName: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.on.square")
                .foregroundStyle(.secondary)

            TextField("Block name", text: $draftName)
                .textFieldStyle(.plain)
                .onSubmit { onRename(draftName) }

            Spacer(minLength: 0)

            Button(action: onInsert) {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .help("Insert this block at the view center")

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this block definition")
        }
        .padding(.vertical, 2)
        .onAppear { draftName = block.name }
        .onChange(of: block.name) { _, newName in
            if draftName != newName { draftName = newName }
        }
    }
}
