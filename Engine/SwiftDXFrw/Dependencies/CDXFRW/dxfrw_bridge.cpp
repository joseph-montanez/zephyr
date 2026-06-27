/**
 * dxfrw_bridge.cpp
 *
 * C++ bridge implementation: implements DRW_Interface to collect parsed
 * DXF entities and exposes them via the C-compatible dxfrw_read() API.
 */

#include "dxfrw_bridge.h"

// SPM defines DEBUG=1 in debug builds, but libdxfrw uses DEBUG as an identifier
#ifdef DEBUG
#undef DEBUG
#endif

#include "drw_entities.h"
#include "drw_interface.h"
#include "drw_objects.h"
#include "libdxfrw.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <string>
#include <unordered_map>
#include <vector>

#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#else
#include <unistd.h>
#endif

// ── Debug trace: prints to stderr so it appears in terminal ────────────
#define DXFRW_TRACE(fmt, ...)                                                  \
  do {                                                                         \
    std::fprintf(stderr, "[DXFRW] " fmt "\n", ##__VA_ARGS__);                  \
    std::fflush(stderr);                                                       \
  } while (0)

static int aciToRgb(int aci) {
  static const int table[256] = {
      -1,       0xFF0000, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x0000FF, 0xFF00FF,
      0xFFFFFF, 0x555555, 0xAAAAAA, 0xFF0000, 0xFF8080, 0xA60000, 0xA65353,
      0x800000, 0x804040, 0x4C0000, 0x4C2626, 0x260000, 0x261313, 0xFF4000,
      0xFF9F80, 0xA62900, 0xA66853, 0x802000, 0x805040, 0x4C1300, 0x4C3026,
      0x260A00, 0x261813, 0xFF8000, 0xFFBF80, 0xA65300, 0xA67C53, 0x804000,
      0x806040, 0x4C2600, 0x4C3926, 0x261300, 0x261D13, 0xFFBF00, 0xFFDF80,
      0xA67C00, 0xA69153, 0x806000, 0x807040, 0x4C3900, 0x4C4326, 0x261D00,
      0x262113, 0xFFFF00, 0xFFFF80, 0xA6A600, 0xA6A653, 0x808000, 0x808040,
      0x4C4C00, 0x4C4C26, 0x262600, 0x262613, 0xBFFF00, 0xDFFF80, 0x7CA600,
      0x91A653, 0x608000, 0x708040, 0x394C00, 0x434C26, 0x1D2600, 0x212613,
      0x80FF00, 0xBFFF80, 0x53A600, 0x7CA653, 0x408000, 0x608040, 0x264C00,
      0x394C26, 0x132600, 0x1D2613, 0x40FF00, 0x9FFF80, 0x29A600, 0x68A653,
      0x208000, 0x508040, 0x134C00, 0x304C26, 0x0A2600, 0x182613, 0x00FF00,
      0x80FF80, 0x00A600, 0x53A653, 0x008000, 0x408040, 0x004C00, 0x264C26,
      0x002600, 0x132613, 0x00FF40, 0x80FF9F, 0x00A629, 0x53A668, 0x008020,
      0x408050, 0x004C13, 0x264C30, 0x00260A, 0x132618, 0x00FF80, 0x80FFBF,
      0x00A653, 0x53A67C, 0x008040, 0x408060, 0x004C26, 0x264C39, 0x002613,
      0x13261D, 0x00FFBF, 0x80FFDF, 0x00A67C, 0x53A691, 0x008060, 0x408070,
      0x004C39, 0x264C43, 0x00261D, 0x132621, 0x00FFFF, 0x80FFFF, 0x00A6A6,
      0x53A6A6, 0x008080, 0x408080, 0x004C4C, 0x264C4C, 0x002626, 0x132626,
      0x00BFFF, 0x80DFFF, 0x007CA6, 0x5391A6, 0x006080, 0x407080, 0x00394C,
      0x26434C, 0x001D26, 0x132126, 0x0080FF, 0x80BFFF, 0x0053A6, 0x537CA6,
      0x004080, 0x406080, 0x00264C, 0x26394C, 0x001326, 0x131D26, 0x0040FF,
      0x809FFF, 0x0029A6, 0x5368A6, 0x002080, 0x405080, 0x00134C, 0x26304C,
      0x000A26, 0x131826, 0x0000FF, 0x8080FF, 0x0000A6, 0x5353A6, 0x000080,
      0x404080, 0x00004C, 0x26264C, 0x000026, 0x131326, 0x4000FF, 0x9F80FF,
      0x2900A6, 0x6853A6, 0x200080, 0x504080, 0x13004C, 0x30264C, 0x0A0026,
      0x181326, 0x8000FF, 0xBF80FF, 0x5300A6, 0x7C53A6, 0x400080, 0x604080,
      0x26004C, 0x39264C, 0x130026, 0x1D1326, 0xBF00FF, 0xDF80FF, 0x7C00A6,
      0x9153A6, 0x600080, 0x704080, 0x39004C, 0x43264C, 0x1D0026, 0x211326,
      0xFF00FF, 0xFF80FF, 0xA600A6, 0xA653A6, 0x800080, 0x804080, 0x4C004C,
      0x4C264C, 0x260026, 0x261326, 0xFF00BF, 0xFF80DF, 0xA6007C, 0xA65391,
      0x800060, 0x804070, 0x4C0039, 0x4C2643, 0x26001D, 0x261321, 0xFF0080,
      0xFF80BF, 0xA60053, 0xA6537C, 0x800040, 0x804060, 0x4C0026, 0x4C2639,
      0x260013, 0x26131D, 0xFF0040, 0xFF809F, 0xA60029, 0xA65368, 0x800020,
      0x804050, 0x4C0013, 0x4C2630, 0x26000A, 0x261318, 0x545454, 0x767676,
      0x989898, 0xBBBBBB, 0xDDDDDD, 0xFFFFFF};
  if (aci < 0 || aci > 255)
    return -1;
  return table[aci];
}

static std::string trimDxfLine(const std::string &s) {
  size_t a = 0;
  while (a < s.size() &&
         (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n')) {
    a++;
  }

  size_t b = s.size();
  while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r' ||
                   s[b - 1] == '\n')) {
    b--;
  }

  return s.substr(a, b - a);
}

static std::string upperAscii(std::string value) {
  for (char &c : value) {
    if (c >= 'a' && c <= 'z')
      c = (char)(c - 'a' + 'A');
  }
  return value;
}

struct RawTableInsert {
  std::string blockName;
  std::string parentBlockName;
  std::string layerName = "0";
  std::string lineTypeName = "BYLAYER";
  DXFRW_Coord insertion = {0.0, 0.0, 0.0};
  DXFRW_Coord horizontal = {1.0, 0.0, 0.0};
  DXFRW_Coord extrusion = {0.0, 0.0, 1.0};
  int color = 256;
  int color24 = -1;
};

struct RawViewportData {
  unsigned int handle = 0;
  double paperCenterX = 0.0;
  double paperCenterY = 0.0;
  double paperWidth = 0.0;
  double paperHeight = 0.0;
  int status = 0;
  int viewportID = 0;
  double viewCenterX = 0.0;
  double viewCenterY = 0.0;
  DXFRW_Coord viewTarget = {0.0, 0.0, 0.0};
  double viewHeight = 0.0;
  double twistAngle = 0.0;
};

/* libdxfrw 0.6's ASCII VIEWPORT parser omits groups 17/27/37, 45 and 51.
 * Recover the complete viewport record directly so paper-space projections
 * use deterministic model centers, heights, and twists. */
static std::vector<RawViewportData>
readRawViewports(const char *filePath) {
  std::vector<RawViewportData> viewports;
  std::ifstream input(filePath, std::ios::binary);
  if (!input)
    return viewports;

  char signature[18] = {};
  input.read(signature, sizeof(signature));
  const bool binary =
      input.gcount() == (std::streamsize)sizeof(signature) &&
      std::memcmp(signature, "AutoCAD Binary DXF", sizeof(signature)) == 0;
  if (binary)
    return viewports;
  input.clear();
  input.seekg(0);

  struct Pair {
    int code;
    std::string value;
  };
  std::vector<Pair> pairs;
  std::string codeLine;
  std::string valueLine;
  while (std::getline(input, codeLine) && std::getline(input, valueLine)) {
    const std::string codeText = trimDxfLine(codeLine);
    if (codeText.empty())
      continue;
    char *end = nullptr;
    const long code = std::strtol(codeText.c_str(), &end, 10);
    if (!end || *end != '\0')
      continue;
    if (!valueLine.empty() && valueLine.back() == '\r')
      valueLine.pop_back();
    pairs.push_back({(int)code, trimDxfLine(valueLine)});
  }

  for (size_t i = 0; i < pairs.size(); i++) {
    if (pairs[i].code != 0 || upperAscii(pairs[i].value) != "VIEWPORT")
      continue;
    RawViewportData viewport;
    for (size_t j = i + 1; j < pairs.size() && pairs[j].code != 0; j++) {
      const int code = pairs[j].code;
      const char *value = pairs[j].value.c_str();
      switch (code) {
      case 5: viewport.handle = (unsigned int)std::strtoul(value, nullptr, 16); break;
      case 10: viewport.paperCenterX = std::strtod(value, nullptr); break;
      case 20: viewport.paperCenterY = std::strtod(value, nullptr); break;
      case 40: viewport.paperWidth = std::strtod(value, nullptr); break;
      case 41: viewport.paperHeight = std::strtod(value, nullptr); break;
      case 68: viewport.status = (int)std::strtol(value, nullptr, 10); break;
      case 69: viewport.viewportID = (int)std::strtol(value, nullptr, 10); break;
      case 12: viewport.viewCenterX = std::strtod(value, nullptr); break;
      case 22: viewport.viewCenterY = std::strtod(value, nullptr); break;
      case 17: viewport.viewTarget.x = std::strtod(value, nullptr); break;
      case 27: viewport.viewTarget.y = std::strtod(value, nullptr); break;
      case 37: viewport.viewTarget.z = std::strtod(value, nullptr); break;
      case 45: viewport.viewHeight = std::strtod(value, nullptr); break;
      case 51: viewport.twistAngle = std::strtod(value, nullptr); break;
      default: break;
      }
    }
    if (viewport.handle != 0)
      viewports.push_back(viewport);
  }
  return viewports;
}

/* libdxfrw 0.6 does not expose AcDbTable through DRW_Interface. AutoCAD
 * nevertheless stores the exact generated table graphics in the anonymous
 * block named by group 2 (*T...). Read the small AcDbBlockReference portion
 * directly and synthesize an INSERT after libdxfrw has parsed that block.
 *
 * This intentionally handles ASCII DXF. Binary DXF continues through the
 * normal libdxfrw path, but cannot recover TABLE entities until the upstream
 * library exposes them. */
