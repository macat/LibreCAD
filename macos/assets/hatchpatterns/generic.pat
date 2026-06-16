;; generic.pat — common generic hatch patterns for the LibreCAD macOS port.
;;
;; Standard AutoCAD-format `.pat` definitions (CADEngine/HatchPattern.swift
;; parser). One header line `*NAME, description` per pattern, followed by one or
;; more pattern-line records:
;;
;;     angle, x-origin,y-origin, delta-x,delta-y [, dash1, dash2, ...]
;;
;; The everyday non-ANSI families: dots, grids, brick, herringbone, etc.
;; Definitions match the public AutoCAD acad.pat entries.
;; GPLv2-or-later (LibreCAD derivative).

*DOTS, A scattering of dots
0, 0,0, .03125,.0625, 0,-.0625

*GRID, Grid pattern
0, 0,0, 0,.125
90, 0,0, 0,.125

*CROSS, A series of crosses
0, 0,0, .25,.25, .125,-.375
90, .0625,-.0625, .25,.25, .125,-.375

*SQUARE, Small aligned squares
0, 0,0, 0,.125, .125,-.125
90, 0,0, 0,.125, .125,-.125

*BRICK, Standard brick pattern
0, 0,0, 0,.25
90, 0,0, .25,.25, .25,-.25
90, .125,.125, .25,.25, .25,-.25

*ANGLE, Angle steel
0, 0,0, 0,.275, .2,-.075
90, 0,0, 0,.275, .2,-.075

*HONEY, Honeycomb pattern
0, 0,0, .1083,.1875, .1083,-.2167
120, 0,0, .1083,.1875, .1083,-.2167
60, .1875,0, .1083,.1875, -.2167,.1083

*ZIGZAG, Staircase effect
0, 0,0, .125,.125, .125,-.125
90, .125,0, .125,.125, .125,-.125
