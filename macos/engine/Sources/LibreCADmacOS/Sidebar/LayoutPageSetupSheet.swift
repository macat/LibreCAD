//
//  LayoutPageSetupSheet.swift
//  LibreCADmacOS
//
//  The per-layout PAGE SETUP sheet (backlog #4c — the Model/Layout tab strip's
//  right-click "Page Setup…" action). A small View-layer modal: it edits the ACTIVE
//  layout's page — paper size / orientation / margin / plot scale — prefilled from the
//  layout's current `PageDescriptor`, and on commit hands a fresh `PageDescriptor` back
//  to the host (`LayoutTabStrip`), which calls the already-wired
//  `CanvasModel.setLayoutPage(_:_:)` (one undoable value-snapshot step).
//
//  Engine-independence (project gotcha #1 + the brief): the page ⇄ form mapping lives
//  in a PURE, self-contained `LayoutPageMapper` namespace built ONLY on plain values +
//  the engine's `PageDescriptor` (mm). It deliberately does NOT reference the app's
//  `PrintLayout` / `PaperSize` types — it carries its OWN `PaperPreset` / `Orientation`
//  so the mapper round-trips through `PageDescriptor` alone and unit-tests headlessly
//  (the file is symlinked into the engine test target, like `LayoutRenameSheet`).
//
//  Modal discipline (project gotcha #3): this sheet is presented ONLY from a View-layer
//  `.sheet(item:)` in `LayoutTabStrip`; nothing the headless suite reaches constructs or
//  presents it. The MAPPER (`LayoutPageMapper`) is pure value logic, so the tests drive
//  it + the `CanvasModel.setLayoutPage` round-trip directly, never the sheet.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
import CADEngine

// MARK: - Pure page ⇄ form mapper (testable, no SwiftUI/AppKit)
//
// The single source of truth for converting between the editable FORM state (paper
// preset / orientation / margin / scale) and the engine's `PageDescriptor` (mm). It is
// deliberately free of SwiftUI/AppKit AND of the app's `PrintLayout`/`PaperSize` types
// so the engine test target can exercise it via the symlinked copy, headlessly. The
// SwiftUI sheet below is a thin shell over this.

/// Pure conversions between a layout Page-Setup FORM and the engine `PageDescriptor`.
/// Self-contained (its own `PaperPreset`/`Orientation`) so it never references the app's
/// print types and round-trips through `PageDescriptor` alone.
enum LayoutPageMapper {

    /// A standard paper size, in PORTRAIT millimeters. Self-contained (NOT the app's
    /// `PaperSize`) so the mapper stays engine-test-friendly. `.custom` carries free
    /// width/height the user typed (an arbitrary sheet the presets don't cover).
    enum PaperPreset: String, CaseIterable, Sendable, Hashable {
        case a4, a3, a2, a1, a0, letter, legal, tabloid, custom

        /// (width, height) in millimeters, PORTRAIT (width ≤ height). `.custom` returns
        /// `nil` — its size comes from the form's typed width/height instead.
        var portraitMM: (width: Double, height: Double)? {
            switch self {
            case .a4:      return (210, 297)
            case .a3:      return (297, 420)
            case .a2:      return (420, 594)
            case .a1:      return (594, 841)
            case .a0:      return (841, 1189)
            case .letter:  return (215.9, 279.4)
            case .legal:   return (215.9, 355.6)
            case .tabloid: return (279.4, 431.8)
            case .custom:  return nil
            }
        }

        var label: String {
            switch self {
            case .a4: return "A4"
            case .a3: return "A3"
            case .a2: return "A2"
            case .a1: return "A1"
            case .a0: return "A0"
            case .letter:  return "Letter"
            case .legal:   return "Legal"
            case .tabloid: return "Tabloid"
            case .custom:  return "Custom"
            }
        }
    }

    /// Page orientation. `.portrait` is width ≤ height; `.landscape` swaps them.
    enum Orientation: String, CaseIterable, Sendable, Hashable {
        case portrait, landscape
        var label: String { self == .portrait ? "Portrait" : "Landscape" }
    }

