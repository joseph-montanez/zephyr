# Changelog

Monthly digest condensed from the git history. Instead of per-release notes, all changes are grouped by calendar month and summarized under **New Features** (brand-new capabilities), **New Commands** (new drawing/modify commands on existing features), **Improvements** (refinements to existing features), **DXF & File Formats**, **Bug Fixes**, **Maintenance** (toolchain, packaging, CI, housekeeping), and **Performance**. Fixes and refinements made to a feature during the same month it ships are folded into that feature's entry rather than listed again.

## October 2026

### New Features
- **AutoLISP support** — native engine (FDScript merge), 305/305 dispatch, file picker, persistent session, `c:` command dispatch, and examples; scripted CAD commands with multi-call support; app-wide system variables that survive LOAD/EVAL and wire `GRID`/`ORTHO`/`POLAR` to `GRIDMODE`/`ORTHOMODE`/`POLARMODE`
- **Ribbon** — AutoLISP-defined command chrome in a dockable window: tabs/panels/items, procedural icons, working flyouts, live enable/check state from system variables, classic `File/Edit/View` menu bar, labels-only and icons+labels presentations with the dock node resizing to the active presentation, and hot reload of `lisp/ribbon.lsp` (`RIBBON`, `RIBBONMODE`, `RIBBONRELOAD`); the definition ships as an editable per-user file that reloads on save and survives a failed parse, and no longer gets re-seeded over your edits
- **Multi-window editing** — float/dock OS windows and independent model views, with per-window status bars and window-local selection and gestures
- **Split view workspace** — visible always-on gutters with hairline borders and 3-dot grip handles, resize mouse cursors (`ResizeEW` / `ResizeNS`), smooth divider dragging with grab-offset compensation, double-click a divider to reset to 50/50, and per-pane identity badges showing `<tab> · <view>` (faded on hover so CAD picking is never obstructed)
- **Linux support**
- **Unclamped TrueColor rendering** — `AUTOCONTRAST` disables the viewport's contrast clamping for 24-bit TrueColors and gradients, so vector artwork and other non-CAD drawings show the colors you actually picked instead of adjusted ones (standard ACI 1–255 colors stay clamped); persisted per document

### New Commands
- **INSERT** — insert a block or drawing file as a block reference
- **XATTACH / XREF** — attach a drawing as an external reference and manage references from the External References palette
- **ATTACH, IMAGEATTACH, PDFATTACH** — attach a drawing, raster image, or PDF page as a live reference
- **OFFSET** (`O`) — make a parallel copy of one object at a distance or through a point: Through, Erase, Layer and Multiple options, a live preview once the object is picked, Undo/Exit without leaving the command, and `OFFSETGAPTYPE` corner style for polylines
- **UNDO / REDO** — registered, with ribbon buttons
- **VPEQUAL** (`EQUALIZE`) — resize all split panes to equal sizes across nested layouts
- **VPRESIZE** — grow (`+`) or shrink (`-`) the focused pane by a percentage of its parent split
- **REDRAW** (`R`) / **REGEN** — viewport refresh and full database regeneration from the command line
- **AREA** (`AA`) — opens the measure tool directly in area mode (full `AREA` with Object/Add/Subtract tallies follows in Phase 1)
- **GRADIENT** (`GD`) — gradient-fill entry into the hatch command
- **DRAWORDER** (`DR`) — Above/Under/Front/Back umbrella over the existing draw-order commands, with reference-pick handoff for Above/Under
- **HATCHEDIT** (`HE`) — edit the selected hatch in place, picking up its pattern, scale, and angle
- **-HATCH** — command-line hatch (`-HATCH [pattern] [scale] [angle]`) with pattern validation against the known catalog
- **-TEXT** — prompt-driven single-line text (height, rotation, style, insertion, value) without the modal dialog; writes identical entity data to `TEXT`
- **-LAYER** (`-LA`) — Make/Set/New/On/Off/Color/Ltype/LWeight from the command line (lock/freeze verbs report as pending Phase 1C instead of failing silently)
- **CHPROP / CHANGE** — interactive property editing (Color/LAyer/LType/LTScale/LWeight) with single-undo application and scripted-compatible entity data
- **OSNAP** (F3) — master running-osnap switch that skips entity snaps while leaving grid snap independent; `OSMODE` keeps selecting which modes run
- **COMMANDLINE** (`CLI`, Ctrl+9) — show/hide the command line
- **CLEANSCREENON / CLEANSCREENOFF** (Ctrl+0) — hide all chrome with save/restore
- **TOOLBAR** (`TO`) — ribbon visibility toggle
- **Tier-1 draw parity** — `XLINE` (`XL`), `POINT` (`PO`), `DONUT` (`DO`), `POLYGON` (`POL`), `BOUNDARY` (`BO`/`-BO`) with closed-polyline output, and native `XLine2d` ray handling
- **Dimensioning suite** — `DIMSTYLE` table with manager UI and `-DIMSTYLE`, chaining `DCO`/`DBA` (continue/baseline), smart dispatching `DIM`, `CENTERMARK`/`DIMCENTER`/`CENTERLINE`, re-pointing `DIMREASSOCIATE`, text/geometry `DIMEDIT`/`DIMTEDIT`, and `DIMBREAK`/`DIMSPACE`
- **Text tools** — `FIND` search/replace, `TEXTALIGN` baseline alignment, `TXT2MTXT` merge, and `FIELD` codes with evaluation hooks
- **Selection tools** — `SELECTSIMILAR` with `SELECTSIMILARMODE`, `QSELECT`/`FILTER` predicate engine, `GROUP`/`UNGROUP` with `PICKSTYLE`, and `ISOLATE`/`HIDE`/`UNISOLATE`
- **Drawing management** — reachability-sweep `PURGE`/`-PURGE`, validating `AUDIT`/`RECOVER`, plus `OOPS`, `REVERSE`, and `RENAME`
- **Blocks and references** — `WBLOCK`/`-WBLOCK` with `BASE`/`INSBASE` round-trip, `ATTDEF`/`ATTEDIT` (`ATE`)/`ATTSYNC`, `REFEDIT`/`REFCLOSE` with `NCOPY` and `XBIND`, and `IMAGEADJUST`/`PDFADJUST`
- **Multilines and aliases** — `MLINE` (`ML`) baked from centerlines, `MLSTYLE` manager with live `CMLJUST`/`CMLSCALE`/`CMLSTYLE`, and `ALIASEDIT` over a `zephyr.pgp` file whose user aliases win over built-ins
- **Parametric constraints** — line-solver-backed `GEOMCONSTRAINT` (`GCON`) for Fix/Horizontal/Vertical/Coincident/Parallel/Perpendicular/Equal, `AUTOCONSTRAIN` inference, `DELCONSTRAINT`, badge-overlay `CONSTRAINTBAR` (`CBAR`), and a Parametric ribbon tab (`DIMCONSTRAINT`/`PARAMETERS` stay unregistered until a dimensional solver lands)

