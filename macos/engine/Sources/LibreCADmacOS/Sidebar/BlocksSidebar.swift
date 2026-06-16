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

// MARK: - Blocks panel content (live)

/// The live Blocks content: a list of block definitions with insert / rename / delete /
/// edit affordances + drag-to-place. Rendered as the BODY of the Blocks panel in
/// `SidebarPanelStack` (the panel supplies the header — including the "Create Block…"
/// ＋ — so this view no longer wraps itself in a `Section`). Bound to the same
/// `CanvasModel` the canvas renders so edits reflect live and undo via ⌘Z.
struct BlocksSectionContent: View {
    @Bindable var model: CanvasModel
    /// Bridge to the canvas controller so a block op can request a redraw (the
    /// renderer is on-demand; an insert/delete must nudge it).
    let controllerBox: CADCanvasView.ControllerBox

    /// Per-section thumbnail cache, keyed by `(blockName, modelVersion, size)`.
    /// `modelVersion` bumps on every committed edit + block enter/exit, so an edited
    /// block's stale tile is never returned (its key changes) — edits auto-invalidate.
    @State private var thumbnails = BlockThumbnailCache()

    /// The thumbnail tile edge (points). Matches the row's icon footprint.
    private let thumbSize: CGFloat = 28

    var body: some View {
        let blocks = model.drawing.blocks.blocks
        if blocks.isEmpty {
            Text("No blocks")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            // The Freeze-all / Thaw-all overflow menu (also exposable in the panel
            // header by the next wire-wave via `BlocksPanelMenu`). Embedded at the top
            // of the body so per-document freeze-all is reachable today.
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                BlocksPanelMenu(onFreezeAll: { freezeAll() },
                                onThawAll: { thawAll() })
            }
            // Build ONE ResolveContext for the whole list (shared across rows)
            // so each thumbnail miss doesn't re-snapshot the layer/style/block
            // tables. Captured by `thumbnail(for:)` below.
            let ctx = model.drawing.makeResolveContext()
            ForEach(blocks) { block in
                BlockRow(
                    block: block,
                    thumbnail: thumbnail(for: block.name, context: ctx),
                    onInsert: { insert(block.name) },
                    onEdit: { edit(block.name) },
                    onToggleFrozen: { toggleFrozen(block.name) },
                    onRename: { rename(block.name, to: $0) },
                    onDelete: { delete(block.name) }
                )
                // Drag-to-place: the canvas drop target (owned by the canvas
                // agent) decodes this and calls `model.insertBlock(at:)`.
                .draggable(BlockDragItem(blockName: block.name))
                .contextMenu {
                    Button("Insert at View Center") { insert(block.name) }
                    // WAVE BW (Ask #2): open the in-place Block Editor (BEDIT).
                    Button("Edit Block") { edit(block.name) }
                    // Per-block freeze/visibility (a frozen block's inserts vanish).
                    Button(block.isFrozen ? "Show Block" : "Hide Block") {
                        toggleFrozen(block.name)
                    }
                    Divider()
                    Button("Delete Block", role: .destructive) { delete(block.name) }
                }
            }
        }
    }

    /// The cached/rendered preview image for a block (or `nil` → the row shows the
    /// generic icon). Lazily rendered on the main actor; `thumbSize` distinguishes
    /// cache entries so a future size change doesn't collide.
    private func thumbnail(for name: String, context: ResolveContext) -> NSImage? {
        thumbnails.image(for: model.drawing,
                         blockName: name,
                         version: model.modelVersion,
                         size: thumbSize,
                         context: context)
    }

    // MARK: Ops (all undoable, then nudge the renderer)

    private func insert(_ name: String) {
        if model.insertBlockAtViewCenter(named: name) {
            controllerBox.controller?.requestRedraw()
        }
    }

    /// WAVE BW (Ask #2): enter the in-place Block Editor for `name` (BEDIT). The model
    /// re-scopes the canvas/index/camera to the block's members; the `BlockEditBar`
    /// (Save & Close / Discard) appears via `isEditingBlock`. No-op if a session is
    /// already open or the block is unknown.
    private func edit(_ name: String) {
        if model.enterBlockEditing(name: name) {
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

    /// Toggle a block's frozen flag (the per-row eye). A frozen block's inserts resolve
    /// to nothing, so the canvas must redraw. Undoable via the model wrapper.
    private func toggleFrozen(_ name: String) {
        model.toggleBlockFrozen(name)
        controllerBox.controller?.requestRedraw()
    }

    /// Freeze every named block (the ⋯ menu). Undoable; redraw so frozen inserts vanish.
    private func freezeAll() {
        model.freezeAllBlocks()
        controllerBox.controller?.requestRedraw()
    }

    /// Thaw every named block (the ⋯ menu). Undoable; redraw so the inserts reappear.
    private func thawAll() {
        model.thawAllBlocks()
        controllerBox.controller?.requestRedraw()
    }
}

// MARK: - Blocks panel overflow menu (Freeze All / Thaw All)

/// The Blocks panel's `⋯` overflow menu: Freeze All Blocks / Thaw All Blocks (the
/// document-wide visibility batch, undoable as one ⌘Z step each). Exposed as a small
/// reusable view so it sits at the top of the live `BlocksSectionContent` body today
/// AND can be relocated into the panel HEADER's trailing action slot by the next
/// sidebar wire-wave (which owns `LayersSidebar`/`SidebarPanelStack`) without
/// re-implementing the actions. The host supplies the closures so this view stays
/// model-agnostic and headless-safe (no model reference, no modal of its own — just an
/// `NSMenu`, which is View-layer only).
struct BlocksPanelMenu: View {
    let onFreezeAll: () -> Void
    let onThawAll: () -> Void

    var body: some View {
        Menu {
            Button("Freeze All Blocks", action: onFreezeAll)
            Button("Thaw All Blocks", action: onThawAll)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Freeze or thaw all blocks at once")
    }
}

// MARK: - One block row

/// A single block row: name (inline-editable), an Insert button, and a Delete
/// button. Mirrors `LayerRow`'s callback style — actions route back to the section,
/// which calls the model's undoable mutators.
private struct BlockRow: View {
    let block: Block
    /// A rendered preview of the block's geometry, or `nil` to show the generic
    /// icon (unknown / empty / degenerate block). Computed + cached by the section.
    let thumbnail: NSImage?
    let onInsert: () -> Void
    let onEdit: () -> Void
    let onToggleFrozen: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var draftName: String = ""

    /// The block preview — the rendered thumbnail when available, else the generic
    /// "square.on.square" icon (so a text/empty/unknown block still has a glyph).
    @ViewBuilder private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .interpolation(.high)
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: "square.on.square")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Per-block visibility (eye / eye.slash). A frozen block's inserts vanish
            // from the canvas; its row reads dimmed (below).
            Button(action: onToggleFrozen) {
                Image(systemName: block.isFrozen ? "eye.slash" : "eye")
                    .foregroundStyle(block.isFrozen ? AnyShapeStyle(.tertiary)
                                                     : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(block.isFrozen ? "Show this block (thaw)" : "Hide this block (freeze)")

            preview

            TextField("Block name", text: $draftName)
                .textFieldStyle(.plain)
                .onSubmit { onRename(draftName) }

            Spacer(minLength: 0)

            Button(action: onInsert) {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .help("Insert this block at the view center")

            // WAVE BW (Ask #2): open the in-place Block Editor (BEDIT).
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit this block — changes update every reference")

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this block definition")
        }
        .padding(.vertical, 2)
        // A frozen (hidden) block reads dimmed so the list communicates visibility.
        .opacity(block.isFrozen ? 0.45 : 1)
        .onAppear { draftName = block.name }
        .onChange(of: block.name) { _, newName in
            if draftName != newName { draftName = newName }
        }
    }
}