static std::vector<RawTableInsert>
readRawTableInserts(const char *filePath) {
  std::vector<RawTableInsert> tables;

  std::ifstream input(filePath, std::ios::binary);
  if (!input)
    return tables;

  char signature[18] = {};
  input.read(signature, sizeof(signature));
  const bool binary =
      input.gcount() == (std::streamsize)sizeof(signature) &&
      std::memcmp(signature, "AutoCAD Binary DXF", sizeof(signature)) == 0;
  if (binary)
    return tables;
  input.clear();
  input.seekg(0);

  struct Pair {
    int code;
    std::string value;
  };
  std::vector<Pair> pairs;
  std::string codeLine;
  std::string valueLine;
  while (std::getline(input, codeLine) && std::getline(input, valueLine)) {
    const std::string codeText = trimDxfLine(codeLine);
    if (codeText.empty())
      continue;
    char *end = nullptr;
    const long code = std::strtol(codeText.c_str(), &end, 10);
    if (!end || *end != '\0')
      continue;
    if (!valueLine.empty() && valueLine.back() == '\r')
      valueLine.pop_back();
    pairs.push_back({(int)code, valueLine});
  }

  std::string section;
  std::string currentBlockName;
  bool awaitingBlockName = false;
  for (size_t i = 0; i < pairs.size();) {
    const int code = pairs[i].code;
    const std::string value = upperAscii(trimDxfLine(pairs[i].value));

    if (code == 0 && value == "SECTION" && i + 1 < pairs.size() &&
        pairs[i + 1].code == 2) {
      section = upperAscii(trimDxfLine(pairs[i + 1].value));
      i += 2;
      continue;
    }
    if (code == 0 && value == "ENDSEC") {
      section.clear();
      currentBlockName.clear();
      awaitingBlockName = false;
      i++;
      continue;
    }
    if (section == "BLOCKS" && code == 0 && value == "BLOCK") {
      currentBlockName.clear();
      awaitingBlockName = true;
      i++;
      continue;
    }
    if (section == "BLOCKS" && awaitingBlockName && code == 2) {
      currentBlockName = trimDxfLine(pairs[i].value);
      awaitingBlockName = false;
      i++;
      continue;
    }
    if (section == "BLOCKS" && code == 0 && value == "ENDBLK") {
      currentBlockName.clear();
      awaitingBlockName = false;
      i++;
      continue;
    }

    const bool tableEntity = value == "TABLE" || value == "ACAD_TABLE";
    if ((section != "ENTITIES" && section != "BLOCKS") || code != 0 ||
        !tableEntity) {
      i++;
      continue;
    }

    RawTableInsert table;
    if (section == "BLOCKS")
      table.parentBlockName = currentBlockName;
    bool inTableSubclass = false;
    bool hasHorizontal = false;
    size_t j = i + 1;
    for (; j < pairs.size() && pairs[j].code != 0; j++) {
      const int c = pairs[j].code;
      const std::string raw = trimDxfLine(pairs[j].value);
      if (c == 100) {
        inTableSubclass = upperAscii(raw) == "ACDBTABLE";
        continue;
      }
      if (c == 210) {
        table.extrusion.x = std::strtod(raw.c_str(), nullptr);
        continue;
      }
      if (c == 220) {
        table.extrusion.y = std::strtod(raw.c_str(), nullptr);
        continue;
      }
      if (c == 230) {
        table.extrusion.z = std::strtod(raw.c_str(), nullptr);
        continue;
      }

      if (!inTableSubclass) {
        switch (c) {
        case 2:
          if (table.blockName.empty())
            table.blockName = raw;
          break;
        case 8:
          table.layerName = raw.empty() ? "0" : raw;
          break;
        case 6:
          table.lineTypeName = raw.empty() ? "BYLAYER" : raw;
          break;
        case 10:
          table.insertion.x = std::strtod(raw.c_str(), nullptr);
          break;
        case 20:
          table.insertion.y = std::strtod(raw.c_str(), nullptr);
          break;
        case 30:
          table.insertion.z = std::strtod(raw.c_str(), nullptr);
          break;
        case 62:
          table.color = std::atoi(raw.c_str());
          break;
        case 420:
          table.color24 = std::atoi(raw.c_str());
          break;
        default:
          break;
        }
      } else {
        switch (c) {
        case 11:
          table.horizontal.x = std::strtod(raw.c_str(), nullptr);
          hasHorizontal = true;
          break;
        case 21:
          table.horizontal.y = std::strtod(raw.c_str(), nullptr);
          break;
        case 31:
          table.horizontal.z = std::strtod(raw.c_str(), nullptr);
          break;
        default:
          break;
        }
      }
    }

    if (!table.blockName.empty()) {
      if (!hasHorizontal) {
        table.horizontal = {1.0, 0.0, 0.0};
      }
      tables.push_back(table);
    }
    i = j;
  }

  return tables;
}

static char *makeDxfrwTempPath() {
  char *tmpPath = (char *)std::malloc(260);
  if (!tmpPath)
    return nullptr;

#ifdef _WIN32
  char tmpName[MAX_PATH];
  if (GetTempFileNameA(".", "dxf", 0, tmpName) == 0) {
    std::free(tmpPath);
    return nullptr;
  }
  std::strncpy(tmpPath, tmpName, 260);
  tmpPath[259] = 0;
#else
  std::strncpy(tmpPath, "/tmp/dxfrw_stripped_XXXXXX", 260);
  tmpPath[259] = 0;
  int fd = mkstemp(tmpPath);
  if (fd < 0) {
    std::free(tmpPath);
    return nullptr;
  }
  close(fd);
#endif

  return tmpPath;
}

static void cleanupTempPath(char *path) {
  if (path) {
    std::remove(path);
    std::free(path);
  }
}

/* ── Helper: remove $DWGCODEPAGE from HEADER to avoid iconv crashes ── */
static char *stripDwgCodepage(const char *srcPath) {
  FILE *inFile = std::fopen(srcPath, "rb");
  if (!inFile)
    return nullptr;

  std::fseek(inFile, 0, SEEK_END);
  long fileSize = std::ftell(inFile);
  std::fseek(inFile, 0, SEEK_SET);
  if (fileSize <= 0) {
    std::fclose(inFile);
    return nullptr;
  }

  char *buf = (char *)std::malloc(fileSize + 1);
  if (!buf) {
    std::fclose(inFile);
    return nullptr;
  }
  size_t n = std::fread(buf, 1, fileSize, inFile);
  std::fclose(inFile);
  buf[n] = 0;

  // Find $DWGCODEPAGE
  const char *found = std::strstr(buf, "$DWGCODEPAGE");
  if (!found) {
    std::free(buf);
    return nullptr;
  }

  // Walk back past the newline/carriage return before $DWGCODEPAGE
  const char *cutStart = found;
  if (cutStart > buf)
    cutStart--; // Point to character before $ (usually \n or \r)
  while (cutStart > buf && (*cutStart == '\n' || *cutStart == '\r')) {
    cutStart--;
  }
  // Now cutStart points to the last character of the previous line (usually the
  // '9' of "  9") Walk back to the start of this line
  while (cutStart > buf && *cutStart != '\n' && *cutStart != '\r') {
    cutStart--;
  }
  // Now cutStart points to the \n or \r before the "  9" line, or start of
  // buffer
  if (cutStart > buf && (*cutStart == '\n' || *cutStart == '\r')) {
    cutStart++; // Point to the first character of the "  9" line
  }

  // Walk forward past "$DWGCODEPAGE" line, "  3" line, and the value line
  const char *cutEnd = found;
  for (int lines = 0; lines < 3 && cutEnd < buf + n; lines++) {
    while (cutEnd < buf + n && *cutEnd != '\n')
      cutEnd++;
    if (cutEnd < buf + n)
      cutEnd++;
  }

  DXFRW_TRACE(
      "stripDwgCodepage: cutting %lld bytes (DWGCODEPAGE + group 9,3 + value)",
      (long long)(cutEnd - cutStart));

  char *tmpPath = makeDxfrwTempPath();
  if (!tmpPath) {
    std::free(buf);
    return nullptr;
  }

  FILE *outFile = std::fopen(tmpPath, "wb");
  if (!outFile) {
    std::free(buf);
    std::free(tmpPath);
    return nullptr;
  }

  std::fwrite(buf, 1, cutStart - buf, outFile);
  std::fwrite(cutEnd, 1, (buf + n) - cutEnd, outFile);

  std::fclose(outFile);
  std::free(buf);
  return tmpPath;
}

/* Strip MTEXT "101 Embedded Object" payloads that libdxfrw can misread as
 * normal MTEXT group codes. Some AutoCAD title blocks contain embedded object
 * data after the real MTEXT values; libdxfrw then lets those later 10/20/40
 * codes overwrite the real insertion point/height. Removing that opaque
 * payload before parsing keeps the normal MTEXT fields intact. */
static char *stripMTextEmbeddedObjects(const char *srcPath) {
  FILE *inFile = std::fopen(srcPath, "rb");
  if (!inFile)
    return nullptr;

  std::fseek(inFile, 0, SEEK_END);
  long fileSize = std::ftell(inFile);
  std::fseek(inFile, 0, SEEK_SET);

  if (fileSize <= 0) {
    std::fclose(inFile);
    return nullptr;
  }

  std::string data;
  data.resize((size_t)fileSize);
  size_t n = std::fread(&data[0], 1, (size_t)fileSize, inFile);
  std::fclose(inFile);
  data.resize(n);

  if (data.size() >= 18 &&
      std::memcmp(data.data(), "AutoCAD Binary DXF", 18) == 0) {
    return nullptr;
  }

  std::vector<std::string> lines;
  lines.reserve(8192);

  size_t pos = 0;
  while (pos < data.size()) {
    size_t end = data.find('\n', pos);
    if (end == std::string::npos) {
      std::string line = data.substr(pos);
      if (!line.empty() && line.back() == '\r')
        line.pop_back();
      lines.push_back(line);
      break;
    }

    std::string line = data.substr(pos, end - pos);
    if (!line.empty() && line.back() == '\r')
      line.pop_back();
    lines.push_back(line);
    pos = end + 1;
  }

  std::vector<std::string> out;
  out.reserve(lines.size());

  bool changed = false;
  bool inMText = false;

  size_t i = 0;
  while (i + 1 < lines.size()) {
    const std::string code = trimDxfLine(lines[i]);
    const std::string value = trimDxfLine(lines[i + 1]);

    if (code == "0") {
      inMText = (value == "MTEXT");
      out.push_back(lines[i]);
      out.push_back(lines[i + 1]);
      i += 2;
      continue;
    }

    if (inMText && code == "101" && value == "Embedded Object") {
      changed = true;
      i += 2;

      while (i + 1 < lines.size()) {
        if (trimDxfLine(lines[i]) == "0") {
          inMText = false;
          break;
        }
        i += 2;
      }

      continue;
    }

    out.push_back(lines[i]);
    out.push_back(lines[i + 1]);
    i += 2;
  }

  while (i < lines.size()) {
    out.push_back(lines[i]);
    i++;
  }

  if (!changed)
    return nullptr;

  char *tmpPath = makeDxfrwTempPath();
  if (!tmpPath)
    return nullptr;

  FILE *outFile = std::fopen(tmpPath, "wb");
  if (!outFile) {
    std::free(tmpPath);
    return nullptr;
  }

  for (const std::string &line : out) {
    std::fwrite(line.data(), 1, line.size(), outFile);
    std::fwrite("\n", 1, 1, outFile);
  }

  std::fclose(outFile);

  DXFRW_TRACE("stripMTextEmbeddedObjects: stripped MTEXT Embedded Object "
              "payloads into temp file '%s'",
              tmpPath);
  return tmpPath;
}

/* ── Helper: copy std::string to malloc'd C string ─────────────────────── */

static char *strToC(const std::string &s) {
  if (s.empty())
    return nullptr;
  char *c = (char *)malloc(s.size() + 1);
  if (c) {
    std::memcpy(c, s.c_str(), s.size() + 1);
  }
  return c;
}

static void freeCoordArray(DXFRW_Coord *&arr, int &count) {
  free(arr);
  arr = nullptr;
  count = 0;
}

static void freeVertexArray(DXFRW_Vertex *&arr, int &count) {
  free(arr);
  arr = nullptr;
  count = 0;
}

static void freeDoubleArray(double *&arr, int &count) {
  free(arr);
  arr = nullptr;
  count = 0;
}

/* ── Helper: convert DRW_Coord to DXFRW_Coord ──────────────────────────── */

