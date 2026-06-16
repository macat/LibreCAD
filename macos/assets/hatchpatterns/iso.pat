;; iso.pat — ISO 128 dashed line hatch patterns for the LibreCAD macOS port.
;;
;; Standard AutoCAD-format `.pat` definitions (CADEngine/HatchPattern.swift
;; parser). One header line `*NAME, description` per pattern, followed by one or
;; more pattern-line records:
;;
;;     angle, x-origin,y-origin, delta-x,delta-y [, dash1, dash2, ...]
;;
;; The ISO 128 dash families (dashed / dash-dot / long-dash). Definitions match
;; the public AutoCAD acad_iso.pat ISO entries (mm at scale 1).
;; GPLv2-or-later (LibreCAD derivative).

*ISO02W100, dashed line
0, 0,0, 0,3.0, 12,-3

*ISO03W100, dashed space line
0, 0,0, 0,3.0, 12,-18

*ISO04W100, long dashed dotted line
0, 0,0, 0,3.0, 24,-3,.5,-3

*ISO05W100, long dashed double dotted line
0, 0,0, 0,3.0, 24,-3,.5,-3,.5,-3

*ISO08W100, long dashed short dashed line
0, 0,0, 0,3.0, 24,-3,6,-3

*ISO10W100, dashed dotted line
0, 0,0, 0,3.0, 12,-3,.5,-3

*ISO12W100, dashed double dotted line
0, 0,0, 0,3.0, 12,-3,.5,-3,.5,-3
