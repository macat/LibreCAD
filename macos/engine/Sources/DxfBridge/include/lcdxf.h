/******************************************************************************
**  LibreCAD macOS — DXF bridge (C ABI over libdxfrw)                        **
**                                                                           **
**  This file is part of LibreCAD's native macOS port, a derivative work of  **
**  LibreCAD and libdxfrw. Both are licensed GPLv2-or-later; this fork       **
**  inherits that license.                                                   **
**                                                                           **
**  Copyright (C) 2026 LibreCAD macOS contributors.                          **
**                                                                           **
**  This program is free software; you can redistribute it and/or modify     **
**  it under the terms of the GNU General Public License as published by     **
**  the Free Software Foundation; either version 2 of the License, or        **
**  (at your option) any later version.                                      **
******************************************************************************/

#ifndef LCDXF_H
#define LCDXF_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Count the geometric entities in a DXF file by streaming it through
 * libdxfrw's DRW_Interface. Pure C ABI so Swift can import it as a plain
 * C module (no Swift C++ interop required).
 *
 * @param path UTF-8 filesystem path to a DXF file.
 * @return number of entities counted, or a negative value on failure
 *         (-1 = null/empty path, -2 = libdxfrw reported a read error,
 *          -3 = an exception escaped the parse).
 */
int lc_dxf_count_entities(const char *path);

/**
 * Returns a human-readable description of the last error produced by the
 * most recent bridge call, or NULL if it succeeded. The returned pointer is
 * owned by the bridge and remains valid until the next bridge call.
 */
const char *lc_dxf_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* LCDXF_H */
