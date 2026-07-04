/**
 * dxfrw_writer.cpp
 *
 * Implements dxfrw_write() — a C-compatible bridge that uses libdxfrw's
 * dxfRW writer to produce valid ASCII DXF files from the same POD structs
 * used by the reader bridge (DXFRW_EntityData, DXFRW_LayerData, etc.).
 */

#include "dxfrw_bridge.h"

#ifdef DEBUG
#undef DEBUG
#endif

#include "drw_entities.h"
#include "drw_objects.h"
#include "drw_header.h"
#include "drw_interface.h"
#include "libdxfrw.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>

#define WR_TRACE(fmt, ...)                                                     \
  do {                                                                         \
    std::fprintf(stderr, "[DXFRW-WRITE] " fmt "\n", ##__VA_ARGS__);            \
    std::fflush(stderr);                                                       \
  } while (0)

// ── Helpers ────────────────────────────────────────────────────────────────

// Convert C bridge coord → libdxfrw coord (different types despite same layout)
static DRW_Coord toDRW(const DXFRW_Coord &c) {
  DRW_Coord out;
  out.x = c.x; out.y = c.y; out.z = c.z;
  return out;
}

static int resolveColor(const DXFRW_EntityData *e) {
  if (e->color24 >= 0)
    return e->color24;
  return e->color;
}

static void fillEntity(DRW_Entity &ent, const DXFRW_EntityData *e) {
  if (e->layerName && e->layerName[0])
    ent.layer = std::string(e->layerName);
  else
    ent.layer = "0";
  ent.color = resolveColor(e);
  ent.lWeight = DRW_LW_Conv::lineWidth::widthDefault;
  if (e->lineWeight > 0) {
    int lw = (int)(e->lineWeight * 100.0 + 0.5);
    switch (lw) {
    case 0:   ent.lWeight = DRW_LW_Conv::lineWidth::width00; break;
    case 5:   ent.lWeight = DRW_LW_Conv::lineWidth::width01; break;
    case 9:   ent.lWeight = DRW_LW_Conv::lineWidth::width02; break;
    case 13:  ent.lWeight = DRW_LW_Conv::lineWidth::width03; break;
    case 15:  ent.lWeight = DRW_LW_Conv::lineWidth::width04; break;
    case 18:  ent.lWeight = DRW_LW_Conv::lineWidth::width05; break;
    case 20:  ent.lWeight = DRW_LW_Conv::lineWidth::width06; break;
    case 25:  ent.lWeight = DRW_LW_Conv::lineWidth::width07; break;
    case 30:  ent.lWeight = DRW_LW_Conv::lineWidth::width08; break;
    case 35:  ent.lWeight = DRW_LW_Conv::lineWidth::width09; break;
    case 40:  ent.lWeight = DRW_LW_Conv::lineWidth::width10; break;
    case 50:  ent.lWeight = DRW_LW_Conv::lineWidth::width11; break;
    case 53:  ent.lWeight = DRW_LW_Conv::lineWidth::width12; break;
    case 60:  ent.lWeight = DRW_LW_Conv::lineWidth::width13; break;
    case 70:  ent.lWeight = DRW_LW_Conv::lineWidth::width14; break;
    case 80:  ent.lWeight = DRW_LW_Conv::lineWidth::width15; break;
    case 90:  ent.lWeight = DRW_LW_Conv::lineWidth::width16; break;
    case 100: ent.lWeight = DRW_LW_Conv::lineWidth::width17; break;
    case 106: ent.lWeight = DRW_LW_Conv::lineWidth::width18; break;
    case 120: ent.lWeight = DRW_LW_Conv::lineWidth::width19; break;
    case 140: ent.lWeight = DRW_LW_Conv::lineWidth::width20; break;
    case 158: ent.lWeight = DRW_LW_Conv::lineWidth::width21; break;
    case 200: ent.lWeight = DRW_LW_Conv::lineWidth::width22; break;
    case 211: ent.lWeight = DRW_LW_Conv::lineWidth::width23; break;
    default:  ent.lWeight = DRW_LW_Conv::lineWidth::widthDefault; break;
    }
  }
  if (e->lineTypeName && e->lineTypeName[0])
    ent.lineType = std::string(e->lineTypeName);
  else
    ent.lineType = "ByLayer";
}

// ── Writer class ───────────────────────────────────────────────────────────

class DXFRWWrap : public DRW_Interface {
public:
  dxfRW *writer;
  const DXFRW_EntityData *entities;
  int entityCount;
  const DXFRW_LayerData *layers;
  int layerCount;
  const DXFRW_BlockData *blocks;
  int blockCount;
  bool hadLayer0;

  // ── Reader callbacks (unused) ──────────────────────────────────────────
  void addHeader(const DRW_Header *) override {}
  void addLType(const DRW_LType &) override {}
  void addLayer(const DRW_Layer &) override {}
  void addDimStyle(const DRW_Dimstyle &) override {}
  void addVport(const DRW_Vport &) override {}
  void addTextStyle(const DRW_Textstyle &) override {}
  void addAppId(const DRW_AppId &) override {}
  void addBlock(const DRW_Block &) override {}
  void setBlock(const int) override {}
  void endBlock() override {}
  void addPoint(const DRW_Point &) override {}
  void addLine(const DRW_Line &) override {}
  void addRay(const DRW_Ray &) override {}
  void addXline(const DRW_Xline &) override {}
  void addArc(const DRW_Arc &) override {}
  void addCircle(const DRW_Circle &) override {}
  void addEllipse(const DRW_Ellipse &) override {}
  void addLWPolyline(const DRW_LWPolyline &) override {}
  void addPolyline(const DRW_Polyline &) override {}
  void addSpline(const DRW_Spline *) override {}
  void addKnot(const DRW_Entity &) override {}
  void addInsert(const DRW_Insert &) override {}
  void addTrace(const DRW_Trace &) override {}
  void add3dFace(const DRW_3Dface &) override {}
  void addSolid(const DRW_Solid &) override {}
  void addMText(const DRW_MText &) override {}
  void addText(const DRW_Text &) override {}
  void addDimAlign(const DRW_DimAligned *) override {}
  void addDimLinear(const DRW_DimLinear *) override {}
  void addDimRadial(const DRW_DimRadial *) override {}
  void addDimDiametric(const DRW_DimDiametric *) override {}
  void addDimAngular(const DRW_DimAngular *) override {}
  void addDimAngular3P(const DRW_DimAngular3p *) override {}
  void addDimOrdinate(const DRW_DimOrdinate *) override {}
  void addLeader(const DRW_Leader *) override {}
  void addHatch(const DRW_Hatch *) override {}
  void addViewport(const DRW_Viewport &) override {}
  void addImage(const DRW_Image *) override {}
  void linkImage(const DRW_ImageDef *) override {}
  void addComment(const char *) override {}

  // ── Write callbacks ────────────────────────────────────────────────────
  void writeHeader(DRW_Header &) override {}
  void writeLTypes() override {
    // Mandatory linetypes (ByBlock, ByLayer, Continuous) are already written
    // by libdxfrw's writeTables(). Additional custom linetypes go here.
  }

  void writeLayers() override {
    hadLayer0 = false;
    for (int i = 0; i < layerCount; i++) {
      const DXFRW_LayerData *l = &layers[i];
      DRW_Layer layer;
      layer.name = std::string(l->name ? l->name : "0");
      layer.color = l->color;
      if (l->color24 >= 0) layer.color = l->color24;
      layer.lineType = std::string(l->lineTypeName && l->lineTypeName[0] ? l->lineTypeName : "Continuous");
      layer.plotF = l->plotFlag != 0;
      writer->writeLayer(&layer);
      if (layer.name == "0") hadLayer0 = true;
    }
    if (!hadLayer0) {
      DRW_Layer l0;
      l0.name = "0";
      l0.color = 7;
      l0.lineType = "Continuous";
      writer->writeLayer(&l0);
    }
  }

  void writeDimstyles() override {
    DRW_Dimstyle ds;
    ds.name = "Standard";
    ds.dimasz = 2.5;
    ds.dimexo = 0.625;
    ds.dimexe = 1.25;
    ds.dimtxt = 2.5;
    ds.dimtad = 1;
    ds.dimzin = 8;
    ds.dimtofl = 1;
    ds.dimlunit = 2;
    ds.dimscale = 1.0;
    writer->writeDimstyle(&ds);
  }

  void writeTextstyles() override {
    DRW_Textstyle ts;
    ts.name = "Standard";
    ts.font = "txt";
    ts.height = 0.0;
    ts.width = 1.0;
    ts.oblique = 0.0;
    writer->writeTextstyle(&ts);
  }

  void writeVports() override {
    // Let libdxfrw's writeTables() handle the *ACTIVE vport automatically
  }

  void writeAppId() override {
    DRW_AppId app;
    app.name = "ACAD";
    writer->writeAppId(&app);
  }

  void writeBlockRecords() override {
    writer->writeBlockRecord("*Model_Space");
    writer->writeBlockRecord("*Paper_Space");
    for (int i = 0; i < blockCount; i++)
      writer->writeBlockRecord(std::string(blocks[i].name));
  }

  void writeBlocks() override {
    DRW_Block mb;
    mb.name = "*Model_Space";
    mb.basePoint.x = 0; mb.basePoint.y = 0; mb.basePoint.z = 0;
    writer->writeBlock(&mb);

    DRW_Block pb;
    pb.name = "*Paper_Space";
    pb.basePoint.x = 0; pb.basePoint.y = 0; pb.basePoint.z = 0;
    writer->writeBlock(&pb);

    for (int i = 0; i < blockCount; i++) {
      DRW_Block blk;
      blk.name = std::string(blocks[i].name);
      blk.basePoint.x = blocks[i].basePoint.x;
      blk.basePoint.y = blocks[i].basePoint.y;
      blk.basePoint.z = blocks[i].basePoint.z;
      blk.flags = blocks[i].flags;
      writer->writeBlock(&blk);
      for (int j = 0; j < entityCount; j++) {
        const DXFRW_EntityData *e = &entities[j];
        if (!e->parentBlockName)
          continue;
        if (std::strcmp(e->parentBlockName, blocks[i].name) != 0)
          continue;
        writeOneEntity(e);
      }
    }
  }

  void writeEntities() override {
    for (int i = 0; i < entityCount; i++) {
      const DXFRW_EntityData *e = &entities[i];
      if (e->parentBlockName && e->parentBlockName[0])
        continue;
      writeOneEntity(e);
    }
  }

private:
  void writeOneEntity(const DXFRW_EntityData *e) {
    switch (e->type) {
    case DXFRW_ET_POINT:     writePoint(e); break;
    case DXFRW_ET_LINE:      writeLine(e); break;
    case DXFRW_ET_CIRCLE:    writeCircle(e); break;
    case DXFRW_ET_ARC:       writeArc(e); break;
    case DXFRW_ET_ELLIPSE:   writeEllipse(e); break;
    case DXFRW_ET_LWPOLYLINE: writeLWPolyline(e); break;
    case DXFRW_ET_POLYLINE:  writePolyline(e); break;
    case DXFRW_ET_TEXT:      writeText(e); break;
    case DXFRW_ET_MTEXT:     writeMText(e); break;
    case DXFRW_ET_INSERT:    writeInsert(e); break;
    case DXFRW_ET_SPLINE:    writeSpline(e); break;
    case DXFRW_ET_HATCH:     writeHatch(e); break;
    case DXFRW_ET_SOLID:     writeSolid(e); break;
    case DXFRW_ET_3DFACE:    write3dFace(e); break;
    default: break;
    }
  }

  void writePoint(const DXFRW_EntityData *e) {
    DRW_Point pt;
    fillEntity(pt, e);
    pt.basePoint = toDRW(e->basePoint);
    writer->writePoint(&pt);
  }

  void writeLine(const DXFRW_EntityData *e) {
    DRW_Line line;
    fillEntity(line, e);
    line.basePoint = toDRW(e->basePoint);
    line.secPoint = toDRW(e->secPoint);
    writer->writeLine(&line);
  }

  void writeCircle(const DXFRW_EntityData *e) {
    DRW_Circle c;
    fillEntity(c, e);
    c.basePoint = toDRW(e->basePoint);
    c.radious = e->radius;
    writer->writeCircle(&c);
  }

  void writeArc(const DXFRW_EntityData *e) {
    DRW_Arc a;
    fillEntity(a, e);
    a.basePoint = toDRW(e->basePoint);
    a.radious = e->radius;
    a.staangle = e->startAngle;
    a.endangle = e->endAngle;
    writer->writeArc(&a);
  }

  void writeEllipse(const DXFRW_EntityData *e) {
    DRW_Ellipse el;
    fillEntity(el, e);
    el.basePoint = toDRW(e->basePoint);
    el.secPoint = toDRW(e->secPoint);
    el.ratio = e->axisRatio;
    el.staparam = e->startAngle;
    el.endparam = e->endAngle;
    writer->writeEllipse(&el);
  }

  void writeLWPolyline(const DXFRW_EntityData *e) {
    DRW_LWPolyline lw;
    fillEntity(lw, e);
    lw.flags = e->flags;
    lw.vertexnum = e->vertexCount;
    for (int i = 0; i < e->vertexCount; i++) {
      DRW_Vertex2D v;
      v.x = e->vertices[i].x;
      v.y = e->vertices[i].y;
      v.stawidth = e->vertices[i].startWidth;
      v.endwidth = e->vertices[i].endWidth;
      v.bulge = e->vertices[i].bulge;
      lw.addVertex(v);
    }
    writer->writeLWPolyline(&lw);
  }

  void writePolyline(const DXFRW_EntityData *e) {
    DRW_Polyline pl;
    fillEntity(pl, e);
    pl.flags = e->flags;
    for (int i = 0; i < e->vertexCount; i++) {
      DRW_Vertex v(e->vertices[i].x, e->vertices[i].y, 0.0, e->vertices[i].bulge);
      v.stawidth = e->vertices[i].startWidth;
      v.endwidth = e->vertices[i].endWidth;
      pl.addVertex(v);
    }
    writer->writePolyline(&pl);
  }

  void writeText(const DXFRW_EntityData *e) {
    DRW_Text txt;
    fillEntity(txt, e);
    txt.basePoint = toDRW(e->basePoint);
    txt.secPoint = toDRW(e->secPoint);
    txt.text = std::string(e->textValue ? e->textValue : "");
    txt.height = e->textHeight;
    txt.style = std::string(e->textStyle ? e->textStyle : "Standard");
    txt.angle = e->textAngle;
    txt.alignH = (DRW_Text::HAlign)e->alignH;
    txt.alignV = (DRW_Text::VAlign)e->alignV;
    writer->writeText(&txt);
  }

  void writeMText(const DXFRW_EntityData *e) {
    DRW_MText mt;
    fillEntity(mt, e);
    mt.basePoint = toDRW(e->basePoint);
    mt.text = std::string(e->textValue ? e->textValue : "");
    mt.height = e->textHeight;
    mt.style = std::string(e->textStyle ? e->textStyle : "Standard");
    mt.angle = e->textAngle;
    writer->writeMText(&mt);
  }

  void writeInsert(const DXFRW_EntityData *e) {
    DRW_Insert ins;
    fillEntity(ins, e);
    ins.basePoint = toDRW(e->basePoint);
    ins.name = std::string(e->blockName ? e->blockName : "");
    ins.xscale = e->xscale;
    ins.yscale = e->yscale;
    ins.zscale = e->zscale;
    ins.angle = e->insertAngle;
    ins.colcount = e->colCount;
    ins.rowcount = e->rowCount;
    ins.colspace = e->colSpace;
    ins.rowspace = e->rowSpace;
    writer->writeInsert(&ins);
  }

  void writeSpline(const DXFRW_EntityData *e) {
    DRW_Spline sp;
    fillEntity(sp, e);
    sp.degree = e->splineDegree;
    sp.nknots = e->splineNKnots;
    sp.ncontrol = e->splineNControl;
    for (int i = 0; i < e->splineNKnots; i++)
      sp.knotslist.push_back(e->splineKnots[i]);
    for (int i = 0; i < e->splineNControl; i++) {
      DRW_Coord *cp = new DRW_Coord();
      cp->x = e->splineControlPoints[i].x;
      cp->y = e->splineControlPoints[i].y;
      cp->z = e->splineControlPoints[i].z;
      sp.controllist.push_back(cp);
    }
    if (e->splineWeightCount > 0) {
      for (int i = 0; i < e->splineWeightCount; i++)
        sp.weightlist.push_back(e->splineWeights[i]);
    }
    writer->writeSpline(&sp);
  }

  void writeHatch(const DXFRW_EntityData *e) {
    DRW_Hatch h;
    fillEntity(h, e);
    h.basePoint = toDRW(e->basePoint);
    h.solid = e->hatchSolid;
    h.name = std::string(e->hatchPatternName ? e->hatchPatternName : (e->hatchSolid ? "SOLID" : ""));
    h.scale = e->hatchScale;
    h.angle = e->hatchAngle;
    // Build loops: each loop is a hatch loop containing line entities
    h.loopsnum = e->hatchLoopCount;
    for (int i = 0; i < e->hatchLoopCount && i < 1; i++) { // only outer loop for now
      DRW_HatchLoop *loop = new DRW_HatchLoop(e->hatchLoops[i].loopFlags & 0x01 ? 1 : 0);
      int nv = e->hatchLoops[i].vertexCount;
      if (nv >= 2) {
        for (int j = 0; j < nv - 1; j++) {
          DRW_Line *l = new DRW_Line();
          l->basePoint.x = e->hatchLoops[i].vertices[j].x;
          l->basePoint.y = e->hatchLoops[i].vertices[j].y;
          l->basePoint.z = 0;
          l->secPoint.x = e->hatchLoops[i].vertices[j + 1].x;
          l->secPoint.y = e->hatchLoops[i].vertices[j + 1].y;
          l->secPoint.z = 0;
          loop->objlist.push_back(l);
        }
        // Close the loop
        if (nv >= 3) {
          DRW_Line *cl = new DRW_Line();
          cl->basePoint.x = e->hatchLoops[i].vertices[nv - 1].x;
          cl->basePoint.y = e->hatchLoops[i].vertices[nv - 1].y;
          cl->basePoint.z = 0;
          cl->secPoint.x = e->hatchLoops[i].vertices[0].x;
          cl->secPoint.y = e->hatchLoops[i].vertices[0].y;
          cl->secPoint.z = 0;
          loop->objlist.push_back(cl);
        }
      }
      h.looplist.push_back(loop);
    }
    writer->writeHatch(&h);
  }

  void writeSolid(const DXFRW_EntityData *e) {
    DRW_Solid s;
    fillEntity(s, e);
    s.basePoint = toDRW(e->basePoint);
    s.secPoint = toDRW(e->secPoint);
    s.thirdPoint = toDRW(e->thirdPoint);
    s.fourPoint = toDRW(e->fourPoint);
    writer->writeSolid(&s);
  }

  void write3dFace(const DXFRW_EntityData *e) {
    DRW_3Dface f;
    fillEntity(f, e);
    f.basePoint = toDRW(e->basePoint);
    f.secPoint = toDRW(e->secPoint);
    f.thirdPoint = toDRW(e->thirdPoint);
    f.fourPoint = toDRW(e->fourPoint);
    writer->write3dface(&f);
  }
};

// ── Public C API ──────────────────────────────────────────────────────────

int dxfrw_write(const char *filePath,
                const DXFRW_EntityData *entities, int entityCount,
                const DXFRW_LayerData *layers, int layerCount,
                const DXFRW_BlockData *blocks, int blockCount) {
  if (!filePath || !entities || entityCount < 0 || !layers || layerCount < 0 ||
      !blocks || blockCount < 0) {
    WR_TRACE("dxfrw_write: invalid arguments");
    return 0;
  }

  dxfRW dxf(filePath);
  dxf.setDebug(DRW::DEBUG);

  DXFRWWrap wrap;
  wrap.writer = &dxf;
  wrap.entities = entities;
  wrap.entityCount = entityCount;
  wrap.layers = layers;
  wrap.layerCount = layerCount;
  wrap.blocks = blocks;
  wrap.blockCount = blockCount;

  WR_TRACE("dxfrw_write: writing %d entities, %d layers, %d blocks to %s",
           entityCount, layerCount, blockCount, filePath);

  bool ok = false;
  try {
    ok = dxf.write(&wrap, DRW::AC1021, false);
  } catch (const std::exception &ex) {
    WR_TRACE("dxfrw_write: C++ exception: %s", ex.what());
    return 0;
  } catch (...) {
    WR_TRACE("dxfrw_write: unknown C++ exception");
    return 0;
  }

  if (!ok) {
    WR_TRACE("dxfrw_write: write returned false");
    return 0;
  }

  WR_TRACE("dxfrw_write: success");
  return 1;
}
