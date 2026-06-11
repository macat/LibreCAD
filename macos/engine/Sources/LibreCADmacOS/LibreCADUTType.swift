//
//  LibreCADUTType.swift
//  LibreCADmacOS
//
//  GPLv2-or-later (LibreCAD derivative).
//

import UniformTypeIdentifiers

extension UTType {
    /// Exported DXF type. The full declaration (conforming to public.text /
    /// public.data) is wired up in the app bundle's Info.plist via
    /// macos/scripts/make-app.sh; this mirror lets the document layer refer to
    /// it in code.
    static let librecadDXF = UTType(exportedAs: "org.librecad.dxf")
}
