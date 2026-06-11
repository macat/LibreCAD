/******************************************************************************
**  LibreCAD macOS — DXF bridge implementation (C ABI over libdxfrw)         **
**                                                                           **
**  Derivative work of LibreCAD and libdxfrw, both GPLv2-or-later. The       **
**  DRW_Interface override list mirrors libdxfrw's drw_interface.h and       **
**  LibreCAD's rs_filterdxfrw.h (Qt/RS_* bodies stripped); the callback ->   **
**  data mapping (arc/ellipse/polyline/spline fields, layer flags, ACI       **
**  colors) is ported from rs_filterdxfrw.cpp.                               **
**                                                                           **
**  Copyright (C) 2026 LibreCAD macOS contributors.                          **
**  Copyright (C) 2001-2003 RibbonSoft; (C) 2011-2015 José F. Soriano.       **
**                                                                           **
**  This program is free software; you can redistribute it and/or modify     **
**  it under the terms of the GNU General Public License as published by     **
**  the Free Software Foundation; either version 2 of the License, or        **
**  (at your option) any later version.                                      **
******************************************************************************/

#include "lcdxf.h"

#include <cmath>
#include <cstdint>
#include <deque>
#include <exception>
#include <string>
#include <vector>

#include "libdxfrw.h"
#include "drw_interface.h"
#include "drw_objects.h"   // DRW::dxfColors[][3]

/**
 * The owned result handle. Holds the flat POD arrays handed to Swift plus the
 * backing pools that keep their borrowed pointers alive:
 *
 *  - `strings`: a std::deque<std::string> (NOT a vector) so element addresses
 *    are stable across growth — every `const char*` in `entities`/`layers`
 *    points into one of these.
 *  - `vertexPool` / `doublePool`: std::deque of vectors, same stability
 *    rationale, so each entity's `vertices`/`knots`/`weights` pointer stays
 *    valid for the handle's whole lifetime.
 *
 * Everything is freed together by `lc_entity_list_free`.
 */
struct LCEntityList {
    std::vector<LCEntity> entities;
    std::vector<LCLayer>  layers;
    int geometryCount = 0;   // every add* entity libdxfrw delivered

    // Stable-address backing pools (deque: pointers survive growth).
    std::deque<std::string>          strings;
    std::deque<std::vector<LCVertex>> vertexPool;
    std::deque<std::vector<double>>  doublePool;
};

namespace {

/**
 * FlatteningReader implements every DRW_Interface pure-virtual. The geometric
 * add* callbacks flatten their payload into POD copies on `out`; tables collect
 * the layer list; header/blocks/comments and every write* hook (never called on
 * read) are no-ops. The DRW_Interface override list is the checklist
 * (drw_interface.h + rs_filterdxfrw.h).
 */
class FlatteningReader final : public DRW_Interface {
public:
    explicit FlatteningReader(LCEntityList *out) : m_out(out) {}

    // ----- string / array pooling ----------------------------------------
    const char *intern(const std::string &s) {
        m_out->strings.push_back(s);
        return m_out->strings.back().c_str();
    }
    const char *intern(const char *s) {
        return intern(std::string(s ? s : ""));
    }

    // Fill the common (layer/linetype/color/lineweight) attributes from any
    // DRW_Entity. Ported from rs_filterdxfrw.cpp setEntityAttributes.
    void fillCommon(LCEntity &e, const DRW_Entity &src) {
        e.layer = intern(src.layer);
        e.lineType = intern(src.lineType);
        e.color = src.color;
        e.color24 = src.color24;
        e.lineWeightMM100 = DRW_LW_Conv::lineWidth2dxfInt(src.lWeight);
    }

    // Allocate a fresh entity slot with defaulted geometry fields.
    LCEntity makeEntity(int kind) {
        LCEntity e{};
        e.kind = kind;
        e.layer = nullptr;
        e.lineType = nullptr;
        e.color = DRW::ColorByLayer;
        e.color24 = -1;
        e.lineWeightMM100 = -1;
        e.ratio = 1.0;
        e.degree = 0;
        e.closed = 0;
        e.vertices = nullptr;
        e.vertexCount = 0;
        e.knots = nullptr;
        e.knotCount = 0;
        e.weights = nullptr;
        e.weightCount = 0;
        e.typeName = nullptr;
        return e;
    }

