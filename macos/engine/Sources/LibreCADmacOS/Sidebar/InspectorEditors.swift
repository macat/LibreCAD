//
//  InspectorEditors.swift
//  LibreCADmacOS
//
//  The per-section editor sub-views the Inspector composes: the common-attribute
//  editor (layer / pen color / line width), the per-kind geometry editor, the
//  TEXT/MTEXT font-and-style editor (the font-system payoff), and the
//  multi-selection common editor.
//
//  Each editor keeps LOCAL draft state seeded from the entity (re-seeded when the
//  entity id changes, or when the underlying record changes under it — e.g. undo)
//  and, on commit, builds a NEW `EntityRecord`/`EntityKind` via the pure
//  `InspectorEdits` engine helpers and hands it to its `onCommit` closure, which
//  routes through `CanvasModel`'s undoable `.replace` path. The views never touch
//  the drawing directly.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import AppKit
import CADEngine

// MARK: - Common attributes (layer / pen color / line width)

/// Edits the attributes EVERY entity has: its layer (picker), pen color, and line
/// width. Geometry-independent; shown for any single selection.
struct EntityCommonEditor: View {
    let record: EntityRecord
    let layerNames: [String]
    /// Applies a modified record list (here always a single record) — undoable.
    let onCommit: ([EntityRecord]) -> Void

    @State private var layer: String = "0"
    @State private var color: Color = .green
    @State private var widthMM: Double = 0.25

    var body: some View {
        Section("Common") {
            Picker("Layer", selection: $layer) {
                ForEach(layerNames, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: layer) { _, newValue in
                guard newValue != record.layer.name else { return }
                var r = record
                r.layer = LayerID(newValue)
                onCommit([r])
            }

            ColorPicker("Pen color", selection: $color, supportsOpacity: false)
                .onChange(of: color) { _, newColor in
                    let rgba = newColor.rgbaColor
                    var r = record
                    r.pen.lineColor = .explicit(rgba)
                    onCommit([r])
                }

            Picker("Pen color mode", selection: penColorModeBinding) {
                Text("By Layer").tag(PenColorMode.byLayer)
                Text("By Block").tag(PenColorMode.byBlock)
                Text("Explicit").tag(PenColorMode.explicit)
            }

            LabeledContent {
                TextField("Width", value: $widthMM, format: .number)
                    .frame(width: DS.Field.std).multilineTextAlignment(.trailing)
                    .onSubmit(commitWidth)
                    .onChange(of: widthMM) { _, _ in commitWidth() }
            } label: {
                Text("Line width (mm)").lineLimit(1)
            }
        }
        .onAppear(perform: seed)
        .onChange(of: record.id) { _, _ in seed() }
        .onChange(of: record.layer.name) { _, newValue in
            if layer != newValue { layer = newValue }
        }
    }

    /// Pen color mode (the `.byLayer`/`.byBlock` sentinels vs an explicit color).
    private enum PenColorMode { case byLayer, byBlock, explicit }

    private var penColorModeBinding: Binding<PenColorMode> {
        Binding(
            get: {
                switch record.pen.lineColor {
                case .byLayer:  return .byLayer
                case .byBlock:  return .byBlock
                case .explicit: return .explicit
                }
            },
            set: { mode in
                var r = record
                switch mode {
                case .byLayer:  r.pen.lineColor = .byLayer
                case .byBlock:  r.pen.lineColor = .byBlock
                case .explicit: r.pen.lineColor = .explicit(color.rgbaColor)
                }
                onCommit([r])
            }
        )
    }

    private func commitWidth() {
        var r = record
        r.pen.lineWidth = .millimeters(max(0, widthMM))
        onCommit([r])
    }

    private func seed() {
        layer = record.layer.name
        if case .explicit(let rgba) = record.pen.lineColor {
            color = Color(rgba: rgba)
        }
        if case .millimeters(let mm) = record.pen.lineWidth {
            widthMM = mm
        }
    }
}

// MARK: - Geometry (per-kind defining fields)

/// Edits the defining geometry of the selected entity, per kind. Each field
/// commits a `.replace` with the modified `EntityKind` (built by `InspectorEdits`)
/// so the edit is undoable. Kinds without an inline editor yet show a read-only
/// note rather than nothing.
struct GeometryEditor: View {
    let record: EntityRecord
    let onCommit: ([EntityRecord]) -> Void

