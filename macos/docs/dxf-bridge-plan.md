# Swift ↔ C++ Interop Bridge Plan: Reusing LibreCAD's `libdxfrw` from a native macOS Swift app

**Goal:** Let a new native macOS Swift 6 app read/write DXF and DWG files by reusing LibreCAD's `libdxfrw` (vendored at `/Users/macatt/w/LibreCAD/libraries/libdxfrw`) — without dragging in Qt or the rest of LibreCAD.

**Target toolchain:** macOS 26 SDK, Swift 6.2.3, Xcode 26.2, Apple Silicon. Swift 6 C++ interop available (`-cxx-interoperability-mode=default`, SwiftPM `interoperabilityMode(.Cxx)`, Xcode "C++ and Objective-C Interoperability = C++/Objective-C++").

---

## 1. libdxfrw layout & public API

### Public headers (the only ones a consumer includes)
Located in `libraries/libdxfrw/src/`:
- `libdxfrw.h` — **`class dxfRW`**: DXF read/write entry point. `dxfRW(const char* name)`, `read(DRW_Interface*, bool ext)`, `readAscii(...)`, `write(DRW_Interface*, DRW::Version, bool bin)`, plus ~40 per-entity `writeXxx(DRW_*)` methods, `getVersion()`, `getError()`. Also defines `DRW_ParsingContext`.
- `libdwgr.h` — **`class dwgRW`** (alias `dwgR`): DWG read/write entry point. `dwgRW(const char* name)`, `read(DRW_Interface*, bool ext)`, `write(DRW_Interface*, DRW::Version, bool bin)` (write supports R2000/`AC1015` only), per-entity `writeXxx`, `defineBlock(...)`, `getError()`, `getEntityParseFailures()`, `getSkippedCustomClasses()`.
- `drw_interface.h` — **`class DRW_Interface`**: pure-abstract callback interface (see §3). ~50 `addXxx(const DRW_*&/*)` read callbacks + ~12 `writeXxx()` write callbacks. **This is the integration seam.**
- `drw_base.h` — fundamental types: `DRW_Coord` (x,y,z doubles, POD-ish), `DRW_Vertex2D`, **`DRW_Variant`** (tagged union over string/int/double/coord/binary — has a `union` member + back-pointers, fix-ups in copy ctor), `dwgHandle`, `DRW_LW_Conv` (lineweight enum/converters), `namespace DRW` enums (`Version`, `error`, `ETYPE`, `DebugLevel`, color/space/etc.), free function `DRW::setCustomDebugPrinter(DebugPrinter*)`.
- `drw_entities.h` — the **DRW_* entity hierarchy** (all rooted at `DRW_Entity`):
  - Geometry: `DRW_Point`, `DRW_Line`, `DRW_Ray`, `DRW_Xline`, `DRW_Circle`, `DRW_Arc`, `DRW_Ellipse`, `DRW_Trace`, `DRW_Solid`, `DRW_3Dface`.
  - Polylines: `DRW_LWPolyline` (`std::vector<std::shared_ptr<DRW_Vertex2D>> vertlist`), `DRW_Polyline`/`DRW_Vertex`, `DRW_Spline`.
  - Text: `DRW_Text`, `DRW_Attrib`, `DRW_Attdef`, `DRW_MText`, `DRW_Tolerance`.
  - Compound: `DRW_Block`, `DRW_Insert`, `DRW_MLine`(+`DRW_MLineVertex`), `DRW_Hatch`(+`DRW_HatchLoop`), `DRW_Image`, `DRW_Underlay`, `DRW_Leader`, `DRW_MLeader`, `DRW_Viewport`.
  - Dimensions: `DRW_Dimension` base + `DRW_DimAligned`, `DRW_DimLinear`, `DRW_DimRadial`, `DRW_DimDiametric`, `DRW_DimAngular`, `DRW_DimAngular3p`, `DRW_DimOrdinate`.