    // ----- header / tables -----------------------------------------------
    void addHeader(const DRW_Header *data) override { (void)data; }
    void addLType(const DRW_LType &data) override { (void)data; }

    void addLayer(const DRW_Layer &data) override {
        LCLayer l{};
        l.name = intern(data.name);
        l.lineType = intern(data.lineType);
        // DXF stores a frozen/off layer with a negative color number; the flags
        // (code 70) carry the authoritative frozen/locked bits, so normalize the
        // color to its magnitude here.
        l.color = std::abs(data.color);
        l.color24 = data.color24;
        l.lineWeightMM100 = DRW_LW_Conv::lineWidth2dxfInt(data.lWeight);
        l.flags = data.flags;          // bit0 frozen, bit2 locked
        l.plot = data.plotF ? 1 : 0;
        m_out->layers.push_back(l);
    }

    void addDimStyle(const DRW_Dimstyle &data) override { (void)data; }
    void addVport(const DRW_Vport &data) override { (void)data; }
    void addTextStyle(const DRW_Textstyle &data) override { (void)data; }
    void addAppId(const DRW_AppId &data) override { (void)data; }

    // ----- block structure (collected as no-ops; block expansion is a later
    //        owner's job — see ADR-001 / Block.swift) -----------------------
    void addBlock(const DRW_Block &data) override { (void)data; }
    void setBlock(const int handle) override { (void)handle; }
    void endBlock() override {}

    // ----- geometric entities --------------------------------------------
    void addPoint(const DRW_Point &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_POINT);
        fillCommon(e, data);
        e.p1x = data.basePoint.x; e.p1y = data.basePoint.y; e.p1z = data.basePoint.z;
        m_out->entities.push_back(e);
    }

