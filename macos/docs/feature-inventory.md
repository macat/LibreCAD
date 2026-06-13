# LibreCAD Feature / Command / UI Inventory

Source of truth: `librecad/src/lib/engine/rs.h` (`enum RS2::ActionType`, the authoritative
action registry), action classes under `librecad/src/actions` + `librecad/src/lib/actions`,
group wiring in `librecad/src/ui/main/init/lc_actionfactory.cpp` /
`lc_menufactory.cpp` / `lc_toolbarfactory.cpp`, UI panels/dialogs under
`librecad/src/ui` (`.ui` designer files + widget classes).

Purpose: (a) drive a "broad parity" reimplementation plan; (b) inform a modern, Mac-native
(SwiftUI/AppKit) redesign. Qt is NOT being kept — the "Modern Mac take" column proposes the
native reimagining.

**Priority key**: P0 = essential core first wave; P1 = important; P2 = nice-to-have/advanced.

---

## 1. Drawing tools (create entities)

### 1a. Line
| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Line (2-point / multi-point) | `RS_ActionDrawLine` | P0 | Primary draw tool; live coordinate HUD near cursor instead of separate option toolbar |
| Line by angle | `RS_ActionDrawLineAngle` | P1 | Angle field in the inline tool inspector (trailing detail panel) |
| Horizontal / Vertical line | `RS_ActionDrawLineHorVert` (+ `DrawLineHorizontal`/`DrawLineVertical`) | P1 | Modifier-key restriction (hold for ortho) + segmented control, not separate tools |
| Parallel (through point) | `RS_ActionDrawLineParallelThrough` | P1 | Contextual: pick reference, drag offset with snapping |
| Parallel (offset distance) | `RS_ActionDrawLineParallel` | P1 | Same tool as offset-modify conceptually; merge UX |
| Bisector | `RS_ActionDrawLineBisector` | P2 | Keep as advanced construction tool |
| Tangent from point | `RS_ActionDrawLineTangent1` | P2 | Construction submenu |
| Tangent between 2 circles | `RS_ActionDrawLineTangent2` | P2 | Construction submenu |
| Orthogonal tangent | `RS_ActionDrawLineOrthTan` | P2 | Construction submenu |
| Orthogonal / rel-angle line | `RS_ActionDrawLineRelAngle` (+ `LineAngleRel`, `OrthogonalRel`) | P2 | Advanced angle entry |
| Line free-hand | `RS_ActionDrawLineFree` | P2 | Pencil/freehand mode (Apple Pencil friendly) |
| Point→line (perpendicular foot) | `LC_ActionDrawLineFromPointToLine` | P2 | Construction submenu |
| Slice/divide line / circle | `LC_ActionDrawSliceDivide` (`SliceDivideLine`/`SliceDivideCircle`) | P2 | Advanced |
| Cross (centerlines) | `LC_ActionDrawCross` | P2 | Annotation helper |
| Midline | `LC_ActionDrawMidLine` (`DrawLineMiddle`) | P2 | Construction submenu |
| Snake line (polyline-ish) | `LC_ActionDrawLineSnake` (`SnakeLine`/`X`/`Y`) | P2 | Fold into polyline tool |

### 1b. Point
| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Point | `RS_ActionDrawPoint` | P0 | Simple click tool; point-style picker in inspector |
| Points along line | `LC_ActionDrawLinePoints` | P2 | Advanced |
| Midpoints | `DrawPointsMiddle` | P2 | Advanced |
| Point lattice | `LC_ActionDrawPointsLattice` | P2 | Advanced grid-of-points generator |
| Select points / paste to points | `LC_ActionSelectPoints` / `LC_ActionPasteToPoints` | P2 | Power-user paste |