static inline DXFRW_Coord toC(const DRW_Coord &c) {
  DXFRW_Coord r;
  r.x = c.x;
  r.y = c.y;
  r.z = c.z;
  return r;
}

/* ── OCS (arbitrary axis algorithm) helpers ────────────────────────────────
 *
 * Mirror of DRW_Entity::calculateAxis / extrudePoint so the bridge can apply
 * (or invert) the OCS->WCS conversion for the cases libdxfrw gets wrong or
 * does not cover when reading with applyExt=true:
 *   - LWPOLYLINE / 2D POLYLINE bulges: libdxfrw extrudes vertex positions but
 *     never negates the bulge sign, even though a mirroring extrusion
 *     (normal z < 0) reverses in-plane orientation. Fillets render concave
 *     instead of convex without the flip.
 *   - 2D POLYLINE vertices: DRW_Polyline has no applyExtrusion() override at
 *     all, so old-style polylines arrive in raw OCS.
 *   - ELLIPSE: DRW_Ellipse::applyExtrusion() extrudes the major axis vector,
 *     but per the DXF spec the ELLIPSE center (10) and major axis endpoint
 *     (11) are stored in WCS — only the start/end parameters need the z<0
 *     swap. The bridge inverts the unwanted axis transform (the basis is
 *     orthonormal, so the inverse is the transpose) while keeping libdxfrw's
 *     parameter swap.
 */
static void ocsBasis(const DRW_Coord &ext, DRW_Coord &ax, DRW_Coord &ay,
                     DRW_Coord &az) {
  az = ext;
  double m = std::sqrt(az.x * az.x + az.y * az.y + az.z * az.z);
  if (m < 1e-12) {
    az.x = 0.0;
    az.y = 0.0;
    az.z = 1.0;
    m = 1.0;
  }
  az.x /= m;
  az.y /= m;
  az.z /= m;

  if (std::fabs(az.x) < 0.015625 && std::fabs(az.y) < 0.015625) {
    /* Ax = Wy x N, Wy = (0,1,0) */
    ax.x = az.z;
    ax.y = 0.0;
    ax.z = -az.x;
  } else {
    /* Ax = Wz x N, Wz = (0,0,1) */
    ax.x = -az.y;
    ax.y = az.x;
    ax.z = 0.0;
  }
  m = std::sqrt(ax.x * ax.x + ax.y * ax.y + ax.z * ax.z);
  ax.x /= m;
  ax.y /= m;
  ax.z /= m;

  /* Ay = N x Ax */
  ay.x = az.y * ax.z - az.z * ax.y;
  ay.y = az.z * ax.x - az.x * ax.z;
  ay.z = az.x * ax.y - az.y * ax.x;
}

/* OCS -> WCS: w = [Ax | Ay | N] * p  (same as DRW_Entity::extrudePoint) */
static inline void ocsToWcs(const DRW_Coord &ax, const DRW_Coord &ay,
                            const DRW_Coord &az, double &x, double &y,
                            double &z) {
  const double px = x, py = y, pz = z;
  x = ax.x * px + ay.x * py + az.x * pz;
  y = ax.y * px + ay.y * py + az.y * pz;
  z = ax.z * px + ay.z * py + az.z * pz;
}

/* WCS -> OCS: p = transpose([Ax | Ay | N]) * w  (exact inverse, orthonormal) */
static inline void wcsToOcs(const DRW_Coord &ax, const DRW_Coord &ay,
                            const DRW_Coord &az, double &x, double &y,
                            double &z) {
  const double wx = x, wy = y, wz = z;
  x = ax.x * wx + ax.y * wy + ax.z * wz;
  y = ay.x * wx + ay.y * wy + ay.z * wz;
  z = az.x * wx + az.y * wy + az.z * wz;
}

static inline bool isDefaultExtrusion(const DRW_Coord &n) {
  return std::fabs(n.x) < 1e-12 && std::fabs(n.y) < 1e-12 &&
         std::fabs(n.z - 1.0) < 1e-12;
}

/* ── DXFCollector: implements DRW_Interface ────────────────────────────── */

class DXFCollector : public DRW_Interface {
public:
  std::vector<DXFRW_LayerData> layers;
  std::vector<DXFRW_BlockData> blocks;
  std::vector<DXFRW_EntityData> entities;
  std::vector<DXFRW_EntityMetadata> entityMetadata;
  std::vector<unsigned int> blockOwnerHandles;
  std::vector<DXFRW_TextStyleData> textStyles;
  std::vector<DXFRW_LinetypeData> linetypes;
  
  double globalLinetypeScale = 1.0;

  /* Track current block for entity→block association */
  std::string currentBlockName;
  bool inBlock = false;

  /* Progress counter */
  int entityCount = 0;
  int lineCount = 0, lwpolyCount = 0, insertCount = 0, textCount = 0;
  int circleCount = 0, arcCount = 0, pointCount = 0, splineCount = 0;
  int solidCount = 0, hatchCount = 0, dimCount = 0, ellipseCount = 0;
  int polylineCount = 0, mtextCount = 0, faceCount = 0, unknownCount = 0;

  /* Map IMAGEDEF handle → file path for resolve-after-parse linking */
  std::unordered_map<std::string, std::string> imageDefPathMap;

  void bump(DXFRW_EntityType t) {
    entityCount++;
    switch (t) {
    case DXFRW_ET_LINE:
      lineCount++;
      break;
    case DXFRW_ET_LWPOLYLINE:
      lwpolyCount++;
      break;
    case DXFRW_ET_POLYLINE:
      polylineCount++;
      break;
    case DXFRW_ET_INSERT:
      insertCount++;
      break;
    case DXFRW_ET_TEXT:
      textCount++;
      break;
    case DXFRW_ET_MTEXT:
      mtextCount++;
      break;
    case DXFRW_ET_CIRCLE:
      circleCount++;
      break;
    case DXFRW_ET_ARC:
      arcCount++;
      break;
    case DXFRW_ET_POINT:
      pointCount++;
      break;
    case DXFRW_ET_SPLINE:
      splineCount++;
      break;
    case DXFRW_ET_SOLID:
      solidCount++;
      break;
    case DXFRW_ET_3DFACE:
      faceCount++;
      break;
    case DXFRW_ET_HATCH:
      hatchCount++;
      break;
    case DXFRW_ET_DIMENSION:
      dimCount++;
      break;
    case DXFRW_ET_ELLIPSE:
      ellipseCount++;
      break;
    case DXFRW_ET_VIEWPORT:
      break;
    default:
      unknownCount++;
      break;
    }
    if (entityCount % 1000 == 0) {
      DXFRW_TRACE(" progress: %d entities (L=%d LW=%d PL=%d I=%d T=%d MT=%d "
                  "C=%d A=%d S=%d)",
                  entityCount, lineCount, lwpolyCount, polylineCount,
                  insertCount, textCount, mtextCount, circleCount, arcCount,
                  splineCount);
    }
  }

  /* ── Helper: init common entity fields ─────────────────────────────── */

  void initEntity(DXFRW_EntityData &e, DXFRW_EntityType t,
                  const DRW_Entity &src) {
    std::memset(&e, 0, sizeof(e));
    e.type = t;
    e.layerName = strToC(src.layer);
    e.lineTypeName = strToC(src.lineType);
    e.color = src.color;
    e.color24 = src.color24;
    e.lineTypeScale = src.ltypeScale;
    e.lineWeight = DRW_LW_Conv::lineWidth2dxfInt(src.lWeight);
    DXFRW_EntityMetadata metadata = {};
    metadata.handle = src.handle;
    metadata.ownerHandle = src.parentHandle;
    metadata.space = static_cast<int>(src.space);
    entityMetadata.push_back(metadata);

    /* If inside a block, store the PARENT block name */
    if (inBlock && !currentBlockName.empty()) {
      e.parentBlockName = strToC(currentBlockName);
    }
  }

  /* ── DRW_Interface pure virtual implementations ────────────────────── */

  void addHeader(const DRW_Header *data) override {
    DXFRW_TRACE("  addHeader");
    if (!data) return;
    
    auto it = data->vars.find("$LTSCALE");
    if (it != data->vars.end() && it->second && it->second->type() == DRW_Variant::DOUBLE) {
        globalLinetypeScale = it->second->content.d;
    }
  }

  void addLType(const DRW_LType &data) override {
    DXFRW_TRACE("  addLType: %s (%zu elements)", data.name.c_str(),
                data.path.size());
    DXFRW_LinetypeData lt;
    std::memset(&lt, 0, sizeof(lt));
    lt.name = strToC(data.name);
    lt.length = data.length;
    lt.patternCount = (int)data.path.size();
    if (lt.patternCount > 0) {
      lt.pattern = (double *)malloc(sizeof(double) * lt.patternCount);
      for (int i = 0; i < lt.patternCount; i++) {
        /* DXF group 49 convention: >0 dash, <0 gap, 0 dot */
        lt.pattern[i] = data.path[i];
      }
    }
    linetypes.push_back(lt);
  }

  void addLayer(const DRW_Layer &data) override {
    DXFRW_TRACE("  addLayer: %s", data.name.c_str());
    DXFRW_LayerData l;
    std::memset(&l, 0, sizeof(l));
    l.name = strToC(data.name);
    l.color = data.color;
    l.color24 = data.color24;
    l.lineWeight = DRW_LW_Conv::lineWidth2dxfInt(data.lWeight);
    l.plotFlag = data.plotF ? 1 : 0;
    l.lineTypeName = strToC(data.lineType);
    l.transparency = data.transparency;

    // Check extended data for AcCmTransparency (common in newer DXF files).
    // Format: 1001="AcCmTransparency" followed by 1071=<OTC integer>
    // OTC: bits 24-31 = method (2=ByValue), bits 0-23 = alpha (0=transparent, 255=opaque)
    for (size_t i = 0; i + 1 < data.extData.size(); i++) {
      DRW_Variant *v = const_cast<DRW_Variant*>(data.extData[i]);
      DRW_Variant *next = const_cast<DRW_Variant*>(data.extData[i + 1]);
      if (v->code() == 1001 && v->type() == DRW_Variant::STRING) {
        std::string appName(*(v->content.s));
        // Case-insensitive compare with "ACCMTRANSPARENCY"
        bool match = (appName.size() == 16);
        if (match) {
          for (size_t ci = 0; ci < 16; ci++) {
            char a = appName[ci];
            char b = "ACCMTRANSPARENCY"[ci];
            if (a >= 'a' && a <= 'z') a -= 32;
            if (a != b) { match = false; break; }
          }
        }
        if (match) {
          if (next->code() == 1071 && next->type() == DRW_Variant::INTEGER) {
            int otc = next->content.i;
            int method = (otc >> 24) & 0xFF;
            int alpha = otc & 0x00FFFFFF;
            if (method == 2 && alpha >= 0 && alpha <= 255) {
              // Convert OTC alpha to DXF 440 format (0=opaque, 1-90=%transparent)
              double opacity = (double)alpha / 255.0;
              int dxf440 = (int)(((1.0 - opacity) * 100.0) + 0.5);
              if (dxf440 < 1) dxf440 = 1;
              if (dxf440 > 90) dxf440 = 90;
              l.transparency = dxf440;
              DXFRW_TRACE("    AcCmTransparency: OTC=%d (method=%d, alpha=%d) -> DXF440=%d",
                          otc, method, alpha, dxf440);
            }
          }
          break; // Only look at the first AcCmTransparency entry
        }
      }
    }

    layers.push_back(l);
  }

