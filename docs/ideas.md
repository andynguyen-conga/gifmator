# Gifmator — Parked Ideas

A short roadmap of features we agreed to defer. The order below is the order we currently plan to tackle them.

## 1. Crop region selector

**Status**: Queued

### Use case

The user records their whole screen but only wants the exported GIF to focus on a specific window, panel, or UI element. Today they have to re-record or trim the source elsewhere; a crop region keeps the whole recording as the source of truth and only changes what the export sees.

### Rough approach

On the preview, let the user drag a rectangle on top of the video surface with the standard set of resize handles (eight points) and a move-the-whole-rect drag anywhere inside. Esc clears; a "Reset crop" button restores the full frame. The crop rect is passed into the ffmpeg filter chain as a `crop=W:H:X:Y` filter prepended to the existing `scale` / `palettegen` / `paletteuse` passes — the crop happens before the palette is derived so palette colours come from the cropped frames only (same reason we apply `-ss`/`-to` to both passes today). The live size estimate recomputes from cropped dimensions, not source.

### Open questions

- Aspect-ratio snap to common ratios (16:9, 4:3, 1:1) while dragging — hold a modifier to opt in, or a toggle in the crop UI?
- Per-video memory of the last crop — stored by source URL? by content hash? just session-only?
- Interaction between the crop and the preset Width — does Width override the crop output size (always scale cropped region to Width), or is Width a maximum (scale down if cropped region is larger, pass through if smaller)?

## 2. Animated zoom in / zoom out

**Status**: Queued

### Use case

A product walkthrough starts wide and zooms into a specific region to highlight an interaction, or starts tight on a UI detail and pulls back to show context. Baking the motion into the GIF is the point — the viewer sees exactly the camera move the author intended, no extra editing surface needed.

### Rough approach

The user defines two keyframe rectangles on the preview (start rect, end rect) plus a transition duration and an easing choice. ffmpeg handles this cleanly with either the `zoompan` filter or a time-varying `crop` filter driven by a `t`-based expression — pick based on which produces nicer intermediates on 15–30 fps GIFs (zoompan is purpose-built for this but can go blurry on short clips; expression-driven `crop` is sharper but needs manual interpolation). The output size stays controlled by the preset Width; the zoom just changes what the scaled viewport sees frame-by-frame.

### Open questions

- Number of keyframes — just two for v1 (start + end) is almost certainly enough; multi-keyframe is a v2 question.
- Easing choices — linear and ease-in-out as the obvious defaults; a cubic-bezier picker is overkill for v1.
- Whether to let the user hold on a keyframe before and/or after the transition (e.g., 500 ms wide → 1 s zoom → 500 ms held tight) or whether the whole clip is one continuous move.

## 3. Spotlight effect

**Status**: Queued

### Use case

Dim everything outside a specific region to direct the viewer's attention to one UI element in a full-screen recording. Less destructive than crop (the surrounding context stays visible, just dimmed) and more visual than a highlight box.

### Rough approach

Composite a dimmed base layer with a soft-edged mask cut out of the spotlight region. In ffmpeg this is a `boxblur` / `alphaextract` chain for a true soft edge, or the simpler `drawbox` + `blend` route for a hard-edged dim that's easier to reason about. The spotlight region can be static (one rect for the whole clip) or animated between two keyframes (same keyframe story as the zoom feature, so the implementations can share plumbing).

### Open questions

- Soft-edge radius — a single slider in points (0 = hard edge, 32 = very soft) seems right for v1.
- Dim strength — configurable 0–100%, default around 60–70%.
- Interaction with crop and zoom — can all three stack in one export (crop → spotlight → zoom), or are they mutually exclusive for v1? Stacking is more powerful but the UI gets busy fast.

## See also

- The full feasibility plan lives in the Cursor Agent Store under `docs/feasibility-plan.md`.
