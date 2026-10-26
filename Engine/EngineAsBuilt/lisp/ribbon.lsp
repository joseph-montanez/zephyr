;;; =====================================================================
;;; ribbon.lsp - Zephyr ribbon and menu bar definition
;;; =====================================================================
;;;
;;; This file IS the ribbon. Edit it, save, and the ribbon reloads itself
;;; (it also reloads on RIBBONRELOAD, or the Reload button in the ribbon).
;;; Nothing here needs a rebuild.
;;;
;;; Three presentations share this one definition - click the button at the
;;; right end of the ribbon to cycle:
;;;   1. menu    - the classic File / Edit / View menu bar below
;;;   2. labels  - ribbon panels, text buttons only
;;;   3. icons   - ribbon panels, icons + labels
;;;
;;; The file must define (zephyr-ribbon), which returns:
;;;   (zr-ribbon <menubar or nil> <tabs or nil>)
;;;
;;; Helpers (all take a fixed argument list; pass nil for "none"):
;;;   (zr-menubar menus) (zr-tabs tabs) (zr-menu title items)
;;;   (zr-tab title panels) (zr-panel title items)
;;;   (zr-big cmd label icon opts)     large ribbon button (icon + label)
;;;   (zr-small cmd label icon opts)   small ribbon button
;;;   (zr-item cmd label opts)         menu entry (no icon)
;;;   (zr-drop label items)            ribbon flyout
;;;   (zr-sub title items)             menu submenu
;;;   (zr-sep)
;;;
;;; Options - pass a (list ...) of these, or nil:
;;;   (zr-enable pred)  greyed out unless pred holds
;;;   (zr-check pred)   drawn pressed while pred holds
;;;   (zr-tip "text")   tooltip
;;;
;;; Predicates - inside zr-enable / zr-check:
;;;   (zr-sel n)              at least n entities selected
;;;   (zr-nocmd)              no command running
;;;   (zr-cmd "TRIM")         that command is running
;;;   (zr-undoable) (zr-redoable) (zr-dirty)
;;;   (zr-var "GRIDMODE" 1)   system variable equals a value
;;;   (zr-tabcount n)         at least n drawings open
;;;
;;; Labels may interpolate system variables: "Layer: %CLAYER%", "%GRIDMODE%".
;;; Icon names come from the built-in painter set (line, circle, move, trim,
;;; layers, ...); nil derives the icon from the command name, and an unknown
;;; name draws a letter box instead of an empty button.
;;;
;;; Any command that exists can be used - including your own c: routines:
;;;   (zr-big "MYTOOL" "My Tool" nil nil)
;;;
;;; =====================================================================

(defun zephyr-ribbon ()
  (zr-ribbon
    (menubar)
    (tabs)))


