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

// ===========================================================================
//  Writer: flat POD arrays -> DXF, via libdxfrw's write path.
// ===========================================================================

/**
 * Mirror of the reader, in reverse: a DRW_Interface whose write* callbacks emit
 * the caller-supplied LCEntity / LCLayer PODs through dxfRW's write API. The
 * `writeEntities()` / `writeLayers()` / `writeLTypes()` callbacks are the ones
 * libdxfrw drives during a `write()`; the rest are required no-ops (some emit a
 * minimal standard table so the file is well-formed).
 *
 * The per-entity attribute and per-kind geometry mapping is the inverse of
 * FlatteningReader above and of rs_filterdxfrw.cpp's write* callbacks.
 */
class WritingInterface final : public DRW_Interface {
public:
    WritingInterface(dxfRW *dxf,
                     const LCEntity *entities, int entityCount,
                     const LCLayer *layers, int layerCount)
        : m_dxf(dxf),
          m_entities(entities), m_entityCount(entityCount < 0 ? 0 : entityCount),
          m_layers(layers), m_layerCount(layerCount < 0 ? 0 : layerCount) {}

    int skipped() const { return m_skipped; }

    // ----- attribute mapping (inverse of FlatteningReader::fillCommon) -----
    void fillCommon(DRW_Entity &ent, const LCEntity &src) {
        ent.layer    = (src.layer    && src.layer[0])    ? std::string(src.layer)    : std::string("0");
        ent.lineType = (src.lineType && src.lineType[0]) ? std::string(src.lineType) : std::string("BYLAYER");
        ent.color    = src.color;
        ent.color24  = src.color24;
        // src.lineWeightMM100 holds the DXF lineweight integer (mm*100 / sentinel
        // -1/-2/-3), exactly what dxfInt2lineWidth expects.
        ent.lWeight  = DRW_LW_Conv::dxfInt2lineWidth(src.lineWeightMM100);
    }

    // ----- the table/entity callbacks libdxfrw drives during write() -------
    void writeLayers() override {
        bool wroteLayer0 = false;
        for (int i = 0; i < m_layerCount; ++i) {
            const LCLayer &l = m_layers[i];
            const std::string name = (l.name && l.name[0]) ? std::string(l.name) : std::string("0");
            if (name == "0") wroteLayer0 = true;
            DRW_Layer lay;          // ctor sets sane defaults
            lay.name     = name;
            lay.lineType = (l.lineType && l.lineType[0]) ? std::string(l.lineType) : std::string("CONTINUOUS");
            lay.color    = l.color;
            lay.color24  = l.color24;
            lay.lWeight  = DRW_LW_Conv::dxfInt2lineWidth(l.lineWeightMM100);
            lay.flags    = l.flags;     // bit0 frozen, bit2 locked
            lay.plotF    = (l.plot != 0);
            m_dxf->writeLayer(&lay);
        }
        // DXF requires layer "0"; synthesize it if the caller didn't supply one.
        if (!wroteLayer0) {
            DRW_Layer lay;
            lay.name = "0";
            m_dxf->writeLayer(&lay);
        }
    }

    void writeEntities() override {
        for (int i = 0; i < m_entityCount; ++i) {
            writeEntity(m_entities[i]);
        }
    }

    // libdxfrw drives this once; emit the minimal standard linetypes LibreCAD
    // also writes so referencing CONTINUOUS/BYLAYER/BYBLOCK names resolve.
    void writeLTypes() override {
        writeStdLType("CONTINUOUS", "Solid line");
        writeStdLType("ByLayer", "");
        writeStdLType("ByBlock", "");
    }

    void writeTextstyles() override {
        // A single "Standard" text style keeps R2000 readers happy even though
        // we emit no TEXT entities yet.
        DRW_Textstyle ts;
        ts.name = "Standard";
        m_dxf->writeTextstyle(&ts);
    }

    // ----- header: leave libdxfrw's defaults (it fills $ACADVER etc.) -------
    void writeHeader(DRW_Header &data) override { (void)data; }

    // ----- required no-ops --------------------------------------------------
    void writeBlocks() override {}
    void writeBlockRecords() override {}
    void writeVports() override {}
    void writeDimstyles() override {}
    void writeObjects() override {}
    void writeAppId() override {}

