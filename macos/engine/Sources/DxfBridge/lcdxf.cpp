/******************************************************************************
**  LibreCAD macOS — DXF bridge implementation (C ABI over libdxfrw)         **
**                                                                           **
**  Derivative work of LibreCAD and libdxfrw, both GPLv2-or-later. The       **
**  DRW_Interface override list mirrors libdxfrw's drw_interface.h and       **
**  LibreCAD's rs_filterdxfrw.h (Qt/RS_* bodies stripped to no-ops).         **
**                                                                           **
**  Copyright (C) 2026 LibreCAD macOS contributors.                          **
**                                                                           **
**  This program is free software; you can redistribute it and/or modify     **
**  it under the terms of the GNU General Public License as published by     **
**  the Free Software Foundation; either version 2 of the License, or        **
**  (at your option) any later version.                                      **
******************************************************************************/

#include "lcdxf.h"

#include <exception>

#include "libdxfrw.h"
#include "drw_interface.h"

namespace {

/**
 * CountingReader implements every pure-virtual of DRW_Interface. The entity
 * add* callbacks bump a counter; everything else (tables, header, blocks,
 * comments, and all the write* hooks that read never invokes) is a no-op.
 */
class CountingReader final : public DRW_Interface {
public:
    int count = 0;

    // ----- header / tables (not counted) -------------------------------------
    void addHeader(const DRW_Header *data) override { (void)data; }
    void addLType(const DRW_LType &data) override { (void)data; }
    void addLayer(const DRW_Layer &data) override { (void)data; }
    void addDimStyle(const DRW_Dimstyle &data) override { (void)data; }
    void addVport(const DRW_Vport &data) override { (void)data; }
    void addTextStyle(const DRW_Textstyle &data) override { (void)data; }
    void addAppId(const DRW_AppId &data) override { (void)data; }

    // ----- block structure (not counted) -------------------------------------
    void addBlock(const DRW_Block &data) override { (void)data; }
    void setBlock(const int handle) override { (void)handle; }
    void endBlock() override {}

    // ----- geometric entities (counted) --------------------------------------
    void addPoint(const DRW_Point &data) override { (void)data; ++count; }
    void addLine(const DRW_Line &data) override { (void)data; ++count; }
    void addRay(const DRW_Ray &data) override { (void)data; ++count; }
    void addXline(const DRW_Xline &data) override { (void)data; ++count; }
    void addArc(const DRW_Arc &data) override { (void)data; ++count; }
    void addCircle(const DRW_Circle &data) override { (void)data; ++count; }
    void addEllipse(const DRW_Ellipse &data) override { (void)data; ++count; }
    void addLWPolyline(const DRW_LWPolyline &data) override { (void)data; ++count; }
    void addPolyline(const DRW_Polyline &data) override { (void)data; ++count; }
    void addSpline(const DRW_Spline *data) override { (void)data; ++count; }
    void addKnot(const DRW_Entity &data) override { (void)data; }  // sub-record, not an entity
    void addInsert(const DRW_Insert &data) override { (void)data; ++count; }
    void addTrace(const DRW_Trace &data) override { (void)data; ++count; }
    void add3dFace(const DRW_3Dface &data) override { (void)data; ++count; }
    void addSolid(const DRW_Solid &data) override { (void)data; ++count; }
    void addMText(const DRW_MText &data) override { (void)data; ++count; }
    void addText(const DRW_Text &data) override { (void)data; ++count; }
    void addDimAlign(const DRW_DimAligned *data) override { (void)data; ++count; }
    void addDimLinear(const DRW_DimLinear *data) override { (void)data; ++count; }
    void addDimRadial(const DRW_DimRadial *data) override { (void)data; ++count; }
    void addDimDiametric(const DRW_DimDiametric *data) override { (void)data; ++count; }
    void addDimAngular(const DRW_DimAngular *data) override { (void)data; ++count; }
    void addDimAngular3P(const DRW_DimAngular3p *data) override { (void)data; ++count; }
    void addDimOrdinate(const DRW_DimOrdinate *data) override { (void)data; ++count; }
    void addLeader(const DRW_Leader *data) override { (void)data; ++count; }
    void addHatch(const DRW_Hatch *data) override { (void)data; ++count; }
    void addViewport(const DRW_Viewport &data) override { (void)data; ++count; }
    void addImage(const DRW_Image *data) override { (void)data; ++count; }
    void linkImage(const DRW_ImageDef *data) override { (void)data; }  // definition, not an entity

    // ----- misc read hooks (not counted) -------------------------------------
    void addComment(const char *comment) override { (void)comment; }
    void addPlotSettings(const DRW_PlotSettings *data) override { (void)data; }

    // ----- write hooks: never called during read; required to be defined -----
    void writeHeader(DRW_Header &data) override { (void)data; }
    void writeBlocks() override {}
    void writeBlockRecords() override {}
    void writeEntities() override {}
    void writeLTypes() override {}
    void writeLayers() override {}
    void writeTextstyles() override {}
    void writeVports() override {}
    void writeDimstyles() override {}
    void writeObjects() override {}
    void writeAppId() override {}
};

}  // namespace

extern "C" LCStatus lc_dxf_count_entities(const char *path, int *out_count) {
    if (path == nullptr || path[0] == '\0') {
        return LC_ERR_INVALID_PATH;
    }
    // try/catch keeps any libdxfrw exception from crossing the C boundary; both
    // a clean read failure and an escaping exception map to LC_ERR_READ_FAILED.
    try {
        CountingReader reader;
        dxfRW dxf(path);
        // ext=false: do not run the (slower) extended/raw parse path.
        const bool ok = dxf.read(&reader, /*ext=*/false);
        if (!ok) {
            return LC_ERR_READ_FAILED;
        }
        if (out_count != nullptr) {
            *out_count = reader.count;
        }
        return LC_OK;
    } catch (...) {
        return LC_ERR_READ_FAILED;
    }
}
