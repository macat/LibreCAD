//
//  CurrentPropertiesBar.swift
//  LibreCADmacOS
//
//  The PERSISTENT current-properties bar — AutoCAD's "Properties" panel trio
//  (CLAYER + CECOLOR / CELTYPE / CELWEIGHT). A slim, ALWAYS-VISIBLE horizontal strip
//  pinned under the toolbar that shows, and lets the user SET, the attributes NEW
//  geometry will adopt: the active layer, and the current pen's color / line type /
//  line width. Unlike `ToolOptionsBar` (which is CONTEXTUAL and collapses to nothing
//  when the active tool has no options), this bar is always on — the current
//  properties apply to every draw tool, so the control must never disappear.
//
//  ## One source of truth: CanvasModel
//  The pen controls bind to `model.currentPen` (the Stage-1 view-policy field that
//  `CanvasModel.applyCommit` stamps onto freshly-drawn geometry). The layer picker
//  reads/writes the drawing's ACTIVE layer through the undoable `setActiveLayer`. Each
//  pen control defaults to "By Layer", so out of the box new geometry inherits
//  everything from its layer (the LibreCAD/AutoCAD default). Setting a value here does
//  NOT touch existing entities — it only changes what the NEXT drawn entity adopts.
//
//  The line-type / line-width pickers are the shared `PenPickers.swift` views, so this
//  bar and the Layers sidebar offer the exact same vocabulary.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The always-visible current-properties bar. Renders the active-layer picker + the
/// current pen's color / line type / width as one horizontal row.
struct CurrentPropertiesBar: View {
    /// The live canvas model — the single source of truth for the current pen and the
    /// active layer.
    @Bindable var model: CanvasModel
    /// The host controller box, so a change can nudge the canvas to redraw (a current-
    /// properties change does not alter existing geometry, but a redraw keeps any
    /// dependent chrome in step and is cheap/idempotent).
    let controllerBox: CADCanvasView.ControllerBox

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            Label("Current", systemImage: "paintpalette")
                .font(DS.Font.barLabel)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            Divider().frame(height: DS.Size.barDivider)

            captioned("Layer") { layerControl }

            Divider().frame(height: DS.Size.barDivider)

            // Each of the three pen controls SELF-IDENTIFIES (§3b — they were three
            // identical "By Layer" dropdowns): Color carries the swatch + mode word,
            // Type a leading dash preview, Width a leading weight-bar preview, each
            // under a micro-caption. All four controls share the `DS.Field.wide` width.
            captioned("Color") { colorControl }
            captioned("Type")  { typeControl }
            captioned("Width") { widthControl }

