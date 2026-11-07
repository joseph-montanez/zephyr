# Changelog

Monthly digest condensed from the git history. Instead of per-release notes, all changes are grouped by calendar month and summarized under **New Features** (brand-new capabilities), **New Commands** (new drawing/modify commands on existing features), **Improvements** (refinements to existing features), **DXF & File Formats**, **Bug Fixes**, **Maintenance** (toolchain, packaging, CI, housekeeping), and **Performance**. Fixes and refinements made to a feature during the same month it ships are folded into that feature's entry rather than listed again.

## November 2026

### New Features
- **Blocks palette (`BLOCKSPALETTE`)** — tabbed Current / Recent / Favorites / Libraries panel with vector thumbnails, search, pinning, and Explode / Repeat / Prompt-attributes insertion options; Libraries browse folders of `.dxf` / `.dwg` / `.eab` files and per-block container contents with background parsing, and Recent / Favorites, library folders, and insertion defaults persist across restarts; `INSERT` accepts typed `x,y[,z]` points, previews the true-size ghost at the cursor, clones container blocks at commit (single undo, Esc leaves no residue), prompts for attributes when `ATTREQ=1`, and ships `BLOCKSPALETTECLOSE` plus the `BLOCKSLIBRARYPATH` sysvar; block definitions import (0,0)-based so non-zero `BLOCK` base points place correctly by name
- **Model-space plotting** — `PLOT`, `PAGESETUP`, `-PLOT`, `-PAGESETUP`, and `PREVIEW` now work from Model as well as layouts, with named setups strictly scoped to Model or Layout for creation, listing, application, rename/delete binding, plotting, and bulk publish assignment; also adds the AutoCAD PDF High Quality Print device
- **Batch publishing (`PUBLISH`)** — new sheet-list dialog with multi-select, Model/Layout bulk filtering, cross-drawing Master setup assignment, `Import...`, Add/Remove/Move/Preview, Save/Load sheet list, multi-sheet and single-sheet PDF output, per-sheet errors, cancellation cleanup, and publishing from live unsaved drawings using throwaway copies; DWG rows require the installed ODA converter, sheet lists use an internal tolerant `.dsd` subset with CSV logs, and a split page-renderer/document-assembler supports mixed-size multi-sheet PDFs
- **Save As DWG** — the Save and Save As dialogs now offer a DWG Drawing format: the drawing is exported to DXF internally and converted through the ODA FileConverter, so picking the DWG filter (or typing a `.dwg` name) produces a real DWG and the tab stays associated with it for later saves; the DWG version follows the tab's DXF export version (`DXFVERSION`, default AutoCAD 2018), and saving without the converter installed points at the `INSTALLODA` install step
- **Sheet sets** — organize drawings into a sheet set (`.dst`) with `NEWSHEETSET` and `OPENSHEETSET`, manage it from the Sheet Set Manager palette (`SHEETSET`), and drop model views onto sheets with `PLACEVIEW`, which shows a live ghost preview before you commit. `-PUBLISHSET` publishes straight from a sheet set
- **Callouts and transmit** — tag sheets with `PLACECALLOUT`, and package a whole sheet set for sharing with `-TRANSMITSET`, which gathers the set file plus its drawings into one archive folder

