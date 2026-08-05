//
//  ToolBarHost.swift
//  LibreCADmacOS
//
//  Wave 4 Phase 2 — ContentView decomposition. Owns the grouped tool
//  toolbar (macOS-HIG) plus the ToolGroup/ToolCatalog single source of
//  truth. ContentView composes this as a ToolbarContent so its body
//  stays <150 and observation is scoped to toolbar-used slices.
//
//  GPLv2-or-later.
//

import SwiftUI
import CADEngine

// MARK: - ToolBarHost (grouped toolbar)

///
/// The grouped tool toolbar (macOS-HIG). Hosted by ContentView's
/// `.toolbar { ToolBarHost(...) }` so the orchestrator stays thin.
/// Each group renders its PINNED tools as buttons plus a ▾ overflow
/// Menu carrying the whole group (so every tool stays reachable).
/// Small per-group helpers keep the type-checker cheap.
///
struct ToolBarHost: ToolbarContent {
    @Bindable var model: CanvasModel
    let controllerBox: CADCanvasView.ControllerBox
    @Binding var pinnedToolsRaw: String
    @Binding var showInspector: Bool
    let onImage: () -> Void
    let onCreateBlock: () -> Void

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        principalTools
        inspectorTools
    }

    @ToolbarContentBuilder
    private var principalTools: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            toolButton(.select)
            Divider()
            groupSection(.draw)
            Divider()
            groupSection(.modify)
            Divider()
            groupSection(.annotate)
        }
    }

    @ToolbarContentBuilder
    private var inspectorTools: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                _ = model.loadPaintBrushFromSelection()
            } label: {
                Label("Match Properties", systemImage: "eyedropper")
            }
            .help("Match Properties — pick up the selected object's properties (⌘⇧C), then apply to a new selection (⌘⇧V)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the Inspector")
        }
    }

    // MARK: Group helpers — each <150, verbatim from ContentView

    @ViewBuilder
    private func groupSection(_ group: ToolGroup) -> some View {
        ForEach(pinnedTools(in: group), id: \.self) { kind in
            pinnedButton(kind, in: group)
        }
        groupOverflowMenu(group)
    }

    @ViewBuilder
    private func pinnedButton(_ kind: ToolKind, in group: ToolGroup) -> some View {
        if let flyout = ToolCatalog.flyout(for: kind) {
            drawFlyoutButton(flyout)
        } else {
            toolButton(kind)
        }
    }

    @ViewBuilder
    private func groupOverflowMenu(_ group: ToolGroup) -> some View {
        Menu {
            ForEach(ToolCatalog.tools(in: group), id: \.self) { kind in
                overflowEntry(kind)
            }
        } label: {
            Label(group.title, systemImage: group.symbol)
        }
        .menuIndicator(.visible)
        .help("\(group.title) tools — click to activate or pin to the toolbar")
    }

    @ViewBuilder
    private func overflowEntry(_ kind: ToolKind) -> some View {
        let meta = ToolCatalog.metadata(for: kind)
        Menu {
            Button("Use \(kind.title)") { activate(kind) }
            Divider()
            Toggle("Show in Toolbar", isOn: pinBinding(kind))
        } label: {
            Label("\(kind.title)\(meta.shortcut.map { "  (\($0))" } ?? "")",
                  systemImage: meta.symbol)
        }
    }

    @ViewBuilder
    private func toolButton(_ kind: ToolKind) -> some View {
        let meta = ToolCatalog.metadata(for: kind)
        Button {
            activate(kind)
        } label: {
            Label(kind.title, systemImage: meta.symbol)
        }
        .help(meta.help)
        .background(activeBadge(kind))
    }

    @ViewBuilder
    private func activeBadge(_ kind: ToolKind) -> some View {
        if model.activeToolKind == kind {
            RoundedRectangle(cornerRadius: DS.Radius.selection).fill(DS.Palette.selectionFill)
        }
    }

    // MARK: Flyouts

    @ViewBuilder
    private func drawFlyoutButton(_ flyout: ToolCatalog.Flyout) -> some View {
        let meta = ToolCatalog.metadata(for: flyout.primary)
        Menu {
            ForEach(flyout.variants, id: \.self) { variant in
                flyoutVariantRow(variant)
            }
        } label: {
            Label(flyoutLabelTitle(flyout), systemImage: meta.symbol)
        } primaryAction: {
            activate(flyout.primary)
        }
        .menuIndicator(.visible)
        .help("\(flyout.primary.title) — click to draw; hold for variants")
        .background(activeBadge(flyout.primary))
    }

    @ViewBuilder
    private func flyoutVariantRow(_ variant: ToolCatalog.FlyoutVariant) -> some View {
        Button {
            activateVariant(variant)
        } label: {
            Label(ToolCatalog.variantTitle(variant),
                  systemImage: isActiveVariant(variant) ? "checkmark"
                                                        : ToolCatalog.variantSymbol(variant))
        }
    }

    private func flyoutLabelTitle(_ flyout: ToolCatalog.Flyout) -> String {
        if let active = flyout.variants.first(where: { isActiveVariant($0) }) {
            switch active {
            case .kind(let k):     return k.title
            case .circleMode, .arcMode, .splineMode, .divideStyle, .scaleMode:
                return "\(flyout.primary.title) · \(ToolCatalog.variantTitle(active))"
            }
        }
        return flyout.primary.title
    }

    private func activateVariant(_ variant: ToolCatalog.FlyoutVariant) {
        switch variant {
        case .kind(let k):
            activate(k)
        case .circleMode(let mode):
            model.circleConstructionMode = mode
            controllerBox.controller?.activateTool(.circle)
        case .arcMode(let mode):
            model.arcMode = mode
            controllerBox.controller?.activateTool(.arc)
        case .splineMode(let mode):
            model.splineMode = mode
            controllerBox.controller?.activateTool(.spline)
        case .divideStyle(let index):
            model.divideModeStyle = index
            controllerBox.controller?.activateTool(.divide)
        case .scaleMode(let mode):
            model.scaleMode = mode
            controllerBox.controller?.activateTool(.scale)
        }
    }

    private func isActiveVariant(_ variant: ToolCatalog.FlyoutVariant) -> Bool {
        switch variant {
        case .kind(let k):
            return model.activeToolKind == k
        case .circleMode(let mode):
            return model.activeToolKind == .circle && model.circleConstructionMode == mode
        case .arcMode(let mode):
            return model.activeToolKind == .arc && model.arcMode == mode
        case .splineMode(let mode):
            return model.activeToolKind == .spline && model.splineMode == mode
        case .divideStyle(let index):
            return model.activeToolKind == .divide && model.divideModeStyle == index
        case .scaleMode(let mode):
            return model.activeToolKind == .scale && model.scaleMode == mode
        }
    }

    private func activate(_ kind: ToolKind) {
        switch kind {
        case .image:       onImage()
        case .createBlock: onCreateBlock()
        default:           controllerBox.controller?.activateTool(kind)
        }
    }

    // MARK: Pinned customization

    private var pinnedToolsSet: Set<ToolKind> {
        guard pinnedToolsRaw.hasPrefix(Self.pinnedSentinel) else {
            return ToolCatalog.defaultPrimary
        }
        let body = String(pinnedToolsRaw.dropFirst(Self.pinnedSentinel.count))
        let kinds = body.split(separator: ",").compactMap { ToolKind(rawValue: String($0)) }
        return Set(kinds)
    }

    private static let pinnedSentinel = "•"

    private func pinnedTools(in group: ToolGroup) -> [ToolKind] {
        let pinned = pinnedToolsSet
        return ToolCatalog.tools(in: group).filter { pinned.contains($0) }
    }

    private func pinBinding(_ kind: ToolKind) -> Binding<Bool> {
        Binding(
            get: { pinnedToolsSet.contains(kind) },
            set: { isOn in
                var set = pinnedToolsSet
                if isOn { set.insert(kind) } else { set.remove(kind) }
                let ordered = ToolCatalog.allGroupedTools.filter { set.contains($0) }
                pinnedToolsRaw = Self.pinnedSentinel + ordered.map(\.rawValue).joined(separator: ",")
            }
        )
    }
}