### 1c. Circle
| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Circle center+radius (interactive) | `RS_ActionDrawCircle` | P0 | Default circle tool |
| Circle center+radius (typed) | `RS_ActionDrawCircleCR` | P1 | Radius field in inspector |
| Circle 2-point | `RS_ActionDrawCircle2P` | P1 | Variant toggle on circle tool |
| Circle 2-point + radius | `LC_ActionDrawCircle2PR` (`DrawCircle2PR`) | P2 | Variant toggle |
| Circle 3-point | `RS_ActionDrawCircle3P` | P1 | Variant toggle |
| Circle tangential (1 line + 2pt / 2 line + 1pt / 2 / 3) | `RS_ActionDrawCircleTan1_2P`, `Tan2_1P`, `Tan2`, `Tan3` | P2 | "Tangent circle" construction submenu |
| Inscribed circle | `RS_ActionDrawCircleInscribe` | P2 | Construction submenu |
| Concentric/parallel circle | `DrawCircleParallel` (offset of circle) | P2 | Merge with offset |
| Circle from arc | `LC_ActionDrawCircleByArc` | P2 | Convert utility |

### 1d. Arc & curve
| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Arc center-point-angle | `RS_ActionDrawArc` | P0 | Default arc tool |
| Arc 3-point | `RS_ActionDrawArc3P` | P1 | Variant toggle |
| Arc by chord / angle+len | `DrawArcChord` / `DrawArcAngleLen` (in `RS_ActionDrawArc`) | P2 | Variant toggle |
| Arc by 2 points + (angle/radius/length/height) | `LC_ActionDrawArc2Points*` (`Angle`/`Radius`/`Length`/`Height`) | P2 | Inspector input chooser |
| Arc tangential | `RS_ActionDrawArcTangential` | P2 | Continuation tool (chain off endpoint) |
| Arc parallel | `DrawArcParallel` | P2 | Merge with offset |
| Dual (line+arc combo) | `LC_ActionDrawDual` | P2 | Advanced |
| Parabola (4 points / focus-directrix) | `LC_ActionDrawParabola4Points`, `LC_ActionDrawParabolaFD` | P2 | Advanced curves submenu |
| Hyperbola (focus-point) | `LC_ActionDrawHyperbolaFP` | P2 | Advanced curves submenu |

### 1e. Ellipse
| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Ellipse by axis | `RS_ActionDrawEllipseAxis` | P1 | Default ellipse tool |
| Ellipse 1-point (center+) | `LC_ActionDrawEllipse1Point` | P2 | Variant |
| Ellipse foci + point | `RS_ActionDrawEllipseFociPoint` | P2 | Variant |
| Ellipse 4-point / center+3pt | `RS_ActionDrawEllipse4Points`, `RS_ActionDrawEllipseCenter3Points` | P2 | Variant |
| Ellipse inscribed | `RS_ActionDrawEllipseInscribe` | P2 | Construction |
| Elliptical arc (axis / 1-point) | `DrawEllipseArcAxis` / `DrawEllipseArc1Point` | P2 | Variant |

### 1f. Polyline
| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Polyline (segments + arcs) | `RS_ActionDrawPolyline` | P0 | Core; arc-segment mode via modifier, live segment editing |
| Add node | `RS_ActionPolylineAdd` | P1 | Direct node manipulation on selected polyline |
| Append node | `RS_ActionPolylineAppend` | P1 | Drag endpoint to extend |
| Delete node / delete between | `RS_ActionPolylineDel`, `RS_ActionPolylineDelBetween` | P1 | Node context menu / delete key |
| Trim polyline segment | `RS_ActionPolylineTrim` | P1 | Unify with global trim |
| Equidistant (offset polyline) | `RS_ActionPolylineEquidistant` | P2 | Merge with offset |
| Create from segments | `RS_ActionPolylineSegment` | P2 | "Join into polyline" command |
| Arcs→lines / change segment type | `LC_ActionPolylineArcsToLines`, `LC_ActionPolylineChangeSegmentType` | P2 | Segment context menu |

### 1g. Rectangle / polygon / star (`shape_actions`)
| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Rectangle (corner-corner) | `RS_ActionDrawLineRectangle` | P0 | Default rect tool |
| Rectangle 1-point (size) | `LC_ActionDrawRectangle1Point` | P1 | Typed W×H in inspector |
| Rectangle 2-point (with corner styling) | `LC_ActionDrawRectangle2Points` | P1 | Corner radius/chamfer options inline |
| Rectangle 3-point (rotated) | `LC_ActionDrawRectangle3Points` | P2 | Rotated variant |
| Polygon center→corner / center→tangent | `RS_ActionDrawLinePolygon` (`CenCor`/`CenTan`) | P1 | Sides count in inspector |
| Polygon corner→corner / side→side | `RS_ActionDrawLinePolygon2` (`CorCor`/`SideSide`) | P2 | Variant |
| Star | `LC_ActionDrawStar` | P2 | Points + inner/outer radius inspector |