    var body: some View {
        Section("Geometry") {
            switch record.kind {
            case .line(let d):         lineEditor(d)
            case .circle(let d):       circleEditor(d)
            case .arc(let d):          arcEditor(d)
            case .point(let d):        pointEditor(d)
            case .ellipse(let d):      ellipseEditor(d)
            case .spline(let d):       splineEditor(d)
            case .splinePoints(let d): splinePointsEditor(d)
            case .polyline(let d):     polylineEditor(d)
            case .hatch(let d):        hatchEditor(d)
            case .solid(let d):        solidEditor(d)
            case .dimension(let d):    dimensionEditor(d)
            case .insert(let d):       insertEditor(d)
            case .xline(let d):        xlineEditor(d)
            case .ray(let d):          rayEditor(d)
            case .leader(let d):       leaderEditor(d)
            case .text(let d):         textGeometryEditor(d)
            case .mtext(let d):        mtextGeometryEditor(d)
            case .image(let d):        imageGeometryEditor(d)
            }
        }
    }

    // MARK: Line

    @ViewBuilder
    private func lineEditor(_ d: LineData) -> some View {
        PointFields(label: "Start", point: d.start) { onCommit([replacing(InspectorEdits.setLineStart(record.kind, $0))]) }
        PointFields(label: "End", point: d.end) { onCommit([replacing(InspectorEdits.setLineEnd(record.kind, $0))]) }
    }

    // MARK: Circle

    @ViewBuilder
    private func circleEditor(_ d: CircleData) -> some View {
        PointFields(label: "Center", point: d.center) { onCommit([replacing(InspectorEdits.setCircleCenter(record.kind, $0))]) }
        ScalarField(label: "Radius", value: d.radius) { onCommit([replacing(InspectorEdits.setCircleRadius(record.kind, $0))]) }
    }

    // MARK: Arc

    @ViewBuilder
    private func arcEditor(_ d: ArcData) -> some View {
        PointFields(label: "Center", point: d.center) { onCommit([replacing(InspectorEdits.setArcCenter(record.kind, $0))]) }
        ScalarField(label: "Radius", value: d.radius) { onCommit([replacing(InspectorEdits.setArcRadius(record.kind, $0))]) }
        ScalarField(label: "Start angle (°)", value: d.startAngle * 180 / .pi) {
            onCommit([replacing(InspectorEdits.setArcStartAngle(record.kind, $0 * .pi / 180))])
        }
        ScalarField(label: "End angle (°)", value: d.endAngle * 180 / .pi) {
            onCommit([replacing(InspectorEdits.setArcEndAngle(record.kind, $0 * .pi / 180))])
        }
    }

    // MARK: Point

    @ViewBuilder
    private func pointEditor(_ d: PointData) -> some View {
        PointFields(label: "Position", point: d.position) { onCommit([replacing(InspectorEdits.setPointPosition(record.kind, $0))]) }
    }

    // MARK: Ellipse (center / major-axis endpoint / ratio / start+end angle)

    @ViewBuilder
    private func ellipseEditor(_ d: EllipseData) -> some View {
        PointFields(label: "Center", point: d.center) {
            onCommit([replacing(InspectorEdits.setEllipseCenter(record.kind, $0))])
        }
        PointFields(label: "Major axis (Δ)", point: d.majorP) {
            onCommit([replacing(InspectorEdits.setEllipseMajor(record.kind, $0))])
        }
        ScalarField(label: "Ratio (minor/major)", value: d.ratio) {
            onCommit([replacing(InspectorEdits.setEllipseRatio(record.kind, $0))])
        }
        ScalarField(label: "Start angle (°)", value: d.startAngle * 180 / .pi) {
            onCommit([replacing(InspectorEdits.setEllipseStartAngle(record.kind, $0 * .pi / 180))])
        }
        ScalarField(label: "End angle (°)", value: d.endAngle * 180 / .pi) {
            onCommit([replacing(InspectorEdits.setEllipseEndAngle(record.kind, $0 * .pi / 180))])
        }
    }

    // MARK: Spline (degree / closed flag / control-point count + selected point)

    @ViewBuilder
    private func splineEditor(_ d: SplineData) -> some View {
        ScalarField(label: "Degree", value: Double(d.degree)) {
            onCommit([replacing(InspectorEdits.setSplineDegree(record.kind, Int($0.rounded())))])
        }
        Toggle("Closed", isOn: Binding(
            get: { d.closed },
            set: { onCommit([replacing(InspectorEdits.setSplineClosed(record.kind, $0))]) }
        ))
        LabeledContent("Control points") {
            Text("\(d.controlPoints.count)").foregroundStyle(.secondary)
        }
        .lineLimit(1)
        IndexedPointEditor(label: "Control pt", points: d.controlPoints) { idx, pt in
            onCommit([replacing(InspectorEdits.setSplineControlPoint(record.kind, index: idx, pt))])
        }
    }

