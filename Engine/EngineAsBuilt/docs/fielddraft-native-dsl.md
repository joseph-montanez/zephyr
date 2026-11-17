# FieldDraft Native DSL — if the DSL ran natively

> Companion to the current pipeline: **FDScript text → [Parser](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/Parser.swift) → [AST](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/AST.swift) → [AutoLISPBackend](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPBackend.swift) → `.lsp` text → AutoLISP interpreter**.
> This doc describes the **same language executed natively** by [FDInterpreter](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptRuntime/FDInterpreter.swift) against the live [CADDocument](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/ZephyrCore/CAD/CADDocument.swift) via [FDHost](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptRuntime/FDHost.swift) — no `.lsp` emitted, no AutoLISP evaluation.

---

## 1. What “native” means here

Today the DSL is a *transpiler front-end*: the parser produces a backend-neutral `FDProgram`, and the only shipped backend renders AutoLISP parentheses. The runtime ([FDValue](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptRuntime/FDValue.swift) / [FDEnvironment](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptRuntime/FDEnvironment.swift)) exists but is unused by the app — `setup`/`restore` are no-ops in the interpreter, `raw` is a no-op, and every call is delegated to the host as an opaque string name.

A native DSL keeps the **exact same surface syntax** (the parser, lexer, and AST do not change) but changes the **execution lowering**:

| Concern | Today (via AutoLISP) | Native |
|---|---|---|
| Value domain | AutoLISP dynamic types: `nil`/`T`, real/int, string, list, ename, safearray, VLA object | `FDValue`: `.nilValue`, `.bool`, `.number(Double)`, `.string`, `.point(x,y,z)`, `.list([FDValue])`, `.entity(String)` |
| Entities | DXF group-code lists `(0 . "LINE") (10 1 2 0) ...` built with `entmake` | Structured host calls: `entity.create(type: "LINE", points: [p1, p2])` — no group codes in script |
| Selection | `ssget "_I"` returns an opaque selection set | Host returns `.list([.entity("7A3")])` or a first-class `SelectionSet` |
| Points | 3-element lists `(1.0 2.0 0.0)` | `FDValue.point` — arithmetic on points is host-validated, not list indexing |
| Input | `getpoint`/`entsel` park on the AutoLISP input broker | Host suspends the async interpreter until the CAD layer supplies a value — same single-flight guard as MCP `eval_lisp` |
| Scope | `setq` leaks to globals unless the emitter’s `/ locals` list catches it (see Defect 3 in [FDEmitterDefectPins.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Tests/FDScriptTests/FDEmitterDefectPins.swift)) | `FDEnvironment.variables` is a real dictionary; function calls would push/pop a frame — no `/`-list synthesis |
| Errors | `*error*` handler + `princ` + silent `nil` | Thrown `FDRuntimeError` / host errors propagate to the caller (command line, MCP, or test) |
| Escape hatch | `raw("(+ 1 2)")` / `rawTop` emit verbatim text | No-op in interpreter; a native runtime would replace these with typed host calls or reject them at parse time |

The sections below cite the source of truth for each construct. Where the current emitter is buggy, the native reading is marked **(defect)**.

---

## 2. Lexical layer

Source: [Lexer.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/Lexer.swift), [Token.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/Token.swift).

| Token kind | Form | Notes |
|---|---|---|
| `identifier` | `[A-Za-z_][A-Za-z0-9_*?\-]*` | Case-sensitive. `command`, `setq`, `getpoint` are identifiers, not reserved words — the parser matches strings. |
| `number` | `123`, `3.14`, `.5`, `1e-3` | Parsed as `Double`. No integer/real distinction in the AST; the emitter formats integral values as `Int` for AutoLISP. |
| `string` | `"..."` with `\n \t \r \" \\` escapes | Lexer keeps `\\n` as two chars; unescaping is backend-dependent. |
| `comment` | `; rest of line` or `// rest of line` | Both forms lex to `.comment`. Standalone `comment "..."` statements are separate (below). |
| `symbol` | `{ } ( ) , = + - * / < > [ ]` plus two-char `>= <= == !=` | `==`/`!=` are normalized to `=`/`/=` only in the AutoLISP emitter. |
| `newline` | `\n` | Significant as statement separator; blocks are `{ ... }`, not indentation. |
| `eof` | end of input | Parser expects it after the last declaration. |

