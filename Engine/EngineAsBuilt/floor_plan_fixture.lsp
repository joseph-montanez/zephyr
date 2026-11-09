;;; ============================================================
;;; Multi-room architectural floor plan test fixture
;;; Generated entirely with entmake (layers via -LAYER command,
;;; which is the supported table-creation path in this engine).
;;;
;;; Building: 120 x 80 overall (outer faces), origin at SW corner.
;;; Exterior walls: 8 units thick (double line + ANSI31 hatch).
;;; Interior walls: 5 units thick (double line + ANSI31 hatch).
;;;
;;; Layout (clear interior faces):
;;;   LIVING ROOM  x 8..62    y 8..33    (54 x 25)
;;;   BEDROOM      x 67..112  y 8..33    (45 x 25)
;;;   HALLWAY      x 8..112   y 38..48   (104 x 10)
;;;   KITCHEN      x 8..70    y 53..72   (62 x 19)
;;;   BATHROOM     x 75..112  y 53..72   (37 x 19)
;;; Interior walls:
;;;   south hallway wall  y 33..38, x 8..112 (doors at 25..35, 80..90)
;;;   north hallway wall  y 48..53, x 8..112 (doors at 25..35, 85..95)
;;;   south vertical      x 62..67, y 8..33
;;;   north vertical      x 70..75, y 53..72
;;; ============================================================

;; ---- helpers -------------------------------------------------
(defun ln (lay x1 y1 x2 y2)
  (entmake (list '(0 . "LINE") (cons 8 lay)
                 (list 10 x1 y1 0.0) (list 11 x2 y2 0.0))))

(defun hatchrect (x1 y1 x2 y2)
  (entmake (list '(0 . "HATCH") '(8 . "HATCH") '(2 . "ANSI31")
                 '(70 . 0) '(41 . 2.0) '(52 . 0.0)
                 (list 10 x1 y1 0.0) (list 10 x2 y1 0.0)
                 (list 10 x2 y2 0.0) (list 10 x1 y2 0.0))))

;; Horizontal double-line wall segment: x xa..xb between faces y1..y2
(defun wallh (xa xb y1 y2)
  (ln "WALLS" xa y1 xb y1)
  (ln "WALLS" xa y2 xb y2)
  (ln "WALLS" xa y1 xa y2)   ; end cap / jamb
  (ln "WALLS" xb y1 xb y2)   ; end cap / jamb
  (hatchrect xa y1 xb y2))

;; Vertical double-line wall segment: y ya..yb between faces x1..x2
(defun wallv (ya yb x1 x2)
  (ln "WALLS" x1 ya x1 yb)
  (ln "WALLS" x2 ya x2 yb)
  (ln "WALLS" x1 ya x2 ya)   ; end cap / jamb
  (ln "WALLS" x1 yb x2 yb)   ; end cap / jamb
  (hatchrect x1 ya x2 yb))

;; Door: panel LINE (open position) + 90-degree swing ARC, DOORS layer
(defun door (hx hy px py r a1 a2)
  (ln "DOORS" hx hy px py)
  (entmake (list '(0 . "ARC") '(8 . "DOORS")
                 (list 10 hx hy 0.0) (cons 40 r)
                 (cons 50 a1) (cons 51 a2))))

;; Window in a horizontal wall: 2 jamb lines + 3 glass lines
(defun winh (xa xb y1 y2 / yc)
  (setq yc (/ (+ y1 y2) 2.0))
  (ln "WINDOWS" xa y1 xa y2)
  (ln "WINDOWS" xb y1 xb y2)
  (ln "WINDOWS" xa yc xb yc)
  (ln "WINDOWS" xa (+ y1 2.0) xb (+ y1 2.0))
  (ln "WINDOWS" xa (- y2 2.0) xb (- y2 2.0)))

