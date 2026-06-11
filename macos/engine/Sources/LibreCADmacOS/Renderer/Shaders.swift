//
//  Shaders.swift
//  LibreCADmacOS
//
//  Inline Metal Shading Language source, compiled at runtime via
//  `device.makeLibrary(source:)`. Runtime compilation is the robust offline path
//  (no .metallib build step / SwiftPM resource quirks), as the existing demo and
//  rendering-performance.md both note.
//
//  Two pipelines:
//
//  1. INSTANCED LINES (rendering-performance.md §1.1). One *instance* per segment
//     (`LineInstance`: two endpoints as f32 render-space offsets + color + pixel
//     half-width). The vertex shader expands a unit quad's 4 vertices into a
//     screen-space-oriented rectangle: it projects both endpoints to NDC, derives
//     the segment direction and a perpendicular IN PIXEL SPACE, offsets each
//     vertex by `halfWidth + feather` pixels perpendicular, and EXTENDS the quad
//     by the same amount along the segment so round caps have room. The fragment
//     shader computes the distance from the segment centerline (in pixels) and
//     `smoothstep`s alpha over a 1px feather band → resolution-independent
//     analytic AA + round caps/joins, crisp at any zoom. Width is constant in
//     pixels regardless of zoom because the perpendicular is built from the
//     drawable pixel size, not from world units. Pan/zoom only change the matrix
//     uniform — the instance buffer is never rebuilt (ADR-003 floating-origin).
//
//  2. FLAT VERTEX-COLOR (overlay). Plain `position(float2 render-space) + color`
//     vertices through the same world→clip matrix, drawn as line or triangle
//     primitives. Used for the adaptive world grid, selection highlight, snap
//     markers, and the crosshair. No AA (overlays are thin/secondary); good
//     enough for the foundation.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

/// The runtime-compiled MSL source shared by both pipelines.
let canvasMetalSource = """
#include <metal_stdlib>
using namespace metal;

// ---- Uniforms shared by both pipelines -------------------------------------

struct Uniforms {
    float4x4 transform;     // world(render-space)→clip (Viewport.worldToClip)
    float2   viewportPx;    // drawable size in device pixels (for px↔NDC)
};

// ============================================================================
// 1. INSTANCED LINE PIPELINE (screen-space quads, analytic AA, round caps)
// ============================================================================

// Matches Swift `struct LineInstance` (RendererGeometry.swift), interleaved.
struct LineInstance {
    float2 p0;          // segment start, f32(world - renderOrigin)
    float2 p1;          // segment end
    float4 color;       // rgba
    float  halfWidthPx; // half stroke width in device pixels
};

struct LineVaryings {
    float4 position [[position]];
    float4 color;
    // Distance from the segment centerline to this fragment, in PIXELS, carried
    // as (perpendicular, alongPastEnd) so the fragment shader can round the caps.
    float2 distPx;
    float  halfWidthPx;
    float  halfLenPx;   // half the segment length in pixels (for cap rounding)
};

// A unit quad as a triangle strip: (-1,-1)(+1,-1)(-1,+1)(+1,+1).
// x in {-1,+1} selects the endpoint (along the segment), y in {-1,+1} the side.
constant float2 kQuad[4] = {
    float2(-1.0, -1.0), float2(1.0, -1.0),
    float2(-1.0,  1.0), float2(1.0,  1.0)
};

vertex LineVaryings line_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant LineInstance *instances [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]]) {
    LineInstance inst = instances[iid];
    float2 corner = kQuad[vid];

    // Project both endpoints to NDC, then to pixel space.
    float4 c0 = u.transform * float4(inst.p0, 0.0, 1.0);
    float4 c1 = u.transform * float4(inst.p1, 0.0, 1.0);
    float2 ndc0 = c0.xy / c0.w;
    float2 ndc1 = c1.xy / c1.w;
    float2 halfPx = u.viewportPx * 0.5;   // NB: `half` is a reserved MSL type — do not name a var `half`
    float2 px0 = ndc0 * halfPx;   // pixel-space (origin at center; y up)
    float2 px1 = ndc1 * halfPx;

    // Segment direction + perpendicular in pixel space.
    float2 d = px1 - px0;
    float len = length(d);
    float2 dir = (len > 1e-6) ? d / len : float2(1.0, 0.0); // degenerate → dot
    float2 perp = float2(-dir.y, dir.x);

    // Extend by (halfWidth + feather) so round caps/AA have room at both ends.
    float feather = 1.0;
    float ext = inst.halfWidthPx + feather;
    float halfLen = len * 0.5;
    float2 mid = (px0 + px1) * 0.5;

    // Position this corner: along = ±(halfLen + ext), side = ±ext.
    float along = corner.x * (halfLen + ext);
    float side  = corner.y * ext;
    float2 px = mid + dir * along + perp * side;

    // Back to NDC → clip.
    float2 ndc = px / halfPx;

    LineVaryings out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = inst.color;
    // distPx.x = signed perpendicular distance from centerline (pixels)
    // distPx.y = signed distance along from the segment MIDPOINT (pixels)
    out.distPx = float2(side, along);
    out.halfWidthPx = inst.halfWidthPx;
    out.halfLenPx = halfLen;
    return out;
}

fragment float4 line_fragment(LineVaryings in [[stage_in]]) {
    float feather = 1.0;
    // Perpendicular distance from the centerline.
    float dPerp = abs(in.distPx.x);
    // Distance past the segment end along its axis (0 within the body).
    float dAlong = max(abs(in.distPx.y) - in.halfLenPx, 0.0);
    // Round cap: combine perpendicular + past-end as a 2D distance to the
    // centerline ENDPOINT, so caps and the body both feather over `feather` px.
    float dist = sqrt(dPerp * dPerp + dAlong * dAlong);
    float alpha = 1.0 - smoothstep(in.halfWidthPx - feather, in.halfWidthPx + feather, dist);
    if (alpha <= 0.0) discard_fragment();
    return float4(in.color.rgb, in.color.a * alpha);
}

// ============================================================================
// 2. FLAT VERTEX-COLOR PIPELINE (overlay: grid, selection, markers, crosshair)
// ============================================================================

// Matches Swift `struct FlatVertex` (OverlayRenderer.swift).
struct FlatVertex {
    float2 position;    // render-space (f32 offset from renderOrigin)
    float4 color;
};

struct FlatVaryings {
    float4 position [[position]];
    float4 color;
};

vertex FlatVaryings flat_vertex(uint vid [[vertex_id]],
                                constant FlatVertex *verts [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]]) {
    FlatVertex v = verts[vid];
    FlatVaryings out;
    out.position = u.transform * float4(v.position, 0.0, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 flat_fragment(FlatVaryings in [[stage_in]]) {
    return in.color;
}
"""