No string interpolation, no float suffixes, no heredocs.

---

## 3. Declarations (top level)

Source: [Parser.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/Parser.swift) `parseProgram()`.

A program is a sequence of declarations. `include "path.fdscript"` lines are resolved *before* lexing by [IncludeResolver](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/Includes.swift) — recursive, deduped by standardized path, missing file is a parse error.

| Declaration | Syntax | AST | Native meaning |
|---|---|---|---|
| `command` | `command NAME { stmts }` | `.command(FDCommandDecl)` | Registers a zero-arg host command. Native: callable by name from the command line / MCP `run_command`; locals are the command frame. |
| `function` | `function NAME(p1, p2) { stmts }` | `.function(FDFunctionDecl)` | First-class callable. Native: stored in `FDEnvironment.functions`; args bound positionally. |
| `alias` | `alias SHORT = TARGET` | `.alias(FDAliasDecl)` | Command alias. Native: host alias table entry. |
| `macro` | `macro NAME { stmts }` | `macros[name] = tokens` (not in `FDProgram`) | Textual macro, expanded at parse time (depth ≤ 50). **(defect)** `parseMacroCall` returns only the *last* expanded statement — multi-statement macros lose all but one body ([FDEmitterDefectPins.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Tests/FDScriptTests/FDEmitterDefectPins.swift) Defects 2a/2b). Native runtime would expand to a statement list. |
| `rawTop` | `rawTop "..."` or `rawTop (expr)` | `.rawTop(String)` | Verbatim AutoLISP at top level. **No native meaning** — would be rejected or require a host override. |

Example:

```fdscript
// FDScript (current source)
function dist2(p1, p2) {
  setq dx = car(p2) - car(p1)
  return dx
}
command FOO { setq d = dist2(a, b) }
alias F = FOO
```

```autolisp
;;; Compiled FieldDraft Script
(defun dist2 (p1 p2 / dx)
  (setq dx (- (car p2) (car p1)))
  (- (car p2) (car p1)))
(defun c:FOO ( / d)
  (vl-load-com)
  (setq d (dist2 a b))
  (princ))
(defun c:F () (c:FOO))
```

Native reading (executed directly): `dist2` is a closure over `FDValue.point` subtraction; `command FOO` binds `d` in its frame; `alias F` is a host alias. No `(vl-load-com)`, no `(princ)` trailer, no `/ locals` synthesis.

---

## 4. Statements

Source: [ParserStatements.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/ParserStatements.swift), [AST.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/AST.swift), interpreter in [FDInterpreter.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptRuntime/FDInterpreter.swift).

