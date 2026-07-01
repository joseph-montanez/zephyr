# Zephyr

**A native, GPU-accelerated 2D CAD application — free, open source, and built from scratch in Swift.**

Zephyr is a drafting app that runs natively on macOS (Metal) and Windows (Direct3D 12). It reads DWG and DXF, exports PDF with Bluebeam-compatible measurements, and is designed to replace QCAD/LibreCAD as the go-to free alternative to AutoCAD LT. No subscriptions, no telemetry, no Qt/OpenGL legacy stack.

![Zephyr screenshot](docs/uploads/zephyr.png)

## Download

| Platform | Architecture | Download |
|---|---|---|
| macOS 11+ | ARM64 (Apple Silicon) | [Zephyr-macOS-arm64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-macOS-arm64.zip) |
| macOS 11+ | x64 (Intel) | [Zephyr-macOS-x64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-macOS-x64.zip) |
| Windows 10+ | ARM64 (Snapdragon / Surface) | [Zephyr-Windows-arm64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Windows-arm64.zip) |
| Windows 10+ | x64 | [Zephyr-Windows-x64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Windows-x64.zip) |

## Tech Stack

| Layer | Technology |
|---|---|
| **Language** | Swift (~47k LOC) |
| **GPU (macOS)** | Metal via SDL3 |
| **GPU (Windows)** | Direct3D 12 via SDL3 |
| **UI** | ImGui (SDL3 GPU backend) |
| **DXF I/O** | libdxfrw C++ bridge |
| **DWG I/O** | libreDWG C bridge (import/export) |
| **PDF Export** | PDFium (Windows/Linux) · PDFKit (macOS) |
| **PDF Import** | PDFium (Windows/Linux) · PDFKit (macOS) |
| **Compression** | zstd via zlib-ng |
| **Fonts** | SDL_ttf + custom SHX byte-code interpreter |
| **License** | GPL v3 — free to use, fork, and ship |

## Why Zephyr?

- **QCAD/LibreCAD replacement** — DXF parsing that actually works: MText formatting, SHX shape fonts, NURBS splines, dimension styles, and title blocks all render correctly. No raw escape codes leaking into labels, no scrambled curves, no missing logos.
- **AutoCAD LT alternative** — AutoCAD muscle memory preserved. `L`, `PL`, `C`, `REC`, `M`, `TR`, `J` all work. Command palette with fuzzy autocomplete, polar tracking, object snap tracking, grips, and a full snap engine.
- **GPU-native** — Metal on macOS, Direct3D 12 on Windows. Single Swift rendering pipeline. 120 FPS canvas with pixel-perfect GPU picking. No OpenGL emulation layer.
- **Free forever** — GPL v3. No account, no email gate, no subscription. ~14 MB download.

## Current Features

### File I/O
- **DWG import/export** — Full read/write via libreDWG. Blocks, layers, text styles, hatches, splines, polylines with bulge, dimensions. Native DWG round-trip.
- **DXF import/export** — R2007 round-trip. Dimensions, splines, hatches, leaders all preserved. Layer transparency (group code 440) supported.
- **PDF export** — Vector PDF 1.7 with Bluebeam Revu-compatible Measurement dictionary.
- **PDF import** — Cross-platform: PDFKit on macOS, PDFium on Windows. Page selector with preview. Raster underlay at 150 DPI.
- **EAB native format** — Fast binary save/load. zstd compression, BVH spatial index, viewport-culled partial loads.

### libdxf (DXFrw) Enhancements
Zephyr's DXF pipeline is built on a fork of [libdxfrw](https://github.com/LibreCAD/libdxfrw) (a C++ DXF reader/writer backed by iconv for charset conversion). Over 20,000 lines of new C++ were added to the library to fix crashes, close feature gaps, and surface data that AutoCAD and other CAD tools rely on:

| Enhancement | Description |
|---|---|
| **Layer transparency** | Reads DXF group code 440 (opacity 0–100%) and exposes per-layer transparency. Full round-trip support. |
| **Spline NURBS weights** | Parses rational NURBS weights (group 41) for each control point. Enables faithful rendering of weighted spline curves instead of flattening to uniform. |
| **Hatch gradient fills** | Decodes gradient fill sub-objects (codes 450–470) — linear, cylindrical, spherical, etc. Stores gradient name, angle, and two RGB colors per hatch. |
| **Attribute text & block attribute support** | Adds `ATTRIB` and `ATTDEF` entity types with tag, flag, and text value extraction. Block inserts now carry their full attribute payload. |
| **Background fill color** | Hatch background fill (ACI group 63) is surfaced independently from the hatch pattern color, matching AutoCAD's background fill mechanic. |
| **Encoding/codec improvements** | Strips malformed `$DWGCODEPAGE` headers that crash iconv, auto-detects and sanitizes MText embedded objects, and adds ICONV error recovery. Binary DXF sniffing with hex-dump diagnostics for bad input. |
| **vcpkg + CMake integration** | Cross-platform CMake build system with vcpkg-managed dependencies (iconv). Supports static and shared builds on Windows, macOS, and Linux via `find_package` fallback chains.

### Drawing Commands
| Command | Alias | Description |
|---|---|---|
| LINE | `L` | Line segments |
| POLYLINE | `PL` | Multi-vertex polylines with arc segments |
| CIRCLE | `C` | Center-radius circles |
| ARC | `A` | 3-point arcs |
| RECTANGLE | `REC` | Axis-aligned rectangles |
| ELLIPSE | `EL` | Ellipses and elliptical arcs |
| HATCH | `H` | Boundary hatches with pattern fill |
| SPLINE | `SPL` | NURBS splines |
| RAY | `R` | Infinite construction rays |
| TEXT | `T` | Multi-line text with font selection, height, rotation, alignment, column width |
| IMAGE | `IMG` | Raster image placement (PNG, JPG, etc.) |
| PDFIMPORT | `PDFI` | PDF page underlay import with page selector |

### Dimension Commands
| Command | Alias | Description |
|---|---|---|
| DIMLINEAR | `DLI` | Horizontal/vertical dimension between two points |
| DIMALIGNED | `DAL` | Dimension parallel to the measured distance |
| DIMANGULAR | `DAN` | Angle dimension between two lines or an arc |
| DIMARC | `DAR` | Arc length dimension along a curve |
| DIMRADIUS | `DRA` | Radius dimension for arcs/circles |
| DIMDIAMETER | `DDI` | Diameter dimension for arcs/circles |
| DIMORDINATE | `DOR` | X or Y ordinate dimension from a UCS origin |
| DIMJOGGED | `DJO` | Jogged radius dimension (for large radii) |

### Edit & Modify
| Command | Alias | Description |
|---|---|---|
| JOIN | `J` | Join collinear/contiguous entities — lines and arcs auto-convert to NURBS splines for joining |
| TRIM | `TR` | Trim to cutting edges |
| SPLINEEDIT | `SPE` | Edit splines: convert to polyline, close, reverse, insert knot, join |
| MATCHPROP | `MA` | Format painter — copy layer, color, weight, and linetype from source to destinations |
| DDEDIT | `ED` | Edit text and attributes in-place via text editor dialog |
| CLEANSPECKLES | `CS` | Sample-and-erase speckle artifacts from scanned drawings |
| MEASUREGEOM | `MEA` | Quick Measure — hover to raycast orthogonal distances |
| ERASE | `E` | Delete selected entities |
| COPY | `CO` | Duplicate selected entities in-place |
| BRINGTOFRONT | `BTF` | Move selected entities to front of draw order |
| SENDTOBACK | `STB` | Move selected entities to back of draw order |
| BRINGABOVEOBJECTS | `BAO` | Place selection above a picked reference entity |
| SENDUNDEROBJECTS | `SUO` | Place selection under a picked reference entity |
| TEXTTOFRONT | `TTF` | Bring all text, dimensions, and leaders to front |
| HATCHTOBACK | `HTB` | Send all hatches and solid fills to back |

