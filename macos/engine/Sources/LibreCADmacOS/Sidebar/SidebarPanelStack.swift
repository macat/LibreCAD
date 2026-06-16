//
//  SidebarPanelStack.swift
//  LibreCADmacOS
//
//  The reusable container behind the modern, REARRANGEABLE left sidebar. It renders an
//  ordered list of `SidebarPanel`s as a source-list-style stack where each panel is a
//  collapsible disclosure section: a header (chevron + SF-Symbol icon + title + a
//  trailing header-action slot) over its body. The ORDER, the COLLAPSED set, and the
//  HIDDEN set all live in a single `SidebarLayoutConfig` value (persisted by the host
//  via `@AppStorage`); this view is a pure function of that config + the panels.
//
//  Behaviors:
//    • collapse/expand a panel (per-panel disclosure chevron — Stage 1);
//    • drag-to-reorder the panels (a List with `.onMove`, native source-list feel —
//      Stage 2);
//    • show/hide panels via the top "Customize…" (⋯) menu — Stage 2;
//  with every change written straight back through the `config` binding so the host
//  persists it.
//
//  EXTENSIBILITY: a host adds a panel by appending ONE `SidebarPanel` descriptor (id +
//  title + symbol + a header-actions `@ViewBuilder` + a body `@ViewBuilder`) and a
//  `SidebarPanelID` case. The stack and `SidebarLayoutConfig.reconciled` absorb it
//  automatically (it appears at the end, visible + expanded, on first run).
//
//  Decomposed into small `@ViewBuilder` subviews on purpose: a monolithic body over a
//  list of mixed-content panels trips the SwiftUI "unable to type-check in reasonable
//  time" trap (project gotcha #2).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI

// MARK: - Panel descriptor

/// One panel in the stack: its stable identity plus the content the host supplies for
/// its header trailing-actions slot and its body. The label (title/symbol) defaults
/// from the id but can be overridden. `header` and `body` are type-erased so a single
/// `[SidebarPanel]` array can carry heterogeneous panels (layers vs. blocks vs. …).
struct SidebarPanel: Identifiable {
    let id: SidebarPanelID
    let title: String
    let symbol: String
    /// The trailing controls shown in this panel's header (e.g. ＋ / − / ⋯). Built by
    /// the host; relocating buttons into the header is the whole point of the redesign.
    let header: AnyView
    /// This panel's content, shown when the panel is expanded.
    let body: AnyView

    init<Header: View, Body: View>(
        id: SidebarPanelID,
        title: String? = nil,
        symbol: String? = nil,
        @ViewBuilder header: () -> Header,
        @ViewBuilder body: () -> Body
    ) {
        self.id = id
        self.title = title ?? id.defaultTitle
        self.symbol = symbol ?? id.defaultSymbol
        self.header = AnyView(header())
        self.body = AnyView(body())
    }
}

// MARK: - The stack container

/// Renders `panels` in the order/visibility/collapse dictated by `config`, with native
/// source-list styling. Mutations (collapse, reorder, show/hide) write back through the
/// `config` binding so the host persists them via `@AppStorage`.
struct SidebarPanelStack: View {
    /// The panels available in THIS build, keyed by id. The render order comes from
    /// `config.visibleOrder`, not this array's order, so the host can pass them in any
    /// order. A missing descriptor for an id in the order is skipped gracefully.
    let panels: [SidebarPanel]
    /// The persisted layout state (order / collapsed / hidden). Two-way so this view
    /// can mutate it; the host owns the durable `@AppStorage` mirror.
    @Binding var config: SidebarLayoutConfig