    // MARK: SplinePoints (closed flag / control-point count + selected point)

    @ViewBuilder
    private func splinePointsEditor(_ d: SplinePointsData) -> some View {
        Toggle("Closed", isOn: Binding(
            get: { d.closed },
            set: { onCommit([replacing(InspectorEdits.setSplinePointsClosed(record.kind, $0))]) }
        ))
        LabeledContent("Control points") {
            Text("\(d.controlPoints.count)").foregroundStyle(.secondary)
        }
        .lineLimit(1)
        IndexedPointEditor(label: "Control pt", points: d.controlPoints) { idx, pt in
            onCommit([replacing(InspectorEdits.setSplinePointsControlPoint(record.kind, index: idx, pt))])
        }
    }

    // MARK: Polyline (closed flag / vertex count — per-vertex editing is PolylineEditTool)

    @ViewBuilder
    private func polylineEditor(_ d: PolylineData) -> some View {
        Toggle("Closed", isOn: Binding(
            get: { d.closed },
            set: { onCommit([replacing(InspectorEdits.setPolylineClosed(record.kind, $0))]) }
        ))
        LabeledContent("Vertices") {
            Text("\(d.vertices.count)").foregroundStyle(.secondary)
        }
        .lineLimit(1)
        IndexedPointEditor(label: "Vertex", points: d.vertices.map(\.point)) { idx, pt in
            onCommit([replacing(InspectorEdits.setPolylineVertex(record.kind, index: idx, pt))])
        }
    }

    // MARK: Hatch (pattern name / scale / angle / solid flag)

    @ViewBuilder
    private func hatchEditor(_ d: HatchData) -> some View {
        LabeledContent {
            TextField("Pattern", text: Binding(
                get: { d.patternName ?? "" },
                set: { onCommit([replacing(InspectorEdits.setHatchPatternName(record.kind, $0.isEmpty ? nil : $0))]) }
            ))
            .frame(width: DS.Field.wide).multilineTextAlignment(.trailing)
        } label: {
            Text("Pattern").lineLimit(1)
        }
        Toggle("Solid fill", isOn: Binding(
            get: { d.solidFill },
            set: { onCommit([replacing(InspectorEdits.setHatchSolidFill(record.kind, $0))]) }
        ))
        ScalarField(label: "Pattern scale", value: d.patternScale) {
            onCommit([replacing(InspectorEdits.setHatchPatternScale(record.kind, $0))])
        }
        ScalarField(label: "Pattern angle (°)", value: d.patternAngle * 180 / .pi) {
            onCommit([replacing(InspectorEdits.setHatchPatternAngle(record.kind, $0 * .pi / 180))])
        }
    }

    // MARK: Solid (its corner points)

    @ViewBuilder
    private func solidEditor(_ d: SolidData) -> some View {
        ForEach(Array(d.corners.enumerated()), id: \.offset) { idx, corner in
            PointFields(label: "Corner \(idx + 1)", point: corner) {
                onCommit([replacing(InspectorEdits.setSolidCorner(record.kind, index: idx, $0))])
            }
        }
    }

    // MARK: Dimension (definition point / text override / DIMSTYLE name)

    @ViewBuilder
    private func dimensionEditor(_ d: DimData) -> some View {
        PointFields(label: "Definition pt", point: d.definitionPoint) {
            onCommit([replacing(InspectorEdits.setDimDefinitionPoint(record.kind, $0))])
        }
        LabeledContent {
            TextField("Style", text: Binding(
                get: { d.styleName ?? "" },
                set: { onCommit([replacing(InspectorEdits.setDimStyleName(record.kind, $0.isEmpty ? nil : $0))]) }
            ))
            .frame(width: DS.Field.wide).multilineTextAlignment(.trailing)
        } label: {
            Text("Dim style").lineLimit(1)
        }
        LabeledContent {
            TextField("Measured", text: Binding(
                get: { d.textOverride ?? "" },
                set: { onCommit([replacing(InspectorEdits.setDimTextOverride(record.kind, $0))]) }
            ))
            .frame(width: DS.Field.wide).multilineTextAlignment(.trailing)
        } label: {
            Text("Text override").lineLimit(1)
        }
    }

    // MARK: Insert / block reference (block name read-only / scale x,y / rotation)