### Improvements
- **AutoCAD LT alias alignment (breaking)** — Zephyr-only aliases that shadowed LT meanings now resolve to LT: `AA`→`AREA`, `DT`→`TEXT`, `R`→`REDRAW`, and `S`/`D`/`PS`/`CL` are reserved for `STRETCH`/`DIMSTYLE`/`PSPACE`/`CENTERLINE` (honest not-implemented-yet feedback until those phases land); canonical spellings flipped to `PLINE`, `RECTANG`, `SPLINEDIT`, `PROPERTIES`, `EXPORTPDF`, `TEXTEDIT`, `MTEXT`, `LAYOUT`, with the old spellings kept as aliases; displaced commands keep `RO`, `SC`, `TB`, `TOOLS`, `PSTROKE`, `TOR`. Full command names (`AALINES`, `TABLE`, `RAY`, `SCALE`, `DRAW`, `PENSTROKE`, `CLIP`, `TORIENT`) are unaffected, as are ribbon buttons and AutoLISP scripts using full names. Enforced by a new `CommandAliasParityTests` golden table so the four dispatch surfaces cannot drift apart again
- **Function and Ctrl shortcuts** — `F3` OSNAP, `F7` grid, `F8` ortho (now with sysvar sync), `F9` snap (now syncs `SNAPMODE`), `F10` polar, `F11` OTRACK, plus `Ctrl+F/G/L/B` alternates, `Ctrl+1` properties, and bare `Ctrl+P` routing to PDF export until the plot dialog lands
- **Verb/Noun modify workflow** — `MOVE`, `ROTATE`, `SCALE`, `COPY`, `ERASE`, `COPYCLIP`, and `COPYBASE` now accept a selection made *after* the command is invoked ("Select objects..."), with click, window/crossing rectangle selection and Enter/Space/Right-click confirmation; command prompt banners render for active modify commands
- **TRIM** — AutoCAD-style options: cutting-edge selection, box and fence batch trimming, eRase sub-mode, and in-session undo
- **Tab management** — tab reorder, split panes, and tabs that follow the window they belong to
- **Keyboard pane navigation** — `Ctrl+Alt+Arrow` (`Cmd+Alt+Arrow` on macOS) nudges the focused pane's divider in that direction
- **Gradient hatches** — via `-HATCH`, `GF*` system variables and `entmake`; island detection in the Hatch UI
- **Escape/Enter/Space** — one Escape cascade that cancels editors, gestures, commands, snaps and selection a layer at a time, with grip and drag cancelled back to their pre-drag snapshot; Space now commits like Enter while preserving custom Space handling in TRIM and EXPLODE; idle Enter repeats the last command
- **Properties panel** — multi-select entity picker, copy support, and an empty state
- **Layer property sorting**
- **Themes** — Catppuccin palettes, dropdown/slider contrast, and full theming for the Hatch and PenStroke UI
- **PDF export** — DXF paper space layouts (paper size, units, and rotation from `AcDbPlotSettings`), export of the active drawing view, point sizing scaled inversely to prevent giant blocks, contrast adjustment for white strokes on light backgrounds, and `PDFEXPORT` filename normalization
- **PGP user aliases** — `zephyr.pgp` (`ALIAS, *COMMAND`) loads at startup with user entries overriding colliding built-ins (with warnings), editable live via `ALIASEDIT`
- **ARRAYPATH base point** — path arrays stop after the path pick for a base-point step: snap a point on the source object, type `B`, or press Enter to keep the object center

