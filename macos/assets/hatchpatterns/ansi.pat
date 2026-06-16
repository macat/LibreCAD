;; ansi.pat — additional ANSI hatch patterns for the LibreCAD macOS port.
;;
;; Standard AutoCAD-format `.pat` definitions (CADEngine/HatchPattern.swift
;; parser). One header line `*NAME, description` per pattern, followed by one or
;; more pattern-line records:
;;
;;     angle, x-origin,y-origin, delta-x,delta-y [, dash1, dash2, ...]
;;
;; ANSI31/32/37, LINE, NET already ship in librecad.pat; these add the remaining
;; canonical ANSI families (33/34/35/36/38). Definitions match the public
;; AutoCAD acad.pat ANSI entries. GPLv2-or-later (LibreCAD derivative).

*ANSI33, ANSI Bronze, Brass, Copper
45, 0,0, 0,.25, .25,-.0625

*ANSI34, ANSI Plastic, Rubber
45, 0,0, 0,.75
45, .176776695,0, 0,.75
45, .353553391,0, 0,.75
45, .530330086,0, 0,.75

*ANSI35, ANSI Fire brick, Refractory material
45, 0,0, 0,.25, .3125,-.0625,0,-.0625

*ANSI36, ANSI Marble, Slate, Glass
45, 0,0, .21875,.125, .3125,-.0625,0,-.0625

*ANSI38, ANSI Aluminum
45, 0,0, 0,.125
45, 0,0, .375,.6875, .3125,-.1875