  void addDimStyle(const DRW_Dimstyle &data) override {
    DXFRW_TRACE("  addDimStyle");
    (void)data;
  }
  void addVport(const DRW_Vport &data) override { (void)data; }
  void addTextStyle(const DRW_Textstyle &data) override {
    DXFRW_TRACE("  addTextStyle: %s, font: %s", data.name.c_str(),
                data.font.c_str());
    DXFRW_TextStyleData ts;
    std::memset(&ts, 0, sizeof(ts));
    ts.name = strToC(data.name);
    ts.primaryFont = strToC(data.font);
    ts.bigFont = strToC(data.bigFont);
    ts.height = data.height;
    ts.widthFactor = data.width;
    ts.obliqueAngle = data.oblique;
    ts.genFlags = data.genFlag;
    textStyles.push_back(ts);
  }
  void addAppId(const DRW_AppId &data) override { (void)data; }

  void addBlock(const DRW_Block &data) override {
    DXFRW_TRACE("  addBlock: %s", data.name.c_str());
    DXFRW_BlockData b;
    std::memset(&b, 0, sizeof(b));
    b.name = strToC(data.name);
    b.basePoint = toC(data.basePoint);
    b.flags = data.flags;
    blocks.push_back(b);
    blockOwnerHandles.push_back(data.parentHandle);

    /* Enter block scope — subsequent entities belong to this block */
    currentBlockName = data.name;
    inBlock = true;
  }

  void setBlock(const int handle) override { (void)handle; }

  void endBlock() override {
    DXFRW_TRACE("  endBlock");
    inBlock = false;
    currentBlockName.clear();
  }

