# fd-native — running FDScript without AutoLISP

Two files, one idea: the DSL executes directly on typed values.

* [room_native.fdscript](room_native.fdscript) — parametric studio drawn
  with native host calls (`line`, `circle`, `arc`, `text`, `point`,
  `polar`, `rtos` over a real selection). Not valid AutoLISP; that is
  the point.
* [NativeCADHost.swift](NativeCADHost.swift) — in-memory `FDHost`
  showing the engine side: every DSL call arrives as `FDValue`s
  (`.point`, `.number`, `.entity`, …). A production host implements the
  same protocol against the live `CADDocument`.

Engine path (nothing emitted, nothing compiled to `.lsp`):

```swift
let src = try String(contentsOfFile: "room_native.fdscript", encoding: .utf8)
let program = try FieldDraftScriptParser(src).parseProgram()
try await FDInterpreter(host: myCadHost).run(program, command: "ROOM")
```

Not wired into the app or MCP today — `eval_lisp`/`load_lsp` only
accept AutoLISP. Wiring this host (backed by `CADDocument`) into the
command router or an MCP tool is the remaining step.