| FDScript | AST | AutoLISP lowering | Native semantics |
|---|---|---|---|
| `setup` / `restore` | `.setup` / `.restore` | Saves `OSMODE`/`CMDECHO`, installs `*error*`, restores on exit ([AutoLISPBackend.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPBackend.swift) `emitSetup`/`emitRestore`) | **No-op today.** Native: transaction guard — push a CAD checkpoint, restore sysvars on error/cancel. |
| `comment "..."` | `.comment(String)` | `;; text` | Ignored. |
| `setq x = expr` | `.setq([(x, expr)])` | `(setq x expr)` ; block form `setq { a = 1 b = 2 }` → multi-pair `setq` | Bind `x` to the evaluated `FDValue` in the current frame; returns the bound value. Block form is sugar for sequential bindings. |
| `setvar "NAME" expr` | `.setvar(name, expr)` | `(setvar "NAME" expr)` — name may be a string *or* identifier token | Delegated to host (`host.call("setvar", …)`). Native: writes a sysvar; returns the sysvar’s previous value per CAD convention. |
| `princ expr` / `princ(expr)` | `.expr(.call("princ", [expr]))` | `(princ expr)` | Host output: prompt/console write, no newline. |
| `acadCommand(...)` | `.expr(.call("command", args))` | `(command ...)` — sends keystroke tokens to the active command | Host command dispatcher; native form would be a typed `host.runCommand(name:_:)` event. |
| `if cond { } [else { }]` | `.ifStmt` | `(if cond (progn …) (progn …))` | Short-circuit; only one branch evaluates; returns the taken branch’s last value. |
| `ifLet x = point "prompt" [base y] { } [else { }]` | `.ifLet(name, .point(prompt, base), …)` | `(if (setq x (getpoint …)) …)` | Awaits host input; binds `x` to `.point` or `.nilValue`; branches on truthiness. `select "prompt"` variant lowers to `(car (entsel …))`. |
| `while cond { }` | `.whileStmt` | `(while cond …)` | Re-evaluates `cond` each iteration; returns last body value. **(defect)** emitter uses a fresh `LispEnvironment` for the body, so locals assigned only inside the loop are missing from `/` (same root as Defect 3). |
| `cond { cond {…} else {…} }` | `.cond([(cond, body)])` | `(cond (cond …) (T …))` | First truthy case wins; `else` is desugared to `.bool(true)`. |
| `repeat n { }` | `.repeat(count, body)` | `(repeat n …)` | Runs body `Int(n)` times; non-numeric count → `nil` (interpreter returns `.nilValue` without running). |
| `foreach x in list { }` | `.foreach(name, list, body)` | `(foreach x list …)` | Iterates `FDValue.list`; non-list → `nil`. Native: typed iteration over `.list` or a selection set. |
| `return expr` | `.returnStmt(expr)` | Bare expression (AutoLISP returns the last form) | **No early-exit in the interpreter today** — `eval` just returns the value; the enclosing block continues. A native runtime needs a thrown `Return` signal. |
| `selection implied / crossing p1 p2 / window p1 p2 / prompt "…"` | `.call("ssget", …)` ([ParserExpressions.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/ParserExpressions.swift) `parseSelectionExpression`) | `ssget "_I"` / `"_C"` / `"_W"` / prompt string | Host selection query; native returns `.list([.entity(…)])`. |
| `doorPoints {…}` `textSelect id "…" {…}` `normalizeAngle x` `drawDoorPanel …` `drawDoorArc …` | `.raw("")` (placeholder) | Discarded body — text is lost | **(defect)** Bodies are parsed and thrown away (Defect 2c). Native implementations exist in Swift (`withDoorPoints`, `normalizeAngle` in [AutoLISPHelpers.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPHelpers.swift)) but are not wired to the parser. |
| `yield` | last caller statement or `.raw("")` | Splices the macro caller’s block | Only valid inside a macro expansion. **(defect)** keeps only the last caller statement (Defect 2a). Native: splice the whole caller block. |
| `raw("…")` | `.call("raw", [.string])` | `(raw "…")` — invalid AutoLISP | **(defect)** Should emit the string verbatim (Defect 1). Native: no equivalent; use a typed host call. |
| bare `name(args)` | `.expr(.call(name, args))` | `(name args)` with name mapping (below) | Host call by name. |

### 4.1 Truthiness

Native (`isTruthy` in [FDInterpreter.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptRuntime/FDInterpreter.swift)): `nil` and `false` are falsy; **everything else is truthy**, including `0`, `""`, and empty lists. AutoLISP agrees (`nil` is the only false value) except that FDScript’s explicit `T`/`false` have no direct AutoLISP literal — the emitter renders `false` as `nil`.

---

## 5. Expressions

Source: [ParserExpressions.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/ParserExpressions.swift).

### 5.1 Grammar (precedence low → high)

```
comparison : additive ((">"|"<"|">="|"<="|"=="|"!=") additive)*
additive   : multiplicative (("+"|"-") multiplicative)*
multiplicative : unary (("*"|"/") unary)*
unary      : "-" unary | primary
primary    : number | string | nil | T | identifier [ "(" args ")" ]
           | "[" expr, … "]"          -- list literal
           | "(" expr ")"             -- grouping
           | "selection" mode …       -- ssget sugar
```

* No `and`/`or`/`not` infix operators — they are prefix *functions* (`and(a, b)`, `or(a, b)`, `not(x)`).
* No `if`/`cond` expressions — control flow is statement-level.
* No string concatenation — use `strcat(a, b)`.
* `nil`, `T`, and `T`-as-true are literals; every other bare identifier that is not a call is a **symbol reference**.

### 5.2 List literals

```fdscript
setq pt = [1, 2, 0]
setq p   = [pt, 5]   // nested list = polyline point stack
```