### 1h. Spline
| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Spline (control points) | `RS_ActionDrawSpline` | P1 | Bezier-style editing handles |
| Spline through points (interp.) | `LC_ActionDrawSplinePoints` | P1 | Fit-point mode toggle |
| Append/add/remove/del-two points | `LC_ActionSpline*Point*` | P2 | Direct handle editing + context menu |
| Spline explode / from polyline | `LC_ActionSplineExplode`, `LC_ActionSplineFromPolyline` | P2 | Convert utilities |

### 1i. Text & annotation
| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Multiline text (MText) | `RS_ActionDrawMText` | P1 | Inline rich-text editor on canvas, native font picker |
| Single-line text | `RS_ActionDrawText` | P1 | Same editor, single-line mode |

### 1j. Hatch / fill, image, bounding box
| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Hatch / fill | `RS_ActionDrawHatch` | P1 | Pattern picker popover; pick enclosed region by click |
| Insert image | `RS_ActionDrawImage` | P2 | Drag-drop image onto canvas |
| Bounding box | `LC_ActionDrawBoundingBox` | P2 | Utility command |

### 1k. Dimensions (`dimension_actions`)
| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Aligned dimension | `RS_ActionDimAligned` | P1 | Smart dimension tool that infers type from picks |
| Linear dimension | `RS_ActionDimLinear` | P1 | Same smart tool |
| Linear horizontal / vertical | `RS_ActionDimLinear` (`DimLinearHor`/`DimLinearVer`) | P2 | Inferred + modifier override |
| Baseline / continue | `LC_ActionDrawDimBaseline` (`DimBaseline`/`DimContinue`) | P2 | Chained-dimension mode |
| Radial dimension | `RS_ActionDimRadial` | P1 | Smart tool on circle/arc |
| Diametric dimension | `RS_ActionDimDiametric` | P1 | Smart tool on circle |
| Angular dimension | `RS_ActionDimAngular` | P1 | Smart tool on two lines |
| Arc-length dimension | `LC_ActionDimArc` | P2 | Smart tool on arc |
| Leader | `RS_ActionDimLeader` | P1 | Annotation tool |
| Ordinate / ordinate-rebase | `LC_ActionDimOrdinate`, `LC_ActionDimOrdinateRebase` | P2 | Advanced; tie to UCS |
| GD&T feature control frame | `LC_ActionDrawGdtFeatureControlFrame` (`GTDFCFrame`) | P2 | Advanced (currently partially disabled) |
| Apply dim style / regenerate | `LC_ActionDimStyleApply`, `RS_ActionToolRegenerateDimensions` | P2 | Style system, applied automatically |

**Modern Mac take (drawing tools overall)**: Replace the per-tool floating "options toolbar"
with a single contextual **tool inspector** (trailing pane or popover) that updates per active
tool. Collapse the ~30 line/circle/arc variants into ~6 primary tools, each with a variant
segmented control + typed-input fields — instead of 30 separate toolbar buttons. Live
on-canvas dimension/coordinate HUD replaces the status-bar coordinate widget.

---

## 2. Modify tools (`modify_actions` + `order_actions`)

| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Move | `RS_ActionModifyMove` | P0 | Direct drag of selection; modal dialog → inline numeric nudge |
| Copy (move w/ copies) / duplicate | `RS_ActionModifyMove` (copy mode), `LC_ActionModifyDuplicate` | P0 | ⌥-drag to copy; ⌘D duplicate |
| Move + rotate | `RS_ActionModifyMoveRotate` | P2 | Combined transform gizmo |
| Rotate | `RS_ActionModifyRotate` | P0 | On-canvas rotate handle + angle field |
| Rotate two (two centers) | `RS_ActionModifyRotate2` | P2 | Advanced |
| Scale | `RS_ActionModifyScale` | P0 | Corner handles; uniform/non-uniform toggle |
| Mirror | `RS_ActionModifyMirror` | P1 | Pick axis; flip handle |
| Align / align one / align ref | `LC_ActionModifyAlign`, `…Single`, `…Ref` | P2 | Native alignment guides + Align menu |
| Trim (1 boundary) | `RS_ActionModifyTrim` | P0 | Hover-to-trim; one unified trim tool |
| Trim 2 (mutual) | `RS_ActionModifyTrim` (`ModifyTrim2`) | P1 | Same tool, both segments |
| Trim by amount | `RS_ActionModifyTrimAmount` | P2 | Numeric trim |
| Extend | (handled within trim/lengthen logic) | P1 | Same hover tool, opposite direction |
| Lengthen / line gap | `LC_ActionModifyLineGap` | P2 | Numeric extend |
| Offset | `RS_ActionModifyOffset` | P0 | Drag-offset with live distance |
| Fillet (round) | `RS_ActionModifyRound` | P1 | Pick two edges; radius field |
| Chamfer (bevel) | `RS_ActionModifyBevel` | P1 | Pick two edges; distances field |
| Divide / break-divide | `LC_ActionModifyBreakDivide` | P1 | Split at point |
| Break out (cut) | `RS_ActionModifyCut` | P1 | Gap tool |
| Stretch | `RS_ActionModifyStretch` | P1 | Crossing-window stretch |
| Explode (entity) | `RS_ActionBlocksExplode` | P1 | Context menu "Explode" |
| Explode text | `RS_ActionModifyExplodeText` | P2 | Convert text→geometry |
| Line join | `LC_ActionModifyLineJoin` | P2 | "Join" command |
| Revert direction | `RS_ActionModifyRevertDirection` | P2 | Context menu |
| Properties / attributes edit | `RS_ActionModifyEntity`, `RS_ActionModifyAttributes` | P0 | Native inspector (see §6) — no modal |
| Delete | `RS_ActionModifyDelete` (`Quick`/`Free`) | P0 | Delete key |
| Order: raise/lower/top/bottom | `RS_ActionOrder` (`OrderRaise`/`Lower`/`Top`/`Bottom`) | P1 | Arrange menu (Bring to Front etc.) |

**Modern Mac take**: Modify ops should be mostly **direct-manipulation** with handles/gizmos
on selection, not modal dialogs (`qg_dlgmove/rotate/scale/mirror/moverotate` modals get
replaced). Numeric precision via a floating inline field. Trim/extend/offset/fillet/chamfer
unify into a small "edit edges" tool cluster.

---

## 3. Selection tools (`select_actions`)

| Tool | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Select single | `RS_ActionSelectSingle` | P0 | Click (default arrow tool) |
| Select window / deselect window | `RS_ActionSelectWindow` | P0 | Drag rubber-band; L-to-R window vs R-to-L crossing |
| Select all / deselect all | `RS_ActionSelectAll` | P0 | ⌘A / ⌘⇧A |
| Select contour | `RS_ActionSelectContour` | P1 | "Select connected" |
| Select intersected / deselect | `RS_ActionSelectIntersected` | P1 | Crossing-line selection |
| Select invert | `RS_ActionSelectInvert` | P1 | Edit menu "Invert Selection" |
| Select by layer | `RS_ActionSelectLayer` | P1 | Right-click layer → Select Entities |
| Select double (entity pick) | `RS_ActionSelectSingle` (`SelectDouble`), `GetSelect`/`GetEntity` | P1 | Double-click to edit / pick-for-command |

**Modern Mac take**: Selection is the **default tool** (arrow), with marquee + crossing built
in. Replace separate select-by-layer/type actions with a Finder-style filter bar and
right-click "Select Similar / Select on Layer".

---

## 4. Snapping & input

### Snap modes
| Mode | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Free (no snap) | `ActionSnapFree` (via snap handler) | P0 | Snap toggles in unified toolbar control, not a floating snap toolbar |
| Grid | `ActionSnapGrid` | P0 | Toolbar toggle |
| Endpoint | `ActionSnapEndpoint` | P0 | Toolbar toggle; auto-on by default |
| On entity (nearest) | `ActionSnapOnEntity` | P0 | Toolbar toggle |
| Center | `ActionSnapCenter` | P0 | Toolbar toggle |
| Middle / middle-manual | `ActionSnapMiddle`, `LC_ActionSnapMiddleManual` | P1 | Toggle + on-demand override |
| Distance (along entity) | `ActionSnapDist` | P1 | Toggle w/ distance field |
| Intersection / manual intersection | `ActionSnapIntersection`, `RS_ActionSnapIntersectionManual` | P1 | Toggle + on-demand |
| Perpendicular / tangent / nearest | (in `RS_Snapper` snap logic) | P1 | Smart inferred snaps shown as glyphs |