    // ----- read callbacks: never called during write; required to be defined -
    void addHeader(const DRW_Header *data) override { (void)data; }
    void addLType(const DRW_LType &data) override { (void)data; }
    void addLayer(const DRW_Layer &data) override { (void)data; }
    void addDimStyle(const DRW_Dimstyle &data) override { (void)data; }
    void addVport(const DRW_Vport &data) override { (void)data; }
    void addTextStyle(const DRW_Textstyle &data) override { (void)data; }
    void addAppId(const DRW_AppId &data) override { (void)data; }
    void addBlock(const DRW_Block &data) override { (void)data; }
    void setBlock(const int handle) override { (void)handle; }
    void endBlock() override {}
    void addPoint(const DRW_Point &data) override { (void)data; }
    void addLine(const DRW_Line &data) override { (void)data; }
    void addRay(const DRW_Ray &data) override { (void)data; }
    void addXline(const DRW_Xline &data) override { (void)data; }
    void addArc(const DRW_Arc &data) override { (void)data; }
    void addCircle(const DRW_Circle &data) override { (void)data; }
    void addEllipse(const DRW_Ellipse &data) override { (void)data; }
    void addLWPolyline(const DRW_LWPolyline &data) override { (void)data; }
    void addPolyline(const DRW_Polyline &data) override { (void)data; }
    void addSpline(const DRW_Spline *data) override { (void)data; }
    void addKnot(const DRW_Entity &data) override { (void)data; }
    void addInsert(const DRW_Insert &data) override { (void)data; }
    void addTrace(const DRW_Trace &data) override { (void)data; }
    void add3dFace(const DRW_3Dface &data) override { (void)data; }
    void addSolid(const DRW_Solid &data) override { (void)data; }
    void addMText(const DRW_MText &data) override { (void)data; }
    void addText(const DRW_Text &data) override { (void)data; }
    void addDimAlign(const DRW_DimAligned *data) override { (void)data; }
    void addDimLinear(const DRW_DimLinear *data) override { (void)data; }
    void addDimRadial(const DRW_DimRadial *data) override { (void)data; }
    void addDimDiametric(const DRW_DimDiametric *data) override { (void)data; }
    void addDimAngular(const DRW_DimAngular *data) override { (void)data; }
    void addDimAngular3P(const DRW_DimAngular3p *data) override { (void)data; }
    void addDimOrdinate(const DRW_DimOrdinate *data) override { (void)data; }
    void addLeader(const DRW_Leader *data) override { (void)data; }
    void addHatch(const DRW_Hatch *data) override { (void)data; }
    void addViewport(const DRW_Viewport &data) override { (void)data; }
    void addImage(const DRW_Image *data) override { (void)data; }
    void linkImage(const DRW_ImageDef *data) override { (void)data; }
    void addComment(const char *comment) override { (void)comment; }
    void addPlotSettings(const DRW_PlotSettings *data) override { (void)data; }

private:
    dxfRW *m_dxf;
    const LCEntity *m_entities;
    int m_entityCount;
    const LCLayer *m_layers;
    int m_layerCount;
    int m_skipped = 0;

    void writeStdLType(const char *name, const char *desc) {
        DRW_LType lt;
        lt.name = name;
        lt.desc = desc;
        lt.size = 0;
        lt.length = 0.0;
        m_dxf->writeLineType(&lt);
    }

    // Dispatch one POD entity to the matching writer. Unsupported kinds are
    // counted and skipped (mirrors the reader's unsupported-warning path).
    void writeEntity(const LCEntity &e) {
        switch (e.kind) {
        case LC_ENT_LINE:       writeLine(e);       break;
        case LC_ENT_POINT:      writePoint(e);      break;
        case LC_ENT_CIRCLE:     writeCircle(e);     break;
        case LC_ENT_ARC:        writeArc(e);        break;
        case LC_ENT_ELLIPSE:    writeEllipse(e);    break;
        case LC_ENT_LWPOLYLINE: writeLWPolyline(e); break;
        case LC_ENT_POLYLINE:   writeLWPolyline(e); break; // emit as LWPOLYLINE
        default:                ++m_skipped;        break; // SPLINE / UNSUPPORTED / ...
        }
    }

    void writePoint(const LCEntity &e) {
        DRW_Point p;
        fillCommon(p, e);
        p.basePoint.x = e.p1x; p.basePoint.y = e.p1y; p.basePoint.z = e.p1z;
        m_dxf->writePoint(&p);
    }

