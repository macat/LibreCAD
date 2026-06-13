;; librecad.pat — bundled hatch-pattern library for the LibreCAD macOS port.
;;
;; Standard AutoCAD-format `.pat` pattern definitions used by the hatch
;; pattern-line generator (CADEngine/HatchPattern.swift). Each pattern is a
;; header line `*NAME, description` followed by one or more pattern-line
;; definitions:
;;
;;     angle, x-origin,y-origin, delta-x,delta-y [, dash1, dash2, ...]
;;
;;   - angle      : the line family's angle in DEGREES.
;;   - x/y-origin : a point the first line of the family passes through.
;;   - delta-x    : shift along the line between successive dashes (offset).
;;   - delta-y    : perpendicular spacing between parallel lines of the family.
;;   - dash...    : optional dash lengths (positive = pen-down, negative = gap);
;;                  absent ⇒ a solid (continuous) line.
;;
;; These are the canonical ANSI definitions (chord error / spacing in drawing
;; units at scale 1) plus two generic families. GPLv2-or-later (LibreCAD
;; derivative); definitions match the public AutoCAD acad.pat ANSI entries.

*ANSI31, ANSI Iron, Brick, Stone masonry
45, 0,0, 0,.125

*ANSI32, ANSI Steel
45, 0,0, 0,.375
45, .176776695,0, 0,.375

*ANSI37, ANSI Lead, Zinc, Magnesium, Sound/Heat/Elec Insulation
45, 0,0, 0,.125
135, 0,0, 0,.125

*LINE, Parallel horizontal lines
0, 0,0, 0,.125

*NET, Horizontal / vertical grid (cross-hatch)
0, 0,0, 0,.125
90, 0,0, 0,.125