### Restrictions
| Restriction | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Nothing / Orthogonal / Horizontal / Vertical | `ActionRestrictNothing`/`Orthogonal`/`Horizontal`/`Vertical` | P0 | Hold ⇧ for ortho (like Sketch/Figma); explicit toggles secondary |

### Coordinate / command input
| Feature | Source | Priority | Modern Mac take |
|---|---|---|---|
| Command line widget | `QG_CommandWidget` (`qg_commandwidget.ui`) | P1 | Spotlight-style command palette (⌘K) + classic command bar for power users |
| Coordinate widget (abs/rel readout) | `QG_CoordinateWidget` (`qg_coordinatewidget.ui`) | P0 | On-canvas HUD + status bar; live abs/rel |
| Relative zero set / lock / unlock | `RS_ActionSetRelativeZero`, `RS_ActionLockRelativeZero` (Unlock) | P1 | "Set origin here" context action |
| Relative/absolute coord entry | Command-line parser + snapper | P0 | Type `@dx,dy` / `dist<angle` directly while drawing |
| Mouse hint / selection count widgets | `QG_MouseWidget`, `QG_SelectionWidget` | P1 | Status bar segments |
| Info cursor (live measurements) | `LC_InfoCursorSettingsManager` | P1 | On-canvas HUD |

**Modern Mac take**: Snap modes and restrictions belong in **one unified toolbar popover**
(toggle chips) + a Snap menu, not the legacy floating `qg_snaptoolbar`. Smart snapping
(auto endpoint/center/intersection with on-canvas glyphs) should be on by default, à la
Sketch/Figma. Coordinate entry should accept typed deltas inline at the cursor.

---

## 5. Document & view

### Layers (panel + ops) — `layer_actions` / `entity_layer_actions`
| Operation | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Layer list panel | `QG_LayerWidget`, advanced `LC_LayerTreeWidget` | P0 | SwiftUI sidebar section, inline rename/visibility/lock toggles |
| Add / remove / edit layer | `RS_ActionLayersAdd` (+`AddCmd`/`ActivateCmd`), `Remove`, `Edit` | P0 | Inline + `+`/`–`; edit via inspector |
| Toggle view / lock / print / construction | `RS_ActionLayersToggleView`/`ToggleLock`/`TogglePrint`, `LC_ActionLayersToggleConstruction` | P0 | Eye/lock icons inline per row |
| Freeze/lock all, defreeze/unlock all | `RS_ActionLayersFreezeAll`/`LockAll` (+Defreeze/Unlock) | P1 | Sidebar overflow menu |
| Export selected / visible layers | `LC_ActionLayersExport` (`ExportSelected`/`ExportVisible`) | P2 | Export sheet |
| Per-entity layer ops (activate/hide others/toggle…) | `LC_ActionEntityLayer*` (`Activate`/`ToggleView`/`HideOthers`/`TogglePrint`/`ToggleConstruction`/`ToggleLock`) | P1 | Right-click entity → Layer submenu |

### Blocks / inserts — `block_actions`
| Operation | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Block list panel | `QG_BlockWidget` | P1 | Sidebar section (symbols library) |
| Add / remove / edit / attributes | `RS_ActionBlocksAdd`/`Remove`/`Edit`/`Attributes` | P1 | Inline + inspector |
| Create (from selection) / explode | `RS_ActionBlocksCreate`, `RS_ActionBlocksExplode` | P1 | "Group into Symbol" / "Explode" |
| Insert / import / save | `RS_ActionBlocksInsert`, `BlocksImport`, `RS_ActionBlocksSave` | P1 | Drag from sidebar to place |
| Toggle view, freeze/defreeze all | `RS_ActionBlocksToggleView`, `RS_ActionBlocksFreezeAll` (+Defreeze) | P2 | Row toggles |
| Library browser + insert | `QG_LibraryWidget`, `RS_ActionLibraryInsert` | P1 | Symbols gallery panel; drag-drop |

