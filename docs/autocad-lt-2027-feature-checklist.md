# AutoCAD LT 2027 — Complete Feature Checklist (Zephyr evaluation)

 **Strong areas found**

 Core 2D draw/modify, layers (VP overrides, filters, states), blocks/attributes, dimensions/leaders, xrefs/images/PDF
 references, page setup/PDF output, sheet sets, and AutoLISP (305 builtins, SCRIPT, aliases, LISP-defined ribbon).

 **Largest gaps**

 REGION booleans, WIPEOUT, TOLERANCE, QDIM, dynamic/Smart Blocks, xref compare, Trace/Count/DWG Compare,
 cloud/Forma services, DCL/reactors/VLA, and all 3D functionality.

A parity audit of **Zephyr** against **AutoCAD LT 2027** (Windows), not full AutoCAD.

**Result at a glance (2026-11-15):** 233 of 766 workflow items present (30%), 191 partial, 308 missing, 34 N/A. Commands: 142 implemented, 69 partial, 297 missing. System variables: 103 supported of 644.

- **Baseline:** AutoCAD LT 2027 (R26.0) and its 2027.1.x updates, as documented in the AutoCAD LT 2027 Help. Recent additions are tagged `(2024+)`, `(2025+)`, `(2026+)`, `(2027)`, `(2027.1)`.
- **Why this matters:** LT is deliberately a 2D product. It has no 3D modeler, no industry toolsets, no VBA/.NET/ObjectARX, no Action Recorder, no Data Extraction, no CAD Standards, and no Express Tools. Appendix C lists what LT does **not** have so you do not chase features that were never in scope.
- **Coverage:** 766 workflow checklist items, 508 commands (485 from the LT Help command-category pages + 23 supplemental), and 644 system variables. The workflow sections are the primary audit; Appendices A and B cover the long tail.
- **Sources:** AutoCAD LT 2027 Help (Command Reference, User's Guide, Customization Guide, AutoLISP Guide), *What's New in AutoCAD LT 2024–2027*, and *About Working With AutoCAD Drawings in AutoCAD LT*. See Appendix F.
- **Windows build:** this checklist covers AutoCAD LT 2027 for Windows. AutoCAD LT for Mac exists but is a separate, reduced build with its own limitations; do not use it to fill gaps in the Windows list.

## How to use this checklist

Legend for the marks (already applied below):

- `[x]` implemented in Zephyr and behaves equivalently
- `[~]` partial / different workflow / limited
- `[ ]` not implemented in Zephyr (after source/README review)
- `[-]` not applicable: Autodesk account/cloud service, LT-only limitation, or intentionally out of scope

**Evaluation basis:** README, CHANGELOG, command registry/alias table, and source inspection on 2026-11-15. The checklist is a documentation audit, not a runtime conformance test; `[~]` marks a different or reduced workflow. Because items are fine-grained, a `[~]` often means the core command exists while several options/paths are missing. Section summaries count the checkboxes below each heading.

Add short notes after the em dash. Items marked **(LT: …)** describe a behavior or limitation specific to AutoCAD LT; do not assume full AutoCAD behavior.

> Tip: Appendix A is a command-by-command checklist (485 unique commands from 97 Help areas, plus 23 supplemental core commands = 508). Appendix B lists the 644 LT system variables. Use them for the long tail after the workflow sections.

## Evaluation summary (Zephyr vs. AutoCAD LT 2027)

| Area | Present | Partial | Missing | N/A |
|---|---:|---:|---:|---:|
| 0. Scope/product | 4 | 4 | 2 | 5 |
| 1. Installation/environment | 3 | 8 | 9 | 6 |
| 2. User interface | 16 | 19 | 24 | 1 |
| 3. Drawing files/formats | 13 | 15 | 24 | 1 |
| 4. Views/display | 14 | 12 | 10 | 0 |
| 5. Drafting aids | 17 | 9 | 17 | 0 |
| 6. 2D geometry | 15 | 10 | 14 | 0 |
| 7. Parametrics | 4 | 5 | 3 | 0 |
| 8. Select/modify | 38 | 14 | 15 | 0 |
| 9. Layers/properties | 21 | 8 | 6 | 2 |
| 10. Text/fields/tables | 5 | 12 | 16 | 0 |
| 11. Dimensions/leaders | 25 | 11 | 10 | 0 |
| 12. Revision/annotation | 2 | 0 | 6 | 0 |
| 13. Blocks | 11 | 10 | 26 | 0 |
| 14. Xrefs/underlays | 17 | 13 | 23 | 0 |
| 15. Layouts/plot/publish | 14 | 23 | 14 | 3 |
| 16. Collaboration | 0 | 1 | 31 | 15 |
| 17. 3D | 0 | 0 | 19 | 0 |
| 18. Customization/AutoLISP | 9 | 9 | 33 | 0 |
| 19. Performance/security | 5 | 8 | 6 | 1 |
| **Total (workflow)** | **233** | **191** | **308** | **34** |
| Appendix A — commands | 142 | 69 | 297 | 0 |
| Appendix B — system variables | 103 | — | 541 | — |

**Largest functional gaps:** `REGION` booleans, `WIPEOUT`, `TOLERANCE`, `QDIM`, dynamic blocks/Smart Blocks, xref compare, Trace/Count/DWG Compare, cloud/Forma services, DCL/reactors/VLA, and all 3D features. The app is strongest in core 2D drawing/modify, layers, blocks/attributes, dimensions/leaders, xrefs, page setup/PDF output, sheet sets and AutoLISP.

**Zephyr-only or Zephyr-stronger areas (not LT checklist items):** native EAB format with zstd/BVH partial loads, cross-platform macOS/Windows/Linux builds, MCP server for AI control, `PENSTROKE`, `MLINE`/`MLSTYLE`, `TORIENT`, split panes/floating OS windows, the AutoLISP-defined ribbon, and the three GPU backends (Metal/D3D12/Vulkan).

## Contents

0. Scope, product identity and compatibility
1. Installation, environment and program settings
2. User interface and workspace
3. Drawing files, formats and recovery
4. Views, navigation and display
5. Drafting aids and precision
6. Creating 2D geometry
7. Parametric constraints (LT-limited)
8. Selecting and modifying objects
9. Layers, properties and display styles
10. Text, fields and tables
11. Dimensions, leaders and tolerances
12. Revision clouds, wipeouts and annotation utilities
13. Blocks and attributes
14. External references, underlays, images and embedded data
15. Layouts, viewports, plotting and publishing
16. Collaboration, cloud and review
17. 3D viewing and wireframe (LT-limited)
18. Customization and automation
19. Performance, reliability and security
20. Quick reference: what LT is and is not (not a Zephyr score)

Appendices: A. Commands · B. System variables · C. Explicitly not in LT · D. LT vs. full AutoCAD · E. Reference tables · F. Sources

---

## 0. Scope, product identity and compatibility

> **Zephyr evaluation (15 items):** 4 present · 4 partial · 2 missing · 5 N/A.
> DWG is handled through the ODA FileConverter (not native); no DWT templates or proxy graphics. DXF/EAB are native.

- [x] **2D drafting and documentation focus** — the product's primary purpose and default workflows.
- [~] **Native DWG** — reads and writes DWG without translation; no intermediate format.
- [ ] **TrustedDWG** — Autodesk's DWG integrity/compatibility marker on save and open.
- [~] **Full DWG compatibility with AutoCAD** — drawings round-trip; unsupported objects stay as proxy/graphics.
- [~] **Open AutoCAD-created drawings that contain unsupported features** — 3D solids, surfaces, meshes, point clouds, constraints, dynamic blocks, annotative objects, etc. are preserved and displayable.
- [~] **Save in the current DWG format and older DWG formats** — `SAVEAS` format list.
- [x] **Read/write DXF** — ASCII and binary options where offered by `DXFOUT`/`SAVEAS`.
- [ ] **Drawing templates (DWT)** — default template, `QNEW`, `STARTUP`/`STARTMODE`, Start tab templates.
- [x] **Multi-document interface (MDI)** — several drawings open at once, each in its own document window.
- [x] **No dependency on full AutoCAD** — LT is a standalone product, not a mode of AutoCAD.
- [-] **Subscription product** — named-user sign-in, updates through Autodesk Access, offline grace period.
- [-] **Companion web and mobile access** — included with the subscription; desktop `OPENFROMWEBMOBILE`/`SAVETOWEBMOBILE` were **removed in 2027** (use Forma Data Management instead).
- [-] **No industry toolsets** — Architecture, Mechanical, Electrical, MEP, Plant 3D, Map 3D, Raster Design are not included.
- [-] **No 3D modeling, rendering or animation** — see §17 and Appendix C.
- [-] **No full-AutoCAD automation APIs** — no VBA, .NET, ObjectARX or JavaScript API; AutoLISP **is** included (see §18).

---

## 1. Installation, environment and program settings

> **Zephyr evaluation (26 items):** 3 present · 8 partial · 9 missing · 6 N/A.
> Cross-platform app (Windows/macOS/Linux) with portable builds; no Autodesk account services. Autosave and hardware GPU rendering exist; no full Options dialog.

### 1.1 Installation and deployment

- [~] **Windows installer** — typical/custom install, optional components, per-machine deployment.
- [x] **64-bit Windows 10/11 support** — check the current system requirements for CPU, RAM, GPU and disk.
- [~] **Side-by-side installation** with other AutoCAD releases.
- [ ] **Language packs** — install/switch UI languages.
- [ ] **Migration of custom settings** from previous releases.
- [~] **Export/import custom settings** (same release) and **reset to defaults**.
- [ ] **Profiles (`.arg`)** — save, restore and switch program profiles.
- [-] **User profile dialog** `(2027)` — self-identified industry/job role in the Autodesk account profile.
- [-] **Autodesk Access / updates** — update notifications and installation; smart update of web-based features `(2027.1)`.
- [ ] **Silent/scripted install and command-line startup switches** — see Appendix E.
- [ ] **Digitizing tablet support** — `TABLET` calibration/configuration (legacy hardware).
- [x] **Multiple monitors and mixed DPI** — palettes, toolbars and dialogs can live on a second screen.

### 1.2 Files, support paths and trust

- [~] **Options dialog** — Files, Display, Open and Save, Plot and Publish, System, User Preferences, Drafting, Selection, Profiles, Online.
- [~] **Support File Search Path** — fonts, menus, AutoLISP, linetypes, hatch patterns; the `/s` startup switch accepts up to 15 folders.
- [ ] **Trusted locations** — `TRUSTEDPATHS`, including `\..` wildcard for all subfolders `(2027.1)`.
- [ ] **Secure load** — `SECURELOAD`, executable-file restrictions, `/safemode`.
- [-] **Connected Support Files** `(2026+)` — one shared support-file set per Autodesk project on Forma Data Management; tool palettes and partial CUIx can be shared.
- [~] **Customization file locations** — main/enterprise/partial CUIx, roamer vs. local.
- [~] **Temporary file locations** — autosave, xref copies, Activity Insights logs, plot logs.
- [ ] **Printer/plotter support paths** — PC3, PMP, CTB/STB.
- [x] **Hardware acceleration** — on/off, `GRAPHICSCONFIG`, graphics diagnostics `(2025+)`, font display acceleration `(2025+)`, `/nohardware` startup switch.
- [~] **Memory/graphics tuning** — cache sizes, tessellation, view transitions.

### 1.3 Licensing and scope limits

- [-] **Named-user subscription licensing** — sign-in and entitlement checks.
- [ ] **Offline use** within the subscription grace period.
- [-] **No toolsets, no 3D modeler, no rendering** — enforced by product scope, not by a switch.
- [-] **No full AutoCAD APIs** — see the API matrix in Appendix E.

---

## 2. User interface and workspace

> **Zephyr evaluation (60 items):** 16 present · 19 partial · 24 missing · 1 N/A.
> Ribbon (AutoLISP-defined), classic menu bar, command palette, Properties/Layers/Blocks/Xrefs/Sheet Set panels. No Start tab, QAT, toolbars, workspaces, Quick Properties, Tool Palettes, DesignCenter or QuickCalc.

### 2.1 Start tab and application menu

- [ ] **Start tab** — recent files, pinned files, templates, search/sort, cloud storage, new/open.
- [~] **Recent-documents list** — Start tab and application menu, with previews.
- [ ] **Pinned/recent files** and remove-from-list.
- [ ] **Document previews** — preview display for open documents and layouts.
- [~] **Application menu** — New, Open, Save, Save As, Export, Print, Publish, Drawing Utilities, Close, Options, Exit; recent/open document lists.
- [ ] **File tab menu** `(2024+)` — new/open, save all, close all, switch drawings.
- [~] **Layout tab menu** `(2024+)` — new layout, from template, publish, switch layouts.
- [-] **My Insights** — **not available in LT**.

### 2.2 Ribbon, toolbars and menus

- [x] **Ribbon** — tabs, panels, slide-outs, dialog launchers, galleries.
- [x] **Ribbon placement** — dock top/bottom/left/right, undock/floating, second monitor.
- [~] **Ribbon display states** — full, minimal, collapsed; show/hide tabs and panels from the shortcut menu.
- [ ] **Floating and pinned panels** — pull a panel off the ribbon; pin a slide-out open.
- [ ] **Contextual ribbon tabs** — appear for selected objects/commands (hatch, table, block, mtext, etc.).
- [~] **Ribbon customization** — customize tabs/panels/commands from the UI or CUI; tool-palette-group association; convert toolbars to panels.
- [~] **Default ribbon tabs** — Home, Insert, Annotate, Parametric, View, Manage, Output, Collaborate, plus contextual tabs (the visible set depends on workspace/customization).
- [ ] **Quick Access Toolbar (QAT)** — customize, show below/above ribbon, add commands.
- [x] **Classic menu bar** — optional display, legacy menu access.
- [ ] **Toolbars** — classic docked/floating toolbars, show/hide, customize, lock UI.
- [~] **Tooltips and extended tooltips** — ribbon/toolbar tooltips, rollover tooltips for objects, property preview.
- [ ] **Keytips and access keys** — Alt-key navigation of the UI.
- [~] **Cursor badges and crosshair** — cursor badge toggle, crosshair size, pickbox size, cursor type.
- [~] **Workspaces** — switch, save, customize; default *2D Drafting & Annotation* and *AutoCAD Classic*; workspace label `(status bar)`.
- [x] **Status bar** — coordinate readout, model/paper toggle, drafting toggles, annotation scale/viewport tools, workspace switcher, lock UI, graphics performance, clean screen, tray settings, customization.
- [x] **Clean screen** — `CLEANSCREENON`/`OFF`, hide palettes/ribbon/tabs, restore.
- [ ] **Lock UI** — lock position/size of toolbars and dockable windows.

### 2.3 Palettes and dockable windows

- [x] **Properties palette** — object properties, by-layer/by-block, quick select, value editing.
- [ ] **Quick Properties** — on-selection mini palette; customize which properties appear.
- [x] **Layer Properties Manager** — full layer table and filters (also §9.1).
- [x] **Layer States Manager** — save/restore/edit layer states.
- [x] **Blocks palette** — current drawing, recent, favorites, libraries; insert and drag-and-drop.
- [x] **External References palette** — xref tree, status, paths, reload/unload, attach.
- [x] **Sheet Set Manager** — sheet sets, sheets, views, publish/transmit (also §15.3).
- [ ] **Markup Set Manager** — DWF/DWFx markups (also §16.4).
- [ ] **Traces palette** — trace list, create/open, show/hide, comments (also §16.1).
- [ ] **Activity Insights palette** — version/activity history (also §16.3).
- [ ] **Parameters Manager** — dimensional constraint parameters and user variables (LT: view/edit values only).
- [ ] **Tool Palettes** — tool palette window, groups, properties, customize.
- [ ] **DesignCenter** — folders, open drawings, blocks, layers, styles, layouts, xrefs; favorites.
- [ ] **QuickCalc** — calculator palette.
- [ ] **Data Link Manager** — manage table data links.
- [ ] **Plot/Publish details** — `VIEWPLOTDETAILS`.
- [~] **Palette behavior** — dock/undock, auto-hide, transparency, size, lock, show/hide all (`HIDEPALETTES`/`SHOWPALETTES`).
- [~] **Palette appearance** — light/dark theme, palette transparency, font/color settings.

### 2.4 Command line, dynamic input and keyboard

- [x] **Command window** — docked/floating, history, multiple lines, font/colors, transparency.
- [~] **Command history** — `F2` expanded history, text window, `LOGFILEON/OFF`, `COPYHIST`.
- [x] **AutoComplete** — command/system-variable/named-object suggestions while typing.
- [~] **AutoCorrect and synonyms** — typo correction and command synonyms.
- [~] **Input search** — search commands, system variables, named objects; `INPUTSEARCHOPTIONS`.
- [ ] **Transparent commands** — apostrophe-prefixed commands during another command.
- [x] **Command aliases** — `acadlt.pgp` alias table; edit/reload.
- [ ] **External commands** — define OS commands in the PGP file.
- [~] **Command preview** — preview of modify commands before committing.
- [x] **Multiple/repeat** — `MULTIPLE`, repeat last command, space/Enter behavior.
- [~] **Undo inside commands** — `U`/`UNDO` options and command-level undo.
- [ ] **Dynamic input** — pointer input, dimension input, dynamic prompts, tooltips; `DSETTINGS`, `F12`.
- [x] **Coordinate/status readout** — cursor coordinates and unit display on the status bar.
- [~] **Function keys** — `F1`–`F12`; `F4` (3D object snap) and `F6` (dynamic UCS) are **not available in LT**; `F8`/`F10` are mutually exclusive. See Appendix E.
- [~] **Keyboard shortcuts** — Ctrl/Alt/Shift combinations; customizable in CUI.
- [~] **Shortcut menus** — default/edit/command modes, right-click duration, customization.
- [ ] **Command-line startup switches** — `/b`, `/t`, `/c`, `/s`, `/set`, `/v`, `/w`, `/pl`, `/nologo`, `/nossm`, `/nohardware`, `/safemode`. See Appendix E.

---

## 3. Drawing files, formats and recovery

> **Zephyr evaluation (53 items):** 13 present · 15 partial · 24 missing · 1 N/A.
> DXF + DWG (ODA) + EAB; PDF export/import. Autosave exists. No .bak, DWT, partial open, eTransmit, digital signatures or drawing recovery manager.

### 3.1 Creating, opening and saving

- [x] **New drawing** — `NEW`, `QNEW`, from template, Start tab.
- [x] **Open** — `OPEN`, file dialog, recent files, drag-and-drop, open from cloud storage.
- [ ] **Open partial drawings** — `PARTIALOPEN` (open selected views/layers).
- [x] **Save** — `QSAVE`, `SAVEAS`, save all, save a copy.
- [~] **Save as older DWG version** — compatibility formats offered by `SAVEAS`.
- [x] **DXF import/export** — `DXFOUT`/`DXFIN` options, ASCII/binary.
- [x] **Automatic save** — `SAVETIME`, `.sv$` files, `SAVEFILE`, `SAVEFILEPATH`.
- [ ] **Backup files** — `.bak`, `ISAVEBAK`.
- [~] **Incremental vs. full save** — `ISAVEPERCENT`; `SAVEAS` performs a full save `(2027)`.
- [ ] **Thumbnails** — `THUMBSAVE`, update thumbnails, preview in Open/Start tab.
- [ ] **Annotative visual fidelity** — `SAVEFIDELITY`.
- [ ] **Large-object limits / legacy compatibility** — save settings for large coordinates/objects.
- [ ] **Drawing properties** — `DWGPROPS`, standard and custom properties, statistics, summary.
- [x] **Units and insertion scale** — `UNITS`, `INSUNITS`, source/target defaults, block/image/xref scaling.
- [x] **Close/quit** — `CLOSE`, `QUIT`, save prompts, multiple-document close.

### 3.2 Finding, previewing and transferring

- [~] **File navigation and search** — search for drawings from the Open dialog.
- [ ] **Quick view drawings/layouts** — `QVDRAWING`, `QVLAYOUT` and close variants.
- [ ] **Taskbar previews** — `TASKBAR`, Windows thumbnail behavior.
- [~] **Window arrangement** — `SYSWINDOWS`.
- [x] **Copy between drawings** — clipboard, `COPYBASE`/`PASTECLIP`, `PASTEORIG`, `PASTEBLOCK`.
- [x] **WBLOCK** — write selected objects or a block to a new DWG.
- [x] **BASE** — insertion base point for the current drawing.
- [~] **eTransmit** — package drawings with dependencies; folder or ZIP; sheet-set transmittal; saved transmittal setups.
- [ ] **Archive a sheet set** — `ARCHIVE`.
- [ ] **Cloud storage** — Forma Data Management, OneDrive, Dropbox, Box, Google Drive; open/save, share URL `(2025.1+)`.
- [ ] **Share a link** — `SHARE` for Forma Data Management drawings `(2025.1+)`.
- [ ] **Save to/open from Web & Mobile** — **removed in 2027** (`SAVETOWEBMOBILE`/`OPENFROMWEBMOBILE`).

### 3.3 Repair, recovery and integrity

- [x] **AUDIT** — check and fix drawing database errors.
- [x] **RECOVER** — open and repair a damaged drawing.
- [ ] **RECOVERALL** — repair the drawing and all attached xrefs.
- [ ] **Drawing Recovery Manager** — `DRAWINGRECOVERY` after a crash/power failure; backup and autosave restoration.
- [ ] **Backup restore** — `.bak`/`.sv$` workflow.
- [~] **Proxy objects** — display/edit proxy graphics; object enablers for AutoCAD verticals.
- [x] **Unreconciled layers** — notification and reconcile workflow.
- [~] **Xref/data-link/layer notifications** — status-bar warnings.
- [ ] **Digital signatures** — `DIGITALSIGN` for DWG/DWT, signature validation, timestamps, digital IDs (also §19).
- [-] **Password protection** — **not available**: drawing passwords were removed in the 2016-based releases; use PDF/zip/OS/cloud permissions.
- [ ] **Malicious-code recovery** — `SECURELOAD`, trusted paths, `/safemode`, recovery guidance.

### 3.4 Interoperability formats (summary)

- [~] **DWG / DWT / DXF** — native read/write.
- [~] **PDF** — attach as underlay, import geometry/text, export/plot; searchable text via `PDFSHX`.
- [ ] **DWF/DWFx** — attach, publish, markup sets.
- [ ] **DGN** — import, export, attach as underlay; DGN linetypes; bind.
- [ ] **WMF** — import and export.
- [~] **Raster** — attach (BMP, JPG, PNG, TIF, GIF and others supported by the image engine); export BMP/JPG/PNG/TIF.
- [ ] **OLE** — embed/link objects from other Windows applications.
- [ ] **CSV/TXT** — table export (`TABLEEXPORT`), attribute extraction (`ATTEXT`), data links.
- [ ] **XLS/XLSX** — table data links (via Data Link Manager).
- [~] **SLD/SCR** — slides and scripts.
- [~] **LIN/PAT/SHX/TTF/OTF** — linetypes, hatch patterns, shapes/fonts, text fonts.
- [~] **CTB/STB/PC3/PMP** — plot styles and plotter configurations.
- [~] **CUIx/ARG/DST** — customization, profiles, sheet sets.
- [~] **ZIP** — transmittal packages.
- [ ] **Excel/CSV data links** — update direction and notification (also §10.3).

---

## 4. Views, navigation and display

> **Zephyr evaluation (36 items):** 14 present · 12 partial · 10 missing · 0 N/A.

### 4.1 2D navigation

- [x] **Zoom** — real-time, window, previous, extents, all, object, in/out, scale, center, dynamic.
- [x] **Pan** — real-time, point-to-point, with the navigation bar.
- [~] **Zoom wheel behavior** — `ZOOMFACTOR`.
- [ ] **Smooth view transitions** — `VTOPTIONS`, `VTENABLE`, `VTDURATION`, `VTFPS`.
- [~] **Navigation bar** — pan, zoom tools, 2D SteeringWheel, 3Dconnexion in 2D mode.
- [ ] **SteeringWheels** — 2D wheel; `NAVSWHEEL`.
- [ ] **3Dconnexion support** — 2D navigation mode.
- [ ] **ViewCube / ShowMotion / 3D orbit / walk / fly** — **not available in LT**.
- [x] **Clean screen / hide palettes** — maximize drawing area.
- [x] **Regen / redraw** — `REGEN`, `REGENALL`, `REDRAW`, `VIEWRES`.

### 4.2 Named views and viewports

- [~] **Named views** — `VIEW`/`NEWVIEW`, save/restore/delete, model and layout views.
- [~] **View dialog/manager** — named views, preset views, orthographic/isometric views.
- [ ] **View categories** — sheet-set view categories (also §15.3).
- [~] **Model-space viewports** — `VPORTS`, multiple tiled viewports, named viewport configurations.
- [x] **Layout viewports** — `MVIEW`, create/edit/delete, on/off, lock, scale, align.
- [ ] **Viewport clipping** — `VPCLIP`, new boundary, invert, delete, show/hide clipped portion.
- [~] **Maximize/minimize viewport** — `VPMAX`/`VPMIN`, status-bar buttons.
- [x] **Viewport scale** — standard/custom scale list (`SCALELISTEDIT`), viewport scale sync, annotation scale sync.
- [x] **Viewport layer overrides** — `VPLAYER`, VP freeze, per-viewport property overrides (also §9.1).
- [~] **VIEWBACK/VIEWFORWARD** — sequential view history in layouts.
- [x] **CHSPACE** — move objects between model and paper space.
- [ ] **Export layout** — `EXPORTLAYOUT` to model space of a new drawing.

### 4.3 Display controls

- [x] **Draw order** — `DRAWORDER`, send to back/front, above/below object.
- [x] **Text to front / hatch to back** — `TEXTTOFRONT`, `HATCHTOBACK`.
- [x] **Hide/isolate objects** — `HIDEOBJECTS`, `ISOLATEOBJECTS`, `UNISOLATEOBJECTS`.
- [x] **Transparency display** — status-bar toggle, object/layer transparency.
- [x] **Lineweight display** — `LWDISPLAY`, status-bar toggle, model vs. paper space behavior.
- [ ] **Text and attribute display** — `QTEXT`, `QTEXTMODE`, `ATTDISP`.
- [ ] **Fill display** — `FILL`, `FILLMODE`.
- [~] **Frame visibility** — images (`IMAGEFRAME`), xrefs (`XFRAME`), underlays (PDF/DWF/DGN frames), wipeouts (`WIPEOUTFRAME`).
- [ ] **Image quality** — `IMAGEQUALITY` draft/high.
- [~] **Proxy graphics** — `PROXYGRAPHICS`, proxy show.
- [x] **Selection preview/highlight** — selection highlighting; *selection filtering* (limiting what pre-highlights) is **not available in LT**.
- [~] **Cursor/pickbox appearance** — `CURSORSIZE`, `PICKBOX`, `APERTURE`, cursor badges.
- [~] **Graphics performance** — `GRAPHICSCONFIG`, hardware acceleration, diagnostics, font acceleration, memory tuning.
- [~] **View transitions and performance** — `VTOPTIONS`, `VIEWRES`, `WHIPARC`-related tessellation.

---

## 5. Drafting aids and precision

> **Zephyr evaluation (43 items):** 17 present · 9 partial · 17 missing · 0 N/A.
> Nine osnap types (center, vertex/endpoint, midpoint, insertion, quadrant, nearest, perpendicular, tangent, intersection), ortho/polar/OTRACK, UCS/PLAN. No isometric drafting, dynamic input, coordinate filters or annotation scale.

### 5.1 Coordinate systems and entry

- [x] **WCS/UCS** — set origin/orientation, named UCSs, `UCSMAN`, UCS icon (`UCSICON`).
- [x] **One UCS per drawing** — **LT limitation**: no per-viewport UCS; the current viewport's UCS is used.
- [~] **Orthographic/preset UCSs** — via `UCS` options (no dynamic UCS).
- [x] **Plan view** — `PLAN` to the UCS XY plane.
- [x] **Coordinate entry** — absolute, relative `@`, polar `@dist<angle`, direct distance, Cartesian and polar.
- [ ] **Coordinate filters** — `.x`, `.y`, `.z`, `.xy`, etc.
- [ ] **Point entry aids** — object snap tracking, temporary tracking points, direct distance entry.
- [~] **Units and angular formats** — decimal, engineering, architectural, fractional, scientific, surveyor's; precision; `UNITS`, `INSUNITS`.
- [ ] **Elevation and thickness** — `ELEVATION`, `THICKNESS` for pseudo-3D 2D objects.
- [ ] **3D coordinates** — accepted for 3D wireframe creation (no 3D navigation).

### 5.2 Snap, grid, ortho, polar and isometric

- [ ] **Grid** — display, spacing, major lines, adaptive grid, limits, follow dynamic UCS (no).
- [x] **Snap** — grid snap, spacing, rotation, style (standard/isometric), `SNAP`.
- [x] **Ortho** — `ORTHO`, `F8`.
- [x] **Polar tracking** — `POLAR`, `F10`, incremental angles, additional angles, polar snap, measurement.
- [ ] **Isometric drafting** — `ISODRAFT`, `ISOPLANE`, `F5`, isometric grid/snap, 2D isometric drawing.
- [ ] **Limits** — `LIMITS`, on/off, drawing boundary.
- [ ] **Dynamic input** — `DYNMODE`, pointer input, dimension input, dynamic prompts.
- [x] **Object snap tracking** — `OTRACK`, `F11`, alignment paths from osnap points.
- [ ] **Temporary tracking points** — `TT`/`TK` style point tracking (as supported).
- [x] **2D object snap** — status-bar toggle, running osnaps.

### 5.3 Object snaps

- [~] **Endpoint, midpoint, center, geometric center, node, quadrant**.
- [~] **Intersection, apparent intersection, extension**.
- [~] **Insertion, perpendicular, tangent, nearest, parallel**.
- [x] **None / override** — per-pick override, running osnap settings.
- [x] **Object snap settings** — `OSNAP`, `DSETTINGS`, aperture, marker size/color, magnet.
- [ ] **3D object snap** — **not available in LT**.
- [ ] **Snap to underlays/images/PDF** — PDF/DWF/DGN/image osnap toggles (`PDFOSNAP`, `DWFOSNAP`).

### 5.4 Inquiry and calculation

- [x] **DIST** — distance and angle between points.
- [x] **MEASUREGEOM** — distance, radius, angle, area, volume; dynamic measurement.
- [~] **AREA** — object area/perimeter, add/subtract, defined points.
- [x] **ID** — UCS coordinates of a point.
- [~] **LIST / DBLIST** — object/database information.
- [ ] **MASSPROP** — mass properties of 2D regions; 3D solids are view-only in LT.
- [ ] **TIME** — drawing date/time statistics; `REVDATE` block.
- [ ] **STATUS** — drawing statistics, memory/disk/swap report, dimension variable report.
- [~] **SETVAR** — list/change system variables.
- [ ] **SYSVARMONITOR** — monitor variables and notify on change.
- [ ] **QuickCalc** — `QUICKCALC`, variables, functions, units, conversions, paste value.
- [~] **Command prompt calculator** — `CAL`, transparent use inside commands, geometric expressions.
- [x] **DIVIDE** — equal intervals with points/blocks.
- [x] **MEASURE** — measured intervals with points/blocks.
- [x] **PTYPE** — point display style and size.
- [ ] **Annotation scale** — current scale, scale list, `CANNOSCALE`, `ANNOALLVISIBLE`, `ANNOAUTOSCALE`.

---

## 6. Creating 2D geometry

> **Zephyr evaluation (39 items):** 16 present · 10 partial · 13 missing · 0 N/A.
> LINE/PLINE/POLYGON/XLINE/RAY/POINT/DONUT, CIRCLE with all modes, ELLIPSE, SPLINE, BOUNDARY, REVCLOUD, HATCH/GRADIENT. ARC is 3-point; RECTANG is axis-aligned. No WIPEOUT, REGION booleans, BLEND or 2D solids.

### 6.1 Linear and construction geometry

- [x] **LINE** — contiguous segments, close, undo; each segment is a separate object.
- [x] **PLINE** — line/arc segments, width/halfwidth, length, angle, close, undo, taper.
- [~] **RECTANG** — chamfer, fillet, width, elevation, thickness, dimensions, area, rotation.
- [x] **POLYGON** — inscribed/circumscribed, edge, number of sides (`POLYSIDES`).
- [x] **XLINE** — through point, horizontal, vertical, angle, bisect, offset.
- [x] **RAY** — start point and direction.
- [x] **POINT** — single/multiple points; divide/measure.
- [~] **Double lines** — `DLINE` straight/arc segments, justification, scale, snap, style (`MLSTYLE` is not the LT workflow; DLINE settings are).
- [~] **Freehand sketch** — `SKETCH`, record increment, lines/polyline/spline output, tolerance.
- [ ] **2D solid** — `SOLID` filled triangles/quadrilaterals.
- [x] **DONUT** — inside/outside diameter, filled ring.
- [ ] **3D polyline** — `3DPOLY` (3D wireframe creation).
- [x] **Construction/reference geometry** — XLINE, RAY, POINT.
- [ ] **Thickness/elevation** — give 2D objects 3D thickness for wireframe/hidden-line viewing.

### 6.2 Curved and closed geometry

- [x] **CIRCLE** — center/radius, diameter, 2P, 3P, tan-tan-radius, tan-tan-tan.
- [~] **ARC** — 3-point, start-center-end, start-center-angle, start-center-length, start-end-angle, start-end-direction, start-end-radius, continue.
- [x] **ELLIPSE** — axis endpoints, center, elliptical arc, rotation.
- [x] **SPLINE** — fit points, control vertices, close, tangency, degree; `SPLINEDIT`.
- [ ] **HELIX** — **not available in LT**.
- [~] **REGION** — convert closed objects to regions; boolean `UNION`/`SUBTRACT`/`INTERSECT`.
- [~] **BOUNDARY** — pick point, island detection, region/polyline output, boundary set, gap tolerance.
- [ ] **BLEND** — tangent spline between two lines/curves.
- [x] **REVCLOUD** — rectangular/polygonal/freehand, arc length, style, modify, `REVCLOUDPROPERTIES`.
- [ ] **WIPEOUT** — mask areas, polyline boundary, frames, display/plot.
- [ ] **Revision cloud layer** — `REVCLOUDLAYER` `(2026+)`, scale mode `(2026+)`.
- [ ] **2D isometric drawing** — isoplanes and isometric snap/grid.

### 6.3 Hatches, gradients and fills

- [~] **HATCH** — pattern, solid, gradient; predefined/user-defined/custom patterns.
- [~] **Pattern properties** — angle, scale, spacing, double, origin, alignment, color, background color, transparency, layer, annotative, associative.
- [~] **Boundary options** — pick internal point, select objects, boundary set, island detection (normal/outer/ignore), gap tolerance, retain boundary, draw order, separate hatches, create unbounded hatch.
- [x] **Hatch editing** — `HATCHEDIT`, inherit properties, reshape, recreate boundary, hide boundaries, draw order, background color.
- [x] **Hatch draw order** — `HATCHTOBACK`, `HPDRAWORDER`.
- [x] **Gradient fills** — one/two colors, tint/shade, linear/cylindrical/spherical, angle, shift, `GRADIENT`.
- [ ] **Hatch limits** — `HPMAXLINES`, `HPMAXAREAS`, `HPMAXLOOPS`, `HPOBJWARNING`.
- [~] **Hatch pattern scaling and units** — `HPSCALE`, `HPANG`, `HPNAME`, `HPSPACE`, `HPDOUBLE`.
- [ ] **Hatch preview** — `HPQUICKPREVIEW`, timeout.
- [ ] **Hatch layer/color/transparency defaults** — `HPLAYER`, `HPCOLOR`, `HPTRANSPARENCY`, `HPBACKGROUNDCOLOR`.
- [ ] **Annotative hatches** — `HPANNOTATIVE`.
- [ ] **Hatch associativity** — `HPASSOC`.
- [ ] **Wipeout** — `WIPEOUT`, `WIPEOUTFRAME`; masking and plotting.

---

## 7. Parametric constraints (LT-limited)

> **Zephyr evaluation (12 items):** 4 present · 5 partial · 3 missing · 0 N/A.
> Seven geometric constraints (fix/horizontal/vertical/coincident/parallel/perpendicular/equal) with a line solver, AUTOCONSTRAIN, DELCONSTRAINT and CONSTRAINTBAR. No dimensional constraints or Parameters Manager.

> **LT scope:** LT can display and consume constrained drawings, manipulate constrained geometry, change values in the Parameters Manager, and remove all constraints. It **cannot create or edit geometric/dimensional constraints** (`GEOMCONSTRAINT`, `DIMCONSTRAINT`, `AUTOCONSTRAIN`, constraint inference are not part of LT).

- [x] **Display/hide constraint bars** — `CONSTRAINTBAR`, `CONSTRAINTSETTINGS`, `CONSTRAINTBARMODE`, `CBARTRANSPARENCY`.
- [~] **Constraint glyphs and colors** — identify constrained objects; constraint status display.
- [~] **Edit/manipulate constrained geometry** — drag/edit objects that already carry constraints.
- [~] **Geometric constraints** — view/consume: coincident, collinear, concentric, fix, parallel, perpendicular, horizontal, vertical, tangent, smooth, symmetric, equal.
- [ ] **Dimensional constraints** — view/consume: dynamic, annotational, reference; `DCDISPLAY`, `DIMCONSTRAINTICON`, `CONSTRAINTNAMEFORMAT`.
- [ ] **Parameters Manager** — `PARAMETERS`, view/edit parameter values, expressions, parameter groups (LT: value editing only).
- [x] **Constraint removal** — `DELCONSTRAINT` removes all constraints from selected objects.
- [~] **Constraint settings** — `CONSTRAINTSETTINGS`, `CONSTRAINTSOLVEMODE` (view/behavior as supported).
- [ ] **Dynamic-block constraints** — view, modify values, delete in Block Editor; **cannot add** constraints.
- [x] **Infer constraints** — **not available in LT**.
- [x] **AutoConstrain** — **not available in LT**.
- [~] **Parametric drawing creation** — **not available in LT**.

---

## 8. Selecting and modifying objects

> **Zephyr evaluation (67 items):** 39 present · 14 partial · 14 missing · 0 N/A.
> Most core modify commands, including full OFFSET, OVERKILL, and associative arrays. No XPLODE, MOCORO, LENGTHEN, SELECTCOUNT or Geometry Cleanup; GROUP is basic.

### 8.1 Selection

- [x] **Click/pick** — single and multiple selection, noun/verb selection (`PICKFIRST`).
- [x] **Window/crossing** — window, crossing, window polygon, crossing polygon, fence.
- [~] **Lasso selection** — freeform selection where supported by the release.
- [~] **Selection options** — All, Last, Previous, Add/Remove, Multiple, Undo, Single, Box, Auto.
- [x] **Selection cycling** — overlap selection list, status-bar toggle.
- [x] **Quick Select** — `QSELECT` by object type/property.
- [x] **Selection filters** — `FILTER`, saved filter lists.
- [x] **Select Similar** — `SELECTSIMILAR`, settings for matching properties.
- [ ] **Select by count** — `SELECTCOUNT` (adds matching count objects to selection).
- [~] **Selection settings** — `PICKADD`, `PICKAUTO`, `PICKDRAG`, `PICKBOX`, selection preview.
- [~] **Groups** — `GROUP`, `UNGROUP`, `GROUPEDIT`, named/unnamed groups, selectable toggle, legacy group manager `PKFSTGROUP`.
- [~] **Grips** — grip display, colors/size, multifunctional grips, grip tips, dynamic grip menu, multiple copies, grip editing; polyline grip **Lengthen** `(2027.1)`.
- [ ] **Selection filtering (pre-highlight filter)** — **not available in LT**.

### 8.2 Move, rotate, copy, array

- [x] **MOVE** — displacement and two-point.
- [x] **COPY** — multiple copies, displacement/two-point.
- [~] **COPYBASE / CUTBASE** — clipboard with base point.
- [~] **PASTECLIP / PASTEBLOCK / PASTEORIG / PASTESPEC** — clipboard paste modes.
- [ ] **COPYLINK** — copy current view for OLE linking.
- [ ] **MOCORO** — move/copy/rotate/scale in one command.
- [x] **ROTATE** — base point, angle, reference, copy option (2D only; `ROTATE3D` not available).
- [x] **SCALE** — factor, reference, copy (uniform only).
- [x] **STRETCH** — crossing window/polygon, grip stretch.
- [ ] **LENGTHEN** — delta, percent, total, dynamic.
- [x] **ALIGN** — 2D alignment, scale option; **3D alignment not available**.
- [x] **MIRROR** — 2D mirror, erase source; `MIRRHATCH`; **3D mirror not available**.
- [x] **OFFSET** — distance, through point, layer, erase source, multiple.
- [x] **ARRAY** — rectangular (`ARRAYRECT`), polar (`ARRAYPOLAR`), path (`ARRAYPATH`), associative arrays, item count/spacing/angle, rotate items, align items.
- [x] **Array editing** — `ARRAYEDIT`, `ARRAYCLOSE`, source-object editing, limits.
- [x] **Legacy array dialog** — `ARRAYCLASSIC`.
- [ ] **MINSERT** — **not available in LT**.

### 8.3 Resize, trim, break, join, fillet, chamfer

- [x] **TRIM** — cutting edges, fence, crossing, edge mode, project, 3D wireframe trim in current view plane.
- [x] **EXTEND** — boundary edges, fence, edge mode, 3D wireframe extend.
- [x] **BREAK** — two points, first point.
- [x] **BREAKATPOINT** — split at a point.
- [x] **JOIN** — join lines, arcs, polylines, splines and compatible curves.
- [x] **FILLET** — radius, polyline, multiple, trim/no-trim, 2D only (3D solids/surfaces not available).
- [x] **CHAMFER** — distance, angle, polyline, multiple, trim/no-trim, 2D only.
- [ ] **BLEND** — tangent blend between two curves.
- [x] **EXPLODE** — blocks, polylines, regions, dimensions, hatches, mtext etc.; **MINSERT not available**.
- [ ] **XPLODE** — explode with per-object property control.
- [x] **REVERSE** — reverse lines, polylines, splines (useful for linetype direction).
- [x] **OVERKILL** — delete duplicate/overlapping geometry, combine collinear/contiguous objects; ignore/compare properties.
- [x] **PEDIT** — polyline edit: open/close, join, width, edit vertex, fit, spline, decurve, linetype generation, reverse, taper (interactive + `(command "PEDIT" ...)` scripted; Edit vertex is single-target only, Join of closed/curved polylines is rejected).
- [x] **SPLINEDIT** — control points/fit data, refine, join, kink, tangency; `3DEDITBAR` is **not available**.
- [ ] **Geometry Cleanup** `(2027)` — `GEOMETRYCLEANUPOPEN/CLOSE`, scan/fix gaps, overshoots, undershoots, angular errors; 2D linear/open curves on XY only; no blocks, hatches, nonzero Z, paper space, locked/frozen layers.

### 8.4 Erase, undo, purge and cleanup

- [x] **ERASE** — remove objects.
- [ ] **ADDSELECTED** — create a new object of the same type and properties as a selected object, with new geometry.
- [x] **OOPS** — restore the last erased objects.
- [~] **UNDO / MREDO / REDO** — multiple undo steps, undo marks, redo.
- [x] **PURGE** — unused blocks, layers, linetypes, styles, plot styles, zero-length geometry, orphaned data, DGN linestyles, AEC data (`PURGEAECDATA`).
- [ ] **Non-purgeable blocks** — find/remove.
- [x] **RENAME** — rename layers, blocks, styles, etc.
- [x] **Draw order tools** — see §4.3.
- [x] **Hide/isolate** — see §4.3.

### 8.5 Editing specific object types

- [~] **TEXTEDIT/MTEDIT** — edit single-line/multiline text.
- [x] **HATCHEDIT** — hatch/gradient editing.
- [~] **ATTEDIT/EATTEDIT/ATTIPEDIT** — attribute value editing (also §13.2).
- [x] **DIMEDIT/DIMTEDIT** — dimension text/extension lines and text position.
- [x] **MLEADEREDIT** — add/remove leader lines.
- [ ] **TABLEDIT** — table cell text editing.
- [x] **PEDIT/SPLINEDIT** — see above.
- [x] **Properties palette/Quick Properties/MATCHPROP/CHPROP/CHANGE** — property editing.
- [~] **SETBYLAYER/COPYTOLAYER** — property/layer normalization.
- [~] **Region booleans** — `UNION`, `SUBTRACT`, `INTERSECT` for 2D regions.
- [~] **Wipeout/revision-cloud editing** — grips, boundary, arc length.
- [x] **REFEDIT** — in-place editing of xrefs and block definitions (also §14.1 / §13.1).
- [ ] **3D-specific edits** — `ROTATE3D`, `MIRROR3D`, `3DALIGN`, `3DARRAY`, `3DMOVE` are **not available in LT**.

---

## 9. Layers, properties and display styles

> **Zephyr evaluation (37 items):** 21 present · 8 partial · 6 missing · 2 N/A.
> Full layer manager with VP overrides, filters, states and LAYERP/layer tools; ACI/RGB color, linetypes, lineweights, transparency and CTB/STB plotting. No LAYTRANS, color books or plot-style conversion.

### 9.1 Layers

- [x] **Layer Properties Manager** — on/off, freeze/thaw, lock/unlock, plot/no-plot, color, linetype, lineweight, transparency, plot style, description, new viewport VP freeze.
- [x] **Layer filters** — property filters, group filters, xref filters, viewport filters; invert filter.
- [x] **Layer states** — save/restore/edit/import/export, layer state manager, `LAYERSTATE`, `LAYERSTATESAVE`.
- [x] **Current layer** — set current, new layer, delete, rename, purge.
- [x] **Layer 0 / Defpoints behavior** — Layer 0 special handling inside blocks; Defpoints non-plotting layer.
- [~] **Layer tools** — `LAYISO`, `LAYOFF`, `LAYFRZ`, `LAYON`, `LAYTHW`, `LAYULK`, `LAYCUR`, `LAYMCUR`, `LAYMCH`, `LAYMGR`, `LAYMRG`, `LAYDEL`, `LAYWALK`, `LAYERP`, `LAYVPI`, `LAYUNISO`, `COPYTOLAYER`, `SETBYLAYER`.
- [x] **Viewport layer overrides** — `VPLAYER`, VP freeze, per-viewport color/linetype/lineweight/transparency/plot style; remove overrides; `VPLAYEROVERRIDES`, `VPLAYEROVERRIDESMODE`.
- [x] **Xref layer behavior** — `VISRETAIN`, `VISRETAINMODE`, `XREFLAYER`.
- [x] **Unreconciled layers** — notification, reconcile, remove from filter.
- [x] **Layer merge/delete** — merge to target, delete layer and objects.
- [x] **Layer notification** — new-layer alerts, `LAYEREVAL`, `LAYERNOTIFY`.
- [-] **Layer translator** — `LAYTRANS` is **not available in LT**.
- [x] **Layer fade/lock fade** — `LAYLOCKFADECTL`.

### 9.2 Colors, linetypes, lineweights

- [~] **Color** — ACI 1–255, ByLayer/ByBlock, TrueColor (24-bit), color books (PANTONE/RAL/DIC etc.), color dialog.
- [x] **Current color** — `COLOR`, default new-object color, `CECOLOR`.
- [~] **Linetypes** — load from `.lin`, current linetype, object linetype, `LINETYPE`, `LTSCALE`, `CELTSCALE`, `PSLTSCALE`, `MSLTSCALE`.
- [~] **Linetype generation** — `PLINEGEN`, dash patterns in polylines.
- [~] **Custom linetypes** — text/shapes in linetypes, complex linetypes.
- [x] **Lineweights** — standard values, current/default, object lineweight, display/plot, `LWEIGHT`, `LWDISPLAY`.
- [~] **Lineweight scale** — model vs. layout, `LWDISPLAY` options.
- [x] **Transparency** — object and layer transparency, display toggle, hatch transparency.
- [~] **Plot styles** — CTB/STB, plot style table assignment, object plot style, default plot style, `PLOTSTYLE`, `PSTYLEPOLICY`.
- [~] **Plot Style Table Editor** — `STYLESMANAGER`, edit CTB/STB.
- [ ] **Plot style conversion** — `CONVERTCTB`, `CONVERTPSTYLES`.
- [ ] **DGN linetypes** — display and purge.

### 9.3 Object properties and organization

- [x] **Properties palette** — all object properties, grouped by category, by-layer/by-block values.
- [ ] **Quick Properties** — customize visible properties.
- [x] **MATCHPROP** — copy properties, settings for which properties transfer.
- [x] **CHPROP/CHANGE** — change layer/color/linetype/lineweight/etc.
- [ ] **SETBYLAYER** — reset overrides to ByLayer.
- [x] **Property preview** — rollover preview of property changes.
- [x] **Object isolation/hide** — see §4.3.
- [x] **Draw order** — see §4.3.
- [ ] **Annotation scale property** — per-object annotative scale.
- [ ] **Hyperlinks** — object/block hyperlinks (also §14.5).
- [x] **Groups** — see §8.1.
- [-] **Materials** — **not available in LT**.

---

## 10. Text, fields and tables

> **Zephyr evaluation (33 items):** 5 present · 12 partial · 16 missing · 0 N/A.
> TEXT/MTEXT, styles, FIND, TEXTALIGN, TXT2MTXT and a FIELD-code implementation; DATA table object. No SPELL, QTEXT, table styles/formulas/data links, TABLEEXPORT or ATTEXT.

### 10.1 Text creation and styles

- [x] **Single-line text** — `TEXT`, height, rotation, justification, style, oblique, width factor, align/fit.
- [x] **Multiline text** — `MTEXT`, in-place editor, ruler, width, justification, line spacing, paragraph spacing, tabs, indents, columns.
- [~] **MTEXT formatting** — fonts, heights, colors, bold/italic/underline/overline/strikethrough, stacking fractions, symbols, lists/bullets/numbering/letters, background mask, text frame, fields.
- [ ] **MTEXT external editor** — `MTEXTED`, format codes, encoding.
- [~] **Text styles** — `STYLE`, SHX/TTF fonts, big font, fixed height, width factor, oblique, annotative, backwards/upside-down, vertical.
- [ ] **Annotative text** — annotative text styles/objects, annotation scale, auto-scale.
- [~] **Font substitution/mapping** — `FONTALT`, `FONTMAP`, missing-font dialog, substitute fonts.
- [~] **Text scale/justification** — `SCALETEXT`, `JUSTIFYTEXT`, `TEXTALIGN`.
- [x] **Find/replace** — `FIND`, `-FIND`, match case/whole word, search space/selection, text object types (`FINDINCLUDE`, `FINDMATCH`).
- [ ] **Spell check** — `SPELL`, main/custom dictionaries (`DCTMAIN`, `DCTCUST`).
- [~] **Text conversion** — `TXT2MTXT`, `PDFSHXTEXT` (PDF SHX geometry to mtext).
- [~] **Text display** — `QTEXT`, `TEXTTOFRONT`.
- [ ] **Space translation** — `SPACETRANS` for model/paper distances.
- [x] **MText parser features** — stacked text, fields, paragraph formatting.

### 10.2 Fields

- [~] **Insert fields** — `FIELD` in text/mtext/attributes/tables.
- [~] **Field categories** — date/time, saved date, filename/path, author, drawing properties, sheet set/sheet number/sheet title, object properties, formula, system variables (as supported).
- [~] **Field formatting** — format/precision, uppercase/lowercase, display options.
- [~] **Field update** — `UPDATEFIELD`, `FIELDEVAL`, automatic vs. manual.
- [ ] **Field display** — gray background (`FIELDDISPLAY`).
- [ ] **Contextual fields** — fields in blocks/xrefs (object properties).
- [ ] **Hyperlink fields** — hyperlink in a field.
- [ ] **LispVariables fields** — **not available in LT** (cached values display from AutoCAD drawings).

### 10.3 Tables

- [x] **Table object** — `TABLE`, rows/columns, insertion point, table style.
- [ ] **Table styles** — `TABLESTYLE`, cell styles, borders, margins, text height/style, fill.
- [~] **Cell editing** — `TABLEDIT`, in-place editor, merged cells, alignment, formatting.
- [~] **Cell content** — text, blocks (`TINSERT`), fields, formulas.
- [ ] **Formulas** — sum, average, count, cell references, arithmetic.
- [ ] **Data links** — `DATALINK`, link to CSV/Excel, update direction, `DATALINKUPDATE`, `DATALINKNOTIFY`.
- [ ] **Table export** — `TABLEEXPORT` to CSV.
- [ ] **Table layer** — `TABLELAYER` `(2026+)`.
- [ ] **Table toolbar/indicator** — `TABLETOOLBAR`, `TABLEINDICATOR`.
- [ ] **Count table** — `COUNTTABLE` from the Count feature.
- [ ] **Data Extraction to table** — **not available in LT** (`DATAEXTRACTION`/`EATTEXT` absent); attribute extraction to file via `ATTEXT` **is** available.

---

## 11. Dimensions, leaders and tolerances

> **Zephyr evaluation (46 items):** 25 present · 11 partial · 10 missing · 0 N/A.
> Full 2D dimension suite, DIMSTYLE manager, DIMSPACE/DIMBREAK, center marks, LEADER/QLEADER/MLEADER and styles. No QDIM, DIMJOGLINE, DIMINSPECT, TOLERANCE, annotative dimensions or DIMLAYER.

### 11.1 Dimensions

- [x] **DIM (smart dimension)** — one command that creates linear, aligned, angular, arc-length, radius, diameter, ordinate and jogged dimensions.
- [x] **Linear** — `DIMLINEAR`.
- [x] **Aligned** — `DIMALIGNED`.
- [x] **Angular** — `DIMANGULAR`.
- [x] **Arc length** — `DIMARC`.
- [x] **Radius** — `DIMRADIUS`.
- [x] **Diameter** — `DIMDIAMETER`.
- [x] **Ordinate** — `DIMORDINATE`.
- [x] **Jogged** — `DIMJOGGED`.
- [ ] **Jog line** — `DIMJOGLINE`.
- [x] **Baseline** — `DIMBASELINE`.
- [x] **Continue** — `DIMCONTINUE`.
- [x] **Center mark** — `DIMCENTER`, `CENTERMARK`; center layer `CENTERLAYER`.
- [x] **Centerline** — `CENTERLINE`, associate/reassociate/reset/disassociate.
- [ ] **Quick dimension** — `QDIM`.
- [x] **Associative dimensions** — `DIMREASSOCIATE`, `DIMREGEN`, `DIMDISASSOCIATE`.
- [ ] **Annotative dimensions** — dimension style annotative, annotation scale.
- [~] **Dimension scale** — `DIMSCALE`, overall/current style scale, layout scaling.
- [~] **Dimension styles** — `DIMSTYLE`, style families/child styles, overrides, compare styles, purge, import via DesignCenter.
- [~] **Dimension style: Lines tab** — dimension/extension line colors, lineweights, offsets, extensions, suppression.
- [~] **Dimension style: Symbols and Arrows tab** — arrowheads, leader arrow, center marks, arc-length symbol, jog.
- [~] **Dimension style: Text tab** — text style/color/height, placement, alignment, frame.
- [~] **Dimension style: Fit tab** — fit options, overall scale, fine tuning, placement.
- [~] **Dimension style: Primary Units tab** — unit format, precision, prefix/suffix, rounding, zero suppression, angular units.
- [~] **Dimension style: Alternate Units tab** — enable, multiplier, formatting, zero suppression, placement.
- [~] **Dimension style: Tolerances tab** — method, upper/lower values, height scale, zero suppression, alternate tolerance.
- [ ] **Dimension override** — `DIMOVERRIDE`.
- [x] **Dimension text editing** — `DIMEDIT`, `DIMTEDIT`, text position, oblique, home, rotate, justify.
- [x] **Dimension spacing** — `DIMSPACE`.
- [x] **Dimension breaks** — `DIMBREAK`.
- [ ] **Inspection dimensions** — `DIMINSPECT`.
- [ ] **Geometric tolerances** — `TOLERANCE`, feature control frames, composite tolerances.
- [~] **Alternate units / tolerances** — dimension style tabs and overrides.
- [ ] **Dimension layer** — `DIMLAYER`.
- [~] **Associative dimension update** — `DIMREGEN` after edits.

### 11.2 Leaders and multileaders

- [x] **Leader** — `LEADER` (line + annotation).
- [x] **Quick leader** — `QLEADER`, leader settings.
- [x] **Multileader** — `MLEADER`, text/block content, landing, arrowhead.
- [x] **Multileader styles** — `MLEADERSTYLE`, text/leader/arrow/content properties, annotative.
- [x] **Multileader editing** — `MLEADEREDIT` add/remove leader lines, grips.
- [x] **Multileader align** — `MLEADERALIGN`.
- [x] **Multileader collect** — `MLEADERCOLLECT` into rows/columns with one leader.
- [ ] **Multileader layer** — `MLEADERLAYER` `(2025+)`.
- [ ] **Annotation scaling for leaders** — annotative styles and scale.
- [ ] **Background mask / text frame** — leader text frame and mask.
- [x] **Block content in multileaders** — block content type, scale/rotation.

---

## 12. Revision clouds, wipeouts and annotation utilities

> **Zephyr evaluation (8 items):** 2 present · 0 partial · 6 missing · 0 N/A.
> REVCLOUD and text/leader/dimension draw order. No WIPEOUT, annotation monitor, annotation scale, REVDATE or plot stamp.

- [x] **Revision clouds** — rectangular, polygonal, freehand, arc length, style, modify, `REVCLOUDPROPERTIES`.
- [ ] **Revision cloud layer/scale** — `REVCLOUDLAYER`, `REVCLOUDSCALEMODE` `(2026+)`.
- [ ] **Wipeouts** — `WIPEOUT`, polyline boundary, frames, display/plot.
- [ ] **Annotation monitor** — badge nonassociative annotations, status-bar toggle.
- [ ] **Annotation scale tools** — `OBJECTSCALE`, `ANNORESET`, `ANNOUPDATE`, `ANNOALLVISIBLE`, `ANNOAUTOSCALE`.
- [x] **Text/leader/dimension draw order** — `TEXTTOFRONT`, `HATCHTOBACK`.
- [ ] **Date/time block** — `REVDATE`.
- [ ] **Plot stamp** — `PLOTSTAMP` (also §15.1).

---

## 13. Blocks and attributes

> **Zephyr evaluation (47 items):** 11 present · 10 partial · 26 missing · 0 N/A.
> Blocks, block editor, attributes (ATTDEF/ATTEDIT/ATTSYNC), WBLOCK, blocks palette, REFEDIT. No dynamic blocks, Smart Blocks, BTABLE, BATTMAN, ATTEXT, DATAEXTRACTION or COUNT.

### 13.1 Static blocks

- [x] **Define block** — `BLOCK`/`-BLOCK`, base point, select objects, retain/convert/delete source.
- [~] **Block properties** — name, description, block units, annotative, scale uniformly, allow exploding.
- [~] **Block Editor** — `BEDIT`, `BCLOSE`, `BSAVE`, `BSAVEAS`, `BTESTBLOCK`, `BESETTINGS`.
- [ ] **Block authoring palettes** — `BAUTHORPALETTE`, `BAUTHORPALETTECLOSE`.
- [~] **Block definition editing** — redefine, update from drawing, rename, delete, purge, block icon.
- [~] **Nested blocks** — nesting, explode behavior, nested attribute handling.
- [x] **Insert block** — `INSERT`, `CLASSICINSERT`, blocks palette, DesignCenter, drag-and-drop.
- [~] **Insertion options** — scale, rotation, explode, unit scaling, multiple insertion (MINSERT is **not** available), attribute prompts.
- [x] **Blocks palette** — current drawing, recent, favorites, libraries, search.
- [x] **WBLOCK** — export block/objects to a DWG; insert drawing as block.
- [~] **Block library drawing** — organize/insert library blocks.
- [x] **Block reference editing** — move/rotate/scale, grips, properties, reset (`RESETBLOCK`).
- [x] **Explode block** — one level/multiple, attribute behavior.
- [x] **REFEDIT for blocks** — in-place block definition editing (also §14.1).
- [ ] **Count blocks** — `COUNT`, `COUNTTABLE`, `COUNTFIELD` (also §16.3).

### 13.2 Attributes

- [x] **Define attributes** — `ATTDEF`, tag/prompt/default, modes (invisible/constant/verify/preset), multiline, lock position, annotative, text style/height/justification.
- [x] **Attach attributes to blocks** — attribute order, prompt order (`BATTORDER`).
- [x] **Edit attribute values** — `ATTEDIT`, `EATTEDIT`, `ATTIPEDIT`, Properties palette.
- [~] **Edit attribute definitions** — Block Editor, `BATTMAN`.
- [x] **Synchronize attributes** — `ATTSYNC` after definition changes.
- [ ] **Attribute display** — `ATTDISP`, invisible/constant modes.
- [ ] **Attribute extraction** — `ATTEXT` to CSV/TXT with a template file; attribute extraction template setup.
- [~] **Fields in attributes** — field values, sheet-set fields, object properties.
- [~] **Multiple lines in attributes** — multiline attribute support.
- [ ] **Attribute creation/editing convenience** `(2027.1)` — Ctrl+A in the Default/Value text boxes selects all text.
- [~] **Attribute grips** — move/resize, lock position.
- [ ] **Data Extraction** — **not available in LT**.

### 13.3 Dynamic blocks

- [ ] **Create/edit dynamic blocks** — Block Editor, action-based parameters, actions, parameter sets, value sets, grips.
- [ ] **Parameters** — point, linear, polar, XY, rotation, flip, visibility, alignment, base, lookup (as supported).
- [ ] **Actions** — move, scale, stretch, polar stretch, rotate, flip, array, chain, lookup.
- [ ] **Parameter properties** — grips, labels, value sets, chain actions.
- [ ] **Visibility states** — `BVSTATE`, `BVHIDE`, `BVSHOW`, `BVMODE`.
- [ ] **Lookup table** — `BLOOKUPTABLE`, lookup properties.
- [ ] **Block properties table** — `BTABLE`; user parameters and constraint parameters **not available in LT**.
- [ ] **Dynamic block grips** — custom grips, grip cycling (`BCYCLEORDER`), grip color/size.
- [ ] **Reset dynamic block** — `RESETBLOCK`.
- [ ] **Constraint-based dynamic blocks** — constraints can be viewed/used but **not added** in LT.
- [ ] **Test block** — `BTESTBLOCK`.
- [ ] **Dynamic block authoring tools** — action bars (`BACTIONBAR`), block authoring palette, dependency highlight.
- [ ] **Anonymous/unnamed blocks** — dynamic block anonymous names, purge behavior.

### 13.4 Smart Blocks

- [ ] **Search and convert** `(2025+)` — `BSEARCH`/`-BSEARCH`/`BCONVERT` find identical geometry and text variations.
- [ ] **Convert to new/existing block** — choose definition, include existing instances.
- [ ] **Text-to-attribute** — `TEXTTOATTRIBUTE` behavior when text is selected.
- [ ] **Placement suggestions** `(2024+)` — `AUTOPLACEMENT` suggests insertion points based on previous placements.
- [ ] **Layer 0 assignment** `(2026.1+)` — assign objects within the new block to Layer 0.
- [ ] **Include existing blocks** — `BSEARCHINCLUDEEXISTINGBLOCKS`.
- [ ] **Zoom to selection / review** — convert dialog behavior and preview.

---

## 14. External references, underlays, images and embedded data

> **Zephyr evaluation (53 items):** 17 present · 13 partial · 23 missing · 0 N/A.
> DWG/DXF xrefs with overlay/bind/clip/ncopy/xbind/REFEDIT, image and PDF references, PDF import (raster) and export. DWF/DGN parse but do not render; no XOPEN, XCOMPARE, OLE, hyperlinks or geolocation.

### 14.1 DWG xrefs

- [x] **Attach/overlay** — `XATTACH`, attach vs. overlay, nesting behavior.
- [x] **Xref palette** — tree view, status, size, type, saved/current path.
- [x] **Path types** — relative, absolute, no path; found path; repath; find-and-replace paths.
- [ ] **Project search paths / `PROJECTNAME`** — **not available in LT**.
- [x] **Reload/unload** — `XREF` palette or command flow.
- [x] **Bind/insert** — `XBIND`, bind xref (bind vs. insert), xref-dependent named objects, name conflicts.
- [x] **Clip xref** — `XCLIP`, new boundary, invert clip, delete, show/hide clipped portion.
- [x] **Edit in place** — `REFEDIT`, `REFSET`, `REFCLOSE`; working set, save/discard.
- [~] **Open xref** — `XOPEN` in a separate window.
- [x] **NCOPY** — copy objects from xrefs/blocks/DGN underlays.
- [x] **Xref layer properties** — overrides, `VISRETAIN`, VP freeze.
- [x] **Demand load / performance** — `XLOADCTL`, layer/spatial indexes, xref logging.
- [x] **Missing/circular xrefs** — resolve, repath, notifications, Connected References `(2027)`.
- [ ] **Xref compare** — `XCOMPARE`, color modes, change navigation, backup path/size, enable/disable.
- [~] **Xref fade/frame** — `XFADECTL`, `XFRAME`.
- [ ] **Temporary xref copies** — path setting.

### 14.2 PDF, DWF/DWFx and DGN underlays

- [x] **PDF attach** — `PDFATTACH`, page selection, insertion point/scale/rotation.
- [~] **PDF clip/layers/adjust** — `PDFCLIP`, `PDFLAYERS`, `PDFADJUST` (fade/contrast/monochrome).
- [~] **PDF osnap** — `PDFOSNAP`.
- [~] **PDF frame/visibility** — frame display/plot, show/hide, reload/unload, path.
- [ ] **DWF/DWFx attach** — `DWFATTACH`, clip, layers, adjust, frame, snap (`DWFOSNAP`), reload/unload.
- [ ] **DGN attach** — `DGNATTACH`, clip, levels/layers (`DGNLAYERS`), adjust, bind (`DGNBIND`), reload, DGN linetypes.
- [~] **Underlay manager** — list, nesting, path, status, layer override status.
- [~] **Underlay display** — fade/contrast/monochrome, frame, show/hide, clipped portion.
- [ ] **Underlay osnaps** — PDF/DWF/DGN snap support.
- [~] **Publish/transmit with underlays** — include/reference behavior.

### 14.3 Raster images

- [x] **Attach image** — `IMAGEATTACH`, supported formats, insertion scale/rotation.
- [x] **Image manager** — `IMAGE`/External References palette, list, preview, file details.
- [x] **Image adjustment** — `IMAGEADJUST`, brightness/contrast/fade; bitonal color/transparency (`TRANSPARENCY`).
- [x] **Image clipping** — `IMAGECLIP`, new boundary, invert, delete, show/hide.
- [~] **Image frames/quality** — `IMAGEFRAME`, `IMAGEQUALITY`.
- [~] **Load/unload/reload** — performance and memory.
- [x] **Image paths** — relative/absolute, repath, find missing.
- [~] **Nested images** — display names/nesting levels.
- [ ] **Image export** — BMP/JPG/PNG/TIF (`BMPOUT`, `JPGOUT`, `PNGOUT`, `TIFOUT`).

### 14.4 PDF import, DGN and WMF

- [~] **PDF import** — `PDFIMPORT`, geometry/fills/raster, TrueType text, import as block, layer assignment (`PDFIMPORTLAYERS`), filters (`PDFIMPORTFILTER`), image path, mode.
- [ ] **PDF SHX text** — `PDFSHXTEXT` converts SHX geometry to mtext; threshold/layer.
- [~] **PDF export/searchable text** — `EXPORTPDF`, `PDFSHX` for hidden searchable text.
- [ ] **DGN import/export** — `DGNIMPORT`, `DGNEXPORT`, `DGNMAPPING`, design model/units, linetype mapping.
- [ ] **WMF import/export** — `WMFIN`, `WMFOPTS`, `WMFOUT`.
- [ ] **IMPORT/EXPORT generic** — `IMPORT`, `EXPORT` format list.

### 14.5 OLE, hyperlinks and geolocation

- [ ] **OLE insert/embed** — `INSERTOBJ`, paste special, embedded objects.
- [ ] **OLE link management** — `OLELINKS`, update/reconnect/break links, `OLEOPEN`, `OLERESET`, `OLESCALE`, `OLECONVERT`.
- [ ] **OLE display/plot** — frames, plot quality (`OLEQUALITY`), text scaling, source-app startup (`OLESTARTUP`).
- [ ] **Hyperlinks** — `HYPERLINK`, `ATTACHURL`, `DETACHURL`, `GOTOURL`, `HYPERLINKOPTIONS`, `PASTEASHYPERLINK`.
- [ ] **Hyperlink targets** — URL, file, email, named view/location; relative paths; block hyperlinks.
- [ ] **Geographic location** — `GEOGRAPHICLOCATION` from map/latitude-longitude/GIS file; edit/remove.
- [ ] **GIS coordinate system** — assign/change coordinate system.
- [ ] **Online map** — `GEOMAP`, Esri map types `(2025+)`, map display, distortion/scale behavior.
- [ ] **Map images** — `GEOMAPIMAGE`, `GEOMAPIMAGEUPDATE`, capture area, erase.
- [ ] **Position markers** — `GEOMARKLATLONG`, `GEOMARKME`, `GEOMARKPOINT`, `GEOMARKPOSITION`, notes, find/edit/resize.
- [ ] **North direction/marker** — `GEOREORIENTMARKER`, `GEOREMOVE`.
- [ ] **Geolocation limits** — online map cannot be plotted directly; KML/KMZ limitations.

---

## 15. Layouts, viewports, plotting and publishing

> **Zephyr evaluation (54 items):** 14 present · 23 partial · 14 missing · 3 N/A.
> Real model/paper space, LAYOUT create/rename/copy/delete, MVIEW scale, CHSPACE, page setup, PDF plot/preview and PDF batch publish, sheet sets. Plotting is PDF-only; no printer/plotter output, DWF, plot stamp or EXPORTLAYOUT.

### 15.1 Model space, paper space and layouts

- [x] **Model/paper space** — `MODEL`, `TILEMODE`, `PSPACE`, `MSPACE`.
- [x] **Model and layout tabs** — show/hide (`LAYOUTTAB`), right-click tab menu, reorder/move layouts.
- [~] **Layout creation** — `LAYOUT`, `LAYOUTWIZARD`, new/rename/copy/move/delete.
- [~] **Layout templates** — import layout from template/DWT.
- [~] **Layout tab menu** `(2024+)` — new/from template/publish.
- [x] **Page setup** — `PAGESETUP`, `-PAGESETUP`, named page setups, `PSETUPIN`.
- [~] **Page setup overrides** — for layouts/sheet sets/publishing.
- [x] **Layout viewports** — `MVIEW`, `VPORTS`, viewport on/off, lock, scale, alignment; default viewport layer `VIEWPORTLAYER` `(2026+)`.
- [ ] **Viewport clipping** — `VPCLIP`, boundary/invert/delete.
- [~] **Viewport max/min** — `VPMAX`, `VPMIN`.
- [x] **Layer overrides in viewports** — `VPLAYER`, VP freeze, property overrides.
- [ ] **Annotative scaling in viewports** — annotation scale, viewport scale sync.
- [x] **CHSPACE** — transfer objects between model and paper space.
- [ ] **EXPORTLAYOUT** — layout to model space in a new drawing.
- [~] **Plot area/scale** — limits, extents, display, view, window, layout; fit/custom scale.
- [~] **Plot offset/orientation** — center, X/Y offset, portrait/landscape, upside down.
- [x] **Paper size/units** — standard/custom paper sizes, inches/mm.
- [~] **Shade plot** — as displayed/legacy options (LT has no visual styles; plotting is essentially 2D/wireframe/hidden).
- [~] **Plot options** — plot with plot styles, plot paperspace last, hide paperspace objects, plot stamp, transparency, object lineweights, plot to file.
- [x] **Plot preview** — full/preliminary `PREVIEW`.
- [~] **Plot** — `PLOT` to printer/plotter/file.
- [~] **Plotter Manager** — `PLOTTERMANAGER`, PC3 configuration, custom properties, PMP.
- [~] **Plot style tables** — CTB/STB, assign to layout/objects (also §9.2).
- [ ] **Plot stamp** — `PLOTSTAMP`, date/time/scale/user, log file.
- [ ] **Plot/publish details** — `VIEWPLOTDETAILS`, logs.
- [ ] **Background plotting/publishing** — job queue, notifications.
- [ ] **GDI/Windows printer behavior** — custom printer settings `(2026+)`.
- [~] **Paper space lineweight scale** — lineweight scaling in layouts.

### 15.2 Publishing

- [~] **PUBLISH** — sheet list, add/remove sheets, page setup overrides, multi-sheet output.
- [x] **Publish to PDF** — single/multi-sheet, vector/raster, layers, bookmarks, hyperlinks, searchable text.
- [ ] **Publish to DWF/DWFx** — page setup overrides, multi-sheet.
- [ ] **Publish to plotter** — batch plot.
- [ ] **AutoPublish** — `AUTOPUBLISH` to a specified location.
- [~] **Export PDF/DWF commands** — `EXPORTPDF`, `EXPORTDWF`, `EXPORTDWFX`, `EXPORTSETTINGS`.
- [ ] **Publish to Forma Data Management** — push sheets as PDFs `PUSHTOFORMAOPEN` (also §16.2).
- [~] **Publish logs/errors** — job status, warnings, output path.
- [~] **eTransmit** — package published drawings/dependencies (also §3.2).
- [ ] **Archive sheet set** — `ARCHIVE`.

### 15.3 Sheet sets

- [x] **Create/open sheet set** — `NEWSHEETSET`, `OPENSHEETSET`, `SHEETSET`, DST files.
- [~] **Sheet set template** — example sheet set, sheet creation template, page setup overrides.
- [x] **Subsets** — create/organize subsets.
- [x] **Sheets** — import layouts as sheets, new sheet, remove, reorder, open/review.
- [~] **Sheet properties** — sheet number/title, custom properties, multi-sheet property editing `(2027.1)`.
- [~] **Sheet set properties** — project name, custom properties, fields.
- [x] **Sheet views** — add views, view categories, sheet view labels/callout blocks.
- [x] **Sheet list table** — insert/update sheet list table.
- [~] **Sheet set fields** — title block fields (sheet number/title, project, custom).
- [ ] **Saved sheet selections** — save/restore/modify/rename/delete.
- [~] **Publish/transmit/archive sheet set** — PDF/DWF options, eTransmit, archive.
- [-] **Cloud/Connected Sheet Set Manager** — cloud sheet sets, status, conflict notifications `(2026.1+)`.
- [-] **Sheet Set Manager for Web** — **removed in 2026.1.1**.
- [-] **Project-aware settings** — Forma Data Management projects.
- [~] **Sheet status/notifications** — refresh, polling, sheet status.
- [ ] **Sheet set recovery** — recover DST data.

---

## 16. Collaboration, cloud and review

> **Zephyr evaluation (47 items):** 0 present · 1 partial · 31 missing · 15 N/A.
> No Trace, DWG Compare, Count, Smart Blocks, Activity Insights, Autodesk Assistant, markup import, cloud storage or digital signatures. Sheet-set transmit exists as a partial eTransmit.

### 16.1 Trace

- [ ] **Trace overview** — virtual tracing paper over the drawing; no change to the parent drawing.
- [ ] **Traces palette** — create/open/show/hide traces; empty-state workflow.
- [ ] **Trace comments** — add/reply to comments, participants, status.
- [ ] **Trace editing** — draw/edit in the trace environment; `TRACEBACK`, trace view mode.
- [ ] **Copy from trace** — `COPYFROMTRACE` objects into the drawing.
- [ ] **Trace settings** — access control, display, trace layer/color behavior.
- [ ] **Trace across desktop/web/mobile** — collaborators can view/contribute in the companion apps.
- [-] **Multi-user markup** `(2026.1+)` — share layout/model URL; collaborators mark up a trace in AutoCAD web via Forma Data Management.

### 16.2 Cloud and Forma Data Management

- [-] **Forma Data Management (Autodesk Docs)** — open/save, project files, versions.
- [-] **Share URL** — `SHARE` link to a drawing that recipients can edit (2025.1+).
- [-] **Push sheets to Forma** — `PUSHTOFORMAOPEN`/`PUSHTOFORMACLOSE`, upload layouts as PDFs.
- [-] **Connected Support Files** `(2026+)` — shared support files per project.
- [-] **Connected References** `(2027)` — repath missing xrefs across a project.
- [-] **Cloud storage providers** — OneDrive, Dropbox, Box, Google Drive.
- [ ] **Start tab cloud browsing** — recent cloud drawings, project navigation.
- [-] **Drawing History / version history** — view version history from the Start tab (`View Drawing History`) for cloud-stored drawings; compare versions via Activity Insights.
- [-] **Shared Views** — **removed in 2027** (`SHAREDVIEWS`/Share View); use Forma Data Management.
- [-] **Open/save Web & Mobile commands** — **removed in 2027**.

### 16.3 Drawing comparison, count and insights

- [ ] **DWG Compare** — `COMPARE`, revision-cloud change sets, colors, front/back display.
- [ ] **Compare settings** — tolerance, hatch/text/property comparison, change-set shape/margin, show/hide groups.
- [ ] **Compare import/export** — `COMPAREIMPORT`, `COMPAREEXPORT` snapshot drawing, `COMPAREINFO`.
- [ ] **Xref Compare** — `XCOMPARE`, navigation, color mode, backup settings.
- [ ] **Compare limitations** — OLE, cameras, geographic/GIS data, non-DWG underlays, images, coordination models, point clouds are not compared.
- [ ] **COUNT** — count object/block instances, single object, all blocks, area count (`COUNTAREA`), palette (`COUNTLIST`).
- [ ] **Count navigation/results** — next/previous (`COUNTNAVNEXT/PREV`), highlight, verify.
- [ ] **Count output** — `COUNTTABLE`, `COUNTFIELD`, count in fields/tables.
- [ ] **Count limitations** — unsupported object types are excluded from counting.
- [-] **Activity Insights** — palette, version history, filters/search, compare versions, refresh `(2025+)`.
- [-] **Activity Insights logging** — path, support toggle, viewed-activity logging; **LT displays only Version activities**.
- [-] **Autodesk Assistant** — AI chat/help palette `(2024.1+)`, prompt-driven workflows, selection-aware analysis, unit reporting, recommendations `(2027.1)`, object counting `(2027.1)`.
- [ ] **Assistant commands** — `ASSISTANTOPEN`/`ASSISTANTCLOSE` `(2027)`.
- [ ] **InfoCenter/help** — F1 context help, search, subscription info, announcements.

### 16.4 Review and markup

- [ ] **Markup Set Manager** — load DWF/DWFx markups, tree view, sheet/markup details.
- [ ] **Markup status/comments** — change status, add comments, save changes, republish.
- [ ] **Markup visibility** — show/hide DWF geometry, DWG geometry, markup geometry; zoom to markup.
- [ ] **Publish for review** — DWF/DWFx/PDF output for reviewers.
- [ ] **Markup Import / Markup Assist** — **not available in LT**.
- [-] **Shared Views** — **removed in 2027**.
- [ ] **Hyperlinks in published output** — PDF/DWF hyperlink support.

### 16.5 Transmittal, security and trust

- [~] **eTransmit** — `ETRANSMIT`, transmittal setups, folder/ZIP, include fonts/xrefs/images, path options, sheet-set transmittal.
- [ ] **Digital signatures** — `DIGITALSIGN` DWG/DWT, signature validation, time stamps, digital IDs.
- [ ] **TrustedDWG** — integrity check on open/save.
- [ ] **Secure load** — `SECURELOAD`, `TRUSTEDPATHS`, `/safemode`, executable restrictions (`SECURITYOPTIONS`).
- [ ] **Malicious-code recovery** — detection/recovery guidance, trusted locations.
- [-] **Password protection** — **not available** since the 2016-based releases.
- [ ] **Cracked-copy warning** — product integrity notice.
- [ ] **Digital signatures for executables** — verify signed AutoLISP/executables where applicable.

---

## 17. 3D viewing and wireframe (LT-limited)

> **Zephyr evaluation (19 items):** 0 present · 0 partial · 19 missing · 0 N/A.
> Zephyr is 2D-only: no 3D modeling, 3D navigation, visual styles, perspective, point clouds, cameras/lights/materials or rendering.

> **LT scope:** LT opens and displays 3D models created in AutoCAD, but the 3D view/navigation and modeling toolset is absent. There is no orbit, no perspective, no visual styles, no solids/surfaces/meshes, no rendering, no cameras/lights/materials, and no point-cloud indexing.

- [ ] **Open 3D drawings** — display 3D solids/surfaces/meshes created elsewhere (proxy/ACIS display).
- [ ] **3D wireframe creation** — 3D coordinates, `3DPOLY`, thickness/elevation.
- [ ] **Set 3D viewpoint (orthographic/isometric)** — `-VPOINT` (e.g., `1,-1,1`), `PLAN`; standard view directions.
- [ ] **Parallel projection** — parallel projection only; **perspective is not available** (`PERSPECTIVE` cannot be enabled).
- [ ] **Hidden-line removal** — `HIDE`, `HLSETTINGS`, `HALOGAP`, `HIDETEXT`, obscured color/linetype.
- [ ] **SHADEMODE** — **LT supports only 2D Wireframe and Hidden**; no shaded/realistic/wireframe visual styles.
- [ ] **Visual styles** — **not available in LT**.
- [ ] **3D orbit / walk / fly / swivel** — **not available in LT** (3D view and navigation tools absent).
- [ ] **ViewCube / ShowMotion / animation** — **not available in LT**.
- [ ] **Cameras / lights / materials / rendering** — **not available in LT**.
- [ ] **3D solids, surfaces, meshes, NURBS** — **not creatable/editable in LT** (viewed only).
- [ ] **3D operations** — `EXTRUDE`, `REVOLVE`, `LOFT`, `SWEEP`, `PRESSPULL`, `BOX`, `CYLINDER`, `SPHERE`, `UNION`/`SUBTRACT`/`INTERSECT` on solids, `SLICE`, `SECTION`, `SOLIDEDIT`, `SURF*`, `MESH*` — **not available in LT** (region booleans are available).
- [ ] **3D modify** — `ROTATE3D`, `MIRROR3D`, `3DALIGN`, `3DARRAY`, `3DMOVE`, `3DSCALE` — **not available in LT**.
- [ ] **3D object snap / gizmo / dynamic UCS** — **not available in LT**.
- [ ] **Live section / section planes** — **not available in LT**.
- [ ] **Point clouds** — **view only**: open drawings containing point clouds, select/display; cannot attach, index, or explode.
- [ ] **XEDGES** — **not available in LT**.
- [ ] **STL/3D printing/3D output** — **not available in LT**.
- [ ] **Perspective in named views** — **not available in LT**; named views cannot store visual style/background/live section.

---

## 18. Customization and automation

> **Zephyr evaluation (51 items):** 9 present · 9 partial · 33 missing · 0 N/A.
> AutoLISP (305 builtins), SCRIPT, zephyr.pgp aliases, ribbon defined in LISP, custom linetypes/hatch patterns/SHX fonts. No CUI/CUIx, DCL, reactors, full VLA, VLIDE, tool palettes or DesignCenter.

### 18.1 User interface customization

- [ ] **CUI/CUIx editor** — `CUI`, customize ribbon tabs/panels, QAT, toolbars, menus, shortcut menus, keyboard shortcuts, mouse buttons.
- [ ] **Partial CUIx** — load/unload partial customization files; `CUILOAD`/`CUIUNLOAD`, `CUIEXPORT`/`CUIIMPORT`.
- [ ] **Enterprise/main CUIx** — enterprise customization and main customization files.
- [ ] **Workspaces** — create/save/switch, workspace settings.
- [ ] **Command macros** — macro strings, control characters, DIESEL expressions, `^C^C` sequences.
- [ ] **Command tools** — tool palette command tools, custom command sequences.
- [~] **Tooltips/images for commands** — command tooltips, extended tooltips, custom images.
- [ ] **Quick customize** — add commands to QAT/ribbon from the UI.
- [ ] **CUI search/transfer** — search commands/text, transfer customization between files.

### 18.2 Command aliases, scripts and DIESEL

- [x] **Command aliases** — `acadlt.pgp`, alias editing/reload, external commands.
- [ ] **Command line switches** — `/b`, `/t`, `/c`, `/s`, `/set`, `/v`, `/w`, `/pl`, `/nologo`, `/nossm`, `/nohardware`, `/safemode`.
- [x] **Scripts** — `SCRIPT`, `.scr` files, command sequences, comments, `DELAY`, `RSCRIPT`.
- [ ] **Script at startup** — `/b` switch; Startup Suite for applications; `acadlt.lsp` startup file.
- [ ] **DIESEL** — menu/macro expressions, `MODEMACRO`, status-line customization.
- [ ] **Slides** — `MSLIDE`, `VSLIDE`, slide libraries, slide shows from scripts.
- [ ] **Macro control characters** — special characters in command macros.

### 18.3 AutoLISP and DCL

- [x] **AutoLISP interpreter** `(2024+)` — load and run AutoLISP.
- [~] **APPLOAD** — load/unload applications, Startup Suite, load at startup.
- [x] **AutoLISP language** — functions, variables, lists, error handling, namespaces, reactors.
- [x] **Entity access** — `entget`, `entmod`, `entmake`, selection sets, tables, dictionaries.
- [x] **Command function** — call AutoCAD commands from LISP (`command`, `command-s`), pause for input, pick points.
- [ ] **Reactors** — object/command/drawing reactors (as supported).
- [ ] **DCL dialog boxes** — DCL files, dialog management, tiles/controls.
- [~] **ActiveX from AutoLISP** — limited to Windows/AutoLISP only; no full ActiveX Automation.
- [ ] **Visual LISP IDE** — **not available in LT**; use VS Code AutoLISP extension.
- [ ] **VS Code AutoLISP extension** — create/edit/manage/format AutoLISP files.
- [ ] **Digital signing of AutoLISP** — sign LISP files.
- [~] **AutoLISP startup files** — acadlt.lsp/acadltdoc.lsp equivalents, load order, error handling.
- [ ] **DCL/ActiveX docs coverage** — AutoLISP Developer's Guide and Reference included in LT Help.

### 18.4 Other customization content

- [~] **Custom linetypes** — `.lin` definitions, complex linetypes, `-LINETYPE`.
- [x] **Custom hatch patterns** — `.pat` files, custom pattern definitions.
- [~] **Shapes and fonts** — SHX shape/font creation and compilation (`COMPILE`), shape usage in linetypes/text.
- [x] **Text fonts** — TTF/OTF/SHX, font mapping, big fonts, language fonts.
- [ ] **Templates** — DWT with layers/styles/layouts/page setups.
- [~] **Plot styles** — CTB/STB, plot style tables.
- [~] **Sheet set templates** — DST and sheet creation templates.
- [ ] **Tool palettes** — create/modify, tools from objects/blocks/images, command tools, groups, sharing, properties.
- [ ] **DesignCenter** — content browsing/insertion, favorites.
- [~] **Profiles/settings migration** — ARG, export/import, reset.
- [ ] **System variable monitor** — `SYSVARMONITOR`.

### 18.5 APIs and automation scope

- [x] **AutoLISP** — supported.
- [ ] **ActiveX Automation** — limited: AutoLISP only, Windows only.
- [ ] **Visual LISP** — limited (no VLIDE).
- [ ] **ObjectARX** — **not available**.
- [ ] **Managed .NET** — **not available**.
- [ ] **VBA** — **not available**.
- [ ] **JavaScript API** — **not available**.
- [ ] **Action Recorder** — **not available**.
- [ ] **Express Tools** — **not available** (GATTE, FLATTEN, TXTEXP, TCOUNT, BURST, etc.).
- [ ] **Data Extraction** — **not available**.
- [ ] **CAD Standards (DWS/CHECKSTANDARDS)** — **not available**.

---

## 19. Performance, reliability and security

> **Zephyr evaluation (20 items):** 5 present · 8 partial · 6 missing · 1 N/A.
> GPU rendering (Metal/D3D12/Vulkan), BVH picking, autosave, AUDIT/RECOVER, xref/layer notifications. No secure load, digital signatures, drawing recovery manager or GRAPHICSCONFIG.

- [x] **Hardware acceleration** — GPU use, `GRAPHICSCONFIG`, on/off, diagnostics, font display acceleration `(2025+)`.
- [~] **Memory/graphics tuning** — caches, `DRAGP1`/`DRAGP2`, `INTELLIGENTUPDATE`, `VIEWRES`, `WHIPARC`-related.
- [x] **Drawing open performance** — large annotation-scale sets, 2D file open improvements `(2025+)`.
- [~] **Save performance** — incremental save, `ISAVEPERCENT`, full save on `SAVEAS` `(2027)`.
- [x] **Layout switching performance** — `LAYOUTSPATIALFILTERS` `(2027)`.
- [x] **Pan/zoom performance** — raster images/wipeouts, trace background, layout switching.
- [~] **Array editing performance** — in-place associative array editing `(2027.1)`.
- [x] **AUDIT/RECOVER/RECOVERALL** — integrity checking and repair.
- [ ] **Autosave/backup/recovery** — `.sv$`, `.bak`, Drawing Recovery Manager.
- [ ] **Crash/power-failure recovery** — restore drawings and backups.
- [ ] **TrustedDWG / secure load** — integrity and executable security.
- [ ] **Digital signatures** — drawing signing/validation, timestamps.
- [ ] **Malicious-code protection** — `SECURELOAD`, trusted paths, `/safemode`, recovery guidance.
- [-] **Password protection** — **not available**; use PDF/zip/OS/cloud permissions.
- [~] **Layer/xref/data-link notifications** — unreconciled layers, missing refs, data-link updates.
- [~] **Proxy object display** — proxy graphics, object enablers.
- [~] **Large drawing/coordinate compatibility** — save fidelity, large object limits.
- [~] **File format compatibility** — DWG/DXF round-trip with AutoCAD.
- [ ] **Accessibility/DPI** — palette scaling, high-DPI displays.
- [~] **Logging** — command history log, plot/publish logs, xref log, Activity Insights log.

---

## 20. Quick reference: what LT is and is not (not a Zephyr score)

> This table describes AutoCAD LT itself. For the Zephyr comparison, see the **Evaluation summary** at the top and the per-section `Zephyr evaluation` lines.

| Capability | AutoCAD LT 2027 | Notes |
|---|---|---|
| 2D drafting/detailing | Yes | Core product purpose |
| DWG/DXF/DWT | Yes | TrustedDWG, round-trip |
| Blocks/attributes | Yes | Static + action-based dynamic blocks |
| Dynamic block authoring | Yes (actions/parameters) | Constraint parameters not authorable |
| Parametric constraints | View/consume/edit values | Cannot create/edit constraints |
| Sheet sets | Yes | Cloud/Connected SSM; Web SSM removed |
| Plot/publish (PDF/DWF) | Yes | PC3/CTB/STB, batch publish |
| Xrefs/underlays/images | Yes | PDF/DWF/DGN/raster; view point clouds only |
| AutoLISP | Yes | 2024+; limited ActiveX; no VLIDE |
| VBA/.NET/ObjectARX/JS | No | See Appendix C |
| Action Recorder | No | Full AutoCAD only |
| Data Extraction | No | `ATTEXT` is available |
| CAD Standards | No | DWS/CHECKSTANDARDS absent |
| Express Tools | No | Some commands are native (e.g., OVERKILL) |
| 3D modeling/rendering | No | Open/view 3D, wireframe + hidden only |
| 3D navigation (orbit/walk/fly) | No | No ViewCube/ShowMotion |
| Point clouds | View only | No attach/index/explode |
| Markup Import/Assist | No | DWF Markup Set Manager is available |
| Trace | Yes | Traces palette, comments, COPYFROMTRACE |
| DWG Compare / Xref Compare | Yes | With documented object limitations |
| Count / Smart Blocks / Activity Insights / Assistant | Yes | See §16.3 |
| Toolsets (Architecture, Mechanical, …) | No | Full AutoCAD only |

---

## Appendix A. Command checklist (LT 2027)

> **Zephyr:** 142 implemented · 69 partial · 297 missing (README/changelog/registry review).


All commands documented in the AutoCAD LT 2027 Help command-category pages, plus core commands found outside those pages. The main list is alphabetical and each command appears once, with the LT Help areas that document it; supplemental commands follow at the end. Use the italic area tags to find commands by workflow.

> The LT Help category pages omit a handful of core commands (notably the dimension family and a few customization/cloud commands), which are added below. Descriptions are Autodesk's wording and may mention 3D/advanced behavior that LT limits (see Appendix C).

- [x] `-ATTACH` — From the Command prompt, inserts references to external files such as other drawings, raster images, point clouds, coordination models, and underlays.  *Areas: Working with Underlays.*
- [ ] `-BSEARCH` — At the Command prompt, converts the selected entities and identical instances into blocks.  *Areas: Basic Blocks; Smart Blocks.*
- [ ] `-COMPARE` — At the Command prompt, compares a specified drawing to the current drawing.  *Areas: Working With DWG Compare.*
- [ ] `-DGNBIND` — Binds DGN underlays to the current drawing.  *Areas: Working with Underlays.*
- [ ] `-FIND` — Searches for the text that you specify in the entire drawing, the current space or layout, or selected objects.  *Areas: Changing Text in Notes and Labels.*
- [ ] `-GROUP` — Creates and manages saved sets of objects called groups.  *Areas: Working With Groups.*
- [ ] `-IMAGEADJUST` — Controls the brightness, contrast, and fade values of images.  *Areas: Working with Raster Image Files.*
- [ ] `-LAYMCH` — Changes the layer of a selected object to match the layer of a selected object.  *Areas: Layers.*
- [x] `-PAGESETUP` — Modifies the current page layout settings for the plotting device, paper size, plot scale, and several other settings in the command line.  *Areas: Hiding Lines and Shading 3D Objects; Model Space and Paper Space; Print or Plot Settings; Publishing Settings; Working With Layouts.*
- [x] `-PURGE` — Removes unused named objects, such as block definitions and layers, from the current drawing using the command line.  *Areas: Layers; Linetypes; Purging the Current Drawing; Removing Objects and Correcting Mistakes.*
- [ ] `-VPOINT` — Sets the viewing direction for a 3D visualization of the drawing.  *Areas: Controlling 3D Projection.*
- [ ] `3DPOLY` — Creates a 3D polyline.  *Areas: Curved Geometric Objects.*
- [ ] `ACTIVITYINSIGHTSCLOSE` — Closes the Activity Insights palette which displays activities for the current drawing.  *Areas: Activity Insights.*
- [ ] `ACTIVITYINSIGHTSOPEN` — Opens the Activity Insights palette to view activities for the current drawing.  *Areas: Activity Insights.*
- [ ] `ADCCLOSE` — Closes DesignCenter.  *Areas: DesignCenter.*
- [ ] `ADCENTER` — Manages and inserts content such as blocks, xrefs, and hatch patterns.  *Areas: Basic Blocks; DesignCenter; Working With External References.*
- [ ] `ADCNAVIGATE` — Loads a specified drawing file, folder, or network path in the DesignCenter Folders tab.  *Areas: DesignCenter.*
- [ ] `ADDSELECTED` — Creates a new object of the same type and general properties as a selected object, but with different geometric values.  *Areas: Duplicating Objects.*
- [ ] `ADJUST` — Adjusts the fade, contrast and monochrome settings of the selected underlay (DWF, DWFx, PDF, or DGN), or image.  *Areas: Working with Underlays.*
- [x] `ALIGN` — Aligns objects with other objects in 2D and 3D.  *Areas: Moving and Rotating Objects.*
- [ ] `ANNORESET` — Resets the locations of all alternate scale representations of the selected annotative objects.  *Areas: Annotation Scaling.*
- [ ] `ANNOUPDATE` — Updates existing annotative objects to match the current properties of their styles.  *Areas: Annotation Scaling.*
- [ ] `APERTURE` — Controls the size of the object snap target box.  *Areas: Customizing the Drawing Environment; Object Snap.*
- [ ] `APPLOAD` — Loads and unloads applications and defines which applications to load at startup.  *Areas: Internet Collaboration.*
- [~] `ARC` — Creates an arc.  *Areas: Curved Geometric Objects.*
- [ ] `ARCHIVE` — Packages the current sheet set files for storage.  *Areas: Transmittal Packages; Working With Sheet Sets.*
- [x] `AREA` — Calculates the area and perimeter of objects or of defined areas.  *Areas: Areas and Mass Properties.*
- [x] `ARRAY` — Creates copies of objects arranged in a pattern.  *Areas: Working with Arrays.*
- [x] `ARRAYCLASSIC` — Creates arrays using the legacy dialog box.  *Areas: Working with Arrays.*
- [x] `ARRAYCLOSE` — Saves or discards changes made to an array's source objects and exits the array editing state.  *Areas: Working with Arrays.*
- [x] `ARRAYEDIT` — Edits associative array objects and their source objects.  *Areas: Working with Arrays.*
- [x] `ARRAYPATH` — Evenly distributes object copies along a path or a portion of a path.  *Areas: Working with Arrays.*
- [x] `ARRAYPOLAR` — Evenly distributes object copies in a circular pattern around a center point or axis of rotation.  *Areas: Working with Arrays.*
- [x] `ARRAYRECT` — Distributes object copies into any combination of rows, columns, and levels.  *Areas: Working with Arrays.*
- [x] `ATTACH` — Inserts references to external files such as other drawings, raster images, point clouds, coordination models, and underlays.  *Areas: Working With External References; Working with Underlays.*
- [ ] `ATTACHURL` — Attaches hyperlinks to objects or areas in a drawing.  *Areas: Working With Hyperlinks.*
- [~] `ATTDEF` — Creates an attribute definition for storing data in a block.  *Areas: Block Attributes.*
- [ ] `ATTDISP` — Controls the visibility overrides for all block attributes in a drawing.  *Areas: Block Attributes.*
- [~] `ATTEDIT` — Changes attribute information in a block.  *Areas: Block Attributes.*
- [ ] `ATTEXT` — Extracts attribute data, informational text associated with a block, into a file.  *Areas: Block Attributes.*
- [ ] `ATTIPEDIT` — Changes the textual content of an attribute within a block.  *Areas: Block Attributes.*
- [~] `ATTSYNC` — Applies attribute changes in a block definition to all block references.  *Areas: Block Attributes.*
- [x] `AUDIT` — Evaluates the integrity of a drawing and corrects some errors.  *Areas: Repairing Damaged Drawings; Working With the Application Window.*
- [ ] `AUTOPUBLISH` — Publishes drawings to DWF, DWFx, or PDF files automatically to a specified location.  *Areas: Publishing Digital Drawings.*
- [ ] `BACTION` — Adds an action to a dynamic block definition.  *Areas: Dynamic Blocks.*
- [ ] `BACTIONBAR` — Displays or hides action bars for a selection set of parameter objects.  *Areas: Dynamic Blocks.*
- [ ] `BACTIONSET` — Specifies the selection set of objects associated with an action in a dynamic block definition.  *Areas: Dynamic Blocks.*
- [ ] `BACTIONTOOL` — Adds an action to a dynamic block definition.  *Areas: Dynamic Blocks.*
- [x] `BASE` — Sets the insertion base point for the current drawing.  *Areas: Basic Blocks; Working With External References.*
- [ ] `BASSOCIATE` — Associates an action with a parameter in a dynamic block definition.  *Areas: Dynamic Blocks.*
- [ ] `BATTMAN` — Manages the attributes for a selected block definition.  *Areas: Block Attributes.*
- [ ] `BATTORDER` — Specifies the order of attributes for a block.  *Areas: Block Attributes.*
- [ ] `BAUTHORPALETTE` — Opens the Block Authoring Palettes window in the Block Editor.  *Areas: Dynamic Blocks.*
- [ ] `BAUTHORPALETTECLOSE` — Closes the Block Authoring Palettes window in the Block Editor.  *Areas: Dynamic Blocks.*
- [x] `BCLOSE` — Closes the Block Editor.  *Areas: Basic Blocks; Dynamic Blocks.*
- [ ] `BCONSTRUCTION` — Converts block geometry into construction geometry, which may be hidden or displayed.  *Areas: Basic Blocks; Construction Geometry.*
- [ ] `BCYCLEORDER` — Changes the cycling order of grips for a dynamic block reference.  *Areas: Dynamic Blocks.*
- [x] `BEDIT` — Opens the block definition in the Block Editor.  *Areas: Basic Blocks; Dynamic Blocks; Working With Dynamic Block Constraints.*
- [ ] `BESETTINGS` — Displays the Block Editor Settings dialog box.  *Areas: Dynamic Blocks; Working With Dynamic Block Constraints.*
- [ ] `BGRIPSET` — Creates, deletes, or resets grips associated with a parameter.  *Areas: Dynamic Blocks.*
- [ ] `BLEND` — Creates a spline in the gap between two selected lines or curves.  *Areas: Curved Geometric Objects.*
- [x] `BLOCK` — Creates a block definition from selected objects.  *Areas: Basic Blocks; Dynamic Blocks; Saving Drawings.*
- [ ] `BLOCKICON` — Generates preview images for blocks displayed in DesignCenter.  *Areas: DesignCenter.*
- [x] `BLOCKSPALETTE` — Displays the Blocks palette, which you can use to insert blocks and drawings into the current drawing.  *Areas: Basic Blocks; Dynamic Blocks; Starting Drawings.*
- [x] `BLOCKSPALETTECLOSE` — Closes the Blocks palette.  *Areas: Basic Blocks; Dynamic Blocks; Starting Drawings.*
- [ ] `BLOOKUPTABLE` — Displays or creates a lookup table for a dynamic block definition.  *Areas: Dynamic Blocks.*
- [ ] `BMPOUT` — Saves selected objects to a file in device-independent bitmap format.  *Areas: Exporting Raster Files.*
- [x] `BOUNDARY` — Creates regions or a polylines from enclosed areas.  *Areas: Linear Geometric Objects; Regions and Areas.*
- [ ] `BPARAMETER` — Adds a parameter with grips to a dynamic block definition.  *Areas: Dynamic Blocks.*
- [x] `BREAK` — Breaks the selected object between two points.  *Areas: Editing Specific Objects; Removing Objects and Correcting Mistakes.*
- [x] `BREAKATPOINT` — Breaks the selected object into two objects at a specified point.  *Areas: Editing Specific Objects; Removing Objects and Correcting Mistakes.*
- [ ] `BROWSER` — Launches the default web browser defined in your system's registry.  *Areas: Internet Collaboration.*
- [ ] `BSAVE` — Saves the current block definition.  *Areas: Dynamic Blocks.*
- [ ] `BSAVEAS` — Saves a copy of the current block definition under a new name.  *Areas: Dynamic Blocks.*
- [ ] `BSEARCH` — Displays the Convert dialog box, which provides options to convert selected entities and identical instances into blocks.  *Areas: Basic Blocks; Smart Blocks.*
- [ ] `BTABLE` — Stores variations of a block in the Block Properties Table.  *Areas: Dynamic Blocks; Working With Dynamic Block Constraints.*
- [ ] `BTESTBLOCK` — Displays a window within the Block Editor to test a dynamic block.  *Areas: Dynamic Blocks.*
- [ ] `BVHIDE` — Makes objects invisible in the current visibility state or all visibility states in a dynamic block definition.  *Areas: Dynamic Blocks.*
- [ ] `BVSHOW` — Makes objects visible in the current visibility state or all visibility states in a dynamic block definition.  *Areas: Dynamic Blocks.*
- [ ] `BVSTATE` — Creates, sets, or deletes a visibility state in a dynamic block.  *Areas: Dynamic Blocks.*
- [ ] `CAL` — Evaluates mathematical and geometric expressions at the Command prompt or within a command.  *Areas: the Command Prompt Calculator.*
- [ ] `CENTERDISASSOCIATE` — Removes associativity of center marks or centerlines from objects they define.  *Areas: Center Marks and Centerlines.*
- [~] `CENTERLINE` — Creates centerline geometry associated with selected lines and linear polyline segments.  *Areas: Center Marks and Centerlines.*
- [~] `CENTERMARK` — Creates an associative, cross-shaped mark at the center of a selected circle or arc.  *Areas: Center Marks and Centerlines.*
- [ ] `CENTERREASSOCIATE` — Associates or reassociates a center mark or centerline object to selected objects.  *Areas: Center Marks and Centerlines.*
- [ ] `CENTERRESET` — Resets the centerlines to the current value specified in the CENTEREXE system variable.  *Areas: Center Marks and Centerlines.*
- [x] `CHAMFER` — Bevels or chamfers the edges of two 2D objects or the adjacent faces of a 3D solid.  *Areas: Creating Fillets and Chamfers.*
- [x] `CHANGE` — Changes the properties of existing objects.  *Areas: Layers; Object Display Control; Property Tools.*
- [x] `CHPROP` — Changes the properties of an object.  *Areas: Layers; Object Display Control; Property Tools.*
- [x] `CHSPACE` — On a layout, transfers selected objects between model space and paper space.  *Areas: Model Space and Paper Space.*
- [x] `CIRCLE` — Creates a circle.  *Areas: Curved Geometric Objects.*
- [ ] `CLASSICINSERT` — Inserts a block or drawing into the current drawing using the classic version of the INSERT command.  *Areas: Basic Blocks; Dynamic Blocks; Starting Drawings.*
- [ ] `CLASSICLAYER` — Opens the legacy Layer Properties Manager.  *Areas: Layers.*
- [x] `CLEANSCREENOFF` — Restores the state of the display before CLEANSCREENON was used.  *Areas: Customizing the Drawing Environment.*
- [x] `CLEANSCREENON` — Clears the screen of toolbars and dockable windows, excluding the command window.  *Areas: Customizing the Drawing Environment.*
- [x] `CLOSE` — Closes the current drawing.  *Areas: Working With the Application Window.*
- [ ] `COLOR` — Sets the color for new objects.  *Areas: Colors.*
- [x] `COMMANDLINE` — Displays the Command window.  *Areas: Working With the Application Window.*
- [ ] `COMMANDLINEHIDE` — Hides the Command window.  *Areas: Working With the Application Window.*
- [ ] `COMPARE` — Compares a specified drawing file with the current drawing file, highlighting the differences with color within revision clouds.  *Areas: Working With DWG Compare.*
- [ ] `COMPARECLOSE` — Closes the DWG Compare toolbar and ends the comparison.  *Areas: Working With DWG Compare.*
- [ ] `COMPAREEXPORT` — Exports the results of the comparison into a new drawing file, called a snapshot drawing.  *Areas: Working With DWG Compare.*
- [ ] `COMPAREIMPORT` — Imports objects from the compared drawing into the current drawing.  *Areas: Working With DWG Compare.*
- [ ] `COMPAREINFO` — Provides a way to insert or copy the property information about the two compared drawing files.  *Areas: Working With DWG Compare.*
- [~] `CONSTRAINTBAR` — Displays or hides the geometric constraints on an object.  *Areas: Geometric Constraints; Parametric Drawing.*
- [ ] `CONSTRAINTSETTINGS` — Controls the display of geometric constraints on constraint bars.  *Areas: Geometric Constraints; Parametric Drawing.*
- [ ] `CONVERTCTB` — Converts a color-dependent plot style table (CTB) to a named plot style table (STB).  *Areas: Print or Plot Settings.*
- [ ] `CONVERTPSTYLES` — Converts the current drawing to either named or color-dependent plot styles.  *Areas: Print or Plot Settings.*
- [x] `COPY` — Copies objects a specified distance in a specified direction.  *Areas: Duplicating Objects; Editing Specific Objects.*
- [x] `COPYBASE` — Copies selected objects to the Clipboard along with a specified base point.  *Areas: Duplicating Objects; Editing Specific Objects.*
- [x] `COPYCLIP` — Copies selected objects to the Clipboard.  *Areas: Duplicating Objects; Editing Specific Objects; Object Linking and Embedding (OLE); Working With the Application Window.*
- [ ] `COPYHIST` — Copies the text in the command line history to the Clipboard.  *Areas: Editing Specific Objects; Working With the Application Window.*
- [ ] `COPYLINK` — Copies the current view to the Clipboard for linking to other OLE applications.  *Areas: Editing Specific Objects; Object Linking and Embedding (OLE).*
- [x] `COPYTOLAYER` — Copies one or more objects to another layer.  *Areas: Editing Specific Objects; Layers.*
- [ ] `COUNT` — Counts and highlights the instances of the selected object in the drawing.  *Areas: Counting Objects.*
- [ ] `COUNTAREA` — Defines the area to count the instances of an object or block.  *Areas: Counting Objects.*
- [ ] `COUNTAREACLOSE` — Cancels the count selection area.  *Areas: Counting Objects.*
- [ ] `COUNTCLOSE` — Closes the Count toolbar and exits the count.  *Areas: Counting Objects.*
- [ ] `COUNTFIELD` — Creates a field that's set to the value of the current count.  *Areas: Counting Objects.*
- [ ] `COUNTLIST` — Opens the Count palette to display and manage the counted blocks.  *Areas: Counting Objects.*
- [ ] `COUNTLISTCLOSE` — Closes the Count palette.  *Areas: Counting Objects.*
- [ ] `COUNTNAVNEXT` — Zooms to the next object in the count result.  *Areas: Counting Objects.*
- [ ] `COUNTNAVPREV` — Zooms to the previous object in the count result.  *Areas: Counting Objects.*
- [ ] `COUNTTABLE` — Inserts a table containing the block names and the corresponding count of each block in the drawing.  *Areas: Counting Objects.*
- [ ] `CUI` — Manages the customized user interface elements in the product.  *Areas: Customizing the Drawing Environment; Tool Palettes; Working With the Application Window.*
- [ ] `CUSTOMIZE` — Customizes tool palettes and tool palette groups.  *Areas: Tool Palettes.*
- [ ] `CUTBASE` — Copies selected objects to the Clipboard, along with a specified base point, and removes them from the drawing.  *Areas: Duplicating Objects; Editing Specific Objects; Removing Objects and Correcting Mistakes.*
- [ ] `CUTCLIP` — Copies selected objects to the Clipboard and removes them from the drawing.  *Areas: Object Linking and Embedding (OLE); Removing Objects and Correcting Mistakes; Working With the Application Window.*
- [ ] `DATALINK` — Displays the Data Link dialog box.  *Areas: Tables.*
- [ ] `DATALINKUPDATE` — Updates data to or from an established external data link.  *Areas: Tables.*
- [ ] `DBLIST` — Lists database information for each object in the drawing.  *Areas: Areas and Mass Properties; Distances and Angles.*
- [ ] `DCDISPLAY` — Displays or hides the dynamic constraints associated with a selection set of objects.  *Areas: Dimensional Constraints.*
- [~] `DELCONSTRAINT` — Removes all geometric and dimensional constraints from a selection set of objects.  *Areas: Dimensional Constraints; Geometric Constraints; Parametric Drawing.*
- [ ] `DETACHURL` — Removes hyperlinks in a drawing.  *Areas: Working With Hyperlinks.*
- [ ] `DGNADJUST` — Adjust the fade, contrast, and monochrome settings of a DGN underlay.  *Areas: Working with Underlays.*
- [ ] `DGNATTACH` — Inserts a DGN file as an underlay into the current drawing.  *Areas: Working With External References; Working with Underlays.*
- [ ] `DGNCLIP` — Crops the display of a selected DGN underlay to a specified boundary.  *Areas: Working With External References; Working with Underlays.*
- [ ] `DGNEXPORT` — Creates one or more DGN files from the current drawing.  *Areas: Importing and Exporting Microstation DGN Files.*
- [ ] `DGNIMPORT` — Imports the data from a DGN file into a new DWG file or the current DWG file, depending on the DGNIMPORTMODE system variable.  *Areas: Importing and Exporting Microstation DGN Files.*
- [ ] `DGNLAYERS` — Controls the display of layers in a DGN underlay.  *Areas: Working with Underlays.*
- [ ] `DGNMAPPING` — Allows users to create and edit user-defined DGN mapping setups.  *Areas: Importing and Exporting Microstation DGN Files.*
- [x] `DIM` — Creates multiple dimensions and types of dimensions with a single command.  *Areas: Basic Dimensioning.*
- [~] `DIMANGULAR` — Creates an angular dimension.  *Areas: Basic Dimensioning.*
- [~] `DIMARC` — Creates an arc length dimension.  *Areas: Basic Dimensioning.*
- [~] `DIMBREAK` — Breaks or restores dimension and extension lines where they cross other objects.  *Areas: Basic Dimensioning; Dimension Breaks.*
- [~] `DIMDIAMETER` — Creates a diameter dimension for a circle or an arc.  *Areas: Basic Dimensioning.*
- [x] `DIMDISASSOCIATE` — Removes associativity from selected dimensions.  *Areas: Modifying Dimension Geometry.*
- [~] `DIMEDIT` — Edits dimension text and extension lines.  *Areas: Basic Dimensioning; Modifying Dimension Geometry; Modifying Dimension Text.*
- [ ] `DIMINSPECT` — Adds or removes inspection information for a selected dimension.  *Areas: Inspection Dimensions.*
- [~] `DIMJOGGED` — Creates jogged dimensions for circles and arcs.  *Areas: Basic Dimensioning.*
- [~] `DIMLINEAR` — Creates a linear dimension.  *Areas: Basic Dimensioning.*
- [~] `DIMORDINATE` — Creates ordinate dimensions.  *Areas: Basic Dimensioning.*
- [ ] `DIMOVERRIDE` — Controls overrides of system variables used in selected dimensions.  *Areas: Dimension Style Overrides.*
- [~] `DIMRADIUS` — Creates a radius dimension for a circle or an arc.  *Areas: Basic Dimensioning.*
- [~] `DIMREASSOCIATE` — Associates or reassociates selected dimensions to objects or points on objects.  *Areas: Associative Dimensioning; Modifying Dimension Geometry.*
- [ ] `DIMREGEN` — Updates the locations of all associative dimensions.  *Areas: Associative Dimensioning.*
- [~] `DIMSPACE` — Adjusts the spacing between linear dimensions or angular dimensions.  *Areas: Dimension Spacing.*
- [~] `DIMSTYLE` — Creates and modifies dimension styles.  *Areas: Associative Dimensioning; Basic Dimensioning; Dimension Breaks; Dimension Scales; Dimension Style Overrides; Dimension Styles.*
- [~] `DIMTEDIT` — Moves and rotates dimension text and relocates the dimension line.  *Areas: Basic Dimensioning; Modifying Dimension Text.*
- [x] `DIST` — Measures the distance and angle between two points.  *Areas: Distances and Angles.*
- [x] `DIVIDE` — Creates evenly spaced point objects or blocks along the length or perimeter of an object.  *Areas: Measuring and Dividing.*
- [ ] `DLINE` — Creates a double line using straight line segments and arcs.  *Areas: Linear Geometric Objects.*
- [x] `DONUT` — Creates a filled circle or a wide ring.  *Areas: Curved Geometric Objects.*
- [ ] `DRAGMODE` — Controls the way dragged objects are displayed.  *Areas: Customizing the Drawing Environment.*
- [ ] `DRAWINGRECOVERY` — Displays a list of drawing files that can be recovered after a program or system failure.  *Areas: Recovering From a Crash or Power Failure.*
- [ ] `DRAWINGRECOVERYHIDE` — Closes the Drawing Recovery Manager.  *Areas: Recovering From a Crash or Power Failure.*
- [x] `DRAWORDER` — Changes the draw order of images and other objects.  *Areas: Object Display Control.*
- [ ] `DSETTINGS` — Sets grid and snap, polar and object snap tracking, object snap modes, Dynamic Input, and Quick Properties.  *Areas: 2D Isometric Drawing; Dynamic Input Tooltips; Grid and Grid Snap; Object Snap Tracking (AutoTrack); Polar Tracking and PolarSnap.*
- [ ] `DWFADJUST` — Adjust the fade, contrast, and monochrome settings of a DWF or DWFx underlay.  *Areas: Working With DWF Files and Markup.*
- [ ] `DWFATTACH` — Inserts a DWF or DWFx file as an underlay into the current drawing.  *Areas: Working With DWF Files and Markup; Working With External References; Working with Underlays.*
- [ ] `DWFCLIP` — Crops the display of a selected DWF or DWFx underlay to a specified boundary.  *Areas: Working With DWF Files and Markup; Working With External References; Working with Underlays.*
- [ ] `DWFFORMAT` — Sets the default format to DWF or DWFx for output in specific commands.  *Areas: Exporting PDF, DWF, and DWFx Files.*
- [ ] `DWFLAYERS` — Controls the display of layers in a DWF or DWFx underlay.  *Areas: Working With DWF Files and Markup; Working with Underlays.*
- [ ] `DWGPROPS` — Sets and displays the file properties of the current drawing.  *Areas: Starting Drawings; Working With Hyperlinks.*
- [ ] `EATTEDIT` — Edits attributes in a block reference.  *Areas: Block Attributes.*
- [x] `ELLIPSE` — Creates an ellipse or an elliptical arc.  *Areas: 2D Isometric Drawing; Curved Geometric Objects.*
- [x] `ERASE` — Removes objects from a drawing.  *Areas: Removing Objects and Correcting Mistakes.*
- [ ] `ETRANSMIT` — Packages a set of files for Internet transmission.  *Areas: Transmittal Packages.*
- [x] `EXPLODE` — Breaks a compound object into its component objects.  *Areas: Basic Blocks; Editing Specific Objects; Modifying Dimension Geometry.*
- [ ] `EXPORT` — Saves the objects in a drawing to a different file format.  *Areas: Exporting PDF, DWF, and DWFx Files; Exporting Raster Files; Importing and Exporting Microstation DGN Files; Importing and Exporting Windows Metafiles (WMF Files); Internet Collaboration; Publishing Settings.*
- [ ] `EXPORTDWF` — Creates a DWF file and allows you to set individual page setup overrides on a sheet-by-sheet basis.  *Areas: Exporting PDF, DWF, and DWFx Files; Internet Collaboration.*
- [ ] `EXPORTDWFX` — Creates a DWFx file where you can set individual page setup overrides on a sheet-by-sheet basis.  *Areas: Exporting PDF, DWF, and DWFx Files; Internet Collaboration.*
- [ ] `EXPORTLAYOUT` — Creates a visual representation of the current layout in the model space of a new drawing.  *Areas: Working With Layouts.*
- [~] `EXPORTPDF` — Generates a PDF file from a single layout, all layouts, or a specified area in model space.  *Areas: Exporting PDF, DWF, and DWFx Files.*
- [ ] `EXPORTSETTINGS` — Adjusts the page setup and drawing selection when exporting to a DWF, DWFx, or PDF file.  *Areas: Exporting PDF, DWF, and DWFx Files.*
- [~] `EXTEND` — Extends objects to meet the edges of other objects.  *Areas: Resizing Objects.*
- [~] `EXTERNALREFERENCES` — Opens the External References palette.  *Areas: Editing External References; Improving Performance When Using Xrefs; Resolving Xref Errors; Working With External References; Working with Raster Image Files; Working with Underlays.*
- [ ] `EXTERNALREFERENCESCLOSE` — Closes the External References palette.  *Areas: Working With External References.*
- [~] `FIELD` — Creates a multiline text object with a field that can be updated automatically as the field value changes.  *Areas: Tables; Text Styles and Fields.*
- [ ] `FILL` — Controls the display of filled objects such as hatches, 2D solids, and wide polylines.  *Areas: Curved Geometric Objects; Linear Geometric Objects; Object Display Control.*
- [x] `FILLET` — Rounds or fillets the edges of two 2D objects or the adjacent faces of a 3D solid.  *Areas: Creating Fillets and Chamfers.*
- [x] `FILTER` — Creates a list of requirements that an object must meet to be included in a selection set.  *Areas: Selecting Objects.*
- [x] `FIND` — Finds the text that you specify, and can optionally replace it with other text.  *Areas: Changing Text in Notes and Labels.*
- [ ] `FINDINCLUDE` — Controls the types of text objects included in a search when using the -FIND command.  *Areas: Changing Text in Notes and Labels.*
- [ ] `FINDMATCH` — Controls how the entered text string is compared with text in objects when using the -FIND command.  *Areas: Changing Text in Notes and Labels.*
- [ ] `GEOGRAPHICLOCATION` — Assigns geographic location information to a drawing file.  *Areas: Starting Drawings; Working with Geographic Locations.*
- [ ] `GEOMAP` — Displays a map from an online maps service, in the current viewport.  *Areas: Working with Geographic Locations.*
- [ ] `GEOMAPIMAGE` — Captures a portion of the online map to an object known as a map image, and embeds it in the drawing area.  *Areas: Working with Geographic Locations.*
- [ ] `GEOMAPIMAGEUPDATE` — Updates map images from the online maps service and optionally resets their resolution for optimal on-screen viewing.  *Areas: Working with Geographic Locations.*
- [ ] `GEOMARKLATLONG` — Places a position marker at a location defined by latitude and longitude.  *Areas: Working with Geographic Locations.*
- [ ] `GEOMARKME` — Places a position marker in the drawing area at the coordinates corresponding to your current position.  *Areas: Working with Geographic Locations.*
- [ ] `GEOMARKPOINT` — Places a position marker at a specified point in model space.  *Areas: Working with Geographic Locations.*
- [ ] `GEOMARKPOSITION` — Places a position marker at a location you specify.  *Areas: Working with Geographic Locations.*
- [ ] `GEOMETRYCLEANUPCLOSE` — Closes the Geometry Cleanup palette.  *Areas: Resizing Objects.*
- [ ] `GEOMETRYCLEANUPOPEN` — Opens the Geometry Cleanup palette which displays potential gap, overshoot, undershoot, and angular errors for the current drawing.  *Areas: Resizing Objects.*
- [ ] `GEOMETRYERRORREVIEWCLOSE` — Exits the Geometry Cleanup review mode.  *Areas: Resizing Objects.*
- [ ] `GEOREMOVE` — Removes all geographic location information from the drawing file.  *Areas: Working with Geographic Locations.*
- [ ] `GEOREORIENTMARKER` — Changes the north direction and position of the geographic marker in model space, without changing its latitude and longitude.  *Areas: Working with Geographic Locations.*
- [ ] `GETENV` — Displays values of specified system registry variables.  *Areas: Working with Arrays.*
- [ ] `GOTOSTART` — Switches from the current drawing to the Start tab.  *Areas: Working With the Start Tab.*
- [ ] `GOTOURL` — Opens the file or web page associated with the hyperlink attached to an object.  *Areas: Working With Hyperlinks.*
- [x] `GRADIENT` — Fills an enclosed area or selected objects with a gradient fill.  *Areas: Hatches and Gradients.*
- [ ] `GRAPHICSCONFIG` — Sets hardware acceleration on or off and provides access to display performance options.  *Areas: Customizing the Drawing Environment.*
- [ ] `GRAPHSCR` — Causes the text window to display behind the application window.  *Areas: Working With the Application Window.*
- [x] `GRID` — Displays a grid pattern in the current viewport.  *Areas: 2D Isometric Drawing; Grid and Grid Snap.*
- [~] `GROUP` — Creates and manages saved sets of objects called groups.  *Areas: Working With Groups.*
- [ ] `GROUPEDIT` — Adds and removes objects from the selected group, or renames a selected group.  *Areas: Working With Groups.*
- [~] `HATCH` — Fills an enclosed area or selected objects with a hatch pattern, solid fill, or gradient fill.  *Areas: Hatches and Gradients.*
- [x] `HATCHEDIT` — Modifies an existing hatch or fill.  *Areas: Hatches and Gradients.*
- [x] `HATCHTOBACK` — Sets the draw order for all hatches in the drawing to be behind all other objects.  *Areas: Hatches and Gradients; Object Display Control.*
- [ ] `HIDE` — Displays a 3D model with hidden lines suppressed for the 2D Wireframe visual style.  *Areas: Hiding Lines and Shading 3D Objects.*
- [x] `HIDEOBJECTS` — Temporarily suppresses the display of selected objects.  *Areas: Object Display Control.*
- [ ] `HIDEPALETTES` — Hides all displayed palettes, along with the ribbon and the drawing tabs.  *Areas: Customizing the Drawing Environment; Tool Palettes.*
- [ ] `HLSETTINGS` — Sets the display of such properties as hidden lines.  *Areas: Hiding Lines and Shading 3D Objects.*
- [ ] `HYPERLINK` — Attaches a hyperlink to an object or modifies an existing hyperlink.  *Areas: Internet Collaboration; Transmittal Packages; Working With Hyperlinks.*
- [ ] `HYPERLINKOPTIONS` — Controls the display of the hyperlink cursor, tooltips, and shortcut menu.  *Areas: Working With Hyperlinks.*
- [x] `ID` — Displays the UCS coordinate values of a specified location.  *Areas: Displaying Coordinates; Distances and Angles.*
- [~] `IMAGE` — Displays the External References palette.  *Areas: Working with Raster Image Files.*
- [~] `IMAGEADJUST` — Controls the brightness, contrast, and fade values of images.  *Areas: Working with Raster Image Files.*
- [ ] `IMAGEASYNCWAIT` — Ensures that raster images being loaded in the background during file opening are complete before proceeding.  *Areas: Working with Raster Image Files.*
- [~] `IMAGEATTACH` — Inserts a reference to an image file.  *Areas: Working With External References; Working with Raster Image Files; Working with Underlays.*
- [~] `IMAGECLIP` — Crops the display of a selected image to a specified boundary.  *Areas: Working With External References; Working with Raster Image Files.*
- [ ] `IMAGEQUALITY` — Controls the display quality of images.  *Areas: Working with Raster Image Files.*
- [ ] `IMPORT` — Imports files of different formats into the current drawing.  *Areas: Importing and Exporting Microstation DGN Files; Importing and Exporting Windows Metafiles (WMF Files).*
- [ ] `INPUTSEARCHOPTIONS` — Opens a dialog box that controls settings for display of the command line suggestion list for commands, system variables, and named objects.  *Areas: Working With the Application Window.*
- [x] `INSERT` — Displays the Blocks palette, which you can use to insert blocks and drawings into the current drawing.  *Areas: Basic Blocks; Dynamic Blocks; Starting Drawings.*
- [ ] `INSERTOBJ` — Inserts a linked or embedded object.  *Areas: Object Linking and Embedding (OLE).*
- [ ] `INTERSECT` — Creates a 2D region from selected overlapping regions.  *Areas: Regions and Areas.*
- [ ] `ISODRAFT` — Turns isometric drafting settings on or off, and specifies the current 2D isometric drafting plane.  *Areas: 2D Isometric Drawing.*
- [x] `ISOLATEOBJECTS` — Temporarily suppresses the display of all objects except those you select.  *Areas: Object Display Control.*
- [ ] `ISOPLANE` — Specifies the current plane for 2D isometric drawing.  *Areas: 2D Isometric Drawing.*
- [x] `JOIN` — Joins the endpoints of linear and curved objects to create a single object.  *Areas: Editing Specific Objects; Removing Objects and Correcting Mistakes.*
- [ ] `JPGOUT` — Saves selected objects to a file in JPEG file format.  *Areas: Exporting Raster Files.*
- [ ] `JUSTIFYTEXT` — Changes the justification point of selected text objects without changing their locations.  *Areas: Changing Text in Notes and Labels.*
- [ ] `LAYCUR` — Changes the layer property of selected objects to the current layer.  *Areas: Layers.*
- [x] `LAYDEL` — Deletes all objects on a layer and purges the layer.  *Areas: Layers; Purging the Current Drawing; Removing Objects and Correcting Mistakes.*
- [x] `LAYER` — Manages layers and layer properties.  *Areas: Layers.*
- [ ] `LAYERCLOSE` — Closes the Layer Properties Manager.  *Areas: Layers.*
- [x] `LAYERP` — Undoes the last change or set of changes made to layer settings.  *Areas: Layers.*
- [ ] `LAYERPMODE` — Turns on and off the tracking of changes made to layer settings for use by the LAYERP command.  *Areas: Layers.*
- [x] `LAYERSTATE` — Saves, restores, and manages sets of layer settings that are called layer states.  *Areas: Layers.*
- [ ] `LAYERSTATESAVE` — Displays the New Layer State to Save dialog box, where you can provide a name and a description for a new layer state.  *Areas: Layers.*
- [x] `LAYFRZ` — Freezes the layer of selected objects.  *Areas: Layers.*
- [x] `LAYISO` — Hides or locks all layers except those of the selected objects.  *Areas: Layers.*
- [x] `LAYMCH` — Changes the layer of a selected object to match the destination layer.  *Areas: Layers.*
- [x] `LAYMCUR` — Sets the current layer to that of a selected object.  *Areas: Layers.*
- [x] `LAYMRG` — Merges selected layers into a target layer, removing them from the drawing.  *Areas: Layers; Purging the Current Drawing; Removing Objects and Correcting Mistakes.*
- [x] `LAYOFF` — Turns off the layer of a selected object.  *Areas: Layers.*
- [x] `LAYON` — Turns on all layers in the drawing.  *Areas: Layers.*
- [~] `LAYOUT` — Creates and modifies drawing layouts.  *Areas: Working With Layouts.*
- [ ] `LAYOUTWIZARD` — Creates a new layout tab and specifies page and plot settings.  *Areas: Working With Layouts.*
- [x] `LAYTHW` — Thaws all layers in the drawing.  *Areas: Layers.*
- [x] `LAYULK` — Unlocks the layer of a selected object.  *Areas: Layers.*
- [x] `LAYUNISO` — Restores all layers that were hidden or locked with the LAYISO command.  *Areas: Layers.*
- [ ] `LAYVPI` — Freezes selected layers in all layout viewports except the current viewport.  *Areas: Layers.*
- [x] `LAYWALK` — Displays objects on selected layers and hides objects on all other layers.  *Areas: Layers.*
- [~] `LEADER` — Creates a line that connects annotation to a feature.  *Areas: Creating Leaders; Geometric Tolerances.*
- [ ] `LENGTHEN` — Changes the length of objects and the included angle of arcs.  *Areas: Resizing Objects.*
- [ ] `LIMITS` — Sets an invisible rectangular boundary in the drawing area that can limit the grid display and limit clicking or entering point locations.  *Areas: Grid and Grid Snap.*
- [x] `LINE` — Create a series of contiguous line segments. Each segment is a line object that can be edited separately.  *Areas: Linear Geometric Objects.*
- [ ] `LINETYPE` — Loads, sets, and modifies linetypes.  *Areas: Linetypes.*
- [x] `LIST` — Displays property data for selected objects.  *Areas: Areas and Mass Properties; Distances and Angles.*
- [ ] `LOGFILEOFF` — Closes the command history log file opened by LOGFILEON.  *Areas: Working With the Application Window.*
- [ ] `LOGFILEON` — Writes the contents of the command history to a file.  *Areas: Working With the Application Window.*
- [ ] `LTSCALE` — Sets the global linetype scale factor.  *Areas: Linetypes; Model Space and Paper Space.*
- [ ] `LWEIGHT` — Sets the current lineweight, lineweight display options, and lineweight units.  *Areas: Lineweights; Object Display Control.*
- [ ] `MARKUP` — Opens the Markup Set Manager.  *Areas: Working With DWF Files and Markup.*
- [ ] `MARKUPCLOSE` — Closes the Markup Set Manager.  *Areas: Working With DWF Files and Markup.*
- [ ] `MASSPROP` — Calculates the mass properties of selected 2D regions or 3D solids.  *Areas: Areas and Mass Properties; Regions and Areas.*
- [x] `MATCHPROP` — Applies the properties of a selected object to other objects.  *Areas: Hatches and Gradients; Object Properties; Property Tools.*
- [x] `MEASURE` — Creates point objects or blocks at measured intervals along the length or perimeter of an object.  *Areas: Measuring and Dividing.*
- [x] `MEASUREGEOM` — Measures the distance, radius, angle, area, and volume of selected objects, a sequence of points, or dynamically.  *Areas: Areas and Mass Properties; Distances and Angles.*
- [x] `MIRROR` — Creates a mirrored copy of selected objects.  *Areas: Duplicating Objects; Editing Specific Objects.*
- [~] `MLEADER` — Creates a multileader object.  *Areas: Creating Leaders.*
- [x] `MLEADERALIGN` — Aligns and spaces selected multileader objects.  *Areas: Creating Leaders.*
- [x] `MLEADERCOLLECT` — Organizes selected multileaders that contain blocks into rows or columns, and displays the result with a single leader.  *Areas: Creating Leaders.*
- [x] `MLEADEREDIT` — Adds leader lines to, or removes leader lines from, a multileader object.  *Areas: Creating Leaders.*
- [~] `MLEADERSTYLE` — Creates and modifies multileader styles.  *Areas: Creating Leaders.*
- [ ] `MOCORO` — Moves, copies, rotates, and scales selected objects with a single command.  *Areas: Duplicating Objects; Moving and Rotating Objects.*
- [x] `MODEL` — Switches from a named layout tab to the Model tab.  *Areas: Model Space and Paper Space; Working With Layouts.*
- [x] `MOVE` — Moves objects a specified distance in a specified direction.  *Areas: Moving and Rotating Objects.*
- [ ] `MREDO` — Reverses the effects of several previous UNDO or U commands.  *Areas: Removing Objects and Correcting Mistakes.*
- [x] `MSPACE` — In a layout, switches from paper space to model space in a layout viewport.  *Areas: Working With Layouts.*
- [ ] `MTEDIT` — Edits multiline text.  *Areas: Changing Text in Notes and Labels.*
- [x] `MTEXT` — Creates a multiline text object.  *Areas: Changing Text in Notes and Labels; Creating Text for Notes and Labels.*
- [ ] `MULTIPLE` — Repeats the next command until canceled.  *Areas: Working With the Application Window.*
- [~] `MVIEW` — Creates and controls layout viewports.  *Areas: Hiding Lines and Shading 3D Objects; Working With Layouts; Working with Layout Viewports.*
- [ ] `NAVBAR` — Provides access to viewing tools from a unified interface.  *Areas: the Navigation Bar.*
- [ ] `NAVSWHEEL` — Provides access to enhanced navigation tools that are quickly accessible from the cursor.  *Areas: SteeringWheels.*
- [~] `NCOPY` — Copies objects that are contained in an xref, block, or DGN underlay.  *Areas: Duplicating Objects; Editing External References; Working with Underlays.*
- [x] `NEW` — Starts a new drawing.  *Areas: Starting Drawings; Working With the Application Window.*
- [~] `NEWSHEETSET` — Creates a new sheet set data file that manages drawing layouts, file paths, and project data.  *Areas: Working With Sheet Sets.*
- [ ] `NEWVIEW` — Saves a new, named view from the display in the current viewport, or by defining a rectangular window.  *Areas: Saving and Restoring Views.*
- [ ] `OBJECTSCALE` — Adds or deletes supported scales for annotative objects.  *Areas: Annotation Scaling.*
- [x] `OFFSET` — Creates concentric circles, parallel lines, and parallel curves.  *Areas: Curved Geometric Objects.*
- [ ] `OLECONVERT` — Specifies a different source application for an embedded OLE object, and controls whether the OLE object is represented by an icon.  *Areas: Object Linking and Embedding (OLE).*
- [ ] `OLELINKS` — Updates, changes, and cancels a selected linked OLE object.  *Areas: Object Linking and Embedding (OLE).*
- [ ] `OLEOPEN` — Opens the selected OLE object in its source application.  *Areas: Object Linking and Embedding (OLE).*
- [ ] `OLERESET` — Restores the selected OLE object to its original size and shape.  *Areas: Object Linking and Embedding (OLE).*
- [ ] `OLESCALE` — Controls the size, scale, and other properties of a selected OLE object.  *Areas: Object Linking and Embedding (OLE).*
- [x] `OOPS` — Restores erased objects.  *Areas: Removing Objects and Correcting Mistakes.*
- [x] `OPEN` — Opens an existing drawing file.  *Areas: Importing and Exporting DXF Files; Internet Collaboration; Opening Drawings; Starting Drawings; Working With the Application Window.*
- [ ] `OPENDWFMARKUP` — Opens a DWF or DWFx file that contains markups.  *Areas: Working With DWF Files and Markup.*
- [~] `OPENSHEETSET` — Opens a selected sheet set.  *Areas: Opening Drawings; Working With Sheet Sets.*
- [ ] `OPTIONS` — Customizes the program settings.  *Areas: Customizing the Drawing Environment; Working With the Application Window.*
- [x] `ORTHO` — Constrains cursor movement to the horizontal or vertical direction.  *Areas: 2D Isometric Drawing; Ortho Mode.*
- [x] `OSNAP` — Sets running object snap modes.  *Areas: Object Snap.*
- [x] `OVERKILL` — Removes duplicate or overlapping lines, arcs, and polylines. Also, combines those that are partially overlapping or contiguous.  *Areas: Removing Objects and Correcting Mistakes.*
- [~] `PAGESETUP` — Controls the page layout, plotting device, paper size, and other settings for each new layout.  *Areas: Hiding Lines and Shading 3D Objects; Model Space and Paper Space; Print or Plot Settings; Publishing Settings; Working With Layouts.*
- [x] `PAN` — Shifts the view without changing the viewing direction or magnification.  *Areas: Panning and Zooming the View; Working With the Application Window.*
- [ ] `PARAMETERS` — Opens the Parameters Manager palette that includes all dimensional constraint parameters, reference parameters, and user variables in the current drawing.  *Areas: Dimensional Constraints; Dynamic Blocks; Editing Dimensional Constraints; Parametric Drawing; Working With Dynamic Block Constraints; the Parameters Manager.*
- [ ] `PARAMETERSCLOSE` — Closes the Parameters Manager palette.  *Areas: Dynamic Blocks; Parametric Drawing; the Parameters Manager.*
- [ ] `PASTEASHYPERLINK` — Creates a hyperlink to a file, and associates it with a selected object.  *Areas: Working With Hyperlinks.*
- [x] `PASTEBLOCK` — Pastes objects from the Clipboard into the current drawing as a block.  *Areas: Basic Blocks; Duplicating Objects.*
- [x] `PASTECLIP` — Pastes objects from the Clipboard into the current drawing.  *Areas: Duplicating Objects; Object Linking and Embedding (OLE); Working With the Application Window.*
- [x] `PASTEORIG` — Pastes objects from the Clipboard into the current drawing using the original coordinates.  *Areas: Duplicating Objects; Working With Hyperlinks.*
- [ ] `PASTESPEC` — Pastes objects from the Clipboard into the current drawing and controls the format of the data.  *Areas: Duplicating Objects; Object Linking and Embedding (OLE).*
- [~] `PDFADJUST` — Adjust the fade, contrast, and monochrome settings of a PDF underlay.  *Areas: Working with Underlays.*
- [~] `PDFATTACH` — Inserts a PDF file as an underlay into the current drawing.  *Areas: Working With External References; Working with Underlays.*
- [~] `PDFCLIP` — Crops the display of a selected PDF underlay to a specified boundary.  *Areas: Working With External References; Working with Underlays.*
- [~] `PDFIMPORT` — Imports the geometry, fills, raster images, and TrueType text objects from a specified PDF file.  *Areas: Importing PDF Files.*
- [ ] `PDFLAYERS` — Controls the display of layers in a PDF underlay.  *Areas: Working with Underlays.*
- [ ] `PDFSHXTEXT` — Converts the SHX geometry imported from PDF files into individual multiline text objects.  *Areas: Importing PDF Files.*
- [x] `PEDIT` — Edits polylines, objects to be joined to polylines, and related objects.  *Areas: Editing Specific Objects.*
- [ ] `PKFSTGROUP` — Opens the legacy Group Manager.  *Areas: Working With Groups.*
- [x] `PLAN` — Displays an orthographic view of the XY plane of a specified user coordinate system.  *Areas: 3D Views; Controlling 3D Projection.*
- [~] `PLINE` — Creates a 2D polyline, a single object that is composed of line and arc segments.  *Areas: Curved Geometric Objects; Linear Geometric Objects.*
- [~] `PLOT` — Plots a drawing to a plotter, printer, or file.  *Areas: Exporting PDF, DWF, and DWFx Files; Print or Plot Settings; Publishing Settings; Working With Layouts.*
- [ ] `PLOTSTAMP` — Places a plot stamp with information such as date, time, and scale on a specified corner of each drawing and logs it to a file.  *Areas: Print or Plot Settings.*
- [ ] `PLOTSTYLE` — Controls the named plot styles that are attached to the current layout and can be assigned to objects.  *Areas: Print or Plot Settings.*
- [~] `PLOTTERMANAGER` — Displays the Plotter Manager, where you can add or edit a plotter configuration.  *Areas: Print or Plot Settings; Publishing Settings.*
- [ ] `PNGOUT` — Saves selected objects to a file in a Portable Network Graphics format.  *Areas: Exporting Raster Files.*
- [x] `POINT` — Creates a point object.  *Areas: Construction Geometry.*
- [x] `POLYGON` — Creates an equilateral closed polyline.  *Areas: Linear Geometric Objects.*
- [~] `PREVIEW` — Displays the drawing as it will be plotted.  *Areas: Print or Plot Settings.*
- [x] `PROPERTIES` — Controls properties of existing objects.  *Areas: Areas and Mass Properties; Basic Blocks; Block Attributes; Changing Text in Notes and Labels; Creating Leaders; Creating Wireframes and Objects With Thickness; Dimension Style Overrides; Distances and Angles; Dynamic Blocks; Editing Dimensional Constraints; Layers; Modifying Dimension Text; Object Display Control; Object Properties; Property Tools; Text Styles and Fields; Working with Underlays.*
- [ ] `PROPERTIESCLOSE` — Closes the Properties palette.  *Areas: Property Tools.*
- [x] `PSETUPIN` — Imports a user-defined page setup into a new drawing layout.  *Areas: Print or Plot Settings; Working With Layouts.*
- [x] `PSPACE` — In a layout, switches from model space in a layout viewport to paper space.  *Areas: Working With Layouts.*
- [x] `PTYPE` — Specifies the display style and size of point objects.  *Areas: Measuring and Dividing.*
- [~] `PUBLISH` — Publishes drawings to DWF, DWFx, and PDF files, or to printers or plotters.  *Areas: Exporting PDF, DWF, and DWFx Files; Opening Drawings; Publishing Digital Drawings; Publishing Settings; Working With DWF Files and Markup.*
- [x] `PURGE` — Removes unused items, such as block definitions and layers, from the drawing.  *Areas: Basic Blocks; Dynamic Blocks; Layers; Linetypes; Purging the Current Drawing; Removing Objects and Correcting Mistakes; Repairing Damaged Drawings.*
- [ ] `PURGEAECDATA` — Removes the invisible AEC data (AutoCAD Architecture and AutoCAD Civil 3D custom objects) in the drawing at the Command prompt.  *Areas: Purging the Current Drawing; Removing Objects and Correcting Mistakes.*
- [ ] `PUSHTOFORMACLOSE` — Closes the Push to Forma Data Management palette.  *Areas: Forma Data Management.*
- [ ] `PUSHTOFORMAOPEN` — Opens the Push to Forma Data Management palette where you can select layouts to upload as PDFs to Forma Data Management.  *Areas: Forma Data Management.*
- [ ] `QCCLOSE` — Closes the QuickCalc calculator.  *Areas: the QuickCalc Calculator.*
- [ ] `QDIM` — Creates a series of dimensions quickly from selected objects.  *Areas: Basic Dimensioning.*
- [ ] `QKUNGROUP` — Removes a group definition from a drawing.  *Areas: Working With Groups.*
- [~] `QLEADER` — Creates a leader and leader annotation.  *Areas: Creating Leaders; Geometric Tolerances.*
- [ ] `QNEW` — Starts a new drawing from a specified drawing template file.  *Areas: Starting Drawings; Working With the Application Window.*
- [ ] `QSAVE` — Saves the current drawing using the specified default file format.  *Areas: Internet Collaboration; Saving Drawings; Working With the Application Window.*
- [x] `QSELECT` — Creates a selection set based on filtering criteria.  *Areas: Selecting Objects.*
- [ ] `QTEXT` — Controls the display and plotting of text and attribute objects.  *Areas: Creating Text for Notes and Labels; Object Display Control.*
- [ ] `QUICKCALC` — Opens the QuickCalc calculator.  *Areas: Areas and Mass Properties; Distances and Angles; the QuickCalc Calculator.*
- [ ] `QUICKPROPERTIES` — Displays quick property data for selected objects.  *Areas: Property Tools.*
- [ ] `QUIT` — Exits the program.  *Areas: Saving Drawings.*
- [ ] `QVDRAWING` — Displays open drawings and layouts in a drawing using preview images.  *Areas: Opening Drawings.*
- [ ] `QVDRAWINGCLOSE` — Closes preview images of open drawings and their layouts.  *Areas: Opening Drawings.*
- [ ] `QVLAYOUT` — Displays preview images of model space and layouts for the current drawing.  *Areas: Opening Drawings.*
- [ ] `QVLAYOUTCLOSE` — Closes preview images of model space and layouts in the current drawing  *Areas: Opening Drawings.*
- [x] `RAY` — Creates a linear object that starts at a point and continues to infinity.  *Areas: Construction Geometry; Linear Geometric Objects.*
- [x] `RECOVER` — Repairs and then opens a damaged drawing file.  *Areas: Repairing Damaged Drawings; Working With the Application Window.*
- [ ] `RECOVERALL` — Repairs a damaged drawing file along with all attached xrefs.  *Areas: Repairing Damaged Drawings.*
- [~] `RECTANG` — Creates a rectangular polyline.  *Areas: Linear Geometric Objects.*
- [x] `REDO` — Reverses the effects of previous UNDO or U command.  *Areas: Removing Objects and Correcting Mistakes.*
- [x] `REDRAW` — Refreshes the display in the current viewport.  *Areas: Removing Objects and Correcting Mistakes.*
- [x] `REFCLOSE` — Saves back or discards changes made during in-place editing of a reference, either an xref or a block definition.  *Areas: Editing External References; Working With External References.*
- [~] `REFEDIT` — Edits an xref or a block definition directly within the current drawing.  *Areas: Editing External References; Working With External References.*
- [ ] `REFSET` — Adds or removes objects from a working set during in-place editing of a reference, either an xref or a block definition.  *Areas: Editing External References; Working With External References.*
- [x] `REGEN` — Regenerates the drawing from within the current viewport.  *Areas: Hiding Lines and Shading 3D Objects; Object Display Control.*
- [ ] `REGENALL` — Regenerates the entire drawing and refreshes all viewports.  *Areas: Object Display Control.*
- [ ] `REGION` — Converts objects that enclose an area into a 2D region object.  *Areas: Regions and Areas.*
- [x] `RENAME` — Changes the names assigned to items such as layers and dimension styles.  *Areas: Layers; Linetypes; Resolving Xref Errors; Working With External References.*
- [ ] `RESETBLOCK` — Resets one or more dynamic block references to the default values of the block definition.  *Areas: Dynamic Blocks.*
- [x] `REVCLOUD` — Creates or modifies a revision cloud.  *Areas: Revision Clouds.*
- [x] `REVCLOUDPROPERTIES` — Controls the approximate chord length for the arcs in a selected revision cloud.  *Areas: Revision Clouds.*
- [ ] `REVDATE` — Inserts or updates a block containing user name, current time and date, and drawing name.  *Areas: Date and Time.*
- [x] `REVERSE` — Reverses the vertices of selected lines, polylines, splines, and helixes, which is useful for linetypes with included text, or wide polylines with differing beginning and ending widths.  *Areas: Editing Specific Objects; Linetypes.*
- [x] `RIBBON` — Displays the ribbon.  *Areas: Working With the Application Window.*
- [x] `RIBBONCLOSE` — Hides the ribbon.  *Areas: Working With the Application Window.*
- [x] `ROTATE` — Rotates objects around a base point.  *Areas: Moving and Rotating Objects.*
- [x] `SAVEAS` — Saves a copy of the current drawing under a new file name or location.  *Areas: Importing and Exporting DXF Files; Internet Collaboration; Saving Drawings; Starting Drawings.*
- [x] `SCALE` — Enlarges or reduces selected objects, keeping the proportions of the object the same after scaling.  *Areas: Resizing Objects.*
- [~] `SCALELISTEDIT` — Controls the list of scales available for layout viewports, page layouts, and plotting.  *Areas: Working with Layout Viewports.*
- [ ] `SCALETEXT` — Enlarges or reduces selected text objects without changing their locations.  *Areas: Changing Text in Notes and Labels.*
- [ ] `SECURITYOPTIONS` — Controls the security restrictions for running executable files in the product.  *Areas: Protecting Against Malicious Code Reference; Protecting and Signing Drawings.*
- [ ] `SELECT` — Places selected objects in the Previous selection set.  *Areas: Selecting Objects.*
- [ ] `SELECTCOUNT` — Finds all objects within the current count that match the properties of the selected objects, and then adds them to the selection set.  *Areas: Counting Objects; Selecting Objects.*
- [x] `SELECTSIMILAR` — Finds all objects within the current drawing that match the properties of selected objects, and then adds them to the selection set.  *Areas: Selecting Objects.*
- [ ] `SETBYLAYER` — Changes the property overrides of selected objects to ByLayer.  *Areas: Colors; Linetypes; Lineweights; Object Properties.*
- [ ] `SETENV` — Sets values of specified registry variables.  *Areas: Editing Specific Objects.*
- [ ] `SETVAR` — Lists or changes the values of system variables.  *Areas: Working With the Application Window.*
- [ ] `SHADEMODE` — Controls the display of 3D objects.  *Areas: Hiding Lines and Shading 3D Objects.*
- [~] `SHEETSET` — Opens the Sheet Set Manager.  *Areas: Opening Drawings; Publishing Settings; Working With Sheet Sets.*
- [x] `SHEETSETHIDE` — Closes the Sheet Set Manager.  *Areas: Working With Sheet Sets.*
- [ ] `SHOWPALETTES` — Restores the display of hidden palettes, the ribbon, and the drawing tabs.  *Areas: Customizing the Drawing Environment; Tool Palettes.*
- [ ] `SKETCH` — Creates a series of freehand line segments.  *Areas: Linear Geometric Objects.*
- [x] `SNAP` — Restricts cursor movement to specified intervals.  *Areas: 2D Isometric Drawing; Grid and Grid Snap.*
- [ ] `SOLID` — Creates solid-filled triangles and quadrilaterals.  *Areas: Hatches and Gradients.*
- [ ] `SPACETRANS` — Calculates equivalent model space and paper space distances in a layout.  *Areas: Changing Text in Notes and Labels.*
- [ ] `SPELL` — Checks spelling in a drawing.  *Areas: Changing Text in Notes and Labels; Creating Text for Notes and Labels.*
- [x] `SPLINE` — Creates a smooth curve that passes through or near a set of fit points, or that is defined by the vertices in a control frame.  *Areas: Curved Geometric Objects.*
- [~] `SPLINEDIT` — Modifies the parameters of a spline or converts a spline-fit polyline to a spline.  *Areas: Editing Specific Objects.*
- [x] `STRETCH` — Stretches objects crossed by a selection window or polygon.  *Areas: Modifying Dimension Geometry; Moving and Rotating Objects; Resizing Objects.*
- [x] `STYLE` — Creates, modifies, or specifies text styles.  *Areas: Changing Text in Notes and Labels; Creating Text for Notes and Labels; Text Styles and Fields.*
- [~] `STYLESMANAGER` — Displays the Plot Style Manager, where you can revise plot style tables.  *Areas: Print or Plot Settings.*
- [ ] `SUBTRACT` — Creates a new region by subtracting one overlapping region from another.  *Areas: Regions and Areas.*
- [ ] `SYSVARMONITOR` — Monitors a list of system variables and sends notifications when there are changes to any one in the list.  *Areas: Working With the Application Window.*
- [ ] `SYSWINDOWS` — Arranges windows and icons when the application window is shared with external applications.  *Areas: Opening Drawings; Working With the Application Window.*
- [~] `TABLE` — Creates an empty table object.  *Areas: Tables.*
- [ ] `TABLEDIT` — Edits text in a table cell.  *Areas: Tables.*
- [ ] `TABLEEXPORT` — Exports data from a table object in CSV file format.  *Areas: Tables.*
- [ ] `TABLESTYLE` — Creates, modifies, or specifies table styles.  *Areas: Tables.*
- [ ] `TABLET` — Calibrates, configures, and turns on and off an attached digitizing tablet.  *Areas: Working With the Application Window.*
- [ ] `TASKBAR` — Controls the Peek/Preview behavior of the application's button in the Windows taskbar when multiple drawings are open.  *Areas: Opening Drawings; Working With the Application Window.*
- [x] `TEXT` — Creates a single-line text object.  *Areas: Changing Text in Notes and Labels; Creating Text for Notes and Labels; Text Styles and Fields.*
- [x] `TEXTALIGN` — Aligns multiple text objects vertically, horizontally, or obliquely.  *Areas: Creating Text for Notes and Labels.*
- [x] `TEXTEDIT` — Edits a selected multiline or single-line text object, or the text in a dimension object.  *Areas: Block Attributes; Changing Text in Notes and Labels; Creating Text for Notes and Labels; Modifying Dimension Text.*
- [ ] `TEXTSCR` — Opens a text window that displays a history of prompts and command line entries for the current session.  *Areas: Working With the Application Window.*
- [x] `TEXTTOFRONT` — Brings text, leaders, and dimensions in front of all other objects in the drawing.  *Areas: Object Display Control.*
- [ ] `TIFOUT` — Saves selected objects to a file in TIFF file format.  *Areas: Exporting Raster Files.*
- [ ] `TIME` — Displays the date and time statistics of a drawing.  *Areas: Date and Time.*
- [ ] `TINSERT` — Inserts a block in a table cell.  *Areas: Tables.*
- [ ] `TOLERANCE` — Creates geometric tolerances contained in a feature control frame.  *Areas: Geometric Tolerances.*
- [x] `TOOLBAR` — Displays, hides, and customizes toolbars.  *Areas: Customizing the Drawing Environment; Working With the Application Window.*
- [ ] `TOOLPALETTES` — Opens the Tool Palettes window.  *Areas: Basic Blocks; Dynamic Blocks; Tool Palettes.*
- [ ] `TOOLPALETTESCLOSE` — Closes the Tool Palettes window.  *Areas: Tool Palettes.*
- [ ] `TPNAVIGATE` — Displays a specified tool palette or palette group.  *Areas: Tool Palettes.*
- [ ] `TRANSPARENCY` — Controls whether background pixels in an image are transparent or opaque.  *Areas: Working with Raster Image Files.*
- [ ] `TRAYSETTINGS` — Controls the display of icons and notifications in the status bar tray.  *Areas: Customizing the Drawing Environment.*
- [~] `TRIM` — Trims objects to meet the edges of other objects.  *Areas: Resizing Objects.*
- [x] `TXT2MTXT` — Converts or combines single-line or multiline text objects into one or more multiline text objects.  *Areas: Changing Text in Notes and Labels; Importing PDF Files.*
- [x] `UCS` — Sets the origin and orientation of the current user coordinate system (UCS).  *Areas: Grid and Grid Snap; Ortho Mode; Polar Tracking and PolarSnap; the User Coordinate System (UCS).*
- [ ] `UCSICON` — Controls the visibility, placement, appearance, and selectability of the UCS icon.  *Areas: Customizing the Drawing Environment; the User Coordinate System (UCS).*
- [ ] `UCSMAN` — Manages UCS definitions.  *Areas: the User Coordinate System (UCS).*
- [ ] `ULAYERS` — Controls the display of layers in a DWF, DWFx, PDF, or DGN underlay.  *Areas: Layers; Working with Underlays.*
- [x] `UNDO` — Reverses the effect of commands.  *Areas: Removing Objects and Correcting Mistakes.*
- [x] `UNGROUP` — Disassociates the objects from a group.  *Areas: Working With Groups.*
- [ ] `UNION` — Combines two or more 2D regions into a single, composite region.  *Areas: Regions and Areas.*
- [x] `UNISOLATEOBJECTS` — Displays objects previously hidden with the ISOLATEOBJECTS or HIDEOBJECTS command.  *Areas: Object Display Control.*
- [x] `UNITS` — Controls the precision and display formats for coordinates, distances, and angles.  *Areas: Displaying Coordinates; Distances and Angles; Polar Tracking and PolarSnap; Starting Drawings.*
- [ ] `UPDATEFIELD` — Updates fields in selected objects.  *Areas: Tables; Text Styles and Fields.*
- [ ] `UPDATETHUMBSNOW` — Manually updates thumbnail previews for named views, drawings, and layouts.  *Areas: Opening Drawings.*
- [~] `VIEW` — Saves and restores named model space views, layout views, and preset views.  *Areas: 3D Views; Controlling 3D Projection; Saving and Restoring Views.*
- [ ] `VIEWBACK` — Restores sequential views backward after changing the view.  *Areas: Panning and Zooming the View; Saving and Restoring Views; Working with Layout Viewports.*
- [ ] `VIEWFORWARD` — Restores sequential views forward after displaying a previous view with VIEWBACK or Zoom Previous.  *Areas: Panning and Zooming the View; Saving and Restoring Views; Working with Layout Viewports.*
- [ ] `VIEWPLOTDETAILS` — Displays information about completed plot and publish jobs.  *Areas: Print or Plot Settings; Publishing Settings.*
- [ ] `VIEWRES` — Sets the tessellation for objects in the current viewport when WHIPARC is turned off.  *Areas: Curved Geometric Objects; Customizing the Drawing Environment; Panning and Zooming the View.*
- [ ] `VPCLIP` — Redefines a layout viewport object while retaining its properties.  *Areas: Working With Layouts; Working with Underlays.*
- [x] `VPLAYER` — Sets layer visibility within viewports.  *Areas: Working With Layouts; Working with Layout Viewports.*
- [~] `VPMAX` — Expands the current layout viewport for editing.  *Areas: Working With Layouts; Working with Layout Viewports.*
- [~] `VPMIN` — Restores the current layout viewport.  *Areas: Working With Layouts; Working with Layout Viewports.*
- [ ] `VPOINT` — Sets the viewing direction for a 3D visualization of the drawing.  *Areas: Controlling 3D Projection.*
- [~] `VPORTS` — Creates multiple viewports in model space or in a layout (paper space).  *Areas: Model Space and Paper Space; Saving and Restoring Views; Working With Layouts; Working with Layout Viewports.*
- [ ] `VTOPTIONS` — Displays a change in view as a smooth transition.  *Areas: Customizing the Drawing Environment; Panning and Zooming the View.*
- [~] `WBLOCK` — Saves selected objects or converts a block to a specified drawing file.  *Areas: Basic Blocks; Saving Drawings.*
- [ ] `WIPEOUT` — Creates a wipeout object, and controls whether wipeout frames are displayed in the drawing.  *Areas: Working with Wipeouts.*
- [ ] `WMFIN` — Imports a Windows metafile.  *Areas: Duplicating Objects; Importing and Exporting Windows Metafiles (WMF Files).*
- [ ] `WMFOPTS` — Sets options for WMFIN.  *Areas: Duplicating Objects; Importing and Exporting Windows Metafiles (WMF Files).*
- [ ] `WMFOUT` — Saves objects to a Windows metafile.  *Areas: Duplicating Objects; Importing and Exporting Windows Metafiles (WMF Files).*
- [ ] `WORKSPACE` — Creates, modifies, and saves workspaces and makes a workspace current.  *Areas: Customizing the Drawing Environment.*
- [ ] `WSSAVE` — Saves a workspace.  *Areas: Customizing the Drawing Environment.*
- [ ] `WSSETTINGS` — Sets options for workspaces.  *Areas: Customizing the Drawing Environment.*
- [~] `XATTACH` — Attaches selected DWG files as external references (xrefs).  *Areas: Starting Drawings; Working With External References.*
- [~] `XBIND` — Binds one or more definitions of named objects in an xref to the current drawing.  *Areas: Resolving Xref Errors; Working With External References.*
- [~] `XCLIP` — Crops the display of a selected external reference or block reference to a specified boundary.  *Areas: Working With External References.*
- [ ] `XCOMPARE` — Compares an attached xref with the latest state of the referenced drawing file, highlighting the differences with color within revision clouds.  *Areas: Editing External References; Improving Performance When Using Xrefs; Resolving Xref Errors; Working With DWG Compare; Working With External References; Working with Underlays.*
- [ ] `XCOMPARECLOSE` — Closes the Xref Compare toolbar and ends the comparison.  *Areas: Editing External References; Improving Performance When Using Xrefs; Resolving Xref Errors; Working With DWG Compare; Working With External References; Working with Underlays.*
- [ ] `XCOMPARERCNEXT` — Zooms to the next change set of the xref comparison result.  *Areas: Editing External References; Improving Performance When Using Xrefs; Resolving Xref Errors; Working With DWG Compare; Working With External References; Working with Underlays.*
- [ ] `XCOMPARERCPREV` — Zooms to the previous change set of the xref comparison result.  *Areas: Editing External References; Improving Performance When Using Xrefs; Resolving Xref Errors; Working With DWG Compare; Working With External References; Working with Underlays.*
- [x] `XLINE` — Creates a construction line of infinite length.  *Areas: Construction Geometry; Linear Geometric Objects.*
- [ ] `XOPEN` — Opens a selected drawing reference (xref) in a new window.  *Areas: Editing External References.*
- [ ] `XPLODE` — Breaks a compound object into its component objects, with specified properties for the resulting objects.  *Areas: Basic Blocks; Modifying Dimension Geometry.*
- [~] `XREF` — Starts the EXTERNALREFERENCES command.  *Areas: Improving Performance When Using Xrefs; Internet Collaboration; Resolving Xref Errors; Working With External References.*
- [x] `ZOOM` — Increases or decreases the magnification of the view in the current viewport.  *Areas: Panning and Zooming the View; Saving and Restoring Views; Working with Layout Viewports.*

### Supplemental core commands (23)

Commands that are part of the LT workflow but are not linked from the LT command-category pages.

- [~] `DIMALIGNED` — Creates an aligned linear dimension (core command; not linked from the LT category page).
- [x] `DIMBASELINE` — Creates baseline dimensions from a previous or selected dimension.
- [x] `DIMCONTINUE` — Creates a continued dimension from a previous or selected dimension.
- [~] `DIMCENTER` — Creates the center mark or centerlines of circles and arcs.
- [ ] `DIMJOGLINE` — Adds or removes a jog line on a linear or aligned dimension.
- [x] `SCRIPT` — Runs a script (.scr) file of command sequences.
- [ ] `MSLIDE` — Creates a slide (.sld) from the current viewport.
- [ ] `VSLIDE` — Displays a slide file in the drawing area.
- [ ] `DIGITALSIGN` — Attaches a digital signature to a DWG or DWT file.
- [ ] `SIGVALIDATE` — Validates a digital signature attached to a file.
- [ ] `TRACE` — Creates or opens a trace for collaborative markup without altering the drawing.
- [ ] `TRACEBACK` — Switches the active trace to view mode while editing the parent drawing.
- [ ] `COPYFROMTRACE` — Copies objects from a trace into the drawing.
- [ ] `SHARE` — Creates a shareable link to a Forma Data Management drawing (2025.1+).
- [ ] `ASSISTANTOPEN` — Opens the Autodesk Assistant palette (2027).
- [ ] `ASSISTANTCLOSE` — Closes the Autodesk Assistant palette (2027).
- [ ] `HELP` — Displays Help for the active command, dialog or tooltip.
- [ ] `STATUS` — Reports drawing statistics, memory/disk/swap information, and dimension variable values.
- [ ] `COMPILE` — Compiles SHP shape files and PFB PostScript font files into SHX files.
- [ ] `DXFOUT` — Writes the drawing objects to a DXF file (ASCII or binary).
- [ ] `DXFIN` — Loads a DXF file into the current drawing.
- [ ] `PARTIALOPEN` — Loads geometry and named objects from a selected view or layer into a drawing.
- [ ] `BCONVERT` — Smart Blocks convert workflow (also referenced as BSEARCH in current Help).

**Unique commands: 508** — 485 commands from the Help categories plus 23 supplemental commands.

## Appendix B. System-variable checklist (LT 2027)

> **Zephyr:** 103 supported · 541 not supported (LispVarStore registry plus live/read-only cases).


Every system variable documented in the LT 2027 command-category pages, deduplicated and grouped by its first Help category. Descriptions, defaults and ranges are in the LT Help; this is a coverage list for parity checks. Many variables appear in more than one functional area.

### 2D Isometric Drawing (2)

- [ ] `SNAPISOPAIR` · [ ] `SNAPSTYL`

### Activity Insights (4)

- [ ] `ACTIVITYINSIGHTSPATH` · [ ] `ACTIVITYINSIGHTSSTATE` · [ ] `ACTIVITYINSIGHTSSUPPORT` · [ ] `ACTIVITYINSIGHTSVIEWEDLOGGING`

### Annotation Scaling (11)

- [ ] `ANNOALLVISIBLE` · [ ] `ANNOAUTOSCALE` · [ ] `ANNOSCALEZOOM` · [ ] `ANNOTATIVEDWG` · [ ] `CANNOSCALE` · [ ] `CANNOSCALEVALUE` · [ ] `DIMANNO` · [ ] `HPANNOTATIVE`
- [ ] `MSOLESCALE` · [ ] `SAVEFIDELITY` · [ ] `SELECTIONANNODISPLAY`

### Areas and Mass Properties (2)

- [x] `AREA` · [x] `PERIMETER`

### Associative Dimensioning (3)

- [ ] `ANNOMONITOR` · [ ] `DIMASSOC` · [ ] `DIMSTYLE`

### Basic Blocks (23)

- [ ] `ATTDIA` · [ ] `AUTOPLACEMENT` · [ ] `BLOCKCREATEMODE` · [ ] `BLOCKEDITLOCK` · [ ] `BLOCKMRULIST` · [ ] `BLOCKNAVIGATE` · [ ] `BLOCKREDEFINEMODE` · [ ] `BLOCKSRECENTFOLDER`
- [ ] `BLOCKSTATE` · [ ] `BLOCKSYNCFOLDER` · [ ] `EXPLMODE` · [ ] `EXTNAMES` · [ ] `GALLERYVIEW` · [ ] `INSNAME` · [x] `INSUNITS` · [ ] `INSUNITSDEFSOURCE`
- [ ] `INSUNITSDEFTARGET` · [ ] `JIGZOOMMAX` · [ ] `JIGZOOMMIN` · [ ] `MAXSORT` · [ ] `PLACEMENTSWITCH` · [ ] `TEXTTOATTRIBUTE` · [ ] `WBLOCKCREATEMODE`

### Basic Dimensioning (1)

- [ ] `DIMLAYER`

### Block Attributes (6)

- [ ] `AFLAGS` · [ ] `ATTIPE` · [ ] `ATTMODE` · [ ] `ATTMULTI` · [x] `ATTREQ` · [ ] `TEXTEDITMODE`

### Center Marks and Centerlines (8)

- [ ] `CENTERCROSSGAP` · [ ] `CENTERCROSSSIZE` · [ ] `CENTEREXE` · [ ] `CENTERLAYER` · [ ] `CENTERLTSCALE` · [ ] `CENTERLTYPE` · [ ] `CENTERLTYPEFILE` · [ ] `CENTERMARKEXE`

### Changing Text in Notes and Labels (17)

- [ ] `CENTERMT` · [ ] `DCTCUST` · [ ] `DCTMAIN` · [ ] `DWGCODEPAGE` · [x] `MIRRTEXT` · [ ] `MTEXTED` · [ ] `MTEXTEDENCODING` · [ ] `MTEXTFIXED`
- [ ] `MTEXTTOOLBAR` · [ ] `MTJIGSTRING` · [ ] `OSNAPNODELEGACY` · [ ] `TEXTED` · [ ] `TEXTFILL` · [ ] `TEXTGAPSELECTION` · [ ] `TEXTJUSTIFY` · [ ] `TEXTLAYER`
- [ ] `TEXTQLTY`

### Colors (1)

- [x] `CECOLOR`

### Controlling 3D Projection (5)

- [ ] `PERSPECTIVE` · [ ] `VIEWDIR` · [ ] `VIEWMODE` · [ ] `VIEWTWIST` · [ ] `WORLDVIEW`

### Counting Objects (7)

- [ ] `COUNTCHECK` · [ ] `COUNTCOLOR` · [ ] `COUNTERRORCOLOR` · [ ] `COUNTERRORNUM` · [ ] `COUNTNUMBER` · [ ] `COUNTPALETTESTATE` · [ ] `COUNTSERVICE`

### Creating Fillets and Chamfers (10)

- [x] `CHAMFERA` · [x] `CHAMFERB` · [ ] `CHAMFERC` · [ ] `CHAMFERD` · [ ] `CHAMMODE` · [ ] `COMMANDPREVIEW` · [ ] `FILLETPOLYARC` · [x] `FILLETRAD`
- [x] `PROJMODE` · [ ] `TRIMMODE`

### Creating Leaders (11)

- [x] `CMDDIA` · [ ] `CMLEADERSTYLE` · [x] `DIMASZ` · [ ] `DIMCLRD` · [x] `DIMGAP` · [ ] `DIMLDRBLK` · [x] `DIMSCALE` · [ ] `DIMTAD`
- [ ] `DIMTXTDIRECTION` · [ ] `MLEADERLAYER` · [ ] `MLEADERSCALE`

### Creating Text for Notes and Labels (14)

- [ ] `FONTALT` · [ ] `MTEXTAUTOSTACK` · [ ] `MTEXTCOLUMN` · [ ] `MTEXTDETECTSPACE` · [ ] `TEXTALIGNMODE` · [ ] `TEXTALIGNSPACING` · [ ] `TEXTALLCAPS` · [ ] `TEXTAUTOCORRECTCAPS`
- [ ] `TEXTSIZE` · [x] `TEXTSTYLE` · [ ] `TSPACEFAC` · [ ] `TSPACETYPE` · [ ] `TSTACKALIGN` · [ ] `TSTACKSIZE`

### Creating Wireframes and Objects With Thickness (3)

- [ ] `FACETRES` · [ ] `ISOLINES` · [ ] `THICKNESS`

### Curved Geometric Objects (15)

- [x] `CIRCLERAD` · [ ] `DONUTID` · [ ] `DONUTOD` · [x] `FILLMODE` · [ ] `HPBOUND` · [x] `LASTANGLE` · [ ] `MAXINTERSECTIONCURVEPOINTS` · [x] `OFFSETDIST`
- [ ] `PELLIPSE` · [ ] `PLINECONVERTMODE` · [ ] `SPLDEGREE` · [ ] `SPLKNOTS` · [ ] `SPLMETHOD` · [ ] `SPLPERIODIC` · [ ] `WHIPARC`

### Customizing the Drawing Environment (66)

- [ ] `CALCINPUT` · [ ] `CLEANSCREENSTATE` · [ ] `CLIPROMPTLINES` · [ ] `CURSORBADGE` · [x] `CURSORSIZE` · [ ] `CURSORTYPE` · [ ] `DEFLPLSTYLE` · [ ] `DIMPICKBOX`
- [ ] `DRAGMODE` · [ ] `DRAGP1` · [ ] `DRAGP2` · [ ] `EXEDIR` · [ ] `GRIPBLOCK` · [ ] `GRIPCONTOUR` · [ ] `GRIPDYNCOLOR` · [ ] `GRIPHOT`
- [ ] `GRIPHOVER` · [ ] `GRIPMULTIFUNCTIONAL` · [ ] `GRIPS` · [ ] `INTELLIGENTUPDATE` · [ ] `ISAVEBAK` · [ ] `ISAVEPERCENT` · [ ] `LOCALE` · [ ] `LOCALROOTPREFIX`
- [ ] `LOCKUI` · [ ] `LOGFILEMODE` · [ ] `LOGFILENAME` · [ ] `LOGFILEPATH` · [x] `LOGINNAME` · [ ] `MENUNAME` · [ ] `OLEQUALITY` · [ ] `OLESTARTUP`
- [ ] `OSNAPCOORD` · [ ] `PALETTEOPAQUE` · [x] `PAPERUPDATE` · [x] `PICKADD` · [x] `PICKAUTO` · [x] `PICKBOX` · [x] `PICKDRAG` · [x] `PICKFIRST`
- [ ] `PROPERTYPREVIEW` · [ ] `PROPPREVTIMEOUT` · [ ] `PSTYLEPOLICY` · [x] `QTEXTMODE` · [ ] `ROLLOVERTIPS` · [ ] `SAVEFILE` · [ ] `SAVEFILEPATH` · [ ] `SAVETIME`
- [ ] `SHORTCUTMENU` · [ ] `SHORTCUTMENUDURATION` · [ ] `STARTUP` · [ ] `SYSFLOATING` · [ ] `TDUSRTIMER` · [ ] `THUMBSAVE` · [ ] `TOOLTIPMERGE` · [ ] `TOOLTIPS`
- [ ] `UCSICON` · [ ] `USERNAME` · [x] `VISRETAIN` · [ ] `VISRETAINMODE` · [ ] `VTDURATION` · [ ] `VTENABLE` · [ ] `VTFPS` · [ ] `WORKSPACELABEL`
- [ ] `WSCURRENT` · [x] `XLOADCTL`

### Date and Time (3)

- [ ] `CDATE` · [x] `DATE` · [x] `MILLISECS`

### Dimension Scales (1)

- [ ] `DIMLFAC`

### Dimension Spacing (1)

- [ ] `DIMDLI`

### Dimension Styles (1)

- [ ] `DIMCONTINUEMODE`

### Dimensional Constraints (2)

- [ ] `CONSTRAINTNAMEFORMAT` · [ ] `DIMCONSTRAINTICON`

### Displaying Coordinates (3)

- [ ] `COORDS` · [x] `LASTPOINT` · [ ] `STATUSBAR`

### Distances and Angles (5)

- [x] `AUNITS` · [x] `AUPREC` · [ ] `DISTANCE` · [x] `LUNITS` · [x] `LUPREC`

### Duplicating Objects (5)

- [ ] `COPYMODE` · [ ] `OLEHIDE` · [ ] `PASTESPECMODE` · [ ] `WMFBKGND` · [ ] `WMFFOREGND`

### Dynamic Blocks (16)

- [ ] `APSTATE` · [ ] `BACTIONBARMODE` · [ ] `BACTIONCOLOR` · [ ] `BCONSTATUSMODE` · [ ] `BDEPENDENCYHIGHLIGHT` · [ ] `BGRIPOBJCOLOR` · [ ] `BGRIPOBJSIZE` · [ ] `BLOCKEDITOR`
- [ ] `BLOCKTESTWINDOW` · [ ] `BPARAMETERCOLOR` · [ ] `BPARAMETERFONT` · [ ] `BPARAMETERSIZE` · [ ] `BPTEXTHORIZONTAL` · [ ] `BTMARKDISPLAY` · [ ] `BVMODE` · [ ] `GRIPTIPS`

### Dynamic Input Tooltips (9)

- [ ] `DYNDIGRIP` · [ ] `DYNDIVIS` · [ ] `DYNMODE` · [ ] `DYNPICOORDS` · [ ] `DYNPIFORMAT` · [ ] `DYNPIVIS` · [ ] `DYNPROMPT` · [ ] `DYNTOOLTIPS`
- [ ] `TEMPOVERRIDES`

### Editing External References (9)

- [x] `BINDTYPE` · [ ] `COMPARESHOWCONTEXT` · [ ] `REFEDITNAME` · [ ] `XCOMPAREBAKPATH` · [ ] `XCOMPAREBAKSIZE` · [ ] `XCOMPARECOLORMODE` · [ ] `XCOMPAREENABLE` · [ ] `XEDIT`
- [ ] `XFADECTL`

### Editing Specific Objects (8)

- [x] `PEDITACCEPT` · [ ] `PLINEGCENMAX` · [ ] `PLINEGEN` · [ ] `PLINEREVERSEWIDTHS` · [ ] `PLINETYPE` · [ ] `PLINEWID` · [x] `SPLINESEGS` · [x] `SPLINETYPE`

### Editing with Grips (3)

- [ ] `DYNINFOTIPS` · [ ] `GRIPOBJLIMIT` · [ ] `GRIPSIZE`

### Exporting PDF, DWF, and DWFx Files (5)

- [ ] `EXPORTEPLOTFORMAT` · [ ] `EXPORTMODELSPACE` · [ ] `EXPORTPAGESETUP` · [ ] `EXPORTPAPERSPACE` · [ ] `PDFSHX`

### Forma Data Management (1)

- [ ] `PUSHTOFORMASTATE`

### Geometric Constraints (3)

- [ ] `CBARTRANSPARENCY` · [ ] `CONSTRAINTBARMODE` · [ ] `CONSTRAINTSOLVEMODE`

### Graphics System (2)

- [ ] `CACHEMAXFILES` · [ ] `CACHEMAXTOTALSIZE`

### Grid and Grid Snap (13)

- [ ] `GRIDDISPLAY` · [x] `GRIDMAJOR` · [x] `GRIDMODE` · [ ] `GRIDSTYLE` · [x] `GRIDUNIT` · [ ] `LIMCHECK` · [ ] `LIMMAX` · [ ] `LIMMIN`
- [ ] `SNAPANG` · [ ] `SNAPBASE` · [ ] `SNAPGRIDLEGACY` · [x] `SNAPMODE` · [x] `SNAPUNIT`

### Hatches and Gradients (41)

- [x] `GFANG` · [x] `GFCLR1` · [x] `GFCLR2` · [x] `GFCLRLUM` · [x] `GFCLRSTATE` · [x] `GFNAME` · [x] `GFSHIFT` · [x] `HPANG`
- [ ] `HPASSOC` · [ ] `HPBACKGROUNDCOLOR` · [ ] `HPBOUNDRETAIN` · [ ] `HPCOLOR` · [ ] `HPDLGMODE` · [ ] `HPDOUBLE` · [ ] `HPDRAWMODE` · [ ] `HPDRAWORDER`
- [ ] `HPGAPTOL` · [ ] `HPINHERIT` · [ ] `HPISLANDDETECTION` · [ ] `HPISLANDDETECTIONMODE` · [ ] `HPLAYER` · [ ] `HPLINETYPE` · [ ] `HPMAXAREAS` · [ ] `HPMAXLINES`
- [ ] `HPMAXLOOPS` · [x] `HPNAME` · [ ] `HPOBJWARNING` · [ ] `HPORIGIN` · [ ] `HPORIGINMODE` · [ ] `HPPATHALIGNMENT` · [ ] `HPPATHWIDTH` · [ ] `HPPICKMODE`
- [ ] `HPQUICKPREVIEW` · [ ] `HPQUICKPREVTIMEOUT` · [x] `HPSCALE` · [ ] `HPSEPARATE` · [ ] `HPSPACE` · [ ] `HPTRANSPARENCY` · [ ] `MIRRHATCH` · [ ] `OSOPTIONS`
- [x] `PICKSTYLE`

### Hiding Lines and Shading 3D Objects (8)

- [ ] `HALOGAP` · [ ] `HIDETEXT` · [ ] `INTERSECTIONCOLOR` · [ ] `INTERSECTIONDISPLAY` · [ ] `OBSCUREDCOLOR` · [ ] `OBSCUREDLTYPE` · [ ] `SHADEDGE` · [ ] `SHADEDIF`

### Importing and Exporting Microstation DGN Files (3)

- [ ] `DGNIMPORTMAX` · [ ] `DGNIMPORTMODE` · [ ] `DGNMAPPINGPATH`

### Importing PDF Files (6)

- [ ] `PDFIMPORTFILTER` · [ ] `PDFIMPORTIMAGEPATH` · [ ] `PDFIMPORTLAYERS` · [ ] `PDFIMPORTMODE` · [ ] `PDFSHXLAYER` · [ ] `PDFSHXTHRESHOLD`

### Improving Performance When Using Xrefs (4)

- [ ] `INDEXCTL` · [ ] `TREEDEPTH` · [ ] `TREEMAX` · [ ] `XLOADPATH`

### Internet Collaboration (2)

- [ ] `INETLOCATION` · [ ] `STARTMODE`

### Layers (16)

- [x] `CLAYER` · [ ] `LAYEREVAL` · [ ] `LAYEREVALCTL` · [ ] `LAYERFILTERALERT` · [ ] `LAYERMANAGERSTATE` · [ ] `LAYERNOTIFY` · [x] `LAYLOCKFADECTL` · [ ] `REVCLOUDLAYER`
- [ ] `SETBYLAYERMODE` · [ ] `SHOWLAYERUSAGE` · [ ] `SORTORDER` · [ ] `TABLELAYER` · [ ] `VIEWPORTLAYER` · [ ] `VPLAYEROVERRIDES` · [ ] `VPLAYEROVERRIDESMODE` · [ ] `XREFLAYER`

### Linear Geometric Objects (6)

- [x] `ANGDIR` · [ ] `POLYSIDES` · [x] `SKETCHINC` · [ ] `SKPOLY` · [ ] `SKTOLERANCE` · [ ] `SPLFRAME`

### Linetypes (9)

- [x] `CELTSCALE` · [x] `CELTYPE` · [ ] `COMPLEXLTPREVIEW` · [ ] `LTGAPSELECTION` · [x] `LTSCALE` · [ ] `MEASUREINIT` · [x] `MEASUREMENT` · [ ] `MSLTSCALE`
- [x] `PSLTSCALE`

### Lineweights (4)

- [ ] `CELWEIGHT` · [ ] `LWDEFAULT` · [x] `LWDISPLAY` · [ ] `LWUNITS`

### Measuring and Dividing (2)

- [x] `PDMODE` · [x] `PDSIZE`

### Model Space and Paper Space (11)

- [ ] `CLAYOUT` · [x] `CTAB` · [x] `CVPORT` · [ ] `LAYEROVERRIDEHIGHLIGHT` · [ ] `LAYOUTSPATIALFILTERS` · [ ] `LAYOUTTAB` · [ ] `NAVBARDISPLAY` · [x] `TILEMODE`
- [ ] `VIEWCTR` · [ ] `VIEWSIZE` · [ ] `VPMAXIMIZEDSTATE`

### Modifying Dimension Text (9)

- [ ] `DIMCLRT` · [ ] `DIMDSEP` · [ ] `DIMJUST` · [ ] `DIMTIH` · [ ] `DIMTMOVE` · [ ] `DIMTOH` · [ ] `DIMTVP` · [ ] `DIMTXTRULER`
- [ ] `DIMUPT`

### Object Display Control (6)

- [ ] `CETRANSPARENCY` · [ ] `DRAWORDERCTL` · [ ] `OBJECTISOLATIONMODE` · [ ] `RTDISPLAY` · [ ] `SORTENTS` · [x] `TRANSPARENCYDISPLAY`

### Object Linking and Embedding (OLE) (1)

- [ ] `OLEFRAME`

### Object Properties (1)

- [ ] `CPLOTSTYLE`

### Object Snap (5)

- [ ] `APBOX` · [x] `APERTURE` · [ ] `AUTOSNAP` · [x] `OSMODE` · [ ] `OSNAPOVERRIDE`

### Object Snap Tracking (AutoTrack) (2)

- [x] `POLARMODE` · [ ] `TRACKPATH`

### Opening Drawings (13)

- [ ] `ACADPREFIX` · [ ] `APPAUTOLOAD` · [ ] `DWGCHECK` · [x] `FILEDIA` · [ ] `LARGEOBJECTSUPPORT` · [ ] `MYDOCUMENTSPREFIX` · [ ] `QVDRAWINGPIN` · [ ] `QVLAYOUTPIN`
- [ ] `REMEMBERFOLDERS` · [ ] `ROAMABLEROOTPREFIX` · [ ] `SUPPRESSALERTS` · [x] `UPDATETHUMBNAIL` · [ ] `WRITESTAT`

### Ortho Mode (1)

- [x] `ORTHOMODE`

### Panning and Zooming the View (10)

- [x] `EXTMAX` · [x] `EXTMIN` · [ ] `MBUTTONPAN` · [ ] `RTREGENAUTO` · [ ] `VIEWBACKSTATUS` · [ ] `VIEWFWDSTATUS` · [ ] `VSMAX` · [ ] `VSMIN`
- [ ] `ZOOMFACTOR` · [ ] `ZOOMWHEEL`

### Polar Tracking and PolarSnap (5)

- [x] `ANGBASE` · [ ] `POLARADDANG` · [ ] `POLARANG` · [ ] `POLARDIST` · [ ] `SNAPTYPE`

### Print or Plot Settings (9)

- [x] `PLOTOFFSET` · [x] `PLOTROTMODE` · [x] `PLOTTRANSPARENCYOVERRIDE` · [ ] `PLQUIET` · [x] `PSTYLEMODE` · [ ] `RASTERDPI` · [ ] `RASTERPERCENT` · [ ] `RASTERTHRESHOLD`
- [ ] `STUDENTDRAWING`

### Property Tools (4)

- [ ] `OPMSTATE` · [ ] `PROPOBJLIMIT` · [ ] `QPMODE` · [ ] `RIBBONCONTEXTSELLIM`

### Protecting Against Malicious Code Reference (6)

- [ ] `ACADLSPASDOC` · [ ] `LEGACYCODESEARCH` · [ ] `SAFEMODE` · [ ] `SECURELOAD` · [ ] `SECUREREMOTEACCESS` · [ ] `TRUSTEDPATHS`

### Publishing Digital Drawings (3)

- [ ] `AUTODWFPUBLISH` · [ ] `AUTOMATICPUB` · [ ] `PUBLISHHATCH`

### Publishing Settings (4)

- [ ] `BACKGROUNDPLOT` · [ ] `BGCOREPUBLISH` · [ ] `PUBLISHALLSHEETS` · [ ] `PUBLISHCOLLATE`

### Recovering From a Crash or Power Failure (3)

- [ ] `DRSTATE` · [ ] `RECOVERYMODE` · [ ] `REPORTERROR`

### Regions and Areas (1)

- [ ] `DELOBJ`

### Removing Objects and Correcting Mistakes (2)

- [x] `UNDOCTL` · [ ] `UNDOMARKS`

### Repairing Damaged Drawings (2)

- [ ] `AUDITCTL` · [ ] `RECOVERAUTO`

### Resizing Objects (5)

- [x] `EDGEMODE` · [ ] `GEOMETRYCLEANUPSTATE` · [ ] `GEOMETRYCLEANUPZOOMPAN` · [ ] `TRIMEDGES` · [x] `TRIMEXTENDMODE`

### Resolving Xref Errors (1)

- [ ] `XREFCTL`

### Revision Clouds (7)

- [ ] `REVCLOUDAPPROXARCLEN` · [ ] `REVCLOUDARCVARIANCE` · [ ] `REVCLOUDCREATEMODE` · [ ] `REVCLOUDGRIPS` · [ ] `REVCLOUDMAXARCLENGTH` · [ ] `REVCLOUDMINARCLENGTH` · [ ] `REVCLOUDSCALEMODE`

### Saving Drawings (7)

- [ ] `DBMOD` · [x] `DWGNAME` · [x] `DWGPREFIX` · [x] `DWGTITLED` · [ ] `SAVENAME` · [ ] `TDUPDATE` · [ ] `TDUUPDATE`

### Selecting Objects (14)

- [ ] `3DSELECTIONMODE` · [ ] `CROSSINGAREACOLOR` · [x] `HIGHLIGHT` · [ ] `PREVIEWFILTER` · [ ] `SELECTIONAREA` · [ ] `SELECTIONAREAOPACITY` · [x] `SELECTIONCYCLING` · [ ] `SELECTIONEFFECT`
- [ ] `SELECTIONEFFECTCOLOR` · [ ] `SELECTIONOFFSCREEN` · [ ] `SELECTIONPREVIEW` · [ ] `SELECTIONPREVIEWLIMIT` · [x] `SELECTSIMILARMODE` · [ ] `WINDOWAREACOLOR`

### Smart Blocks (1)

- [ ] `BSEARCHINCLUDEEXISTINGBLOCKS`

### Starting Drawings (8)

- [ ] `GEOLATLONGFORMAT` · [ ] `GEOLOCATEMODE` · [ ] `GEOMAPMODE` · [ ] `GEOMARKERVISIBILITY` · [ ] `TDCREATE` · [ ] `TDINDWG` · [ ] `TDUCREATE` · [ ] `UNITMODE`

### Tables (5)

- [ ] `CTABLESTYLE` · [ ] `DATALINKNOTIFY` · [ ] `FIELDDISPLAY` · [ ] `TABLEINDICATOR` · [ ] `TABLETOOLBAR`

### Text Styles and Fields (2)

- [ ] `FIELDEVAL` · [ ] `FONTMAP`

### the QuickCalc Calculator (1)

- [ ] `QCSTATE`

### the User Coordinate System (UCS) (13)

- [ ] `PUCSBASE` · [ ] `UCS2DDISPLAYSETTING` · [ ] `UCSAXISANG` · [ ] `UCSBASE` · [ ] `UCSFOLLOW` · [ ] `UCSNAME` · [ ] `UCSORG` · [ ] `UCSORTHO`
- [ ] `UCSSELECTMODE` · [ ] `UCSVIEW` · [ ] `UCSXDIR` · [ ] `UCSYDIR` · [ ] `WORLDUCS`

### Tool Palettes (2)

- [ ] `SHOWPALETTESTATE` · [ ] `TPSTATE`

### Working with Arrays (2)

- [ ] `ARRAYEDITSTATE` · [ ] `ARRAYTYPE`

### Working With DWF Files and Markup (3)

- [ ] `DWFFRAME` · [ ] `DWFOSNAP` · [ ] `MSMSTATE`

### Working With DWG Compare (14)

- [ ] `COMPARECOLOR1` · [ ] `COMPARECOLOR2` · [ ] `COMPARECOLORCOMMON` · [ ] `COMPAREFRONT` · [ ] `COMPAREHATCH` · [ ] `COMPAREPROPS` · [ ] `COMPARERCMARGIN` · [ ] `COMPARERCSHAPE`
- [ ] `COMPARESHOW1` · [ ] `COMPARESHOW2` · [ ] `COMPARESHOWCOMMON` · [ ] `COMPARESHOWRC` · [ ] `COMPARETEXT` · [ ] `COMPARETOLERANCE`

### Working With External References (10)

- [ ] `DGNFRAME` · [ ] `ERHIGHLIGHT` · [ ] `ERSTATE` · [ ] `FRAMESELECTION` · [ ] `INSBASE` · [ ] `XCLIPFRAME` · [x] `XDWGFADECTL` · [x] `XREFNOTIFY`
- [ ] `XREFOVERRIDE` · [ ] `XREFTYPE`

### Working with Geographic Locations (7)

- [ ] `CGEOCS` · [ ] `GEOMARKPOSITIONSIZE` · [ ] `IMAGEFRAME` · [ ] `LATITUDE` · [ ] `LONGITUDE` · [ ] `NORTHDIRECTION` · [ ] `TIMEZONE`

### Working With Groups (1)

- [ ] `GROUPDISPLAYMODE`

### Working With Hyperlinks (1)

- [ ] `HYPERLINKBASE`

### Working with Layout Viewports (3)

- [ ] `MAXACTVP` · [ ] `MVIEWPREVIEW` · [ ] `VPROTATEASSOC`

### Working With Layouts (1)

- [ ] `LAYOUTCREATEVIEWPORT`

### Working with Raster Image Files (3)

- [ ] `FRAME` · [ ] `IMAGEASYNC` · [ ] `IMAGEHLT`

### Working With Sheet Sets (7)

- [x] `SSFOUND` · [x] `SSLOCATE` · [x] `SSMAUTOOPEN` · [ ] `SSMOPENMODE` · [x] `SSMPOLLTIME` · [x] `SSMSHEETSTATUS` · [x] `SSMSTATE`

### Working With the Application Window (23)

- [ ] `CLIPROMPTUPDATE` · [ ] `CLISTATE` · [ ] `CMDACTIVE` · [ ] `CMDINPUTHISTORYMAX` · [x] `CMDNAMES` · [ ] `COLORTHEME` · [x] `EXPERT` · [ ] `INPUTHISTORYMODE`
- [ ] `INPUTSEARCHDELAY` · [ ] `MENUBAR` · [ ] `RIBBONBGLOAD` · [ ] `RIBBONDOCKEDHEIGHT` · [ ] `RIBBONICONRESIZE` · [ ] `RIBBONSELECTMODE` · [ ] `RIBBONSTATE` · [ ] `SYSMON`
- [ ] `TABMODE` · [ ] `TBSHOWSHORTCUTS` · [ ] `TOOLTIPSIZE` · [ ] `TOUCHMODE` · [ ] `TRAYICONS` · [ ] `TRAYNOTIFY` · [ ] `TRAYTIMEOUT`

### Working with Underlays (4)

- [ ] `DGNOSNAP` · [ ] `PDFFRAME` · [ ] `PDFOSNAP` · [ ] `UOSNAP`

### Working with Wipeouts (1)

- [ ] `WIPEOUTFRAME`

**Total listed: 644 system variables.**

## Appendix C. Explicitly NOT in AutoCAD LT

Use this list to avoid scoring features that were never part of LT. Items are grouped by area.

### C.1 3D modeling, visualization and rendering
- 3D solids, surfaces, meshes and NURBS: creation and editing (`BOX`, `CYLINDER`, `SPHERE`, `CONE`, `WEDGE`, `TORUS`, `POLYSOLID`, `EXTRUDE`, `REVOLVE`, `LOFT`, `SWEEP`, `PRESSPULL`, `SURF*`, `MESH*`, `SOLIDEDIT`, `SLICE`, `SECTION`, and solid booleans; 2D region booleans *are* available).
- 3D navigation: `3DORBIT`, orbit/swivel/walk/fly, ViewCube, ShowMotion, animation paths, cameras.
- Visual styles (`VSCURRENT`, `VISUALSTYLES`) — LT's `SHADEMODE` offers only 2D Wireframe and Hidden.
- Perspective view (`PERSPECTIVE` cannot be turned on), lens length, clipping planes, live section.
- Lights, materials, rendering (`LIGHT`, `MATERIALS`, `RENDER`), render presets, sun/sky.
- 3D object snaps, gizmos, dynamic UCS, per-viewport UCS (LT uses one UCS per drawing).
- `ROTATE3D`, `MIRROR3D`, `3DALIGN`, `3DARRAY`, `3DMOVE`, `3DSCALE`, `XEDGES`, `3DEDITBAR`.
- Point-cloud indexing/attachment (`POINTCLOUDATTACH`, `POINTCLOUDINDEX`) — LT can open and view point clouds but cannot attach, index or explode them.
- 3D printing/STL export, ACIS (`SAT`) import/export, 3DS import.

### C.2 Parametrics and dynamic blocks
- Creating or editing geometric/dimensional constraints (`GEOMCONSTRAINT`, `DIMCONSTRAINT`, `AUTOCONSTRAIN`, constraint inference, "Infer Constraints" status-bar toggle).
- Constraint-based dynamic-block authoring (constraints can be viewed/used, and values edited, but not added).
- Block Properties Table user parameters and constraint parameters (action parameters are supported).

### C.3 Automation, data and standards
- Action Recorder (`ACTRECORD`, `ACTSTOP`, action macros).
- Data Extraction (`DATAEXTRACTION`, `EATTEXT`) — `ATTEXT` attribute extraction is available.
- CAD Standards (`CHECKSTANDARDS`, `STANDARDS`, DWS standards checking; DWS is not a supported signature/standard file type).
- VBA (`VBAIDE`, `VBALOAD`), Managed .NET (`NETLOAD`), ObjectARX (`ARXLOAD`), JavaScript API.
- Visual LISP IDE (`VLIDE`, `VLISP`) — AutoLISP itself is supported; use VS Code.
- Express Tools: `GATTE`, `FLATTEN`, `TXTEXP`, `TCOUNT`, `BURST`, and the rest of the Express Tools suite.
- Database connectivity (`DBCONNECT`/dbConnect), SQL/data-source links beyond table data links.
- `MINSERT` (multiple block insertion), `HELIX`, `MLINE` (LT uses `DLINE` double lines), `XEDGES`.
- `3DFACE` — the Help page exists (shared documentation), but LT availability lists mark it unavailable; verify in your build before treating it as a gap.

### C.4 Collaboration/review features not in LT
- Markup Import and Markup Assist (PDF/JPG/PNG markup recognition) — **not available for AutoCAD LT**.
- Shared Views — **removed in 2027** for AutoCAD/LT.
- Open From Web & Mobile / Save To Web & Mobile commands — **removed in 2027**.
- Docs Markup Import (Autodesk Docs PDF markups into Trace).

### C.5 Toolsets and specialized features
- The seven industry toolsets: Architecture, Mechanical, Electrical, MEP, Plant 3D, Map 3D, Raster Design.
- Map 3D/GIS editing (LT has geolocation and online maps, but not GIS data editing), Civil 3D objects, IFC/BIM, Navisworks coordination.
- Point-cloud editing, raster design tools, rendering/animation add-ons.
- Vault integration (full AutoCAD/enterprise).

### C.6 Deliberate LT limits (feature exists, but reduced)
- **One UCS per drawing** (no per-viewport UCS).
- **No visual styles**; only 2D Wireframe/Hidden shading.
- **No perspective**; named views cannot store perspective/visual style/background/live section.
- **No constraint creation/editing**; viewing, manipulation and parameter-value editing only.
- **No LispVariables fields** (cached values still display).
- **No point-cloud attach/index**; view/select only.
- **No Project search paths / `PROJECTNAME`** for xrefs.
- **No selection filtering** (the pre-highlight filter), 3D object snap, gizmo, dynamic UCS, or Infer Constraints status-bar toggles.
- **No password protection** for drawings (removed in the 2016-based releases).
- **No Drawing Standards (.dws)** checking or signing.
- **No user/constraint parameters** in block properties tables.

### C.7 Recently removed (do not implement for 2027 parity)
- `OPENFROMWEBMOBILE`, `SAVETOWEBMOBILE`, `PSOUT` (removed 2027).
- Shared Views (`SHAREVIEW`/`SHAREDVIEWS`) (removed 2027).
- Sheet Set Manager for Web (removed 2026.1.1).
## Appendix D. LT vs. full AutoCAD matrix

| Capability | AutoCAD LT 2027 | AutoCAD 2027 |
|---|---|---|
| 2D drafting, editing, annotation | Yes | Yes |
| DWG/DXF/DWT compatibility | Yes | Yes |
| Blocks + attributes | Yes | Yes |
| Action-based dynamic blocks | Yes | Yes |
| Constraint-based dynamic blocks | View/use only | Yes |
| Parametric constraints | View/edit values only | Create/edit |
| Sheet sets (desktop + cloud) | Yes | Yes |
| Plot/publish PDF/DWF, plot styles | Yes | Yes |
| Xrefs, PDF/DWF/DGN underlays, images | Yes | Yes |
| Point clouds | View only | Attach/index/edit |
| AutoLISP | Yes | Yes |
| Visual LISP IDE | No | Yes |
| ActiveX Automation | AutoLISP-only, limited | Yes |
| VBA / .NET / ObjectARX / JS API | No | Yes |
| Action Recorder | No | Yes |
| Data Extraction | No (ATTEXT only) | Yes |
| CAD Standards (DWS) | No | Yes |
| Express Tools | No | Yes |
| 3D solids/surfaces/meshes | No | Yes |
| 3D navigation/visual styles/perspective | No | Yes |
| Rendering, lights, materials, cameras | No | Yes |
| Markup Import / Markup Assist | No | Yes |
| Trace | Yes | Yes |
| DWG Compare / Xref Compare | Yes | Yes |
| Count, Smart Blocks, Activity Insights | Yes | Yes |
| Autodesk Assistant | Yes | Yes |
| Industry toolsets | No | Yes (7 toolsets) |
| Shared Views | Removed 2027 | Removed 2027 |
| Drawing password protection | Removed 2016 | Removed 2016 |
## Appendix E. Reference tables

### E.1 Function keys

| Key | LT 2027 action | Notes |
|---|---|---|
| F1 | Help | Context help for the active command/dialog/tooltip |
| F2 | Expanded command history | Text window/history |
| F3 | Object snap on/off | Running 2D osnaps |
| F4 | 3D object snap | **Not available in LT** |
| F5 | Isoplane | Cycles 2D isometric planes |
| F6 | Dynamic UCS | **Not available in LT** |
| F7 | Grid display | |
| F8 | Ortho | Mutually exclusive with F10 |
| F9 | Grid snap | |
| F10 | Polar tracking | Mutually exclusive with F8 |
| F11 | Object snap tracking | |
| F12 | Dynamic input | |

### E.2 Command-line startup switches

| Switch | Meaning |
|---|---|
| `/b script` | Run a script after startup (SCR assumed) |
| `/c config` | Configuration folder/file (CFG assumed) |
| `/nohardware` | Disable hardware acceleration at startup |
| `/nologo` | Suppress the logo screen |
| `/nossm` | Do not open the Sheet Set Manager palette |
| `/pl dsd` | Background publish a drawing set description (DSD) |
| `/s folders` | Alternate support folders (max 15, semicolon-delimited) |
| `/safemode` | Prevent all executable code from loading/running |
| `/set dst` | Load a named sheet set at startup |
| `/t template` | New drawing from a template (DWT assumed) |
| `/v view` | Display a named view at startup |
| `/w workspace` | Restore a workspace from the loaded CUIx files |

### E.3 File formats

| Format | Read | Write | LT notes |
|---|---|---|---|
| DWG | Yes | Yes | Current and older DWG versions |
| DWT | Yes | Yes | Drawing templates |
| DXF | Yes | Yes | ASCII/binary options |
| DWS | Limited | No | Standards checking/signing not supported |
| PDF | Yes | Yes | Attach, import geometry/text, export/plot; `PDFSHX` searchable text |
| DWF/DWFx | Yes | Yes | Attach/publish/markup sets |
| DGN | Yes | Yes | Import/export/attach; DGN linetypes; bind |
| WMF | Yes | Yes | `WMFIN`/`WMFOUT` |
| BMP/JPG/PNG/TIF/GIF | Yes (attach) | BMP/JPG/PNG/TIF | Raster images |
| CSV/TXT | Yes | Yes | Table export, `ATTEXT`, data links |
| XLS/XLSX | Yes | No | Table data links |
| SLD | Yes | Yes | Slides (`VSLIDE`/`MSLIDE`) |
| SCR | Yes | Yes | Scripts |
| LIN/PAT/TTF/OTF | Yes | Yes | Linetypes, hatch patterns, text fonts |
| SHX | Yes | Yes | Shape/font files can be compiled with `COMPILE` |
| CTB/STB/PC3/PMP | Yes | Yes | Plot styles/configurations |
| CUIx/ARG/DST | Yes | Yes | Customization/profiles/sheet sets |
| ZIP | Yes | Yes | eTransmit/archive packages |
| SAT/STL/3DS/STEP/IGES | No | No | Full AutoCAD/other products only |

### E.4 Programming interfaces in LT

| Interface | LT 2027 support |
|---|---|
| AutoLISP | Yes (2024+) |
| Visual LISP | Limited (no VLIDE) |
| ActiveX Automation | AutoLISP only, limited, Windows only |
| ObjectARX | No |
| Managed .NET | No |
| VBA | No |
| JavaScript API | No |
| DCL dialogs | Yes (AutoLISP) |

### E.5 Status-bar toggles present in LT

Coordinates, Model/Paper space, Grid, Snap, Dynamic Input, Ortho, Polar Tracking, Isometric Drafting, Object Snap Tracking, 2D Object Snap, LineWeight, Transparency, Selection Cycling, Maximize/Minimize Viewport, Annotation Visibility, AutoScale, Annotation Scale, Viewport Lock, Viewport Scale, Viewport Scale Sync, Workspace Switching, Annotation Monitor, Units, Quick Properties, Lock UI, Graphics Performance, Clean Screen, Tray Settings.

> Not present in LT: Infer Constraints, 3D Object Snap, Dynamic UCS, Selection Filtering, Gizmo.

### E.6 Recent LT feature timeline

| Release | Highlights relevant to a parity audit |
|---|---|
| 2024 | AutoLISP in LT; Smart Blocks placement suggestions; Trace updates and `COPYFROMTRACE`; file tab and layout tab menus; Start tab sorting/search; `PDFSHX`=2 searchable text. |
| 2025 | Activity Insights; Smart Blocks search and convert (text variations); hatch improvements; Esri map additions; Trace updates; font-display acceleration; faster 2D file open. |
| 2026 | Connected Support Files; Smart Blocks text variations; cloud Sheet Set Manager improvements; `REVCLOUDLAYER`, `REVCLOUDSCALEMODE`, `TABLELAYER`, `VIEWPORTLAYER`, `CENTERLAYER` option; GDI plot enhancement. |
| 2027 | Geometry Cleanup; Connected References; AI-enhanced Autodesk Assistant; partial CUIx/tool palette sharing on projects; multi-sheet property editing and polyline grip Lengthen (2027.1); `SAVEAS` full save; removal of Web & Mobile open/save and Shared Views. |

## Appendix F. Sources

- AutoCAD LT 2027 Help — Command Reference, System Variables, User's Guide: <https://help.autodesk.com/view/ACDLT/2027/ENU/>
- *What's New or Changed in AutoCAD LT 2027* (`AutoCAD-LT-WhatsNew`, GUID-A9705369-1107-43E4-A723-D7D72FD0318A)
- *What's New in AutoCAD LT 2024/2025/2026* (LT What's New book)
- *About Working With AutoCAD Drawings in AutoCAD LT* (GUID-97C5344F-CF59-4B02-9EA2-22247820D239)
- *IMPORTANT: Limited Parametric Drawing Functionality in AutoCAD LT* (GUID-A950070D-4AEB-4F0E-B1D9-0AD53E10048C)
- *About Supported Programming Interfaces* (GUID-E6429154-36DF-4D84-8ABC-9FCA15B66158)
- *Status Bar Quick Reference* (GUID-E3B34B0A-EA98-45E9-937A-BF5FEF4152DB), *Function Key Reference* (GUID-ACAA0279-047D-458E-889F-60BBFDD40489), *Command Line Switch Reference* (GUID-5D481F9B-E8BB-469D-B5C4-ED997B8263D5)
- *About Digital Signatures For Drawings* (GUID-3D3F2AB3-E3B0-40D7-9A47-4BC77AAE451E), *About Passwords and Encryption* (GUID-4E32143C-AA81-4A4E-9191-B32C4AA259EE)
- *DWG Compare Limitations* (GUID-3D918CC7-4FB7-4951-8F04-C2434DFD04A2), *About Activity Insights* (GUID-57A1B411-9F00-4318-9CA1-A6490571597D)
- *About Creating Dynamic Blocks* (GUID-DF133028-1A0C-4739-859F-83D967041B91), *About Using ActiveX with AutoLISP* (GUID-BA470FE7-6488-4BC9-8FC8-ED93C32D86AA)