| Form | AutoLISP lowering | Native |
|---|---|---|
| `[1, 2, 0]` | `(list 1 2 0)` — **evaluating** form | `.list([.number(1), .number(2), .number(0)])` |
| `[]` | `'()` (quoted empty) | `.list([])` |
| `[POINT]` where `POINT` is a symbol | `(list POINT)` — **(defect)** evaluates `POINT` as a variable (Defect 5). Correct lowering is `'(POINT)` | `.list([.string/symbol POINT])` — data vs. reference must be distinguished at the AST level |

---

## 6. Builtins — the whole registry

Source: [Builtins.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/Builtins.swift) `FDBuiltinRegistry.functions` (141 names) + statement keywords. Every name is currently classified **AutoLISP-only**; `backends(for:)` returns `[.autolisp]` for everything — the `.runtime` case exists but is unused.

### 6.1 Name mapping (FDScript → AutoLISP)

From `mapFunctionName` / `emitCall` in [AutoLISPBackend.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPBackend.swift). Anything not listed passes through verbatim.

| FDScript | AutoLISP | Notes |
|---|---|---|
| `onePlus` / `oneMinus` | `1+` / `1-` | |
| `appendList` | `append` | |
| `type_` / `print_` / `exit_` / `quit_` | `type` / `print` / `exit` / `quit` | Trailing `_` avoids Swift keyword collisions |
| `bitNot` | `~` | |
| `vlaxEnameToVlaObject` | `vlax-ename->vla-object` | |
| `vlaxSafearrayToList` | `vlax-safearray->list` | |
| `vlaGetBoundingBox` | `vla-getboundingbox` | Note the exact casing |
| `vlCatchAllApply` | `vl-catch-all-apply` | |
| `getLocation(h)` | `(cdr (assoc 10 (entget h)))` | Special-cased inline |
| `==` / `!=` | `=` / `/=` | In binary-operator emitter |

**Unmapped names (Defect 4):** `vlStringToList`, `vlListToString`, `vlStringSearch`, `vlStringSubst`, and the file-IO family below emit verbatim and are invalid AutoLISP. Correct spellings would be `vl-string->list`, `open`, `read-line`, `write-line`, etc. (the Swift helpers in [AutoLISPFileIO.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPFileIO.swift) already use the right forms). A native runtime eliminates this class entirely — the host owns the name table.

### 6.2 Catalog by family

| Family | FDScript names | File(s) |
|---|---|---|
| Math | `abs atan cos sin exp expt fix float gcd log max min rem sqrt`, `onePlus oneMinus zerop minusp numberp`, `boole logand logior lsh bitNot` | [AutoLISPMath.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPMath.swift) |
| String | `strcat strlen substr strcase ascii chr itoa atof atoi rtos angtof angtos distof wcmatch snvalid`, `vlStringToList vlListToString vlStringSearch vlStringSubst` | [AutoLISPString.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPString.swift) |
| List | `list cons car cdr cadr caddr last length nth appendList reverse member assoc subst`, `vlSort vlRemove vlPosition vlEvery vlSome` | [AutoLISPList.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPList.swift) |
| Logic / eval | `and or not eq equal atom listp null boundp type_ eval set`, `lambda mapcar apply quote` | [AutoLISPOperators.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPOperators.swift), [AutoLISPMisc.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPMisc.swift) |
| Entity | `entlast entnext entdel entget entmod entmake entmakex entupd handent redraw regapp`, `textbox` | [AutoLISPEntity.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPEntity.swift) |
| Selection | `ssget ssadd ssdel sslength ssname ssmemb ssgetfirst sssetfirst` | [AutoLISPSelection.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPSelection.swift) |
| Tables / dict | `tblnext tblsearch tblobjname namedobjdict dictadd dictnext dictremove dictrename dictsearch`, `dictSet dictHas dictGet` | [AutoLISPTable.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPTable.swift), [AutoLISPDict.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPDict.swift) |
| File I/O | `fileOpen fileClose readLine readChar writeLine writeChar findfile load` | [AutoLISPFileIO.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPFileIO.swift) — **all unmapped (Defect 4)** |
| Input | `getint getreal getstring getdist getangle getcorner getkword getorient initget getfiled nentsel entsel getpoint` | [AutoLISPInput.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPInput.swift) |
| System | `getenv setenv ver exit_ quit_ gc mem`, `prompt prin1 print_ terpri alert` | [AutoLISPSystem.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPSystem.swift) |
| VLX / COM | `vlaxEnameToVlaObject vlaxSafearrayToList vlaGetBoundingBox vlCatchAllApply vlRegistryRead vlRegistryWrite` | mapped in §6.1 |
| Geometry | `trans cvunit osnap inters textbox` | [AutoLISPMisc.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPMisc.swift) |
| Command | `commandS initcommandversion initdia help` | |
| Dynamic symbol | `symName symRead symGet symSet symBound symClear set` | Special-cased in `emitCall`: `(set (read (strcat …)) value)` |
| Graphics (Swift API only, not in FDScript registry) | `grdraw grvecs grread grtext grclear graphscr textscr textpage menucmd menugroup tablet setview` | [AutoLISPGraphics.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPGraphics.swift) |

