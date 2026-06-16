//
//  ColorSwatchPicker.swift
//  LibreCADmacOS
//
//  A SMALL color swatch that presents a SwiftUI `ColorPicker` in a popover — the
//  compact replacement for the stock `ColorPicker(...).labelsHidden()` in DENSE
//  bars (the layer-row color well, the current-pen color well).
//
//  ## Why this exists
//  `ColorPicker("", selection:…).labelsHidden().frame(width:…)` renders AppKit's
//  `NSColorWell`, which enforces its OWN intrinsic ~44×22pt rounded-pill size and
//  IGNORES `.frame(width:)`. In a tight sidebar row that pill is far too big and
//  visually dominates. The stock control cannot be shrunk, so dense sites use this
//  swatch-button instead: a 16×16 rounded chip that, on tap, opens the real
//  `ColorPicker` in a popover. The popover's picker still drives the same
//  `Binding<Color>`, so the model wiring / undo path the caller already has is
//  untouched — only the on-screen control changes.
//
//  This is intentionally NOT used in full-width grouped-Form value rows (the
//  Inspector / App Settings), where the labelled stock well reads correctly.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI

/// A compact tappable color chip that presents a `ColorPicker` in a popover. Drop-in
/// for `ColorPicker("", selection: $c, supportsOpacity: false).labelsHidden().frame(width:)`
/// in dense bars — the bound `Color` is edited identically (so any caller `onChange` /
/// callback still fires), only smaller.
struct ColorSwatchPicker: View {
    /// The bound color — edited by the popover's `ColorPicker`, exactly as the stock
    /// well would have edited it (so the caller's existing wiring/undo path is intact).
    @Binding var color: Color
    /// Whether the popover picker exposes an opacity slider (dense bars pass `false`).
    var supportsOpacity: Bool = false
    /// Help tooltip on the swatch (the caller's existing `.help(...)` string).
    var help: String = "Color"

    /// Drives the popover that hosts the real `ColorPicker`.
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            // NOTE: the literal 16 / 3 / 0.5 metrics below are intentional for now —
            // they will migrate to a shared design-token file in a later wave.
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ColorPicker("Color", selection: $color, supportsOpacity: supportsOpacity)
                .labelsHidden()
                .padding(12)
        }
    }
}