### DXF & File Formats
- **MLINE support** — plus DXF entity handles preserved in xdata
- **MLINESTYLE objects** — multiline styles round-trip through DXF (`MLINESTYLE` table + rebuilt `MLINE` entities) and a new EAB section carries named multiline styles
- **References on the wire** — INSERT/xref and ATTACH payload handling, with `REFPATHTYPE` 0/2 mapping
- **Gradient hatch write-back** — `GF*` system variables and `entmake` support

### Bug Fixes
- **DXF ellipse arcs** — elliptical arcs with near-zero parameter spans are no longer promoted to full ellipses; only an exact `0...2pi` span is treated as a full ellipse, so tiny projection-export ticks no longer render as large stray circles
- **Sheet ghost-double** — a layout whose only viewport is the overall paper-space viewport (ID 1) no longer projects model space on top of its paper geometry; the synthetic model-fit fallback now applies only to effectively-empty sheets (no visible vector paper content), so legacy layouts with just an invisible insert or missing raster still show the drawing instead of rendering blank
- **Missing rasters** — unresolved IMAGE/UNDERLAY references render nothing (no more X placeholder frame) and are excluded from zoom extents; repair the path via the External References palette
- **`HSPLIT` / `VPORTS 2H`** — after `VSPLIT`, fixed variable shadowing in `PaneLayout.split` recursion where child splits inherited their parent's axis instead of the requested one
- **Snapping in modify commands** — base point selection during `MOVE` and friends now honors active entity snap targets (circle quadrants/center, line endpoints, midpoints) instead of falling back to raw mouse coordinates
- **SHX shape fonts** — fractional arcs, clockwise octant arcs, multi-stroke outline behavior, and hole nudging
- **Explode** — rectangles and compound entities split into separate elements
- **Gradient hatches** — angled gradient projection
- **`CADDocument` concurrency** — crash prevention on concurrent access
- **Hatch editing** — undo/redo history registration
- **Floating windows** — input dead zones, pane divider drag, click-to-raise, and white flash on view swap
- **LINE / Polyline** — Enter-to-finish; command bar and autocomplete always render on top
- **ODA setup** — download 404 and teardown hardening; first-run setup popup
- **Windows builds** — missing DLLs, crash when engine init fails, and `igInputText` String-pointer warnings
- **Per-window state** — ImGui contexts, window-local main tab and selection gestures, long EAB strings, and a quieter initial load
- **Frame tearing** — reused ImGui transfer buffers are now mapped with `cycle=true`; mapping with `cycle=false` let a new frame overwrite upload data the GPU was still reading, which tore the interface every couple of frames
- **EAB constraint codec** — sub-entity/index fields now read in writer order, so coincident endpoint indexes survive a save/load round trip

### Maintenance
- **Swift 6.4 migration** — toolchain bump and `zlib-ng` fix
- **Dependencies** — SDL3 3.4.18 and SDL3_image 3.4.8
- **macOS bundles** — Universal binary and bundled Swift runtime
- **Linux packaging** — Snap, AppImage and Flatpak (x64 and ARM64); DXC pinned to v1.8.2407 for glibc 2.35 compatibility
- **CI** — build fixes across Windows, macOS and Linux; Linux CI on every push
- **`test.ps1`** — test-runner wrapper that sets the SDL3/zlib-ng build environment, detects host arch and Visual Studio, pre-builds the test bundle, and propagates exit codes
- **Website and docs** — Linux support, AutoLISP, OFFSET, corrected downloads, roadmap

