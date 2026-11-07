# Changelog

## Unreleased

### Added
- Blocks palette (`BLOCKSPALETTE`): tabbed Current / Recent / Favorites /
  Libraries panel with vector thumbnails, search, pinning, and Explode /
  Repeat / Prompt-attributes insertion options. Libraries browse folders of
  `.dxf` / `.dwg` / `.eab` files and per-block container contents with
  background parsing; Recent / Favorites, library folders, and insertion
  defaults persist across restarts. `INSERT` accepts typed `x,y[,z]` points,
  previews the true-size ghost at the cursor, clones container blocks at
  commit (single undo, Esc leaves no residue), and prompts for attributes
  when `ATTREQ=1`. New `BLOCKSPALETTECLOSE` command and `BLOCKSLIBRARYPATH`
  sysvar; block definitions import (0,0)-based so non-zero `BLOCK` base
  points place correctly by name.
- AutoCAD-style layer multi-selection in the Layers panel: Ctrl+Click
  toggles, Shift+Click selects a range, Ctrl+A (panel focused) selects
  all visible layers. Select All / Deselect All / Select All Except
  Current / Invert / Select Current / Select Similar live in the Select
  menu and a right-click row menu. All bulk operations now target the
  selection when one exists (else the previous filter scope), bulk
  Off/Freeze skip the current layer with a notice, and bulk delete has
  a confirmation dialog listing skipped layers with reasons. Clicking a
  row no longer changes the current layer: double-click, the Set
  Current button, or the context menu makes a layer current (gold check
  marker), and rename moved from double-click to F2 / right-click.

### Changed
- Layers panel redesigned with ribbon-style procedural icons: grouped
  wrapping icon toolbar with tooltips, search + sort on one row, scope
  menu chips (the Unreconciled/VP-frozen checkboxes moved into the
  Filter menu), and icon rows showing current/on/off/frozen/locked/
  VP-frozen/no-plot at a glance. Rare actions (Walk, States, LAYERP,
  Reconcile, Plot Style, Description) moved to a More menu. All symbols
  are draw-list line art now; the previous Unicode glyphs rendered as
  "?" in the UI font.
- TRIM and EXTEND now default to Quick mode (TRIMEXTENDMODE=1, the current
  AutoCAD default): starting TRIM with nothing selected goes straight to
  click-to-trim with all objects acting as cutting edges. An empty-space
  press-drag trims/extends everything the freehand path crosses on release,
  a plain empty click arms a two-point fence, and C forces a crossing box
  (new in TRIM). A picked object that cannot be trimmed is deleted in Quick
  mode instead of left unchanged. PICKFIRST is now honored by both commands:
  pre-selected objects become the only edges when on (even in Quick) and are
  ignored when off. TRIM's Mode option is an explicit [Quick/Standard]
  prompt like EXTEND's. TRIMEXTENDMODE and PICKFIRST persist across restarts.

### Fixed
- Snap and trim responsiveness after the screen-space curve LOD change. Each
  mouse-motion snap ran the discrete anchor + intersection solve up to three
  times (once per fallback pass); fallback passes now skip the already-computed
  discrete stage. Intersection snap pre-rejects far curves by bounds, sorts
  near curves, and exits the pairwise solve once no later pair can win.
  The first iteration of that skip dropped endpoint/midpoint/center/
  intersection snaps when OTRACK was on (the wide fallback could only return
  on-curve points); the discrete result is now carried forward instead, so
  chaining a new LINE off an old endpoint works again.
- Trim/extend clicks no longer recompile every cutter drawing-wide or test
  every cutter in the solvers: each solver broad-phase filters cutters by the
  target's bbox first, and single/box/fence trims splice only the changed
  entities' cutter contributions (undo still recompiles fully). Trim clicks
  also rebuild the entity grid so the next snap keeps its broad phase instead
  of full-scanning per mousemove until regen lands. No geometry behavior
  changed; spline trim exactness is untouched.
- Hatch selection highlight now draws only the hatch boundary loops (outline)
  instead of re-tinting every pattern line in the selection color, matching
  AutoCAD behavior where the pattern keeps its own colors.
- HATCH / BOUNDARY pick-point detection now nodes edges at interior crossings, so a line through a circle yields the seed's half instead of the whole circle; the legacy walker stays as fallback.