    @ViewBuilder
    private func insertEditor(_ d: InsertData) -> some View {
        LabeledContent {
            Text(d.blockName.isEmpty ? "—" : d.blockName)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        } label: {
            Text("Block").lineLimit(1)
        }
        PointFields(label: "Insertion", point: d.insertionPoint) {
            onCommit([replacing(InspectorEdits.setInsertPosition(record.kind, $0))])
        }
        ScalarField(label: "Scale X", value: d.scale.x) {
            onCommit([replacing(InspectorEdits.setInsertScaleX(record.kind, $0))])
        }
        ScalarField(label: "Scale Y", value: d.scale.y) {
            onCommit([replacing(InspectorEdits.setInsertScaleY(record.kind, $0))])
        }
        ScalarField(label: "Rotation (°)", value: d.rotation * 180 / .pi) {
            onCommit([replacing(InspectorEdits.setInsertRotation(record.kind, $0 * .pi / 180))])
        }
    }

    // MARK: XLine (infinite construction line — base point + direction angle)

    @ViewBuilder
    private func xlineEditor(_ d: XLineData) -> some View {
        PointFields(label: "Base", point: d.base) {
            onCommit([replacing(InspectorEdits.setXLineBase(record.kind, $0))])
        }
        ScalarField(label: "Direction (°)", value: d.direction.angle * 180 / .pi) {
            onCommit([replacing(InspectorEdits.setXLineAngle(record.kind, $0 * .pi / 180))])
        }
    }

    // MARK: Ray (semi-infinite construction line — base point + direction angle)

    @ViewBuilder
    private func rayEditor(_ d: RayData) -> some View {
        PointFields(label: "Base", point: d.base) {
            onCommit([replacing(InspectorEdits.setRayBase(record.kind, $0))])
        }
        ScalarField(label: "Direction (°)", value: d.direction.angle * 180 / .pi) {
            onCommit([replacing(InspectorEdits.setRayAngle(record.kind, $0 * .pi / 180))])
        }
    }

    // MARK: Leader (vertex count + annotation text + arrow size/flag)

    @ViewBuilder
    private func leaderEditor(_ d: LeaderData) -> some View {
        LabeledContent("Vertices") {
            Text("\(d.vertices.count)").foregroundStyle(.secondary)
        }
        .lineLimit(1)
        Toggle("Arrowhead", isOn: Binding(
            get: { d.hasArrow },
            set: { onCommit([replacing(InspectorEdits.setLeaderHasArrow(record.kind, $0))]) }
        ))
        ScalarField(label: "Arrow size", value: d.arrowSize) {
            onCommit([replacing(InspectorEdits.setLeaderArrowSize(record.kind, $0))])
        }
        LabeledContent {
            TextField("Annotation", text: Binding(
                get: { InspectorEdits.leaderText(record.kind) },
                set: { onCommit([replacing(InspectorEdits.setLeaderText(record.kind, $0))]) }
            ))
            .frame(width: DS.Field.wide).multilineTextAlignment(.trailing)
        } label: {
            Text("Text").lineLimit(1)
        }
    }

    // MARK: Text geometry (position / height / rotation)

    @ViewBuilder
    private func textGeometryEditor(_ d: TextData) -> some View {
        PointFields(label: "Insertion", point: d.position) { onCommit([replacing(InspectorEdits.setTextPosition(record.kind, $0))]) }
        ScalarField(label: "Height", value: d.height) { onCommit([replacing(InspectorEdits.setTextHeight(record.kind, $0))]) }
        ScalarField(label: "Rotation (°)", value: d.rotation * 180 / .pi) {
            onCommit([replacing(InspectorEdits.setTextRotation(record.kind, $0 * .pi / 180))])
        }
    }

    // MARK: MText geometry (position / height / width / rotation)

    @ViewBuilder
    private func mtextGeometryEditor(_ d: MTextData) -> some View {
        PointFields(label: "Insertion", point: d.position) { onCommit([replacing(InspectorEdits.setMTextPosition(record.kind, $0))]) }
        ScalarField(label: "Height", value: d.height) { onCommit([replacing(InspectorEdits.setMTextHeight(record.kind, $0))]) }
        ScalarField(label: "Wrap width", value: d.rectWidth) { onCommit([replacing(InspectorEdits.setMTextRectWidth(record.kind, $0))]) }
        ScalarField(label: "Rotation (°)", value: d.rotation * 180 / .pi) {
            onCommit([replacing(InspectorEdits.setMTextRotation(record.kind, $0 * .pi / 180))])
        }
    }

    // MARK: Image geometry (position / size / rotation / fade / read-only path)