    void writeLine(const LCEntity &e) {
        DRW_Line l;
        fillCommon(l, e);
        l.basePoint.x = e.p1x; l.basePoint.y = e.p1y; l.basePoint.z = e.p1z;
        l.secPoint.x  = e.p2x; l.secPoint.y  = e.p2y; l.secPoint.z  = e.p2z;
        m_dxf->writeLine(&l);
    }

    void writeCircle(const LCEntity &e) {
        DRW_Circle c;
        fillCommon(c, e);
        c.basePoint.x = e.cx; c.basePoint.y = e.cy; c.basePoint.z = e.cz;
        c.radious = e.radius;
        m_dxf->writeCircle(&c);
    }

    void writeArc(const LCEntity &e) {
        DRW_Arc a;
        fillCommon(a, e);
        a.basePoint.x = e.cx; a.basePoint.y = e.cy; a.basePoint.z = e.cz;
        a.radious  = e.radius;
        a.staangle = e.startAngle;   // POD already carries CCW start/end
        a.endangle = e.endAngle;
        m_dxf->writeArc(&a);
    }

    void writeEllipse(const LCEntity &e) {
        DRW_Ellipse el;
        fillCommon(el, e);
        el.basePoint.x = e.cx;  el.basePoint.y = e.cy;  el.basePoint.z = e.cz;
        el.secPoint.x  = e.p2x; el.secPoint.y  = e.p2y; el.secPoint.z  = e.p2z;
        el.ratio    = e.ratio;
        el.staparam = e.startAngle;
        el.endparam = e.endAngle;
        m_dxf->writeEllipse(&el);
    }

    void writeLWPolyline(const LCEntity &e) {
        DRW_LWPolyline pol;
        fillCommon(pol, e);
        pol.flags = (e.closed != 0) ? 1 : 0;
        if (e.vertexCount > 0 && e.vertices != nullptr) {
            for (int i = 0; i < e.vertexCount; ++i) {
                const LCVertex &v = e.vertices[i];
                pol.addVertex(DRW_Vertex2D(v.x, v.y, v.bulge));
            }
        }
        pol.vertexnum = static_cast<int>(pol.vertlist.size());
        m_dxf->writeLWPolyline(&pol);
    }
};

// Map the public LCDxfVersion enum onto libdxfrw's DRW::Version; default R2000.
inline DRW::Version toDrwVersion(int v) {
    switch (v) {
    case LC_DXF_R12:   return DRW::AC1009;
    case LC_DXF_R14:   return DRW::AC1014;
    case LC_DXF_R2000: return DRW::AC1015;
    case LC_DXF_R2004: return DRW::AC1018;
    case LC_DXF_R2007: return DRW::AC1021;
    case LC_DXF_R2018: return DRW::AC1032;
    default:           return DRW::AC1015;
    }
}

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

extern "C" LCStatus lc_dxf_write(const char *path,
                                 const LCEntity *entities, int entityCount,
                                 const LCLayer *layers, int layerCount,
                                 int version,
                                 int *out_skipped) {
    if (out_skipped != nullptr) {
        *out_skipped = 0;
    }
    if (path == nullptr || path[0] == '\0') {
        return LC_ERR_INVALID_PATH;
    }
    // A negative count with a NULL array is a programmer error; treat a
    // non-positive count as "no items" and clamp to a NULL-safe path.
    if ((entityCount > 0 && entities == nullptr) ||
        (layerCount  > 0 && layers   == nullptr)) {
        return LC_ERR_INVALID_PATH;
    }
    // try/catch keeps any libdxfrw exception (or std::bad_alloc) from crossing
    // the C boundary; a clean write failure and an escaping exception both map
    // to LC_ERR_WRITE_FAILED.
    try {
        dxfRW dxf(path);
        WritingInterface iface(&dxf, entities, entityCount, layers, layerCount);
        // bin=false -> ASCII DXF (matches the reader and rs_filterdxfrw).
        const bool ok = dxf.write(&iface, toDrwVersion(version), /*bin=*/false);
        if (!ok) {
            return LC_ERR_WRITE_FAILED;
        }
        if (out_skipped != nullptr) {
            *out_skipped = iface.skipped();
        }
        return LC_OK;
    } catch (...) {
        return LC_ERR_WRITE_FAILED;
    }
}