    /// The editable form state — the shape the sheet binds + the mapper converts. Pure
    /// value type so the round-trip (`form(from:) ⇄ pageDescriptor(from:)`) is testable.
    struct PageForm: Equatable, Sendable {
        var preset: PaperPreset
        var orientation: Orientation
        /// Used ONLY when `preset == .custom`: the PORTRAIT width/height the user typed.
        var customWidthMM: Double
        var customHeightMM: Double
        var marginMM: Double
        /// Scale-to-fit when true; otherwise the fixed plot ratio in `ratio`.
        var fitToPage: Bool
        var ratio: Double
    }

    // MARK: Tolerance for matching a descriptor's size back to a preset

    /// Two paper dimensions are "the same preset" within this mm tolerance (rounding of
    /// the US sizes' fractional millimeters can leave a hair of error after a round-trip).
    static let sizeMatchTolMM = 0.5

    // MARK: form → PageDescriptor (commit)

    /// Builds the engine `PageDescriptor` (mm) the commit hands to `setLayoutPage`.
    /// Orientation rotates a preset's portrait dims (and a `.custom` size's typed dims);
    /// the margin is clamped non-negative; the scale is `.fit` or a positive ratio
    /// (`PageDescriptor`/`LayoutPlotScale.fixed` clamp a degenerate ratio to 1:1).
    static func pageDescriptor(from form: PageForm) -> PageDescriptor {
        let (pw, ph) = portraitSize(of: form)
        let (w, h): (Double, Double) = form.orientation == .portrait ? (pw, ph) : (ph, pw)
        let scale: LayoutPlotScale = form.fitToPage ? .fit : .fixed(form.ratio)
        return PageDescriptor(widthMM: max(1, w),
                              heightMM: max(1, h),
                              marginMM: max(0, form.marginMM),
                              plotScale: scale)
    }

    /// The PORTRAIT (width ≤ height) size the form describes — a preset's fixed dims, or
    /// the typed custom size normalized to portrait (so orientation is applied cleanly).
    private static func portraitSize(of form: PageForm) -> (width: Double, height: Double) {
        if let p = form.preset.portraitMM { return p }
        // Custom: normalize the typed pair to portrait (smaller side = width), each ≥ 1mm.
        let a = max(1, form.customWidthMM)
        let b = max(1, form.customHeightMM)
        return (min(a, b), max(a, b))
    }

    // MARK: PageDescriptor → form (prefill)

    /// Derives the editable form from an existing `PageDescriptor` (the sheet's prefill).
    /// Detects orientation from width/height, matches the (re-portrait-ed) size to a
    /// known preset within `sizeMatchTolMM` else falls to `.custom`, and reflects the
    /// plot scale as fit vs. a fixed ratio.
    static func form(from page: PageDescriptor) -> PageForm {
        let isLandscape = page.widthMM > page.heightMM
        let orientation: Orientation = isLandscape ? .landscape : .portrait
        // Re-portrait the descriptor's size for preset matching (presets are portrait).
        let pw = min(page.widthMM, page.heightMM)
        let ph = max(page.widthMM, page.heightMM)
        let preset = matchPreset(portraitWidth: pw, portraitHeight: ph)

        let fit = page.plotScale.ratioValue == nil
        let ratio = page.plotScale.ratioValue ?? 1

        return PageForm(preset: preset,
                        orientation: orientation,
                        customWidthMM: pw,
                        customHeightMM: ph,
                        marginMM: page.marginMM,
                        fitToPage: fit,
                        ratio: ratio)
    }

    /// Finds the preset whose PORTRAIT dims match `(portraitWidth, portraitHeight)`
    /// within `sizeMatchTolMM`, else `.custom`.
    static func matchPreset(portraitWidth pw: Double, portraitHeight ph: Double) -> PaperPreset {
        for preset in PaperPreset.allCases {
            guard let dims = preset.portraitMM else { continue }
            if abs(dims.width - pw) <= sizeMatchTolMM,
               abs(dims.height - ph) <= sizeMatchTolMM {
                return preset
            }
        }
        return .custom
    }
}