- `drw_objects.h` — **table records** rooted at `DRW_TableEntry`: `DRW_Layer`, `DRW_LType`, `DRW_Textstyle`, `DRW_Dimstyle`, `DRW_Vport`, `DRW_View`, `DRW_UCS`, `DRW_AppId`, `DRW_Block_Record`, `DRW_ImageDef`, `DRW_PlotSettings`, `DRW_Dictionary`, `DRW_Layout`, `DRW_MLineStyle`, `DRW_MLeaderStyle`, `DRW_DbColor`, `DRW_Scale`, `DRW_VisualStyle`, `DRW_UnderlayDefinition`. Also `DRW_WritingContext`.
- `drw_header.h` — **`class DRW_Header`**: header variables. `std::unordered_map<std::string,DRW_Variant*> vars` + `customVars`; accessors `getDouble/getInt/getStr(key, out*)`. **Owns raw `DRW_Variant*` and deletes them in dtor** (ownership caveat).

### Internal headers/impl (`src/intern/`) — compiled in, not exposed
DXF codecs: `dxfreader`, `dxfwriter`, `drw_textcodec`, embedded codepage tables `drw_cptable932/936/949/950`, `drw_cptables`. DWG machinery: `dwgbuffer`, `dwgbufferw`, `dwgutil`, `rscodec` (Reed–Solomon), and the version-specific **DWG readers** `dwgreader` (base) + `dwgreader15/18/21/24/27/32`, plus **DWG writer** `dwgwriter`/`dwgwriter15`. Debug: `drw_dbg` (singleton `DRW_dbg`, silent by default), `drw_reserve.h` (small template helper).

### DWG support specifically
`dwgRW` (libdwgr.h/.cpp) → `dwgReader` base + per-format-version subclasses `dwgReader15` (R2000), `dwgReader18` (R2004), `dwgReader21` (R2007), `dwgReader24` (R2010), `dwgReader27` (R2013), `dwgReader32` (R2018). Writing is `dwgWriter15` only (R2000/`AC1015`). All share the same `DRW_Interface` callback contract as DXF — **no separate data model**.

---

## 2. Dependencies & build