Dynamic-symbol natives (`dictSet`/`symSet` etc.) concatenate name parts with `strcat` + `read`, then `eval`/`set`/`boundp`. A native runtime replaces this with a `SymbolTable` host capability — no `read`/`eval` of constructed text.

---

## 7. Host contract — what “native” actually calls

Source: [FDHost.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptRuntime/FDHost.swift), [FDInterpreter.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptRuntime/FDInterpreter.swift).

```swift
protocol FDHost: Sendable {
    func call(_ name: String, _ args: [FDValue], env: inout FDEnvironment) async throws -> FDValue
}
```

The interpreter is async: every expression, every input request, every host call is `async throws`. The sketch protocols (`FDCADHost`, `FDIOHost`, `FDNetworkHost`) are aspirational — the shipped host protocol is a single stringly-typed `call`.

A native Zephyr host would implement `call` by dispatching on the §6.2 names to structured CAD operations:

| Host name | Native operation |
|---|---|
| `getpoint` | Suspend until the user picks; return `.point` or `.nilValue` on cancel. |
| `entsel` | Pick-one; return `.entity(handle)` or `.nilValue`. |
| `ssget` | Selection query (`_I`/`_C`/`_W`/filter); return `.list([.entity])`. |
| `entmake` / `entmod` / `entget` | Create / modify / read an entity via structured properties, not DXF lists. |
| `setvar` / `getvar` (via `getvar` call) | Sysvar read/write with type checking. |
| `command` | Dispatch to the command router; result is the command’s return value. |
| math / string / list | Pure computation in the interpreter or host — no CAD round-trip. |

The Swift result-builder API ([LispCore.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/LispCore.swift), [LispBlock.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/LispBlock.swift), [LispControlFlow.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/LispControlFlow.swift), [LispCommands.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/LispCommands.swift)) is the *other* DSL in the tree: Swift code that renders AutoLISP `LispNode`s. Natively, those same builders would render `FDValue` operations instead of strings — the node protocol is already backend-agnostic in shape (`render(environment:)`), only the output format changes.

---

## 8. Worked examples — three columns

### 8.1 Arithmetic + locals

```fdscript
command SUM {
  setq a = 3
  setq b = 4
  setq s = a + b * 2
  princ(s)
}
```

| | Text |
|---|---|
| FDScript | above |
| AutoLISP (emitted) | `(defun c:SUM ( / a b s) (vl-load-com) (setq a 3) (setq b 4) (setq s (+ a (* b 2))) (princ s) (princ))` |
| Native | `a := 3; b := 4; s := a + b*2; host.princ(s)` — `a/b/s` live in the command frame; no `/` list, no `vl-load-com`. |

### 8.2 Interactive point + branch

```fdscript
command DOOR {
  setup
  ifLet hinge = point "Click hinge" {
    ifLet latch = point "Click latch" base hinge {
      princ("Swing from hinge")
    } else { princ("cancelled") }
  } else { princ("cancelled") }
  restore
}
```

| | Text |
|---|---|
| AutoLISP (emitted) | `(if (setq hinge (getpoint "\nClick hinge")) (if (setq latch (getpoint hinge "\nClick latch")) …))` wrapped in `(progn …)` branches; `setup`/`restore` expand to the OSMODE/CMDECHO/`*error*` boilerplate |
| Native | `host.awaitPoint(prompt: "Click hinge") → hinge` (suspends; `nil` if Esc) → branch on truthiness → `host.awaitPoint(prompt: "Click latch", base: hinge)` → … `setup`/`restore` = checkpoint guard. |

### 8.3 Entity creation (the biggest native win)

