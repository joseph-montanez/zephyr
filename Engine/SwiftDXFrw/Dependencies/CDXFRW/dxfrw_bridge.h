/**
 * dxfrw_bridge.h
 *
 * C-compatible bridge between libdxfrw (C++ DXF library) and Swift.
 *
 * This header defines POD structs for DXF entities, layers, and blocks,
 * plus a simple extern "C" API that Swift can call via a Clang module.
 *
 * The implementation (dxfrw_bridge.cpp) uses libdxfrw's C++ API internally
 * to parse DXF files and populate these structs.
 */

#ifndef DXFRW_BRIDGE_H
#define DXFRW_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

/* ── Coordinate ─────────────────────────────────────────────────────────── */

typedef struct {
  double x;
  double y;
  double z;
} DXFRW_Coord;

/* ── Vertex (for LWPolyline) ────────────────────────────────────────────── */

typedef struct {
  double x;
  double y;
  double startWidth;
  double endWidth;
  double bulge;
} DXFRW_Vertex;

typedef struct {
  int vertexCount;
  DXFRW_Coord *vertices;
  int editVertexCount;
  DXFRW_Coord *editVertices;
  int loopFlags;
} DXFRW_HatchLoopData;

/* ── Entity type enum ───────────────────────────────────────────────────── */

typedef enum {
  DXFRW_ET_POINT = 0,
  DXFRW_ET_LINE = 1,
  DXFRW_ET_CIRCLE = 2,
  DXFRW_ET_ARC = 3,
  DXFRW_ET_ELLIPSE = 4,
  DXFRW_ET_LWPOLYLINE = 5,
  DXFRW_ET_POLYLINE = 6,
  DXFRW_ET_TEXT = 7,
  DXFRW_ET_MTEXT = 8,
  DXFRW_ET_INSERT = 9,
  DXFRW_ET_SPLINE = 10,
  DXFRW_ET_HATCH = 11,
  DXFRW_ET_SOLID = 12,
  DXFRW_ET_3DFACE = 13,
  DXFRW_ET_DIMENSION = 14,
  DXFRW_ET_LEADER = 15,
  DXFRW_ET_IMAGE = 16,
  DXFRW_ET_VIEWPORT = 17,
  DXFRW_ET_UNKNOWN = 99
} DXFRW_EntityType;

/* ── Dimension sub-type ─────────────────────────────────────────────────── */

typedef enum {
  DXFRW_DIM_ALIGNED = 0,
  DXFRW_DIM_LINEAR = 1,
  DXFRW_DIM_RADIAL = 2,
  DXFRW_DIM_DIAMETRIC = 3,
  DXFRW_DIM_ANGULAR = 4,
  DXFRW_DIM_ANGULAR3P = 5,
  DXFRW_DIM_ORDINATE = 6
} DXFRW_DimType;

/* ── Entity data (tagged union) ─────────────────────────────────────────── */

