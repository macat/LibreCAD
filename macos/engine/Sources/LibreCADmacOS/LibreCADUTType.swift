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

    /// DWG (binary AutoCAD) type. macOS ships a system declaration for DWG under
    /// `com.autodesk.dwg`; we IMPORT (not export) it so we interoperate with that
    /// system type rather than minting a competing one. The document layer also
    /// falls back to the extension-derived type (see `LibreCADDocument.dwgTypes`)
    /// so Open / double-click resolve regardless of which UTI Launch Services
    /// assigns the file. (The bundle's Info.plist still declares
    /// `org.librecad.dwg` as a CFBundleDocumentType for icon/role association.)
    static let librecadDWG = UTType(importedAs: "com.autodesk.dwg")

    /// Native LibreCAD JSON type (.lcad). Exported so the system knows our
    /// lossless format that preserves constraints/parameters/tables/layouts.
    static let librecadLCAD = UTType(exportedAs: "org.librecad.lcad")
}