            Spacer(minLength: 0)
        }
        .barStrip()
    }

    /// Wraps a control with a small `DS.Font.secondaryLabel` micro-caption above it, so
    /// the three look-alike "By Layer" pickers each announce what they set.
    @ViewBuilder
    private func captioned<Content: View>(_ caption: String,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(caption)
                .font(DS.Font.secondaryLabel)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Active-layer quick picker (CLAYER)

    /// A compact picker over the drawing's layer names, bound to the ACTIVE layer.
    /// Selecting one activates it (undoable) so the next drawn entity lands there.
    @ViewBuilder
    private var layerControl: some View {
        Picker("Layer", selection: activeLayerBinding) {
            ForEach(model.drawing.layers.layers) { layer in
                Text(layer.name).tag(layer.name)
            }
        }
        .labelsHidden()
        .frame(width: DS.Field.wide)
        .help("Active layer — new geometry is drawn on this layer")
    }

    private var activeLayerBinding: Binding<String> {
        Binding(
            get: { model.drawing.layers.activeLayerName },
            set: { name in
                // Route through the SINGLE active-layer path (`makeLayerCurrent`): the W3B
                // undoable funnel that bumps `modelVersion` — matching the Layers sidebar /
                // gear-menu "Make Current" rather than poking `setActiveLayer` directly. The
                // funnel no-ops when `name` is already current.
                if model.makeLayerCurrent(name) {
                    controllerBox.controller?.requestRedraw()
                }
            }
        )
    }

    // MARK: - Current pen color (CECOLOR)

    /// The color control: a leading 16pt swatch (only meaningful when Explicit) plus a
    /// "By Layer / By Block / Explicit" mode menu. The swatch is the visual identifier
    /// that distinguishes this from the type/width pickers. Writes to
    /// `model.currentPen.lineColor`.
    @ViewBuilder
    private var colorControl: some View {
        HStack(spacing: DS.Space.sm) {
            if case .explicit = model.currentPen.lineColor {
                // A SMALL 16pt chip (ColorSwatchPicker), not the stock ~44×22pt
                // NSColorWell pill — it opens the real ColorPicker in a popover and
                // writes through the SAME `explicitColorBinding` (undo path unchanged).
                ColorSwatchPicker(color: explicitColorBinding,
                                  help: "Current explicit pen color")
            }
            Picker("Color", selection: colorModeBinding) {
                Text("By Layer").tag(PenColorMode.byLayer)
                Text("By Block").tag(PenColorMode.byBlock)
                Text("Explicit").tag(PenColorMode.explicit)
            }
            .labelsHidden()
            .help("Current pen color mode")
        }
        .frame(width: DS.Field.wide)
    }

    /// The line-TYPE control: the shared `LineTypePicker` (its rows now carry dash
    /// previews) sized to the shared field width. Its leading preview reads like the
    /// dash pattern, distinguishing it from the color/width controls (§3b).
    @ViewBuilder
    private var typeControl: some View {
        LineTypePicker(selection: lineTypeBinding, label: "")
            .labelsHidden()
            .frame(width: DS.Field.wide)
            .help("Current line type (By Layer = inherit from the layer)")
    }

    /// The line-WIDTH control: the shared `LineWidthPicker` (its rows now carry
    /// weight-bar previews) sized to the shared field width.
    @ViewBuilder
    private var widthControl: some View {
        LineWidthPicker(selection: lineWidthBinding, label: "")
            .labelsHidden()
            .frame(width: DS.Field.wide)
            .help("Current line width (By Layer = inherit from the layer)")
    }

    /// Pen color mode (the sentinels vs an explicit color).
    private enum PenColorMode: Hashable { case byLayer, byBlock, explicit }

    private var colorModeBinding: Binding<PenColorMode> {
        Binding(
            get: {
                switch model.currentPen.lineColor {
                case .byLayer:  return .byLayer
                case .byBlock:  return .byBlock
                case .explicit: return .explicit
                }
            },
            set: { mode in
                switch mode {
                case .byLayer:  model.currentPen.lineColor = .byLayer
                case .byBlock:  model.currentPen.lineColor = .byBlock
                case .explicit:
                    // Preserve any prior explicit color; default to black on first switch.
                    if case .explicit = model.currentPen.lineColor { break }
                    model.currentPen.lineColor = .explicit(.black)
                }
                controllerBox.controller?.requestRedraw()
            }
        )
    }

    private var explicitColorBinding: Binding<Color> {
        Binding(
            get: {
                if case .explicit(let rgba) = model.currentPen.lineColor {
                    return Color(rgba: rgba)
                }
                return .black
            },
            set: { newColor in
                model.currentPen.lineColor = .explicit(newColor.rgbaColor)
                controllerBox.controller?.requestRedraw()
            }
        )
    }

    // MARK: - Current pen line type / width (CELTYPE / CELWEIGHT)

    private var lineTypeBinding: Binding<PenLineType> {
        Binding(
            get: { model.currentPen.lineType },
            set: {
                guard $0 != model.currentPen.lineType else { return }
                model.currentPen.lineType = $0
                controllerBox.controller?.requestRedraw()
            }
        )
    }

    private var lineWidthBinding: Binding<PenLineWidth> {
        Binding(
            get: { model.currentPen.lineWidth },
            set: {
                guard $0 != model.currentPen.lineWidth else { return }
                model.currentPen.lineWidth = $0
                controllerBox.controller?.requestRedraw()
            }
        )
    }
}