```fdscript
command LINE2 {
  ifLet p1 = point "first" {
    ifLet p2 = point "second" base p1 {
      entmake([0, "LINE", 8, "0", 10, p1, 11, p2])
    }
  }
}
```

| | Text |
|---|---|
| FDScript | above — note `[0, "LINE", …]` is a *list literal*, so it emits `(list 0 "LINE" …)` and `entmake` receives an evaluated list |
| AutoLISP (emitted) | `(entmake (list 0 "LINE" 8 "0" 10 p1 11 p2))` — correct by accident: points are already lists |
| Native | `host.entityCreate(type: .line, layer: "0", start: p1, end: p2)` — group codes, `assoc`/`entget` round-trips, and the `cdr(assoc 10 …)` pattern (`getLocation`) disappear. The `[0, "LINE", …]` idiom is replaced by named arguments. |

### 8.4 Loop over a selection

```fdscript
command HIGHLIGHT {
  setq ss = selection implied
  foreach e in ss {
    commandS("_.HIGHLIGHT", e, "")
  }
}
```

Native: `let ss = try await host.selection(.implied)` → `for e in ss { try await host.runCommand("HIGHLIGHT", args: [e]) }`. `commandS` → `_` prefix tokens are gone.

### 8.5 Door helpers (currently broken — shown for contrast)

```fdscript
command DOOR2 {
  doorPoints {
    setq dWidth = 36
  }
}
```

| Lane | Result |
|---|---|
| FDScript parse | `.raw("")` — body discarded ([ParserStatements.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptCore/ParserStatements.swift)) |
| AutoLISP emitted | Nothing (empty placeholder) — **Defect 2c** |
| Native | Would call `host.doorPoints(width: 36)` answering prompts for hinge/latch/swing ([AutoLISPDoor.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptBackends/AutoLISPDoor.swift) `withDoorPoints`). |

---

## 9. Known gaps a native runtime must close

From [FDEmitterDefectPins.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Tests/FDScriptTests/FDEmitterDefectPins.swift) — each is a place where the text pipeline loses information that a native interpreter keeps:

1. **`raw("…")`** emits `(raw "…")` instead of the verbatim string. Native: delete `raw`, keep `rawTop` as the only escape — or remove both.
2. **Macros** (`macro`/`yield`/`parseMacroCall`) keep only the last expanded statement. Native: macro expansion must produce a statement *list*.
3. **`doorPoints` et al.** discard their bodies. Native: implement as host operations; the Swift versions already exist.
4. **Branch locals** (`while`/`cond` branches, `if` branches via `emitBranch` with a fresh environment) are missing from `defun` `/` locals and leak to globals. Native: real lexical frames remove the `/`-list synthesis entirely.
5. **Name mapping** leaves `vl*` and file-IO names unmapped. Native: host owns the table; FDScript names need not mirror AutoLISP spellings at all.
6. **Symbol lists** (`[POINT]`) emit the evaluating `(list POINT)` form. Native: distinguish quoted data from evaluated lists in the AST (a `.quotedList` case or a quote marker).
7. **`return`** does not exit early; **`setup`/`restore`** and **`raw`** are no-ops in the interpreter. Native: `return` = throw `Return`; `setup`/`restore` = checkpoint guard; `raw` = parse error.

---

## 10. How to read this doc

* **Writing native Zephyr commands today:** write FDScript (§3–§6), compile with `AutoLISPBackend`, load the `.lsp` — the doc’s §6.1/§6.2 tables tell you exactly which spellings are safe (avoid `vlString*`, `fileOpen` family) and §4 tells you which constructs are silently broken (multi-statement macros, `doorPoints`, `raw`).
* **Building the native runtime:** the parser/AST (§2–§5) are frozen — implement [FDHost](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptRuntime/FDHost.swift) against `CADDocument` and run [FDInterpreter](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Sources/FieldDraftScriptRuntime/FDInterpreter.swift) directly. Start with the §7 table, then §8.3’s structured-entity form.
* **Verifying:** [FDEmitterDefectPins.swift](file:///Users/josephmontanez/Documents/dev/zephyr/Engine/EngineAsBuilt/Tests/FDScriptTests/FDEmitterDefectPins.swift) is the current contract — flip each `KnownDefect` test when the corresponding native behavior lands.
