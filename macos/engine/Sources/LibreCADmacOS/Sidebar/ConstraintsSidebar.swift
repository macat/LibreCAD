//
//  ConstraintsSidebar.swift
//  LibreCADmacOS
//
//  The "Constraints" sidebar panel — the GUI surface over the drawing's PARAMETRIC
//  CONSTRAINT table (the owner's ask #3: "add gui to handle them. currently they are
//  hard to find in the menu"). It lists every constraint in the active drawing grouped
//  by category (Geometric vs Dimensional), and — the HEADLINE new capability — lets the
//  user DELETE a constraint per-row (one ⌘Z restores it). Delete was previously
//  unreachable from any UI; this panel wires `model.removeConstraint(id:)` to a trash
//  button + a context-menu action.
//
//  Other affordances, each routed through an EXISTING public `CanvasModel` funnel:
//    • "Selection only" filter — show just the constraints referencing the current
//      selection (`model.constraints(for:)`), so a user can answer "which constraint is
//      this glyph?" by selecting the entity.
//    • Click-to-select — clicking a row REPLACES the selection with the entities the
//      constraint references (`model.setSelection`), which repaints the highlight + the
//      glyph overlay so the constraint's geometry lights up.
//
//  Like the other sidebar panels it is rendered as the BODY of a `SidebarPanel` in the
//  rearrangeable `SidebarPanelStack` (`LayersSidebar` supplies the header; this view the
//  content + a compact header control). It binds to the SAME live `CanvasModel` the
//  canvas renders, so a delete reflects live (the glyph overlay drops the badge) and undo
//  via ⌘Z reverts it.
//
//  ## Purity / modal discipline (project gotchas)
//  There is NO modal anywhere here — every action funnels through a pure, undoable (delete)
//  or undo-free (select) `CanvasModel` method. Nothing in this view is reachable from the
//  headless test suite; the testable LOGIC (grouping / selection-filter / row text) lives
//  in the SwiftUI-FREE `ConstraintListModel` enum below, unit-tested directly via the
//  `_SharedConstraintsSidebar.swift` symlink (the test target depends only on CADEngine).
//
//  ## Type-check discipline (project gotcha #2)
//  The body is decomposed into many small `@ViewBuilder` / `private var` subviews so
//  SwiftUI never trips the "unable to type-check in reasonable time" trap on the grouped,
//  mixed-content list.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

// NOTE: the PURE, SwiftUI-free list logic (`ConstraintListModel` — grouping, the
// selection filter, the row text, the click-to-select target) lives in the sibling
// `ConstraintListLogic.swift` so the test target can reach it via a CADEngine-only
// symlink (`_SharedConstraintListLogic.swift`). The SwiftUI views below are thin shells
// over those helpers.

// MARK: - Constraints panel header control ("Selection only" toggle)

/// The Constraints panel's header control: a compact "Selection only" filter toggle (a
/// `line.3.horizontal.decrease.circle` glyph that fills when on). A small reusable view
/// so the panel HEADER can host it; the host supplies the binding.
struct ConstraintsHeaderControls: View {
    @Binding var selectionOnly: Bool

    var body: some View {
        Button {
            selectionOnly.toggle()
        } label: {
            Image(systemName: selectionOnly
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(.borderless)
        .help(selectionOnly
              ? "Showing only constraints on the current selection — click to show all"
              : "Show only constraints on the current selection")
    }
}

// MARK: - The Constraints panel content (live)

/// The live Constraints content: the drawing's constraints grouped by category, each row
/// showing its glyph + name + reference description (+ value for dimensional kinds), with
/// per-row delete + click-to-select. Bound to the live `CanvasModel` so a delete reflects
/// live (glyph overlay drops the badge) and undo via ⌘Z reverts it.
struct ConstraintsSectionContent: View {
    @Bindable var model: CanvasModel
    /// Bridge to the canvas controller so a click-to-select can request a redraw (the
    /// renderer is on-demand; a selection change must nudge the highlight + glyph overlay).
    let controllerBox: CADCanvasView.ControllerBox
    /// Whether the "Selection only" filter is on (owned by `LayersSidebar`, surfaced in the
    /// panel header). When on, only constraints referencing the current selection show.
    let selectionOnly: Bool

    var body: some View {
        let shown = ConstraintListModel.displayed(
            model.allConstraints,
            selectionIDs: model.selection.ids,
            selectionOnly: selectionOnly)
        if shown.isEmpty {
            emptyState
        } else {
            categoryList(shown)
        }
    }

    // MARK: Empty state

    /// The empty state — distinct copy for "drawing has no constraints" vs. "selection
    /// filter matched none", so the user knows whether to draw/constrain or just clear the
    /// filter.
    @ViewBuilder
    private var emptyState: some View {
        if selectionOnly && !model.selection.ids.isEmpty {
            SidebarEmptyState(
                icon: "line.3.horizontal.decrease.circle",
                title: "No constraints on the selection")
        } else if selectionOnly {
            SidebarEmptyState(
                icon: "cursorarrow",
                title: "Select an entity to see its constraints")
        } else {
            SidebarEmptyState(
                icon: "ruler",
                title: "No constraints in this drawing")
        }
    }

    // MARK: Grouped list

    /// The constraints grouped under Geometric / Dimensional headers (a category with no
    /// rows is skipped so the panel never shows an empty header).
    @ViewBuilder
    private func categoryList(_ shown: [Constraint]) -> some View {
        ForEach(ConstraintListModel.Category.allCases) { category in
            let rows = shown.filter { ConstraintListModel.Category.of($0) == category }
            if !rows.isEmpty {
                categoryHeader(category, count: rows.count)
                ForEach(rows) { constraint in
                    ConstraintRow(
                        constraint: constraint,
                        isUnsatisfied: ConstraintListModel.isUnsatisfied(
                            constraint, unsatisfiedIDs: model.unsatisfiedConstraintIDs),
                        onSelect: { selectEntities(of: constraint) },
                        onDelete: { delete(constraint) })
                }
            }
        }
    }

    /// A small section header for a category (the title + a count badge).
    @ViewBuilder
    private func categoryHeader(_ category: ConstraintListModel.Category, count: Int) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(category.title)
                .font(DS.Font.hint)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(DS.Font.hint)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.top, DS.Space.xs)
    }

