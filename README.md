> AutoCAD and DWG are registered trademarks of Autodesk, Inc. Zephyr is an independent application and is not affiliated with, sponsored by, or endorsed by Autodesk.

# Zephyr

**A native, GPU-accelerated 2D CAD application — free, open source, and built from scratch in Swift.**

Zephyr is a drafting app that runs natively on macOS (Metal), Windows (Direct3D 12), and Linux (Vulkan). It reads DWG and DXF, exports PDF with Bluebeam-compatible measurements, and is designed to replace QCAD/LibreCAD as the go-to free alternative to AutoCAD LT. No subscriptions, no telemetry, no Qt/OpenGL legacy stack.

![Zephyr screenshot](docs/uploads/zephyr.png)

## Download

| Platform | Architecture | Download |
|---|---|---|
| macOS 12+ | Universal (Apple Silicon & Intel) | [Zephyr-macOS-Universal.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-macOS-Universal.zip) |
| Windows 10+ | ARM64 (Snapdragon / Surface) | [Zephyr-Windows-arm64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Windows-arm64.zip) |
| Windows 10+ | x64 | [Zephyr-Windows-x64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Windows-x64.zip) |
| Linux (AppImage) | x64 | [Zephyr-Linux-x64.AppImage](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-x64.AppImage) |
| Linux (AppImage) | ARM64 | [Zephyr-Linux-arm64.AppImage](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-arm64.AppImage) |
| Linux (Flatpak) | x64 | [Zephyr-Linux-x64.flatpak](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-x64.flatpak) |
| Linux (Flatpak) | ARM64 | [Zephyr-Linux-arm64.flatpak](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-arm64.flatpak) |
| Linux (Portable ZIP, glibc 2.35+) | x64 | [Zephyr-Linux-x64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-x64.zip) |
| Linux (Portable ZIP, glibc 2.35+) | ARM64 | [Zephyr-Linux-arm64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-arm64.zip) |
| Linux (Snap) | x64 | [zephyr_1.0_amd64.snap](https://github.com/joseph-montanez/zephyr/releases/download/nightly/zephyr_1.0_amd64.snap) |
| Linux (Snap) | ARM64 | [zephyr_1.0_arm64.snap](https://github.com/joseph-montanez/zephyr/releases/download/nightly/zephyr_1.0_arm64.snap) |

### Linux Distribution Compatibility

| Format | Compatible Distributions & Versions | How to Run / Install |
|---|---|---|
| **Flatpak** | **Any Linux distribution with Flatpak installed**<br>• Ubuntu (all supported releases)<br>• Debian 11/12+<br>• Fedora (all releases)<br>• Arch Linux / Manjaro<br>• openSUSE Leap & Tumbleweed<br>• RHEL / Rocky / AlmaLinux 8/9+<br>• Linux Mint & Pop!_OS | `flatpak install --user <file>.flatpak`<br>`flatpak run com.zephyr.cad` |
| **AppImage** | **Any Linux distribution with `glibc >= 2.35`**<br>• Ubuntu 22.04 LTS (Jammy) & 24.04 LTS (Noble)+<br>• Debian 12 (Bookworm) & 13 (Trixie)<br>• Fedora 37+ (including 38, 39, 40, 41+)<br>• Linux Mint 21+ & Pop!_OS 22.04+<br>• Arch Linux / Manjaro (all rolling)<br>• openSUSE Leap 15.5+ & Tumbleweed | `chmod +x <file>.AppImage`<br>`./<file>.AppImage` |
| **Snap** | **Any Linux distribution with `snapd`**<br>• Ubuntu (pre-installed)<br>• Debian, Fedora, Arch, openSUSE with `snapd` installed | `sudo snap install --dangerous <file>.snap`<br>(see [DEVELOPMENT.md](DEVELOPMENT.md#4-snap-packaging)) |
| **Portable ZIP** | **Distributions with `glibc >= 2.35`**<br>• Portable directory; requires host graphics/audio drivers | Extract and execute `./Zephyr` |

## Escape the Rent Trap

**Own nothing and be happy? Break free from constant price hikes.**

If you look at the subscription costs for AutoCAD LT, it's **$540 a year** if you pay upfront (which would be the $45 a "month"), or a massive markup to **$840 a year** if you have to pay the $70 monthly. They use aggressive marketing to lock you into 3-year commitments just to avoid price hikes, and the second you stop paying, you own absolutely nothing.

On top of that, finding great cross-platform tools that treat macOS and Linux as first-class citizens is a nightmare. Most polished solutions are strictly Windows-only. For example, while Autodesk finally added AutoLISP support to AutoCAD LT on Windows recently (2024), their official documentation explicitly states that AutoLISP is completely blocked on AutoCAD LT for Mac. If you're on a Mac and need LISP automation, they force you to step up to the full AutoCAD license at over **$2,000 a year**.

> **Note:** We highly encourage looking at other excellent free open-source software like **QCAD**, **LibreCAD**, **FreeCAD**, **SolveSpace**, **Open CAD Studio** and **Open 2D Studio** as powerful options to try in your drafting workflows. Zephyr exists alongside these community solutions as a performance-oriented alternative, utilizing Direct3D 12 on Windows, Metal on macOS, and Vulkan on Linux through a single Swift GPU pipeline to feel native on all three.

## Tech Stack

| Layer | Technology |
|---|---|
| **Language** | Swift (~170k lines, excl. blanks/comments) |
| **GPU (macOS)** | Metal via SDL3 |
| **GPU (Windows)** | Direct3D 12 via SDL3 |
| **GPU (Linux)** | Vulkan via SDL3 |
| **UI** | ImGui (SDL3 GPU backend) |
| **DXF I/O** | Swift port of libdxfrw) |
| **DWG I/O** | ODA CLI bridge (import/export) today — native Swift DWG codec planned, see Roadmap |
| **PDF Export** | PDFium (Windows/Linux) · PDFKit (macOS) |
| **PDF Import** | PDFium (Windows/Linux) · PDFKit (macOS) |
| **Compression** | zstd via zlib-ng |
| **Fonts** | SDL_ttf + custom SHX byte-code interpreter |
| **License** | GPL v3 — free to use, fork, and ship |

## Why Zephyr?

- **QCAD/LibreCAD replacement** — DXF parsing that actually works: MText formatting, SHX shape fonts, NURBS splines, dimension styles, and title blocks all render correctly. No raw escape codes leaking into labels, no scrambled curves, no missing logos.
- **AutoCAD LT alternative** — AutoCAD muscle memory preserved. `L`, `PL`, `C`, `REC`, `M`, `O`, `TR`, `J` all work. Command palette with fuzzy autocomplete, polar tracking, object snap tracking, grips, and a full snap engine. The ribbon and its classic `File / Edit / View` menu bar are AutoLISP files you can rewrite, not compiled-in chrome.
- **GPU-native** — Metal on macOS, Direct3D 12 on Windows, Vulkan on Linux. Single Swift rendering pipeline. 120 FPS canvas with pixel-perfect GPU picking. No OpenGL emulation layer.
- **Free forever** — GPL v3. No account, no email gate, no subscription.

## Current Features

### File I/O
- **DWG import/export** — Full read/write via ODA FileConverter. Blocks, layers, text styles, hatches, splines, polylines with bulge, dimensions. Native DWG round-trip. The converter is a host CLI bridge, so DWG currently requires a desktop OS — the roadmap's native Swift codec removes that constraint.
- **DXF import/export** — R2007 round-trip. Dimensions, splines, hatches, leaders all preserved. Layer transparency (group code 440) supported.
- **PDF export** — Vector PDF 1.7 with Bluebeam Revu-compatible Measurement dictionary.
- **PDF import** — Cross-platform: PDFKit on macOS, PDFium on Windows/Linux. Page selector with preview. Raster underlay at 150 DPI. (Import embeds a snapshot; `PDFATTACH` keeps a live link — see External References below.)
- **External references (xrefs)** — Attach DWG/DXF drawings, raster images, and PDF pages as live references with `ATTACH`. Host files store paths only; referenced content renders from a runtime copy and never bakes into saves. Full DXF write-back (xref blocks, `IMAGEDEF`/`PDFDEFINITION`, `SPATIAL_FILTER` clips), so files round-trip with AutoCAD.
- **EAB native format** — Fast binary save/load. zstd compression, BVH spatial index, viewport-culled partial loads.

### Swift DXF Module (SwiftDXFrw)

Zephyr's DXF pipeline runs entirely in Swift — a native port of [libdxfrw](https://github.com/LibreCAD/libdxfrw) that eliminates the C++ bridge and its ABI pitfalls. ~8.6k lines of Swift (excluding blanks/comments) across `DXFReader`, `DXFWriter`, `DXFEntity`, `DXFColorTable`, and `DXFTextCodec`. The port preserves every enhancement from the original C++ fork while adding Swift-native safety and cross-platform builds with zero C++ toolchain dependency.

| Feature | Description |
|---|---|
| **Layer transparency** | Reads DXF group code 440 (opacity 0–100%) and exposes per-layer transparency. Full round-trip support. |
| **Spline NURBS weights** | Parses rational NURBS weights (group 41) for each control point. Enables faithful rendering of weighted spline curves instead of flattening to uniform. |
| **Hatch gradient fills** | Decodes gradient fill sub-objects (codes 450–470) — linear, cylindrical, spherical, etc. Stores gradient name, angle, and two RGB colors per hatch. |
| **Attribute text & block attribute support** | `ATTRIB` and `ATTDEF` entity types with tag, flag, and text value extraction. Block inserts carry their full attribute payload. |
| **Background fill color** | Hatch background fill (ACI group 63) surfaced independently from pattern color, matching AutoCAD's background fill mechanic. |
| **Encoding/codec improvements** | Strips malformed `$DWGCODEPAGE` headers, auto-detects and sanitizes MText embedded objects, error recovery for charset conversion. Binary DXF sniffing with hex-dump diagnostics for bad input. |
| **Zero-C++ dependency** | Compiles on macOS, Windows, and Linux via Swift Package Manager. No vcpkg, no CMake, no iconv linkage — pure Swift with Foundation's encoding support. |

### Drawing Commands
| Command | Alias | Description |
|---|---|---|
| LINE | `L` | Line segments |
| POLYLINE | `PL` | Multi-vertex polylines with arc segments |
| CIRCLE | `C` | Center-radius circles |
| ARC | `A` | 3-point arcs |
| RECTANGLE | `REC` | Axis-aligned rectangles |
| ELLIPSE | `EL` | Ellipses and elliptical arcs |
| HATCH | `H` | Boundary hatches with pattern fill |
| SPLINE | `SPL` | NURBS splines |
| RAY | `R` | Infinite construction rays |
| TEXT | `T` | Multi-line text with font selection, height, rotation, alignment, column width |
| IMAGE | `IMG` | Embedded raster image placement (PNG, JPG, etc.) — use `IMAGEATTACH` for a live reference |
| PDFIMPORT | `PDFI` | Embed a PDF page as raster/vectors — use `PDFATTACH` for a live underlay |
| TABLE | `DT` | Insert a configurable data table with rows and columns |
| MEASURE | | Place points or blocks at measured intervals along an object |
| DIVIDE | `DIV` | Place points or blocks at equal divisions along an object |

### File Commands
| Command | Alias | Description |
|---|---|---|
| NEW | `N` | Create a new blank drawing in a new tab |
| OPEN | | Open a DXF, DWG, or EAB file in a new tab |
| CLOSE | | Close the active drawing tab |
| CLOSEALL | | Close all open drawing tabs |
| CLOSEALLOTHERS | | Close all tabs except the active one |
| SAVE | `QSAVE` | Save the current drawing to its file |
| SAVEAS | | Save the current drawing as a new file |
| PDFEXPORT | `EXPORTPDF` | Export the current drawing to a PDF file |

### Tabs, Windows & Split Views
| Command | Alias | Description |
|---|---|---|
| TABLEFT | `TABL` | Move the active tab one position left |
| TABRIGHT | `TABR` | Move the active tab one position right |
| TABWINDOW | `TABW`, `FLOAT` | Float the active tab into its own OS window |
| TABDOCK | `TABD`, `DOCK` | Dock the active floating tab back into the main window |
| FILETAB | | Show the file tab bar |
| FILETABCLOSE | | Hide the file tab bar |
| VPORTS | | Manage split panes: `VPORTS 2V`, `2H`, `SINGLE`, `JOIN`, `TOGGLE`, or `?` |
| VSPLIT | | Split the focused pane side-by-side |
| HSPLIT | | Split the focused pane stacked |
| UNSPLIT | `CLOSESPLIT` | Remove all splits, keeping the focused pane |
| CLOSEPANE | | Close the focused pane |
| VPMAX | | Maximize the focused pane (arrangement is saved) |
| VPMIN | | Restore the split arrangement saved by VPMAX |

### Ribbon
| Command | Alias | Description |
|---|---|---|
| RIBBON | | Show or hide the ribbon (a dockable window; position persists) |
| RIBBONCLOSE | | Hide the ribbon |
| RIBBONMODE | | Switch presentation: `RIBBONMODE menu`, `labels`, or `full`; bare Enter reports the current mode |
| RIBBONRELOAD | | Re-read the AutoLISP ribbon definition (`lisp/ribbon.lsp`) |

The ribbon's contents are **defined in AutoLISP**, not in the binary — see [Customizing the ribbon](#customizing-the-ribbon). That same file also defines the classic `File / Edit / View …` menu bar, because the ribbon's display control cycles three presentations of one definition: the **menu bar**, **labels only**, and **icons + labels**.

#### Working with tabs

- Click a file tab to activate that drawing. Drag it left or right to reorder it, or drag it out of the main window to float it.
- `TABLEFT`/`TABL` and `TABRIGHT`/`TABR` move the active tab one slot. Moving a tab does not change which drawing is active.
- `Ctrl+Tab` and `Ctrl+Shift+Tab` cycle open drawings, including drawings hosted in floating windows.
- Dirty drawings keep their unsaved marker and save/discard confirmation. `CLOSE` still closes the active drawing; it is not the same as closing a float window (below).
- `FILETAB` and `FILETABCLOSE` show or hide the file-tab bar. The file-tab bar itself remains in the main window; floated drawings do not get a second copy of it.

#### Floating a drawing into an OS window

`TABWINDOW` (`TABW` or `FLOAT`) moves the active drawing into a true SDL/OS window with its own native title bar, so it can be moved to another monitor. Running the command again for an already floated drawing raises its window. You can pan, zoom, select, edit, use commands, and edit blocks in the float window. Click, mouse-wheel, pen, and keyboard input in a window activate the drawing it hosts; merely hovering over it does not steal activation.

`TABDOCK` (`TABD` or `DOCK`) returns the active floating drawing to the main tab bar at its existing tab-order position. The float window's OS close box also docks it. It never closes the drawing, so unsaved work is not lost. Up to four drawings can be floated at once. All windows belong to one Zephyr process and share one active drawing and editing session at a time, while inactive windows continue to show their hosted drawing, cursor, hover, and stored selection.

#### Splitting the main window

`VSPLIT` splits the focused main pane side-by-side; `HSPLIT` stacks it. Repeating either command splits the newly focused pane again, creating a nested arrangement. New panes start at 50/50. Drag a divider to resize (minimum pane size: 80 points).

When another docked drawing is available, a new pane shows the next docked drawing. When only one docked drawing is available, the new pane shows the same drawing, AutoCAD-viewport style. Click a pane to focus it and activate its drawing. Click a file tab while split to bring that drawing into the focused pane. Each pane remembers its own pan/zoom/rotation and its Model or paper-layout view for the drawing it shows, so one pane can show `Model` while another shows `Layout1`, or two panes can compare different drawings. The bottom Model/Layout tabs belong to the tab shown by the current window or focused pane.

`CLOSEPANE` joins away the focused pane. `UNSPLIT` and `VPORTS SINGLE` collapse to the focused pane and remember the arrangement. `VPMAX` does the same as a maximize step, `VPMIN` restores the remembered arrangement, and `VPORTS TOGGLE` switches between single and split. `VPORTS ?` lists the current panes in command output and marks the focused pane with `*`. Bare `VPORTS` prints the accepted options and the current layout; Zephyr's compact forms are `VPORTS 2V` and `VPORTS 2H`.

#### AutoCAD compatibility

| Area | AutoCAD behavior | Zephyr behavior |
|---|---|---|
| File-tab visibility | `FILETAB` / `FILETABCLOSE` | Same command names and purpose. |
| Tiled viewports | `VPORTS` creates multiple model-space views of one drawing. | Same-drawing panes are supported, and panes may also show different drawings. Supported options are `2V`, `2H`, `SINGLE`, `JOIN`, `TOGGLE`, and `?`. AutoCAD named configurations (`SAVE`/`RESTORE`/`DELETE`) and preset 3/4 arrangements are not implemented yet. |
| Maximize a viewport | `VPMAX` / `VPMIN` expand and restore a layout viewport for model-space editing. | The names are reused for Zephyr split panes: maximize the focused pane, then restore the saved pane tree. This is not paper-space `MSPACE` editing. |
| Drawing layouts | Model/layout tabs and the full `LAYOUT` management command. | Model/layout tabs switch views. `MODEL`, `SHEET`/`LAYOUT`, `VIEW`, `NEXTVIEW`, and `PREVIOUSVIEW` are selectors for imported Model/paper views; they do not implement AutoCAD layout creation/copy/rename options or `MSPACE`/`PSPACE`. |
| Tab order and floating | File tabs and document-window workflows vary by AutoCAD version. | `TABLEFT`, `TABRIGHT`, `TABWINDOW`, and `TABDOCK` (with the `TABL`/`TABR`/`TABW`/`TABD` aliases) are Zephyr command names. Drag-to-reorder and drag-out-to-float provide the pointer workflow. |
| Drawing activation | One current drawing/viewport receives editing input. | Exactly one tab and, when split, one focused pane is active across the main and float windows. Direct interaction activates the clicked window/pane. |

Dialogs are parented to the window hosting the active drawing where the platform supports it. Tab-close confirmations surface in the main window, where the file tabs live. Split layouts and floated positions are session state; they are not saved as named viewport configurations yet.

### Dimension Commands
| Command | Alias | Description |
|---|---|---|
| DIMLINEAR | `DLI` | Horizontal/vertical dimension between two points |
| DIMALIGNED | `DAL` | Dimension parallel to the measured distance |
| DIMANGULAR | `DAN` | Angle dimension between two lines or an arc |
| DIMARC | `DAR` | Arc length dimension along a curve |
| DIMRADIUS | `DRA` | Radius dimension for arcs/circles |
| DIMDIAMETER | `DDI` | Diameter dimension for arcs/circles |
| DIMORDINATE | `DOR` | X or Y ordinate dimension from a UCS origin |
| DIMJOGGED | `DJO` | Jogged radius dimension (for large radii) |

### Leader Commands
| Command | Alias | Description |
|---|---|---|
| LEADER | `LEAD` | Create a leader line with annotation |
| QLEADER | `LE` | Quick leader — specify points then text |
| MLEADER | `MLD` | Create a multileader object |
| MLEADEREDIT | `MLE` | Edit multileader content and properties |
| MLEADERALIGN | `MLA` | Align selected multileaders |
| MLEADERCOLLECT | `MLC` | Collect multileaders into a group |
| MLEADERSTYLE | `MLS` | Create and manage multileader styles |

### Edit & Modify
| Command | Alias | Description |
|---|---|---|
| JOIN | `J` | Join collinear/contiguous entities — lines and arcs auto-convert to NURBS splines for joining |
| TRIM | `TR` | Trim to cutting edges |
| SPLINEEDIT | `SPE` | Edit splines: convert to polyline, close, reverse, insert knot, join |
| MATCHPROP | `MA` | Format painter — copy layer, color, weight, and linetype from source to destinations |
| DDEDIT | `ED` | Edit text and attributes in-place via text editor dialog |
| ARRAY | `AR` | Create a rectangular, polar, or path array |
| CLEANSPECKLES | `CS` | Sample-and-erase speckle artifacts from scanned drawings |
| MEASUREGEOM | `MEA` | Quick Measure — hover to raycast orthogonal distances |
| ERASE | `E` | Delete selected entities |
| COPY | `CO` | Duplicate selected entities in-place |
| BRINGTOFRONT | `BTF` | Move selected entities to front of draw order |
| SENDTOBACK | `STB` | Move selected entities to back of draw order |
| BRINGABOVEOBJECTS | `BAO` | Place selection above a picked reference entity |
| SENDUNDEROBJECTS | `SUO` | Place selection under a picked reference entity |
| TEXTTOFRONT | `TTF` | Bring all text, dimensions, and leaders to front |
| HATCHTOBACK | `HTB` | Send all hatches and solid fills to back |
| FILLET | `F` | Round corners between objects using an exact tangent arc |
| CHAMFER | `CHA` | Bevel corners between two objects |
| OFFSET | `O` | Parallel copy at a distance or through a point — Through, Erase, Layer, and Multiple options |
| ALIGN | `AL` | Align objects by matching two pairs of source/destination points (move, rotate, optionally scale) |
| TORIENT | `TO` | Rotate text individually to an absolute or most-readable angle |

#### Offset

`OFFSET` (`O`) makes a parallel copy of one object at a time, then loops back for the next object until Enter or Esc.

1. **Specify the distance** — type a value, press Enter to reuse the last distance, or pick two points and Zephyr uses the distance between them. A live preview follows the cursor once an object is picked.
2. **Select object to offset** — lines, rays, circles, arcs, ellipses, splines, and polylines (arc/bulge segments included). Block references, text, hatches, leaders, and dimensions cannot be offset.
3. **Pick a point on the side** to place the copy.

Options at the distance prompt, AutoCAD-style:

- **Through (`T`)** — skip the distance; the copy passes through the point you pick.
- **Erase (`E`)** — delete the source object after offsetting (Yes/No, default No).
- **Layer (`L`)** — `Source` (default) keeps the original layer and color; `Current` places copies on the active layer with BYLAYER color.

At the side prompt, **Multiple (`M`)** offsets the same object repeatedly with each click, **Undo (`U`)** reverts the last offset without leaving the command, and **Exit (`E`)** ends it. Ellipses and splines offset to splines, as in AutoCAD.

`OFFSETGAPTYPE` controls outside corners when offsetting polylines: `0` extends segments to sharp corners (default), `1` rounds corners with an arc whose radius equals the offset distance, `2` chamfers them. Inside corners always trim to the intersection. The last distance is remembered as the next default; from AutoLISP both settings are the `OFFSETDIST` (`-1` means Through is the default) and `OFFSETGAPTYPE` system variables.

### Array Commands
| Command | Alias | Description |
|---|---|---|
| ARRAY | `AR` | Create a rectangular, polar, or path array |
| ARRAYRECT | `ARRAYR` | Create an associative rectangular array |
| ARRAYPOLAR | `ARRAYP` | Create an associative polar array |
| ARRAYPATH | `ARRAYPA` | Create an associative path array |
| ARRAYEDIT | | Select and edit an associative array |
| ARRAYCLOSE | | Close array editing or source-edit mode |
| -ARRAYCLOSE | | Close array source editing from command line (`[Yes|No]`) |
| ARRAYCLASSIC | | Create a legacy non-associative rectangular or polar array |
| -ARRAY | | Create a non-associative rectangular or polar array from prompts |
| ARRAYASSOCIATIVITY | | Set whether new arrays are associative (`[0|1]`) |
| ARRAYEDITSTATE | | Display whether array source editing is active |
| ARRAYTYPE | | Set the default array type (`[0|1|2]`: rectangular, path, polar) |
| EXPLODE | `X` | Break compound objects into component elements |

### Clipboard (Copy/Paste)
| Command | Description |
|---|---|
| COPYCLIP | Copy selected entities to clipboard |
| COPYBASE | Copy selected entities with a specified base point |
| PASTECLIP | Paste clipboard entities at viewport center |
| PASTEORIG | Paste clipboard entities at original coordinates |
| PASTEBLOCK | Paste clipboard entities as a new block |

### Tool Modes
SELECT, MOVE, ROTATE, SCALE, PAN, ZOOM

### View Commands
| Command | Alias | Description |
|---|---|---|
| ZOOM | `Z` | AutoCAD-style ZOOM with sub-commands: All, Center, Dynamic, Extents, Left, Previous, Right, Scale, Object, Window, Realtime |
| ZOOMEXTENTS | `ZOOME` | Zoom to fit all entities |
| PAN | `P` | Click-and-drag pan (hand cursor mode) |
| -PAN | | Pan by displacement vector |
| DVIEW | `DV` | Dynamic view twist (rotate the 2D view angle) |
| PLAN | | Reset view rotation to standard orientation |
| VIEW | `VIEWS` | List, select, or cycle model and sheet views |
| SHEET | `LAYOUT` | Select or cycle imported DXF sheet layouts |
| MODEL | `2DVIEW` | Switch to the DXF 2D model-space view |
| NEXTVIEW | `VIEWNEXT` | Switch to next model or sheet view |
| PREVIOUSVIEW | `PREVVIEW`, `VIEWPREV` | Switch to previous model or sheet view |
| SELECTALL | `SELALL` | Select all entities in the active layer |
| VPORTS | | Split the main view into tiled panes showing different tabs (`2V`, `2H`, `SINGLE`, `JOIN`, `TOGGLE`, `?`) |
| VPMAX / VPMIN | | Maximize the focused pane / restore the saved arrangement |
| AUTOCONTRAST | `TRUECOLORCONTRAST`, `CONTRAST` | Toggle viewport auto-contrast adjustment for 24-bit TrueColors and gradients (`ON`/`OFF`, default `ON`). Preserves contrast for standard ACI colors |

### Snap Engine
9 anchor types with two-tier filtering (AABB proximity → exact distance):
center, vertex, midpoint, insertion point, quadrant, nearest, perpendicular, tangent, intersection

### Tracking
- **Ortho mode (F8)** — Hard-constrain cursor to cardinal axes (0°/90°/180°/270°) from the reference point. Works with direct distance entry — type a number during MOVE to move precisely along the ortho axis.
- **Polar tracking** at configurable angle increments (`POLARANG`)
- **Object snap tracking (OTRACK)** from acquired points (500ms dwell)
- **Extension snapping** along existing geometry
- **Snap angle** (`SNAPANG`) sets crosshair and ortho rotation angle
- **Direct distance entry** — during MOVE/COPY, type a distance and press Enter to move exactly that far along the current direction. Works with ortho, polar, OTRACK, and extension snaps — the ghost preview and tracking line always follow the active snap direction.
- Toggle via `POLAR`, `OTRACK`, `EXTENSION`, `ORTHO` commands or `F8` (ortho)

### Grips
Per-vertex grips on polylines and polygons. Corner, center, midpoint, and rotation grips on selection bounding boxes. Configurable limits: `SETTINGSGRIPOBJECTMAX` (entity count threshold, default 100) and `SETTINGSGRIPMAX` (total grip squares drawn, default 1000).

### Blocks & External References
- **Block edit in-place** (`BEDIT` / `BE`) — enter block editor with green banner and titlebar indicator. Save/Discard/Cancel dialog on close.
- **BCLOSE** — close block editor with save confirmation prompt.
- **BLOCKS panel** — block library with preview and Insert.
- **SIMPLIFY** — swaps heavy blocks for bounding-box stand-ins during pan/zoom.
- **MAKE BLOCK** — `BLOCK` / `BMAKE` to create a new block from selected entities.

| Command | Alias | Description |
|---|---|---|
| INSERT | `I`, `-INSERT` | Insert an existing block, or a whole DWG/DXF/EAB file as an embedded block copy |
| ATTACH | | Attach a drawing, raster image, or PDF as a live reference (routes by file type) |
| XATTACH | `XA` | Attach a DWG/DXF drawing as an xref — Attachment or Overlay |
| IMAGEATTACH | | Attach a raster image (PNG, JPG, GIF, BMP, …) as a live reference |
| PDFATTACH | | Attach one page of a PDF as a live underlay |
| -ATTACH | | Command-line attach: path → (page) → insertion point → scale → rotation; `?` at the page prompt lists the page count |
| XREF | `ER`, `EXTERNALREFERENCES` | External References palette — every drawing, image, and PDF reference with live status |
| -XREF | | Command-line xref manager: `?/Bind/Attach/Detach/Reload/Unload/Load/Path` |
| XBIND | | Bind one xref-dependent layer (`Xref\|Layer`) into the host |

#### How references work

- **Attachment vs Overlay** — Attached drawings travel with the host when the host is itself referenced elsewhere; overlays don't. Nested overlays show as *Orphaned*, reference cycles as *Circular*.
- **Paths** are saved per `REFPATHTYPE` (default `1` = relative to the host drawing). Resolution follows AutoCAD's search order: the saved path, relative to the immediate host, the drawing folder, then configured support search paths. Windows paths degrade gracefully to a filename search on macOS/Linux.
- **Statuses** in the palette match AutoCAD's vocabulary: Loaded, Unloaded, Not Found, Unresolved, Orphaned, Unreferenced, Needs Reloading — plus Zephyr's Circular and Over Budget. Changed source files are detected in the background and flagged Needs Reloading; the status bar shows `XREF ⚠`.
- **Delete ≠ Detach.** Deleting a placed instance leaves the reference definition in the list as *Unreferenced* (that's AutoCAD behavior too). **Detach** (palette or `-XREF`) removes the definition and all its placements. **Bind** makes a drawing permanent (`BINDTYPE 0` keeps `Name$0$Symbol` names, `1` merges like INSERT); **Embed** does the same for an image or PDF.
- **Layers** from a referenced drawing appear as `XrefName|Layer` and behave like normal layers (freeze/off/opacity). `VISRETAIN` controls whether host overrides survive a reload. Xref geometry is dimmed by `XDWGFADECTL` (default 50) so host work stays readable.
- **Loading is async and capped** — up to 32 loaded drawing xrefs, nesting depth 16, and 5M total primitives per tab (set `XLOADCTL` to `0` to disable the caps). Loading never dirties the drawing and never enters undo. Images/PDFs share a decoded-pixel budget.
- **Clipping** — `CLIP` works on xrefs, images, and PDF underlays, and clips print to PDF correctly.

| System variable | Default | Meaning |
|---|---|---|
| `REFPATHTYPE` | `1` | Saved path kind for new references: `0` none (filename only), `1` relative, `2` full |
| `VISRETAIN` | `1` | `1` keep host layer overrides on reload, `0` reset to the referenced file's layer states |
| `BINDTYPE` | `0` | Bind mode: `0` Bind (`$0$` names), `1` Insert (merge, host wins) |
| `XDWGFADECTL` | `50` | Xref fade percent, `0`–`90` (display only) |
| `XREFNOTIFY` | `1` | Background change detection for referenced files |
| `XLOADCTL` | `2` | `0` disables the load caps; `1`/`2` keep them |

Not yet: `REFEDIT` in-place editing of a referenced drawing (Bind or open the file instead), DWF/DGN underlays (they parse but don't render), and on-zoom re-rendering of PDF pages (fixed rasterization DPI). Two AutoCAD caveats apply as usual: AutoCAD displays only **DWG** xrefs — a DXF target must be converted to DWG first (saving as DWG warns you) — and the unloaded state is remembered only in EAB files, not in DWG/DXF.

### Layers
- Full layer table with ACI color indexing.
- Per-layer line type, weight, and **opacity** (DXF group code 440, 0–100%).
- Layer opacity slider in the layer panel.
- Layer management commands: `LAYER NEW`, `LAYER DELETE`, `LAYER RENAME`, `LAYER ?` (alphabetical listing).
- **Sortable Layers panel** — Run `LAYERSORT` (for example `LAYERSORT COLOR DESC`, `LAYERSORT USED`, or `LAYERSORT REVERSE`) to sort by name, state, color, linetype, lineweight, opacity, plot, or used; it opens the Layers panel so the new order is visible. Repeating a key toggles direction. The panel also has **On/Color/Name** sort buttons, a **Sort** menu, and a name search box. Sort choice persists across sessions, not in the drawing.
- Layer move command (`LAYERMOVE` / `LM`) — modal dialog with filterable layer list.

### SHX Shape Font Interpreter
Full byte-code interpreter for AutoCAD `.shx` shape fonts. Text renders as pure vectors at any zoom — no bitmap degradation.

### MText Parser
Full interpreter for DXF formatting codes — `%%u` (underline), `%%o` (overline), `%%d` (degree), `%%c` (diameter), `\P` (paragraph break), font/color/width stack changes. Attachment point, column width, and line spacing factor all honored.

### NURBS / Spline Evaluator
Adaptive subdivision keyed to screen pixels. Curves stay smooth at any zoom, bounded arcs stay bounded.

### AutoLISP
Native AutoLISP engine with **305 builtins** — the full inventoried set, verified against every documented example. Runs your existing `.lsp` routines: entity creation and editing (`entmake`/`entmod`/`entget`), selection sets, system variables, file I/O, dictionaries, layer states, and scripted `(command …)` calls, with AutoCAD-compatible undo grouping per script.

| Command | Alias | Description |
|---|---|---|
| LOAD | | Load and evaluate a `.lsp` file (opens a file picker) |
| EVAL | | Evaluate a single Lisp expression string |
| SCRIPT | `SCR` | Run a `.scr` command script (opens a file picker) |

```lisp
;; Color all circles red
(setq ss (ssget "_X" '((0 . "CIRCLE"))))
(setq i 0)
(repeat (sslength ss)
  (setq e (entget (ssname ss i)))
  (entmod (if (assoc 62 e)
            (subst '(62 . 1) (assoc 62 e) e)
            (append e (list '(62 . 1)))))
  (setq i (1+ i)))
```

Scripted command calls include `(command "INSERT" ...)`, `(command "_CHPROP" ...)` (color, layer, linetype, ltscale, lineweight), and, for images/PDFs, `(command "-ATTACH" path [page] point [scale [rotation]])`. Drawing properties and system variables (`CELTYPE`, `CELTSCALE`, `CELWEIGHT`, `CECOLOR`, `LTSCALE`, `AUTOCONTRAST`, plus xref variables `REFPATHTYPE`, `VISRETAIN`, `BINDTYPE`, `XDWGFADECTL`, `XREFNOTIFY`, `XLOADCTL`) work through `getvar`/`setvar`, and `(tblsearch "BLOCK" name)` returns an xref's saved path (group 1) and flags (group 70).

Runnable examples live in `Engine/EngineAsBuilt/Tools/lisp/examples/` (`SHAPES`, `SELCOUNT`, `REDCIRCLES`, `INPUTDEMO`) — `LOAD` one and run its command. Each is executed by `LispExamplesTests`, so they double as compatibility checks. Loaded `c:` routines stay resident for the session and run by bare name (built-ins win on collision); `setq` globals persist across `EVAL` runs too.

The ribbon and its classic menu bar are also AutoLISP-defined (`lisp/ribbon.lsp`) — see [Customizing the ribbon](#customizing-the-ribbon); that is a declarative layout document, not a dialog toolkit.

Not yet supported (Tier 2, clean errors for now): DCL dialogs, reactors, the rest of the `vla-*`/`vlax-*` object model beyond `vl-load-com`, `vlax-ename->vla-object`, `vla-getboundingbox`, and `vlax-safearray->list`, and ARX/VLX/VBA application loading. Out-of-process COM interop (foreign ActiveX servers, type-library import) is Windows-only and not planned.

### UI
- **Command palette** — Type any letter to open, Tab-cycle through fuzzy-matched autocomplete. Space repeats the last command (AutoCAD-style). 100+ registered commands with descriptions and syntax hints.
- **Multi-drawing tabs, OS float windows, and split panes** — Reorder tabs, dock drawings side-by-side, or move a drawing to another monitor. Dirty-state tracking and unsaved-changes confirmation apply across windows. See “Tabs, Windows & Split Views” above.
- **Draw palette** — Visual tool picker with categorized commands.
- **Layer panel** — Visibility toggles, color swatches, opacity sliders, entity counts.
- **Properties panel** — Per-entity property editing with geometry inspector.
- **Block panel** — Block library with preview and insert.
- **External References palette** — One list for drawing xrefs, images, and PDF underlays: status, saved vs found-at path, size/date, and Load/Unload/Reload/Repath/Detach/Bind/Embed actions. Toggle with `XREF`.
- **Radial navigation** — Right-click radial menu for pan, zoom, fit (`NAV` to toggle).
- **Text editor** — Modal dialog for text creation/editing with font selection, height, rotation, alignment, and MTEXT width.
- **Ribbon** — Tabs (Home, Insert, Annotate, View, Manage, Output, Custom) of panels with buttons, flyouts and live state: items grey out when the command cannot run (nothing selected, nothing to undo) and toggles like Grid/Ortho show their current state from the drawing's system variables. One control cycles the presentation: `File / Edit / View …` menu bar → labels-only ribbon → icons + labels. Dock it anywhere like the other panels — a docked ribbon shrinks to the active presentation so the canvas takes the space back — `RIBBON` toggles it and the layout persists.

#### Customizing the ribbon

`lisp/ribbon.lsp` defines the whole command chrome — tabs, panels, items, their order, labels, icons, tooltips and when they enable. It is created from the bundled default on first run at `Zephyr/lisp/ribbon.lsp` inside the app-data directory (`%LOCALAPPDATA%` on Windows, `~/Library/Application Support` on macOS), and reloads itself about a second after you save, or immediately with `RIBBONRELOAD`.

```lisp
(defun zephyr-ribbon ()
  (zr-ribbon
    (zr-menubar
      (list (zr-menu "File"
              (list (zr-item "NEW" "New" nil)
                    (zr-item "OPEN" "Open..." nil)))))
    (zr-tabs
      (list (zr-tab "Home"
              (list (zr-panel "Draw"
                      (list (zr-big   "LINE"   "Line"   "line" nil)
                            (zr-small "CIRCLE" "Circle" "circle"
                              (list (zr-enable (zr-sel 1))))))))))))
```

Any registered command can be used, including your own `c:` routines (`(zr-big "MYTOOL" "My Tool" nil nil)`). Items can be enabled/checked from declarative predicates — `(zr-sel n)`, `(zr-nocmd)`, `(zr-cmd "TRIM")`, `(zr-undoable)`, `(zr-redoable)`, `(zr-dirty)`, `(zr-var "GRIDMODE" 1)`, `(zr-tabcount n)` — and labels interpolate system variables (`"Layer: %CLAYER%"`). The shipped file documents every helper at the top; a broken definition leaves the previous one live and prints the error.
- **Status bar** — Coordinates, snap mode indicators, entity count, undo/redo depth, and an `XREF ⚠` warning when a reference is missing or needs reloading.

### Rendering Engine
- **Metal** (macOS), **Direct3D 12** (Windows), and **Vulkan** (Linux) via SDL3 GPU API
- **Multi-sample anti-aliasing** (MSAA)
- **GPU-based entity picking** — 9×9 pixel-perfect ID rendering
- **BVH spatial index** — Accelerated hit testing and viewport culling

### Display & Theme
- **Dark/Light theme** toggle (`THEME` command, or the View ribbon's Display panel).
- **Background color** — settable via `SET-BACKGROUND <hex|ACI>`.
- **Auto-contrast toggle** — `AUTOCONTRAST [ON/OFF]` toggles viewport auto-contrast clamping for 24-bit TrueColors and gradient fills while preserving contrast adjustment for standard ACI 1–255 colors (persisted per document in `.eab`).
- **Display palette generation counter** ensures line colors update immediately on background/theme change without requiring a zoom.
- **Anti-aliased line rendering** toggle (`AALINES`/`AA`).
- **FPS counter** (`FPS` toggle, shown in titlebar).

### Grid
- Configurable grid with `GRID`, `GRID SPACING <value>`, `GRID ORIGIN <x> <y>`, `GRID SNAP` commands.

### Document Settings

| Command | Alias | Description |
|---|---|---|
| UNITS | `UNIT`, `DDUNITS` | Set or display the drawing base unit (mm, cm, m, in, ft, yd). Flows through to PDF `/Measure` dictionary for Bluebeam Revu, DXF `$INSUNITS`, and EAB file header. |
| SETUISCALE | `ZOOMUI`, `UISCALE` | Override UI zoom scale (e.g. `SETUISCALE 1.5` for 150%). `SETUISCALE AUTO` reverts to system DPI. Scales all UI elements including fonts. |
| STYLE | `ST` | Create, edit, and manage text styles (font file, height, width, oblique) |
| OFFSETGAPTYPE | | Polyline offset corner style for `OFFSET`: `0` extend (sharp corners), `1` fillet (arc radius = offset distance), `2` chamfer |
| LANGUAGE | `LANG` | Set the UI font glyph profile without translating UI text (e.g. `LANGUAGE cjk` for Chinese/Japanese/Korean glyphs) |

## Roadmap

Features planned or in active development to be programmed:

- **Parametric Constraints & Numerical Solver** — 15 geometric and dimensional constraint types (coincident, parallel, perpendicular, tangent, concentric, horizontal, vertical, equal, distance, angle, fix, midpoint, collinear, symmetric, offset). Core data models (`CADConstraint`) and `.eab` file serialization are implemented; the numerical constraint solver, interactive commands (`GEOMCONSTRAINT`, `DIMCONSTRAINT`, `PARAMETRIC`), and constraint indicator glyphs are to be programmed.
- **In-Place Reference Editing (`REFEDIT`)** — In-place editing of referenced drawings and blocks.
- **Underlay Enhancements** — Rendering support for DWF/DGN underlays and on-zoom vector re-rendering for PDF attachments.
- **Extended AutoLISP (Tier 2) — DCL Dialogs** — `.dcl` parsing plus `load_dialog`/`new_dialog`/`action_tile`/`start_dialog`/`done_dialog`, rendered through the existing ImGui layer. No COM dependency, so this is fully cross-platform.
- **Extended AutoLISP (Tier 2) — Reactors** — `vlr-object-reactor`, `vlr-command-reactor`, `vlr-editor-reactor`, and their callback plumbing, driven by the editor's own event stream. Also fully cross-platform.
- **Extended AutoLISP (Tier 2) — VLA/VLAX Object Model** — the `vla-get-*`/`vla-put-*`/`vla-*` method and property surface, plus safearrays and variants, backed by a native descriptor table over Zephyr's own objects (the same approach BricsCAD ships as "Fast-COM"), not by COM. Literal ActiveX/COM interop — `vlax-create-object` against foreign servers, `vlax-import-type-library`, third-party ActiveX controls, VBA/VLX hosting — is Windows-only by nature and out of scope.
- **Native DWG I/O** — An in-process Swift DWG reader/writer to replace the ODA FileConverter CLI bridge (`Sources/ZephyrCore/IO/ODADWGConverter.swift`) and retire `INSTALLODA`. A host-side external binary cannot exist on Web, iOS, or Android, so this is the blocker for DWG on those targets — and on desktop it drops an out-of-process round-trip per open and save.
- **Web** — Browser build via the SDL3 SDL_GPU WebGPU backend, currently an open upstream PR ([libsdl-org/SDL#16020](https://github.com/libsdl-org/SDL/pull/16020)). Web lands when that backend does.
- **iOS and Android** — Additional targets in the same SDL3/Swift pipeline, independent of the web work: Metal on iOS and Vulkan on Android already ship in SDL_GPU, so the remaining work is platform shell — touch and pen input mapping, on-device document access and packaging, and mobile-appropriate UI density.

## Nightly Builds

Same links as above — updated on every push.

| Platform | Architecture | Download |
|---|---|---|
| macOS | Universal (Apple Silicon & Intel) | [Zephyr-macOS-Universal.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-macOS-Universal.zip) |
| Windows | ARM64 | [Zephyr-Windows-arm64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Windows-arm64.zip) |
| Windows | x64 | [Zephyr-Windows-x64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Windows-x64.zip) |
| Linux (AppImage) | x64 | [Zephyr-Linux-x64.AppImage](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-x64.AppImage) |
| Linux (AppImage) | ARM64 | [Zephyr-Linux-arm64.AppImage](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-arm64.AppImage) |
| Linux (Flatpak) | x64 | [Zephyr-Linux-x64.flatpak](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-x64.flatpak) |
| Linux (Flatpak) | ARM64 | [Zephyr-Linux-arm64.flatpak](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-arm64.flatpak) |
| Linux (Portable ZIP, glibc 2.35+) | x64 | [Zephyr-Linux-x64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-x64.zip) |
| Linux (Portable ZIP, glibc 2.35+) | ARM64 | [Zephyr-Linux-arm64.zip](https://github.com/joseph-montanez/zephyr/releases/download/nightly/Zephyr-Linux-arm64.zip) |
| Linux (Snap) | x64 | [zephyr_1.0_amd64.snap](https://github.com/joseph-montanez/zephyr/releases/download/nightly/zephyr_1.0_amd64.snap) |
| Linux (Snap) | ARM64 | [zephyr_1.0_arm64.snap](https://github.com/joseph-montanez/zephyr/releases/download/nightly/zephyr_1.0_arm64.snap) |

## Quick Start

```bash
# macOS
cd Engine/EngineAsBuilt
sh compile-macos.sh

# Windows (ARM64, via Visual Studio Native Tools)
cd Engine\EngineAsBuilt
.\compile.ps1

# Linux (first run ./setup-linux.sh from the repo root for dependencies)
cd Engine/EngineAsBuilt
./compile-linux.sh
```

---

[Development Setup](DEVELOPMENT.md) · [Issues](https://github.com/joseph-montanez/as-built/issues)