    void addLine(const DRW_Line &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_LINE);
        fillCommon(e, data);
        e.p1x = data.basePoint.x; e.p1y = data.basePoint.y; e.p1z = data.basePoint.z;
        e.p2x = data.secPoint.x;  e.p2y = data.secPoint.y;  e.p2z = data.secPoint.z;
        m_out->entities.push_back(e);
    }

    // RAY / XLINE: infinite-length construction lines. Not in the frozen entity
    // model; collect as unsupported so Swift warns rather than silently drops.
    void addRay(const DRW_Ray &data) override { addUnsupportedEntity(data, "RAY"); }
    void addXline(const DRW_Xline &data) override { addUnsupportedEntity(data, "XLINE"); }

    void addArc(const DRW_Arc &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_ARC);
        fillCommon(e, data);
        e.cx = data.basePoint.x; e.cy = data.basePoint.y; e.cz = data.basePoint.z;
        e.radius = data.radious;
        e.startAngle = data.staangle;
        e.endAngle = data.endangle;
        m_out->entities.push_back(e);
    }

    void addCircle(const DRW_Circle &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_CIRCLE);
        fillCommon(e, data);
        e.cx = data.basePoint.x; e.cy = data.basePoint.y; e.cz = data.basePoint.z;
        e.radius = data.radious;
        m_out->entities.push_back(e);
    }

    void addEllipse(const DRW_Ellipse &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_ELLIPSE);
        fillCommon(e, data);
        // center=basePoint, major-axis endpoint (relative)=secPoint,
        // ratio, start/end ellipse parameters. Mirrors addEllipse in
        // rs_filterdxfrw.cpp, including the full-ellipse end==0 normalization.
        e.cx = data.basePoint.x; e.cy = data.basePoint.y; e.cz = data.basePoint.z;
        e.p2x = data.secPoint.x; e.p2y = data.secPoint.y; e.p2z = data.secPoint.z;
        e.ratio = data.ratio;
        e.startAngle = data.staparam;
        double ang2 = data.endparam;
        if (std::fabs(ang2 - 2.0 * M_PI) < 1e-10 && std::fabs(data.staparam) < 1e-10) {
            ang2 = 0.0;
        }
        e.endAngle = ang2;
        m_out->entities.push_back(e);
    }

    void addLWPolyline(const DRW_LWPolyline &data) override {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_LWPOLYLINE);
        fillCommon(e, data);
        e.closed = (data.flags & 0x1) ? 1 : 0;
        m_out->vertexPool.emplace_back();
        std::vector<LCVertex> &verts = m_out->vertexPool.back();
        verts.reserve(data.vertlist.size());
        for (const auto &v : data.vertlist) {
            if (v) verts.push_back(LCVertex{v->x, v->y, v->bulge});
        }
        e.vertices = verts.empty() ? nullptr : verts.data();
        e.vertexCount = static_cast<int32_t>(verts.size());
        m_out->entities.push_back(e);
    }

    void addPolyline(const DRW_Polyline &data) override {
        ++m_out->geometryCount;
        // Only the simple 2D polyline is flattened; 3D meshes / polyface meshes
        // (flags 0x10 / 0x40) are not in the frozen model -> unsupported warning.
        if ((data.flags & 0x10) || (data.flags & 0x40)) {
            LCEntity e = makeEntity(LC_ENT_UNSUPPORTED);
            fillCommon(e, data);
            e.typeName = intern("POLYLINE_MESH");
            m_out->entities.push_back(e);
            return;
        }
        LCEntity e = makeEntity(LC_ENT_POLYLINE);
        fillCommon(e, data);
        e.closed = (data.flags & 0x1) ? 1 : 0;
        m_out->vertexPool.emplace_back();
        std::vector<LCVertex> &verts = m_out->vertexPool.back();
        verts.reserve(data.vertlist.size());
        for (const auto &v : data.vertlist) {
            if (v) verts.push_back(LCVertex{v->basePoint.x, v->basePoint.y, v->bulge});
        }
        e.vertices = verts.empty() ? nullptr : verts.data();
        e.vertexCount = static_cast<int32_t>(verts.size());
        m_out->entities.push_back(e);
    }

    void addSpline(const DRW_Spline *data) override {
        ++m_out->geometryCount;
        if (data == nullptr) return;
        LCEntity e = makeEntity(LC_ENT_SPLINE);
        fillCommon(e, *data);
        e.degree = data->degree;
        e.closed = (data->flags & 0x1) ? 1 : 0;

        // Control points -> vertices (bulge unused). Mirrors addSpline's
        // controllist walk in rs_filterdxfrw.cpp.
        m_out->vertexPool.emplace_back();
        std::vector<LCVertex> &cps = m_out->vertexPool.back();
        cps.reserve(data->controllist.size());
        for (const auto &c : data->controllist) {
            if (c) cps.push_back(LCVertex{c->x, c->y, 0.0});
        }
        e.vertices = cps.empty() ? nullptr : cps.data();
        e.vertexCount = static_cast<int32_t>(cps.size());

        // Knots.
        m_out->doublePool.emplace_back(data->knotslist.begin(), data->knotslist.end());
        std::vector<double> &knots = m_out->doublePool.back();
        e.knots = knots.empty() ? nullptr : knots.data();
        e.knotCount = static_cast<int32_t>(knots.size());

        // Weights.
        m_out->doublePool.emplace_back(data->weightlist.begin(), data->weightlist.end());
        std::vector<double> &weights = m_out->doublePool.back();
        e.weights = weights.empty() ? nullptr : weights.data();
        e.weightCount = static_cast<int32_t>(weights.size());

        m_out->entities.push_back(e);
    }

    void addKnot(const DRW_Entity &data) override { (void)data; } // sub-record

    // ----- entities not in the frozen geometry model: count + warn --------
    void addInsert(const DRW_Insert &data) override { addUnsupportedEntity(data, "INSERT"); }
    void addTrace(const DRW_Trace &data) override { addUnsupportedEntity(data, "TRACE"); }
    void add3dFace(const DRW_3Dface &data) override { addUnsupportedEntity(data, "3DFACE"); }
    void addSolid(const DRW_Solid &data) override { addUnsupportedEntity(data, "SOLID"); }
    void addMText(const DRW_MText &data) override { addUnsupportedEntity(data, "MTEXT"); }
    void addText(const DRW_Text &data) override { addUnsupportedEntity(data, "TEXT"); }
    void addDimAlign(const DRW_DimAligned *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimLinear(const DRW_DimLinear *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimRadial(const DRW_DimRadial *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimDiametric(const DRW_DimDiametric *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimAngular(const DRW_DimAngular *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimAngular3P(const DRW_DimAngular3p *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addDimOrdinate(const DRW_DimOrdinate *data) override { addUnsupportedDim(data, "DIMENSION"); }
    void addLeader(const DRW_Leader *data) override { addUnsupportedDim(data, "LEADER"); }
    void addHatch(const DRW_Hatch *data) override { addUnsupportedDim(data, "HATCH"); }
    void addViewport(const DRW_Viewport &data) override { addUnsupportedEntity(data, "VIEWPORT"); }
    void addImage(const DRW_Image *data) override { addUnsupportedDim(data, "IMAGE"); }
    void linkImage(const DRW_ImageDef *data) override { (void)data; } // definition, not entity

    // ----- misc read hooks (not collected) -------------------------------
    void addComment(const char *comment) override { (void)comment; }
    void addPlotSettings(const DRW_PlotSettings *data) override { (void)data; }

    // ----- write hooks: never called during read; required to be defined --
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

private:
    LCEntityList *m_out;

    // Common path for an entity passed by const-ref that we don't flatten.
    template <typename T>
    void addUnsupportedEntity(const T &data, const char *name) {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_UNSUPPORTED);
        fillCommon(e, data);
        e.typeName = intern(name);
        m_out->entities.push_back(e);
    }

    // Common path for an entity passed by const-pointer (dimensions, hatch,
    // leader, image) that we don't flatten.
    template <typename T>
    void addUnsupportedDim(const T *data, const char *name) {
        ++m_out->geometryCount;
        LCEntity e = makeEntity(LC_ENT_UNSUPPORTED);
        if (data) fillCommon(e, *data);
        else { e.layer = intern("0"); e.lineType = intern("BYLAYER"); }
        e.typeName = intern(name);
        m_out->entities.push_back(e);
    }
};

}  // namespace

// --------------------------------------------------------------------------
//  C ABI
// --------------------------------------------------------------------------

extern "C" LCStatus lc_dxf_read(const char *path, LCEntityList **out) {
    if (path == nullptr || path[0] == '\0' || out == nullptr) {
        return LC_ERR_INVALID_PATH;
    }
    // try/catch keeps any libdxfrw exception (or std::bad_alloc) from crossing
    // the C boundary; a clean read failure and an escaping exception both map to
    // LC_ERR_READ_FAILED.
    try {
        auto *list = new LCEntityList();
        FlatteningReader reader(list);
        dxfRW dxf(path);
        // ext=false: skip the (slower) extended/raw parse path.
        const bool ok = dxf.read(&reader, /*ext=*/false);
        if (!ok) {
            delete list;
            return LC_ERR_READ_FAILED;
        }
        *out = list;
        return LC_OK;
    } catch (...) {
        return LC_ERR_READ_FAILED;
    }
}

extern "C" int lc_entity_list_count(const LCEntityList *list) {
    return list ? static_cast<int>(list->entities.size()) : 0;
}

extern "C" const LCEntity *lc_entity_list_entities(const LCEntityList *list) {
    if (list == nullptr || list->entities.empty()) return nullptr;
    return list->entities.data();
}

extern "C" int lc_entity_list_geometry_count(const LCEntityList *list) {
    return list ? list->geometryCount : 0;
}

extern "C" int lc_layer_count(const LCEntityList *list) {
    return list ? static_cast<int>(list->layers.size()) : 0;
}

extern "C" const LCLayer *lc_layers(const LCEntityList *list) {
    if (list == nullptr || list->layers.empty()) return nullptr;
    return list->layers.data();
}

extern "C" void lc_entity_list_free(LCEntityList *list) {
    delete list;
}

extern "C" int32_t lc_aci_to_rgb(int32_t aci) {
    // 0 == ByBlock, 256 == ByLayer, out-of-range -> inherit. Mirrors
    // RS_FilterDXFRW::numberToColor's sentinel handling.
    if (aci <= 0 || aci > 255) {
        return -1;
    }
    const unsigned char *c = DRW::dxfColors[aci];
    return (static_cast<int32_t>(c[0]) << 16)
         | (static_cast<int32_t>(c[1]) << 8)
         |  static_cast<int32_t>(c[2]);
}

extern "C" LCStatus lc_dxf_count_entities(const char *path, int *out_count) {
    LCEntityList *list = nullptr;
    const LCStatus status = lc_dxf_read(path, &list);
    if (status != LC_OK) {
        return status;
    }
    if (out_count != nullptr) {
        *out_count = list->geometryCount;
    }
    lc_entity_list_free(list);
    return LC_OK;
}
