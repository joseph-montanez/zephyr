# Changelog

Monthly digest condensed from the git history. Instead of per-release notes, all changes are grouped by calendar month and summarized under **New Features** (brand-new capabilities), **New Commands** (new drawing/modify commands on existing features), **Improvements** (refinements to existing features), **DXF & File Formats**, **Bug Fixes**, **Maintenance** (toolchain, packaging, CI, housekeeping), and **Performance**. Fixes and refinements made to a feature during the same month it ships are folded into that feature's entry rather than listed again.

## November 2026

### New Features
- **Blocks palette** - browse and insert blocks with thumbnails and search.
- **Model-space plotting** - plot, page setup, and preview work from Model space.
- **Batch publishing** - publish multiple sheets to PDF at once.
- **Sheet sets** - organize drawings, place views, and publish the set.
- **Callouts and transmit** - tag sheets and package a set for sharing.
- **Save As DWG** - save directly to DWG.
- **New themes** - dark purple starfield theme and a vivid pink theme.
- **MCP server for AI driving** - lets AI tools inspect and drive the app.
- **Native dimensions from Lisp** - create dimensions from Lisp with matching export.

### New Commands
- **PUBLISH / +PUBLISH / -PUBLISH** - publish multiple sheets to PDF.
- **Sheet-set commands** - `SHEETSET`, `SHEETSETHIDE`, `NEWSHEETSET`, `OPENSHEETSET`, `PLACEVIEW`, `PLACECALLOUT`, `SHEETLISTTABLE`, `-PUBLISHSET`, `-TRANSMITSET`.
- **Blocks palette** - `BLOCKSPALETTE` / `BLOCKSPALETTECLOSE`.
- **BLOCKLOD** - toggle automatic zoom-gated collapsing of small block inserts on or off.
- **Layer commands** - `LAYFRZ`, `LAYTHW`, `LAYLCK`, `LAYULK`, `LAYDEL`, `LAYMRG`, `LAYWALK`, `COPYTOLAYER`, `VPLAYER`, `LAYERSTATE`, `LAYERP`, and richer `-LAYER`.
- **UCS / PLAN** - set custom drawing planes and align the view.
- **MIRROR (`MI`)** - mirror objects across a line.
- **STRETCH (`S`)** - stretch points inside a crossing window.
- **BREAK (`BR`) / BREAKATPOINT** - erase a span or split at a point.
- **EXTEND (`EX`)** - extend objects to boundary edges.
- **SNAP / GRIDSPACING / GRIDMAJOR** - grid snap with separate X/Y spacing.
- **STARFIELD (`STARS`)** - toggle the starfield on or off.
- **VIEWCTR / VIEWSIZE** - show the viewport center and height.

### Improvements
- **Fit/Aligned text** - spans its two points.
- **Space acts as Enter** - Space submits commands like Enter.
- **Dropdown option lists** - prompts show a pick list with the current value.
- **Clickable prompt chips** - command keywords are clickable.
- **THEME prompt** - bare `THEME` lists and switches themes.
- **Feature options palette** - Enter picks the highlighted option.
- **PDF font handling** - choose searchable text, outlines, or SHX geometry.
- **PDF table text sizing** - scaled tables print at the right size.
- **PDF Extents framing** - Extents plots stay on the page.
- **PDF plot-style ink** - pen tables color dimensions and table text.
- **Shared TRIM/EXTEND modes** - both share Quick/Project/Edge modes.
- **Consistent trim at any zoom** - trim no longer changes with zoom.
- **Smoother curves when zooming** - curves refine with zoom.
- **Faster spline math** - intersections are faster, same accuracy.
- **Layers panel refresh** - multi-select, bulk actions, search, sort.
- **LAYOUT SAveas** - duplicate the current layout under a new name.
- **MEASUREGEOM Angle mode** - three-click angle with an arc overlay.
- **WBLOCK file export** - export blocks to DXF or DWG.
- **Cross-tab clipboard** - copy and paste across open drawings.
- **Restore saved Model view on open** - open at the saved view when it overlaps the drawing, else zoom to extents.

### DXF & File Formats
- **Mirrored geometry round-trips** - mirrored blocks and arcs survive save and reopen.
- **Real spline export** - keep true spline definitions.