### Pen / attributes — `pen_actions`
| Operation | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Pick / apply / copy pen | `LC_ActionPenPick` (+`PickResolved`), `LC_ActionPenApply`, `PenCopy` | P1 | Eyedropper + paste-style in inspector |
| Sync pen from layer | `LC_ActionPenSyncActiveByLayer` (`PenSyncFromLayer`) | P2 | "Reset to layer" button |
| Pen toolbar / palette / wizard | `QG_WidgetPen` (`qg_widgetpen.ui`), `LC_PenPaletteWidget`, pen_wizard `colorwizard.ui` | P1 | Color/width/linetype controls in inspector, not a toolbar |

### Zoom / pan / view
| Operation | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Zoom in / out | `RS_ActionZoomIn` (`ZoomIn`/`ZoomOut`) | P0 | Pinch / ⌘+ / ⌘- ; trackpad-native |
| Zoom auto (fit) | `RS_ActionZoomAuto` | P0 | ⌘0 "Zoom to Fit" |
| Zoom window | `RS_ActionZoomWindow` | P0 | Drag-zoom; secondary |
| Pan | `RS_ActionZoomPan` | P0 | Space-drag / two-finger; default behavior |
| Zoom scroll | `RS_ActionZoomScroll` | P1 | Scroll wheel |
| Zoom previous | `RS_ActionZoomPrevious` | P1 | Back gesture |
| Redraw | `RS_ActionZoomRedraw` | P2 | Automatic; remove from UI |
| Named views (save/restore) | `LC_NamedViewsListWidget` (`view_restore` menu) | P2 | Views sidebar section |
| UCS (user coordinate systems) | `LC_ActionUCSCreate`, `LC_ActionUCSByDimOrdinate`, `LC_UCSListWidget`, UCS status widget | P2 | Advanced; "Custom Axes" |
| Grid / metagrid / draft mode toggles | `ActionViewGrid`, `ActionViewDraft` (`LC_GridViewInvoker`) | P0 | View menu toggles |

### Print / print preview
| Operation | LibreCAD action class | Priority | Modern Mac take |
|---|---|---|---|
| Print | `ActionFilePrint` (`slotFilePrint`) | P1 | Native `NSPrintOperation` |
| Print to PDF | `ActionFilePrintPDF` (`slotFilePrintPDF`) | P1 | Native PDF export (system) |
| Print preview (+ scale/options) | `RS_ActionPrintPreview` (`qg_printpreviewoptions.ui`) | P1 | Live print-layout mode |
| Device/paper options | `lc_deviceoptions.ui`, PaperFormat enum | P1 | Page setup sheet |

### Import / export / file
| Operation | Source | Priority | Modern Mac take |
|---|---|---|---|
| New / new from template | `ActionFileNew`, `ActionFileNewTemplate` | P0 | ⌘N / template chooser |
| Open / close / quit | `ActionFileOpen`, `ActionFileClose`, `ActionFileQuit` | P0 | Standard |
| Save / Save As | (file menu; `LC_DocumentsStorage`) | P0 | Standard + autosave |
| Recent files | `QG_RecentFiles`, `LC_LastOpenFilesOpener` | P1 | File menu "Open Recent" |
| **DXF read/write** (R12–2018) | `RS_FilterDXFRW` (`rs_filterdxfrw.h`) + libdxfrw | **P0** | Core interchange via a DXF bridge (see `dxf-bridge-plan.md`) |
| DXF1 (QCad1) read | `RS_FilterDXF1` | P2 | Legacy import only |
| **DWG read/write** | `RS_FilterDXFRW` (`DWGSUPPORT`, FormatDWG) | P1 | Import/export if libredwg available |
| JWW / JWC read | `RS_FilterJWW` | P2 | Import filter |
| LFF / CXF fonts | `RS_FilterLFF`, `RS_FilterCXF` | P2 | Font loading (LibreCAD font files) |
| Export raster (PNG/JPG/BMP/…) | `LC_ImageExporter` + `QImageWriter`, `LC_ExportToImageService` (`qg_dlgimageoptions.ui`) | P1 | Native export sheet, system image codecs |
| Export SVG | `LC_ImageExporter` (`QSvgGenerator`) | P1 | Export sheet |
| Export PDF | print-to-PDF path | P1 | System PDF |
| Export MakerCAM (SVG/CAM) | `LC_ActionFileExportMakerCam` (`qg_dlgoptionsmakercam.ui`) | P2 | CAM export sheet |
| **CLI: dxf2pdf** | `librecad/src/main/console_dxf2pdf/console_dxf2pdf.cpp` | P2 | Ship a headless `librecad --dxf2pdf` CLI |
| **CLI: dxf2png** | `librecad/src/main/console_dxf2png.cpp` | P2 | Headless CLI; reuse engine |