;; Window in a vertical wall: 2 jamb lines + 3 glass lines
(defun winv (ya yb x1 x2 / xc)
  (setq xc (/ (+ x1 x2) 2.0))
  (ln "WINDOWS" x1 ya x2 ya)
  (ln "WINDOWS" x1 yb x2 yb)
  (ln "WINDOWS" xc ya xc yb)
  (ln "WINDOWS" (+ x1 2.0) ya (+ x1 2.0) yb)
  (ln "WINDOWS" (- x2 2.0) ya (- x2 2.0) yb))

;; Centered two-line room label (name + nominal size)
(defun roomlabel (cx cy hgt nm sz)
  (entmake (list '(0 . "TEXT") '(8 . "ROOM_LABELS")
                 (list 10 cx (+ cy (* hgt 0.75)) 0.0) (cons 40 hgt)
                 (cons 1 nm) '(71 . 0) '(72 . 1) '(73 . 2) '(50 . 0.0)
                 (list 11 cx (+ cy (* hgt 0.75)) 0.0)))
  (entmake (list '(0 . "TEXT") '(8 . "ROOM_LABELS")
                 (list 10 cx (- cy (* hgt 0.75)) 0.0) (cons 40 (* hgt 0.7))
                 (cons 1 sz) '(71 . 0) '(72 . 1) '(73 . 2) '(50 . 0.0)
                 (list 11 cx (- cy (* hgt 0.75)) 0.0))))

;; Horizontal linear DIMENSION
(defun dimh (x1 x2 yorig yline txt)
  (entmake (list '(0 . "DIMENSION") '(8 . "DIMENSIONS")
                 (list 10 x1 yline 0.0)
                 (list 11 (/ (+ x1 x2) 2.0) yline 0.0)
                 (list 13 x1 yorig 0.0) (list 14 x2 yorig 0.0)
                 '(70 . 32) '(50 . 0.0) (cons 1 txt))))

;; Vertical linear DIMENSION
(defun dimv (y1 y2 xorig xline txt)
  (entmake (list '(0 . "DIMENSION") '(8 . "DIMENSIONS")
                 (list 10 xline y1 0.0)
                 (list 11 xline (/ (+ y1 y2) 2.0) 0.0)
                 (list 13 xorig y1 0.0) (list 14 xorig y2 0.0)
                 '(70 . 32) '(50 . 90.0) (cons 1 txt))))

;; ---- clean slate + layers (idempotent) ------------------------
(defun mklayer (nm col)
  (if (tblsearch "LAYER" nm)
    (command "-LAYER" "C" col nm "")
    (command "-LAYER" "M" nm "C" col "" "")))
(command "ERASE" "ALL" "")
(mklayer "WALLS" "7")
(mklayer "HATCH" "9")
(mklayer "DOORS" "3")
(mklayer "WINDOWS" "4")
(mklayer "ROOM_LABELS" "2")
(mklayer "DIMENSIONS" "6")
(setvar "CLAYER" "WALLS")

;; ---- exterior walls (8 thick), segmented at openings ---------
;; South wall y 0..8 ; openings: win 15..27, main door 29..41,
;; win 45..57, win 80..92
(wallh 0.0 15.0 0.0 8.0)
(wallh 27.0 29.0 0.0 8.0)
(wallh 41.0 45.0 0.0 8.0)
(wallh 57.0 80.0 0.0 8.0)
(wallh 92.0 120.0 0.0 8.0)
;; North wall y 72..80 ; openings: win 20..35, win 45..57, win 88..100
(wallh 0.0 20.0 72.0 80.0)
(wallh 35.0 45.0 72.0 80.0)
(wallh 57.0 88.0 72.0 80.0)
(wallh 100.0 120.0 72.0 80.0)
;; West wall x 0..8, y 8..72 ; openings: win y 15..27, win y 58..68
(wallv 8.0 15.0 0.0 8.0)
(wallv 27.0 58.0 0.0 8.0)
(wallv 68.0 72.0 0.0 8.0)
;; East wall x 112..120, y 8..72 ; openings: win y 15..27, win y 58..66
(wallv 8.0 15.0 112.0 120.0)
(wallv 27.0 58.0 112.0 120.0)
(wallv 66.0 72.0 112.0 120.0)