### Bug Fixes
- **Simplify frame thickness** - collapsed-block outlines render as thin 2px frames instead of giant solid-looking slabs.
- **Block editor framing** - fits the block in view on open.
- **Imported text width** - uses the correct default width.
- **Text spaces** - leading and trailing spaces are preserved.
- **SHX text bounds** - picking uses the rendered size.
- **Wrapped MTEXT leading spaces** - keeps its own line so following words align.
- **Distributed MTEXT paragraphs** - spreads across the styled width.
- **SHX word wrap** - wraps like AutoCAD without overflowing the width.
- **Text edits keep position** - editing centered or fitted text no longer shifts it off its anchor; edited MTEXT keeps its horizontal alignment and exports its text.
- **UTF-8 text support** - non-ASCII text is preserved correctly when opening DWG/DXF files.
- **Hatch gaps** - blanks around text in hatches stay blank.
- **Hatch highlight** - selected hatches outline instead of recoloring.
- **HATCH crossing edges** - hatches only the picked side.
- **Click inside hatches** - clicking inside a hatch selects it.
- **Open hatch boundaries no longer fill** - a loop with a real gap is dropped instead of painting its closing chord across the drawing, and file-ordered loop edges stitch in order so dense shared-vertex boundaries stay closed.
- **Huge-drawing streaks** - uploads no longer tear into streaks or kill the GPU.
- **EXPORTPDF prompt** - no longer hangs after export.
- **Table edges on PDFs** - plotted tables keep visible edges.
- **Table title heights** - use the correct height.
- **Table merges on import** - merged cells import correctly.
- **Panning memory use** - text no longer leaks while panning.
- **PAN behavior** - pans only while the mouse button is held.
- **Lisp `atof` overflow** - huge numbers clamp instead of returning infinity.
- **AutoLISP crash while a script runs** - no longer crashes; reads and writes are serialized.
- **Layout colors** - follow Model layer colors.
- **Spline trim** - stops at the cutting edge.
- **Snaps with OTRACK on** - endpoint and midpoint snaps work again.
- **Grid visibility and snap** - clearer grid, exact snap interval.
- **Measurement overlays** - stay on the canvas.
- **MCP thumbnails** - match the window orientation.
- **Overlapping picks** - shows a choice list again.
- **Zoom extents after scripts** - refreshes correctly after edits.
- **Stale nested dimensions no longer explode extents** - rebuilt from the definition points so zoom lands on the drawing.
- **Cross-tab paste left invisible geometry** - paste lands on the right layers.

### Maintenance
- **Code cleanup** - internal cleanup, no behavior change.

### Performance
- **Zoom and pan stay smooth on large drawings** - zoom no longer stalls or forces full rebuilds; curves refine in place and text stays visible while panning.
- **Faster hover and snap** - moving the cursor is cheaper on big drawings; snaps feel instant.
- **Quieter hover** - panels and fast cursor moves no longer highlight.
- **Fewer draw calls on line-heavy drawings** - renders much faster without changing the picture.
- **Adaptive hairline rendering** - huge drawings fall back to 1px line pairs past the vertex budget, and a hard total-vertex cap with a `capped` PerfStats flag stops uploads that would remove the GPU device.
- **Survives GPU trouble** - reports one clear message instead of spamming, so you can still save and close.
- **Huge drawings keep working** - geometry uploads in safe chunks instead of killing the GPU.
- **Zoom-gated block LOD** - small blocks collapse to batch-friendly triangle boxes when zoomed out and return to full detail on zoom-in.
- **Zoom-gated text and hatch density** - sub-legible text fades out and sub-pixel hatch lines are skipped when zoomed out.
- **Tessellate-time polyline decimation** - sub-pixel interior vertices are dropped at build time; dashed lines keep their dots and tiny closed parcels vanish instead of emitting degenerate segments.
- **PerfStats breakdown in the header** - the FPS display now includes verts, batches, sprites, line/tri/hatch verts, and the content census.
- **Hatch selection on huge boundaries** - the hatch ribbon payload is cached per document revision, solid fills highlight by boundary outline, and midpoint grips stop past 1,024 points, so selecting a large water hatch no longer pins the CPU.

## October 2026