    /// Fast lookup from id → descriptor.
    private var byID: [SidebarPanelID: SidebarPanel] {
        Dictionary(panels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        List {
            ForEach(Array(orderedVisiblePanels.enumerated()), id: \.element.id) { index, panel in
                // The Customize (show/hide) menu rides in the FIRST panel header's
                // trailing actions instead of a dedicated top band — that empty "tune"
                // row is gone (plan §3a). A first panel always exists whenever `order` is
                // non-empty: `reconciled` enforces a ZERO-VISIBLE FLOOR (it un-hides the
                // first panel if a persisted config would hide them all), and
                // `orderedVisiblePanels` below falls back to `order.first` as a final
                // backstop — so the customize entry never becomes unreachable.
                panelSection(panel, isFirst: index == 0)
            }
            .onMove(perform: movePanels)
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, DS.Size.listRowMin)
    }

    // MARK: Ordered, visible panels

    /// The descriptors to render, in the config's visible order (hidden panels dropped,
    /// ids without a descriptor skipped).
    ///
    /// Belt-and-suspenders backstop to the config-layer ZERO-VISIBLE FLOOR: if the visible
    /// list resolves to EMPTY while the config still has SOME ordered panel we hold a
    /// descriptor for, render `order.first` anyway. The Customize (⋯) menu lives in the
    /// first rendered panel's header, so an empty render would orphan it; this guarantees
    /// at least one header even if an all-hidden config ever slipped past reconciliation.
    private var orderedVisiblePanels: [SidebarPanel] {
        let map = byID
        let visible = config.visibleOrder.compactMap { map[$0] }
        if visible.isEmpty, let firstID = config.order.first, let firstPanel = map[firstID] {
            return [firstPanel]
        }
        return visible
    }

    // MARK: Customize (show/hide) — the ⋯ menu (now in the first panel header)

    /// The ⋯ menu: one toggle per panel (checkmark = shown), plus a "Show All" reset.
    /// Iterates the FULL order (not just visible) so a hidden panel can be re-shown.
    ///
    /// Now that this menu rides in the FIRST visible panel's header (the empty top band is
    /// gone), the LAST remaining visible panel's "hide" toggle is DISABLED — hiding it
    /// would leave zero panels, and with no first header the menu itself would become
    /// unreachable (you could never re-show anything). This keeps the customize entry
    /// always reachable without a dedicated top row (or any ContentView change).
    @ViewBuilder
    private var customizeMenu: some View {
        let onlyVisible = config.visibleOrder.count <= 1
        Menu {
            ForEach(config.order, id: \.self) { id in
                if let panel = byID[id] {
                    Toggle(isOn: hiddenBinding(id).inverted) {
                        Label(panel.title, systemImage: panel.symbol)
                    }
                    // Don't let the user hide the last visible panel (would orphan this menu).
                    .disabled(onlyVisible && !config.isHidden(id))
                }
            }
            Divider()
            Button("Show All Panels") {
                config = config.settingAllHidden(false)
            }
            .disabled(config.hidden.isEmpty)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Customize which panels appear, and drag a panel's header to reorder")
    }

    // MARK: One panel section (collapsible header over body)

    /// A single panel as a `Section` whose header is the disclosure row and whose
    /// content is the panel body (shown only when expanded). `.tag(panel.id)` keeps the
    /// `ForEach`/`onMove` identity stable for drag-reorder. `isFirst` injects the
    /// Customize (show/hide) ⋯ menu into THIS panel's header (it replaced the top band).
    @ViewBuilder
    private func panelSection(_ panel: SidebarPanel, isFirst: Bool) -> some View {
        Section {
            if !config.isCollapsed(panel.id) {
                panel.body
                    // A touch of vertical breathing room around each panel's body rows.
                    .padding(.vertical, DS.Space.xs)
            }
        } header: {
            panelHeader(panel, isFirst: isFirst)
                .tag(panel.id)
        }
    }

    /// The panel header row: a tappable disclosure chevron + icon + title (toggles
    /// collapse), then the host-supplied trailing action slot (＋ / − / ⋯). On the FIRST
    /// panel the Customize ⋯ menu is appended (the relocated top-band control). The
    /// chevron + label area is one button so the whole left side toggles; the trailing
    /// slot is independent so its buttons don't also collapse the panel.
    @ViewBuilder
    private func panelHeader(_ panel: SidebarPanel, isFirst: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            disclosureLabel(panel)
            Spacer(minLength: DS.Space.xs)
            panel.header
                .buttonStyle(.borderless)
            if isFirst {
                customizeMenu
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .contentShape(Rectangle())
    }

    /// The chevron + SF-Symbol icon + title, as a single borderless toggle that flips
    /// this panel's collapsed state.
    @ViewBuilder
    private func disclosureLabel(_ panel: SidebarPanel) -> some View {
        Button {
            // Animate the collapse so the body expand/collapse matches the chevron
            // rotation (NIT 3) instead of the body popping in/out.
            withAnimation(.easeInOut(duration: 0.15)) {
                config = config.togglingCollapsed(panel.id)
            }
        } label: {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(config.isCollapsed(panel.id) ? 0 : 90))
                    .animation(.easeInOut(duration: 0.15), value: config.isCollapsed(panel.id))
                Image(systemName: panel.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: DS.Size.rowIcon, alignment: .center)
                Text(panel.title)
                    .font(DS.Font.panelTitle)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(config.isCollapsed(panel.id) ? "Expand \(panel.title)" : "Collapse \(panel.title)")
    }

    // MARK: Reorder

    /// Drag-to-reorder over the VISIBLE list → reweave into the full order (hidden
    /// panels keep their slots) and persist.
    private func movePanels(fromOffsets source: IndexSet, toOffset destination: Int) {
        config = config.movingVisible(fromOffsets: source, toOffset: destination)
    }

    // MARK: Bindings

    /// A two-way binding for whether `id` is hidden (used by the Customize toggles,
    /// inverted so the toggle reads "shown").
    private func hiddenBinding(_ id: SidebarPanelID) -> Binding<Bool> {
        Binding(
            get: { config.isHidden(id) },
            set: { config = config.settingHidden(id, $0) }
        )
    }
}

// MARK: - Small binding helper

private extension Binding where Value == Bool {
    /// The logical inverse of a `Bool` binding (so a "hidden" flag can drive a "shown"
    /// toggle without a second stored property).
    var inverted: Binding<Bool> {
        Binding(get: { !wrappedValue }, set: { wrappedValue = !$0 })
    }
}