    // MARK: Actions

    /// Click-to-select: REPLACE the selection with the entities `constraint` references,
    /// then nudge the canvas to repaint the highlight + glyph overlay. A selection change
    /// is view-side state (no undo) — like the other Select verbs. No-op if it references
    /// no entity (e.g. a constraint over a since-deleted entity).
    private func selectEntities(of constraint: Constraint) {
        let target = ConstraintListModel.selectionTarget(for: constraint)
        guard !target.isEmpty else { return }
        if model.setSelection(target) {
            controllerBox.controller?.requestRedraw()
        }
    }

    /// Delete `constraint` through the undoable `model.removeConstraint(id:)` (one ⌘Z
    /// restores it), then nudge the canvas so the glyph overlay drops the badge. The
    /// model funnel already bumps `modelVersion`/`modelDirty`; we just request the redraw.
    private func delete(_ constraint: Constraint) {
        if model.removeConstraint(id: constraint.id) {
            controllerBox.controller?.requestRedraw()
        }
    }
}

// MARK: - One constraint row

/// A single constraint row: a glyph chip + the kind name, a reference description (the
/// entities / point roles it binds), the driven value for dimensional kinds, and a trailing
/// trash button. The whole row is click-to-select (selects the constraint's entities); the
/// trash button + a context menu both delete. All actions call back into the panel, which
/// routes them through the model's funnels.
private struct ConstraintRow: View {
    let constraint: Constraint
    /// Whether the geometry does NOT satisfy this constraint (its id is in the model's
    /// `unsatisfiedConstraintIDs` — a `.failed` component). Drives the warning styling so
    /// the row flags it instead of showing it as if it holds.
    let isUnsatisfied: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            glyphChip
            VStack(alignment: .leading, spacing: 1) {
                titleLine
                referenceLine
            }
            Spacer(minLength: DS.Space.xs)
            if isUnsatisfied { warningBadge }
            deleteButton
        }
        .padding(.vertical, DS.Space.xxs)
        .padding(.horizontal, DS.Space.xs)
        .contentShape(Rectangle())
        // Tap the row (outside the trash button) to select the constraint's entities.
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete Constraint", systemImage: "trash")
            }
        }
    }

    /// The terse CAD glyph (∥ / ⊥ / ↔ …) in a small monospaced chip — the same mark the
    /// on-canvas overlay draws, so the row and the badge read as the same thing.
    @ViewBuilder
    private var glyphChip: some View {
        Text(ConstraintGlyph.label(for: constraint.kind))
            .font(.callout.weight(.semibold))
            .frame(width: DS.Size.rowIcon, alignment: .center)
            // Orange when the geometry doesn't honor it (mirrors the on-canvas warning
            // badge); the normal accent otherwise.
            .foregroundStyle(isUnsatisfied ? Color.orange : DS.Palette.accent)
    }

    /// A small warning indicator shown on an UNSATISFIED row: an orange triangle with the
    /// pure `unsatisfiedNote` as its tooltip, so a constraint the geometry can't honor is
    /// visibly flagged in the list (not just on the canvas).
    @ViewBuilder
    private var warningBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(DS.Font.hint)
            .foregroundStyle(Color.orange)
            .help(ConstraintListModel.unsatisfiedNote(constraint, unsatisfiedIDs: [constraint.id])
                  ?? "This constraint is not satisfied by the geometry")
    }

    /// The kind name + (for a dimensional constraint) its driven value.
    @ViewBuilder
    private var titleLine: some View {
        HStack(spacing: DS.Space.xs) {
            Text(ConstraintListModel.displayName(for: constraint.kind))
                .font(DS.Font.rowLabel)
            if let value = ConstraintListModel.valueDescription(for: constraint) {
                Text(value)
                    .font(DS.Font.rowValue)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    /// The reference description (which entities / point roles the constraint binds).
    @ViewBuilder
    private var referenceLine: some View {
        Text(ConstraintListModel.referenceDescription(for: constraint))
            .font(DS.Font.hint)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    /// The trailing trash button — the headline new "delete" capability. `.borderless` so
    /// its tap doesn't also fire the row's select gesture.
    @ViewBuilder
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Delete this constraint (⌘Z restores it)")
    }
}
