//
//  DesignTokens.swift
//  LibreCADmacOS
//
//  Single source of truth for SwiftUI-chrome metrics (panels / bars / rows).
//  Wave 1 of the UI redesign (see macos/docs/ui-redesign-plan.md §1): every
//  region references THIS token set so radii, paddings, field widths, and
//  selection tints stop drifting per-finding. UI-only; defines the system,
//  changes no behavior on its own.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI

/// Single source of truth for SwiftUI-chrome metrics. CanvasTheme covers ONLY
/// the Metal canvas; this covers panels/bars/rows. Use these everywhere — no
/// inline radius/padding/width/color literals in views.
enum DS {
    // SPACING — 4pt base. Allowed ONLY {2,4,6,8,12,16,24}. Retire 5,7,9,10,14.
    enum Space { static let xxs:CGFloat=2; static let xs:CGFloat=4; static let sm:CGFloat=6
                 static let md:CGFloat=8; static let lg:CGFloat=12; static let xl:CGFloat=16; static let xxl:CGFloat=24 }
    // CORNER RADIUS — three roles + the swatch exception.
    enum Radius { static let selection:CGFloat=6; static let card:CGFloat=10
                  static let modal:CGFloat=14; static let swatch:CGFloat=3 }   // ✅ swatch = 3 (resolved 3-vs-4)
    // CONTROL SIZE
    enum Size { static let iconButton:CGFloat=22; static let swatch:CGFloat=16; static let rowIcon:CGFloat=20
                static let barDivider:CGFloat=16; static let barPadV:CGFloat=6; static let barPadH:CGFloat=12
                static let listRowMin:CGFloat=22 }
    // FIELD WIDTH — tiers replace the 28..160 grab-bag. `xy` is the documented paired-field exception.
    enum Field { static let xy:CGFloat=56; static let narrow:CGFloat=72; static let std:CGFloat=96; static let wide:CGFloat=130 }
    // TYPE RAMP — semantic roles → system fonts (Dynamic Type preserved).
    enum Font {
        static let panelTitle     = SwiftUI.Font.subheadline.weight(.semibold) // was .headline
        static let rowLabel       = SwiftUI.Font.callout
        static let rowValue       = SwiftUI.Font.callout.monospacedDigit()
        static let secondaryLabel = SwiftUI.Font.caption
        static let hint           = SwiftUI.Font.caption                        // + .foregroundStyle(.tertiary)
        static let barLabel       = SwiftUI.Font.callout.weight(.medium)
    }
    // SEMANTIC COLOR — ONE accent source, ONE selection opacity.
    enum Palette {
        static let accent        = Color.accentColor
        static let selectionFill = Color.accentColor.opacity(0.15)   // ALL selection backgrounds
        static let separator     = Color(nsColor: .separatorColor)
        static let panelBg       = Color(nsColor: .controlBackgroundColor)
        static let onAccent      = Color.white                        // text on a solid-accent fill
    }
}

// Reusable bar primitive (kills the copy-pasted `.background(.bar)+Divider` in 7 places).
extension View {
    func barStrip(dividerEdge: VerticalEdge = .bottom) -> some View {
        self.padding(.horizontal, DS.Size.barPadH).padding(.vertical, DS.Size.barPadV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: dividerEdge == .bottom ? .bottom : .top) { Divider() }
    }
}