;;; ---------------------------------------------------------------------
;;; Classic menu bar (shown in "menu" display mode)
;;; ---------------------------------------------------------------------
(defun menubar ()
  (zr-menubar
    (list

      (zr-menu "File"
        (list
          (zr-item "NEW" "New" nil)
          (zr-item "OPEN" "Open..." nil)
          (zr-sep)
          (zr-item "SAVE" "Save" nil)
          (zr-item "SAVEAS" "Save As..." nil)
          (zr-sep)
          (zr-sub "Export"
            (list
              (zr-item "PDFEXPORT" "PDF..." nil)))
          (zr-sep)
          (zr-item "CLOSE" "Close Drawing" nil)
          (zr-sep)
          (zr-item "TABWINDOW" "Float This Drawing" nil)
          (zr-item "TABDOCK" "Dock This Drawing" nil)
          (zr-sep)
          (zr-item "FILETAB" "Show File Tabs" nil)
          (zr-item "FILETABCLOSE" "Hide File Tabs" nil)))

      (zr-menu "Edit"
        (list
          (zr-item "UNDO" "Undo" (list (zr-enable (zr-undoable))))
          (zr-item "REDO" "Redo" (list (zr-enable (zr-redoable))))
          (zr-sep)
          (zr-item "ERASE" "Erase" nil)
          (zr-sub "Clipboard"
            (list
              (zr-item "COPYCLIP" "Copy" nil)
              (zr-item "PASTECLIP" "Paste" nil)
              (zr-item "PASTEORIG" "Paste to Original Coordinates" nil)))
          (zr-sep)
          (zr-item "MATCHPROP" "Match Properties" (list (zr-enable (zr-sel 1))))))

      (zr-menu "View"
        (list
          (zr-item "ZOOMEXTENTS" "Zoom Extents" nil)
          (zr-item "ZOOM" "Zoom" nil)
          (zr-item "PAN" "Pan" nil)
          (zr-item "PLAN" "Plan View" nil)
          (zr-sep)
          (zr-sub "Viewports"
            (list
              (zr-item "VPORTS" "Viewport Setup" nil)
              (zr-item "VSPLIT" "Split Side by Side" nil)
              (zr-item "HSPLIT" "Split Stacked" nil)
              (zr-item "UNSPLIT" "Remove Splits" nil)
              (zr-item "VPMAX" "Maximize Pane" nil)
              (zr-item "VPMIN" "Restore Panes" nil)
              (zr-item "VPEQUAL" "Equalize Panes" nil)))
          (zr-sep)
          (zr-sub "Display"
            (list
              (zr-item "GRID" "Grid" (list (zr-check (zr-var "GRIDMODE" 1))))
              (zr-item "ORTHO" "Ortho" (list (zr-check (zr-var "ORTHOMODE" 1))))
              (zr-item "POLAR" "Polar Tracking" (list (zr-check (zr-var "POLARMODE" 1))))
              (zr-item "AALINES" "Anti-aliased Lines" nil)
              (zr-item "THEME" "Theme" nil)
              (zr-item "FPS" "FPS Counter" nil)
              (zr-item "NAV" "Radial Navigation" nil)))
          (zr-sep)
          (zr-item "PROPS" "Properties Panel" nil)
          (zr-item "LAYER" "Layers Panel" nil)))

      (zr-menu "Insert"
        (list
          (zr-item "INSERT" "Insert Block" nil)
          (zr-item "BLOCK" "Create Block" (list (zr-enable (zr-sel 1))))
          (zr-item "BEDIT" "Block Editor" nil)
          (zr-item "BLOCKS" "Blocks Panel" nil)
          (zr-sep)
          (zr-item "XREF" "External References" nil)
          (zr-item "XATTACH" "Attach Drawing (Xref)" nil)
          (zr-item "IMAGEATTACH" "Attach Image" nil)
          (zr-item "PDFATTACH" "Attach PDF" nil)
          (zr-item "CLIP" "Clip Reference" (list (zr-enable (zr-sel 1))))
          (zr-sep)
          (zr-item "TABLE" "Insert Table" nil)))

      (zr-menu "Format"
        (list
          (zr-item "UNITS" "Drawing Units" nil)
          (zr-item "STYLE" "Text Style" nil)
          (zr-item "MLEADERSTYLE" "Leader Style" nil)
          (zr-sep)
          (zr-item "DXFVERSION" "DXF Version" nil)
          (zr-item "SET-BACKGROUND" "Background Colour" nil)
          (zr-item "LANGUAGE" "Font Language Profile" nil)
          (zr-item "SETUISCALE" "UI Scale" nil)))

      (zr-menu "Draw"
        (list
          (zr-item "LINE" "Line" nil)
          (zr-item "POLYLINE" "Polyline" nil)
          (zr-item "CIRCLE" "Circle" nil)
          (zr-item "ARC" "Arc" nil)
          (zr-item "RECTANGLE" "Rectangle" nil)
          (zr-item "ELLIPSE" "Ellipse" nil)
          (zr-item "HATCH" "Hatch" nil)
          (zr-item "SPLINE" "Spline" nil)
          (zr-item "PENSTROKE" "Pen Stroke" nil)
          (zr-item "RAY" "Ray" nil)
          (zr-item "XLINE" "Construction Line" nil)
          (zr-item "POLYGON" "Polygon" nil)
          (zr-item "BOUNDARY" "Boundary" nil)
          (zr-item "POINT" "Point" nil)
          (zr-item "DONUT" "Donut" nil)
          (zr-sep)
          (zr-item "TEXT" "Single Line Text" nil)
          (zr-item "TABLE" "Table" nil)
          (zr-item "REVCLOUD" "Revision Cloud" nil)
          (zr-sep)
          (zr-sub "Dimensions"
            (list
              (zr-item "DIMLINEAR" "Linear" nil)
              (zr-item "DIMALIGNED" "Aligned" nil)
              (zr-item "DIMANGULAR" "Angular" nil)
              (zr-item "DIMRADIUS" "Radius" nil)
              (zr-item "DIMDIAMETER" "Diameter" nil)
              (zr-item "DIMARC" "Arc Length" nil)
              (zr-item "DIMORDINATE" "Ordinate" nil)
              (zr-item "DIMJOGGED" "Jogged" nil)))
          (zr-sub "Leaders"
            (list
              (zr-item "MLEADER" "Multileader" nil)
              (zr-item "QLEADER" "Quick Leader" nil)
              (zr-item "LEADER" "Leader" nil)))))

      (zr-menu "Modify"
        (list
          (zr-item "MOVE" "Move" nil)
          (zr-item "COPY" "Copy" nil)
          (zr-item "ROTATE" "Rotate" nil)
          (zr-item "SCALE" "Scale" nil)
          (zr-item "ALIGN" "Align" nil)
          (zr-item "ERASE" "Erase" nil)
          (zr-sep)
          (zr-item "TRIM" "Trim" nil)
          (zr-item "OFFSET" "Offset" nil)
          (zr-item "FILLET" "Fillet" nil)
          (zr-item "CHAMFER" "Chamfer" nil)
          (zr-item "JOIN" "Join" (list (zr-enable (zr-sel 1))))
          (zr-item "EXPLODE" "Explode" nil)
          (zr-item "MATCHPROP" "Match Properties" (list (zr-enable (zr-sel 1))))
          (zr-item "TORIENT" "Text Orient" (list (zr-enable (zr-sel 1))))
          (zr-sep)
          (zr-sub "Array"
            (list
              (zr-item "ARRAY" "Array" nil)
              (zr-item "ARRAYRECT" "Rectangular" nil)
              (zr-item "ARRAYPOLAR" "Polar" nil)
              (zr-item "ARRAYPATH" "Path" nil)
              (zr-item "ARRAYEDIT" "Edit Array" nil)
              (zr-item "ARRAYCLOSE" "Close Array" nil)))))

      (zr-menu "Tools"
        (list
          (zr-item "LAYER" "Layers" nil)
          (zr-item "LAYERSORT" "Sort Layers" nil)
          (zr-item "LAYERMOVE" "Move to Layer" (list (zr-enable (zr-sel 1))))
          (zr-item "LAYMCH" "Change to Layer" (list (zr-enable (zr-sel 1))))
          (zr-item "LAYMCUR" "Make Layer Current" nil)
          (zr-item "LAYISO" "Isolate Layer" nil)
          (zr-item "LAYUNISO" "Restore Layers" nil)
          (zr-item "LAYOFF" "Turn Layer Off" nil)
          (zr-item "LAYON" "Turn Layer On" nil)
          (zr-sep)
          (zr-sub "AutoLISP"
            (list
              (zr-item "LOAD" "Load LISP File..." nil)
              (zr-item "EVAL" "Evaluate Expression..." nil)
              (zr-item "SCRIPT" "Run Script..." nil)))
          (zr-sep)
          (zr-item "INSTALLODA" "Install DWG Converter" nil)
          (zr-sep)
          (zr-sub "Ribbon"
            (list
              (zr-item "RIBBONRELOAD" "Reload Definition" nil)
              (zr-item "RIBBONMODE" "Cycle Display Mode" nil)
              (zr-item "RIBBON" "Show / Hide Ribbon" nil))))))))