### Units / drawing prefs
| Operation | Source | Priority | Modern Mac take |
|---|---|---|---|
| Drawing options (units/grid/paper/dims/splines/points/vars) | `RS_ActionOptionsDrawing` → `qg_dlgoptionsdrawing.ui` tabs: Units, Grid, Paper, Dims, Splines, Points, Meta, Variables, Custom | P0 | Document settings sheet/inspector |
| Application options (general) | `qg_dlgoptionsgeneral.ui` tabs: Appearance, Coordinate, Defaults, Grid, InfoCursor, Paths, Preview, Render, Snap, Startup | P1 | macOS Settings window (Cmd-,) panes |
| Dimension style manager | `lc_dlgdimstylemanager.ui` (+preview panel) | P2 | Styles editor |

---

## 6. Panels / dialogs inventory

### Dock widget panels (sidebar candidates)
| Panel | Class / `.ui` | Priority | Modern Mac take |
|---|---|---|---|
| Layer list (simple) | `QG_LayerWidget` / `qg_layerwidget` | P0 | Sidebar "Layers" section |
| Layer tree (advanced, groups) | `LC_LayerTreeWidget` (`lc_layertreeoptionsdialog.ui`) | P1 | Sidebar w/ grouping/filter |
| Block list | `QG_BlockWidget` | P1 | Sidebar "Symbols" section |
| Library browser | `QG_LibraryWidget` | P1 | Symbols gallery |
| Command line | `QG_CommandWidget` / `qg_commandwidget.ui` | P1 | Command palette + console |
| Pen palette | `LC_PenPaletteWidget` / `lc_penpalettewidget.ui` | P1 | Inspector controls |
| Pen wizard (color) | pen_wizard `colorwizard.ui` | P2 | Native color well |
| Quick / entity info | `LC_QuickInfoWidget` / `lc_quickinfowidget.ui` | P1 | Inspector "Info" tab |
| CAD tool dock | `LC_CadDockWidget` (cad toolbars) | P1 | Collapse into main toolbar |
| UCS list | `LC_UCSListWidget` / `lc_ucslistwidget.ui` | P2 | Advanced sidebar section |
| Named views list | `LC_NamedViewsListWidget` / `lc_namedviewslistwidget.ui` | P2 | Sidebar "Views" |
| Workspaces | `dock_widgets/workspaces` | P2 | Saved layouts (macOS-native) |

### Entity property / attribute dialogs (→ unified inspector)
`lc_dlgentityproperties.ui` + per-type editing widgets: line, circle, arc, ellipse, polyline,
spline, splinepoints, text, mtext, point, hatch, image, insert, hyperbola, parabola,
dimension (`lc_dlgdimension.ui`), tolerance (`lc_dlgtolerance.ui`), attributes
(`qg_dlgattributes.ui`), hatch (`qg_dlghatch.ui`), text/mtext (`qg_dlgtext.ui`,
`qg_dlgmtext.ui`), block (`qg_blockdialog.ui`), dim-label editor.
**Priority P0 (the inspector itself); per-type editors P1.**
**Modern Mac take**: One persistent **trailing Inspector** with a section per selected entity
type (like Sketch/PixelmatorPro), replacing ~20 modal dialogs. Multi-select shows shared props.