typedef struct {
  DXFRW_EntityType type;

  /* Common to all entities */
  char *
      layerName; /* layer name (strdup'd, caller frees via dxfrw_result_free) */
  char *lineTypeName; /* entity line type override (strdup'd, caller frees via
                         dxfrw_result_free) */
  int color;          /* AutoCAD Color Index (ACI), 256 = ByLayer */
  int color24;        /* 24-bit RGB, -1 = not set */
  double lineTypeScale;
  double lineWeight; /* mm */
  int flags;         /* entity-specific flags (e.g. polyline closed=1) */

  /* Geometry fields — which ones are valid depends on `type` */

  /* POINT, LINE, CIRCLE, ARC, ELLIPSE, TEXT, MTEXT, INSERT, SOLID, 3DFACE */
  DXFRW_Coord basePoint; /* primary insertion / center point */

  /* LINE, ELLIPSE, TEXT, MTEXT (secondary alignment point) */
  DXFRW_Coord
      secPoint; /* second point (end of line, major axis end, text align pt) */

  /* SOLID, 3DFACE, TRACE */
  DXFRW_Coord thirdPoint; /* third point */
  DXFRW_Coord fourPoint;  /* fourth point */

  /* CIRCLE, ARC */
  double radius; /* circle/arc radius */

  /* ARC, ELLIPSE */
  double startAngle; /* start angle / start parameter (radians) */
  double endAngle;   /* end angle / end parameter (radians) */
  int isCCW;         /* counter-clockwise? (1/0) */

  /* ELLIPSE */
  double axisRatio; /* ratio of minor to major axis */

  /* LWPOLYLINE, POLYLINE */
  int vertexCount;
  DXFRW_Vertex *vertices; /* array of `vertexCount` vertices */

  /* POLYLINE (3D polyline) */
  // Uses `vertices` but each DXFRW_Vertex.x/y/z are all used

  /* TEXT, MTEXT */
  char *textValue;       /* text string */
  double textHeight;     /* text height */
  double textAngle;      /* rotation angle. libdxfrw hands TEXT code 50
                            through raw, which the DXF spec defines in
                            DEGREES. MTEXT is also degrees in practice:
                            when the rotation comes from the code-11
                            direction vector libdxfrw converts it to
                            degrees in DRW_MText::updateAngle(). Swift
                            converts both with * .pi / 180. */
  double textWidthScale; /* width factor */
  char *textStyle;       /* text style name */
  int alignH;            /* horizontal justification */
  int alignV;            /* vertical justification */

  /* MTEXT */
  double mtextInterline; /* interline spacing factor */

  /* INSERT */
  char *blockName;       /* referenced block name (INSERT entities) */
  char *parentBlockName; /* parent block name if entity is inside a block
                            definition */
  double xscale;         /* X scale factor */
  double yscale;         /* Y scale factor */
  double zscale;         /* Z scale factor */
  double insertAngle;    /* rotation angle (radians) */
  int colCount;          /* column count */
  int rowCount;          /* row count */
  double colSpace;       /* column spacing */
  double rowSpace;       /* row spacing */

  /* SPLINE */
  int splineDegree;
  int splineNKnots;
  double *splineKnots; /* array of `splineNKnots` knot values */
  int splineNControl;
  DXFRW_Coord
      *splineControlPoints; /* array of `splineNControl` control points */
  int splineNFit;
  DXFRW_Coord *splineFitPoints; /* array of `splineNFit` fit points */

  /* --- FIX: Added Weights for Splines --- */
  int splineWeightCount;
  double *splineWeights; /* array of `splineWeightCount` weight values */

  double splineTolKnot;
  double splineTolControl;
  double splineTolFit;
  DXFRW_Coord splineTgStart; /* start tangent */
  DXFRW_Coord splineTgEnd;   /* end tangent */

  /* HATCH */
  int hatchSolid;         /* solid fill (1) or pattern (0) */
  char *hatchPatternName; /* pattern name */
  double hatchScale;
  double hatchAngle;
  int hatchLoopCount;
  DXFRW_HatchLoopData *hatchLoops;

  /* GRADIENT (HATCH sub-type, DXF codes 450-470) */
  int isGradient;         /* 0=no, 1=linear, 2=cylindrical, etc. */
  char *gradientName;     /* e.g. "LINEAR", strdup'd, caller frees */
  double gradientAngle;   /* gradient angle (radians) */
  int color1;             /* first gradient color: 24-bit RGB or -1=use entity color */
  int color2;             /* second gradient color: 24-bit RGB or -1 */
  int hatchBackgroundColor; /* hatch background fill color ACI (DXF group 63, non-gradient context), -1 if not set */

  /* DIMENSION */
  DXFRW_DimType dimType;
  char *dimText;            /* dimension text override */
  char *dimStyle;           /* dimension style name */
  DXFRW_Coord dimDefPoint;  /* definition point */
  DXFRW_Coord dimTextPoint; /* text midpoint */
  double dimAngle;          /* rotation angle for linear dims */
  double dimOblique;        /* oblique angle */
  double dimLeaderLength;   /* leader length */

  /* LEADER */
  DXFRW_Coord leaderOffsettext; /* offset of last leader vertex from annotation */

  /* Extrusion direction (for 2D entities that have extrusion) */
  DXFRW_Coord extrusion;

  /* IMAGE entity (DXF IMAGE) */
  char *imageDefHandle;        /* handle reference to IMAGEDEF (strdup'd) */
  char *imageFilePath;         /* resolved file path from IMAGEDEF (strdup'd) */
  DXFRW_Coord imageU;          /* U-axis vector (single pixel width in world units) */
  DXFRW_Coord imageV;          /* V-axis vector (single pixel height in world units) */
  double imageBrightness;      /* 0-100 */
  double imageContrast;        /* 0-100 */
  double imageFade;            /* 0-100 */
  double imageSizeU;           /* pixel width of image (from sizeu) */
  double imageSizeV;           /* pixel height of image (from sizev) */
  int imageClippingEnabled;    /* 1=clipped, 0=not */
  int imageClipVertexCount;    /* number of clip boundary vertices */
  DXFRW_Coord *imageClipVertices; /* clip boundary array */
  int imageDisplayFlags;       /* display flags */

  /* VIEWPORT entity (paper-space window into model space) */
  double viewportWidth;        /* paper-space width, group 40 */
  double viewportHeight;       /* paper-space height, group 41 */
  int viewportStatus;          /* status / stacking number, group 68 */
  int viewportID;              /* viewport ID, group 69 */
  double viewportViewCenterX;  /* model-space view center X, group 12 */
  double viewportViewCenterY;  /* model-space view center Y, group 22 */
  DXFRW_Coord viewportViewTarget; /* model-space target, groups 17/27/37 */
  double viewportViewHeight;   /* model-space view height, group 45 */
  double viewportTwistAngle;   /* view twist in radians, group 51 */

} DXFRW_EntityData;