;;; ---------------------------------------------------------------------
;;; Ribbon tabs (shown in "labels" and "icons" display modes)
;;; ---------------------------------------------------------------------
(defun tabs ()
  (zr-tabs
    (list

      ;; =================================================================
      (zr-tab "Home"
        (list
          (zr-panel "Draw"
            (list
              (zr-big   "LINE"      "Line"     "line"     nil)
              (zr-big   "POLYLINE"  "Polyline" "polyline" nil)
              (zr-small "CIRCLE"    "Circle"   "circle"   nil)
              (zr-small "ARC"       "Arc"      "arc"      nil)
              (zr-small "RECTANGLE" "Rectangle" "rect"    nil)
              (zr-drop  "More"
                (list
                  (zr-item "ELLIPSE"   "Ellipse"    nil)
                  (zr-item "HATCH"     "Hatch"      nil)
                  (zr-item "SPLINE"    "Spline"     nil)
                  (zr-item "PENSTROKE" "Pen Stroke" nil)
                  (zr-item "RAY"       "Ray"        nil)
                  (zr-item "XLINE"     "Xline"      nil)
                  (zr-item "POLYGON"   "Polygon"    nil)
                  (zr-item "BOUNDARY"  "Boundary"   nil)
                  (zr-item "POINT"     "Point"      nil)
                  (zr-item "DONUT"     "Donut"      nil)))))

          (zr-panel "Modify"
            (list
              (zr-big   "MOVE"    "Move"   "move"   nil)
              (zr-big   "ERASE"   "Erase"  "erase"  nil)
              (zr-small "COPY"    "Copy"   "copy"   nil)
              (zr-small "ROTATE"  "Rotate" "rotate" nil)
              (zr-small "SCALE"   "Scale"  "scale"  nil)
              (zr-drop  "More"
                (list
                  (zr-item "TRIM"      "Trim"       nil)
                  (zr-item "OFFSET"    "Offset"     nil)
                  (zr-item "FILLET"    "Fillet"     nil)
                  (zr-item "CHAMFER"   "Chamfer"    nil)
                  (zr-item "ARRAY"     "Array"      nil)
                  (zr-item "EXPLODE"   "Explode"    nil)
                  (zr-item "JOIN"      "Join"       nil)
                  (zr-item "MATCHPROP" "Match Props" nil)
                  (zr-item "ALIGN"     "Align"      nil)))))

          (zr-panel "Layers"
            (list
              (zr-big   "LAYER" "Layers"          "layers"    nil)
              (zr-small "LA"    "Layer: %CLAYER%" "layer-cur" nil)))

          (zr-panel "Blocks"
            (list
              (zr-big   "BLOCKS" "Blocks" "block"  nil)
              (zr-big   "INSERT" "Insert" "insert" nil)
              (zr-small "BEDIT"  "Edit"   "block"  nil)))

          (zr-panel "Status"
            (list
              (zr-small "GRID"  "Grid: %GRIDMODE%"   "grid"
                (list (zr-check (zr-var "GRIDMODE" 1))))
              (zr-small "ORTHO" "Ortho: %ORTHOMODE%" "ortho"
                (list (zr-check (zr-var "ORTHOMODE" 1))))
              (zr-small "POLAR" "Polar: %POLARMODE%" "polar"
                (list (zr-check (zr-var "POLARMODE" 1))))))))

      ;; =================================================================
      (zr-tab "Insert"
        (list
          (zr-panel "Block"
            (list
              (zr-big   "INSERT" "Insert"  "insert" nil)
              (zr-big   "BLOCK"  "Create"  "block"  (list (zr-enable (zr-sel 1))))
              (zr-small "BEDIT"  "Editor"  "block"  nil)
              (zr-small "BLOCKS" "Panel"   "block"  nil)))

          (zr-panel "Reference"
            (list
              (zr-big   "XREF"        "Xrefs"   "xref"  nil)
              (zr-big   "XATTACH"     "Attach"  "xref"  nil)
              (zr-small "IMAGEATTACH" "Image"   "image" nil)
              (zr-small "PDFATTACH"   "PDF"     "pdf"   nil)
              (zr-small "CLIP"        "Clip"    "xref"
                (list (zr-enable (zr-sel 1))))))

          (zr-panel "Data"
            (list
              (zr-big   "TABLE" "Table"   "table" nil)
              (zr-small "PROPS" "Properties" "props" nil)))))

      ;; =================================================================
      (zr-tab "Annotate"
        (list
          (zr-panel "Text"
            (list
              (zr-big   "TEXT"   "Text"   "text"  nil)
              (zr-small "DDEDIT" "Edit"   "text"  (list (zr-enable (zr-sel 1))))
              (zr-small "STYLE"  "Styles" "style" nil)))

          (zr-panel "Dimensions"
            (list
              (zr-big   "DIMLINEAR"  "Linear"  "dim" nil)
              (zr-small "DIMALIGNED" "Aligned" "dim" nil)
              (zr-small "DIMANGULAR" "Angular" "dim" nil)
              (zr-small "DIMRADIUS"  "Radius"  "dim" nil)
              (zr-drop  "More"
                (list
                  (zr-small "DIMDIAMETER" "Diameter"   "dim"   nil)
                  (zr-item "DIMARC"      "Arc Length" nil)
                  (zr-item "DIMORDINATE" "Ordinate"   nil)
                  (zr-item "DIMJOGGED"   "Jogged"     nil)))))

          (zr-panel "Leaders"
            (list
              (zr-big   "MLEADER"      "Multileader" "leader" nil)
              (zr-small "QLEADER"      "Quick"       "leader" nil)
              (zr-small "LEADER"       "Leader"      "leader" nil)
              (zr-small "MLEADERSTYLE" "Style"       "leader" nil)))

          (zr-panel "Measure"
            (list
              (zr-big   "MEASUREGEOM" "Measure" "measure" nil)
              (zr-small "MEASURE"     "Divide"  "measure" nil)
              (zr-small "DIVIDE"      "Points"  "measure" nil)
              (zr-small "DIST"        "Distance" "measure" nil)
              (zr-small "AREA"        "Area"     "measure" nil)
              (zr-small "LIST"        "List"     "measure" nil)
              (zr-small "ID"          "Locate Pt" "measure" nil)))))

      ;; =================================================================
      (zr-tab "View"
        (list
          (zr-panel "Navigate"
            (list
              (zr-big   "ZOOMEXTENTS" "Extents" "zoom" nil)
              (zr-small "ZOOM"        "Zoom"    "zoom" nil)
              (zr-small "PAN"         "Pan"     "pan"  nil)
              (zr-small "PLAN"        "Plan"    "view" nil)))

          (zr-panel "Windows"
            (list
              (zr-big   "VPORTS" "Viewports" "vport" nil)
              (zr-small "VSPLIT" "Split V"   "vport" nil)
              (zr-small "HSPLIT" "Split H"   "vport" nil)
              (zr-small "UNSPLIT" "Unsplit"  "vport" nil)
              (zr-drop  "More"
                (list
                  (zr-small "VPMAX"     "Maximize Pane" "vport" nil)
                  (zr-item "VPMIN"     "Restore Panes" nil)
                  (zr-item "VPEQUAL"   "Equalize Panes" nil)
                  (zr-item "CLOSEPANE" "Close Pane"    nil)))))

          (zr-panel "Display"
            (list
              (zr-small "GRID"  "Grid: %GRIDMODE%" "grid"
                (list (zr-check (zr-var "GRIDMODE" 1))))
              (zr-small "ORTHO" "Ortho: %ORTHOMODE%" "ortho"
                (list (zr-check (zr-var "ORTHOMODE" 1))))
              (zr-small "AALINES" "Smooth Lines" "theme" nil)
              (zr-small "THEME"   "Theme"        "theme" nil)
              (zr-drop  "More"
                (list
                  (zr-small "FPS"   "FPS Counter"       "props" nil)
                  (zr-item "NAV"   "Radial Navigation" nil)
                  (zr-item "PROPS" "Properties Panel"  nil)))))

          (zr-panel "File Tabs"
            (list
              (zr-small "FILETAB"      "Show File Tabs" "view" nil)
              (zr-small "FILETABCLOSE" "Hide File Tabs" "view" nil)
              (zr-small "TABWINDOW"    "Float Drawing"  "view" nil)
              (zr-small "TABDOCK"      "Dock Drawing"   "view" nil)))))

      ;; =================================================================
      (zr-tab "Manage"
        (list
          (zr-panel "Drawing"
            (list
              (zr-big   "UNITS"     "Units" "units" nil)
              (zr-small "DXFVERSION" "DXF Version" "save" nil)
              (zr-small "SET-BACKGROUND" "Background" "theme" nil)))

          (zr-panel "Styles"
            (list
              (zr-small "STYLE"        "Text Style"   "style"  nil)
              (zr-small "MLEADERSTYLE" "Leader Style" "leader" nil)
              (zr-small "SPLINETESS"   "Spline Detail" "spline" nil)))

          (zr-panel "AutoLISP"
            (list
              (zr-big   "LOAD"   "Load"   "open"  nil)
              (zr-small "EVAL"   "Eval"   "props" nil)
              (zr-small "SCRIPT" "Script" "print" nil)))

          (zr-panel "Ribbon"
            (list
              (zr-big   "RIBBONRELOAD" "Reload" "reload" nil)
              (zr-small "RIBBONMODE"   "Display Mode" "theme" nil)))))

      ;; =================================================================
      (zr-tab "Output"
        (list
          (zr-panel "PDF"
            (list
              (zr-big   "PDFEXPORT" "Export PDF" "pdf" nil)
              (zr-small "PDFIMPORT" "Import PDF" "pdf" nil)
              (zr-small "PDFATTACH" "Attach PDF" "pdf" nil)))

          (zr-panel "System"
            (list
              (zr-small "SETUISCALE"  "UI Scale"  "zoom"  nil)
              (zr-small "LANGUAGE"    "Language"  "style" nil)
              (zr-small "INSTALLODA"  "DWG Converter" "save" nil)))))

      ;; =================================================================
      ;; Add your own commands here - anything registered (including your
      ;; own c: routines) can go on a ribbon button.
      (zr-tab "Custom"
        (list
          (zr-panel "Custom"
            (list
              (zr-big   "RIBBONRELOAD" "Reload Definition" "reload" nil)
              (zr-small "DRAW"         "Draw Palette"      "line"   nil))))))))