// MARK: - Tool grouping catalog (single source of truth)

/// The three macOS-HIG toolbar/menu groups every drawing tool falls into.
enum ToolGroup: String, CaseIterable, Sendable {
    case draw
    case modify
    case annotate

    var title: String {
        switch self {
        case .draw:     return "Draw"
        case .modify:   return "Modify"
        case .annotate: return "Annotate"
        }
    }

    var symbol: String {
        switch self {
        case .draw:     return "pencil.tip.crop.circle"
        case .modify:   return "slider.horizontal.3"
        case .annotate: return "text.bubble"
        }
    }
}

enum ToolCatalog {
    struct Metadata {
        let symbol: String
        let help: String
        let shortcut: String?
    }

    static func group(for kind: ToolKind) -> ToolGroup? {
        for group in ToolGroup.allCases where tools(in: group).contains(kind) {
            return group
        }
        return nil
    }

    static func tools(in group: ToolGroup) -> [ToolKind] {
        switch group {
        case .draw:     return drawTools
        case .modify:   return modifyTools
        case .annotate: return annotateTools
        }
    }

    static var allGroupedTools: [ToolKind] {
        drawTools + modifyTools + annotateTools
    }

    static let defaultPrimary: Set<ToolKind> = [
        .line, .circle, .arc, .rectangle, .polyline,
        .move, .copy, .rotate, .scale, .trim, .offset,
        .text, .linearDim, .leader, .multileader,
    ]