### New Features
- **AutoLISP support** — native engine (FDScript merge), 305/305 dispatch, file picker, persistent session, `c:` command dispatch, and examples; scripted CAD commands with multi-call support; app-wide system variables that survive LOAD/EVAL and wire `GRID`/`ORTHO`/`POLAR` to `GRIDMODE`/`ORTHOMODE`/`POLARMODE`
- **Ribbon** — AutoLISP-defined command chrome in a dockable window: tabs/panels/items, procedural icons, working flyouts, live enable/check state from system variables, classic `File/Edit/View` menu bar, labels-only and icons+labels presentations with the dock node resizing to the active presentation, and hot reload of `lisp/ribbon.lsp` (`RIBBON`, `RIBBONMODE`, `RIBBONRELOAD`); the definition ships as an editable per-user file that reloads on save and survives a failed parse, and no longer gets re-seeded over your edits
- **Multi-window editing** — float/dock OS windows and independent model views, with per-window status bars and window-local selection and gestures
- **Split view workspace** — visible always-on gutters with hairline borders and 3-dot grip handles, resize mouse cursors (`ResizeEW` / `ResizeNS`), smooth divider dragging with grab-offset compensation, double-click a divider to reset to 50/50, and per-pane identity badges showing `<tab> Â· <view>` (faded on hover so CAD picking is never obstructed)
- **Linux support**
- **Unclamped TrueColor rendering** — `AUTOCONTRAST` disables the viewport's contrast clamping for 24-bit TrueColors and gradients, so vector artwork and other non-CAD drawings show the colors you actually picked instead of adjusted ones (standard ACI 1â€“255 colors stay clamped); persisted per document
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
- **AutoCAD LT alias alignment (breaking)** — Zephyr-only aliases that shadowed LT meanings now resolve to LT: `AA`â†’`AREA`, `DT`â†’`TEXT`, `R`â†’`REDRAW`, and `S`/`D`/`PS`/`CL` are reserved for `STRETCH`/`DIMSTYLE`/`PSPACE`/`CENTERLINE` (`S`/`STRETCH` still reports not-implemented-yet; `PS`/`MS` switch paper/model space for real — see Paper space); canonical spellings flipped to `PLINE`, `RECTANG`, `SPLINEDIT`, `PROPERTIES`, `EXPORTPDF`, `TEXTEDIT`, `MTEXT`, `LAYOUT`, with the old spellings kept as aliases; displaced commands keep `RO`, `SC`, `TB`, `TOOLS`, `PSTROKE`, `TOR`. Full command names (`AALINES`, `TABLE`, `RAY`, `SCALE`, `DRAW`, `PENSTROKE`, `CLIP`, `TORIENT`) are unaffected, as are ribbon buttons and AutoLISP scripts using full names. Enforced by a new `CommandAliasParityTests` golden table so the four dispatch surfaces cannot drift apart again
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
- **LAYOUT goes modal like AutoCAD** — bare `LAYOUT` no longer cycles sheets; it prompts `Enter layout option [Copy/Delete/New/Rename/SAveas/Set/Template/?] <set>:` and stays active across the option/name steps, so `LAYOUT` â†’ `N` â†’ `<name>` creates and activates a sheet just like AutoCAD. `NEW`/`DELETE`/`RENAME`/`COPY`/`SET` with a missing name now prompt for it instead of printing usage, and a bare layout name or sheet index at the prompt switches to that sheet (`Esc` cancels)
- **Layer Properties Manager** — the Layers panel (`LA`/`LAYER`) is now a full manager: global columns plus selected-viewport (`VP Freeze`/`VP Color`/`VP Linetype`/`VP Lineweight`/`VP Transparency`/`VP Plot Style`) columns with per-row VP-frozen markers, a filter/state/viewport scope strip (stored property filters, stored layer states, unreconciled-only and VP-frozen-only flags) with a layer-count summary, single-undo bulk transactions (On/Off, Freeze/Thaw, Lock/Unlock, Plot/NoPlot, VP Freeze/Thaw) over the whole scope, and pickers/dialogs for color (ACI/RGB), linetype, lineweight, transparency, plot style, description, merge, delete (with erase-entities), LAYWALK isolation walk, and a layer-state manager (save/restore/delete plus `LAYERP` and reconcile-all); the grid renders at most 500 rows per group so huge layer tables stay fluid, the status bar flags unreconciled and VP-frozen layers, and the Home ribbon Layers panel gains Walk and States buttons
- **Layer model, viewport overrides, states, and history** — canonical frozen/locked/description/reconciled/transparency/color-source/plot-style fields; frozen layers stay out of regeneration, selection, and plotting, locked layers block edits while preserving snaps and use `LAYLOCKFADECTL` dimming, and `Defpoints`/No Plot layers never plot; `TRANSPARENCYDISPLAY` and `LWDISPLAY` control transparency and lineweight display; selected viewports support VP Freeze, New VP Freeze, and VP color/linetype/lineweight/transparency/plot-style overrides; named snapshots support `.las` exchange, property/group/invert filters, `LAYERP` history, and reconcile tracking for newly introduced layers
- **Cotton Candy theme** — new Barbie-pink light preset (`CANDY`, also reachable as `BARBIE` / `RAINBOW` / `Cotton Candy`) with deep-raspberry text, rainbow window controls, and readable contrast on panels and buttons; exact-name matching in the `THEME` prompt now resolves any alias to its preset (previously only short name, id, and display name matched, so aliases never applied at the prompt)
- **Per-window panel layouts for float windows** — each OS window (main plus `TABFLOAT` floats) keeps its own panel visibility, position, size, and docking; a newly floated window copies the main layout once and then diverges, toggles and panel close buttons affect only the issuing window, and each window layout persists across restarts

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
- **Stale theme colors on background windows** — every OS window owns its own ImGui context but only the current one was restyled on a theme switch, so float windows kept rendering dropdowns and popups in the previous theme; each window now stamps the applied theme revision and re-syncs on activation
- **Stray empty "Debug" panel** — overlay clip-rect pushes ran while no ImGui window was open, marking ImGui's implicit `Debug##Default` fallback window as used so it rendered as a floating empty panel; the out-of-window clip calls are removed (background/foreground lists keep their own clips) and the dashed-line helper now requires an explicit draw list