    @ViewBuilder
    private func imageGeometryEditor(_ d: ImageData) -> some View {
        PointFields(label: "Insertion", point: d.insertion) {
            onCommit([replacing(InspectorEdits.setImageInsertion(record.kind, $0))])
        }
        ScalarField(label: "Width", value: d.worldWidth) {
            onCommit([replacing(InspectorEdits.setImageWidth(record.kind, $0))])
        }
        ScalarField(label: "Height", value: d.worldHeight) {
            onCommit([replacing(InspectorEdits.setImageHeight(record.kind, $0))])
        }
        ScalarField(label: "Rotation (°)", value: d.rotation * 180 / .pi) {
            onCommit([replacing(InspectorEdits.setImageRotation(record.kind, $0 * .pi / 180))])
        }
        ScalarField(label: "Fade", value: Double(d.display.fade)) {
            onCommit([replacing(InspectorEdits.setImageFade(record.kind, Int($0.rounded())))])
        }
        LabeledContent {
            Text(d.imageDef.path.isEmpty ? "—" : (d.imageDef.path as NSString).lastPathComponent)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(d.imageDef.path)   // full path on hover (read-only)
        } label: {
            Text("File").lineLimit(1)
        }
    }

    /// A copy of the selected record with its geometry swapped to `kind`.
    private func replacing(_ kind: EntityKind) -> EntityRecord {
        var r = record
        r.kind = kind
        return r
    }
}

// MARK: - TEXT / MTEXT font + style editor (the font-system payoff)

/// The font/style editor for a TEXT or MTEXT entity: a font-family picker (native
/// families from the system + the document's `.lff` stroke fonts), bold/italic
/// toggles, text height, justification, width factor, and oblique angle, plus the
/// raw string. Font/bold/italic changes upsert a derived `TextStyle` and repoint
/// the entity at it (so the traits render); the rest edit `TextData`/`MTextData`
/// directly.
struct TextStyleEditor: View {
    let record: EntityRecord
    /// The `.lff` stroke font base names to offer alongside native families.
    let strokeFontNames: [String]
    /// The style the entity currently resolves to (seeds font / bold / italic).
    let resolvedStyle: TextStyle
    /// Commit a font/style change: (entity id, new kind with the new styleName,
    /// the style to upsert). Routes through `CanvasModel.applyTextStyleEdit`.
    let onStyleCommit: (EntityID, EntityKind, TextStyle?) -> Void
    /// Commit a per-entity text edit (no style table change).
    let onKindCommit: (EntityID, EntityKind) -> Void

    /// The selected font family (native family OR a "stroke:<name>" sentinel).
    @State private var fontSelection: FontChoice = .native(family: TextStyle.defaultNativeFamily)
    @State private var bold: Bool = false
    @State private var italic: Bool = false
    @State private var bodyText: String = ""

    var body: some View {
        Section("Font & Style") {
            Picker("Font", selection: $fontSelection) {
                Section("Native") {
                    ForEach(Self.nativeFamilies, id: \.self) { fam in
                        Text(fam).tag(FontChoice.native(family: fam))
                    }
                }
                Section("Stroke (.lff)") {
                    ForEach(strokeFontNames, id: \.self) { name in
                        Text(name).tag(FontChoice.stroke(name: name))
                    }
                }
            }
            .onChange(of: fontSelection) { _, _ in commitStyle() }

            Toggle("Bold", isOn: $bold)
                .onChange(of: bold) { _, _ in commitStyle() }
            Toggle("Italic", isOn: $italic)
                .onChange(of: italic) { _, _ in commitStyle() }

            // Per-entity TextData/MTextData fields below this point.
            perEntityFields
        }
        .onAppear(perform: seed)
        .onChange(of: record.id) { _, _ in seed() }
    }

    // MARK: Per-entity (justification / width / oblique / generation / text)

