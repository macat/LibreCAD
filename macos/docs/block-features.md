# AutoCAD LT Block Features — Complete Product Specification

> **Purpose**: This document is an exhaustive feature specification for AutoCAD LT's block system. It is written as acceptance criteria for implementing equivalent features in another CAD product. Every behavior, option, parameter, constraint, and edge case is documented so a developer who has never used AutoCAD can build a functionally equivalent system.
>
> **Scope**: Covers block definitions, block references, dynamic blocks, block attributes, external references (xrefs), block libraries, content management, and all related commands. AutoCAD LT limitations relative to full AutoCAD are explicitly called out.

---

## Table of Contents

1. [Foundational Concepts](#1-foundational-concepts)
2. [Creating Block Definitions](#2-creating-block-definitions)
3. [Inserting Block References](#3-inserting-block-references)
4. [The Block Editor (BEDIT)](#4-the-block-editor-bedit)
5. [Dynamic Blocks — Parameters](#5-dynamic-blocks--parameters)
6. [Dynamic Blocks — Actions](#6-dynamic-blocks--actions)
7. [Dynamic Blocks — Parameter Sets](#7-dynamic-blocks--parameter-sets)
8. [Dynamic Blocks — Value Sets](#8-dynamic-blocks--value-sets)
9. [Dynamic Blocks — Visibility States](#9-dynamic-blocks--visibility-states)
10. [Dynamic Blocks — Lookup Tables](#10-dynamic-blocks--lookup-tables)
11. [Dynamic Blocks — Constraints](#11-dynamic-blocks--constraints)
12. [Dynamic Blocks — Block Properties Table](#12-dynamic-blocks--block-properties-table)
13. [Dynamic Blocks — Advanced Behaviors](#13-dynamic-blocks--advanced-behaviors)
14. [Block Attributes](#14-block-attributes)
15. [External References (Xrefs)](#15-external-references-xrefs)
16. [In-Place Reference Editing (REFEDIT)](#16-in-place-reference-editing-refedit)
17. [Block Libraries & Content Management](#17-block-libraries--content-management)
18. [Nested Blocks](#18-nested-blocks)
19. [Anonymous Blocks](#19-anonymous-blocks)
20. [Modifying Block Definitions](#20-modifying-block-definitions)
21. [Purging and Cleanup](#21-purging-and-cleanup)
22. [AutoCAD LT Limitations](#22-autocad-lt-limitations)
23. [DWG File Format — Block Storage](#23-dwg-file-format--block-storage)
24. [Commands Reference](#24-commands-reference)
25. [System Variables Reference](#25-system-variables-reference)

---

## 1. Foundational Concepts

### 1.1 What is a Block?

A **block** is a compound object that combines multiple geometric objects (lines, arcs, circles, text, etc.) into a single named entity. Blocks enable reuse, consistency, and efficient drawing management.

The term "block" is used interchangeably for two distinct concepts:

| Concept | Description |
|---------|-------------|
| **Block Definition** | The template/blueprint. Contains the name, base point, and set of geometric objects. Stored once in the drawing's Block Table. |
| **Block Reference** | An instance/insertion of a block definition placed in the drawing. Multiple references can point to the same definition. Each reference has its own position, scale, and rotation. |

### 1.2 Block Definition vs Block Reference

**Block Definition** properties:
- **Name**: Up to 255 characters. Can include letters, numbers, spaces, and special characters not reserved by the OS (when EXTNAMES = 1).
- **Base Point**: The insertion origin point. Used as the reference point for positioning, rotation, and scaling during insertion.
- **Geometry**: The set of objects (lines, arcs, polylines, text, hatches, etc.) that visually represent the block.
- **Description**: Optional text describing the block's purpose.
- **Block Unit**: The unit of measurement for the block (Inches, Millimeters, Meters, etc., or Unitless). Controls automatic scaling when inserted into a drawing with different units.
- **Behavior flags**: Annotative, Allow Exploding, Scale Uniformly.

**Block Reference** properties:
- **Insertion Point**: X, Y, Z coordinates where the block's base point is placed.
- **Scale**: X, Y, Z scale factors. Can be independent (non-uniform) or uniform.
- **Rotation**: Angle of rotation around the insertion point.
- **Layer**: Always inserted on the current layer, but objects within the block preserve their original layer/color/linetype properties.
- **Dynamic Properties** (if dynamic block): Custom properties exposed by parameters.

### 1.3 Property Inheritance: BYLAYER, BYBLOCK, and Explicit

Objects within a block can have three color/linetype/lineweight assignment modes:

| Mode | Behavior when block is inserted |
|------|-------------------------------|
| **Explicit** (e.g., Red, Dashed) | Object always displays with that specific property regardless of the layer or block reference properties. |
| **BYLAYER** | Object inherits properties from the layer it was originally created on. Even when the block reference is on a different layer, the internal objects use their original layer's properties. |
| **BYBLOCK** | Object inherits properties from the block reference itself. If the block reference is set to Green, all BYBLOCK objects display as Green. If no color is set on the reference, BYBLOCK objects display as White (on dark background) or Black (on light background). |

### 1.4 Units and Scaling

When inserting a block:
- The block is automatically scaled based on the ratio of the block's defined units (INSUNITS of the block) to the drawing's units (INSUNITS of the drawing).
- Example: Block defined in centimeters inserted into a drawing using meters → scale factor = 0.01.
- If block unit is set to "Unitless," no automatic scaling occurs.

---

## 2. Creating Block Definitions

### 2.1 BLOCK Command (Dialog Version)

**Command**: `BLOCK`  
**Ribbon**: Home tab → Block panel → Create  
**Dialog**: Block Definition dialog box

#### Dialog Options

| Field | Description |
|-------|-------------|
| **Name** | The block name. Up to 255 characters. |
| **Base Point** | The insertion base point. Can be picked on screen or entered as X, Y, Z coordinates. |
| **Objects** | Selection set of objects to include. Three modes for what happens to selected objects after creation: |
| | • **Retain**: Objects remain as individual entities in the drawing |
| | • **Convert to block**: Objects are replaced with a block reference (most common) |
| | • **Delete**: Objects are removed from the drawing |
| **Behavior: Annotative** | If checked, the block scales automatically based on the current annotation scale. |
| **Behavior: Match block orientation to layout** | Block reference adjusts orientation to match paper space layout. Only available when Annotative is checked. |
| **Behavior: Scale uniformly** | Forces uniform X, Y, Z scaling on insertion (no non-uniform stretch). |
| **Behavior: Allow exploding** | If unchecked, the EXPLODE command cannot decompose this block reference. |
| **Settings: Block Unit** | Drop-down of measurement units (Inches, Feet, Millimeters, Centimeters, Meters, Kilometers, etc., or Unitless). |
| **Description** | Optional text description shown in DesignCenter and Blocks palette. |
| **Open in block editor** | If checked, immediately opens the block in the Block Editor after creation. |

#### Selection Order Matters for Attributes

When selecting objects for a block that includes attribute definitions (ATTDEF objects), the selection order of attributes determines the prompt order during insertion. Select geometry first, then select attributes one by one in the desired prompt order.

#### Redefining Existing Blocks

If you enter the name of an existing block, the system prompts: "Block [name] already exists. Do you want to redefine it?" If yes:
- All existing block references in the drawing are immediately updated with the new geometry.
- Existing attribute values in placed references are preserved (not reset).
- New attribute definitions only apply to subsequent insertions.
- Use ATTSYNC to force-update attribute definitions on existing references.

### 2.2 -BLOCK Command (Command-Line Version)

**Command**: `-BLOCK`  
**No dialog** — everything is done via command prompts.

#### Prompts

```
Enter block name or [?]:
```

- **Block name**: Names the new block.
- **?**: Lists existing block definitions in the drawing.

```
Specify insertion base point or [Annotative]:
```

- Enter a point or type `A` for annotative options.
- If annotative: prompts Yes/No, then "Match orientation to layout" Yes/No.

```
Select objects:
```

- Standard object selection. Press Enter when done.

```
Specify the behavior of source objects [Retain/Convert to block/Delete] <Convert to block>:
```

### 2.3 WBLOCK Command (Write Block)

**Command**: `WBLOCK`  
**Dialog**: Write Block dialog box

Saves objects, a block definition, or the entire drawing as a new external DWG file. Can also create a new block definition in the current drawing.

#### Source Options

| Source | Description |
|--------|-------------|
| **Block** | Writes an existing block definition to a new DWG file. |
| **Entire Drawing** | Saves the entire current drawing as a new file. Removes unused named objects (a "cleanup" save). |
| **Objects** | Writes selected objects to a new DWG file. |

#### Object Disposition (when Source = Objects)

| Option | Description |
|--------|-------------|
| **Retain** | Selected objects remain in the drawing. |
| **Convert to Block** | Selected objects become a block reference in the current drawing. The block is named after the output filename. |
| **Delete from Drawing** | Selected objects are erased after being written to the file. |

#### Additional Settings

- **Base Point**: X, Y, Z coordinates (can be picked on screen).
- **File Name and Path**: Output location.
- **Block Unit**: Unit for automatic scaling when inserted elsewhere.

### 2.4 Creating Blocks via Drag-and-Drop

Dragging a `.dwg` file from the file system into the drawing canvas inserts it as a block reference. The filename (without extension) becomes the block name.

---

## 3. Inserting Block References

### 3.1 INSERT / CLASSICINSERT Command

**Command**: `INSERT` or `CLASSICINSERT`

#### Methods of Insertion

| Method | Command/Interface | Description |
|--------|------------------|-------------|
| **Ribbon Gallery** | Home tab → Block panel → Insert | Shows thumbnails of blocks defined in the current drawing. Click to insert. Good for small numbers of blocks. |
| **Blocks Palette** | `BLOCKSPALETTE` or `CONTENT` | Three/four tabs: Current Drawing, Recent, Favorites, Libraries. Supports drag-and-drop and click-and-place. |
| **Classic Insert Dialog** | `CLASSICINSERT` | Traditional dialog box with name field, browse button, and insertion parameters. |
| **Tool Palettes** | `TOOLPALETTES` | Customizable palettes with block tools. Drag or click to insert. |
| **DesignCenter** | `ADCENTER` | Browse blocks from any DWG file. Drag-and-drop into drawing. |
| **Drag from File System** | N/A | Drag a .dwg file into the canvas. |

#### Insertion Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| **Insertion Point** | X, Y, Z coordinates or pick on screen. | Specify on screen |
| **Scale X** | Scale factor in X direction. | 1.0 |
| **Scale Y** | Scale factor in Y direction. | 1.0 |
| **Scale Z** | Scale factor in Z direction. | 1.0 |
| **Uniform Scale** | If checked, X scale applies to Y and Z. | Off (unless block was defined with "Scale Uniformly") |
| **Rotation** | Angle in degrees. | 0 |
| **Explode** | If checked, block is immediately exploded into its component objects on insertion. Uniform scale is forced. | Off |
| **Repeat Placement** | Automatically prompts for additional insertion points until Esc. | Off |

#### Auto-Scaling on Insertion

When inserting a block from another file or DesignCenter:
- The block's INSUNITS value is compared with the drawing's INSUNITS value.
- If they differ, the block is automatically scaled by the conversion factor.
- Example: Block in mm → Drawing in inches → Scale = 1/25.4.

#### Behavior with Existing Block Names

If you insert a block from an external file and a block with the same name already exists in the drawing:
- The existing definition takes precedence. The external definition is NOT imported.
- To update/override, use DesignCenter with the "Redefine" option, or use `BLOCKREDEFINEMODE` system variable (values 0, 1, 2 control behavior).

### 3.2 Blocks Palette Detailed Behavior

Tabs:
1. **Current Drawing**: Shows all block definitions in the active drawing (excludes dimension-style and multileader-style blocks).
2. **Recent**: Shows recently inserted blocks across all drawings (syncs to Autodesk account).
3. **Favorites**: User-pinned blocks.
4. **Libraries**: Browse blocks from a folder or a specific drawing file. Supports cloud storage for cross-device sync.

Insertion options at the bottom of the palette:
- **Insertion Point**: Check/uncheck to specify on screen.
- **Scale**: Check/uncheck to specify on screen.
- **Rotation**: Check/uncheck to specify on screen.
- **Repeat Placement**: Toggle auto-repeat.
- **Explode**: Toggle explode-on-insert.

**Note**: Drag-and-drop ignores the Scale and Rotation options (uses defaults). Click-and-place respects all options.

### 3.3 -INSERT Command (Command-Line)

```
Enter block name or [?] <last>: 
```
- Enter name, `?` to list, or `~` to browse for an external file.

```
Specify insertion point or [Basepoint/Scale/X/Y/Z/Rotate]:
```
- Subcommands allow specifying scale/rotation before picking the point.

```
Enter X scale factor, specify opposite corner, or [Corner/XYZ] <1>:
Enter Y scale factor <use X scale factor>:
Specify rotation angle <0>:
```

---

## 4. The Block Editor (BEDIT)

### 4.1 Overview

The Block Editor is a dedicated authoring environment for creating and modifying block definitions. It provides:

- A **drawing area** with a distinct gray background (to distinguish from regular drawing).
- A **contextual ribbon tab** (Block Editor tab) with tools for saving, testing, and exiting.
- **Block Authoring Palettes** with tabs for Parameters, Actions, Parameter Sets, and Constraints.
- A **test environment** for validating dynamic block behavior.

**Command**: `BEDIT`  
**Access**: Home tab → Block panel → Block Editor  
**Lock**: Controlled by `BLOCKEDITLOCK` system variable (1 = locked, cannot open).

### 4.2 Block Editor-Only Commands

These commands are available **only** inside the Block Editor:

| Command | Description | LT Available? |
|---------|-------------|---------------|
| `BACTION` | Adds an action to a dynamic block definition | ✓ |
| `BACTIONBAR` | Controls the display of action bars | ✓ |
| `BACTIONSET` | Specifies the selection set of objects associated with an action | ✓ |
| `BACTIONTOOL` | Adds an action from the Actions tab | ✓ |
| `BASSOCIATE` | Associates an action with a parameter | ✓ |
| `BATTORDER` | Specifies the order of attributes for a block | ✓ |
| `BAUTHORPALETTE` | Opens the Block Authoring Palettes | ✓ |
| `BAUTHORPALETTECLOSE` | Closes the Block Authoring Palettes | ✓ |
| `BCLOSE` | Closes the Block Editor | ✓ |
| `BCPARAMETER` | Applies constraint parameters to objects | ✗ (Full AutoCAD only) |
| `BCYCLEORDER` | Changes the cycling order of grips for a dynamic block | ✓ |
| `BCONSTRUCTION` | Converts geometry to construction geometry | ✓ |
| `BGRIPSET` | Specifies a grip set for a parameter | ✓ |
| `BLOOKUPTABLE` | Displays or creates a lookup table for a dynamic block | ✓ |
| `BPARAMETER` | Adds a parameter to a dynamic block definition | ✓ |
| `BSAVE` | Saves the current block definition | ✓ |
| `BSAVEAS` | Saves the current block definition under a new name | ✓ |
| `BTABLE` | Displays a dialog to define block variations (Block Properties Table) | ✗ (Full AutoCAD only) |
| `BTESTBLOCK` | Opens a test window to test the dynamic block | ✓ |
| `BVHIDE` | Makes objects invisible for the current visibility state | ✓ |
| `BVSHOW` | Makes objects visible for the current or all visibility states | ✓ |
| `BVSTATE` | Creates, sets, renames, or deletes visibility states | ✓ |

### 4.3 Block Editor Ribbon Tab

| Panel | Tools |
|-------|-------|
| **Open/Save** | Edit/Create Block Definition, Save Block Definition (`BSAVE`), Save Block As (`BSAVEAS`), Test Block (`BTESTBLOCK`) |
| **Geometric** | Auto Constrain¹, Geometric Constraint¹, Show/Hide Constraints |
| **Dimensional** | Parameter Constraint (`BCPARAMETER`)¹, Block Table (`BTABLE`)¹ |
| **Manage** | Parameter (`BPARAMETER`), Action (`BACTION`), Define Attribute, Authoring Palettes, Parameters Manager |
| **Visibility** | Visibility Mode (`BVMODE`), Make Visible (`BVSHOW`), Make Invisible (`BVHIDE`), Manage Visibility States, Visibility State dropdown |
| **Close** | Close Block Editor (`BCLOSE`) |

¹ Not available in AutoCAD LT

### 4.4 Block Editor Testing

`BTESTBLOCK` opens a temporary environment within the Block Editor where you can:
- Insert a test instance of the block
- Interact with grips and dynamic properties
- Verify parameter/action behavior
- Test visibility state switching
- Verify value set constraints

**Behavior**: The test environment is isolated. Changes to the test instance don't affect the definition. Close with the "Close Test Block" button.

### 4.5 Construction Geometry

`BCONSTRUCTION` converts regular geometry in the Block Editor to **construction geometry** — objects that are visible in the editor for reference but are never displayed in block references. Displayed as dashed lines in the editor.

**Use cases**: Guide lines, reference points, alignment aids that help position parameters and actions but shouldn't appear in the final block.

---

## 5. Dynamic Blocks — Parameters

### 5.1 Overview

Parameters define **what can change** in a dynamic block. Each parameter:
- Defines a **custom property** for the block reference.
- Specifies **key points** (locations that drive actions).
- Displays **grips** that users manipulate to change the block.
- Can have **value sets** that constrain allowable values.
- Has a **label** that appears as a property name in the Properties palette.

Parameters are added via the **Parameters tab** of the Block Authoring Palettes, or via the `BPARAMETER` command.

### 5.2 Parameter Types

#### 5.2.1 Point Parameter

| Property | Value |
|----------|-------|
| **Custom Properties** | Position X, Position Y |
| **Grips** | 1 (at the specified point) |
| **Compatible Actions** | Move, Stretch |
| **Appearance in Editor** | Ordinate dimension-like display |

**Behavior**: Defines an X, Y location in the drawing. When the grip is moved, the associated action moves/stretches objects.

**Properties**:
- Position X, Position Y: Current coordinates
- Label (custom name for the Properties palette)
- Description
- Show properties: Yes/No
- Chain Actions: Yes/No

#### 5.2.2 Linear Parameter

| Property | Value |
|----------|-------|
| **Custom Properties** | Distance |
| **Grips** | 2 (start and end points) |
| **Compatible Actions** | Move, Scale, Stretch, Array |
| **Appearance in Editor** | Aligned dimension-like display |

**Behavior**: Shows the distance between two anchor points. Constrains grip movement along a preset angle. Grips are at each endpoint.

**Properties**:
- Distance: Current distance value
- Angle: The angle of the parameter line
- Base X, Base Y: Start point coordinates
- End X, End Y: End point coordinates
- Label, Description
- Number of grips: 0, 1, or 2
- Value set type: None, List, Increment
- Minimum, Maximum values
- Show properties: Yes/No
- Chain Actions: Yes/No

#### 5.2.3 Polar Parameter

| Property | Value |
|----------|-------|
| **Custom Properties** | Distance, Angle |
| **Grips** | 2 (start and end points) |
| **Compatible Actions** | Move, Scale, Stretch, Polar Stretch, Array |
| **Appearance in Editor** | Aligned dimension with angle display |

**Behavior**: Like Linear but also exposes the angle as an editable property. The grip can move in any direction, changing both distance and angle simultaneously.

#### 5.2.4 XY Parameter

| Property | Value |
|----------|-------|
| **Custom Properties** | Horizontal Distance, Vertical Distance |
| **Grips** | Up to 4 (one per corner/key point) |
| **Compatible Actions** | Move, Scale, Stretch, Array |
| **Appearance in Editor** | Pair of horizontal and vertical dimensions sharing a base point |

**Behavior**: Defines independent horizontal (X) and vertical (Y) distances from a base point. Each grip can be associated with different actions.

#### 5.2.5 Rotation Parameter

| Property | Value |
|----------|-------|
| **Custom Properties** | Angle |
| **Grips** | 1 (rotation grip) |
| **Compatible Actions** | Rotate |
| **Appearance in Editor** | Circle with angle marker |

**Behavior**: Defines a rotation angle around a center point. The grip rotates associated objects.

**Properties**:
- Angle: Current rotation value
- Base angle: Starting angle
- Default angle
- Label, Description
- Value set for angle (list or increment)

#### 5.2.6 Alignment Parameter

| Property | Value |
|----------|-------|
| **Custom Properties** | None exposed (affects block's Rotation property) |
| **Grips** | 1 (alignment grip) |
| **Compatible Actions** | None needed (self-contained) |
| **Appearance in Editor** | Alignment line |

**Behavior**: The block reference automatically rotates to align with nearby objects (lines, polylines, arcs, etc.) when the alignment grip is near them. This is a "standalone" parameter — it always applies to the entire block and requires no associated action.

**Key behavior details**:
- When you drag the block reference near a line or other linear object, the block automatically aligns its rotation to match the angle of that object.
- The alignment parameter defines the alignment direction and the grip point.
- Only one alignment parameter is allowed per block.

#### 5.2.7 Flip Parameter

| Property | Value |
|----------|-------|
| **Custom Properties** | Flip state (Not Flipped / Flipped) |
| **Grips** | 1 (flip grip — shown as a directional arrow) |
| **Compatible Actions** | Flip |
| **Appearance in Editor** | Reflection line |

**Behavior**: Flips (mirrors) objects about the defined reflection line. The flip grip is a toggle — clicking it alternates between flipped and not-flipped states.

**Properties**:
- Flip state: "Not Flipped" or "Flipped"
- Label, Description
- Base X, Base Y: Reflection line start
- End X, End Y: Reflection line end

#### 5.2.8 Visibility Parameter

| Property | Value |
|----------|-------|
| **Custom Properties** | Visibility state name (string) |
| **Grips** | 1 (dropdown grip) |
| **Compatible Actions** | None needed (self-contained) |
| **Appearance in Editor** | Text label with grip |

**Behavior**: Controls which objects are visible in the block reference. Clicking the grip in the drawing displays a dropdown list of available visibility states. Selecting a state shows/hides geometry according to the state's definition.

**Key rules**:
- Only **one** visibility parameter allowed per block.
- Always applies to the entire block (no selection set needed).
- No action association required.
- See Section 9 for full visibility states specification.

#### 5.2.9 Lookup Parameter

| Property | Value |
|----------|-------|
| **Custom Properties** | Lookup value (from defined table) |
| **Grips** | 1 (dropdown grip) |
| **Compatible Actions** | Lookup |
| **Appearance in Editor** | Text label |

**Behavior**: Defines a custom property that evaluates to a value from a predefined lookup table. When the user clicks the grip, a dropdown list of allowable values appears. Selecting a value sets other parameters to their mapped values.

See Section 10 for full lookup table specification.

#### 5.2.10 Base Point Parameter

| Property | Value |
|----------|-------|
| **Custom Properties** | None |
| **Grips** | 0 (no user-manipulable grip) |
| **Compatible Actions** | Cannot be associated with actions, but CAN belong to an action's selection set |
| **Appearance in Editor** | Circle with crosshairs |

**Behavior**: Defines the base point for the dynamic block reference relative to the block's geometry. Overrides the block definition's original base point for dynamic behavior purposes.

**Key distinction**: The base point parameter doesn't drive actions — it establishes a reference origin that other actions and parameters can use.

### 5.3 Parameter Common Properties

All parameters share these configurable properties (set via the Properties palette when a parameter is selected in the Block Editor):

| Property | Description |
|----------|-------------|
| **Label** | Custom name displayed in the Properties palette. Should be unique within the block. |
| **Description** | Optional description text. |
| **Show** | Yes/No — whether the property appears in the Properties palette when the block reference is selected in a drawing. |
| **Number of Grips** | How many grips the parameter exposes (0, 1, or 2 depending on parameter type). |
| **Chain Actions** | Yes/No — whether actions triggered by this parameter can trigger other chained actions. See Section 13.1. |
| **Value Set** | Constrains the parameter's allowable values. See Section 8. |

---

## 6. Dynamic Blocks — Actions

### 6.1 Overview

Actions define **what happens** when a parameter is manipulated. Every action:
- Must be **associated with a parameter**.
- Has a **key point** (the point on the parameter that drives the action).
- Has a **selection set** (the geometry affected by the action).

Actions are added via the **Actions tab** of the Block Authoring Palettes, or via the `BACTIONTOOL` command.

**Visual indicator**: In the Block Editor, actions appear as lightning bolt icons near their associated parameter. An exclamation point (!) on the icon indicates the action has no selection set defined yet.

### 6.2 Action Types

#### 6.2.1 Move Action

| Property | Value |
|----------|-------|
| **Compatible Parameters** | Point, Linear, Polar, XY |
| **Effect** | Moves the selection set objects by the distance and angle of the grip movement |

**Behavior**: When the user drags the associated grip, objects in the selection set translate by the same vector. Similar to the MOVE command.

**Override Properties**:
- **Distance Multiplier**: Multiplies the actual grip movement distance. E.g., multiplier of 2 = objects move twice the grip distance.
- **Angle Offset**: Adds an angle offset to the movement direction. E.g., offset of 90° = objects move perpendicular to grip direction.
- **XY** (when associated with XY parameter): Can constrain movement to X only, Y only, or XY.

#### 6.2.2 Scale Action

| Property | Value |
|----------|-------|
| **Compatible Parameters** | Linear, Polar, XY |
| **Effect** | Scales the selection set relative to a base point |

**Behavior**: When the parameter value changes, objects in the selection set scale proportionally. The scale factor is derived from the ratio of the new parameter value to the original.

**Properties**:
- **Base Type**: 
  - *Dependent*: Scale base point is the parameter's base point.
  - *Independent*: Scale base point is specified separately.
- **Base Point** (if independent): Specified XY location.

#### 6.2.3 Stretch Action

| Property | Value |
|----------|-------|
| **Compatible Parameters** | Point, Linear, Polar, XY |
| **Effect** | Moves objects fully within a stretch frame; stretches objects that cross the frame boundary |

**Behavior**: Objects entirely within the stretch frame move rigidly. Objects that cross the stretch frame boundary are stretched (vertices within the frame move, vertices outside stay fixed). This is analogous to the STRETCH command.

**Required inputs during creation**:
1. Associate with a parameter
2. Specify the key point on the parameter
3. Define a stretch frame (crossing window)
4. Select the objects

**Override Properties**: Distance Multiplier, Angle Offset (same as Move).

#### 6.2.4 Polar Stretch Action

| Property | Value |
|----------|-------|
| **Compatible Parameters** | Polar (only) |
| **Effect** | Rotates, moves, and stretches objects based on the polar parameter's angle and distance changes |

**Behavior**: Combines rotation and stretching in one action. When the polar parameter's key point is dragged:
- Objects in the stretch frame are rotated by the angle change and stretched by the distance change.
- Objects outside the stretch frame but in the selection set are only rotated.

**Required inputs**:
1. Associate with polar parameter
2. Specify a stretch frame
3. Select objects to stretch (within frame)
4. Select objects to rotate only

#### 6.2.5 Rotate Action

| Property | Value |
|----------|-------|
| **Compatible Parameters** | Rotation (only) |
| **Effect** | Rotates the selection set around the rotation parameter's center point |

**Behavior**: When the rotation grip is moved, all objects in the selection set rotate by the same angle. Similar to the ROTATE command.

#### 6.2.6 Flip Action

| Property | Value |
|----------|-------|
| **Compatible Parameters** | Flip (only) |
| **Effect** | Mirrors the selection set about the flip parameter's reflection line |

**Behavior**: Clicking the flip grip mirrors all objects in the selection set about the defined reflection line. It's a toggle — the same grip flips and unflips.

#### 6.2.7 Array Action

| Property | Value |
|----------|-------|
| **Compatible Parameters** | Linear, Polar, XY |
| **Effect** | Creates a rectangular array of the selection set objects |

**Behavior**: When the parameter value increases, additional copies of the selection set objects are arrayed. The number of copies is determined by the parameter distance divided by the column/row offset distance.

**Properties**:
- **Column Offset**: Distance between columns.
- **Row Offset** (for XY parameter): Distance between rows.

**Key detail**: The array is dynamic — stretching the parameter adds or removes copies automatically.

#### 6.2.8 Lookup Action

| Property | Value |
|----------|-------|
| **Compatible Parameters** | Lookup (only) |
| **Effect** | Evaluates a lookup table and sets other parameter values accordingly |

**Behavior**: When added to a block with a lookup parameter, it creates a lookup table mapping. The lookup action reads the current values of input parameters (or the selected lookup value) and sets output parameter values.

See Section 10 for full lookup table specification.

### 6.3 Parameter-Action Compatibility Matrix

| Action \ Parameter | Point | Linear | Polar | XY | Rotation | Alignment | Flip | Visibility | Lookup | Base Point |
|-------------------|-------|--------|-------|----|----------|-----------|------|------------|--------|------------|
| **Move** | ✓ | ✓ | ✓ | ✓ | – | – | – | – | – | – |
| **Scale** | – | ✓ | ✓ | ✓ | – | – | – | – | – | – |
| **Stretch** | ✓ | ✓ | ✓ | ✓ | – | – | – | – | – | – |
| **Polar Stretch** | – | – | ✓ | – | – | – | – | – | – | – |
| **Rotate** | – | – | – | – | ✓ | – | – | – | – | – |
| **Flip** | – | – | – | – | – | – | ✓ | – | – | – |
| **Array** | – | ✓ | ✓ | ✓ | – | – | – | – | – | – |
| **Lookup** | – | – | – | – | – | – | – | – | ✓ | – |

**Standalone parameters** (no action needed): Alignment, Visibility, Base Point.

---

## 7. Dynamic Blocks — Parameter Sets

### 7.1 Overview

Parameter Sets are pre-packaged combinations of a parameter and one or more actions, available on the **Parameter Sets tab** of the Block Authoring Palettes. They streamline the most common workflows.

When you add a parameter set, the parameter and its associated action(s) are created together. A yellow exclamation mark (!) appears on the action icon, indicating you still need to define the selection set for the action.

### 7.2 Available Parameter Sets

| Parameter Set | What It Creates |
|--------------|----------------|
| **Point Move** | Point parameter + Move action |
| **Linear Move** | Linear parameter + Move action (endpoint) |
| **Linear Stretch** | Linear parameter + Stretch action |
| **Linear Array** | Linear parameter + Array action |
| **Linear Move Pair** | Linear parameter + 2 Move actions (one for each endpoint) |
| **Linear Stretch Pair** | Linear parameter + 2 Stretch actions (one for each endpoint) |
| **Polar Move** | Polar parameter + Move action |
| **Polar Stretch** | Polar parameter + Stretch action |
| **Polar Array** | Polar parameter + Array action |
| **Polar Move Pair** | Polar parameter + 2 Move actions (endpoints) |
| **Polar Stretch Pair** | Polar parameter + 2 Stretch actions (endpoints) |
| **XY Move** | XY parameter + Move action (endpoint) |
| **XY Move Pair** | XY parameter + 2 Move actions (base + endpoint) |
| **XY Move Box Set** | XY parameter + 4 Move actions (one per key point) |
| **XY Stretch Box Set** | XY parameter + 4 Stretch actions (one per key point) |
| **XY Array Box Set** | XY parameter + Array action |
| **Rotation Set** | Rotation parameter + Rotate action |
| **Flip Set** | Flip parameter + Flip action |
| **Visibility Set** | Visibility parameter (no action needed) + visibility state setup |
| **Lookup Set** | Lookup parameter + Lookup action |

### 7.3 Post-Creation Workflow

After inserting a parameter set:
1. Right-click the action's exclamation icon (or use `BACTIONSET`).
2. Select "Action Selection Set > New Selection Set."
3. Select the geometry objects that the action should affect.
4. Press Enter to confirm.

---

## 8. Dynamic Blocks — Value Sets

### 8.1 Overview

Value Sets constrain the allowable values for a parameter. They define discrete values or ranges that a parameter can take, preventing users from setting arbitrary values.

### 8.2 Value Set Types

| Type | Description | Behavior |
|------|-------------|----------|
| **None** | No constraint. Any value is allowed. | Continuous range. |
| **List** | A defined set of discrete values. | Grip snaps to nearest listed value. Properties palette shows dropdown. |
| **Increment** | Values must be multiples of a specified increment within a range. | Grip snaps to nearest increment. |

### 8.3 List Value Set

**Configuration**:
- List of explicit values (e.g., 24, 30, 36, 42, 48 for door widths in inches).
- Each value is a discrete allowed position.

**Behavior in drawing**:
- Dragging the grip snaps to the nearest listed value.
- The Properties palette shows a dropdown of all listed values.
- Values are displayed in the block's unit format.

### 8.4 Increment Value Set

**Configuration**:
- **Minimum value**: Lower bound.
- **Maximum value**: Upper bound.
- **Increment**: Step size between values.

**Behavior in drawing**:
- The parameter value snaps to the nearest increment within the min/max range.
- Example: Min=12, Max=48, Increment=6 → Allowed values: 12, 18, 24, 30, 36, 42, 48.

### 8.5 Value Set on Specific Parameter Types

| Parameter | Value Set Applies To |
|-----------|---------------------|
| Linear | Distance value |
| Polar | Distance value, Angle value (separate value sets) |
| XY | Horizontal distance, Vertical distance (separate value sets) |
| Rotation | Angle value |

**Note**: Point, Alignment, Flip, Visibility, Lookup, and Base Point parameters do not support value sets (their values are controlled differently).

### 8.6 Visual Feedback

When value sets are defined:
- In the Block Editor, grip locations show small tick marks at allowed positions.
- In the drawing, the grip snaps to allowed positions as the user drags.

---

## 9. Dynamic Blocks — Visibility States

### 9.1 Overview

Visibility states control which objects within a block are visible at any given time. Each state has a name and a defined set of visible/invisible objects. The user switches between states using a dropdown grip in the drawing.

### 9.2 Creating Visibility States

**Prerequisite**: A visibility parameter must exist in the block (only one allowed per block).

#### Using BVSTATE command or the Visibility States dialog:

| Action | Description |
|--------|-------------|
| **New** | Creates a new visibility state. Options: leave visibility of existing objects unchanged in new state, or show all existing objects, or hide all existing objects. |
| **Rename** | Renames an existing state. |
| **Delete** | Removes a state (at least one must remain). |
| **Move Up / Move Down** | Reorders states in the dropdown list. |
| **Set Current** | Sets the active state in the Block Editor for editing. |

### 9.3 Managing Object Visibility Per State

In the Block Editor:

1. Set the desired visibility state as current (dropdown on the ribbon).
2. Draw or select objects.
3. Use `BVSHOW` to make selected objects visible in the current state (or all states).
4. Use `BVHIDE` to make selected objects invisible in the current state (or all states).

**`BVMODE` system variable**: Controls the display of invisible objects in the Block Editor.
- **0**: Invisible objects are not shown at all.
- **1**: Invisible objects are shown as dimmed/faded (for reference).

### 9.4 Behavior in Drawing

- When the user clicks the visibility grip on a block reference, a dropdown appears listing all state names.
- Selecting a state name immediately updates the display — objects assigned as visible for that state appear; others disappear.
- The current state is also accessible via the Properties palette.

### 9.5 Rules and Constraints

| Rule | Description |
|------|-------------|
| One visibility parameter per block | You cannot have multiple visibility parameters. |
| At least one state required | The block must have at least one visibility state defined. |
| Default state | The first state in the list is the default when the block is inserted. |
| Objects can be in multiple states | The same geometry can be visible in several states. |
| New objects default behavior | When you create new geometry while a state is current, the object is visible in that state. You must explicitly add it to other states with BVSHOW. |
| Interaction with other parameters | Visibility states combine with other dynamic parameters. A block can be both stretchable and have visibility states. |

### 9.6 Common Use Case: Multi-Configuration Block

Example — a valve block with three configurations:
- **State "Gate Valve"**: Shows gate valve geometry.
- **State "Ball Valve"**: Shows ball valve geometry.
- **State "Check Valve"**: Shows check valve geometry.

All three geometries exist in the block definition. Each state makes one set visible and hides the others.

---

## 10. Dynamic Blocks — Lookup Tables

### 10.1 Overview

A lookup table maps combinations of parameter values to named configurations. It's accessed via the `BLOOKUPTABLE` command in the Block Editor.

### 10.2 Table Structure

The lookup table is a grid:

| Column Type | Description |
|-------------|-------------|
| **Input Properties** | Existing parameter values from the block (e.g., Width, Height, Angle). These are read from the block's current state. |
| **Lookup Properties** | Output values displayed in the lookup parameter's dropdown. Can be simple labels or mapped values. |

**Example: Door block lookup table**

| Width (Input) | Height (Input) | Door Size (Lookup) |
|--------------|---------------|-------------------|
| 30 | 80 | 2'-6" x 6'-8" |
| 32 | 80 | 2'-8" x 6'-8" |
| 36 | 80 | 3'-0" x 6'-8" |
| 36 | 84 | 3'-0" x 7'-0" |

### 10.3 Behavior

**Forward lookup** (user selects from dropdown):
- User clicks the lookup grip → dropdown shows all values from the Lookup column.
- Selecting "3'-0" x 6'-8"" automatically sets Width=36, Height=80.

**Reverse lookup** (user changes a parameter):
- If the user stretches the block to Width=32, Height=80, the lookup property automatically updates to "2'-8" x 6'-8"".
- If the parameter combination doesn't match any row, the lookup displays "<Unmatched>".

### 10.4 Allow Reverse Lookup Property

A checkbox "Allow Reverse Lookup" controls whether changing input parameters can drive the lookup:
- **Checked**: Changes to input parameters update the lookup display.
- **Unchecked**: The lookup only works one-way (user must select from dropdown).

### 10.5 Adding Custom Values

The lookup table can include an option to allow custom values not in the table. When unchecked, only the defined values are allowed, effectively constraining the block to specific configurations.

---

## 11. Dynamic Blocks — Constraints

> **⚠️ AutoCAD LT Limitation**: Geometric and dimensional constraints in dynamic blocks are **NOT available in AutoCAD LT**. The Constraints tab on the Block Authoring Palette is not shown. Users of LT can **use** blocks that contain constraints (created in full AutoCAD), but cannot **create or edit** them.

### 11.1 Overview (Full AutoCAD Only)

Constraints in dynamic blocks establish geometric and dimensional relationships between objects. They are similar to parametric constraints in the regular drawing environment but work within the block definition.

### 11.2 Geometric Constraints

Applied via the Constraints tab → Geometric section:

| Constraint | Description |
|-----------|-------------|
| **Coincident** | Constrains two points together or a point to a curve. |
| **Perpendicular** | Two lines must be at 90° to each other. |
| **Parallel** | Two lines must be parallel. |
| **Tangent** | Two curves must be tangent. |
| **Horizontal** | A line or point pair must be parallel to the X axis. |
| **Vertical** | A line or point pair must be parallel to the Y axis. |
| **Collinear** | Two or more line segments must lie on the same infinite line. |
| **Concentric** | Two arcs/circles must share the same center point. |
| **Smooth** | A spline maintains G2 continuity with another curve. |
| **Symmetric** | Objects are symmetric about a line. |
| **Equal** | Arcs/circles have equal radii, or lines have equal lengths. |
| **Fix** | Locks a point or curve in absolute position. |

### 11.3 Constraint Parameters (Dimensional)

Constraint parameters combine a dimensional constraint with a parameter, enabling them to be exposed as custom grips and properties:

| Constraint Parameter | Description |
|---------------------|-------------|
| **Aligned** | Constrains length of a line or distance between two objects. |
| **Horizontal** | Constrains the X distance. |
| **Vertical** | Constrains the Y distance. |
| **Angular** | Constrains the angle between two lines. |
| **Radial** | Constrains the radius of a circle/arc. |
| **Diameter** | Constrains the diameter of a circle/arc. |

**Key behavior**: Constraint parameters can have custom grip counts (0, 1, or 2 grips). A constraint parameter with 0 grips cannot be edited by grip manipulation but can still be changed via the Properties palette.

### 11.4 Interaction with Parameters and Actions

Constraints can **conflict** with parameters and actions. When a constraint prevents a parameter from reaching a requested value, the constraint takes precedence.

**Note**: "It is possible to create constraints that conflict with parameters and actions." — always test thoroughly after adding constraints.

---

## 12. Dynamic Blocks — Block Properties Table

> **⚠️ AutoCAD LT Limitation**: The Block Properties Table (`BTABLE`) is **NOT available in AutoCAD LT**.

### 12.1 Overview (Full AutoCAD Only)

The Block Properties Table (`BTABLE`) defines a spreadsheet-like table of allowed variations for a block. Each row represents a valid configuration, and each column corresponds to a block parameter or attribute.

### 12.2 How It Differs from Lookup Table

| Feature | Lookup Table (BLOOKUPTABLE) | Block Properties Table (BTABLE) |
|---------|---------------------------|-------------------------------|
| Availability | AutoCAD and LT | AutoCAD only |
| UI | Grid within the block editor | Dedicated dialog box |
| Purpose | Maps input parameters to output label | Defines complete block configurations |
| Constraint | Values outside table may be allowed | Can restrict to table values only |
| Attributes | Cannot set attribute values | Can set attribute values |

### 12.3 Usage

The table defines explicit parameter/attribute value combinations. When a user selects a block reference, they can choose from the defined configurations via the Properties palette.

---

## 13. Dynamic Blocks — Advanced Behaviors

### 13.1 Chain Actions

**Property**: `Chain Actions` (set per parameter)

When Chain Actions is set to **Yes** for a parameter:
- If an action triggered by this parameter moves an object that contains or is associated with another parameter, that secondary parameter's actions are also triggered.
- Creates a cascading effect where one grip manipulation triggers multiple parameter changes.

**Example**: A stretch action moves a point parameter. If the point parameter has Chain Actions = Yes and its own move action, the objects in the move action's selection set also move.

**Warning**: Circular chains can cause unexpected behavior. AutoCAD detects and warns about circular references.

### 13.2 Grip Cycling Order (BCYCLEORDER)

When multiple grips overlap or are close together, the user can cycle through them by pressing Ctrl. `BCYCLEORDER` defines the cycling order.

### 13.3 Action Selection Sets

The selection set of an action determines which objects are affected. Selection sets can include:
- Regular geometry (lines, arcs, circles, etc.)
- Other parameters (their grip locations move with the action)
- Other actions (their effect areas move with the action)
- Attributes
- Construction geometry (won't display but affects behavior)

### 13.4 Distance Multiplier and Angle Offset

These override properties are available on Move, Stretch, and Polar Stretch actions:

| Property | Description |
|----------|-------------|
| **Distance Multiplier** | A factor applied to the grip movement distance. Default = 1.0. Value of 0.5 = objects move half the grip distance. Value of 2.0 = objects move twice the grip distance. |
| **Angle Offset** | An angle added to the grip movement direction. Default = 0°. Value of 90° = objects move perpendicular to the grip direction. |

**Set via**: Properties palette when an action is selected in the Block Editor, or via command prompts when adding the action.

### 13.5 Grip Types

Dynamic blocks can display different grip types:

| Grip Shape | Meaning |
|-----------|---------|
| **Square (Standard)** | Move/stretch/scale grip (from point, linear, polar, XY parameters) |
| **Circle (Rotation)** | Rotation grip |
| **Triangle (Arrow)** | Flip grip |
| **Down-Arrow (Dropdown)** | Visibility or Lookup parameter grip — click to show a list |
| **Alignment** | Alignment grip — drag near objects to auto-align |

### 13.6 Number of Grips Per Parameter

Many parameters support configuring how many grips are displayed:
- **0 grips**: Parameter can only be modified via the Properties palette.
- **1 grip**: Only one key point has a grip (usually the endpoint).
- **2 grips**: Both endpoints have grips (for Linear, Polar, XY).

---

## 14. Block Attributes

### 14.1 Overview

Attributes are **data fields** embedded in blocks. They store text-based information (part numbers, descriptions, prices, room numbers, etc.) that can vary per block reference.

### 14.2 Attribute Definition (ATTDEF)

**Command**: `ATTDEF`  
**Ribbon**: Home tab → Block panel → Define Attributes  
**Dialog**: Attribute Definition dialog box

#### Mode Options

| Mode | Description |
|------|-------------|
| **Invisible** | Attribute value is not displayed or printed in the drawing. `ATTDISP` command can override to show all. |
| **Constant** | Fixed value that cannot be changed per block reference. Used for information that never varies. |
| **Verify** | User is prompted to verify the value is correct during insertion (confirmation step). |
| **Preset** | Attribute is set to its default value without prompting the user. Only applies when `ATTDIA = 0` (command-line prompting). |
| **Lock Position** | When checked, the attribute's position within the block is locked — it cannot be moved independently using grip editing. When unchecked, the user can reposition the attribute relative to the block geometry. |
| **Multiple Lines** | Allows the attribute value to contain multiple lines of text. Enables setting a boundary width for text wrapping. |

**Default mode values are stored in the `AFLAGS` system variable.**

#### Data Fields

| Field | Description |
|-------|-------------|
| **Tag** | The identifier for the attribute. Displayed in the drawing as placeholder text before the block is created. Used as the column header in data extraction. Must be unique within the block. Cannot contain spaces. |
| **Prompt** | The message displayed to the user during block insertion to request the attribute value. |
| **Default** | The default value assigned if the user doesn't provide one. Can contain field expressions for auto-updating values. |

#### Text Settings

| Setting | Description |
|---------|-------------|
| **Justification** | Text alignment (Left, Center, Right, Middle, Fit, Align, etc.) |
| **Text Style** | References a defined text style. |
| **Annotative** | If checked, attribute scales with annotation scale. |
| **Text Height** | Height of the attribute text. |
| **Rotation** | Rotation angle of the text. |
| **Boundary Width** | (Multiple Lines only) Maximum line width before wrapping. 0 = no limit. |

#### Insertion Point

- Can be specified by coordinates or picked on screen.
- **Align Below Previous Attribute Definition**: Automatically positions below the last-defined attribute.

### 14.3 Editing Attributes

#### Methods

| Command | Description | Dialog? |
|---------|-------------|---------|
| **Double-click block** | Opens the Enhanced Attribute Editor (EATTEDIT) | ✓ |
| **EATTEDIT** | Edit attributes of a single block reference (values, text options, properties) | ✓ |
| **ATTEDIT / -ATTEDIT** | Edit attributes globally across multiple blocks. Can change values, positions, heights, angles, styles, layers, colors. | Command-line or dialog |
| **BATTMAN** | Block Attribute Manager — edit attribute definitions for a block (order, modes, tag names, prompts, defaults). Changes the definition, not individual reference values. | ✓ |
| **Properties palette** | Select a block reference, scroll to Attributes section, edit values directly. | N/A |

#### Enhanced Attribute Editor (EATTEDIT) Tabs

| Tab | Controls |
|-----|----------|
| **Attribute** | Mode flags, Tag, Prompt, Default value |
| **Text Options** | Text Style, Justification, Height, Rotation, Width Factor, Oblique Angle, Annotative, Backwards, Upside Down, Boundary Width |
| **Properties** | Layer, Color, Linetype, Lineweight, Plot Style |

### 14.4 Attribute Sync (ATTSYNC)

**Command**: `ATTSYNC`

Synchronizes attribute definitions in a block definition with all existing block references. Use this after:
- Adding new attribute definitions to a block
- Removing attribute definitions
- Changing attribute order, modes, or positions

**Behavior**:
- Existing attribute values are preserved for matching tags.
- New attributes get their default values.
- Removed attributes are deleted from references.
- Position, mode, and text properties are updated to match the current definition.

### 14.5 Attribute Order (BATTORDER)

**Command**: `BATTORDER` (in Block Editor)

Controls the prompt order of attributes during block insertion. Attributes are listed in order — use Move Up/Move Down to reorder.

### 14.6 Attribute Display Control

| Command/Variable | Description |
|-----------------|-------------|
| **ATTDISP** | Controls visibility of all attributes: Normal (respect Invisible mode), ON (show all, even invisible), OFF (hide all). |
| **ATTDIA** | System variable. 0 = attribute prompts appear on the command line. 1 = attribute prompts appear in a dialog box. |
| **ATTREQ** | System variable. 0 = attributes are set to default values without prompting. 1 = user is prompted for values. |

### 14.7 Extracting Attribute Data

#### DATAEXTRACTION Command

A multi-page wizard that extracts attribute data (and other block/object properties) into:
- A **table object** in the drawing
- An external **CSV file**
- Both

**Wizard steps**:
1. Create new or use existing data extraction settings (.DXE file)
2. Define data source (current drawing, external files, sheet sets)
3. Select object types (filter to blocks only)
4. Select properties/attributes to extract
5. Refine data (reorder, rename, hide columns, add formulas)
6. Choose output (table in drawing and/or external file)
7. Set table style and title

**Data extraction settings (.DXE file)** can be reused for recurring extractions.

**Auto-update**: Tables linked to data extractions can be refreshed via right-click → "Update Table Data Links" when blocks are added or modified.

#### EATTEXT (Attribute Extraction - Legacy)

Older extraction method. Extracts to TXT, CSV, XLS, or MDB format. Still functional but DATAEXTRACTION is preferred.

> **AutoCAD LT Note**: `DATAEXTRACTION` is available in LT. `EATTEXT` is available in LT. `ATTOUT`/`ATTIN` (Express Tools export/import) are **not available** in LT.

### 14.8 Field Attributes

Attribute default values can contain **field expressions** that auto-update:
- Date/time fields
- Document properties (filename, file size, author)
- Object properties (references to other object values)
- Sheet set fields

**Behavior**: Field values update when the drawing is regenerated, saved, plotted, or when UPDATEFIELD is executed.

**Important**: Fields within attributes in dynamic blocks require a regen to update when the block's dynamic properties change. Adding a dynamic action (even a dummy one) can force field updates.

---

## 15. External References (Xrefs)

### 15.1 Overview

External References (xrefs) are DWG drawings referenced by another drawing. Unlike blocks, xrefs maintain a **live link** to the source file — changes in the source automatically update in the host drawing.

### 15.2 Xref vs Block

| Feature | Block | Xref |
|---------|-------|------|
| Storage | Embedded in drawing file | Linked to external file |
| Updates | Manual (re-insert to update) | Automatic on reload |
| File size impact | Full geometry stored in host | Only link stored; geometry loaded on demand |
| Nesting | Blocks can contain blocks | Xrefs can contain xrefs |
| Editing | Edit in Block Editor | Edit in place (REFEDIT) or edit source file |
| Named objects | Merged into host drawing | Prefixed with xref name (e.g., `FloorPlan|Layer1`) |

### 15.3 Attach vs Overlay

| Type | Description |
|------|-------------|
| **Attachment** | The xref is **included** if the host drawing is itself referenced by another drawing. Creates a nested reference chain. |
| **Overlay** | The xref is **NOT included** if the host drawing is referenced by another drawing. Only visible in the immediate host. |

**Use case**: Overlay is commonly used for background references (like a floor plan) that shouldn't cascade through multiple levels of referencing.

### 15.4 Xref Commands

| Command | Description |
|---------|-------------|
| **XATTACH** | Attaches an external reference (DWG file) |
| **XREF / EXTERNALREFERENCES** | Opens the External References palette |
| **XBIND** | Binds individual named objects from an xref |
| **XCLIP / CLIP** | Clips an xref to a boundary |

### 15.5 Attaching an Xref

**Attach dialog settings**:

| Setting | Description |
|---------|-------------|
| **Reference Type** | Attachment or Overlay |
| **Path Type** | Full path, Relative path, or No path (filename only — must be findable via search paths) |
| **Insertion Point** | X, Y, Z coordinates (can specify on screen) |
| **Scale** | X, Y, Z scale factors. Uniform scale option. |
| **Rotation** | Angle |

### 15.6 Path Types

| Path Type | Description | When to Use |
|-----------|-------------|-------------|
| **Full Path** | Absolute file path (e.g., `C:\Projects\Floor1.dwg`) | When files never move |
| **Relative Path** | Path relative to host drawing (e.g., `..\xrefs\Floor1.dwg`) | When project folder structure is maintained |
| **No Path** | Just the filename (e.g., `Floor1.dwg`) | When files are in the same folder or on AutoCAD's search path |

### 15.7 Xref States

| Status | Description |
|--------|-------------|
| **Loaded** | Xref is found and displayed |
| **Unloaded** | Xref link exists but geometry is not loaded (saves memory) |
| **Not Found** | Xref file cannot be located at the saved path |
| **Unresolved** | Xref exists but cannot be read (corrupt, locked, etc.) |
| **Orphaned** | Xref was nested inside another xref that has been detached |

### 15.8 Binding Xrefs

**Bind** converts an xref into a regular block, making it a permanent part of the drawing:

| Bind Type | Named Object Handling |
|-----------|---------------------|
| **Bind** | Named objects (layers, styles, etc.) are prefixed with `xrefname$0$originalname`. Avoids conflicts. |
| **Insert** | Named objects are merged with host drawing's objects. Duplicates use the host's version. |

**Behavior**: After binding, the xref link is severed. The geometry is now a local block. Changes to the original file no longer propagate.

**Individual binding** (`XBIND`): Binds individual named objects (layers, linetypes, dimension styles, etc.) from an xref without binding the entire reference.

### 15.9 Clipping Xrefs

**Command**: `XCLIP` or `CLIP`

Clips the xref display to a defined boundary:

| Boundary Type | Description |
|--------------|-------------|
| **Rectangular** | Two opposite corner points |
| **Polygonal** | Multiple vertex points forming a polygon |
| **Select Polyline** | Use an existing polyline as the boundary (must be non-self-intersecting, straight segments) |

**Additional options**:
- **On/Off**: Toggle clipping without deleting the boundary.
- **Delete**: Remove the clip boundary entirely.
- **Invert Clip**: Show what's outside the boundary instead of inside.
- **Clip Depth**: For 3D — set front and back clipping planes.
- **Generate Polyline**: Create a polyline matching the existing clip boundary (for editing, then redefining the clip).

**`FRAME` system variable**: Controls whether clip boundaries are visible (0=invisible, 1=displayed, 2=displayed but not plotted).

### 15.10 Demand Loading

| System Variable | Value | Description |
|----------------|-------|-------------|
| **XLOADCTL** | 0 | Demand loading disabled. Entire xref loaded. |
| | 1 | Demand loading enabled. Only needed portions loaded. Others can edit the xref file. |
| | 2 | Demand loading enabled with file copy. AutoCAD copies the xref and references the copy, so the original file is unlocked for editing by others. |

### 15.11 Xref Notification

The `XREFNOTIFY` system variable controls notification when xrefs are modified:
- **0**: No notification.
- **1**: Balloon notification when modified xrefs are detected.
- **2**: Balloon notification for modified and missing xrefs.

### 15.12 Xref Fading

`XDWGFADECTL` controls the fading percentage of xref geometry to visually distinguish it from the current drawing's objects (0–90).

---

## 16. In-Place Reference Editing (REFEDIT)

### 16.1 Overview

**Command**: `REFEDIT`  
Allows editing an xref or block reference directly within the host drawing without opening the source file separately.

### 16.2 Workflow

1. **Select reference**: Click on the xref or block to edit.
2. **Choose nesting level**: If the selected object is within a nested reference, cycle through available references with Next/OK.
3. **Attribute handling**: If editing a block with attributes, choose whether to display attribute definitions for editing. (Attributes are temporarily hidden; attribute definitions become visible and editable.)
4. **Select working set**: Choose which objects within the reference to include in the editing session:
   - **All**: All objects in the reference.
   - **Nested**: Manually select specific objects.
5. **Edit objects**: Modify geometry in the working set. Non-working-set objects are faded (controlled by `XFADECTL`).
6. **Save back**: Use `REFCLOSE` → Save to commit changes back to the reference. For xrefs, the source DWG file is updated. For blocks, the block definition is updated.

### 16.3 Limitations

- Cannot have multiple simultaneous REFEDIT sessions.
- Reference file is locked during editing (other users cannot edit it).
- Some operations are restricted in the REFEDIT state.
- For blocks with attributes: changes to attribute definitions only affect new insertions, not existing references (use ATTSYNC separately).

---

## 17. Block Libraries & Content Management

### 17.1 DesignCenter (ADCENTER)

**Command**: `ADCENTER` (Ctrl+2)

A file-browser-like panel for navigating and importing named objects from any DWG file:
- **Browse tab**: Navigate folders/files/network locations.
- **Content**: View blocks, layers, layouts, linetypes, text styles, dimension styles, xrefs from any DWG.
- **Insert**: Double-click a block to insert it. Drag-and-drop is also supported.
- **Redefine**: Right-click a block → Redefine, to update the block definition in the current drawing with the one from the source.

### 17.2 Tool Palettes (TOOLPALETTES)

**Command**: `TOOLPALETTES` (Ctrl+3)

Customizable palette window with tabbed groups:
- **Block tools**: Drag blocks from DesignCenter onto a palette. Each tool stores the block's source, scale, rotation, and layer override.
- **Custom properties**: Each tool can have preset property overrides (layer, color, scale, rotation).
- **Organization**: Create tabs for categories (electrical, furniture, plumbing, etc.).
- **Sharing**: Palettes can be exported/imported as XML files for team standardization.

### 17.3 Blocks Palette (BLOCKSPALETTE)

The modern interface for block management:
- **Current Drawing tab**: All blocks in the active drawing.
- **Recent tab**: Blocks recently used across any drawing (can sync to Autodesk account).
- **Favorites tab**: User-saved favorite blocks.
- **Libraries tab**: Browse blocks from a folder or drawing file. Can point to cloud storage for cross-device access.

### 17.4 Block Library Organization Best Practices

Blocks can be organized as:
1. **Block library drawings**: A single DWG file containing many block definitions (no references placed — just definitions).
2. **Folder of DWG files**: Each DWG file is one block. The folder serves as the library.
3. **Template files (.dwt)**: Include commonly used blocks so they're available in every new drawing.

---

## 18. Nested Blocks

### 18.1 Definition

A nested block is a block that contains references to other blocks within its definition. Nesting can be multiple levels deep (block A contains block B, which contains block C).

### 18.2 Behavior

| Aspect | Behavior |
|--------|----------|
| **Display** | Nested blocks display as part of the parent block. |
| **Selection** | Clicking on a nested block selects the outermost block. Use Ctrl+Click to select nested blocks directly (when not in REFEDIT). |
| **Exploding** | Exploding a block that contains nested blocks converts the parent to individual objects and nested block references. Nested blocks remain as blocks (not fully exploded in one step). |
| **Redefining** | Redefining an inner block updates all instances, including those nested within other blocks. |
| **Properties** | BYBLOCK properties in nested blocks resolve to the containing block's properties, not the outermost block. For BYBLOCK to cascade through all levels, every nesting level must use BYBLOCK. |

### 18.3 Limitations

- Blocks cannot contain references to themselves (no circular references).
- Deep nesting can impact performance.
- Some operations (like attribute editing) behave differently with nested blocks.

---

## 19. Anonymous Blocks

### 19.1 Definition

Anonymous blocks are unnamed blocks automatically created by AutoCAD for internal use. They have names starting with `*` followed by a letter and a number (e.g., `*U1`, `*D5`, `*X10`).

### 19.2 Types of Anonymous Blocks

| Prefix | Created By |
|--------|-----------|
| **\*U** | Dynamic blocks (each unique configuration generates an anonymous block) |
| **\*D** | Dimensions |
| **\*A** | Associative hatches |
| **\*T** | Tables |
| **\*X** | Other internal uses |
| **\*E** | Non-uniformly scaled blocks |
| **\*Model_Space** | Model space |
| **\*Paper_Space** | Paper space layouts |

### 19.3 Dynamic Blocks and Anonymous Blocks

When a dynamic block reference is modified (parameters changed), AutoCAD creates an anonymous block (`*U##`) to represent that specific configuration. The block reference's `EffectiveName` property still shows the original dynamic block name, but the internal `Name` property shows the anonymous block name.

**Implications for developers**:
- Use `EffectiveName` (or `IsDynamicBlock` property) to identify dynamic blocks, not the raw block name.
- Anonymous blocks for dynamic blocks should not be exposed to users.
- Purging unused anonymous blocks is handled automatically by AutoCAD in most cases.

### 19.4 Handling Anonymous Blocks

- Anonymous blocks **cannot** be inserted by name (the `*` prefix prevents it).
- They **can** be seen in block counts and property queries.
- They are **automatically cleaned up** when no longer referenced (or via PURGE).

---

## 20. Modifying Block Definitions

### 20.1 Methods

| Method | Description | Updates Existing References? |
|--------|-------------|------------------------------|
| **Block Editor (BEDIT)** | Full editing environment. Save to update. | Yes, immediately. |
| **In-place editing (REFEDIT)** | Edit within the drawing context. Save back to update. | Yes, immediately. |
| **Redefine via BLOCK command** | Create a new definition with the same name. | Yes, immediately. |
| **Insert from external source** | DesignCenter → Redefine. | Yes, after redefine. |
| **Explode + Modify + Recreate** | Explode a reference, edit objects, create new BLOCK with same name. | Yes, after recreation. |

### 20.2 What Happens When a Block is Redefined

1. All references to the block in the drawing are immediately updated to show the new geometry.
2. Existing attribute **values** are preserved (they don't reset to defaults).
3. New attribute definitions only appear in subsequently inserted references.
4. Use `ATTSYNC` to propagate new/changed attribute definitions to existing references.
5. Dynamic properties may reset if the parameter structure changes significantly.

### 20.3 Updating Blocks from External Files

Blocks originally inserted from external files are **not automatically updated** when the source file changes (unlike xrefs). To update:
1. Use DesignCenter to reinsert the block with "Redefine" option.
2. Or: Delete the old block definition (PURGE), then INSERT the external file again.

---

## 21. Purging and Cleanup

### 21.1 PURGE Command

**Command**: `PURGE`  
Removes unused named objects from the drawing, including:
- Block definitions (not referenced by any block references)
- Layers, linetypes, text styles, dimension styles, table styles, multileader styles, etc.

#### Options

| Option | Description |
|--------|-------------|
| **View items you can purge** | Shows unused items that can be removed. |
| **View items you cannot purge** | Shows items in use with reasons why they can't be removed. |
| **Purge Nested Items** | Also purges unused items nested within other unused items. |
| **Confirm each item** | Prompts for confirmation before each deletion. |

#### Purge Unnamed Objects Options

| Option | Description |
|--------|-------------|
| **Zero-length geometry** | Deletes lines, arcs, circles, polylines of zero length. |
| **Empty text objects** | Deletes blank text or text containing only spaces. |
| **Orphaned data** | Removes obsolete DGN linestyle data. |

### 21.2 Items That Cannot Be Purged

- Block definitions with existing references in the drawing.
- Layer 0 and Defpoints layer.
- The current layer, text style, dimension style, linetype.
- Named objects referenced by other objects.
- Blocks on locked layers cannot have their unnamed objects purged.

### 21.3 -PURGE Command (Command Line)

Provides a command-line interface for purging. Prompts:
```
Enter type of unused objects to purge [Blocks/DEtailviewstyles/Dimstyles/Groups/LAyers/LTypes/MAterials/MUltileaderstyles/Plotstyles/SHapes/textSTyles/Mlinestyles/SEctionviewstyles/TAblestyles/Visualstyles/Regapps/Zero-length geometry/Empty text objects/All]:
```

---

## 22. AutoCAD LT Limitations

### 22.1 Dynamic Blocks in LT — The Key Distinction

| Capability | AutoCAD LT | Full AutoCAD |
|-----------|------------|-------------|
| **Use/insert dynamic blocks** | ✓ Yes | ✓ Yes |
| **Manipulate dynamic block grips** | ✓ Yes | ✓ Yes |
| **Change dynamic properties via Properties palette** | ✓ Yes | ✓ Yes |
| **Create dynamic blocks (parameters, actions)** | ✓ Yes | ✓ Yes |
| **Edit dynamic blocks in Block Editor** | ✓ Yes | ✓ Yes |
| **Add geometric constraints in Block Editor** | ✗ No | ✓ Yes |
| **Add dimensional constraint parameters (BCPARAMETER)** | ✗ No | ✓ Yes |
| **Block Properties Table (BTABLE)** | ✗ No | ✓ Yes |
| **Auto-constrain objects (AUTOCONSTRAIN)** | ✗ No | ✓ Yes |

> **Important clarification**: Despite what some third-party sources claim, AutoCAD LT **CAN create and edit dynamic blocks** — it supports parameters, actions, parameter sets, visibility states, lookup tables, and all the features described in Sections 5–10. The specific limitations are around **parametric constraints** (geometric and dimensional) and the **Block Properties Table**, which are full-AutoCAD-only features.

### 22.2 Other Block-Related LT Limitations

| Feature | LT Availability |
|---------|----------------|
| **ATTREDEF** (redefine block attributes) | ✗ Not available |
| **Express Tools** (ATTOUT/ATTIN, etc.) | ✗ Not available |
| **API/VBA/ActiveX for blocks** | ✗ Limited (no .NET, limited AutoLISP, no VBA IDE) |
| **Action Recorder** | ✗ Not available |
| **3D block geometry** | ✗ LT is 2D only |
| **Vault integration** (version control) | ✗ Not available |
| **Xref Compare** | ✗ Not available |
| **Data Extraction (DATAEXTRACTION)** | ✓ Available |
| **DesignCenter** | ✓ Available |
| **Tool Palettes** | ✓ Available |
| **Blocks Palette** | ✓ Available |
| **REFEDIT (in-place editing)** | ✓ Available |
| **Xrefs (attach, overlay, bind, clip)** | ✓ Available |

### 22.3 Behavioral Differences

- When LT opens a drawing containing blocks with constraints (created in full AutoCAD), the constraints are **preserved and functional** — the block behaves correctly. The user just can't modify those constraints.
- LT does not have the Constraints tab in the Block Authoring Palettes.
- LT cannot create user parameters of type "Area" or "Volume" (these require dimensional constraint parameters).

---

## 23. DWG File Format — Block Storage

### 23.1 Block Table

The DWG file maintains a **Block Table** — a symbol table that stores all block definitions in the drawing.

| Component | Description |
|-----------|-------------|
| **Block Table** | The master container. One per drawing. |
| **Block Table Records** | Individual block definitions. Each record contains the block name, base point, and a list of entity handles (the objects that make up the block). |
| **Model Space** | Stored as a special block table record named `*Model_Space`. |
| **Paper Space** | Each layout has a block table record named `*Paper_Space` or `*Paper_Space0`, etc. |

### 23.2 Object Relationships

| Relationship | Description |
|-------------|-------------|
| **Block Definition → Entities** | A block table record "owns" the entities (lines, arcs, etc.) that define the block geometry. |
| **Block Reference → Block Definition** | A block reference (INSERT entity) points to a block table record by handle/object ID. |
| **Attribute Reference → Attribute Definition** | An attribute reference within a block reference points back to the attribute definition in the block table record. |
| **Dynamic Block → Anonymous Blocks** | Dynamic block references with modified parameters create anonymous block table records (`*U##`). The effective name property links back to the original dynamic block definition. |

### 23.3 Handles and Object IDs

Every object in a DWG file has:
- A **handle**: A persistent hexadecimal identifier that remains constant across saves.
- An **object ID**: A session-specific memory address (not persistent across sessions).

Block references store the handle of their block definition. This handle-based linking is how AutoCAD resolves which block definition a reference points to.

### 23.4 Block Scaling and Transformation

Each block reference stores a transformation matrix that includes:
- Translation (insertion point offset from 0,0,0)
- Scale (X, Y, Z factors)
- Rotation (around the Z axis)

The geometry displayed is the block definition's geometry transformed by this matrix.

### 23.5 Purging in Terms of DWG Structure

When PURGE removes a block:
- The block table record is deleted.
- All owned entities within the record are deleted.
- Handles are not reassigned to new objects.
- The file size reduction is realized after the next save.

---

## 24. Commands Reference

### 24.1 Block Creation & Definition Commands

| Command | Description | Dialog? | LT? |
|---------|-------------|---------|-----|
| `BLOCK` | Creates a block definition from selected objects | ✓ | ✓ |
| `-BLOCK` | Command-line version of BLOCK | – | ✓ |
| `WBLOCK` | Writes objects/blocks to an external DWG file | ✓ | ✓ |
| `-WBLOCK` | Command-line version of WBLOCK | – | ✓ |
| `BEDIT` | Opens the Block Editor for a block definition | ✓ (select block dialog) | ✓ |
| `BCLOSE` | Closes the Block Editor | – | ✓ |
| `BSAVE` | Saves the current block definition in the Block Editor | – | ✓ |
| `BSAVEAS` | Saves the block definition under a new name | ✓ | ✓ |

### 24.2 Block Insertion Commands

| Command | Description | Dialog? | LT? |
|---------|-------------|---------|-----|
| `INSERT` | Inserts a block (opens ribbon gallery) | Gallery | ✓ |
| `-INSERT` | Command-line block insertion | – | ✓ |
| `CLASSICINSERT` | Opens the classic Insert dialog box | ✓ | ✓ |
| `MINSERT` | Inserts a block in a rectangular array pattern (result cannot be exploded) | – | ✓ |
| `BLOCKSPALETTE` / `CONTENT` | Opens the Blocks palette | Palette | ✓ |
| `ADCENTER` | Opens DesignCenter | Panel | ✓ |
| `TOOLPALETTES` | Opens Tool Palettes | Panel | ✓ |

### 24.3 Block Editing Commands

| Command | Description | Dialog? | LT? |
|---------|-------------|---------|-----|
| `REFEDIT` | Edits a block or xref in place | ✓ | ✓ |
| `-REFEDIT` | Command-line version of REFEDIT | – | ✓ |
| `REFCLOSE` | Saves or discards REFEDIT changes | – | ✓ |
| `REFSET` | Adds/removes objects from the REFEDIT working set | – | ✓ |
| `EXPLODE` | Breaks a block reference into component objects | – | ✓ |
| `XPLODE` | Explode with control over resulting properties | – | ✗ (Express Tool) |
| `BURST` | Explodes block and converts attributes to text | – | ✗ (Express Tool) |

### 24.4 Dynamic Block Commands (Block Editor Only)

| Command | Description | LT? |
|---------|-------------|-----|
| `BPARAMETER` | Adds a parameter | ✓ |
| `BACTION` / `BACTIONTOOL` | Adds an action | ✓ |
| `BACTIONSET` | Defines/modifies an action's selection set | ✓ |
| `BACTIONBAR` | Controls action bar display | ✓ |
| `BASSOCIATE` | Associates an action with a parameter | ✓ |
| `BGRIPSET` | Specifies grip settings | ✓ |
| `BCYCLEORDER` | Sets grip cycling order | ✓ |
| `BCONSTRUCTION` | Converts geometry to construction geometry | ✓ |
| `BLOOKUPTABLE` | Opens the lookup table editor | ✓ |
| `BTESTBLOCK` | Tests the dynamic block | ✓ |
| `BVSTATE` | Manages visibility states | ✓ |
| `BVSHOW` | Makes objects visible in a visibility state | ✓ |
| `BVHIDE` | Makes objects invisible in a visibility state | ✓ |
| `BCPARAMETER` | Applies constraint parameters | ✗ |
| `BTABLE` | Opens block properties table | ✗ |

### 24.5 Attribute Commands

| Command | Description | Dialog? | LT? |
|---------|-------------|---------|-----|
| `ATTDEF` | Creates an attribute definition | ✓ | ✓ |
| `-ATTDEF` | Command-line attribute definition | – | ✓ |
| `EATTEDIT` | Edits attributes of a selected block | ✓ | ✓ |
| `ATTEDIT` / `-ATTEDIT` | Edits attributes globally | Both | ✓ |
| `BATTMAN` | Block Attribute Manager | ✓ | ✓ |
| `BATTORDER` | Sets attribute order in Block Editor | ✓ | ✓ |
| `ATTSYNC` | Synchronizes attribute definitions to existing references | – | ✓ |
| `ATTDISP` | Controls attribute visibility display | – | ✓ |
| `DATAEXTRACTION` | Extracts attribute data to table or file | ✓ (Wizard) | ✓ |
| `EATTEXT` | Legacy attribute extraction | ✓ | ✓ |
| `ATTREDEF` | Redefines block attributes (updates existing refs) | – | ✗ |
| `ATTOUT` | Export attributes to text file (Express Tools) | – | ✗ |
| `ATTIN` | Import attributes from text file (Express Tools) | – | ✗ |

### 24.6 External Reference Commands

| Command | Description | Dialog? | LT? |
|---------|-------------|---------|-----|
| `XATTACH` | Attaches an xref DWG | ✓ | ✓ |
| `XREF` / `EXTERNALREFERENCES` | Opens External References palette | Palette | ✓ |
| `XBIND` | Binds individual named objects from an xref | ✓ | ✓ |
| `-XBIND` | Command-line xbind | – | ✓ |
| `XCLIP` / `CLIP` | Clips an xref or block to a boundary | – | ✓ |
| `XOPEN` | Opens an xref in a new drawing window | – | ✓ |

### 24.7 Cleanup Commands

| Command | Description | Dialog? | LT? |
|---------|-------------|---------|-----|
| `PURGE` | Removes unused named objects | ✓ | ✓ |
| `-PURGE` | Command-line purge | – | ✓ |
| `RENAME` | Renames named objects (blocks, layers, etc.) | ✓ | ✓ |
| `-RENAME` | Command-line rename | – | ✓ |

---

## 25. System Variables Reference

### 25.1 Block-Related System Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| **ATTDIA** | Integer | 1 | Controls attribute prompting during block insertion. 0 = command line prompts. 1 = dialog box. |
| **ATTREQ** | Integer | 1 | Controls whether attributes are requested during insertion. 0 = use defaults silently. 1 = prompt user. |
| **ATTDISP** | Integer | 1 | Controls attribute visibility. 0 = all invisible. 1 = normal (respect individual settings). 2 = all visible. |
| **ATTIPE** | Integer | 0 | Controls if in-place editing is used for attributes. 0 = dialog. 1 = in-place. |
| **ATTMULTI** | Integer | 1 | Controls whether multi-line attributes can be created. 0 = no. 1 = yes. |
| **AFLAGS** | Integer | 0 | Default attribute modes for new ATTDEF commands. Bitfield: 1=Invisible, 2=Constant, 4=Verify, 8=Preset. |
| **BLOCKEDITLOCK** | Integer | 0 | Prevents the Block Editor from being opened. 0 = unlocked. 1 = locked. |
| **BLOCKREDEFINEMODE** | Integer | 1 | Controls behavior when inserting a block with a name that already exists. 0 = silently replace. 1 = dialog prompt. 2 = command-line prompt. |
| **BLOCKNAVIGATE** | Integer | 1 | Controls what's shown in the Libraries tab of the Blocks palette. 0 = last used library. 1 = specific folder. |
| **EXTNAMES** | Integer | 1 | Controls the naming convention for named objects. 0 = AutoCAD R14 naming (31 char limit). 1 = long names (255 chars). |
| **INSBASE** | Point | 0,0,0 | Stores the insertion base point for the current drawing (set by BASE command). |
| **INSNAME** | String | "" | Stores the default block name for INSERT command. |
| **INSUNITS** | Integer | 1 | Specifies the drawing units for automatic block scaling on insertion. 0=Unitless, 1=Inches, 2=Feet, 3=Miles, 4=Millimeters, 5=Centimeters, 6=Meters, 7=Kilometers, ... |
| **INSUNITSDEFSOURCE** | Integer | 1 | Default source units for INSERT when INSUNITS=0. |
| **INSUNITSDEFTARGET** | Integer | 1 | Default target units for INSERT when drawing INSUNITS=0. |

### 25.2 Dynamic Block System Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| **BACTIONBARMODE** | Integer | 1 | Controls how action bars display in Block Editor. 0 = legacy (action objects at parameter). 1 = action bars. |
| **BACTIONCOLOR** | Integer | 7 | Color of action objects in Block Editor. |
| **BGRIPOBJCOLOR** | Integer | 141 | Color of custom grips in Block Editor. |
| **BGRIPOBJSIZE** | Integer | 8 | Size of custom grips in Block Editor. |
| **BPARAMETERCOLOR** | Integer | 7 | Color of parameter objects in Block Editor. |
| **BPARAMETERFONT** | String | "Simplex.shx" | Font for parameter text in Block Editor. |
| **BPARAMETERSIZE** | Integer | 12 | Size of parameter text in Block Editor. |
| **BTMARKDISPLAY** | Integer | 1 | Controls display of value set markers. 0 = off. 1 = on. |
| **BVMODE** | Integer | 0 | Controls visibility of invisible objects in Block Editor. 0 = not shown. 1 = shown dimmed. |

### 25.3 Xref System Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| **XLOADCTL** | Integer | 2 | Controls xref demand loading. 0=off, 1=on, 2=on with copy. |
| **XREFNOTIFY** | Integer | 2 | Controls xref change notification. 0=off, 1=modified only, 2=modified+missing. |
| **XDWGFADECTL** | Integer | 50 | Controls fading percentage for xref geometry (0-90). |
| **XFADECTL** | Integer | 50 | Controls fading of non-working-set objects during REFEDIT (0-90). |
| **XREFOVERRIDE** | Integer | 0 | Controls whether xref object properties can be overridden by the host drawing. 0 = no. 1 = yes. |
| **XREFTYPE** | Integer | 0 | Default xref type. 0 = Attachment. 1 = Overlay. |
| **PROJECTNAME** | String | "" | Project name for xref path search. |
| **FRAME** | Integer | 2 | Controls visibility of frames for xref clips, image boundaries, etc. 0=invisible, 1=visible, 2=visible but not plotted. |
| **VISRETAIN** | Integer | 1 | Controls whether xref layer visibility/freeze/lock/color/linetype settings are saved in the host drawing. 0 = no. 1 = yes. |
| **XEDIT** | Integer | 1 | Controls whether the current drawing can be edited in-place by another drawing. 0 = no. 1 = yes. |

### 25.4 Other Relevant System Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| **EXPLMODE** | Integer | 1 | Controls whether non-uniformly scaled blocks can be exploded. 0 = no. 1 = yes. |
| **QAFLAGS** | Integer | 0 | Quality assurance flags — various debugging/testing behaviors. |
| **DATALINKNOTIFY** | Integer | 2 | Controls the Data Links tray icon for extracted data updates. |

---

## Appendix A: Glossary

| Term | Definition |
|------|-----------|
| **Block Definition** | The stored template/blueprint of a block, containing name, base point, and geometry. |
| **Block Reference** | An instance of a block placed in the drawing. Points to a block definition. |
| **Block Table** | The DWG database table containing all block definitions. |
| **Block Table Record** | A single entry in the Block Table representing one block definition. |
| **Dynamic Block** | A block with parameters and actions that allow manipulation after insertion. |
| **Parameter** | A dynamic block element that defines what can change (position, distance, angle, visibility, etc.). |
| **Action** | A dynamic block element that defines how geometry changes in response to parameter manipulation. |
| **Parameter Set** | A pre-packaged combination of a parameter and associated action(s). |
| **Value Set** | A constraint on a parameter's allowable values (list, increment, or none). |
| **Visibility State** | A named configuration that controls which objects are visible within a dynamic block. |
| **Lookup Table** | A mapping table that connects parameter values to named configurations. |
| **Constraint** | A geometric or dimensional rule applied to block geometry (full AutoCAD only). |
| **Constraint Parameter** | A dimensional constraint combined with a parameter, enabling grip access (full AutoCAD only). |
| **Attribute** | A data field embedded in a block for storing variable text information. |
| **Attribute Definition (ATTDEF)** | The template for an attribute, defining its tag, prompt, default, modes, and text properties. |
| **Attribute Reference** | An instance of an attribute within a specific block reference, containing the actual value. |
| **Xref (External Reference)** | A DWG file referenced by another drawing, maintaining a live link. |
| **Anonymous Block** | An auto-generated unnamed block (prefixed with `*`) used internally by AutoCAD. |
| **Construction Geometry** | Geometry visible only in the Block Editor, used for reference during block authoring. |
| **Selection Set (action)** | The set of objects affected by a dynamic block action. |
| **Key Point** | The point on a parameter that drives an action. |
| **Grip** | An interactive handle displayed on a selected block reference for manipulation. |
| **BYBLOCK** | Property assignment mode where the object inherits properties from the block reference. |
| **BYLAYER** | Property assignment mode where the object inherits properties from its layer. |

---

## Appendix B: Feature Implementation Priority Matrix

For implementing equivalent features, this matrix suggests a build order based on dependency and usage frequency:

| Priority | Feature | Rationale |
|----------|---------|-----------|
| **P0 — Foundation** | Block definitions, Block Table, block references | Everything depends on this. |
| **P0 — Foundation** | BYBLOCK/BYLAYER property inheritance | Core to block rendering. |
| **P0 — Foundation** | Block insertion (position, scale, rotation) | Basic usage. |
| **P0 — Foundation** | Block base point | Needed for insertion. |
| **P1 — Core** | Block Editor environment | Required for all authoring. |
| **P1 — Core** | Block attributes (ATTDEF, basic editing) | Very widely used. |
| **P1 — Core** | Nested blocks | Common in real drawings. |
| **P1 — Core** | Explode | Essential manipulation command. |
| **P2 — Dynamic Basics** | Parameters (Point, Linear, Rotation, Flip) | Core dynamic block capability. |
| **P2 — Dynamic Basics** | Actions (Move, Stretch, Rotate, Flip) | Core dynamic block capability. |
| **P2 — Dynamic Basics** | Parameter-Action association and selection sets | How params and actions connect. |
| **P2 — Dynamic Basics** | Grip display and manipulation | User interaction model. |
| **P3 — Dynamic Advanced** | Visibility states | Very popular feature. |
| **P3 — Dynamic Advanced** | Value sets (List, Increment) | Common constraint mechanism. |
| **P3 — Dynamic Advanced** | Lookup tables | Common for standardized components. |
| **P3 — Dynamic Advanced** | Polar parameter and Polar Stretch | Used in angular components. |
| **P3 — Dynamic Advanced** | XY parameter and box sets | Used in 2D-resizable components. |
| **P3 — Dynamic Advanced** | Array action | Used in repeating components. |
| **P3 — Dynamic Advanced** | Chain Actions | Enables complex block behaviors. |
| **P4 — Extended** | Scale action | Less common but important. |
| **P4 — Extended** | Alignment parameter | Specialized but valuable. |
| **P4 — Extended** | Base Point parameter | For complex dynamic blocks. |
| **P4 — Extended** | Distance Multiplier / Angle Offset | Advanced override properties. |
| **P4 — Extended** | Attribute extraction (DATAEXTRACTION) | Reporting feature. |
| **P4 — Extended** | Attribute sync (ATTSYNC) | Definition management. |
| **P5 — Xrefs** | External references (attach, overlay) | Different subsystem, but block-related. |
| **P5 — Xrefs** | Xref bind (Bind, Insert modes) | Conversion xref → block. |
| **P5 — Xrefs** | Xref clipping | Display management. |
| **P5 — Xrefs** | Demand loading | Performance optimization. |
| **P6 — Constraints (Optional)** | Geometric constraints in blocks | Full AutoCAD only; complex to implement. |
| **P6 — Constraints (Optional)** | Constraint parameters (BCPARAMETER) | Full AutoCAD only. |
| **P6 — Constraints (Optional)** | Block Properties Table (BTABLE) | Full AutoCAD only. |
| **P7 — Content Management** | DesignCenter | Library browsing. |
| **P7 — Content Management** | Tool Palettes | Organized access. |
| **P7 — Content Management** | Blocks Palette with cloud sync | Modern UX. |

---

*Document generated from Autodesk official documentation (help.autodesk.com), Autodesk blogs, and community resources. Covers AutoCAD 2025/2026 feature set with AutoCAD LT limitations explicitly noted.*
