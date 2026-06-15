//
//  LibreCADApp.swift
//  LibreCADmacOS
//
//  SwiftUI entry point. The app is now DOCUMENT-BASED: a `DocumentGroup` over the
//  off-main-safe `LibreCADDocument` (a `ReferenceFileDocument` for `.dxf`). That
//  gives native New / Open / Open Recent / Save / Save As / Revert / autosave /
//  versions / the dirty dot / multi-window for free. Each document window hosts
//  `ContentView`, which builds the live `@MainActor CADDrawing`/`CanvasModel` from
//  the document's Sendable payload — on the MAIN ACTOR — and runs the canvas +
//  inspector + toolbar + palette + gizmos.
//
//  ⚠️ LAUNCH-SAFETY — why DocumentGroup is safe HERE (it crashed once).
//  An earlier document build SIGTRAP-crashed because `CADDocument.init` called
//  `MainActor.assumeIsolated` while NSDocument constructed the document OFF the
//  main actor (a background NSOperationQueue). The current `LibreCADDocument`
//  init/snapshot/fileWrapper touch ONLY Sendable value data (never a `@MainActor`
//  type, never `assumeIsolated`); the `@MainActor` model is built later in the
//  view. See LibreCADDocument.swift / ContentView.swift and DEVLOG.md ("SIGTRAP").
//
//  File ▸ New / Open / Open Recent / Save / Save As / Revert are now NATIVE
//  DocumentGroup commands (no custom panels). Export (PDF/PNG/SVG) and Print STAY
//  custom (they are not the document type) and are added to the File menu via
//  focused scene values, as are the tool/undo/delete/palette commands.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import AppKit
import CADEngine

@main
struct LibreCADApp: App {

