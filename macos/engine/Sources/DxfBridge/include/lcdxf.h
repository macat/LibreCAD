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
 * Status codes returned by the bridge. Replaces the previous process-global
 * error-string scheme: every call now returns an explicit, thread-safe status,
 * and outputs are written through out-parameters. Swift maps these to a thrown
 * `CADEngineError`.
 */
typedef enum LCStatus {
    LC_OK = 0,                /**< Success. */
    LC_ERR_INVALID_PATH = 1,  /**< path was null or empty. */
    LC_ERR_READ_FAILED = 2    /**< libdxfrw could not read the file (bad/missing/corrupt). */
} LCStatus;

/**
 * Count the geometric entities in a DXF file by streaming it through libdxfrw's
 * DRW_Interface. Pure C ABI so Swift can import it as a plain C module (no
 * Swift C++ interop required).
 *
 * No process-global state: the result is written to *out_count and the outcome
 * is the returned status, so concurrent/serialized callers never race on a
 * shared error buffer.
 *
 * @param path       UTF-8 filesystem path to a DXF file.
 * @param out_count  On LC_OK, receives the entity count (>= 0). Untouched on
 *                   error. May be NULL (the count is then discarded).
 * @return LC_OK on success; LC_ERR_INVALID_PATH for a null/empty path;
 *         LC_ERR_READ_FAILED if libdxfrw fails to read (also covers any
 *         exception escaping the parse — caught at the C boundary).
 */
LCStatus lc_dxf_count_entities(const char *path, int *out_count);

#ifdef __cplusplus
}
#endif

#endif /* LCDXF_H */