// MARK: - The Page Setup sheet (SwiftUI; thin, decomposed per gotcha #2)

#if canImport(SwiftUI)
/// The per-layout Page Setup sheet. Self-contained: it owns the live `PageForm` draft
/// (seeded from the layout's current page on init), derives the resulting
/// `PageDescriptor` purely via `LayoutPageMapper`, and reports the confirmed descriptor
/// (or a cancel) to the host. Decomposed into small `@ViewBuilder` subviews so the
/// SwiftUI type-checker stays comfortable (gotcha #2 — mirrors `LayoutRenameSheet`).
struct LayoutPageSetupSheet: View {
    /// The layout being edited (its name labels the sheet; its page seeds the form).
    let layoutName: String

    /// Reports the confirmed `PageDescriptor` (built by `LayoutPageMapper`) to the host,
    /// which calls `CanvasModel.setLayoutPage(layoutName, page)`.
    let onCommit: (PageDescriptor) -> Void
    /// Reports a cancel back to the host (dismiss with no action).
    let onCancel: () -> Void

    /// The live editable form, seeded from the layout's current page on appear.
    @State private var form: LayoutPageMapper.PageForm

    init(layoutName: String,
         page: PageDescriptor,
         onCommit: @escaping (PageDescriptor) -> Void,
         onCancel: @escaping () -> Void) {
        self.layoutName = layoutName
        self.onCommit = onCommit
        self.onCancel = onCancel
        self._form = State(initialValue: LayoutPageMapper.form(from: page))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            formBody
            Divider()
            buttons
        }
        .frame(minWidth: 420)
    }

    // MARK: - Subviews (decomposed for the type checker)

    @ViewBuilder private var header: some View {
        Text("Page Setup")
            .font(.headline)
            .padding([.top, .horizontal])
            .padding(.bottom, 4)
        Text("Set the paper size, orientation, margin, and plot scale for the “\(layoutName)” layout.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal)
            .padding(.bottom, 8)
    }

    @ViewBuilder private var formBody: some View {
        Form {
            Section("Paper") {
                paperPicker
                orientationPicker
                if form.preset == .custom { customSizeFields }
            }
            Section("Margin") {
                LabeledContent("Margin (mm)") {
                    TextField("mm", value: Binding(
                        get: { form.marginMM },
                        set: { form.marginMM = max(0, $0) }
                    ), format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
                }
            }
            Section("Plot scale") {
                Toggle("Scale to fit page", isOn: $form.fitToPage)
                if !form.fitToPage { ratioField }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var paperPicker: some View {
        Picker("Paper size", selection: $form.preset) {
            ForEach(LayoutPageMapper.PaperPreset.allCases, id: \.self) { p in
                Text(p.label).tag(p)
            }
        }
    }

    @ViewBuilder private var orientationPicker: some View {
        Picker("Orientation", selection: $form.orientation) {
            ForEach(LayoutPageMapper.Orientation.allCases, id: \.self) { o in
                Text(o.label).tag(o)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private var customSizeFields: some View {
        LabeledContent("Width (mm)") {
            TextField("mm", value: Binding(
                get: { form.customWidthMM },
                set: { form.customWidthMM = max(1, $0) }
            ), format: .number)
            .frame(width: 90).multilineTextAlignment(.trailing)
        }
        LabeledContent("Height (mm)") {
            TextField("mm", value: Binding(
                get: { form.customHeightMM },
                set: { form.customHeightMM = max(1, $0) }
            ), format: .number)
            .frame(width: 90).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder private var ratioField: some View {
        LabeledContent("Scale (drawing : paper)") {
            HStack(spacing: 4) {
                TextField("ratio", value: Binding(
                    get: { form.ratio },
                    set: { form.ratio = ($0.isFinite && $0 > 0) ? $0 : 1 }
                ), format: .number)
                .frame(width: 90).multilineTextAlignment(.trailing)
                Text(": 1").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("OK") { onCommit(LayoutPageMapper.pageDescriptor(from: form)) }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}
#endif