  void addPoint(const DRW_Point &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_POINT, data);
    e.basePoint = toC(data.basePoint);
    e.extrusion = toC(data.extPoint);
    bump(e.type);
    entities.push_back(e);
  }

  void addLine(const DRW_Line &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_LINE, data);
    e.basePoint = toC(data.basePoint);
    e.secPoint = toC(data.secPoint);
    e.extrusion = toC(data.extPoint);
    bump(e.type);
    entities.push_back(e);
  }

  void addRay(const DRW_Ray &data) override {
    /* Treat rays as lines for import purposes */
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_LINE, data);
    e.basePoint = toC(data.basePoint);
    e.secPoint = toC(data.secPoint);
    bump(e.type);
    entities.push_back(e);
  }

  void addXline(const DRW_Xline &data) override {
    /* Treat xlines as lines */
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_LINE, data);
    e.basePoint = toC(data.basePoint);
    e.secPoint = toC(data.secPoint);
    bump(e.type);
    entities.push_back(e);
  }

  void addArc(const DRW_Arc &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_ARC, data);
    e.basePoint = toC(data.basePoint);
    e.radius = data.radious;
    e.startAngle = data.staangle;
    e.endAngle = data.endangle;
    e.isCCW = data.isccw;
    e.extrusion = toC(data.extPoint);
    bump(e.type);
    entities.push_back(e);
  }

  void addCircle(const DRW_Circle &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_CIRCLE, data);
    e.basePoint = toC(data.basePoint);
    e.radius = data.radious;
    e.extrusion = toC(data.extPoint);
    bump(e.type);
    entities.push_back(e);
  }

  void addEllipse(const DRW_Ellipse &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_ELLIPSE, data);
    e.basePoint = toC(data.basePoint);
    /* Per the DXF spec, the ELLIPSE major axis endpoint (group 11) is stored
     * in WCS — but DRW_Ellipse::applyExtrusion() (applyExt=true) ran
     * extrudePoint() on it, rotating/mirroring a vector that was already in
     * world space. Invert that transform here (the OCS basis is orthonormal,
     * so the inverse is the transpose). libdxfrw's start/end parameter swap
     * for z<0 extrusions IS spec-correct (parameters sweep CCW about the
     * entity normal) and is kept as delivered. Identity for default
     * extrusion, so unconverted entities pass through untouched. */
    {
      DRW_Coord eAx, eAy, eAz;
      ocsBasis(data.extPoint, eAx, eAy, eAz);
      double mx = data.secPoint.x;
      double my = data.secPoint.y;
      double mz = data.secPoint.z;
      wcsToOcs(eAx, eAy, eAz, mx, my, mz);
      e.secPoint.x = mx;
      e.secPoint.y = my;
      e.secPoint.z = mz; /* major axis endpoint, WCS as stored in the file */
    }
    e.axisRatio = data.ratio;
    e.startAngle = data.staparam;
    e.endAngle = data.endparam;
    e.isCCW = data.isccw;
    e.extrusion = toC(data.extPoint);
    bump(e.type);
    entities.push_back(e);
  }

  void addLWPolyline(const DRW_LWPolyline &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_LWPOLYLINE, data);
    e.flags = data.flags;
    e.vertexCount = (int)data.vertlist.size();
    e.extrusion = toC(data.extPoint);

    /* libdxfrw (applyExt=true) already converted the vertex positions from
     * OCS to WCS, but DRW_LWPolyline::applyExtrusion() never touches the
     * bulge values. A mirroring extrusion (normal z < 0) reverses in-plane
     * orientation, so every bulge sign must flip or fillet arcs bow into the
     * shape instead of out of it. */
    const bool mirrored = data.extPoint.z < 0.0;

    if (e.vertexCount > 0) {
      e.vertices = (DXFRW_Vertex *)malloc(sizeof(DXFRW_Vertex) * e.vertexCount);
      for (int i = 0; i < e.vertexCount; i++) {
        DRW_Vertex2D *v = data.vertlist[i];
        e.vertices[i].x = v->x;
        e.vertices[i].y = v->y;
        e.vertices[i].startWidth =
            v->stawidth != 0.0 ? v->stawidth : data.width;
        e.vertices[i].endWidth = v->endwidth != 0.0 ? v->endwidth : data.width;
        e.vertices[i].bulge = mirrored ? -v->bulge : v->bulge;
      }
    }
    bump(e.type);
    entities.push_back(e);
  }

  void addPolyline(const DRW_Polyline &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_POLYLINE, data);
    e.flags = data.flags;
    e.vertexCount = (int)data.vertlist.size();
    e.extrusion = toC(data.extPoint);

    /* DRW_Polyline has no applyExtrusion() override, so libdxfrw hands the
     * bridge raw OCS coordinates for old-style 2D POLYLINEs. Convert here.
     * 3D polylines (flag 8), 3D meshes (flag 16), and polyface meshes
     * (flag 64) store WCS vertices per the DXF spec and are left untouched.
     */
    const bool is2D = (data.flags & (8 | 16 | 64)) == 0;
    const bool needsOcs = is2D && !isDefaultExtrusion(data.extPoint);
    const bool mirrored = needsOcs && data.extPoint.z < 0.0;
    DRW_Coord bAx, bAy, bAz;
    if (needsOcs) {
      ocsBasis(data.extPoint, bAx, bAy, bAz);
    }

    if (e.vertexCount > 0) {
      e.vertices = (DXFRW_Vertex *)malloc(sizeof(DXFRW_Vertex) * e.vertexCount);
      for (int i = 0; i < e.vertexCount; i++) {
        DRW_Vertex *v = data.vertlist[i];
        double vx = v->basePoint.x;
        double vy = v->basePoint.y;
        double vz = v->basePoint.z;
        if (needsOcs) {
          ocsToWcs(bAx, bAy, bAz, vx, vy, vz);
        }
        e.vertices[i].x = vx;
        e.vertices[i].y = vy;
        e.vertices[i].startWidth =
            v->stawidth != 0.0 ? v->stawidth : data.defstawidth;
        e.vertices[i].endWidth =
            v->endwidth != 0.0 ? v->endwidth : data.defendwidth;
        e.vertices[i].bulge = mirrored ? -v->bulge : v->bulge;
      }
    }
    bump(e.type);
    entities.push_back(e);
  }

  void addSpline(const DRW_Spline *data) override {
    if (!data)
      return;
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_SPLINE, *data);

    e.splineDegree = data->degree;
    e.splineTolKnot = data->tolknot;
    e.splineTolControl = data->tolcontrol;
    e.splineTolFit = data->tolfit;
    e.splineTgStart = toC(data->tgStart);
    e.splineTgEnd = toC(data->tgEnd);
    e.flags = data->flags;

    /* Knots */
    e.splineNKnots = (int)data->knotslist.size();
    if (e.splineNKnots > 0) {
      e.splineKnots = (double *)malloc(sizeof(double) * e.splineNKnots);
      for (int i = 0; i < e.splineNKnots; i++) {
        e.splineKnots[i] = data->knotslist[i];
      }
    }

    /* Control points */
    e.splineNControl = (int)data->controllist.size();
    if (e.splineNControl > 0) {
      e.splineControlPoints =
          (DXFRW_Coord *)malloc(sizeof(DXFRW_Coord) * e.splineNControl);
      for (int i = 0; i < e.splineNControl; i++) {
        e.splineControlPoints[i] = toC(*data->controllist[i]);
      }
    }

    /* Fit points */
    e.splineNFit = (int)data->fitlist.size();
    if (e.splineNFit > 0) {
      e.splineFitPoints =
          (DXFRW_Coord *)malloc(sizeof(DXFRW_Coord) * e.splineNFit);
      for (int i = 0; i < e.splineNFit; i++) {
        e.splineFitPoints[i] = toC(*data->fitlist[i]);
      }
    }

    /* --- Extract Weights for Spline --- */
    e.splineWeightCount = (int)data->weightlist.size();
    if (e.splineWeightCount > 0) {
      e.splineWeights = (double *)malloc(sizeof(double) * e.splineWeightCount);
      for (int i = 0; i < e.splineWeightCount; i++) {
        e.splineWeights[i] = data->weightlist[i];
      }
    } else {
      e.splineWeightCount = 0;
      e.splineWeights = nullptr;
    }

    bump(e.type);
    entities.push_back(e);
  }

  void addKnot(const DRW_Entity &data) override { (void)data; }

  void addInsert(const DRW_Insert &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_INSERT, data);
    e.basePoint = toC(data.basePoint);
    /* blockName is the referenced block for INSERT.
     * parentBlockName was already set by initEntity if we're inside a block. */
    e.blockName = strToC(data.name);
    e.xscale = data.xscale;
    e.yscale = data.yscale;
    e.zscale = data.zscale;
    e.insertAngle = data.angle;
    e.colCount = data.colcount;
    e.rowCount = data.rowcount;
    e.colSpace = data.colspace;
    e.rowSpace = data.rowspace;
    e.extrusion = toC(data.extPoint);
    bump(e.type);
    entities.push_back(e);
  }

  void addTableInsert(const RawTableInsert &table) {
    for (const DXFRW_EntityData &existing : entities) {
      if (existing.type != DXFRW_ET_INSERT || !existing.blockName)
        continue;
      if (table.blockName != existing.blockName)
        continue;
      const std::string existingParent =
          existing.parentBlockName ? existing.parentBlockName : "";
      if (table.parentBlockName != existingParent)
        continue;
      if (std::fabs(existing.basePoint.x - table.insertion.x) < 1e-9 &&
          std::fabs(existing.basePoint.y - table.insertion.y) < 1e-9 &&
          std::fabs(existing.basePoint.z - table.insertion.z) < 1e-9) {
        return;
      }
    }

    DXFRW_EntityData e;
    std::memset(&e, 0, sizeof(e));
    e.type = DXFRW_ET_INSERT;
    e.layerName = strToC(table.layerName);
    e.lineTypeName = strToC(table.lineTypeName);
    e.color = table.color;
    e.color24 = table.color24;
    e.lineTypeScale = 1.0;
    e.lineWeight = -1.0;
    e.basePoint = table.insertion;
    e.blockName = strToC(table.blockName);
    if (!table.parentBlockName.empty())
      e.parentBlockName = strToC(table.parentBlockName);
    e.xscale = 1.0;
    e.yscale = 1.0;
    e.zscale = 1.0;
    e.insertAngle =
        std::atan2(table.horizontal.y, table.horizontal.x);
    e.colCount = 1;
    e.rowCount = 1;
    e.extrusion = table.extrusion;
    bump(e.type);
    entities.push_back(e);
    entityMetadata.push_back({});
    DXFRW_TRACE("  addTable: block=%s parent=%s layer=%s "
                "at=(%.6f,%.6f,%.6f)",
                table.blockName.c_str(), table.parentBlockName.c_str(),
                table.layerName.c_str(),
                table.insertion.x, table.insertion.y, table.insertion.z);
  }

  void addTrace(const DRW_Trace &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_SOLID, data);
    e.basePoint = toC(data.basePoint);
    e.secPoint = toC(data.secPoint);
    e.thirdPoint = toC(data.thirdPoint);
    e.fourPoint = toC(data.fourPoint);
    e.extrusion = toC(data.extPoint);
    bump(e.type);
    entities.push_back(e);
  }

  void add3dFace(const DRW_3Dface &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_3DFACE, data);
    e.basePoint = toC(data.basePoint);
    e.secPoint = toC(data.secPoint);
    e.thirdPoint = toC(data.thirdPoint);
    e.fourPoint = toC(data.fourPoint);
    e.flags = data.invisibleflag;
    bump(e.type);
    entities.push_back(e);
  }

  void addSolid(const DRW_Solid &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_SOLID, data);
    e.basePoint = toC(data.basePoint);
    e.secPoint = toC(data.secPoint);
    e.thirdPoint = toC(data.thirdPoint);
    e.fourPoint = toC(data.fourPoint);
    e.extrusion = toC(data.extPoint);
    bump(e.type);
    entities.push_back(e);
  }

  void addMText(const DRW_MText &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_MTEXT, data);
    e.basePoint = toC(data.basePoint);
    e.secPoint = toC(data.secPoint);
    e.textValue = strToC(data.text);
    e.textHeight = data.height;
    e.textAngle = data.angle; /* degrees for MTEXT */
    e.textWidthScale = data.widthscale;
    e.textStyle = strToC(data.style);
    e.mtextInterline = data.interlin;
    e.extrusion = toC(data.extPoint);

    // For MTEXT, code 71 (attachment point) is parsed into data.textgen (1 to
    // 9). Code 72 and 73 are drawing direction and line spacing style in MTEXT,
    // but DRW_Text::parseCode incorrectly maps them to alignH/alignV, so we
    // ignore them.
    int attachment = data.textgen;
    int alignH = 0; // Default: Left
    int alignV = 3; // Default: Top

    if (attachment == 1 || attachment == 4 || attachment == 7) {
      alignH = 0; // Left
    } else if (attachment == 2 || attachment == 5 || attachment == 8) {
      alignH = 1; // Center
    } else if (attachment == 3 || attachment == 6 || attachment == 9) {
      alignH = 2; // Right
    }

    if (attachment == 1 || attachment == 2 || attachment == 3) {
      alignV = 3; // Top
    } else if (attachment == 4 || attachment == 5 || attachment == 6) {
      alignV = 2; // Middle
    } else if (attachment == 7 || attachment == 8 || attachment == 9) {
      alignV = 1; // Bottom
    }

    e.alignH = alignH;
    e.alignV = alignV;

    bump(e.type);
    entities.push_back(e);
  }

  void addText(const DRW_Text &data) override {
    if (data.text.find("2004") != std::string::npos || data.text.find("10.1.00") != std::string::npos) {
        printf("[addText DEBUG] text: '%s', h: %f, base(%f,%f), sec(%f,%f), alignH: %d, alignV: %d\n",
               data.text.c_str(), data.height, data.basePoint.x, data.basePoint.y, data.secPoint.x, data.secPoint.y, data.alignH, data.alignV);
    }
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_TEXT, data);
    e.basePoint = toC(data.basePoint);
    e.secPoint = toC(data.secPoint);
    e.textValue = strToC(data.text);
    e.textHeight = data.height;
    e.textAngle = data.angle; /* degrees */
    e.textWidthScale = data.widthscale;
    e.textStyle = strToC(data.style);
    e.extrusion = toC(data.extPoint);
    e.alignH = (int)data.alignH;
    e.alignV = (int)data.alignV;
    bump(e.type);
    entities.push_back(e);
  }

  /* ── Dimension callbacks ─────────────────────────────────────────── */

  void addDimAlign(const DRW_DimAligned *data) override {
    addDimCommon(data, DXFRW_DIM_ALIGNED);
  }
  void addDimLinear(const DRW_DimLinear *data) override {
    addDimCommon(data, DXFRW_DIM_LINEAR);
  }
  void addDimRadial(const DRW_DimRadial *data) override {
    addDimCommon(data, DXFRW_DIM_RADIAL);
  }
  void addDimDiametric(const DRW_DimDiametric *data) override {
    addDimCommon(data, DXFRW_DIM_DIAMETRIC);
  }
  void addDimAngular(const DRW_DimAngular *data) override {
    addDimCommon(data, DXFRW_DIM_ANGULAR);
  }
  void addDimAngular3P(const DRW_DimAngular3p *data) override {
    addDimCommon(data, DXFRW_DIM_ANGULAR3P);
  }
  void addDimOrdinate(const DRW_DimOrdinate *data) override {
    addDimCommon(data, DXFRW_DIM_ORDINATE);
  }

  void addLeader(const DRW_Leader *data) override {
    if (!data)
      return;
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_LEADER, *data);
    e.flags = data->arrow;              // 0=Disabled, 1=Enabled
    e.alignH = data->leadertype;        // 0=Straight, 1=Spline
    e.textHeight = data->textheight;    // text annotation height
    e.textWidthScale = data->textwidth; // text annotation width (group code 41)
    e.dimStyle = strToC(data->style);
    e.leaderOffsettext = toC(data->offsettext);

    e.vertexCount = (int)data->vertexlist.size();
    if (e.vertexCount > 0) {
      e.vertices = (DXFRW_Vertex *)malloc(sizeof(DXFRW_Vertex) * e.vertexCount);
      for (int i = 0; i < e.vertexCount; i++) {
        DRW_Coord *v = data->vertexlist[i];
        if (v) {
          e.vertices[i].x = v->x;
          e.vertices[i].y = v->y;
          e.vertices[i].startWidth = v->z; // Store Z coordinate in startWidth
          e.vertices[i].endWidth = 0.0;
          e.vertices[i].bulge = 0.0;
        } else {
          e.vertices[i].x = 0.0;
          e.vertices[i].y = 0.0;
          e.vertices[i].startWidth = 0.0;
          e.vertices[i].endWidth = 0.0;
          e.vertices[i].bulge = 0.0;
        }
      }
    }
    bump(e.type);
    entities.push_back(e);
  }

  static void appendUniquePoint(std::vector<DXFRW_Coord> &pts,
                                const DRW_Coord &p) {
    DXFRW_Coord c = toC(p);
    if (!pts.empty()) {
      double dx = pts.back().x - c.x;
      double dy = pts.back().y - c.y;
      double dz = pts.back().z - c.z;
      if (dx * dx + dy * dy + dz * dz < 1e-12)
        return;
    }
    pts.push_back(c);
  }

  static void appendUniquePoint(std::vector<DXFRW_Coord> &pts,
                                const DXFRW_Coord &p) {
    if (!pts.empty()) {
      double dx = pts.back().x - p.x;
      double dy = pts.back().y - p.y;
      double dz = pts.back().z - p.z;
      if (dx * dx + dy * dy + dz * dz < 1e-12)
        return;
    }
    pts.push_back(p);
  }

  static void getHatchLoopEditPoints(const DRW_HatchLoop *loop, std::vector<DXFRW_Coord> &outPoints) {
    if (!loop) return;

    for (size_t j = 0; j < loop->objlist.size(); ++j) {
      DRW_Entity *ent = loop->objlist.at(j);
      if (!ent)
        continue;

      switch (ent->eType) {
      case DRW::LINE: {
        DRW_Line *l = (DRW_Line *)ent;
        appendUniquePoint(outPoints, l->basePoint);
        appendUniquePoint(outPoints, l->secPoint);
        break;
      }
      case DRW::ARC: {
        DRW_Arc *a = (DRW_Arc *)ent;
        double start = a->staangle;            // already radians (libdxfrw /ARAD)
        double end = a->endangle;
        double span = end - start;
        if (span <= 0.0)
          span += 2.0 * M_PI;                  // forward short arc; isccw ignored
        int steps = std::max(1, (int)ceil(fabs(span) / (M_PI * 0.5)));
        for (int k = 0; k <= steps; ++k) {
          double t = (double)k / (double)steps;
          double angle = start + span * t;
          DRW_Coord pt;
          pt.x = a->basePoint.x + cos(angle) * a->radious;
          pt.y = a->basePoint.y - sin(angle) * a->radious;   // CW: minus
          pt.z = a->basePoint.z;
          appendUniquePoint(outPoints, pt);
        }
        break;
      }
      case DRW::CIRCLE: {
        DRW_Circle *c = (DRW_Circle *)ent;
        for (int k = 0; k < 4; ++k) {
          double angle = (double)k * M_PI * 0.5;
          DRW_Coord pt;
          pt.x = c->basePoint.x + cos(angle) * c->radious;
          pt.y = c->basePoint.y - sin(angle) * c->radious;   // CW: minus
          pt.z = c->basePoint.z;
          appendUniquePoint(outPoints, pt);
        }
        break;
      }
      case DRW::ELLIPSE: {
        DRW_Ellipse *el = (DRW_Ellipse *)ent;
        DRW_Coord center = el->basePoint;
        DRW_Coord majorVec = el->secPoint;
        double majorLen =
            sqrt(majorVec.x * majorVec.x + majorVec.y * majorVec.y +
                majorVec.z * majorVec.z);
        double minorLen = majorLen * el->ratio;
        if (majorLen > 1e-12 && minorLen > 1e-12) {
          DRW_Coord majorDir = majorVec;
          majorDir.x /= majorLen;
          majorDir.y /= majorLen;
          majorDir.z /= majorLen;
          DRW_Coord minorDir;
          minorDir.x = majorDir.y;             // CW perpendicular (-90)
          minorDir.y = -majorDir.x;
          minorDir.z = 0;
          double start = el->staparam;          // already radians
          double end = el->endparam;
          double sweep = end - start;
          if (sweep <= 0.0)
            sweep += 2.0 * M_PI;               // forward short arc; isccw ignored
          int steps = std::max(1, (int)ceil(fabs(sweep) / (M_PI * 0.5)));
          for (int k = 0; k <= steps; ++k) {
            double t = (double)k / (double)steps;
            double param = start + sweep * t;
            DRW_Coord pt;
            pt.x = center.x + majorDir.x * cos(param) * majorLen +
                  minorDir.x * sin(param) * minorLen;
            pt.y = center.y + majorDir.y * cos(param) * majorLen +
                  minorDir.y * sin(param) * minorLen;
            pt.z = center.z + majorDir.z * cos(param) * majorLen +
                  minorDir.z * sin(param) * minorLen;
            appendUniquePoint(outPoints, pt);
          }
        }
        break;
      }
      case DRW::LWPOLYLINE: {
        DRW_LWPolyline *pl = (DRW_LWPolyline *)ent;
        for (size_t k = 0; k < pl->vertlist.size(); ++k) {
          DRW_Vertex2D *v = pl->vertlist.at(k);
          if (!v)
            continue;
          DXFRW_Coord pt;
          pt.x = v->x;
          pt.y = v->y;
          pt.z = pl->elevation;
          appendUniquePoint(outPoints, pt);
        }
        break;
      }
      case DRW::POLYLINE: {
        DRW_Polyline *pl = (DRW_Polyline *)ent;
        for (size_t k = 0; k < pl->vertlist.size(); ++k) {
          DRW_Vertex *v = pl->vertlist.at(k);
          if (v)
            appendUniquePoint(outPoints, v->basePoint);
        }
        break;
      }
      case DRW::SPLINE: {
        DRW_Spline *sp = (DRW_Spline *)ent;
        if (!sp->controllist.empty()) {
          for (size_t k = 0; k < sp->controllist.size(); ++k) {
            if (sp->controllist[k])
              appendUniquePoint(outPoints, *sp->controllist[k]);
          }
        } else {
          for (size_t k = 0; k < sp->fitlist.size(); ++k) {
            if (sp->fitlist[k])
              appendUniquePoint(outPoints, *sp->fitlist[k]);
          }
        }
        break;
      }
      default:
        break;
      }
    }

    if (outPoints.size() > 1) {
      const DXFRW_Coord &a = outPoints.front();
      const DXFRW_Coord &b = outPoints.back();
      double dx = a.x - b.x;
      double dy = a.y - b.y;
      double dz = a.z - b.z;
      if (dx * dx + dy * dy + dz * dz < 1e-10)
        outPoints.pop_back();
    }

}

  static void getHatchLoopPoints(const DRW_HatchLoop *loop,
                                 std::vector<DXFRW_Coord> &outPoints) {
    // 1. Collect points for each edge independently
    std::vector<std::vector<DXFRW_Coord>> edges;

    for (size_t j = 0; j < loop->objlist.size(); ++j) {
      DRW_Entity *ent = loop->objlist.at(j);
      if (!ent)
        continue;

      std::vector<DXFRW_Coord> edgePts;

      switch (ent->eType) {
      case DRW::LINE: {
        DRW_Line *l = (DRW_Line *)ent;
        edgePts.push_back(toC(l->basePoint));
        edgePts.push_back(toC(l->secPoint));
        break;
      }
      case DRW::ARC: {
        DRW_Arc *a = (DRW_Arc *)ent;
        double start = a->staangle;
        double end = a->endangle;
        double span = end - start;
        if (span <= 0.0)
          span += 2.0 * M_PI;                  // forward short arc; isccw ignored

        int segments = 16;
        for (int s = 0; s <= segments; ++s) {
          double t = (double)s / segments;
          double angle = start + span * t;
          DRW_Coord pt;
          pt.x = a->basePoint.x + cos(angle) * a->radious;
          pt.y = a->basePoint.y - sin(angle) * a->radious;   // CW: minus
          pt.z = a->basePoint.z;
          edgePts.push_back(toC(pt));
        }
        break;
      }
      case DRW::CIRCLE: {
        DRW_Circle *c = (DRW_Circle *)ent;
        int segments = 32;
        for (int s = 0; s <= segments; ++s) {
          double angle = (double)s * 2.0 * M_PI / segments;
          DRW_Coord pt;
          pt.x = c->basePoint.x + cos(angle) * c->radious;
          pt.y = c->basePoint.y - sin(angle) * c->radious;   // CW: minus
          pt.z = c->basePoint.z;
          edgePts.push_back(toC(pt));
        }
        break;
      }
      case DRW::LWPOLYLINE: {
        DRW_LWPolyline *pl = (DRW_LWPolyline *)ent;
        bool isClosed = (pl->flags & 1) != 0;
        for (size_t k = 0; k < pl->vertlist.size(); ++k) {
          DRW_Vertex2D *v = pl->vertlist.at(k);
          DRW_Coord pt;
          pt.x = v->x;
          pt.y = v->y;
          pt.z = pl->elevation;
          edgePts.push_back(toC(pt));

          if (v->bulge != 0) {
            bool hasNext = k + 1 < pl->vertlist.size();
            if (hasNext || isClosed) {
              DRW_Vertex2D *v2 =
                  hasNext ? pl->vertlist.at(k + 1) : pl->vertlist.at(0);
              double b = v->bulge;
              double dx = v2->x - v->x;
              double dy = v2->y - v->y;
              double L = sqrt(dx * dx + dy * dy);
              if (L > 1e-10) {
                double R = L * (1.0 + b * b) / (4.0 * fabs(b));
                double mx = (v->x + v2->x) * 0.5;
                double my = (v->y + v2->y) * 0.5;
                double px = v->y - v2->y;
                double py = v2->x - v->x;
                double factor = (1.0 - b * b) / (4.0 * b);
                double cx = mx + factor * px;
                double cy = my + factor * py;
                double startAngle = atan2(v->y - cy, v->x - cx);
                double sweep = 4.0 * atan(fabs(b));
                int segs = (int)ceil(sweep * 12.0);
                if (segs < 4)
                  segs = 4;
                for (int j2 = 1; j2 < segs; ++j2) {
                  double t = (double)j2 / segs;
                  double angle = startAngle + (b > 0 ? sweep * t : -sweep * t);
                  DRW_Coord rpt;
                  rpt.x = cx + R * cos(angle);
                  rpt.y = cy + R * sin(angle);
                  rpt.z = pl->elevation;
                  edgePts.push_back(toC(rpt));
                }
              }
            }
          }
        }
        break;
      }
      case DRW::POLYLINE: {
        DRW_Polyline *pl = (DRW_Polyline *)ent;
        bool isClosed = (pl->flags & 1) != 0;
        for (size_t k = 0; k < pl->vertlist.size(); ++k) {
          DRW_Vertex *v = pl->vertlist.at(k);
          edgePts.push_back(toC(v->basePoint));

          if (v->bulge != 0) {
            bool hasNext = k + 1 < pl->vertlist.size();
            if (hasNext || isClosed) {
              DRW_Vertex *v2 =
                  hasNext ? pl->vertlist.at(k + 1) : pl->vertlist.at(0);
              double b = v->bulge;
              double dx = v2->basePoint.x - v->basePoint.x;
              double dy = v2->basePoint.y - v->basePoint.y;
              double L = sqrt(dx * dx + dy * dy);
              if (L > 1e-10) {
                double R = L * (1.0 + b * b) / (4.0 * fabs(b));
                double mx = (v->basePoint.x + v2->basePoint.x) * 0.5;
                double my = (v->basePoint.y + v2->basePoint.y) * 0.5;
                double px = v->basePoint.y - v2->basePoint.y;
                double py = v2->basePoint.x - v->basePoint.x;
                double factor = (1.0 - b * b) / (4.0 * b);
                double cx = mx + factor * px;
                double cy = my + factor * py;
                double startAngle =
                    atan2(v->basePoint.y - cy, v->basePoint.x - cx);
                double sweep = 4.0 * atan(fabs(b));
                int segs = (int)ceil(sweep * 12.0);
                if (segs < 4)
                  segs = 4;
                for (int j2 = 1; j2 < segs; ++j2) {
                  double t = (double)j2 / segs;
                  double angle = startAngle + (b > 0 ? sweep * t : -sweep * t);
                  DRW_Coord rpt;
                  rpt.x = cx + R * cos(angle);
                  rpt.y = cy + R * sin(angle);
                  rpt.z = v->basePoint.z;
                  edgePts.push_back(toC(rpt));
                }
              }
            }
          }
        }
        break;
      }
      case DRW::ELLIPSE: {
        DRW_Ellipse *el = (DRW_Ellipse *)ent;
        DRW_Coord center = el->basePoint;
        DRW_Coord majorVec = el->secPoint;
        double majorLen =
            sqrt(majorVec.x * majorVec.x + majorVec.y * majorVec.y +
                 majorVec.z * majorVec.z);
        double minorLen = majorLen * el->ratio;
        if (majorLen > 1e-12 && minorLen > 1e-12) {
          DRW_Coord majorDir = majorVec;
          majorDir.x /= majorLen;
          majorDir.y /= majorLen;
          majorDir.z /= majorLen;
          DRW_Coord minorDir;
          minorDir.x = majorDir.y;             // CW perpendicular (-90)
          minorDir.y = -majorDir.x;
          minorDir.z = 0;
          int segments = 32;
          double start = el->staparam;
          double end = el->endparam;
          double sweep = end - start;
          if (sweep <= 0.0)
            sweep += 2.0 * M_PI;               // forward short arc; isccw ignored

          for (int s = 0; s <= segments; ++s) {
            double t = (double)s / segments;
            double param = start + sweep * t;
            DRW_Coord pt;
            pt.x = center.x + majorDir.x * cos(param) * majorLen +
                   minorDir.x * sin(param) * minorLen;
            pt.y = center.y + majorDir.y * cos(param) * majorLen +
                   minorDir.y * sin(param) * minorLen;
            pt.z = center.z + majorDir.z * cos(param) * majorLen +
                   minorDir.z * sin(param) * minorLen;
            edgePts.push_back(toC(pt));
          }
        }
        break;
      }
      case DRW::SPLINE: {
        DRW_Spline *sp = (DRW_Spline *)ent;
        int degree = sp->degree;
        if (degree < 1)
          degree = 3;
        int nctrl = (int)sp->controllist.size();
        int nknots = (int)sp->knotslist.size();
        if (nctrl > degree && nknots > 0) {
          int expectedCPs = nknots - degree - 1;
          /* Build arrays with optional wrapping for closed splines */
          std::vector<DRW_Coord> cpts;
          std::vector<double> wts;
          for (int ci = 0; ci < nctrl; ci++) {
            cpts.push_back(*sp->controllist[ci]);
          }
          for (int ci = 0; ci < (int)sp->weightlist.size() && ci < nctrl;
               ci++) {
            wts.push_back(sp->weightlist[ci]);
          }
          /* Pad control points if compacted (periodic splines) */
          while ((int)cpts.size() < expectedCPs) {
            cpts.push_back(cpts[cpts.size() % nctrl]);
            wts.push_back(
                wts.empty() ? 1.0 : wts[wts.size() % sp->weightlist.size()]);
          }
          while ((int)wts.size() < (int)cpts.size()) {
            wts.push_back(1.0);
          }

          int m = nknots - 1;
          int p = degree;
          double tMin = sp->knotslist[p];
          double tMax = sp->knotslist[m - p];
          if (tMax > tMin) {
            int segments = 48;
            for (int si = 0; si <= segments; si++) {
              double t = tMin + (tMax - tMin) * (double)si / (double)segments;
              if (si == segments)
                t -= 1e-9;

              /* Find knot span */
              int span = p;
              while (span < m - p && sp->knotslist[span + 1] <= t)
                span++;

              /* Basis functions (De Boor bottom-up) */
              double N[32] = {};
              double left[32] = {}, right[32] = {};
              N[0] = 1.0;
              for (int j = 1; j <= p; j++) {
                left[j] = t - sp->knotslist[span + 1 - j];
                right[j] = sp->knotslist[span + j] - t;
                double saved = 0.0;
                for (int r = 0; r < j; r++) {
                  double temp = N[r] / (right[r + 1] + left[j - r]);
                  N[r] = saved + right[r + 1] * temp;
                  saved = left[j - r] * temp;
                }
                N[j] = saved;
              }

              /* Multiply with control points and weights */
              double px = 0, py = 0, pz = 0, wSum = 0;
              for (int j = 0; j <= p; j++) {
                int idx = span - p + j;
                if (idx < 0 || idx >= (int)cpts.size())
                  continue;
                double w = (idx < (int)wts.size()) ? wts[idx] : 1.0;
                double basis = N[j] * w;
                px += cpts[idx].x * basis;
                py += cpts[idx].y * basis;
                pz += cpts[idx].z * basis;
                wSum += basis;
              }
              if (wSum > 1e-10) {
                DRW_Coord pt;
                pt.x = px / wSum;
                pt.y = py / wSum;
                pt.z = pz / wSum;
                edgePts.push_back(toC(pt));
              }
            }
          }
        } else if (!sp->fitlist.empty()) {
          /* Fallback: connect fit points with line segments */
          for (size_t fi = 0; fi < sp->fitlist.size(); fi++) {
            edgePts.push_back(toC(*sp->fitlist[fi]));
          }
        }
        break;
      }
      default:
        break;
      }

      if (!edgePts.empty()) {
        edges.push_back(edgePts);
      }
    }

    // 2. Stitch the disjointed edges end-to-end to prevent path zig-zagging
    if (edges.empty())
      return;

    std::vector<bool> used(edges.size(), false);
    outPoints = edges[0];
    used[0] = true;
    int usedCount = 1;

    auto distSq = [](const DXFRW_Coord &p1, const DXFRW_Coord &p2) {
      double dx = p1.x - p2.x, dy = p1.y - p2.y;
      return dx * dx + dy * dy;
    };

    while (usedCount < edges.size()) {
      DXFRW_Coord tail = outPoints.back();
      int bestEdge = -1;
      bool reverseEdge = false;
      double bestDist = 1e9;

      // Find the nearest contiguous edge
      for (size_t i = 1; i < edges.size(); ++i) {
        if (used[i] || edges[i].empty())
          continue;

        double dStart = distSq(tail, edges[i].front());
        double dEnd = distSq(tail, edges[i].back());

        if (dStart < bestDist) {
          bestDist = dStart;
          bestEdge = (int)i;
          reverseEdge = false;
        }
        if (dEnd < bestDist) {
          bestDist = dEnd;
          bestEdge = (int)i;
          reverseEdge = true;
        }
      }

      if (bestEdge != -1 && bestDist < 1e-4) { // Edges connect
        used[bestEdge] = true;
        usedCount++;
        if (reverseEdge) {
          outPoints.insert(outPoints.end(), edges[bestEdge].rbegin(),
                           edges[bestEdge].rend());
        } else {
          outPoints.insert(outPoints.end(), edges[bestEdge].begin(),
                           edges[bestEdge].end());
        }
      } else {
        // Fallback: If disconnected, just dump the next unused edge
        for (size_t i = 1; i < edges.size(); ++i) {
          if (!used[i]) {
            used[i] = true;
            usedCount++;
            outPoints.insert(outPoints.end(), edges[i].begin(), edges[i].end());
            break;
          }
        }
      }
    }
  }

  void addHatch(const DRW_Hatch *data) override {
    if (!data)
      return;
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_HATCH, *data);
    e.hatchSolid = data->solid;
    e.hatchPatternName = strToC(data->name);
    e.hatchScale = data->scale;
    e.hatchAngle = data->angle;
    e.extrusion = toC(data->extPoint);

    e.hatchLoopCount = (int)data->looplist.size();
    if (e.hatchLoopCount > 0) {
      e.hatchLoops = (DXFRW_HatchLoopData *)malloc(sizeof(DXFRW_HatchLoopData) *
                                                   e.hatchLoopCount);
      for (int i = 0; i < e.hatchLoopCount; i++) {
        DRW_HatchLoop *loop = data->looplist.at(i);
        std::vector<DXFRW_Coord> rawPoints;
        std::vector<DXFRW_Coord> editPoints;
        getHatchLoopPoints(loop, rawPoints);
        getHatchLoopEditPoints(loop, editPoints);

        std::vector<DXFRW_Coord> cleanPoints;
        for (size_t k = 0; k < rawPoints.size(); ++k) {
          if (cleanPoints.empty()) {
            cleanPoints.push_back(rawPoints[k]);
          } else {
            const DXFRW_Coord &last = cleanPoints.back();
            double dx = rawPoints[k].x - last.x;
            double dy = rawPoints[k].y - last.y;
            if (sqrt(dx * dx + dy * dy) > 1e-5) {
              cleanPoints.push_back(rawPoints[k]);
            }
          }
        }

        e.hatchLoops[i].loopFlags = loop->type;
        e.hatchLoops[i].vertexCount = (int)cleanPoints.size();
        if (e.hatchLoops[i].vertexCount > 0) {
          e.hatchLoops[i].vertices = (DXFRW_Coord *)malloc(
              sizeof(DXFRW_Coord) * e.hatchLoops[i].vertexCount);
          std::memcpy(e.hatchLoops[i].vertices, cleanPoints.data(),
                      sizeof(DXFRW_Coord) * e.hatchLoops[i].vertexCount);
        } else {
          e.hatchLoops[i].vertices = nullptr;
        }

        e.hatchLoops[i].editVertexCount = (int)editPoints.size();
        if (e.hatchLoops[i].editVertexCount > 0) {
          e.hatchLoops[i].editVertices = (DXFRW_Coord *)malloc(
              sizeof(DXFRW_Coord) * e.hatchLoops[i].editVertexCount);
          std::memcpy(e.hatchLoops[i].editVertices, editPoints.data(),
                      sizeof(DXFRW_Coord) * e.hatchLoops[i].editVertexCount);
        } else {
          e.hatchLoops[i].editVertices = nullptr;
        }
      }
    }

    /* Gradient data (populated from DRW_Hatch's gradient fields) */
    e.isGradient = data->isGradient;
    e.gradientName = strToC(data->gradientName);
    e.gradientAngle = data->gradientAngle;
    e.color1 = -1;
    e.color2 = -1;
    e.hatchBackgroundColor = (data->bgColor >= 0 && data->bgColor <= 255) ? aciToRgb(data->bgColor) : -1;

    auto entityRgb = [&]() -> int {
      if (e.color24 >= 0)
        return e.color24;
      if (e.color > 0 && e.color < 256)
        return aciToRgb(e.color);
      return -1;
    };

    auto stopRgb = [&](size_t idx) -> int {
      if (idx >= data->gradientColors.size())
        return -1;
      const auto &gc = data->gradientColors[idx];
      if (gc.rgb >= 0)
        return gc.rgb;
      return aciToRgb((int)gc.unkShort);
    };

    if (data->gradientColors.size() >= 2) {
      e.color1 = stopRgb(0);
      e.color2 = stopRgb(data->gradientColors.size() - 1);
    } else if (data->gradientColors.size() == 1) {
      int stop = stopRgb(0);
      int base = entityRgb();
      e.color1 = (base >= 0) ? base : stop;
      e.color2 = stop;
    } else if (data->singleColorGrad != 0 && data->gradientTint > 0.0) {
      int base = entityRgb();
      e.color1 = base;
      if (base >= 0) {
        double tint = data->gradientTint;
        int r = (base >> 16) & 0xFF;
        int g = (base >> 8) & 0xFF;
        int b = base & 0xFF;
        r = (std::min)(255, (int)(r * (1.0 - tint) + 255 * tint));
        g = (std::min)(255, (int)(g * (1.0 - tint) + 255 * tint));
        b = (std::min)(255, (int)(b * (1.0 - tint) + 255 * tint));
        e.color2 = (r << 16) | (g << 8) | b;
      }
    }

    bump(e.type);
    entities.push_back(e);
  }

  void addViewport(const DRW_Viewport &data) override {
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_VIEWPORT, data);
    e.basePoint = toC(data.basePoint);
    e.viewportWidth = data.pswidth;
    e.viewportHeight = data.psheight;
    e.viewportStatus = data.vpstatus;
    e.viewportID = data.vpID;
    e.viewportViewCenterX = data.centerPX;
    e.viewportViewCenterY = data.centerPY;
    e.viewportViewTarget = toC(data.viewTarget);
    e.viewportViewHeight = data.viewHeight;
    e.viewportTwistAngle = data.twistAngle;
    bump(e.type);
    entities.push_back(e);
  }
  void addImage(const DRW_Image *data) override {
    if (!data) return;
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_IMAGE, *data);

    // Insertion point (basePoint from DRW_Line)
    e.basePoint = toC(data->basePoint);

    // U-axis vector: secPoint - basePoint (sizeu gives pixel width)
    e.imageU = toC(data->secPoint);

    // V-vector (from vVector field)
    e.imageV = toC(data->vVector);

    // Image pixel dimensions from sizeu/sizev
    e.imageSizeU = data->sizeu;
    e.imageSizeV = data->sizev;
    e.imageBrightness = data->brightness;
    e.imageContrast   = data->contrast;
    e.imageFade       = data->fade;

    // Clipping
    e.imageClippingEnabled = data->clip;
    e.imageClipVertexCount = 0;  // clipping boundary handled separately if needed
    e.imageClipVertices = nullptr;

    // Display flags
    e.imageDisplayFlags = 0;

    // Store IMAGEDEF handle reference (duint32 → string)
    char refBuf[32];
    std::snprintf(refBuf, sizeof(refBuf), "%u", data->ref);
    e.imageDefHandle = strToC(std::string(refBuf));

    bump(e.type);
    entities.push_back(e);
  }

  void linkImage(const DRW_ImageDef *data) override {
    if (!data) return;
    // Store handle → file path mapping for later resolution
    char handleBuf[32];
    std::snprintf(handleBuf, sizeof(handleBuf), "%u", data->handle);
    std::string handleStr(handleBuf);
    std::string path = data->name;

    imageDefPathMap[handleStr] = path;

    // Also resolve any already-created entities that reference this handle
    for (auto &entity : entities) {
      if (entity.type == DXFRW_ET_IMAGE && entity.imageDefHandle) {
        std::string defHandle(entity.imageDefHandle);
        if (defHandle == handleStr && entity.imageFilePath == nullptr) {
          entity.imageFilePath = strToC(path);
        }
      }
    }
  }

  void addComment(const char *comment) override { (void)comment; }

  /* ── Write callbacks (unused, we only read) ──────────────────────── */

  void writeHeader(DRW_Header &data) override { (void)data; }
  void writeBlocks() override {}
  void writeBlockRecords() override {}
  void writeEntities() override {}
  void writeLTypes() override {}
  void writeLayers() override {}
  void writeTextstyles() override {}
  void writeVports() override {}
  void writeDimstyles() override {}
  void writeAppId() override {}