### Clipboard (Copy/Paste)
| Command | Description |
|---|---|
| COPYCLIP | Copy selected entities to clipboard |
| COPYBASE | Copy selected entities with a specified base point |
| PASTECLIP | Paste clipboard entities at viewport center |
| PASTEORIG | Paste clipboard entities at original coordinates |
| PASTEBLOCK | Paste clipboard entities as a new block |

### Tool Modes
SELECT, MOVE, ROTATE, SCALE, PAN, ZOOM

### View Commands
| Command | Alias | Description |
|---|---|---|
| ZOOM | `Z` | AutoCAD-style ZOOM with sub-commands: All, Center, Dynamic, Extents, Left, Previous, Right, Scale, Object, Window, Realtime |
| ZOOMEXTENTS | `ZOOME` | Zoom to fit all entities |
| PAN | `P` | Click-and-drag pan (hand cursor mode) |
| -PAN | | Pan by displacement vector |
| DVIEW | `DV` | Dynamic view twist (rotate the 2D view angle) |
| PLAN | | Reset view rotation to standard orientation |
| VIEW | `VIEWS` | List, select, or cycle model and sheet views |
| SHEET | `LAYOUT` | Select or cycle imported DXF sheet layouts |
| MODEL | `2DVIEW` | Switch to the DXF 2D model-space view |
| NEXTVIEW | | Switch to next model or sheet view |
| PREVIOUSVIEW | | Switch to previous model or sheet view |

### Snap Engine
9 anchor types with two-tier filtering (AABB proximity → exact distance):
center, vertex, midpoint, insertion point, quadrant, nearest, perpendicular, tangent, intersection

### Tracking
- **Ortho mode (F8)** — Hard-constrain cursor to cardinal axes (0°/90°/180°/270°) from the reference point. Works with direct distance entry — type a number during MOVE to move precisely along the ortho axis.
- **Polar tracking** at configurable angle increments (`POLARANG`)
- **Object snap tracking (OTRACK)** from acquired points (500ms dwell)
- **Extension snapping** along existing geometry
- **Snap angle** (`SNAPANG`) sets crosshair and ortho rotation angle
- **Direct distance entry** — during MOVE/COPY, type a distance and press Enter to move exactly that far along the current direction. Works with ortho, polar, OTRACK, and extension snaps — the ghost preview and tracking line always follow the active snap direction.
- Toggle via `POLAR`, `OTRACK`, `EXTENSION`, `ORTHO` commands or `F8` (ortho)

### Grips
Per-vertex grips on polylines and polygons. Corner, center, midpoint, and rotation grips on selection bounding boxes. Configurable limits: `SETTINGSGRIPOBJECTMAX` (entity count threshold, default 100) and `SETTINGSGRIPMAX` (total grip squares drawn, default 1000).

### Blocks
- **Block edit in-place** (`BEDIT` / `BE`) — enter block editor with green banner and titlebar indicator. Save/Discard/Cancel dialog on close.
- **BCLOSE** — close block editor with save confirmation prompt.
- **BLOCKS panel** — block library with preview.
- **SIMPLIFY** — swaps heavy blocks for bounding-box stand-ins during pan/zoom.
- **MAKE BLOCK** — `BLOCK` / `BMAKE` to create a new block from selected entities.

### Layers
- Full layer table with ACI color indexing.
- Per-layer line type, weight, and **opacity** (DXF group code 440, 0–100%).
- Layer opacity slider in the layer panel.
- Layer management commands: `LAYER NEW`, `LAYER DELETE`, `LAYER RENAME`.
- Layer move command (`LAYERMOVE` / `LM`) — modal dialog with filterable layer list.

### Constraints (15 types)
Coincident, parallel, perpendicular, tangent, concentric, horizontal, vertical, equal, distance, angle, fix, midpoint, collinear, symmetric, offset. Numeric solver with cached transforms.

### SHX Shape Font Interpreter
Full byte-code interpreter for AutoCAD `.shx` shape fonts. Text renders as pure vectors at any zoom — no bitmap degradation.