/* ── Layer data ─────────────────────────────────────────────────────────── */

typedef struct {
  char *name;
  int color;         /* ACI, 256 = ByLayer, 0 = ByBlock */
  int color24;       /* 24-bit RGB, -1 = not set */
  double lineWeight; /* mm, -1 = ByLayer, -2 = ByBlock, -3 = Default */
  int plotFlag;      /* 1 = plot, 0 = no plot */
  char *lineTypeName;
  int transparency;  /* DXF group 440: 0 = opaque, 1-90 = % transparent, > 90 = direct alpha value. -1 = not set / ByLayer */
} DXFRW_LayerData;

/* ── TextStyle data ─────────────────────────────────────────────────────── */

typedef struct {
  char *name;          /* style name */
  char *primaryFont;   /* primary font filename (e.g. romans.shx) */
  char *bigFont;       /* bigfont filename */
  double height;       /* height */
  double widthFactor;  /* width factor */
  double obliqueAngle; /* oblique angle */
  int genFlags;        /* generation flags */
} DXFRW_TextStyleData;

/* ── Block data ─────────────────────────────────────────────────────────── */

typedef struct {
  char *name;
  DXFRW_Coord basePoint;
  int flags; /* block type flags */
  /* block entities are stored inline in the entities array with a blockName
   * field */
} DXFRW_BlockData;

/* Kept separate from DXFRW_EntityData so adding ownership metadata does not
 * alter the ABI/stride of the pointer-heavy entity struct. */
typedef struct {
  unsigned int handle;
  unsigned int ownerHandle;
  int space; /* 0 = model space, 1 = paper space */
} DXFRW_EntityMetadata;

typedef struct {
  unsigned int ownerHandle;
} DXFRW_BlockMetadata;

/* ── Linetype data ──────────────────────────────────────────────────────── */

typedef struct {
  char *name;       /* linetype name (e.g. HIDDEN2, GRIDLINE) */
  double *pattern;  /* DXF group-49 elements in drawing units:
                     * > 0 = dash (pen down), < 0 = gap (pen up), 0 = dot.
                     * NULL/empty for continuous linetypes. */
  int patternCount; /* number of elements in pattern */
  double length;    /* total pattern length (DXF group 40) */
} DXFRW_LinetypeData;

/* ── Result struct ──────────────────────────────────────────────────────── */

typedef struct {
  /* Dynamically allocated arrays */
  DXFRW_LayerData *layers;
  int layerCount;

  DXFRW_BlockData *blocks;
  int blockCount;

  DXFRW_EntityData *entities;
  int entityCount;

  DXFRW_TextStyleData *textStyles;
  int textStyleCount;

  DXFRW_LinetypeData *linetypes;
  int linetypeCount;

  DXFRW_EntityMetadata *entityMetadata;
  DXFRW_BlockMetadata *blockMetadata;

  double globalLinetypeScale;

  /* Error info */
  int success;        /* 1 if parse succeeded, 0 on error */
  char *errorMessage; /* error description, or NULL */
} DXFRW_Result;

/* ── API ────────────────────────────────────────────────────────────────── */

/**
 * Parse a DXF file and return all entities, layers, and blocks.
 *
 * @param filePath  Path to the DXF file (ASCII or binary).
 * @param outResult Pointer to a DXFRW_Result that will be populated.
 * The caller must free this with dxfrw_result_free().
 * @return 1 on success, 0 on failure (error info in outResult->errorMessage).
 */
int dxfrw_read(const char *filePath, DXFRW_Result *outResult);

/**
 * Free all memory allocated by dxfrw_read().
 * After calling this, the DXFRW_Result struct is zeroed.
 */
void dxfrw_result_free(DXFRW_Result *result);

#ifdef __cplusplus
}
#endif

#endif /* DXFRW_BRIDGE_H */