private:
  /* Common dimension processing */
  void addDimCommon(const DRW_Dimension *data, DXFRW_DimType dimType) {
    if (!data)
      return;
    DXFRW_EntityData e;
    initEntity(e, DXFRW_ET_DIMENSION, *data);
    e.dimType = dimType;
    e.dimText = strToC(data->getText());
    e.dimStyle = strToC(data->getStyle());
    e.dimDefPoint = toC(data->getDefPoint());
    e.dimTextPoint = toC(data->getTextPoint());
    // e.blockName = strToC(data->getName());
    e.blockName = strToC(const_cast<DRW_Dimension *>(data)->getName());
    /* angle/oblique are protected in base class; skip for now */
    e.dimAngle = 0.0;
    e.dimOblique = 0.0;
    e.extrusion.x = e.extrusion.y = 0.0;
    e.extrusion.z = 1.0;
    bump(e.type);
    entities.push_back(e);
  }
};

/* ── Extern "C" API ────────────────────────────────────────────────────── */

int dxfrw_read(const char *filePath, DXFRW_Result *outResult) {
  if (!filePath || !outResult)
    return 0;

  DXFRW_TRACE("dxfrw_read: opening '%s'", filePath);

  /* Zero the result */
  std::memset(outResult, 0, sizeof(DXFRW_Result));

  char *codepageStrippedPath = stripDwgCodepage(filePath);
  const char *afterCodepagePath =
      codepageStrippedPath ? codepageStrippedPath : filePath;

  if (codepageStrippedPath) {
    DXFRW_TRACE("dxfrw_read: stripped DWGCODEPAGE, using temp file '%s'",
                codepageStrippedPath);
  }

  char *mtextStrippedPath = stripMTextEmbeddedObjects(afterCodepagePath);
  const char *parsePath =
      mtextStrippedPath ? mtextStrippedPath : afterCodepagePath;

  /* Create the DXF reader */
  dxfRW dxf(parsePath);
  DXFRW_TRACE("dxfrw_read: dxfRW created, starting parse...");

  /* Create our collector */
  DXFCollector collector;

  /* Parse with exception protection — libdxfrw can throw on malformed files */
  bool ok = false;

  /* Sniff the file to diagnose binary/encoding issues */
  {
    FILE *sniff = std::fopen(filePath, "rb");
    if (sniff) {
      unsigned char buf[256];
      size_t n = std::fread(buf, 1, sizeof(buf) - 1, sniff);
      std::fclose(sniff);
      buf[n] = 0;
      // Check for binary DXF signature (AutoCAD binary DXF starts with "AutoCAD
      // Binary DXF")
      bool isBinary =
          (n > 18 && std::memcmp(buf, "AutoCAD Binary DXF", 18) == 0);
      DXFRW_TRACE(
          "dxfrw_read: file sniff: %zu bytes, binary=%s, first line: '%.100s'",
          n, isBinary ? "YES" : "no",
          isBinary ? "(binary)" : (const char *)buf);
    }
  }

  try {
    /* applyExt=true: libdxfrw converts OCS coordinates to WCS using the
     * arbitrary axis algorithm for the entity types whose DXF coordinates
     * are stored in OCS — CIRCLE, ARC (including the M_PI-angle mirror and
     * start/end swap for (0,0,-1) extrusion), ELLIPSE (major-axis mirror and
     * start/end parameter swap), SOLID/TRACE, and LWPOLYLINE vertices.
     * Entities whose DXF coordinates are already WCS (LINE, POINT, SPLINE,
     * HATCH boundaries, MTEXT) have no-op applyExtrusion() overrides and are
     * untouched. INSERT base points are NOT converted by libdxfrw
     * (DRW_Insert::applyExtrusion is a no-op), so mirrored block references
     * remain the responsibility of DXFImporter.swift's insert transform.
     *
     * This was previously `false`, which left LWPOLYLINEs/ARCs/etc. with
     * 210 extrusion (0,0,-1) in raw OCS coordinates — rendering them
     * mirrored about the Y axis relative to the WCS entities in the file. */
    ok = dxf.read(&collector, true);
    if (ok) {
      const std::vector<RawViewportData> viewports =
          readRawViewports(filePath);
      std::unordered_map<unsigned int, RawViewportData> viewportByHandle;
      for (const RawViewportData &viewport : viewports)
        viewportByHandle[viewport.handle] = viewport;
      const size_t count =
          std::min(collector.entities.size(), collector.entityMetadata.size());
      for (size_t i = 0; i < count; i++) {
        if (collector.entities[i].type != DXFRW_ET_VIEWPORT)
          continue;
        const auto found =
            viewportByHandle.find(collector.entityMetadata[i].handle);
        if (found == viewportByHandle.end())
          continue;
        const RawViewportData &viewport = found->second;
        DXFRW_EntityData &entity = collector.entities[i];
        entity.basePoint.x = viewport.paperCenterX;
        entity.basePoint.y = viewport.paperCenterY;
        entity.viewportWidth = viewport.paperWidth;
        entity.viewportHeight = viewport.paperHeight;
        entity.viewportStatus = viewport.status;
        entity.viewportID = viewport.viewportID;
        entity.viewportViewCenterX = viewport.viewCenterX;
        entity.viewportViewCenterY = viewport.viewCenterY;
        entity.viewportViewTarget = viewport.viewTarget;
        entity.viewportViewHeight = viewport.viewHeight;
        entity.viewportTwistAngle = viewport.twistAngle;
      }
      const std::vector<RawTableInsert> tables =
          readRawTableInserts(filePath);
      for (const RawTableInsert &table : tables) {
        collector.addTableInsert(table);
      }
    }
  } catch (const std::exception &ex) {
    DXFRW_TRACE("dxfrw_read: C++ exception: %s", ex.what());
    outResult->success = 0;
    outResult->errorMessage = strToC(ex.what());
    cleanupTempPath(mtextStrippedPath);
    cleanupTempPath(codepageStrippedPath);
    return 0;
  } catch (...) {
    DXFRW_TRACE("dxfrw_read: unknown C++ exception");
    outResult->success = 0;
    outResult->errorMessage = strToC("Unknown C++ exception during DXF parse");
    cleanupTempPath(mtextStrippedPath);
    cleanupTempPath(codepageStrippedPath);
    return 0;
  }

  DXFRW_TRACE("dxfrw_read: parse %s (layers=%zu blocks=%zu entities=%zu)",
              ok ? "OK" : "FAILED", collector.layers.size(),
              collector.blocks.size(), collector.entities.size());

  if (!ok) {
    outResult->success = 0;
    outResult->errorMessage = strToC("Failed to parse DXF file");
    cleanupTempPath(mtextStrippedPath);
    cleanupTempPath(codepageStrippedPath);
    return 0;
  }

  /* ── Populate result: layers ─────────────────────────────────────── */

  outResult->layerCount = (int)collector.layers.size();
  if (outResult->layerCount > 0) {
    outResult->layers = (DXFRW_LayerData *)malloc(sizeof(DXFRW_LayerData) *
                                                  outResult->layerCount);
    DXFRW_TRACE("dxfrw_read: copying %d layers", outResult->layerCount);
    std::memcpy(outResult->layers, collector.layers.data(),
                sizeof(DXFRW_LayerData) * outResult->layerCount);
  }

  /* ── Populate result: blocks ─────────────────────────────────────── */

  outResult->blockCount = (int)collector.blocks.size();
  if (outResult->blockCount > 0) {
    outResult->blocks = (DXFRW_BlockData *)malloc(sizeof(DXFRW_BlockData) *
                                                  outResult->blockCount);
    DXFRW_TRACE("dxfrw_read: copying %d blocks", outResult->blockCount);
    std::memcpy(outResult->blocks, collector.blocks.data(),
                sizeof(DXFRW_BlockData) * outResult->blockCount);
  }

  /* ── Populate result: entities ───────────────────────────────────── */

  outResult->entityCount = (int)collector.entities.size();
  if (outResult->entityCount > 0) {
    outResult->entities = (DXFRW_EntityData *)malloc(sizeof(DXFRW_EntityData) *
                                                     outResult->entityCount);
    DXFRW_TRACE("dxfrw_read: copying %d entities", outResult->entityCount);
    std::memcpy(outResult->entities, collector.entities.data(),
                sizeof(DXFRW_EntityData) * outResult->entityCount);
  }

  if (outResult->entityCount > 0) {
    outResult->entityMetadata = (DXFRW_EntityMetadata *)calloc(
        outResult->entityCount, sizeof(DXFRW_EntityMetadata));
    const int metadataCount = (int)collector.entityMetadata.size();
    const int copyCount = std::min(outResult->entityCount, metadataCount);
    for (int i = 0; i < copyCount; i++) {
      outResult->entityMetadata[i] = collector.entityMetadata[i];
    }
    DXFRW_TRACE("dxfrw_read: entity metadata=%d entities=%d",
                metadataCount, outResult->entityCount);
  }

  if (outResult->blockCount > 0) {
    outResult->blockMetadata = (DXFRW_BlockMetadata *)calloc(
        outResult->blockCount, sizeof(DXFRW_BlockMetadata));
    const int metadataCount = (int)collector.blockOwnerHandles.size();
    const int copyCount = std::min(outResult->blockCount, metadataCount);
    for (int i = 0; i < copyCount; i++) {
      outResult->blockMetadata[i].ownerHandle = collector.blockOwnerHandles[i];
    }
  }

  /* ── Populate result: textStyles ─────────────────────────────────── */

  outResult->textStyleCount = (int)collector.textStyles.size();
  if (outResult->textStyleCount > 0) {
    outResult->textStyles = (DXFRW_TextStyleData *)malloc(
        sizeof(DXFRW_TextStyleData) * outResult->textStyleCount);
    DXFRW_TRACE("dxfrw_read: copying %d textStyles", outResult->textStyleCount);
    std::memcpy(outResult->textStyles, collector.textStyles.data(),
                sizeof(DXFRW_TextStyleData) * outResult->textStyleCount);
  }

  /* ── Populate result: linetypes ──────────────────────────────────── */

  outResult->linetypeCount = (int)collector.linetypes.size();
  if (outResult->linetypeCount > 0) {
    outResult->linetypes = (DXFRW_LinetypeData *)malloc(
        sizeof(DXFRW_LinetypeData) * outResult->linetypeCount);
    DXFRW_TRACE("dxfrw_read: copying %d linetypes", outResult->linetypeCount);
    std::memcpy(outResult->linetypes, collector.linetypes.data(),
                sizeof(DXFRW_LinetypeData) * outResult->linetypeCount);
  }

  DXFRW_TRACE("dxfrw_read: success, returning");
  cleanupTempPath(mtextStrippedPath);
  cleanupTempPath(codepageStrippedPath);
  
  outResult->globalLinetypeScale = collector.globalLinetypeScale;
  
  outResult->success = 1;
  return 1;
}

