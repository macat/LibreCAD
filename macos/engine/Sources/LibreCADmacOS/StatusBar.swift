//
//  StatusBar.swift
//  LibreCADmacOS
//
//  The persistent bottom STATUS BAR (UX-plan U3, gaps G3 / G4 / G6) — a slim,
//  always-on strip that tells the user, at a glance: what mode/tool they are in and
//  what step it expects (the verb prompt), where the cursor is (unit-aware absolute
//  X/Y + the relative offset + the live distance/angle while drawing), what the
//  cursor is snapped to, and the current zoom. It replaces the transient corner HUD
//  chips (`coordinateHUD` / `toolPromptHUD`) with a single persistent readout.
//
//  ## Layout
//    [ Tool: step — ⮐ Finish · ⌫ Undo point · esc Cancel ] … [ X / Y · @Δx,Δy · ⟂d ∠a ] … [ Snap · zoom% ]
//  Left  = `model.toolStepReadout` + always-on verb hints (so the keyboard verbs
//          are discoverable — gap G4).
//  Center= the unit-aware coordinate readouts (`model.cursorReadout` /
//          `relativeReadout` / `distanceAngleReadout`), formatted by the engine's
//          pure `CoordinateFormatter` from the document's units/precision (G6).
//  Right = the active snap mode (`model.snapReadout`) + zoom % (`model.zoomPercent`).
//
//  ## Coexistence with U1's command line
//  This bar is hosted by ContentView ABOVE the U1 command-line `safeAreaInset`
//  (added with a higher z-order / stacked inset), so the two stack cleanly: the
//  status readout sits just over the command field. It is read-only (no focus, no
//  keystrokes), so it never competes with the command line's text entry.
//
//  ## Styling (HIG, light + dark)
//  Uses the `.bar` material + semantic foreground styles so it inverts correctly in
//  both appearances, matching the command line's `.background(.bar)`. Monospaced
//  digits keep the coordinate readout from jittering as values change.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The persistent bottom status bar. Reads the live `CanvasModel` derived readouts
/// (all pure, engine-formatted) and lays them out left / center / right.
struct StatusBar: View {
    /// The live canvas state (cursor, snap, tool, viewport). Observed, so the bar
    /// updates as the cursor moves / the tool changes / the user zooms.
    let model: CanvasModel

    var body: some View {
        HStack(spacing: 12) {
            // Left: active tool + step prompt + verb hints (gap G3 / G4).
            toolSegment

            Spacer(minLength: 8)

            // Center: the unit-aware coordinate readouts (gap G6).
            coordinateSegment

            Spacer(minLength: 8)

            // Right: snap mode + zoom.
            statusSegment
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        // The bar is a read-only telemetry strip; it must never take focus or block
        // VoiceOver navigation of the canvas/command line.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Segments

    /// Active tool + current step, plus the always-on keyboard verb hints (only while
    /// a tool is active — in select mode the verbs don't apply).
    private var toolSegment: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isToolActive ? "pencil.tip" : "cursorarrow")
                .foregroundStyle(model.isToolActive ? Color.accentColor : .secondary)
            Text(model.toolStepReadout)
                .foregroundStyle(.primary)
            if model.isToolActive {
                Text("\u{23CE} Finish \u{00B7} \u{232B} Undo point \u{00B7} esc Cancel")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Absolute X/Y (unit-aware) + the relative `@Δx,Δy` and live distance/angle
    /// while a tool has placed a reference point. A neutral placeholder when the
    /// cursor is outside the canvas, so the segment never collapses to nothing.
    private var coordinateSegment: some View {
        HStack(spacing: 14) {
            if let abs = model.cursorReadout {
                Text(abs)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if let rel = model.relativeReadout {
                    Text(rel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let da = model.distanceAngleReadout {
                    Text(da)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\u{2014}")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Active snap mode + zoom percentage.
    private var statusSegment: some View {
        HStack(spacing: 14) {
            Label(model.snapReadout, systemImage: "scope")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
            Text("\(model.zoomPercent)%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Accessibility

    /// A spoken summary combining the segments (VoiceOver reads the whole bar as one
    /// element rather than fragmenting it across the readouts).
    private var accessibilitySummary: String {
        var parts: [String] = [model.toolStepReadout]
        if let abs = model.cursorReadout { parts.append(abs) }
        parts.append("Snap \(model.snapReadout)")
        parts.append("Zoom \(model.zoomPercent) percent")
        return parts.joined(separator: ", ")
    }
}
