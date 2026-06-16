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
        HStack(spacing: 12) {
            Label("Current", systemImage: "paintpalette")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            Divider().frame(height: 16)

            layerControl

            Divider().frame(height: 16)

            colorControl
            LineTypePicker(selection: lineTypeBinding, label: "")
                .labelsHidden()
                .frame(maxWidth: 130)
                .help("Current line type (By Layer = inherit from the layer)")
            LineWidthPicker(selection: lineWidthBinding, label: "")
                .labelsHidden()
                .frame(maxWidth: 130)
                .help("Current line width (By Layer = inherit from the layer)")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
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
        .frame(maxWidth: 150)
        .help("Active layer — new geometry is drawn on this layer")
    }

    private var activeLayerBinding: Binding<String> {
        Binding(
            get: { model.drawing.layers.activeLayerName },
            set: { name in
                guard name != model.drawing.layers.activeLayerName else { return }
                model.drawing.setActiveLayer(name)
                controllerBox.controller?.requestRedraw()
            }
        )
    }

    // MARK: - Current pen color (CECOLOR)

    /// The color control: a "By Layer / By Block / Explicit" mode menu plus, when
    /// Explicit, a color well. Mirrors the Inspector's pen-color model but writes to
    /// `model.currentPen.lineColor`.
    @ViewBuilder
    private var colorControl: some View {
        HStack(spacing: 6) {
            Picker("Color", selection: colorModeBinding) {
                Text("By Layer").tag(PenColorMode.byLayer)
                Text("By Block").tag(PenColorMode.byBlock)
                Text("Explicit").tag(PenColorMode.explicit)
            }
            .labelsHidden()
            .frame(maxWidth: 110)
            .help("Current pen color mode")

            if case .explicit = model.currentPen.lineColor {
                // A SMALL 16pt chip (ColorSwatchPicker), not the stock ~44×22pt
                // NSColorWell pill — it opens the real ColorPicker in a popover and
                // writes through the SAME `explicitColorBinding` (undo path unchanged).
                ColorSwatchPicker(color: explicitColorBinding,
                                  help: "Current explicit pen color")
            }
        }
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