    @ViewBuilder
    private var perEntityFields: some View {
        switch record.kind {
        case .text(let d):
            Picker("Justify (H)", selection: hAlignBinding(d)) {
                Text("Left").tag(TextHAlign.left)
                Text("Center").tag(TextHAlign.center)
                Text("Right").tag(TextHAlign.right)
                Text("Aligned").tag(TextHAlign.aligned)
                Text("Middle").tag(TextHAlign.middle)
                Text("Fit").tag(TextHAlign.fit)
            }
            Picker("Justify (V)", selection: vAlignBinding(d)) {
                Text("Baseline").tag(TextVAlign.baseline)
                Text("Bottom").tag(TextVAlign.bottom)
                Text("Middle").tag(TextVAlign.middle)
                Text("Top").tag(TextVAlign.top)
            }
            ScalarField(label: "Width factor", value: d.widthFactor) {
                onKindCommit(record.id, InspectorEdits.setTextWidthFactor(record.kind, $0))
            }
            ScalarField(label: "Oblique (°)", value: d.obliqueAngle * 180 / .pi) {
                onKindCommit(record.id, InspectorEdits.setTextOblique(record.kind, $0 * .pi / 180))
            }
            Toggle("Backward", isOn: generationBinding(.backward, d.generation))
            Toggle("Upside down", isOn: generationBinding(.upsideDown, d.generation))
            TextField("Text", text: $bodyText, axis: .vertical)
                .lineLimit(1...4)
                .onSubmit { onKindCommit(record.id, InspectorEdits.setTextString(record.kind, bodyText)) }

        case .mtext:
            Picker("Attachment", selection: attachmentBinding) {
                Text("Top Left").tag(MTextAttachment.topLeft)
                Text("Top Center").tag(MTextAttachment.topCenter)
                Text("Top Right").tag(MTextAttachment.topRight)
                Text("Middle Left").tag(MTextAttachment.middleLeft)
                Text("Middle Center").tag(MTextAttachment.middleCenter)
                Text("Middle Right").tag(MTextAttachment.middleRight)
                Text("Bottom Left").tag(MTextAttachment.bottomLeft)
                Text("Bottom Center").tag(MTextAttachment.bottomCenter)
                Text("Bottom Right").tag(MTextAttachment.bottomRight)
            }
            if case .mtext(let d) = record.kind {
                ScalarField(label: "Line spacing", value: d.lineSpacingFactor) {
                    onKindCommit(record.id, InspectorEdits.setMTextLineSpacingFactor(record.kind, $0))
                }
            }
            TextField("Text", text: $bodyText, axis: .vertical)
                .lineLimit(1...6)
                .onSubmit { onKindCommit(record.id, InspectorEdits.setMTextPlainText(record.kind, bodyText)) }

        default:
            EmptyView()
        }
    }

    // MARK: Bindings

    private func hAlignBinding(_ d: TextData) -> Binding<TextHAlign> {
        Binding(get: { d.hAlign },
                set: { onKindCommit(record.id, InspectorEdits.setTextHAlign(record.kind, $0)) })
    }

    private func vAlignBinding(_ d: TextData) -> Binding<TextVAlign> {
        Binding(get: { d.vAlign },
                set: { onKindCommit(record.id, InspectorEdits.setTextVAlign(record.kind, $0)) })
    }

    private func generationBinding(_ flag: TextGenerationFlags, _ current: TextGenerationFlags) -> Binding<Bool> {
        Binding(
            get: { current.contains(flag) },
            set: { on in
                let newKind: EntityKind = flag == .backward
                    ? InspectorEdits.setTextBackward(record.kind, on)
                    : InspectorEdits.setTextUpsideDown(record.kind, on)
                onKindCommit(record.id, newKind)
            }
        )
    }

    private var attachmentBinding: Binding<MTextAttachment> {
        Binding(
            get: {
                if case .mtext(let d) = record.kind { return d.attachment }
                return .topLeft
            },
            set: { onKindCommit(record.id, InspectorEdits.setMTextAttachment(record.kind, $0)) }
        )
    }

    // MARK: Style commit (font family + bold/italic → upserted TextStyle)

    /// Builds the chosen `FontSource`, derives a canonical `TextStyle` for it +
    /// the bold/italic traits, and commits: the style is upserted and the entity's
    /// `styleName` is repointed at it (one undo step).
    private func commitStyle() {
        let source: FontSource
        switch fontSelection {
        case .native(let family): source = .native(family: family)
        case .stroke(let name):   source = .stroke(lff: name)
        }
        let style = InspectorEdits.derivedTextStyle(font: source, bold: bold, italic: italic)
        let newKind: EntityKind
        switch record.kind {
        case .text:  newKind = InspectorEdits.setTextStyleName(record.kind, style.name)
        case .mtext: newKind = InspectorEdits.setMTextStyleName(record.kind, style.name)
        default:     return
        }
        onStyleCommit(record.id, newKind, style)
    }

    // MARK: Seed

    private func seed() {
        switch resolvedStyle.primaryFont {
        case .native(let family): fontSelection = .native(family: family)
        case .stroke(let lff):    fontSelection = .stroke(name: lff.isEmpty ? "standard" : lff)
        case .shx:                fontSelection = .native(family: TextStyle.defaultNativeFamily)
        }
        bold = resolvedStyle.bold
        italic = resolvedStyle.italic
        switch record.kind {
        case .text(let d):  bodyText = d.text
        case .mtext(let d): bodyText = InspectorEdits.mtextPlainText(.mtext(d))
        default:            bodyText = ""
        }
    }

    /// The font picker's selection — a native family or a stroke base name. A small
    /// `Hashable` so it can tag picker rows.
    private enum FontChoice: Hashable {
        case native(family: String)
        case stroke(name: String)
    }

