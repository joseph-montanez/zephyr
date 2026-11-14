# Changelog

All notable changes to EngineAsBuilt are documented here.

## Unreleased

- Idle redraw: the lazy render loop now wakes when deferred render work
  lands (regen in flight, vertex-build in flight, deferred GPU swap,
  stale generation, bridge/curve work, visible-document flags, and
  finished ribbon loads) instead of waiting for cursor input. The gate
  re-samples after polling so mid-wait completions render in the same
  iteration. Generation mismatch during active Lisp evaluation no longer
  holds full-rate rendering.
- File open: DXF/DWG/EAB import (`TabManager.openTab`) now has a
  headless entry point (`open_drawing` MCP tool, same funnel as the
  Open dialog) with engine/state diagnostics, and a regression test
  pinning that an opened drawing becomes active with regeneration
  pending.

Known follow-up: opening a drawing hands-off still reverts to the
previous tab in the live app. ImGui's persistently selected stale tab
item passes `TabBarActivationPolicy.shouldActivateTab` during the
forced-selection lag frame, so the tab bar switches back before the new
drawing's regen can present. The policy and its tests are unchanged.
