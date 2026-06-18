//
//  CanvasCursorVisibility.swift
//  LibreCADmacOS
//
//  The pure, side-effect-free DECISION PREDICATE for the AutoCAD-style cursor:
//  while a drawing/edit tool is active the canvas draws its own "spider" crosshair
//  overlay, and the NATIVE macOS pointer must be HIDDEN so the user sees ONLY the
//  drawn crosshair (AutoCAD parity) — not the OS arrow/cross drawn on top of it.
//
//  WHY a free function (not an inline expression): hiding the pointer is done with
//  the layering-independent `NSCursor.hide()` / `NSCursor.unhide()` (a cursor RECT on
//  the MTKView is shadowed by the transparent click-through overlay subviews stacked
//  on top, which is why the earlier transparent-cursor-rect attempt never worked).
//  `hide`/`unhide` are REFERENCE-COUNTED, so the one risk is an unbalanced call
//  leaving the pointer stuck invisible. Concentrating the entire "should it be hidden"
//  decision in ONE pure predicate lets `FlippedMTKView.reconcileCursorHidden()` keep
//  exactly one outstanding hide, and lets this truth table be unit-tested HEADLESSLY
//  (the live AppKit visibility itself is chrome the headless suite + LCShot cannot
//  observe). It is intentionally tiny + dependency-free so it can be symlinked into
//  the test target (`_SharedCanvasCursorVisibility.swift`) — `CADCanvasView.swift`'s
//  dependency closure is far too large to symlink whole.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

/// Whether the native macOS pointer should be HIDDEN over the canvas right now.
///
/// The pointer is hidden — so the drawn crosshair is the only cursor (AutoCAD parity)
/// — exactly when ALL THREE hold:
///   • `mouseInsideCanvas`  — the pointer is over the canvas view's bounds (not the
///     sidebar / menu bar / title bar), so we only ever hide it where the crosshair
///     is actually drawn;
///   • `crosshairVisible`   — a drawing/edit tool is active (`CanvasModel.crosshairVisible`),
///     so in SELECT mode the normal arrow stays (nothing to replace it with);
///   • `windowIsKey`        — the canvas's window is the key window, so switching apps /
///     windows reveals the pointer again (and returning re-hides it).
///
/// Pure: no side effects, no globals — just a boolean of its inputs. The actual
/// `NSCursor.hide()`/`unhide()` balancing lives in `FlippedMTKView.reconcileCursorHidden()`,
/// which calls this and keeps at most one outstanding hide.
func cursorShouldBeHidden(
    mouseInsideCanvas: Bool,
    crosshairVisible: Bool,
    windowIsKey: Bool
) -> Bool {
    mouseInsideCanvas && crosshairVisible && windowIsKey
}