    /// The native font families to offer (system families, sorted). Cached once.
    private static let nativeFamilies: [String] = {
        var families = Set(NSFontManager.shared.availableFontFamilies)
        families.insert(TextStyle.defaultNativeFamily)   // ensure the default is present
        return families.sorted()
    }()
}

// MARK: - Multi-selection common editor

/// Edits the fields shared by ALL selected entities: layer, pen color (+ color
/// mode), line type, and line width. Each change writes the chosen value onto every
/// selected record, committed as one undoable group. The "—" sentinel marks a field
/// whose values DIFFER across the selection ("mixed"); leaving a picker on "—"
/// commits nothing, so a multi-edit only changes the fields the user explicitly
/// sets — F21's multi-edit UX, extended beyond the v4 layer/color/width set.
struct MultiCommonEditor: View {
    let records: [EntityRecord]
    let layerNames: [String]
    let onCommitAll: ([EntityRecord]) -> Void
    /// Resets every selected entity's pen to `.byLayer` (one undo step). Supplied by
    /// the Inspector (routes through `CanvasModel.resetSelectionPenToLayer`).
    var onResetPenToLayer: (() -> Void)?

    @State private var layer: String = ""
    @State private var color: Color = .green
    @State private var widthMM: Double = 0.25
    @State private var colorMode: PenColorMode = .mixed
    @State private var lineType: LineTypeChoice = .mixed

    /// The pen-color modes a multi-edit can set (plus a "mixed" sentinel so a
    /// heterogeneous selection shows "—" until the user picks one).
    private enum PenColorMode: Hashable { case mixed, byLayer, byBlock, explicit }

    /// A line-type choice for the multi-edit (plus "mixed"). Mirrors the common
    /// `PenLineType` cases the inspector lets a multi-selection set in bulk.
    private enum LineTypeChoice: Hashable {
        case mixed, byLayer, solid, dashed, dotted, dashDot, center

        var penLineType: PenLineType? {
            switch self {
            case .mixed:   return nil
            case .byLayer: return .byLayer
            case .solid:   return .solid
            case .dashed:  return .dashed
            case .dotted:  return .dotted
            case .dashDot: return .dashDot
            case .center:  return .center
            }
        }
    }

    var body: some View {
        Section("Common (applies to all)") {
            Picker("Layer", selection: $layer) {
                Text("—").tag("")
                ForEach(layerNames, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: layer) { _, newValue in
                guard !newValue.isEmpty else { return }
                onCommitAll(records.map { r in
                    var copy = r; copy.layer = LayerID(newValue); return copy
                })
            }

            Picker("Pen color mode", selection: $colorMode) {
                Text("—").tag(PenColorMode.mixed)
                Text("By Layer").tag(PenColorMode.byLayer)
                Text("By Block").tag(PenColorMode.byBlock)
                Text("Explicit").tag(PenColorMode.explicit)
            }
            .onChange(of: colorMode) { _, newMode in
                switch newMode {
                case .mixed:    break
                case .byLayer:  commit { $0.pen.lineColor = .byLayer }
                case .byBlock:  commit { $0.pen.lineColor = .byBlock }
                case .explicit: commit { $0.pen.lineColor = .explicit(color.rgbaColor) }
                }
            }

            ColorPicker("Pen color", selection: $color, supportsOpacity: false)
                .onChange(of: color) { _, newColor in
                    let rgba = newColor.rgbaColor
                    colorMode = .explicit
                    commit { $0.pen.lineColor = .explicit(rgba) }
                }

            Picker("Line type", selection: $lineType) {
                Text("—").tag(LineTypeChoice.mixed)
                Text("By Layer").tag(LineTypeChoice.byLayer)
                Text("Solid").tag(LineTypeChoice.solid)
                Text("Dashed").tag(LineTypeChoice.dashed)
                Text("Dotted").tag(LineTypeChoice.dotted)
                Text("Dash-Dot").tag(LineTypeChoice.dashDot)
                Text("Center").tag(LineTypeChoice.center)
            }
            .onChange(of: lineType) { _, newType in
                guard let lt = newType.penLineType else { return }
                commit { $0.pen.lineType = lt }
            }

            LabeledContent {
                TextField("Width", value: $widthMM, format: .number)
                    .frame(width: DS.Field.std).multilineTextAlignment(.trailing)
                    .onSubmit(commitWidth)
            } label: {
                Text("Line width (mm)").lineLimit(1)
            }

            if let reset = onResetPenToLayer {
                Button("Reset Pen to Layer", action: reset)
            }
        }
        .onAppear(perform: seed)
        .onChange(of: records.map(\.id)) { _, _ in seed() }
    }

    /// Commits a per-record edit to EVERY selected record as one undoable group.
    private func commit(_ edit: (inout EntityRecord) -> Void) {
        onCommitAll(records.map { r in var copy = r; edit(&copy); return copy })
    }

    private func commitWidth() {
        commit { $0.pen.lineWidth = .millimeters(max(0, widthMM)) }
    }

    /// Seeds the pickers from the selection: a field shared by ALL records shows that
    /// shared value; a heterogeneous field shows "—" (mixed). So the inspector tells
    /// the user at a glance which fields already agree across the selection.
    private func seed() {
        // Layer (shared name ⇒ that name, else "—").
        let layers = Set(records.map(\.layer.name))
        layer = layers.count == 1 ? (layers.first ?? "") : ""

        // Color mode (shared ⇒ that mode, else "mixed"). Also seed the swatch from a
        // shared explicit color so the ColorPicker shows the right starting color.
        let modes = Set(records.map { r -> PenColorMode in
            switch r.pen.lineColor {
            case .byLayer:  return .byLayer
            case .byBlock:  return .byBlock
            case .explicit: return .explicit
            }
        })
        colorMode = modes.count == 1 ? (modes.first ?? .mixed) : .mixed
        if colorMode == .explicit,
           case .explicit(let rgba)? = records.first?.pen.lineColor {
            color = Color(rgba: rgba)
        }

        // Line type (shared ⇒ that type, else "mixed").
        let types = Set(records.map(\.pen.lineType))
        if types.count == 1, let only = types.first {
            switch only {
            case .byLayer: lineType = .byLayer
            case .solid:   lineType = .solid
            case .dashed:  lineType = .dashed
            case .dotted:  lineType = .dotted
            case .dashDot: lineType = .dashDot
            case .center:  lineType = .center
            default:       lineType = .mixed
            }
        } else {
            lineType = .mixed
        }

        // Width (shared explicit mm ⇒ that value).
        let widths = Set(records.map(\.pen.lineWidth))
        if widths.count == 1, case .millimeters(let mm)? = widths.first {
            widthMM = mm
        }
    }
}

// MARK: - Reusable field rows

/// A labeled X/Y pair of numeric fields editing a `Vector`, committing the new
/// vector on submit / change.
struct PointFields: View {
    let label: String
    let point: Vector
    let onCommit: (Vector) -> Void

