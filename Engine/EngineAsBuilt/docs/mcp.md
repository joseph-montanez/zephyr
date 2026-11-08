# Zephyr MCP — AI-driven CAD in the live app

The live app can host an MCP server for AI-driven CAD work: the agent
creates geometry with AutoLISP, sees deterministic thumbnails back, and
iterates — all against the running drawing. No GPU scraping, no synthetic
mouse input.

## 1. Start the app server

Build once, then run with `--mcp-port` (any free localhost port; the
client configs below all use `17813`):

```powershell
swift build --configuration debug
.build\debug\Zephyr.exe --mcp-port 17813
```

Or via `swift run` (arguments after the executable name reach the app):

```powershell
swift run --configuration debug Zephyr -- --mcp-port 17813
```

Without the flag the server stays off and the app behaves exactly as
before. Check health independently of any client:

```powershell
curl http://127.0.0.1:17813/health
```

The server binds **localhost only** and exposes `POST /mcp` (plain
JSON-RPC 2.0) plus `GET /health`. There is no auth — anyone on the
machine can drive the drawing, which is the point for a local agent.

## 2. Attach a client

The repo ships project-scoped configs; all launch the same
[bridge](C:\dev\zephyr\Engine\EngineAsBuilt\Tools\mcp-bridge.py)
(`Tools/mcp-bridge.py`), which translates client stdio to `POST /mcp`.
The app **must already be running** with the matching `--mcp-port`
before the client connects.

| Client | Config (committed) | Notes |
|---|---|---|
| Claude Code | [.mcp.json](C:\dev\zephyr\Engine\EngineAsBuilt\.mcp.json) | Auto-picked up in this project; approve on first use (`/mcp` or `reset-project-choices` to re-prompt). |
| Pi agent | [.pi/mcp.json](C:\dev\zephyr\Engine\EngineAsBuilt\.pi\mcp.json) | Written by `pi mcp add -l zephyr -- python Tools/mcp-bridge.py --port 17813`. Trust the project when pi prompts, then `pi mcp list` should show `zephyr`. |
| OpenCode | [opencode.json](C:\dev\zephyr\Engine\EngineAsBuilt\opencode.json) | v2 shape (`mcp.servers.<name>`, `type: "local"`). Plain JSON; OpenCode also accepts `.jsonc`. |
| Cursor | [.cursor/mcp.json](C:\dev\zephyr\Engine\EngineAsBuilt\.cursor\mcp.json) | Enable the server under Cursor Settings → MCP. |
| VS Code | [.vscode/mcp.json](C:\dev\zephyr\Engine\EngineAsBuilt\.vscode\mcp.json) | Uses the `servers` key (not `mcpServers`) with `type: "stdio"`. VS Code also reads root `.mcp.json`. |

Changing the port? Pass `--port` to the bridge and `--mcp-port` to the
app with the same value, in every config you use.

### Muse (Meta) — user-global config

Muse reads `mcp_servers` from its own settings file
(`%USERPROFILE%\.config\muse\settings.json`), not from the repo, so
this one is a manual entry rather than a committed file. It speaks
stdio to the same bridge:

```json
{ "mcp_servers": {
    "zephyr": { "transport": "stdio",
                "command": "python",
                "args": ["C:\\dev\\zephyr\\Engine\\EngineAsBuilt\\Tools\\mcp-bridge.py",
                         "--port", "17813"],
                "framing": "content_length",
                "enabled": true,
                "mode": "optional" }
} }
```

`framing: content_length` matches the bridge's LSP-style framing
exactly. `mode: optional` keeps a down app from aborting the whole
run — Muse skips the server with a warning instead. Run `/mcp` in an
interactive session for a live inventory of connected servers.
Takes effect on the next Muse launch. (`muse mcp login/logout`
covers OAuth for remote servers only; it is unrelated to this entry.)

## 3. The agent loop

Tools (see `tools/list`): `eval_lisp`, `load_lsp`, `run_command`,
`provide_input`, `cancel_eval`, `doc_summary`, `batch_summary`,
`set_camera_bounds`, `zoom_extents`, `thumbnail`, `load_reference`.

Recommended floor-plan loop:

1. `load_reference` with the plan PNG **and explicit world bounds**
   (`min_x/min_y/max_x/max_y`). This also pins the vision frustum on
   turn 1 when no camera is set.
2. `eval_lisp` / `run_command` to create geometry
   (e.g. `(entmake '((0 . "LINE") (10 1 2 0) (11 3 4 0)))`).
3. `thumbnail` (or cheap `batch_summary` first: same checksums tell
   whether anything actually mutated before spending vision tokens).
4. Compare, fix, repeat. Use `provide_input` the moment a call
   returns `waiting_for_input` — interactive prompts (`getpoint`,
   `pause` in `(command ...)`) park instead of failing.

Rules that keep the loop aligned:

- The frustum stays pinned until changed. Prefer `set_camera_bounds`
  once; `zoom_extents` is a recovery tool, not a per-turn call —
  reframing mid-loop shifts world-to-pixel scale and breaks visual
  diffing.
- Only one evaluation runs at a time (same single-flight guard as the
  command line). A second `eval_lisp` is rejected until the first
  completes, waits, or is cancelled via `cancel_eval`.
- Reference overlay + grid ticks share the thumbnail's coordinate
  space: pixel error maps to CAD units through the tick labels, and
  the echoed `frustum`/`pixelsPerUnit` in every response is the
  ground truth.

## 4. Troubleshooting

- **Client shows connection refused / bridge error**: the app isn't
  running with `--mcp-port`, or the ports differ. Start the app
  first — unlike headless MCP servers, there is no app to
  auto-launch.
- **`waiting_for_input` never resolves**: answer it with
  `provide_input` (`{"text": ""}` is Enter; `{"point": [x, y]}` picks).
  A second prompt usually follows — keep answering until `completed`.
- **`evaluation already running`**: a ribbon load or command-line
  Lisp run owns the session; wait or `cancel_eval`.
- **Thumbnail looks stale after an edit**: the server retries
  freshness for ~2 s (`fresh: true` in the response). On huge
  regenerations, call `batch_summary` until the checksums settle,
  then `thumbnail`.
- **`load_reference` rejected**: only 8-bit RGB/RGBA non-interlaced
  PNGs are accepted. Re-export the reference (most exporters and
  screenshots already qualify).
- **Port already in use**: the app prints `MCP server failed to
  start...` and keeps running without MCP. Pick another port and
  mirror it in the client config.