### Modal action dialogs (→ replace with direct manipulation / inline)
`qg_dlgmove`, `qg_dlgrotate`, `qg_dlgrotate2`, `qg_dlgscale`, `qg_dlgmirror`,
`qg_dlgmoverotate`, `qg_layerdialog` (P0 keep as sheet), `lc_inputtextdialog`.
**Priority P1.** Mac take: gizmos + inline numeric fields; only layer add stays a small sheet.

### Settings / system dialogs
`qg_dlgoptionsgeneral.ui` (P1), `qg_dlgoptionsdrawing.ui` (P0), `lc_deviceoptions.ui` (P1),
`lc_dlgdimstylemanager.ui` (P2), `lc_actionsshortcutsdialog.ui` (P1 → System Settings >
Keyboard style), widget/icons setup (P2, Qt-specific — drop), `lc_dlgabout.ui` (P1),
`qg_dlginitial.ui` welcome (P2), `qg_exitdialog.ui`/`lc_dlgnewversionavailable.ui` (P2).

### Status bar widgets
Coordinate (P0), mouse hint (P1), selection count (P1), active layer name (P1),
rel-zero coords (P1), angles-basis (P2), UCS-state (P2).
**Mac take**: a compact, native status bar with live coordinate + a context hint segment.

---

## Priority rollup (the broad-parity first wave)

**P0 (first wave — must ship for a usable CAD app):**
Draw: Line, Polyline, Rectangle, Circle (center+radius, +CR/3P later), Arc (center-pt-angle),
Point. Modify: Move, Copy/Duplicate, Rotate, Scale, Trim, Offset, Delete, Properties edit.
Select: single, window/crossing, all, deselect-all. Snap: free/grid/endpoint/center/on-entity
+ ortho restriction. Coord: live coordinate HUD, relative/absolute typed entry, set relative
zero. Document: Layers panel (add/remove/edit/visibility/lock/print/construction, active
layer), drawing options (units/grid/paper). View: zoom in/out/fit/window, pan, grid toggle.
File: New/Open/Save/Save As/Close/Quit, **DXF read+write**, entity Inspector.

**P1:** dimensions (smart aligned/linear/radial/diametric/angular/leader), mirror, fillet
(round), chamfer (bevel), stretch, break/divide, explode, order/arrange, hatch, text/mtext,
blocks/symbols + library, pen attributes, line variants (angle/parallel/hor-vert), circle
2P/3P, arc 3P, ellipse axis, spline, polyline node editing, select contour/intersected/
invert/by-layer, snap middle/distance/intersection, print + PDF/PNG/SVG export, named UCS-less
views, app settings, DWG, command palette.

**P2:** all advanced construction variants (tangent/inscribe/parabola/hyperbola/star, ordinate
& GD&T dims, point lattice, slice/divide, snake line), UCS, dimension style manager,
workspaces, MakerCAM/CAM export, JWW/CXF/LFF/DXF1 filters, CLI dxf2pdf/dxf2png, font viewer,
release-check/about/exit dialogs.

---

## Counts (distinct tools/commands, excluding `not_used/`)

| Category | Count |
|---|---|
| Drawing — Line | ~17 |
| Drawing — Point | 6 |
| Drawing — Circle | 12 |
| Drawing — Arc/Curve | ~13 |
| Drawing — Ellipse | 8 |
| Drawing — Polyline | 10 |
| Drawing — Rect/Polygon/Star | 9 |
| Drawing — Spline | 12 |
| Drawing — Text/Hatch/Image/BBox | 5 |
| Drawing — Dimensions | ~18 |
| Modify (+order) | ~30 |
| Selection | ~14 |
| Snap modes | ~12 |
| Restrictions | 4 |
| Rel-zero / coord input | ~6 |
| Info / measure | ~11 |
| Layers (layer + entity-layer ops) | ~21 |
| Blocks + library | ~13 |
| Pen | ~6 |
| Zoom / view / UCS | ~14 |
| File / import / export / CLI | ~20 |
| Options / preferences | ~4 dialogs (≈19 tabs) |
| Panels (dock widgets) | ~13 |
| Dialogs (`.ui`, excl. not_used) | ~95 |

**Total distinct actions in `RS2::ActionType`: ~250** (the authoritative registry, including
~30 in `not_used/` slated for removal). Net live tool/command surface ≈ **220**.