    // MARK: Draw flyouts

    enum FlyoutVariant: Hashable {
        case kind(ToolKind)
        case circleMode(CircleConstructionMode)
        case arcMode(ArcCreationMode)
        case splineMode(SplineMode)
        case divideStyle(Int)
        case scaleMode(ScaleTool.ScaleMode)
    }

    struct Flyout: Identifiable {
        let primary: ToolKind
        let variants: [FlyoutVariant]
        var id: ToolKind { primary }
    }

    static let drawFlyouts: [Flyout] = [
        Flyout(primary: .line, variants: [.kind(.xline), .kind(.ray), .kind(.lineConstruction)]),
        Flyout(primary: .circle, variants: [
            .circleMode(.centerRadius), .circleMode(.twoPoint), .circleMode(.threePoint),
            .circleMode(.tanTanRadius), .circleMode(.tanTanTan), .circleMode(.fromArc),
        ]),
        Flyout(primary: .arc, variants: [
            .arcMode(.centerStartEnd), .arcMode(.threePoint), .arcMode(.tangential),
        ]),
        Flyout(primary: .rectangle, variants: [.kind(.polygon)]),
        Flyout(primary: .spline, variants: [
            .splineMode(.fit), .splineMode(.controlPoints),
        ]),
    ]

    static let modifyFlyouts: [Flyout] = [
        Flyout(primary: .divide, variants: [.divideStyle(0), .divideStyle(1)]),
        Flyout(primary: .scale, variants: [.scaleMode(.factor), .scaleMode(.nonUniform)]),
    ]

    static var allFlyouts: [Flyout] { drawFlyouts + modifyFlyouts }

    static func flyout(for kind: ToolKind) -> Flyout? {
        allFlyouts.first { $0.primary == kind }
    }

    static func variantTitle(_ variant: FlyoutVariant) -> String {
        switch variant {
        case .kind(let k):           return k.title
        case .circleMode(let m):     return circleModeTitle(m)
        case .arcMode(let m):        return arcModeTitle(m)
        case .splineMode(let m):     return splineModeTitle(m)
        case .divideStyle(let i):    return divideStyleTitle(i)
        case .scaleMode(let m):      return scaleModeTitle(m)
        }
    }

    static func variantSymbol(_ variant: FlyoutVariant) -> String {
        switch variant {
        case .kind(let k):       return metadata(for: k).symbol
        case .circleMode:        return "circle"
        case .arcMode:           return "point.topleft.down.to.point.bottomright.curvepath"
        case .splineMode:        return "scribble.variable"
        case .divideStyle(let i): return i == 1 ? "ruler" : "number"
        case .scaleMode(let m):  return m == .nonUniform
                                        ? "arrow.up.left.and.arrow.down.right"
                                        : "arrow.up.left.and.down.right.magnifyingglass"
        }
    }

    static func circleModeTitle(_ mode: CircleConstructionMode) -> String {
        switch mode {
        case .centerRadius: return "Center, Radius"
        case .twoPoint:     return "2 Points"
        case .threePoint:   return "3 Points"
        case .tanTanRadius: return "Tan, Tan, Radius"
        case .tanTanTan:    return "Tan, Tan, Tan"
        case .fromArc:      return "From Arc"
        }
    }

    static func arcModeTitle(_ mode: ArcCreationMode) -> String {
        switch mode {
        case .centerStartEnd: return "Center, Start, End"
        case .threePoint:     return "3 Points"
        case .tangential:     return "Tangential"
        }
    }

    static func splineModeTitle(_ mode: SplineMode) -> String {
        switch mode {
        case .fit:           return "Fit Points"
        case .controlPoints: return "Control Points"
        }
    }

    static func divideStyleTitle(_ index: Int) -> String {
        index == 1 ? "By Length" : "By Number"
    }

    static func scaleModeTitle(_ mode: ScaleTool.ScaleMode) -> String {
        switch mode {
        case .factor:     return "Uniform"
        case .reference:  return "By Reference"
        case .nonUniform: return "Non-uniform X/Y"
        }
    }

