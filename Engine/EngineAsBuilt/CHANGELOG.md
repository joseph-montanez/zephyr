# Changelog

## Unreleased

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