### Dependency findings — clean
- **No Qt.** `libdxfrw.pro` explicitly does `QT -= core gui` (and `-= svg`). No `#include <Q...>`, no `QString`/`QFile` anywhere in `src/`. (Qt only appears in the *LibreCAD consumer* `rs_filterdxfrw.*`, which we are NOT reusing.)
- **No iconv** — character-set conversion is self-contained (`drw_textcodec` + embedded codepage tables + `rscodec`).
- **No zlib** — no inflate/deflate; DWG R2004+ compression is handled in-tree by `dwgutil`/buffers.
- **No `std::filesystem`.**
- **No C++ exceptions** thrown by the library (`grep "throw "` → none). Errors are reported via return `bool` + `getError()` → `DRW::error` enum. (Build still defaults to exceptions-enabled; that's fine for interop.)
- Standard library only: `<string>`, `<vector>`, `<list>`, `<map>`, `<unordered_map>`, `<memory>` (smart pointers), `<array>`, `<fstream>`, `<cmath>`, `<cstring>`. Direct file I/O via `std::ifstream`/`std::ofstream` (paths passed as `const char*`).

### C++ standard
CMake `CMakeLists.txt` sets `CMAKE_CXX_STANDARD 11` but the target requests `target_compile_features(dxfrw PUBLIC cxx_std_14)`; code uses `std::make_unique` (C++14). **No C++17 features** found (no `std::optional`/`std::variant`/`if constexpr`/structured bindings/`string_view`). → **Compile with `-std=c++14` or newer; C++17/C++20 is safe and recommended** (Swift interop prefers a modern standard; use `-std=c++20`).

### Exact `.cpp` files to compile into the standalone C++ target
(from `CMakeLists.txt` `libdxfrw_srcs`, paths relative to `libraries/libdxfrw/`)
```
src/drw_base.cpp
src/drw_classes.cpp
src/drw_entities.cpp
src/drw_header.cpp
src/drw_objects.cpp
src/libdwgr.cpp
src/libdxfrw.cpp
src/intern/drw_dbg.cpp
src/intern/drw_textcodec.cpp
src/intern/dwgbuffer.cpp
src/intern/dwgbufferw.cpp
src/intern/dwgwriter15.cpp
src/intern/dwgreader.cpp
src/intern/dwgreader15.cpp
src/intern/dwgreader18.cpp
src/intern/dwgreader21.cpp
src/intern/dwgreader24.cpp
src/intern/dwgreader27.cpp
src/intern/dwgreader32.cpp
src/intern/dwgutil.cpp
src/intern/dxfreader.cpp
src/intern/dxfwriter.cpp
src/intern/rscodec.cpp
```
(23 `.cpp` files. `drw_classes.cpp` is required even though there's no `drw_classes.h` in the install set — it backs `DRW_Class` used by DWG.) Exclude everything under `dwg2dxf/` and `tests/`.

### Include paths
- `libraries/libdxfrw/src` (for public headers)
- `libraries/libdxfrw/src/intern` (internal headers include each other by bare name)

The `.pro`/`.travis`/`conanfile.py` exist but we don't need them; build the 23 files directly.

---

## 3. Interop suitability & recommended bridge shape

### C++ constructs that are tricky for direct Swift interop
1. **`DRW_Interface` is a pure-abstract class with ~50 pure-virtual callbacks.** Swift's C++ interop **cannot subclass a C++ polymorphic class and override its virtuals** (no Swift-defines-C++-vtable). This is the single biggest blocker — and read *and* write both flow through this interface. → must be implemented **in C++**.
2. **`std::shared_ptr` / `std::vector<std::shared_ptr<...>>`** (e.g. `DRW_LWPolyline::vertlist`, `DRW_Spline`, hatch loops). Swift can import some of these but ergonomics are poor and lifetime is subtle.
3. **Raw-pointer ownership quirks:** `DRW_Header` owns `DRW_Variant*` and **deletes them in its destructor**; `DRW_Variant` holds a `union` plus self-referential back-pointers fixed up in its copy ctor. Passing these across the boundary directly is error-prone.
4. **Deep inheritance hierarchies** (`DRW_Entity` → `DRW_Point` → `DRW_Line` → ... 4-5 levels) with protected virtual `parseDwg`/`encodeDwg`. Slicing risk if copied by value.
5. **`std::string` UTF-8 payloads** everywhere (layer names, text) — fine to read on the C++ side, convert to Swift `String` at the shim boundary.
6. Global mutable state: `DRW_dbg` singleton (silent by default; leave alone) and `DRW::setCustomDebugPrinter`.

### Decision: **C ABI shim implemented in Objective-C++ (or plain C++), NOT direct Swift↔C++ interop, NOT an ObjC class hierarchy.**

Justification:
- The interface-implementation requirement (#1) forces a **C++-side implementation of `DRW_Interface`** no matter what. Once you're writing C++ to implement the interface, the cleanest, most stable, most Swift-friendly boundary is a **thin C ABI / POD layer**, not exposing the DRW_* graph directly.
- A flat C/POD boundary side-steps every item in the tricky list (shared_ptr, unions, deep inheritance, owning raw pointers) — the shim flattens DRW_* into trivially-copyable C structs / Swift-importable structs before anything crosses.
- **Objective-C++ (`.mm`) is the recommended language for the shim file** because it compiles C++ freely, lives naturally in an Xcode/SwiftPM target, and lets you optionally surface a small `@objc`/Swift-friendly class facade. (Plain C++ with `extern "C"` works too if you want zero ObjC; pick ObjC++ for the smoother Xcode story.) Direct C++ interop *can* additionally be turned on to consume nice Swift structs the shim emits, but it must not be the mechanism that implements `DRW_Interface`.

### Architecture (3 layers)
```
┌─────────────────────────────────────────────────────────────┐
│ Swift app:  LCDXFReader.read(path) -> [LCEntity]             │  Swift
│             LCDXFWriter(...).write(entities, to: path)       │
├─────────────────────────────────────────────────────────────┤
│ Bridge shim (.mm / .cpp):                                    │  ObjC++/C++
│  - class LCCollector : public DRW_Interface  (read)          │   (we own)
│      every addXxx() flattens DRW_* -> POD, appends to vector │
│  - class LCEmitter   : public DRW_Interface  (write)         │
│      writeEntities() iterates app-supplied PODs -> dxfRW::*  │
│  - extern "C" / @objc facade returning C arrays or NSArray   │
├─────────────────────────────────────────────────────────────┤
│ libdxfrw static lib (23 .cpp, no Qt)                         │  upstream C++
└─────────────────────────────────────────────────────────────┘
```

### Illustrative API sketch

**C ABI exposed by the shim (`LCDxfBridge.h`, includable from Swift via a module map / bridging header):**
```c
typedef enum { LC_LINE, LC_CIRCLE, LC_ARC, LC_LWPOLYLINE, LC_TEXT,
               LC_INSERT, LC_ELLIPSE, /* ... */ } LCEntityKind;

typedef struct { double x, y, z; } LCPoint;

typedef struct {            // flat, trivially-copyable
    LCEntityKind kind;
    int          color;     // resolved/raw color
    const char*  layer;     // UTF-8, owned by result handle
    // discriminated payload (one union arm per kind), e.g.:
    LCPoint p1, p2;         // line endpoints / circle center+radius-in-p2.x
    double  d1, d2, d3;     // radius / angles / etc.
    const LCPoint* verts;   // for polyline; count below
    size_t  vertCount;
} LCEntity;

typedef struct LCReadResult LCReadResult;          // opaque, owns backing storage
LCReadResult* lc_dxf_read(const char* path);       // DXF or DWG (sniffed)
size_t        lc_result_count(const LCReadResult*);
LCEntity      lc_result_entity(const LCReadResult*, size_t i);
const char*   lc_result_error(const LCReadResult*); // NULL on success
void          lc_result_free(LCReadResult*);

typedef struct LCWriteJob LCWriteJob;
LCWriteJob*   lc_writer_begin(const char* path, int /*DRW::Version*/ ver, int isDwg);
void          lc_writer_add(LCWriteJob*, const LCEntity*);
int           lc_writer_commit(LCWriteJob*);        // 0 = ok
void          lc_writer_free(LCWriteJob*);
```

**C++ shim collector (the part Swift can't write):**
```cpp
class LCCollector : public DRW_Interface {
public:
    std::vector<LCEntity> entities;
    std::vector<std::string> strPool;   // keeps layer/text alive

    void addLine(const DRW_Line& d) override {
        LCEntity e{}; e.kind = LC_LINE;
        e.p1 = {d.basePoint.x, d.basePoint.y, d.basePoint.z};
        e.p2 = {d.secPoint.x,  d.secPoint.y,  d.secPoint.z};
        e.layer = pool(d.layer); e.color = d.color;
        entities.push_back(e);
    }
    void addLWPolyline(const DRW_LWPolyline& d) override { /* flatten vertlist */ }
    // ... implement every pure-virtual addXxx / writeXxx (most as no-ops) ...
    const char* pool(const std::string& s){ strPool.push_back(s); return strPool.back().c_str(); }
};
```
> Note: a real `LCCollector` must override **every** pure-virtual in `DRW_Interface` (the `add*` read hooks and the `write*` hooks) — the no-op defaults that exist are only on the newer optional hooks; the core ones (`addLine`, `addCircle`, `writeEntities`, `writeLayers`, ...) are `= 0` and must be defined or the shim won't compile. Mirror the skeleton in `rs_filterdxfrw.h` for the exhaustive list.

**Swift facade:**
```swift
public struct LCEntity { /* mirror of C struct, mapped to Swift types */ }

public enum LCDXF {
    public static func read(_ path: String) throws -> [LCEntity] {
        guard let r = lc_dxf_read(path) else { throw LCError.open }
        if let err = lc_result_error(r) { let m = String(cString: err); lc_result_free(r); throw LCError.parse(m) }
        defer { lc_result_free(r) }
        return (0..<lc_result_count(r)).map { mapEntity(lc_result_entity(r, $0)) }
    }
}
```

### Reference: how LibreCAD itself consumes the library
`librecad/src/lib/filters/rs_filterdxfrw.{h,cpp}` — `class RS_FilterDXFRW : public RS_FilterInterface, DRW_Interface`. This is the **canonical, battle-tested example** of implementing `DRW_Interface` and driving `dxfRW`/`dwgRW`. Use its `addXxx`/`writeXxx` override list as the checklist for the shim. (It mixes in Qt/RS_* types — strip those; keep only the DRW_* interaction pattern.) The upstream `dwg2dxf/` example (referenced by CMake, not present in this clone) is an even smaller standalone consumer of the same shape.

---

## 4. Risk list

1. **`DRW_Interface` cannot be implemented in Swift.** Mitigation: implement in C++/ObjC++ shim (core of this plan). Non-negotiable.
2. **Completeness of the flatten layer.** ~50 read callbacks and ~40 writer entity types. MVP can no-op the exotic ones (hatch, mleader, dimensions, underlay, image) and grow incrementally — but the shim must still *compile* all pure-virtuals. Track coverage explicitly.
3. **Ownership/lifetime across the boundary.** `DRW_Header` deletes its `DRW_Variant*`; `DRW_Variant` has self-referential pointers fixed in its copy ctor. Never hand these to Swift; flatten to PODs inside the callback while the C++ object is still alive. String lifetime: keep a string pool in the result handle (as sketched).
4. **DWG version coverage asymmetry.** Reading supports R2000–R2018 (`dwgreader15..32`); **writing DWG supports only R2000 (`AC1015`)**. Surface this in the writer API (reject other versions early). DXF read/write covers the full version range.
5. **DWG read robustness.** Upstream exposes `getEntityParseFailures()` and `getSkippedCustomClasses()` — DWG is reverse-engineered and lossy on vendor custom classes (oType ≥ 500). Plumb these through so the Swift layer can warn the user; don't treat a nonzero failure count as a hard error.
6. **C++ standard / Swift-interop flags.** Build the static lib and the shim with the **same** `-std` (use `-std=c++20`) and the same C++ stdlib (libc++ on macOS — default, no issue). If enabling direct C++ interop on the shim's emitted structs, keep `-cxx-interoperability-mode=default` consistent across the Swift target and the shim's module.
7. **No exceptions today, but build defaults enable them.** Library reports errors via `bool`+`getError()`. Keep the C ABI exception-free (don't let a `std::bad_alloc` escape across the C boundary — wrap shim bodies in `try{}catch{}` returning an error code if you compile with exceptions).
8. **GPL licensing.** libdxfrw is **GPLv2-or-later**. Statically linking it into a new app makes the app a derivative work subject to GPL. Confirm the new macOS app's license is GPL-compatible before shipping. (Legal/process risk, not technical.)
9. **`int handle`/`duint32` truncation.** Some API surfaces (`dxfRW::getBlockRecordHandleToWrite` returns `int`, `setBlock(int)`) narrow 32-bit handles to `int`. Match types carefully in the C ABI (`uint32_t`) to avoid sign issues.
10. **Thread-safety.** `DRW_dbg` is a process-global singleton; `dxfRW`/`dwgRW` instances carry per-file state. Treat read/write as single-threaded per instance; don't share an instance across threads. Fine for a one-shot read/write call.