### MText Parser
Full interpreter for DXF formatting codes — `%%u` (underline), `%%o` (overline), `%%d` (degree), `%%c` (diameter), `\P` (paragraph break), font/color/width stack changes. Attachment point, column width, and line spacing factor all honored.

### NURBS / Spline Evaluator
Adaptive subdivision keyed to screen pixels. Curves stay smooth at any zoom, bounded arcs stay bounded.

### UI
- **Command palette** — Press Space, type, Tab-cycle through fuzzy-matched autocomplete. 100+ registered commands with descriptions and syntax hints.
- **Multi-drawing tabs** — Open multiple files, dirty-state tracking, unsaved-changes confirmation. Tab management commands: `NEW`, `CLOSE`, `CLOSEALL`, `CLOSEALLOTHERS`.
- **Draw palette** — Visual tool picker with categorized commands.
- **Layer panel** — Visibility toggles, color swatches, opacity sliders, entity counts.
- **Properties panel** — Per-entity property editing with geometry inspector.
- **Block panel** — Block library with preview and insert.
- **Radial navigation** — Right-click radial menu for pan, zoom, fit (`NAV` to toggle).
- **Text editor** — Modal dialog for text creation/editing with font selection, height, rotation, alignment, and MTEXT width.
- **Toolbar** — Quick-access buttons for open, save, save-as, import-PDF, tool modes, AA toggle, nav toggle, edit block, view rotation slider with reset, and dark/light theme toggle. Collapsible to mini-toolbar.
- **Status bar** — Coordinates, snap mode indicators, entity count, undo/redo depth.

### Rendering Engine
- **Metal** (macOS) and **Direct3D 12** (Windows) via SDL3 GPU API
- **Multi-sample anti-aliasing** (MSAA)
- **GPU-based entity picking** — 9×9 pixel-perfect ID rendering
- **BVH spatial index** — Accelerated hit testing and viewport culling

### Display & Theme
- **Dark/Light theme** toggle (`THEME` command or toolbar button).
- **Background color** — settable via `SET-BACKGROUND <hex|ACI>`.
- **Display palette generation counter** ensures line colors update immediately on background/theme change without requiring a zoom.
- **Anti-aliased line rendering** toggle (`AALINES`/`AA`).
- **FPS counter** (`FPS` toggle, shown in titlebar).

### Grid
- Configurable grid with `GRID`, `GRID SPACING <value>`, `GRID ORIGIN <x> <y>`, `GRID SNAP` commands.

### Document Settings

| Command | Alias | Description |
|---|---|---|
| UNITS | `UNIT`, `DDUNITS` | Set or display the drawing base unit (mm, cm, m, in, ft, yd). Flows through to PDF `/Measure` dictionary for Bluebeam Revu, DXF `$INSUNITS`, and EAB file header. |
| SETUISCALE | `ZOOMUI`, `UISCALE` | Override UI zoom scale (e.g. `SETUISCALE 1.5` for 150%). `SETUISCALE AUTO` reverts to system DPI. Scales all UI elements including fonts. |

## Nightly Builds

Same links as above — all four platform/architecture combinations updated on every push.

| Platform | Architecture | Download |
|---|---|---|
| macOS | ARM64 | [Zephyr-macOS-arm64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-macOS-arm64.zip) |
| macOS | x64 | [Zephyr-macOS-x64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-macOS-x64.zip) |
| Windows | ARM64 | [Zephyr-Windows-arm64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Windows-arm64.zip) |
| Windows | x64 | [Zephyr-Windows-x64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Windows-x64.zip) |

## Quick Start

```bash
# macOS
cd Engine/EngineAsBuilt
sh compile-macos.sh

# Windows (ARM64, via Visual Studio Native Tools)
cd Engine\EngineAsBuilt
.\compile.ps1
```

---

[Development Setup](DEVELOPMENT.md) · [Issues](https://github.com/joseph-montanez/as-built/issues)