    private static let drawTools: [ToolKind] = [
        .line, .circle, .arc, .rectangle, .polyline, .point,
        .ellipse, .polygon, .spline, .hatch, .image,
        .xline, .ray, .insert, .viewport,
        .wipeout, .mline, .table,
    ]

    private static let modifyTools: [ToolKind] = [
        .move, .copy, .offset, .rotate, .scale, .mirror,
        .array, .arrayPath, .divide, .explode, .stretch, .lengthen, .break,
        .trim, .extend, .fillet, .chamfer,
        .polylineEdit, .join, .explodeText, .align,
        .createBlock, .explodeInsert,
        .lineConstruction,
    ]

    private static let annotateTools: [ToolKind] = [
        .text,
        .linearDim, .alignedDim, .radialDim, .diameterDim, .angularDim,
        .ordinateDim, .arcLengthDim, .angular3pDim,
        .leader, .multileader, .baselineDim, .continueDim,
        .measureDistance, .measureAngle, .measureArea, .measureLength,
        .revcloud,
    ]

    static func metadata(for kind: ToolKind) -> Metadata {
        switch kind {
        case .select:    return .init(symbol: "cursorarrow", help: "Select / pan (V)", shortcut: "V")
        case .line:      return .init(symbol: "line.diagonal", help: "Draw line (L)", shortcut: "L")
        case .circle:    return .init(symbol: "circle", help: "Draw circle (C)", shortcut: "C")
        case .arc:       return .init(symbol: "point.topleft.down.to.point.bottomright.curvepath", help: "Draw arc (A)", shortcut: "A")
        case .rectangle: return .init(symbol: "rectangle", help: "Draw rectangle (R)", shortcut: "R")
        case .polyline:  return .init(symbol: "scribble", help: "Draw polyline (P)", shortcut: "P")
        case .point:     return .init(symbol: "smallcircle.filled.circle", help: "Place point (O)", shortcut: "O")
        case .ellipse:   return .init(symbol: "oval", help: "Draw ellipse (E)", shortcut: "E")
        case .polygon:   return .init(symbol: "hexagon", help: "Draw polygon (G)", shortcut: "G")
        case .spline:    return .init(symbol: "scribble.variable", help: "Draw spline (S)", shortcut: "S")
        case .hatch:     return .init(symbol: "square.grid.2x2.fill", help: "Hatch fill selection (H)", shortcut: "H")
        case .image:     return .init(symbol: "photo", help: "Place image — pick a file, then click two corners (⇧Y)", shortcut: "⇧Y")
        case .xline:     return .init(symbol: "line.diagonal.arrow", help: "Construction line — infinite (⌥I)", shortcut: "⌥I")
        case .ray:       return .init(symbol: "arrow.up.right", help: "Ray — semi-infinite construction line (⌥Y)", shortcut: "⌥Y")
        case .insert:    return .init(symbol: "square.on.square.dashed", help: "Insert block (⇧I)", shortcut: "⇧I")
        case .move:      return .init(symbol: "arrow.up.and.down.and.arrow.left.and.right", help: "Move selection (M)", shortcut: "M")
        case .copy:      return .init(symbol: "plus.square.on.square", help: "Copy selection (⇧C)", shortcut: "⇧C")
        case .offset:    return .init(symbol: "plus.rectangle.on.rectangle", help: "Offset selection (⇧O)", shortcut: "⇧O")
        case .rotate:    return .init(symbol: "rotate.right", help: "Rotate selection (⇧R)", shortcut: "⇧R")
        case .scale:     return .init(symbol: "square.resize", help: "Scale selection (⇧S)", shortcut: "⇧S")
        case .mirror:    return .init(symbol: "flip.horizontal", help: "Mirror selection (⇧M)", shortcut: "⇧M")
        case .array:     return .init(symbol: "square.grid.3x3", help: "Array selection (⇧A)", shortcut: "⇧A")
        case .arrayPath: return .init(symbol: "point.topleft.down.to.point.bottomright.curvepath", help: "Array selection along a path (⌥P)", shortcut: "⌥P")
        case .divide:    return .init(symbol: "divide", help: "Divide selection (⇧D)", shortcut: "⇧D")
        case .explode:   return .init(symbol: "burst", help: "Explode selection (⇧X)", shortcut: "⇧X")
        case .stretch:   return .init(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Stretch selection (⌥S)", shortcut: "⌥S")
        case .lengthen:  return .init(symbol: "ruler", help: "Lengthen line/arc (⇧L)", shortcut: "⇧L")
        case .break:     return .init(symbol: "scissors.badge.ellipsis", help: "Break entity (⇧B)", shortcut: "⇧B")
        case .trim:      return .init(symbol: "scissors", help: "Trim to boundary (T)", shortcut: "T")
        case .extend:    return .init(symbol: "arrow.right.to.line", help: "Extend to boundary (X)", shortcut: "X")
        case .fillet:    return .init(symbol: "circle.bottomrighthalf.checkered", help: "Fillet (round) corner (F)", shortcut: "F")
        case .chamfer:   return .init(symbol: "skew", help: "Chamfer (bevel) corner (⇧F)", shortcut: "⇧F")
        case .polylineEdit: return .init(symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", help: "Edit polyline vertices (⇧P)", shortcut: "⇧P")
        case .join:      return .init(symbol: "link", help: "Join lines/arcs into a polyline (⇧J)", shortcut: "⇧J")
        case .explodeText: return .init(symbol: "character.cursor.ibeam", help: "Explode text to geometry (⇧E)", shortcut: "⇧E")
        case .align:     return .init(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Align selection to a 2-point reference (⌥A)", shortcut: "⌥A")
        case .createBlock:   return .init(symbol: "square.on.square.dashed", help: "Create block from selection (⌥B)", shortcut: "⌥B")
        case .explodeInsert: return .init(symbol: "square.split.2x2", help: "Explode block reference (⌥X)", shortcut: "⌥X")
        case .text:        return .init(symbol: "character.textbox", help: "Add text (⇧T)", shortcut: "⇧T")
        case .linearDim:   return .init(symbol: "ruler", help: "Linear dimension (D)", shortcut: "D")
        case .alignedDim:  return .init(symbol: "arrow.up.left.and.arrow.down.right", help: "Aligned dimension (I)", shortcut: "I")
        case .radialDim:   return .init(symbol: "arrow.left.and.right", help: "Radius dimension (U)", shortcut: "U")
        case .diameterDim: return .init(symbol: "circle.and.line.horizontal", help: "Diameter dimension (B)", shortcut: "B")
        case .angularDim:  return .init(symbol: "angle", help: "Angular dimension (N)", shortcut: "N")
        case .ordinateDim: return .init(symbol: "arrow.down.to.line", help: "Ordinate dimension (⌥O)", shortcut: "⌥O")
        case .arcLengthDim: return .init(symbol: "arrow.up.and.down.and.sparkles", help: "Arc length dimension (⌥G)", shortcut: "⌥G")
        case .angular3pDim: return .init(symbol: "angle", help: "Angular dimension, 3-point (⌥N)", shortcut: "⌥N")
        case .leader:      return .init(symbol: "text.bubble", help: "Leader callout (⌥L)", shortcut: "⌥L")
        case .multileader: return .init(symbol: "text.bubble.fill", help: "Multileader (MLEADER) callout (⌥M)", shortcut: "⌥M")
        case .baselineDim: return .init(symbol: "arrow.up.and.line.horizontal.and.arrow.down", help: "Baseline dimension chain (⌥D)", shortcut: "⌥D")
        case .continueDim: return .init(symbol: "arrow.left.and.line.vertical.and.arrow.right", help: "Continue dimension chain (⌥C)", shortcut: "⌥C")
        case .measureDistance: return .init(symbol: "ruler", help: "Measure distance (⇧K)", shortcut: "⇧K")
        case .measureAngle:    return .init(symbol: "angle", help: "Measure angle", shortcut: nil)
        case .measureArea:     return .init(symbol: "square.dashed", help: "Measure area + perimeter", shortcut: nil)
        case .measureLength:   return .init(symbol: "sum", help: "Total length of selection", shortcut: nil)
        case .viewport:    return .init(symbol: "rectangle.dashed", help: "Place a paper-space viewport — drag two corners on a layout sheet (⌥V)", shortcut: "⌥V")
        case .revcloud:    return .init(symbol: "cloud", help: "Revision cloud", shortcut: nil)
        case .lineConstruction: return .init(symbol: "line.diagonal", help: "Line construction (perpendicular / parallel / bisector / tangent)", shortcut: nil)
        case .wipeout:     return .init(symbol: "rectangle.slash", help: "Wipeout (mask region in the background color)", shortcut: nil)
        case .mline:       return .init(symbol: "lines.measurement.horizontal", help: "Draw multiline (parallel mitered element lines)", shortcut: nil)
        case .table:       return .init(symbol: "tablecells", help: "Insert table — click a point to place a default grid", shortcut: nil)
        }
    }
}
