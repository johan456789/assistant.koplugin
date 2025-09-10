## Goal

Replace the current stream mode (InputDialog + StreamText) with a time-throttled streaming approach that renders Markdown in `ChatGPTViewer` periodically during the stream.

## Constraints

- KOReader often runs on low-compute e-ink devices; minimize CPU, memory, and screen refreshes.
- Must render as Markdown during streaming; no plain-text interim mode.
- Maintain existing user-facing affordances (Stop, scroll buttons, Copy/Save/Ask Another Question post-stream).

## High-level Design

1. Query still uses provider handlers with SSE-like streaming.
2. Accumulate incoming chunks in a buffer.
3. A time-based ticker (e.g., 500–1000 ms) triggers re-render into `ChatGPTViewer` using Markdown each tick.
4. On stream completion or cancel, perform one final render, ensure scroll state is sane, and enable post-actions.

## Implementation Steps

1) Settings and Defaults
- Add a setting in `assistant_settings.lua`:
  - `stream_render_interval_ms` (default 750; allowed range 300–2000).
  - `stream_auto_scroll` (default true) to auto-stick to bottom during stream if the user has not scrolled up.

2) Replace Stream UI with ChatGPTViewer
- In `assistant_querier.lua`:
  - Remove `InputDialog:new{ ... add_scroll_buttons = true }` streaming path.
  - Create a `ChatGPTViewer` instance up-front with:
    - `render_markdown = true`.
    - Empty initial text or a short placeholder (e.g., “Generating…”).
    - Title showing provider/model (mimic current dialog header data).
    - Include `Stop` action via viewer close (and long-press hold-close hook).

3) Stream Buffer and Throttled Renderer
- Maintain module-local fields on the querier during a stream:
  - `stream_buffer` (string builder table, concat on tick).
  - `stream_last_render_ts` (number, seconds).
  - `stream_timer_handle` (scheduled task id).
  - `stream_active_viewer` (the `ChatGPTViewer`).
  - `user_interrupted` flag (existing).
- For every SSE chunk:
  - Append to `stream_buffer`.
  - If no pending timer, schedule a render after `stream_render_interval_ms`.
- On timer fire:
  - Concat buffer, clear it, and call a new method `viewer:updateStreamingMarkdown(new_markdown)`.
  - Reschedule only if more chunks arrive.
- On stream end or cancel:
  - Cancel pending timer.
  - Perform a final render with any remaining buffer.
  - Clear temporary fields.

4) Viewer: streaming update API
- Add a lightweight method on `ChatGPTViewer`:
  - `updateStreamingMarkdown(new_text)`
    - Set `self.text = new_text`.
    - Recreate `ScrollHtmlWidget` with current CSS and font size (same as `init`/`update`).
    - Replace the inner widget (`self.textw[1] = self.scroll_text_w`).
    - Use partial/fast refresh invalidation.
- Auto-scroll behavior during stream:
  - If `stream_auto_scroll` is true and user hasn’t scrolled up (see Nice-to-have), scroll to bottom or keep the last-page ratio.

5) Stop/Cancel
- Keep the existing interrupt mechanism (`interrupt_stream`) but route the Stop action through the viewer’s close.
- On close while streaming: set `user_interrupted = true`, interrupt subprocess, cancel timer, close viewer.

6) Error Handling
- If a non-200 or parsing error is detected mid-stream:
  - Finalize the viewer with the error text (rendered as Markdown inside a notice block).
  - Maintain the same Close behavior.

## UI/UX Details

- Title bar: “Assistant: AI is responding” + provider/model in description line within the viewer content (first line), or adapt the titlebar left icon callback to open settings (existing behavior).
- Buttons row: keep existing `ChatGPTViewer` defaults (⇱ ⇲ Close Copy/Add Note/Save depending on settings). The Stop semantics map to Close while a stream is active.
- During the stream, show content as it grows; upon completion, the viewer can add “Ask Another Question” button (already present).

## Performance Considerations

- Choose a default interval of 750 ms to limit Markdown parsing and HTML layout.
- Use `UIManager:setDirty(self.frame, "partial")` after each tick.
- Avoid string churn by buffering chunks in a table and `table.concat` per tick.
- Ensure timer scheduling uses `UIManager:scheduleIn` and that we unschedule on close/cancel.

## Edge Cases

- Providers that burst large chunks: renderer still throttles by time.
- Very slow models: viewer is updated rarely; UX remains consistent.
- User closes the viewer mid-stream: cancel timer and subprocess; do not attempt final render.

## Backward Compatibility / Removals

- Remove `InputDialog` streaming path entirely.
- Retain error dialogs (`InfoMessage`/`ConfirmBox`) behavior.

## Testing Plan

- Emulated fast stream (local mock) to stress the throttling and verify no UI stutter.
- Long outputs with lists/code blocks to ensure Markdown remains stable between ticks.
- RTL and large font sizes: verify CSS and pagination remain sane.
- E-ink device: verify flash/ghosting is acceptable at 750 ms.

## Nice-to-have: Preserve Scroll Position

Goal: if the user scrolls up during the stream, do not snap back to the bottom; if the user stays at the bottom, continue auto-sticking.

Design:
- Add methods on `ChatGPTViewer`:
  - `getScrollRatio()` → float [0..1] for `ScrollHtmlWidget` (derived from `htmlbox_widget.page_num/page_count`).
  - `setScrollRatio(ratio)` → scrolls to a given ratio.
  - `isNearBottom(threshold)` → true if ratio ≥ `1 - threshold` (e.g., 0.02).
- On every streaming tick:
  - Before re-render: capture `prev_ratio = getScrollRatio()` and a boolean `was_near_bottom = isNearBottom(0.02)`.
  - After re-render: if user had scrolled up (not near bottom), restore `setScrollRatio(prev_ratio)`; else scroll to bottom/last page.
- Detect manual user scroll:
  - Hook the scroll callback (`_buttons_scroll_callback`) to set `user_pinned_bottom = false` when not near bottom, true when near bottom again.

Implementation notes:
- `ScrollHtmlWidget` currently lacks explicit ratio getters/setters; we can compute ratio via `page_num/page_count` and expose small helpers on the viewer.
- This approach works despite widget recreation, as long as we capture and restore ratio each tick.

## Risks & Mitigations

- Frequent Markdown re-render still heavy → use ≥500 ms interval, consider 1000 ms on low-end devices.
- Flicker on e-ink → keep partial refresh; consider debouncing when user is interacting (pause renders for ~1s after a pan/scroll gesture).
- Unexpected malformed interim Markdown (unfinished code fences) → acceptable; final render fixes it. Optionally, sanitize fence balancing per tick.

## Rollout Plan

1. Implement behind a feature flag `use_stream_mode_chatgptviewer` (default on; can fallback to old path if needed during testing).
2. Measure on-device performance and adjust default interval.
3. Remove legacy stream path after validation.