void dxfrw_result_free(DXFRW_Result *result) {
  if (!result)
    return;

  /* Free layers */
  for (int i = 0; i < result->layerCount; i++) {
    free(result->layers[i].name);
    free(result->layers[i].lineTypeName);
  }
  free(result->layers);

  /* Free blocks */
  for (int i = 0; i < result->blockCount; i++) {
    free(result->blocks[i].name);
  }
  free(result->blocks);
  free(result->blockMetadata);

  /* Free entities */
  for (int i = 0; i < result->entityCount; i++) {
    DXFRW_EntityData *e = &result->entities[i];
    free(e->layerName);
    free(e->lineTypeName);
    free(e->textValue);
    free(e->textStyle);
    free(e->blockName);
    free(e->parentBlockName);
    free(e->hatchPatternName);
    free(e->gradientName);
    free(e->dimText);
    free(e->dimStyle);

    if (e->hatchLoopCount > 0 && e->hatchLoops) {
      for (int j = 0; j < e->hatchLoopCount; j++) {
        free(e->hatchLoops[j].vertices);
        free(e->hatchLoops[j].editVertices);
      }
      free(e->hatchLoops);
    }

    if (e->vertexCount > 0) {
      free(e->vertices);
    }
    if (e->splineNKnots > 0) {
      free(e->splineKnots);
    }
    if (e->splineNControl > 0) {
      free(e->splineControlPoints);
    }
    if (e->splineNFit > 0) {
      free(e->splineFitPoints);
    }

    /* --- FIX: Free the Spline Weights --- */
    if (e->splineWeightCount > 0) {
      free(e->splineWeights);
    }

    /* Free image fields */
    free(e->imageDefHandle);
    free(e->imageFilePath);
    if (e->imageClipVertexCount > 0 && e->imageClipVertices) {
      free(e->imageClipVertices);
    }
  }
  free(result->entities);
  free(result->entityMetadata);

  /* Free textStyles */
  for (int i = 0; i < result->textStyleCount; i++) {
    free(result->textStyles[i].name);
    free(result->textStyles[i].primaryFont);
    free(result->textStyles[i].bigFont);
  }
  free(result->textStyles);

  /* Free linetypes */
  for (int i = 0; i < result->linetypeCount; i++) {
    free(result->linetypes[i].name);
    free(result->linetypes[i].pattern);
  }
  free(result->linetypes);

  /* Free error message */
  free(result->errorMessage);

  /* Zero the struct */
  std::memset(result, 0, sizeof(DXFRW_Result));
}