### Performance
- **DXF import** — 2.2× faster: per-entity string format hoisting, byte-scanning of group pairs, skipping code-page conversion
- **NURBS** — single scratch buffer per evaluation instead of three arrays
- **EAB/SHX** — one byte helper with safe loads, gated by golden digests
- **Swift 6.4 branch** — performance harness and baseline
- **Large-selection cursor lag** — the Properties panel picker rebuilt, relabeled, and re-sorted the whole selection every frame (plus a console print per frame); it is now cached and rebuilt only when the selection or document changes, with no per-frame allocation in the comparator. Also cached: rect-select preview queries (per frame → per changed rect), renderable world bounds, and layer lookups; hover hit-tests are throttled (8 ms) with grip early-outs, live-drag transforms skip full storage prep, and the vertex rebuild no longer launches mid-rect-drag
- **ImGui uploads** — transfer buffers are reused across frames instead of created/released per frame (amortized growth with headroom)
- **Bulk-move path-array refresh** — moving N objects rescanned the whole registry N times to refresh path arrays; the scan now runs once over the union of moved handles, ~92x fewer scans (measured 19.3s to 0.21s moving 150 objects in a 336k-entity file)

## September 2026

No commits.

## August 2026

11 commits · 2026-08-02 – 2026-08-12

### Features
- PEN command: freehand drawing, pen erase, and pen splines
- Pen strokes exported to DXF as solid hatches
- REVCLOUD support
- Hatch pattern parsing from `.pat` files
- CLIP command (work in progress)
- DXF writer: hatch export and table support

### Bug Fixes
- Rotated panning in NAV
- DXF hatch export fixes

## July 2026

117 commits · 2026-07-01 – 2026-07-28

### Features
- Native DXF export: writer with layout/output handling, round-trip payload support, and SORTENTSTABLE parsing
- `libdxfrw` replaced with a native Swift DXF reader (iconv removed); Windows code-page encoding/decoding
- Hatch and data tables go native: hatchPath geometry, mirrored hatch handling, data-table import rework and interaction
- Text overhaul: text styles, shape-font parser, encoding, indentation/tab stops, and per-entity style overrides
- ATTDEF and attribute handling improvements
- Leader commands: classic leaders, arrow/block leaders, legacy overrides, PDMODE
- New commands: ARRAY, ALIGN, TORIENT, LENGTHEN, MEASURE/DIVIDE, FILLET, CHAMFER
- DWG converter command and ODA install command
- Native open/save dialogs and drag-and-drop file open
- Ortho axis alignment honors SNAPANG
- User settings and language selection; view background color followed for line/fill colors
- Region support; renderer refresh on open/view switch
- macOS 11 support; SDL/Swift version bumps

### Bug Fixes
- DXF write fixes: arcs, hatches, version on save, layer opacity, linetypes, ellipse hatches
- DXF import fixes: sheets support, parentHandle overwrite, insert transforms, 32-bit floating point precision loss
- Hatch/gradient not persisting on save; scale and rotation not preserved
- Windows release build and compile.ps1 fixes; macOS hotkey vs Windows keymapping
- Crash on minimize; GPU desync crash prevention; memory fixes
- Zoom extents; spline trim at touching line cutters; retraced polyline linetype rendering
- Point/vertex dot rendering too large; anti-aliased line thickness; line width handling at zoom
- Hatch rendering around dimensional text; hatch/dimension orientation
- Window focus issue; libdwg linking; macOS build actions in CI

### Performance
- Reduced texture atlas memory
- Big-O/allocation optimizations in hot paths

## June 2026 — project launch

60 commits · 2026-06-23 – 2026-06-30

### Features
- Initial release: project renamed, GPLv3 license, README with macOS/Windows build downloads
- DWG import/export via LibreDWG, plus a UI scale override
- Initial dimension support (linear, radial, diameter) with presentation and editing
- Complete hatch creation/editing workflow: UI, background fills, gradients, hole detection and preservation, scaling
- NURBS/spline work: knot insertion, 3-degree splines, tessellation quality, and JOIN converting lines & arcs to cubic splines
- Bulge-aware LWPOLYLINE support
- AutoCAD-style direct numeric entry for all drawing commands
- Ortho mode and move-with-distance
- Text alignment/justification and block attributes; block UI improvements
- New commands: UNITS, MATCHPROP, grip-object/grip-max settings
- Improved file browser UI; Windows font registry lookup for font resolution

### Bug Fixes
- Save crash on Windows; macOS x64 build, compile, and startup fixes
- EAB file corruption, ImGui clipper crashes, drag undo, and focus handling
- Line thickness, plot style, and solid fill rendering fixes
- Dashed-line vertex move preview
- Spline trimming inside closed curves
- Copy/paste/drag issues
- Cross-platform `strdup` replacement; LibreDWG CMake wrapped in vcvars context for Windows `cl.exe`

### Performance
- Non-blocking save with progress bar, plus autosave
- ImGui max vertex count raised to 4 billion for very large documents