    @State private var x: Double = 0
    @State private var y: Double = 0

    var body: some View {
        LabeledContent {
            HStack(spacing: DS.Space.sm) {
                TextField("x", value: $x, format: .number)
                    .frame(width: DS.Field.xy).multilineTextAlignment(.trailing)
                    .onSubmit(commit)
                TextField("y", value: $y, format: .number)
                    .frame(width: DS.Field.xy).multilineTextAlignment(.trailing)
                    .onSubmit(commit)
            }
        } label: {
            Text(label).lineLimit(1)
        }
        .onAppear(perform: seed)
        .onChange(of: point) { _, _ in seed() }
    }

    private func commit() { onCommit(Vector(x, y)) }
    private func seed() { x = point.x; y = point.y }
}

/// A labeled single numeric field, committing on submit / change.
struct ScalarField: View {
    let label: String
    let value: Double
    let onCommit: (Double) -> Void

    @State private var draft: Double = 0

    var body: some View {
        LabeledContent {
            TextField(label, value: $draft, format: .number)
                .frame(width: DS.Field.std).multilineTextAlignment(.trailing)
                .onSubmit { onCommit(draft) }
        } label: {
            Text(label).lineLimit(1)
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, newValue in draft = newValue }
    }
}

/// Picks one point out of a list (a control polygon / vertex ring) and edits its
/// X/Y. The user selects an index from a stepper; the X/Y row below it edits the
/// selected point and commits `(index, newPoint)`. Read-only (no row) when the list
/// is empty. Used for spline / splinePoints control points + polyline vertices,
/// where full per-point editing lives in a dedicated on-canvas tool but the
/// inspector still offers a light "nudge a chosen point" affordance.
struct IndexedPointEditor: View {
    let label: String
    let points: [Vector]
    /// Commits a new coordinate for the point at `index`.
    let onCommit: (Int, Vector) -> Void

    @State private var index: Int = 0

    var body: some View {
        if !points.isEmpty {
            let clamped = Swift.min(index, points.count - 1)
            Stepper(value: $index, in: 0...(points.count - 1)) {
                Text("\(label) index: \(clamped + 1) of \(points.count)")
            }
            PointFields(label: "\(label) \(clamped + 1)", point: points[clamped]) { pt in
                onCommit(clamped, pt)
            }
        }
    }
}