    /// The F8 key as a SwiftUI `KeyEquivalent`. SwiftUI ships no function-key
    /// constants, so it is built from AppKit's `NSF8FunctionKey` Unicode scalar — the
    /// same code AppKit's menu key-equivalent matching uses, so ⌥-free F8 in the menu
    /// fires the Ortho toggle. (The canvas `keyDown` also handles F8 via keyCode 100,
    /// so it works whether the menu or the canvas has key focus.)
    private static let f8Key = KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!))
    /// The "open command palette" (⌘K) action published by the focused window.
    @FocusedValue(\.commandPalette) private var commandPalette
    @FocusedValue(\.focusCommandLine) private var focusCommandLine
    /// The "open Document Settings" (⌥⌘,) action published by the focused window (D8).
    @FocusedValue(\.openDocumentSettings) private var openDocumentSettings
    /// The "New from Template…" chooser action published by the focused window (F24).
    @FocusedValue(\.newFromTemplate) private var newFromTemplate
    /// The Zoom-to-Fit action published by the focused window.
    @FocusedValue(\.zoomToFit) private var zoomToFit
    /// Export (PDF/PNG/SVG) and Print actions published by the focused window.
    @FocusedValue(\.exportDocument) private var exportDocument
    @FocusedValue(\.printDocument) private var printDocument
    /// The tool-activation action published by the focused window.
    @FocusedValue(\.activateTool) private var activateTool
    /// The "begin Image placement" action published by the focused window (Tools ▸
    /// Image…) — presents the file-picker, then arms the two-click placement.
    @FocusedValue(\.placeImage) private var placeImage
    /// Undo / redo actions published by the focused window.
    @FocusedValue(\.undoAction) private var undoAction
    @FocusedValue(\.redoAction) private var redoAction
    /// Delete-selection action published by the focused window (Edit ▸ Delete, ⌫).
    @FocusedValue(\.deleteSelection) private var deleteSelection
    /// Duplicate-selection action published by the focused window (Edit ▸ Duplicate,
    /// ⌘D) — duplicates the current selection in place (a small nudge) as one
    /// undoable group via the pure `Duplicate.duplicate` static API.
    @FocusedValue(\.duplicateSelection) private var duplicateSelection
    /// Whether the focused window has a draw tool mid-run. When true the Edit ▸
    /// Delete item is disabled so its bare-⌫ shortcut does NOT pre-empt the tool's
    /// `.backspace` (see the Delete button below and MUST-FIX 1).
    @FocusedValue(\.isToolActive) private var isToolActive

    var body: some Scene {
        // The document scene: a brand-new document is the empty `LibreCADDocument()`;
        // opening a file constructs `LibreCADDocument(configuration:)` OFF-main from
        // Sendable bytes (the launch-safe path). The editor closure hands us the
        // document reference, which ContentView turns into the live model on-main.
        DocumentGroup(newDocument: { LibreCADDocument() }) { configuration in
            ContentView(document: configuration.document)
        }
        .commands {
            // File ▸ New from Template… — added right after the native New item
            // (DocumentGroup owns plain New / Open / Open Recent). It raises the
            // template chooser on the focused window (F24); picking a template seeds
            // that window's drawing from a bundled `.dxf` template (entities + layers
            // + units), giving a pre-populated drawing. ⇧⌘N is the conventional
            // "new from template" chord (plain ⌘N stays the native blank New).
            CommandGroup(after: .newItem) {
                Button("New from Template…") { newFromTemplate?() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(newFromTemplate == nil)
            }
            // File ▸ Export… / Print… — added AFTER the native Save items (Save /
            // Save As / Revert come from DocumentGroup). Export renders the drawing
            // to PDF / PNG / SVG (not the document type); Print drives the system
            // print dialog. Both route to the focused window via focused values.
            CommandGroup(after: .saveItem) {
                Divider()
                Menu("Export…") {
                    Button("PDF…") { exportDocument?(.pdf) }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(exportDocument == nil)
                    Button("PNG…") { exportDocument?(.png) }
                        .disabled(exportDocument == nil)
                    Button("SVG…") { exportDocument?(.svg) }
                        .disabled(exportDocument == nil)
                }
                // File ▸ Print… (⌘P) — the system print dialog, fitted to paper.
                Button("Print…") { printDocument?() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(printDocument == nil)

                Divider()
                // File ▸ Document Settings… (⌥⌘, — decision D8). The per-document
                // settings sheet (units / grid & snap / dimensions / layers / paper).
                // ⌘, is reserved for a future app-level Preferences, so document
                // settings take ⌥⌘,. Routed to the focused window via a focused value.
                Button("Document Settings…") { openDocumentSettings?() }
                    .keyboardShortcut(",", modifiers: [.command, .option])
                    .disabled(openDocumentSettings == nil)
            }
            // Undo / redo. DocumentGroup provides system Undo/Redo bound to the
            // document's environment UndoManager — which our model now ADOPTS, so
            // edits register against it. We still REPLACE the items to route ⌘Z/⇧⌘Z
            // through `model.undo()`/`redo()`, which run the post-undo bookkeeping the
            // raw UndoManager can't (rebuild the spatial index, clear selection,
            // request a redraw). Because the model's manager IS the environment
            // manager, the native dirty/clean tracking still works.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { undoAction?() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(undoAction == nil)
                Button("Redo") { redoAction?() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(redoAction == nil)
            }
            // Edit ▸ Delete — removes the current selection (undoable). The ⌫ key on
            // the canvas is also handled directly by the controller (select mode);
            // this menu item makes it discoverable and gives it a standard shortcut.
            //
            // It is DISABLED while a draw tool is mid-run (`isToolActive == true`).
            // `NSMenu.performKeyEquivalent` runs BEFORE the canvas `keyDown`, so an
            // enabled bare-⌫ item would steal ⌫ from the active tool (where ⌫ must
            // be the tool's `.backspace`). A disabled item's key equivalent is not
            // consumed, so ⌫ falls through to the canvas `keyDown`, which routes it
            // to the tool. In select mode (`isToolActive` false/nil) the item stays
            // enabled and ⌫ deletes the selection. (MUST-FIX 1.)
            CommandGroup(after: .pasteboard) {
                Button("Delete") { deleteSelection?() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(deleteSelection == nil || (isToolActive ?? false))

                // Edit ▸ Duplicate (⌘D) — duplicate the current selection in place
                // (AutoCAD-style: a small nudge so the copies are grabbable apart from
                // their sources), as one undoable group. Routes to the focused window
                // via the `duplicateSelection` focused value, which calls
                // `CanvasModel.duplicateSelection` (the pure `Duplicate.duplicate`
                // static API → `applyCommit`). ⌘D is a command-modifier chord, so it
                // never collides with the canvas keymap (bare/⇧/⌥ tool letters) — it
                // stays enabled even while a draw tool is mid-run.
                Button("Duplicate") { duplicateSelection?() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(duplicateSelection == nil)

                Divider()
                // Edit ▸ Select All / Deselect All / Invert Selection — the standard
                // editing-selection primitives. Each routes through the responder
                // chain (`NSApp.sendAction(_:to:nil:from:)`) to the focused window's
                // canvas (FlippedMTKView), which implements the matching `@objc`
                // action and operates on its CanvasModel. Select All skips locked /
                // hidden geometry (engine `SelectionPolicy`). ⌘A / ⇧⌘A are standard;
                // Invert has no standard shortcut (matches AutoCAD/most CAD apps).
                Button("Select All") {
                    NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
                Button("Deselect All") {
                    NSApp.sendAction(Selector(("deselectAllEntities:")), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Invert Selection") {
                    NSApp.sendAction(Selector(("invertSelectionAction:")), to: nil, from: nil)
                }

                Divider()
                // Edit ▸ Select Connected / Select Contour (wire-wave-2). Both grow the
                // selection from a SEED (the single selected entity, else the entity
                // under the cursor) via the pure engine `SelectionTraversal`:
                //   • Connected — the whole connected component (chain/network) sharing
                //     endpoints with the seed (`SelectionTraversal.connected`).
                //   • Contour — the single closed loop the seed belongs to
                //     (`SelectionTraversal.contour`); a no-op if the seed is not part of
                //     a closed loop. Routed through the responder chain to the focused
                //     canvas (like Invert), which resolves the seed + applies the result
                //     to its CanvasModel. No standard shortcut (matches most CAD apps).
                Button("Select Connected") {
                    NSApp.sendAction(Selector(("selectConnectedAction:")), to: nil, from: nil)
                }
                Button("Select Contour") {
                    NSApp.sendAction(Selector(("selectContourAction:")), to: nil, from: nil)
                }
            }
            CommandGroup(after: .toolbar) {
                // ⌘K — the command palette: fuzzy-find and run any tool/app action.
                Button("Command Palette…") { commandPalette?() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(commandPalette == nil)
                // ⇧⌘L — focus the bottom command/coordinate input line (U1, D1) so
                // the user can type a precise coordinate/length. (Space also focuses
                // it on the canvas while a tool is active.)
                Button("Command Line") { focusCommandLine?() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(focusCommandLine == nil)
                Button("Zoom to Fit") { zoomToFit?() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(zoomToFit == nil)
                // View ▸ Zoom Window (⇧⌘Z is taken by Redo; use ⌥⌘Z) — arm the
                // transient drag-box zoom: the next drag draws a box, releasing zooms
                // to fit it (F23). Routed through the responder chain to the focused
                // canvas (which also drives the menu checkmark via
                // `validateUserInterfaceItem`).
                Button("Zoom Window") {
                    NSApp.sendAction(Selector(("zoomWindowAction:")), to: nil, from: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
                // View ▸ Zoom Previous (⌥⌘[) — return to the most recent prior
                // viewport (F23). Disabled (via the canvas validator) when the zoom
                // history is empty.
                Button("Zoom Previous") {
                    NSApp.sendAction(Selector(("zoomPreviousAction:")), to: nil, from: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .option])

                Divider()
                // View ▸ Named Views (LibreCAD / AutoCAD parity) — save the current
                // viewport under a name and restore it later. Routed through the
                // responder chain to the focused canvas (the Ortho / Zoom-Window /
                // Relative-zero pattern); the `@objc` handlers live in the extension on
                // the canvas view in THIS file (below), so the whole feature's wiring
                // stays in the menu + app. Save prompts for a name via an AppKit alert
                // (View-layer only — never reachable from tests); Restore/Delete raise a
                // small AppKit picker of the saved names (a "Manage Views…" affordance,
                // which the brief allows) so the dynamic name list does not depend on a
                // SwiftUI focused value (ContentView, the focused-value provider, is not
                // part of this change). ⌥⌘S saves; Restore/Delete have no chord (they
                // open a picker). `validateUserInterfaceItem` greys out Restore/Delete
                // when no view is saved.
                Button("Save View…") {
                    NSApp.sendAction(Selector(("saveNamedViewAction:")), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Restore View…") {
                    NSApp.sendAction(Selector(("restoreNamedViewAction:")), to: nil, from: nil)
                }
                Button("Delete View…") {
                    NSApp.sendAction(Selector(("deleteNamedViewAction:")), to: nil, from: nil)
                }

                Divider()
                // View ▸ Ortho (F8) — toggles the persistent ortho restriction
                // (horizontal/vertical lock relative to the last point while drawing).
                // Routed through the responder chain to the focused canvas (which also
                // drives the menu checkmark via `validateUserInterfaceItem`). Hold-⇧
                // during point input flips ortho on-the-fly without touching this flag.
                Button("Ortho") {
                    NSApp.sendAction(Selector(("toggleOrthoAction:")), to: nil, from: nil)
                }
                .keyboardShortcut(Self.f8Key, modifiers: [])

                Divider()
                // Relative-zero (LibreCAD's "Set relative zero") — the datum the
                // command line's `@dx,dy` / polar / bare-distance input measures from.
                // Routed through the responder chain to the focused canvas (the
                // Ortho / Zoom-Window pattern); the `@objc` handlers live in an
                // extension on the canvas view in THIS file (see below), so the wiring
                // stays entirely in the menu + app. The shortcuts use ⌥⌘ chords so they
                // never collide with the canvas keymap (bare / ⇧ / ⌥ tool letters) nor
                // the existing command-modifier menu chords (confirmed against the
                // keymap: ⌥⌘R / ⌥⌘L / ⌥⌘0 are all free).
                //
                // Set Relative Origin (⌥⌘R) — arm a one-shot pick: the next snapped
                // canvas click sets the relative zero to that point.
                Button("Set Relative Origin") {
                    NSApp.sendAction(Selector(("setRelativeZeroAction:")), to: nil, from: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                // Lock / Unlock Relative Zero (⌥⌘L) — when locked the relative zero
                // stops auto-advancing to the last placed point (it stays a fixed
                // datum); unlocking restores the auto-follow behavior.
                Button("Lock Relative Zero") {
                    NSApp.sendAction(Selector(("toggleRelativeZeroLockAction:")), to: nil, from: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                // Reset Relative Zero to Origin (⌥⌘0) — set it back to (0, 0).
                Button("Reset Relative Zero to Origin") {
                    NSApp.sendAction(Selector(("resetRelativeZeroAction:")), to: nil, from: nil)
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
            // The Tools menu — the discoverable source of truth for EVERY tool and
            // its shortcut. Grouped into Draw / Modify / Annotate SUBMENUS (consistent
            // with the toolbar's grouped sections + per-group overflow), with Select as
            // the always-present core mode at top. Each item activates the tool on the
            // focused canvas via the `activateTool` focused value; the same shortcuts
            // are also handled directly by the canvas `keyDown` (CADCanvasView.handleKey)
            // so they work whether the menu or the canvas has focus. Decomposed into
            // small per-group computed properties so the SwiftUI type-checker never sees
            // a large monolithic menu expression (gotcha #2).
            CommandMenu("Tools") {
                Button("Select") { activateTool?(.select) }
                    .keyboardShortcut("v", modifiers: [])
                    .disabled(activateTool == nil)

                Divider()
                drawMenu
                modifyMenu
                annotateMenu
            }
            // The Arrange menu (F16) — draw-order (Z-stack) ops + Revert Direction on
            // the current selection. Routed through the responder chain to the focused
            // canvas (like the Edit/View selection items), which acts on its
            // CanvasModel + drives each item's enabled state via
            // `validateUserInterfaceItem`. Shortcuts follow the common app convention
            // (⌘⇧] / ⌘] front/forward, ⌘[ / ⌘⇧[ backward/back).
            CommandMenu("Arrange") {
                Button("Bring to Front") {
                    NSApp.sendAction(Selector(("bringToFrontAction:")), to: nil, from: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Bring Forward") {
                    NSApp.sendAction(Selector(("bringForwardAction:")), to: nil, from: nil)
                }
                .keyboardShortcut("]", modifiers: .command)
                Button("Send Backward") {
                    NSApp.sendAction(Selector(("sendBackwardAction:")), to: nil, from: nil)
                }
                .keyboardShortcut("[", modifiers: .command)
                Button("Send to Back") {
                    NSApp.sendAction(Selector(("sendToBackAction:")), to: nil, from: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()
                // Revert Direction — flip the selection's defining direction (line
                // endpoints swap, polyline vertex order reverses, arc/spline sweep
                // flips). The drawn shape is unchanged.
                Button("Revert Direction") {
                    NSApp.sendAction(Selector(("revertDirectionAction:")), to: nil, from: nil)
                }
            }
        }

        // The APPLICATION-LEVEL Preferences window (audit G7). On macOS a `Settings`
        // scene is special: AppKit AUTOMATICALLY wires it to the standard application-
        // menu "Settings…/Preferences…" item with the conventional ⌘, shortcut and the
        // standard preferences-window chrome — we must NOT declare ⌘, ourselves (that
        // would double-bind it). These app-WIDE prefs (defaults for new drawings,
        // global appearance/quality) are backed by `@AppStorage` (see AppSettingsView),
        // so they persist + apply to new documents — DISTINCT from the per-DOCUMENT
        // settings sheet (File ▸ Document Settings…, ⌥⌘,) which stays unchanged (D8).
        Settings {
            AppSettingsView()
        }
    }

    // MARK: - Tools menu groups (Draw / Modify / Annotate)
    //
    // Each group is a SUBMENU mirroring the toolbar's grouped sections (ContentView's
    // `ToolCatalog`). Split into small computed properties (and per-group helpers) so
    // no single menu body is large enough to blow the SwiftUI type-checker (gotcha #2).
    // Every existing keyboard shortcut is preserved exactly; only the nesting changed.

    /// Tools ▸ Draw — geometry-creating tools (+ a Construction Lines subgroup). A
    /// `toolItem(_:_:_:)` button activates a kind via `activateTool`; Image routes
    /// through the file-picker `placeImage` flow (the kind needs a file chosen first).
    @ViewBuilder
    private var drawMenu: some View {
        Menu("Draw") {
            toolItem(.line, "l", [])
            toolItem(.circle, "c", [])
            toolItem(.arc, "a", [])
            toolItem(.rectangle, "r", [])
            toolItem(.polyline, "p", [])
            toolItem(.point, "o", [])
            toolItem(.ellipse, "e", [])
            toolItem(.polygon, "g", [])
            toolItem(.spline, "s", [])
            toolItem(.hatch, "h", [])
            // Image (⇧Y) routes through the file-picker flow, not a bare activate.
            Button("Image…") { placeImage?() }
                .keyboardShortcut("y", modifiers: .shift)
                .disabled(placeImage == nil)

            Divider()
            // Construction lines: infinite XLine (⌥I) + semi-infinite Ray (⌥Y).
            toolItem(.xline, "i", .option)
            toolItem(.ray, "y", .option)
            toolItem(.insert, "i", .shift)
        }
    }

    /// Tools ▸ Modify — selection transforms + edit-under-cursor tools (+ a Blocks
    /// subgroup). Modify tools act on the current selection (select in V mode, then
    /// activate); with nothing selected the tool's HUD prompts "Select objects…".
    @ViewBuilder
    private var modifyMenu: some View {
        Menu("Modify") {
            toolItem(.move, "m", [])
            toolItem(.copy, "c", .shift)
            toolItem(.offset, "o", .shift)
            toolItem(.rotate, "r", .shift)
            toolItem(.scale, "s", .shift)
            toolItem(.mirror, "m", .shift)
            toolItem(.array, "a", .shift)
            toolItem(.arrayPath, "p", .option)
            toolItem(.divide, "d", .shift)
            toolItem(.explode, "x", .shift)
            toolItem(.stretch, "s", .option)
            toolItem(.lengthen, "l", .shift)
            toolItem(.break, "b", .shift)

            Divider()
            // Edit tools (pick entities under the cursor; no pre-selection needed).
            toolItem(.trim, "t", [])
            toolItem(.extend, "x", [])
            toolItem(.fillet, "f", [])
            toolItem(.chamfer, "f", .shift)
            toolItem(.polylineEdit, "p", .shift)
            toolItem(.join, "j", .shift)
            toolItem(.explodeText, "e", .shift)
            toolItem(.align, "a", .option)

            Divider()
            blocksMenu
        }
    }

    /// Tools ▸ Annotate — text, dimensions (+ subtypes), leaders, and the read-only
    /// Measure subgroup. Mirrors the toolbar's Annotate group.
    @ViewBuilder
    private var annotateMenu: some View {
        Menu("Annotate") {
            toolItem(.text, "t", .shift)

            Divider()
            dimensionsMenu

            Divider()
            // Leader callout + chained linear dims (stacked / running).
            toolItem(.leader, "l", .option)
            toolItem(.baselineDim, "d", .option)
            toolItem(.continueDim, "c", .option)

            Divider()
            measureMenu
        }
    }

    /// Dimensions subgroup (the five base dims + the three wave-2 subtypes).
    @ViewBuilder
    private var dimensionsMenu: some View {
        Menu("Dimensions") {
            toolItem(.linearDim, "d", [])
            toolItem(.alignedDim, "i", [])
            toolItem(.radialDim, "u", [])
            toolItem(.diameterDim, "b", [])
            toolItem(.angularDim, "n", [])

            Divider()
            toolItem(.ordinateDim, "o", .option)
            toolItem(.arcLengthDim, "g", .option)
            toolItem(.angular3pDim, "n", .option)
        }
    }

    /// Measure subgroup (read-only queries; only Distance keys ⇧K).
    @ViewBuilder
    private var measureMenu: some View {
        Menu("Measure") {
            toolItem(.measureDistance, "k", .shift)
            toolItem(.measureAngle, nil, [])
            toolItem(.measureArea, nil, [])
            toolItem(.measureLength, nil, [])
        }
    }

    /// Blocks subgroup (Create Block / Explode Block).
    @ViewBuilder
    private var blocksMenu: some View {
        Menu("Blocks") {
            toolItem(.createBlock, "b", .option)
            toolItem(.explodeInsert, "x", .option)
        }
    }

    /// One Tools-menu item: a button that activates `kind` via the focused
    /// `activateTool`, titled from the kind, with the given keyboard shortcut. A `nil`
    /// `key` means the tool has no key chord (menu/⌘K only). Disabled when no canvas is
    /// focused. Keeps each menu group body tiny for the type-checker.
    @ViewBuilder
    private func toolItem(_ kind: ToolKind, _ key: Character?, _ modifiers: EventModifiers) -> some View {
        if let key {
            Button(kind.title) { activateTool?(kind) }
                .keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
                .disabled(activateTool == nil)
        } else {
            Button(kind.title) { activateTool?(kind) }
                .disabled(activateTool == nil)
        }
    }
}

// MARK: - Relative-zero responder-chain actions (LibreCAD's "Set relative zero")
//
// The View ▸ Set Relative Origin / Lock Relative Zero / Reset Relative Zero menu items
// dispatch via `NSApp.sendAction(_:to:nil:from:)` (the same responder-chain wiring the
// Ortho / Zoom-Window / Select-All items use). The focused window's canvas
// (`FlippedMTKView`) is the first responder, so the action lands here. These handlers
// are declared in an EXTENSION on the canvas view (it lives in the same module), which
// keeps the relative-zero feature's wiring contained to the menu + this file — no edit
// to the canvas-view or content-view source is needed. Each forwards to the owning
// controller's `CanvasModel` (the testable set/lock/reset logic) and requests a redraw
// so the origin marker / status readout refresh. `validateUserInterfaceItem` on the
// canvas view returns `true` for any selector it doesn't special-case, so these items
// stay enabled while the canvas is focused (the model methods are safe no-ops/idempotent
// when there is nothing to do).
extension FlippedMTKView {

    /// View ▸ Set Relative Origin (⌥⌘R) — arm a one-shot pick: the next snapped canvas
    /// click sets the relative zero to that point (consumed on the existing select-mode
    /// click path in `CanvasModel.toggleSelection`).
    @objc func setRelativeZeroAction(_ sender: Any?) {
        controller?.model.armSetRelativeZero()
        controller?.requestRedraw()
    }

    /// View ▸ Lock / Unlock Relative Zero (⌥⌘L) — toggles whether the relative zero
    /// stays a fixed datum (locked) or auto-follows the last placed point (unlocked).
    @objc func toggleRelativeZeroLockAction(_ sender: Any?) {
        controller?.model.toggleRelativeZeroLock()
        controller?.requestRedraw()
    }

    /// View ▸ Reset Relative Zero to Origin (⌥⌘0) — set the relative zero back to (0,0).
    @objc func resetRelativeZeroAction(_ sender: Any?) {
        controller?.model.resetRelativeZeroToOrigin()
        controller?.requestRedraw()
    }
}

// MARK: - Named-views responder-chain actions (LibreCAD / AutoCAD "Named Views")
//
// The View ▸ Save View… / Restore View… / Delete View… menu items dispatch via
// `NSApp.sendAction(_:to:nil:from:)` (the same responder-chain wiring the Ortho /
// Zoom-Window / Relative-zero items use). The focused window's canvas
// (`FlippedMTKView`) is the first responder, so the action lands here. These handlers
// live in an EXTENSION on the canvas view (same module) so the feature's wiring is
// contained to the menu + this file — no edit to the canvas-view or content-view
// source is needed. Each forwards to the owning controller's `CanvasModel` (the
// testable save/restore/delete logic on `NamedViewTable`) and requests a redraw so the
// restored viewport repaints.
//
// The NAME PROMPT (Save) and the NAME PICKER (Restore / Delete) are AppKit panels
// (`NSAlert`), so they are View-layer ONLY — never reachable from the headless tests
// (which exercise `NamedViewTable` + capture/apply + the `CanvasModel` save/restore
// methods directly). Restore/Delete on an empty table show a brief notice instead of a
// silent no-op (the items stay enabled because `validateUserInterfaceItem`, which lives
// in the non-owned canvas-view file, is not extended for these selectors).
extension FlippedMTKView {

    /// View ▸ Save View… (⌥⌘S) — prompt for a name, then save the current viewport
    /// under it (overwriting a same-named view, AutoCAD "save over").
    @objc func saveNamedViewAction(_ sender: Any?) {
        guard let controller else { return }
        let suggested = "View \(controller.model.namedViewNames.count + 1)"
        guard let name = Self.promptForViewName(
            title: "Save View",
            message: "Save the current view (center + zoom) under a name:",
            defaultName: suggested,
            confirm: "Save",
            in: window) else { return }
        _ = controller.model.saveNamedView(name: name)
        controller.requestRedraw()
    }

    /// View ▸ Restore View… — pick a saved view by name, then restore its viewport.
    @objc func restoreNamedViewAction(_ sender: Any?) {
        guard let controller else { return }
        let names = controller.model.namedViewNames
        guard !names.isEmpty else {
            Self.showNoViewsNotice(in: window)
            return
        }
        guard let name = Self.promptForExistingView(
            title: "Restore View",
            message: "Choose a saved view to restore:",
            names: names,
            confirm: "Restore",
            in: window) else { return }
        _ = controller.model.restoreNamedView(name: name)
        controller.requestRedraw()
    }

    /// View ▸ Delete View… — pick a saved view by name, then delete it.
    @objc func deleteNamedViewAction(_ sender: Any?) {
        guard let controller else { return }
        let names = controller.model.namedViewNames
        guard !names.isEmpty else {
            Self.showNoViewsNotice(in: window)
            return
        }
        guard let name = Self.promptForExistingView(
            title: "Delete View",
            message: "Choose a saved view to delete:",
            names: names,
            confirm: "Delete",
            in: window) else { return }
        _ = controller.model.deleteNamedView(name: name)
        controller.requestRedraw()
    }

    // MARK: AppKit prompts (View-layer only — never reached by the headless tests)

    /// A modal name-entry alert (an OK/Cancel `NSAlert` with an accessory text
    /// field). Returns the trimmed entered name, or `nil` if cancelled / blank.
    private static func promptForViewName(
        title: String, message: String, defaultName: String,
        confirm: String, in window: NSWindow?
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = runAlert(alert, in: window)
        guard response == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A modal name-PICKER alert (an OK/Cancel `NSAlert` with an accessory popup of
    /// the saved names). Returns the chosen name, or `nil` if cancelled.
    private static func promptForExistingView(
        title: String, message: String, names: [String],
        confirm: String, in window: NSWindow?
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        popup.addItems(withTitles: names)
        alert.accessoryView = popup
        let response = runAlert(alert, in: window)
        guard response == .alertFirstButtonReturn,
              let chosen = popup.titleOfSelectedItem else { return nil }
        return chosen
    }

    /// Shows a brief "no saved views yet" notice (Restore/Delete with an empty table).
    private static func showNoViewsNotice(in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "No Saved Views"
        alert.informativeText = "Save a view first with View ▸ Save View…"
        alert.addButton(withTitle: "OK")
        _ = runAlert(alert, in: window)
    }

    /// Runs an alert as a sheet on `window` (falling back to a modal run when there
    /// is no window), returning the user's response. Sheets are run via a nested run
    /// loop so this stays a synchronous helper matching the responder-chain handlers.
    private static func runAlert(_ alert: NSAlert, in window: NSWindow?) -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        // Present as a sheet but run a nested modal loop so this stays synchronous
        // (matching the responder-chain handlers). The completion stops the nested
        // loop with the user's response, which `runModal(for:)` then returns.
        alert.beginSheetModal(for: window) { response in
            NSApp.stopModal(withCode: response)
        }
        return NSApp.runModal(for: alert.window)
    }
}
