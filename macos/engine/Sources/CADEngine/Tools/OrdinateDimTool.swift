//
//  OrdinateDimTool.swift
//  CADEngine
//
//  The interactive ORDINATE dimension creation tool — places a `DimKind.ordinate`
//  dimension measuring the X- or Y-coordinate of a feature point relative to a
//  datum origin, shown as a leader from the feature to a text location.
//
//  Ported in spirit from LibreCAD's `LC_ActionDimOrdinate`
//  (librecad/src/actions/drawing/draw/dimensions/lc_actiondimordinate.*) +
//  `LC_DimOrdinate` (librecad/src/lib/engine/document/entities/lc_dimordinate.*),
//  with the magic `int m_status` replaced by an exhaustive private `enum State`.
//  Built against the FROZEN `Tool` contract: a PURE value type that takes already-
//  snapped WORLD points and authors one `.dimension` entity whose graphic is
//  computed in `resolve()` (ADR-001).
//
//  Click sequence:
//    1. datum origin          (.settingOrigin → .settingFeature)
//    2. feature point         (.settingFeature → .settingLeader)
//    3. leader / text location → `leaderEnd`; the dominant component of the
//       feature→leader vector chooses the measured axis (a mostly-vertical leader
//       drag measures the X coordinate; a mostly-horizontal one measures Y), unless
//       the tool is locked to `.x` / `.y`. Commit `.ordinate`, then RESET.
//
//  PURE: never touches CADDrawing/Quadtree/GUI; ignores `context` (it needs only
//  the snapped points). UNWIRED at creation (registered in a later wire-wave).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDim* family).
//  Copyright (C) LibreCAD contributors (LC_ActionDimOrdinate / LC_DimOrdinate).
//

import Foundation

/// The interactive Ordinate dimension tool. See the file header for the click
/// sequence. The measured axis is chosen by the leader-drag direction (auto), or
/// locked via the `axis` option (`.x` / `.y`).
public struct OrdinateDimTool: Tool {

    /// Which coordinate the ordinate measures.
    public enum Axis: Sendable, Equatable {
        /// Auto: the dominant component of the feature→leader drag picks the axis
        /// (a vertical leader measures X; a horizontal leader measures Y).
        case auto
        /// Lock to the X coordinate (X-datum ordinate; vertical leader).
        case x
        /// Lock to the Y coordinate (Y-datum ordinate; horizontal leader).
        case y
    }

    private enum State: Equatable {
        case settingOrigin
        case settingFeature(origin: Vector)
        case settingLeader(origin: Vector, feature: Vector)
    }

    private var state: State = .settingOrigin
    private var cursor: Vector = .invalid

    /// The measured-axis lock. Default `.auto`.
    public var axis: Axis

    public init(axis: Axis = .auto) {
        self.axis = axis
    }

    public var title: String {
        switch axis {
        case .auto: return "Ordinate Dimension"
        case .x:    return "Ordinate Dimension (X)"
        case .y:    return "Ordinate Dimension (Y)"
        }
    }

    public var status: String {
        switch state {
        case .settingOrigin:  return "Specify ordinate datum origin"
        case .settingFeature: return "Specify feature location"
        case .settingLeader:  return "Specify leader endpoint (drag to set axis)"
        }
    }

    public var preview: [ResolvedPolyline] {
        guard case .settingLeader(let origin, let feature) = state,
              cursor.valid, origin.valid, feature.valid,
              let data = makeData(origin: origin, feature: feature, leader: cursor) else {
            return []
        }
        return DimToolSupport.previewLines(data)
    }

    /// Resolves the measured axis for the feature→leader drag, honoring the lock.
    /// In `.auto`, a leader whose drag is more vertical than horizontal measures
    /// the X coordinate (the standard ordinate gesture), else the Y coordinate.
    private func measuresX(feature: Vector, leader: Vector) -> Bool {
        switch axis {
        case .x: return true
        case .y: return false
        case .auto:
            let dx = abs(leader.x - feature.x)
            let dy = abs(leader.y - feature.y)
            return dy >= dx   // a more-vertical leader → X-datum ordinate
        }
    }

    /// Builds the `DimData` for the picked points + leader. `definitionPoint` is the
    /// datum origin (DXF code 10). Returns `nil` for a degenerate leader on the
    /// feature.
    private func makeData(origin: Vector, feature: Vector, leader: Vector) -> DimData? {
        guard leader.distance(to: feature) > Tolerance.distance else { return nil }
        return DimData(
            kind: .ordinate(origin: origin, feature: feature, leaderEnd: leader,
                            measuringX: measuresX(feature: feature, leader: leader)),
            definitionPoint: origin
        )
    }

    /// A draw tool: it IGNORES `context` and emits the new dimension as `.add`.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview
        case .click(let p), .value(let p):
            return handleClick(p)
        case .backspace:
            return handleBackspace()
        case .cancel:
            reset()
            return .finished
        case .commit:
            reset()
            return .finished
        }
    }

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .settingOrigin:
            state = .settingFeature(origin: p)
            cursor = p
            return .none
        case .settingFeature(let origin):
            state = .settingLeader(origin: origin, feature: p)
            cursor = p
            return .none
        case .settingLeader(let origin, let feature):
            guard let data = makeData(origin: origin, feature: feature, leader: p) else {
                // Leader coincident with the feature — keep waiting for a usable one.
                return .none
            }
            let record = EntityRecord(id: .placeholder, kind: .dimension(data))
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingOrigin:
            return .none
        case .settingFeature:
            reset()
            return .preview
        case .settingLeader(let origin, _):
            state = .settingFeature(origin: origin)
            cursor = origin
            return .preview
        }
    }

    private mutating func reset() {
        state = .settingOrigin
        cursor = .invalid
    }
}
