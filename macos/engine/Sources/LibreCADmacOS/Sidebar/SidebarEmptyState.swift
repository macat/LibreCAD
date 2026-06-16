//
//  SidebarEmptyState.swift
//  LibreCADmacOS
//
//  One reusable empty-state view for the sidebar panels (Layer States, Blocks,
//  Parts Library). Wave 1 of the UI redesign (see macos/docs/ui-redesign-plan.md
//  §3a "Three different empty states") DEFINES it; the sidebar panels CONSUME it
//  in Wave 2. All metrics/typography route through the shared `DS` token layer.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI

/// A centered, low-emphasis empty-state for a sidebar panel: an SF Symbol, a
/// title, and an optional call-to-action link. Use one of these everywhere a
/// sidebar panel has nothing to show, so the empty states stop drifting.
struct SidebarEmptyState: View {
    /// SF Symbol name shown above the title.
    let icon: String
    /// Short description of the empty state (e.g. "No blocks defined").
    let title: String
    /// Optional call-to-action: a link-styled button under the title.
    var cta: (label: String, action: () -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(DS.Font.rowLabel)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let cta {
                Button(cta.label, action: cta.action)
                    .buttonStyle(.link)
                    .font(DS.Font.hint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.lg)
    }
}