;; ---- interior partition walls (5 thick) -----------------------
;; South hallway wall y 33..38 ; doors 25..35 (Living), 80..90 (Bedroom)
(wallh 8.0 25.0 33.0 38.0)
(wallh 35.0 80.0 33.0 38.0)
(wallh 90.0 112.0 33.0 38.0)
;; North hallway wall y 48..53 ; doors 25..35 (Kitchen), 85..95 (Bath)
(wallh 8.0 25.0 48.0 53.0)
(wallh 35.0 85.0 48.0 53.0)
(wallh 95.0 112.0 48.0 53.0)
;; South vertical x 62..67 (Living | Bedroom), no opening
(wallv 8.0 33.0 62.0 67.0)
;; North vertical x 70..75 (Kitchen | Bathroom), no opening
(wallv 53.0 72.0 70.0 75.0)

;; ---- doors (panel + 90 deg swing arc) -------------------------
;; NOTE: DXF group 50/51 (ARC start/end, rotations) are in DEGREES.
;; Main entrance, south wall 29..41 (w=12): hinge (29,8), opens N
(door 29.0 8.0 29.0 20.0 12.0 0.0 90.0)
;; Living Room from hall, 25..35: hinge (35,38), opens S into room
(door 35.0 38.0 35.0 28.0 10.0 180.0 270.0)
;; Bedroom from hall, 80..90: hinge (90,38), opens S into room
(door 90.0 38.0 90.0 28.0 10.0 180.0 270.0)
;; Kitchen from hall, 25..35: hinge (25,48), opens N into room
(door 25.0 48.0 25.0 58.0 10.0 0.0 90.0)
;; Bathroom from hall, 85..95: hinge (85,48), opens N into room
(door 85.0 48.0 85.0 58.0 10.0 0.0 90.0)

;; ---- windows (jambs + centerline glass) -----------------------
(winh 15.0 27.0 0.0 8.0)      ; south, Living
(winh 45.0 57.0 0.0 8.0)      ; south, Living
(winh 80.0 92.0 0.0 8.0)      ; south, Bedroom
(winh 20.0 35.0 72.0 80.0)    ; north, Kitchen
(winh 45.0 57.0 72.0 80.0)    ; north, Kitchen
(winh 88.0 100.0 72.0 80.0)   ; north, Bathroom
(winv 15.0 27.0 0.0 8.0)      ; west, Living
(winv 58.0 68.0 0.0 8.0)      ; west, Kitchen
(winv 15.0 27.0 112.0 120.0)  ; east, Bedroom
(winv 58.0 66.0 112.0 120.0)  ; east, Bathroom

;; ---- room labels (centered) -----------------------------------
(roomlabel 35.0 20.5 3.0 "LIVING ROOM" "54' x 25'")
(roomlabel 89.5 20.5 3.0 "BEDROOM" "45' x 25'")
(roomlabel 39.0 62.5 3.0 "KITCHEN" "62' x 19'")
(roomlabel 93.5 62.5 3.0 "BATHROOM" "37' x 19'")
(roomlabel 60.0 43.0 2.4 "HALLWAY" "104' x 10'")

;; ---- dimensions ------------------------------------------------
(dimh 0.0 120.0 0.0 -10.0 "120'-0\"")        ; overall width (south)
(dimv 0.0 80.0 120.0 130.0 "80'-0\"")        ; overall depth (east)
(dimh 8.0 62.0 8.0 29.0 "54'-0\"")           ; Living clear width
(dimh 67.0 112.0 8.0 29.0 "45'-0\"")         ; Bedroom clear width
(dimh 8.0 70.0 72.0 56.5 "62'-0\"")          ; Kitchen clear width
(dimh 75.0 112.0 72.0 56.5 "37'-0\"")        ; Bathroom clear width
(dimv 8.0 33.0 8.0 12.0 "25'-0\"")           ; Living clear depth

(setvar "CLAYER" "WALLS")
"floor-plan-fixture-done"