### New Commands
- **PUBLISH / +PUBLISH / -PUBLISH** — publish dialog workflow, preload the dialog from a sheet list, and foreground command-line publishing with a CSV log beside the `.dsd` file
- **-EXPORTPDF** — headless command-line export of the current layout to PDF with the persisted options (no popup, no save window); an explicit path wins, otherwise `<drawing>.pdf` beside the drawing, and unsaved drawings without a path report usage instead of failing silently
- **Layer command parity** — `LAYFRZ`/`LAYTHW`, `LAYLCK`/`LAYULK`, `LAYDEL`, `LAYMRG`, `LAYWALK`, `COPYTOLAYER`, `VPLAYER`, `LAYERSTATE`/`-LAYERSTATE`, and `LAYERP`, plus expanded `-LAYER` grammar for lock/freeze, transparency, description, reconcile, state, and viewport freeze/thaw; scripted `(command ...)` supports `-LAYER`, `LAYERSTATE`, and `LAYERP`
- **UCS / PLAN (model view rotation, AutoCAD parity)** — type `UCS` for World/3point/View/Z/Origin/Prev frame control with bare-Enter defaults, then `PLAN` (Current/Ucs/World) to align the view to the frame and zoom to extents; `UCS Z 45` rotates counter-clockwise exactly like AutoCAD LT (the typed visual rotation is mapped into the engine's Y-down world); bare `UCS`/`PLAN` + Enter now opens the interactive option prompt instead of waiting for same-line parameters, so `UCS` → Enter → `Z` → Enter → `45` → Enter works as in LT (typed one-line `UCS Z 45` is retired under Space == Enter; pasted/programmatic multi-token input replays stepwise through the same prompts); a per-frame reconcile plus command-start release drops stray SDL relative-mouse capture so the cursor can no longer stay parked at the window center after radial-nav drags, with 27 focused command tests and 13 capture-policy tests backing the 26-test planar kernel suite
- **MIRROR (`MI`)** — mirror selected objects across a two-point mirror line with a live mirrored ghost: pickfirst or pick/box selection, snapped or typed mirror-line points, then `Erase source objects? [Yes/No] <N>` (No keeps the sources and reflects copies) with one undo entry and the result left selected; locked-layer objects are refused and viewport-projected copies skipped with counts; `MIRRTEXT` is honored and now defaults to `0`, so text and attributes stay readable while their insertion points mirror (text inside block definitions mirrors fully, like AutoCAD), and a nonzero value mirrors them truly
- **STRETCH (`S`)** — the reserved `S` alias is now the real command: capture a crossing window (`C`, or a right-to-left drag) or crossing polygon (`CP`) and defining points inside move while the rest hold, so partially enclosed geometry stretches and wholly enclosed or individually picked objects move whole (`R` removes from the set); base/second points with a live stretched-geometry ghost, direct-distance, `@x,y`, and `dist<angle` entry, plus a `Displacement` branch whose last displacement is remembered for the session; zero displacement exits with no undo and one undo entry covers the whole set
- **BREAK (`BR`) / BREAKATPOINT** — `BREAK` erases the span between two points on one object (the pick point is the first break point, projected onto the object; `F` re-prompts for an explicit first point) and exits single-shot, while `BREAKATPOINT` splits an object at one point with no gap and repeats until Enter; each applied break pushes exactly one undo entry and degenerate or rejected picks push nothing
- **EXTEND (`EX`)** — extend open objects to boundary edges along their natural path from the end nearest the pick: Standard mode picks boundaries with the same pick/box/`<select all>` loop as `TRIM` (with pre-selection adopted), Quick mode treats everything visible as a boundary, and the extend prompt adds Fence, Crossing, Cutting edges, Mode, Project, Edge, and in-session Undo, with Shift-select trimming through the same boundary set; boundaries exclude the target's own edges and are rebuilt after every extension (see the shared TRIM/EXTEND modes under Improvements); the four commands above ship on the Modify ribbon panel (and the fallback More menu), through scripted AutoLISP `(command ...)` — including `STRETCH` `_C`/`_CP` and the `BREAK` `_F`, point-pick, and entsel forms — with 107 new command and round-trip tests plus alias-parity coverage

### Improvements
- **Space == Enter command input (AutoCAD parity)** — Space now submits exactly like Enter: every prompt takes one token per keypress, so `UCS Z 45` and `THEME light` can no longer be typed as one line — the sequences `UCS`␣`Z`␣`45`␣ and `THEME`␣`light`␣ work prompt by prompt instead. Bare one-shot commands (`-LAYER`, `LAYERSTATE`, `-DIMSTYLE`, `VPLAYER`, `MVIEW`, `SCALELISTEDIT`, `UNDO`, `THEME`, `LAYERSORT`, `LAYMRG`, sheet-set verbs, …) open prompted sub-sessions with verb-then-operand phases; pasted text, ribbon macros, and programmatic callers replay token-by-token through the same single-submit path. Prompts whose values may contain blanks (layer/block names, paths, text strings, `getstring T`) keep Space literal and submit on Enter only. Spaced command names are retired (`GRIDSNAP`/`GRIDSPACING`/`GRIDORIGIN`; `-LAYER` verbs replace `LAYER NEW/DELETE/RENAME`); repeat-last stores the command name only and re-enters at the first prompt
- **THEME sub-command** — bare `THEME` opens `Enter theme [Dark/Light/Latte/Frappe/Macchiato/Mocha/Next/?] <current>:` with exact, unique-prefix, `NEXT`, and `?` handling; ambiguous/unknown names re-prompt and bare Enter keeps the current theme. `DARKMODE`/`LIGHTMODE` stay direct single-token commands
- **Feature options palette** — Enter on an empty buffer with a highlighted option submits it (arrows + Enter picks without typing; typed text still wins so numbers and custom strings are never clobbered). Mouse-hovered and selected rows now use the theme's tinted `commandRowHighlight` with gold text instead of the raw ImGui header color, which was unreadable in dark themes
- **PDF export font handling (AutoCAD parity)** — `EXPORTPDF` now opens a standalone options popup (never inside the file-export window) before the system save window: `Capture fonts used in the drawing` embeds TTF subsets as live searchable text measured with real font advances, `Convert all text to geometry` explodes glyphs to vector outlines (overrides Capture and greys it out), and SHX renders as stroke geometry with invisible searchable text (`EPDFSHX` equivalent); options persist across sessions and are shared with `PLOT`, export leaves the tab's file association, display name, and saved revision untouched, and bare `Ctrl+P` now routes to `PLOT`; title-block fidelity fixes driven by the SS-11 sheet: extension-less SHX styles (`romand`/`simplex`/…) no longer resolve to Arial substitutes, PDF line wraps match the canvas via the screen's ~2% wrap tolerance, `\H` run scaling carries through TTF layout, emission, and screen sprites, and shared-face catalog entries union their glyph sets so every emitted CID keeps its `ToUnicode` mapping (a missing apostrophe mapping extracted as a newline)
- **PDF table text sizing** — cell text tessellated under a scaled table transform now carries world-sized heights and widths instead of local ones, fixing undersized text on scaled title-block tables (e.g. 3.18-high text in 5.0-high rows under a 4.69x insert)
- **PDF Extents framing** — layouts that plot Extents (e.g. centered 1:1 sheets) no longer export shifted a full sheet height off the page: the Y offset now composes against the area bottom, matching the engine's Y-down content against the Y-up printable rect (Window/Limits composition unchanged)
- **PDF plot-style text ink (AutoCAD parity)** — CTB/STB plot styles now map every text path in plotted PDFs, not just standalone `TEXT`/`MTEXT`: dimension text, datatable cell text, and other block-nested text resolve through the same pen as geometry, so `monochrome.ctb` plots them black; object-color tables preserve the display color (white stays visible) and grayscale/screening follow the pen; the vector strokes and fills around that text (dimension/extension lines, arrows, table grid) follow the pen as well, while raster images and gradients keep their authored colors
- **Planar UCS kernel foundation (Phase 1)** — new `ZephyrKernel` UCS math with canonical planar origin/angle transforms, ANGBASE/ANGDIR-neutral internal geometry plus injected orientation/delta boundary converters, absolute/relative/polar point parsing, and 26 focused kernel tests; no command, display, or persistence wiring yet
- **Ribbon fallback pattern icon** — fallback Draw panel now lists `HATCH` followed by `PATTERN`, and the `pattern` icon is registered with the known-icon set and painter coverage
- **TRIM/EXTEND shared modes (AutoCAD parity)** — `TRIM` and the new `EXTEND` now share `TRIMEXTENDMODE` (`1` = Quick, all visible objects act as edges, now the default like current AutoCAD; `0` = Standard cutting/boundary-edge selection) through a single backing store read by both commands and by `getvar`/`setvar`, plus `Project` (`PROJMODE`: None/UCS/View, default UCS) and `Edge` (`EDGEMODE`: No extend intersects boundaries as built, Extend lets them extend naturally) options on both prompts; Shift-select in `TRIM` extends and Shift-select in `EXTEND` trims through the same edge set and solvers; starting `TRIM` with nothing selected goes straight to click-to-trim, an empty-space press-drag trims/extends everything the freehand path crosses on release, a plain empty click arms a two-point fence, `C` forces a crossing box (new in `TRIM`), a picked object that cannot be trimmed is deleted in Quick mode instead of left unchanged, `PICKFIRST` is honored by both commands (pre-selected objects become the only edges when on), `TRIM`'s Mode option is an explicit [Quick/Standard] prompt, and `TRIMEXTENDMODE` and `PICKFIRST` persist across restarts; the new sysvars (`TRIMEXTENDMODE`, `PROJMODE`, `EDGEMODE`) validate their ranges in `setvar`, as does `MIRRTEXT`
- **Screen-space curve tessellation with curve-only zoom LOD** — arcs, circles, ellipses, bulged polylines, and splines now tessellate from a screen-space tolerance (`0.25 px / zoom`) over 2x zoom bands with hysteresis instead of a fixed world-space chord, so zooming in refines curves instead of exposing facets; straight lines, hatches, and text stay on a static path while a zoom-band crossing re-tessellates only curve-bearing entities in place (background compute, draw order and z preserved), with per-curve caps from a shared segment budget and frustum culling that drops off-screen spans to a coarse tolerance
- **Shifted-frame spline intersection polish** — the kernel refines spline crossings with a bounding-box-center origin, knot-span-clamped damped Newton at tangencies and shallow crossings, and a scale-aware residual gate, cutting the polish regression from ~827s to ~1.8s while holding sub-1e-9 world-unit residuals
- **Zoom-independent trim** — trim tolerances no longer depend on zoom; the tolerance is `max(kernel linear, localDiagonal * 1e-9)` so trim results are identical at every zoom level
- **Layers panel multi-selection and redesign** - Ctrl+Click toggles, Shift+Click selects a range, Ctrl+A (panel focused) selects all visible layers; Select All / Deselect All / Select All Except Current / Invert / Select Current / Select Similar live in the Select menu and a right-click row menu. All bulk operations now target the selection when one exists (else the previous filter scope), bulk Off/Freeze skip the current layer with a notice, and bulk delete has a confirmation dialog listing skipped layers with reasons. Clicking a row no longer changes the current layer: double-click, the Set Current button, or the context menu makes a layer current (gold check marker), and rename moved from double-click to F2 / right-click. The panel also gains a ribbon-style grouped wrapping icon toolbar with tooltips, search + sort on one row, scope menu chips, and icon rows showing current/on/off/frozen/locked/VP-frozen/no-plot at a glance, with rare actions (Walk, States, LAYERP, Reconcile, Plot Style, Description) in a More menu; the old Unicode glyphs rendered as ? in the UI font, so all symbols are draw-list line art now

### DXF & File Formats
- **Mirrored geometry round-trips** — `$MIRRTEXT` now writes the stored header value instead of a hardcoded `0`, mirrored block inserts export with a negative Y scale (rotation stays with the X axis) so reimport rebuilds the orientation-reversing transform instead of losing the reflection to magnitude-only scales, and mirrored (clockwise) arcs emit the same point set counter-clockwise from the end angle with the negated sweep rather than the complement arc; the orientation test is now a single canonical determinant check (`Transform3D.reversesOrientation2D`) shared by the entity, kernel-bridge, and DXF paths so every mirror path agrees
- **Analytic spline export** — DXF export writes real `SPLINE` entities (degree, knots, control points, weights) instead of tessellated chords, EAB round-trips the analytic definition, and PDF bounds span the exact endpoints; 50-digit oracle scripts live in `Tools/oracles` with literal golden values in the tests

### Bug Fixes
- **AutoLISP `atof` overflow** — out-of-range exponents such as `"1e400"` parsed to infinity and were returned as-is; results now clamp to `+/-greatestFiniteMagnitude` with the sign preserved, while underflow (`"1e-400"`) still yields `0.0` and in-range values are untouched
- **PAN press-and-hold (AutoCAD parity)** — `PAN` no longer latches on the first click and pans on hover until `Esc`; it now pans only while the left button is held, releasing stops the pan while staying in the command for another drag, with `Esc`/`Enter` to exit
- **Layout layer colors and AutoCAD color parity** — layout views now pick up layer color edits made in Model (sibling views reconcile layers render-only, without dirtying the sheet), and sheet rendering matches AutoCAD contrast behavior: only ACI 7 inverts on white paper while explicit ACI 1–6/8–255 and TrueColors render raw, so an ACI-31 salmon hatch no longer renders dark and explicit TrueColor white stays paper-white instead of mapping to charcoal; the importer records the ACI index vs 24-bit source (DXF 62 vs 420) and that distinction round-trips through export, PDF output, and the GPU vertex upload
- **EXPORTPDF stuck prompt** — exporting no longer leaves the command line waiting for input after the dialog opens
- **Spline trim overshoot** — trimming a spline no longer overshoots past the cutting edge: the stored intersection was already double-precision exact and the visible artifact came from fixed world-space tessellation drawing the curve past the true trim point, so the fix keeps analytic curves as the source of truth and drives the display from screen-space tolerance; verified end to end on `spline-trim-1.eab`/`spline-trim-2.eab`
- **Style-less table title heights** — `ACAD_TABLE` cells with no text height/style (e.g. CADdetails title blocks) now inherit the `*T` display-block `MTEXT` nominal height and style instead of falling back to `rowHeight * 0.6` with a nil style that the screen renderer then clobbered to Standard 2.0, so `PLAY SYSTEMS: SHIPS & CASTLES` renders at 4.77 against `PIRATE SHIP` at 2.38; table cell text also carries an explicit-height marker through the render path like `MTEXT` nominal heights
- **Merged table cells and centered text on DXF/DWG import** — `ACAD_TABLE` import now honors the merged-cell groups it used to drop (175/176 border width/height in cells, 173 on the virtual cells an anchor covers), so a title row like the Drive Roller `Parts List` imports as one cell spanning all columns with no interior grid lines instead of five separate cells; cells without a group-170 override also inherit alignment from their `TABLESTYLE` row style (title/header/data, honoring 280/281 suppression), so title, header, and quantity cells render centered as AutoCAD draws them while explicit 170 overrides still win, and edited tables write the span groups back out in sync
- **Table edges erased on plotted PDFs** — the PDF plot-style pass recomputed each entity's raw (unadjusted) color when no pen explicitly recolored it, so ByLayer ACI 7 geometry with no per-primitive color plotted raw white on white paper; on the Drive Roller sheet that invisible sheet-border polyline painted over every coincident table edge, leaving the Parts List top/right and title-block bottom/right borders hairline-faint in Export/Plot/Publish output. Object-color plotting now keeps the page-adjusted color (ACI 7 stays charcoal, explicit pen colors and grayscale unchanged), matching the text ink path. The same pass exposed a malformed catalog dictionary — `/UseOutlines` sat as a value-less `ViewerPreferences` key that strict parsers (MuPDF) reject as zero pages; it is now emitted as the `/PageMode` entry it always meant to be
- **Discrete snaps with OTRACK on** - the wide OTRACK fallback pass could only return on-curve points, dropping endpoint/midpoint/center/intersection snaps when OTRACK was on; the discrete result is now carried forward instead, so chaining a new LINE off an old endpoint works again
- **Hatch selection highlight** - selection, hover, rect-preview, and collaborator highlights now draw only the hatch boundary loops (outline) instead of re-tinting every pattern line in the selection color, matching AutoCAD where the pattern keeps its own colors
- **Measurement overlays clipped to the canvas** - `MEASUREGEOM` lines and labels are drawn on the ImGui draw list, which renders after every window, so they painted over the ribbon and other docked panels; primary-window overlays are now clipped to the drawing canvas (which already excludes docked panels), and the tool draws on the background list so floating panels cover it too
- **HATCH respects crossing edges (AutoCAD parity)** - Pick Points in HATCH (and BOUNDARY) now splits edges at interior crossings before tracing the boundary, so a line through a circle hatches only the seed's half instead of the whole circle; the legacy vertex-only walk remains as fallback

### Performance
- **Parallel curve-only zoom settle** — the band-crossing LOD refresh fans curve-bearing entities across a weight-chunked task group (same order-deterministic output as before) and shares the full regen's per-curve-budget accounting, measured at 4–7% of a full regen on `floorplan.eab` and a strictly cheaper, culling-assisted settle on the curve-dominated `gekko.eab` (zoomed settle halves vs full-fit); a refresh reproduces the full-regen tessellation point-for-point at the same band
- **Snap and trim responsiveness** - each mouse-motion snap ran the discrete anchor + intersection solve up to three times (once per fallback pass); fallback passes now skip the already-computed discrete stage. Intersection snap pre-rejects far curves by bounds, sorts near curves, and exits the pairwise solve once no later pair can win. Trim/extend solvers broad-phase filter cutters by the target's bbox, single/box/fence trims splice only the changed entities' cutter contributions (undo still recompiles fully), and trim clicks rebuild the entity grid so the next snap keeps its broad phase instead of full-scanning until regen lands. No geometry behavior changed; spline trim exactness is untouched

## October 2026

### New Features
- **AutoLISP support** — native engine (FDScript merge), 305/305 dispatch, file picker, persistent session, `c:` command dispatch, and examples; scripted CAD commands with multi-call support; app-wide system variables that survive LOAD/EVAL and wire `GRID`/`ORTHO`/`POLAR` to `GRIDMODE`/`ORTHOMODE`/`POLARMODE`
- **Ribbon** — AutoLISP-defined command chrome in a dockable window: tabs/panels/items, procedural icons, working flyouts, live enable/check state from system variables, classic `File/Edit/View` menu bar, labels-only and icons+labels presentations with the dock node resizing to the active presentation, and hot reload of `lisp/ribbon.lsp` (`RIBBON`, `RIBBONMODE`, `RIBBONRELOAD`); the definition ships as an editable per-user file that reloads on save and survives a failed parse, and no longer gets re-seeded over your edits
- **Multi-window editing** — float/dock OS windows and independent model views, with per-window status bars and window-local selection and gestures
- **Split view workspace** — visible always-on gutters with hairline borders and 3-dot grip handles, resize mouse cursors (`ResizeEW` / `ResizeNS`), smooth divider dragging with grab-offset compensation, double-click a divider to reset to 50/50, and per-pane identity badges showing `<tab> · <view>` (faded on hover so CAD picking is never obstructed)
- **Linux support**
- **Unclamped TrueColor rendering** — `AUTOCONTRAST` disables the viewport's contrast clamping for 24-bit TrueColors and gradients, so vector artwork and other non-CAD drawings show the colors you actually picked instead of adjusted ones (standard ACI 1–255 colors stay clamped); persisted per document
- **Paper space (model/paper space)** — `PSPACE`/`MSPACE` switch spaces for real with live `TILEMODE`/`CVPORT`/`CTAB` and `(layoutlist)`; activating a sheet rebuilds its floating-viewport projections from current model geometry, and projected copies are render-only (skipped by hit-testing, rect/lasso/`selectAll`, erase, move/scale/rotate) with undo-free, revision-free refresh; `MVIEW` lists, creates (fit-to-model by default), and controls floating viewports (`ON`/`OFF`/scale/twist/`SELECT`), clicking a viewport frame picks it as the default for `ZOOM nXP` paper scale and `CHSPACE`; `CHSPACE` moves entities across spaces through the viewport transform with undo in both documents; `LAYOUT NEW/RENAME/DELETE/COPY/?` manages sheets (Letter default with a fit viewport); `PSLTSCALE` scales projected linetypes with the viewport so dashes read the same size on paper
- **Page Setup (AutoCAD LT plot configuration)** — complete subsystem on the Phase 0 model: named page setups in `ACAD_PLOTSETTINGS` (create/apply/rename/delete with bound-layout propagation, `ModelType` scoping, import from other drawings), virtual device catalog (`DWG To PDF.pc3` at 200 DPI reference, raster virtuals; foreign plotter names preserved), the ten-group Page Setup dialog with live Partial Preview, Page Setup Manager, New Page Setup and Import dialogs, `PLOT` dialog, and live-canvas `PREVIEW`; the paper-space canvas now draws the physical sheet (143/142 plot-scale framing), drop shadow and dashed printable area (4-state margin rotation, `PLOTOFFSET` origin); `.ctb`/`.stb` tables parse (PIAF/zlib) and drive monochrome/grayscale/screening in plotted PDFs; plot transparency and PDF Options persist via EAB/XDATA (no plain DXF code exists for them)

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
- **MVIEW** (`MV`) — list, create, and control paper-space floating viewports: `?` lists id/on-off/scale/twist, two paper corners create a fit-to-model viewport, `ON`/`OFF`/`S` (scale)/`T` (twist) edit by id, `SELECT x,y` picks the viewport under a paper point
- **CHSPACE** — move selected entities between paper and model space through the active floating viewport's transform, adopting missing layers/blocks on the destination side
- **PAGESETUP** — open the Page Setup Manager for the active layout (also on the Output ribbon tab and layout-tab right-click); `CMDDIA=0` falls back to `-PAGESETUP`
- **PLOT** (`PRINT`) — plot the active layout to PDF through the Page Setup body (setup dropdown, `Add...`, `Apply to Layout`, destination file); `-PLOT` runs the full 19-step command-line configuration flow
- **PREVIEW** — live plot preview of the active layout (Fit/zoom, drag to pan, `Esc` to return) sharing the canvas sheet geometry
- **PSETUPIN / -PSETUPIN** — import named page setups from a `.dwg`/`.dwt`/`.dxf` without importing the drawing (`?` listing, `*`/`?` wildcards, redefine/skip on name conflicts; `FILEDIA=0` uses the command line)
- **SCALELISTEDIT / -SCALELISTEDIT** — List/Add/Delete/Reset the drawing's custom scale list feeding the Page Setup Scale dropdown; **STYLESMANAGER / PLOTTERMANAGER** open the plot-styles/plotters folders

### Improvements
- **Intersection object snap** — crossing points of two objects are now discrete snap targets (drawn with the X marker), so geometry can be placed exactly on offset/construction-line intersections instead of only the nearest on-curve point; works across lines, polylines (including self-crossings), circles, arcs, ellipses, splines, rays and xlines, competes with endpoints/midpoints by distance, stays sticky-locked, and can be acquired as an OTRACK tracking point
- **AutoCAD LT alias alignment (breaking)** — Zephyr-only aliases that shadowed LT meanings now resolve to LT: `AA`→`AREA`, `DT`→`TEXT`, `R`→`REDRAW`, and `S`/`D`/`PS`/`CL` are reserved for `STRETCH`/`DIMSTYLE`/`PSPACE`/`CENTERLINE` (`S`/`STRETCH` still reports not-implemented-yet; `PS`/`MS` switch paper/model space for real — see Paper space); canonical spellings flipped to `PLINE`, `RECTANG`, `SPLINEDIT`, `PROPERTIES`, `EXPORTPDF`, `TEXTEDIT`, `MTEXT`, `LAYOUT`, with the old spellings kept as aliases; displaced commands keep `RO`, `SC`, `TB`, `TOOLS`, `PSTROKE`, `TOR`. Full command names (`AALINES`, `TABLE`, `RAY`, `SCALE`, `DRAW`, `PENSTROKE`, `CLIP`, `TORIENT`) are unaffected, as are ribbon buttons and AutoLISP scripts using full names. Enforced by a new `CommandAliasParityTests` golden table so the four dispatch surfaces cannot drift apart again
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
- **PDF export** — DXF paper space layouts (paper size, units, and rotation from `AcDbPlotSettings`), export of the active drawing view, point sizing scaled inversely to prevent giant blocks, contrast adjustment for white strokes on light backgrounds, and `PDFEXPORT` filename normalization; with plot settings present, export becomes an exact plot (paper-exact page, std/custom/fit scale, centered/stored offsets, printable-area clipping, CTB pens, lineweight and transparency rules, viewports-first ordering) while model-space export keeps auto-fit
- **Plot system variables** — `PLOTOFFSET`, `PAPERUPDATE`, `PLOTROTMODE`, `PLOTTRANSPARENCYOVERRIDE` (registry, persisted) and read-only drawing `PSTYLEMODE` (persisted via `$PSTYLEMODE`), alongside existing `CTAB`/`PSLTSCALE`
- **PGP user aliases** — `zephyr.pgp` (`ALIAS, *COMMAND`) loads at startup with user entries overriding colliding built-ins (with warnings), editable live via `ALIASEDIT`
- **ARRAYPATH base point** — path arrays stop after the path pick for a base-point step: snap a point on the source object, type `B`, or press Enter to use the end of the path curve nearest the path pick (AutoCAD's default, keeping the first item in place, array running from that end); after creation, `ARRAYBASEPOINT` (Path Array ribbon `Base Point...` button) re-picks the base so the snapped source point rides the path without moving item stations (object snaps now resolve per array instance, so the pick lands on the item as drawn instead of being stolen by the path curve), the selection marker now draws the true path-riding anchor (re-picking the marker is a no-op instead of a jump), and an `Align` dropdown next to Align Items picks Relative to Start, Tangent, or Normal (perpendicular-rung) rotation
- **Docked panels** — a dock node holding a single window no longer shows a tab bar (the tab bar returns when a second window joins the node); the ribbon gains a Pop-out button beside Reload to undock in one click, and the click-to-show-tabs triangle moves to the top-center of the panel, clear of the window resize borders that used to swallow its clicks
- **LAYOUT goes modal like AutoCAD** — bare `LAYOUT` no longer cycles sheets; it prompts `Enter layout option [Copy/Delete/New/Rename/SAveas/Set/Template/?] <set>:` and stays active across the option/name steps, so `LAYOUT` → `N` → `<name>` creates and activates a sheet just like AutoCAD. `NEW`/`DELETE`/`RENAME`/`COPY`/`SET` with a missing name now prompt for it instead of printing usage, and a bare layout name or sheet index at the prompt switches to that sheet (`Esc` cancels)
- **Layer Properties Manager** — the Layers panel (`LA`/`LAYER`) is now a full manager: global columns plus selected-viewport (`VP Freeze`/`VP Color`/`VP Linetype`/`VP Lineweight`/`VP Transparency`/`VP Plot Style`) columns with per-row VP-frozen markers, a filter/state/viewport scope strip (stored property filters, stored layer states, unreconciled-only and VP-frozen-only flags) with a layer-count summary, single-undo bulk transactions (On/Off, Freeze/Thaw, Lock/Unlock, Plot/NoPlot, VP Freeze/Thaw) over the whole scope, and pickers/dialogs for color (ACI/RGB), linetype, lineweight, transparency, plot style, description, merge, delete (with erase-entities), LAYWALK isolation walk, and a layer-state manager (save/restore/delete plus `LAYERP` and reconcile-all); the grid renders at most 500 rows per group so huge layer tables stay fluid, the status bar flags unreconciled and VP-frozen layers, and the Home ribbon Layers panel gains Walk and States buttons
- **Layer model, viewport overrides, states, and history** — canonical frozen/locked/description/reconciled/transparency/color-source/plot-style fields; frozen layers stay out of regeneration, selection, and plotting, locked layers block edits while preserving snaps and use `LAYLOCKFADECTL` dimming, and `Defpoints`/No Plot layers never plot; `TRANSPARENCYDISPLAY` and `LWDISPLAY` control transparency and lineweight display; selected viewports support VP Freeze, New VP Freeze, and VP color/linetype/lineweight/transparency/plot-style overrides; named snapshots support `.las` exchange, property/group/invert filters, `LAYERP` history, and reconcile tracking for newly introduced layers

### DXF & File Formats
- **MLINE support** — plus DXF entity handles preserved in xdata
- **MLINESTYLE objects** — multiline styles round-trip through DXF (`MLINESTYLE` table + rebuilt `MLINE` entities) and a new EAB section carries named multiline styles
- **References on the wire** — INSERT/xref and ATTACH payload handling, with `REFPATHTYPE` 0/2 mapping
- **Plot settings round-trip** — sheets export full `AcDbPlotSettings` (paper size, margins, units/rotation, device/style, origin, window, scale, flags) instead of the legacy all-zero synthetic block, so paper size survives DXF save/reload; `$TILEMODE` follows the active space and `$PSLTSCALE` the active document on export; paper-space selection groups stay per-view (model groups stay on Model) and persist through EAB via the layout-settings section; named setups now round-trip as standalone `PLOTSETTINGS` objects in `ACAD_PLOTSETTINGS` (plus `LAYOUT` plot-Code-1 association and `LIMMIN`/`LIMMAX` sync), plot transparency/PDF Options ride `ZEPHYR_PLOT` XDATA, and EAB gains length-guarded plot fields plus named-setup and custom-scale sections (older files load with defaults)
- **Gradient hatch write-back** — `GF*` system variables and `entmake` support
- **Layer parity persistence** — EAB v23 layer tail plus additive viewport-override and layer-state sections; DXF layer descriptions, 70 state bits, color-book and transparency encodings, and viewport `331`/`ZEPHYR_VP` round trips; layer-state snapshots exchange through DXF group-code `.las` files

### Bug Fixes
- **DXF ellipse arcs** — elliptical arcs with near-zero parameter spans are no longer promoted to full ellipses; only an exact `0...2pi` span is treated as a full ellipse, so tiny projection-export ticks no longer render as large stray circles
- **Sheet ghost-double** — a layout whose only viewport is the overall paper-space viewport (ID 1) no longer projects model space on top of its paper geometry; the synthetic model-fit fallback now applies only to effectively-empty sheets (no visible vector paper content), so legacy layouts with just an invisible insert or missing raster still show the drawing instead of rendering blank
- **Snapping in modify commands** — base point selection during `MOVE` and friends now honors active entity snap targets (circle quadrants/center, line endpoints, midpoints) instead of falling back to raw mouse coordinates
- **SHX shape fonts** — fractional arcs, clockwise octant arcs, multi-stroke outline behavior, and hole nudging
- **Explode** — rectangles and compound entities split into separate elements
- **`CADDocument` concurrency** — crash prevention on concurrent access
- **LINE / Polyline** — Enter-to-finish; command bar and autocomplete always render on top
- **ODA setup** — download 404 and teardown hardening; first-run setup popup
- **Windows builds** — missing DLLs, crash when engine init fails, and `igInputText` String-pointer warnings
- **MLeader callout justification** — ODA-converted drawings repeat AcDbText placement groups inside ATTDEFs, which clobbered centered justification so block-content callouts (e.g. detail bubbles) rendered left-aligned at the insertion point; duplicate placement codes inside the attribute subclass are now ignored once a real AcDbText subclass was seen
- **MTEXT alignment code** — AutoCAD's `\A0/1/2;` marker is stacked-text alignment, not paragraph justification, so it no longer centers whole paragraphs and width-less notes stay anchored at their insertion point; MTEXT attachment points decompose into justification, and `\A` round-trips on export
- **Legacy leader arrows** — DIMSCALE folds into arrow size, text offset, and text height (including per-entity DSTYLE overrides), and custom arrowhead blocks orient tip-at-origin per the AutoCAD convention
- **Radial nav cursor on secondary monitors** — moving the nav itself no longer enables SDL relative-mouse capture (an absolute drag needs none), so the cursor is no longer parked mid-window with no warp-back owed; a mouse-up lost while the app window sits on a secondary monitor now force-releases the drag from the physical button state instead of stranding relative capture on
- **Radial nav follows window resizes** — the nav now owns its position every frame and clamps the remembered (or dragged) spot into the current window, so shrinking the window can no longer strand it off-screen

### Maintenance
- **Swift 6.4 migration** — toolchain bump and `zlib-ng` fix
- **Dependencies** — SDL3 3.4.18 and SDL3_image 3.4.8
- **macOS bundles** — Universal binary and bundled Swift runtime
- **Linux packaging** — Snap, AppImage and Flatpak (x64 and ARM64); DXC pinned to v1.8.2407 for glibc 2.35 compatibility
- **CI** — build fixes across Windows, macOS and Linux; Linux CI on every push
- **`test.ps1`** — test-runner wrapper that sets the SDL3/zlib-ng build environment, detects host arch and Visual Studio, pre-builds the test bundle, and propagates exit codes
- **Website and docs** — Linux support, AutoLISP, OFFSET, corrected downloads, roadmap, and a site rework around honest AutoCAD LT role support

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
