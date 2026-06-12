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

            LabeledContent("Line width (mm)") {
                TextField("Width", value: $widthMM, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
                    .onSubmit(commitWidth)
                    .onChange(of: widthMM) { _, _ in commitWidth() }
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
            case .line(let d):       lineEditor(d)
            case .circle(let d):     circleEditor(d)
            case .arc(let d):        arcEditor(d)
            case .point(let d):      pointEditor(d)
            case .text(let d):       textGeometryEditor(d)
            case .mtext(let d):      mtextGeometryEditor(d)
            default:
                Text("No inline geometry editor for this kind yet.")
                    .font(.callout).foregroundStyle(.secondary)
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

/// Edits the fields shared by ALL selected entities: layer, pen color, line width.
/// Each change writes the chosen value onto every selected record, committed as one
/// undoable group.
struct MultiCommonEditor: View {
    let records: [EntityRecord]
    let layerNames: [String]
    let onCommitAll: ([EntityRecord]) -> Void

    @State private var layer: String = ""
    @State private var color: Color = .green
    @State private var widthMM: Double = 0.25

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

            ColorPicker("Pen color", selection: $color, supportsOpacity: false)
                .onChange(of: color) { _, newColor in
                    let rgba = newColor.rgbaColor
                    onCommitAll(records.map { r in
                        var copy = r; copy.pen.lineColor = .explicit(rgba); return copy
                    })
                }

            LabeledContent("Line width (mm)") {
                TextField("Width", value: $widthMM, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
                    .onSubmit(commitWidth)
            }
        }
    }

    private func commitWidth() {
        onCommitAll(records.map { r in
            var copy = r; copy.pen.lineWidth = .millimeters(max(0, widthMM)); return copy
        })
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
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("x", value: $x, format: .number)
                    .frame(width: 70).multilineTextAlignment(.trailing)
                    .onSubmit(commit)
                TextField("y", value: $y, format: .number)
                    .frame(width: 70).multilineTextAlignment(.trailing)
                    .onSubmit(commit)
            }
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
        LabeledContent(label) {
            TextField(label, value: $draft, format: .number)
                .frame(width: 90).multilineTextAlignment(.trailing)
                .onSubmit { onCommit(draft) }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, newValue in draft = newValue }
    }
}