### Maintenance
- **Swift 6.4 migration** — toolchain bump and `zlib-ng` fix
- **Dependencies** — SDL3 3.4.18 and SDL3_image 3.4.8
- **macOS bundles** — Universal binary and bundled Swift runtime
- **Linux packaging** — Snap, AppImage and Flatpak (x64 and ARM64); DXC pinned to v1.8.2407 for glibc 2.35 compatibility
- **CI** — build fixes across Windows, macOS and Linux; Linux CI on every push
- **`test.ps1`** — test-runner wrapper that sets the SDL3/zlib-ng build environment, detects host arch and Visual Studio, pre-builds the test bundle, and propagates exit codes
- **Website and docs** — Linux support, AutoLISP, OFFSET, corrected downloads, roadmap, and a site rework around honest AutoCAD LT role support

### Performance
- **DXF import** — 2.2Ã— faster: per-entity string format hoisting, byte-scanning of group pairs, skipping code-page conversion
- **NURBS** — single scratch buffer per evaluation instead of three arrays
- **EAB/SHX** — one byte helper with safe loads, gated by golden digests
- **Swift 6.4 branch** — performance harness and baseline
- **Large-selection cursor lag** — the Properties panel picker rebuilt, relabeled, and re-sorted the whole selection every frame (plus a console print per frame); it is now cached and rebuilt only when the selection or document changes, with no per-frame allocation in the comparator. Also cached: rect-select preview queries (per frame â†’ per changed rect), renderable world bounds, and layer lookups; hover hit-tests are throttled (8 ms) with grip early-outs, live-drag transforms skip full storage prep, and the vertex rebuild no longer launches mid-rect-drag
- **ImGui uploads** — transfer buffers are reused across frames instead of created/released per frame (amortized growth with headroom)
- **Bulk-move path-array refresh** — moving N objects rescanned the whole registry N times to refresh path arrays; the scan now runs once over the union of moved handles, ~92x fewer scans (measured 19.3s to 0.21s moving 150 objects in a 336k-entity file)

## September 2026

No commits.

## August 2026

11 commits Â· 2026-08-02 â€“ 2026-08-12

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

117 commits Â· 2026-07-01 â€“ 2026-07-28

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

60 commits Â· 2026-06-23 â€“ 2026-06-30

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

