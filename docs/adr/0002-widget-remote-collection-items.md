# ADR 0002: Keep the widget's RemoteViewsService adapter until minSdk reaches 31

- Status: accepted
- Date: 2026-08-02

## Context

The home-screen widget fills its list through the classic collection-widget pattern: `RemoteViews.setRemoteAdapter(viewId, Intent)` points the launcher at `OmniTermWidgetService`, which returns a `RemoteViewsFactory` that loads rows and renders them one at a time, and `AppWidgetManager.notifyAppWidgetViewDataChanged()` tells the launcher to re-fetch.

API 35 deprecated both `setRemoteAdapter(int, Intent)` and `notifyAppWidgetViewDataChanged()`. Their replacement, `setRemoteAdapter(int, RemoteViews.RemoteCollectionItems)`, pushes the rendered items directly and needs no service, no factory and no invalidation call — but it was added in **API 31**, and this project's `minSdk` is **24**. Adopting it therefore cannot replace the current path; it can only sit beside it, leaving both to be maintained and the deprecated calls still compiled for API 24–30.

The pattern carries a known ANR hazard, which is why the existing code is shaped the way it is. `notifyAppWidgetViewDataChanged()` is normally answered on a binder thread where blocking is fine, but when our own process fires it while a widget is visible, the launcher can re-enter `onDataSetChanged()` **on the main thread** — and that callback blocks on a database read. Two defences are in place:

- The notify call is issued from `Dispatchers.IO`, never the main thread.
- `onDataSetChanged()` hands the load to an IO coroutine and waits for it only when it is *not* on the main thread; on the main thread it returns immediately and lets the launcher pick the rows up on its next bind, which the same update already schedules.

A third hazard is thread visibility rather than blocking: `onDataSetChanged()` loads on one thread while `getCount()`/`getViewAt()` are read from the launcher's binder thread, so the published rows are `@Volatile`. Without that barrier the launcher can pair a fresh `getCount()` with a stale row and render one host's metrics under another host's name.

## Decision

Keep the `RemoteViewsService` adapter and leave the deprecation warnings visible. Do not add a parallel `RemoteCollectionItems` path solely to silence them, and do not suppress them — the warnings are the reminder that this is deferred, not resolved.

Raising `minSdk` to 31 is a product decision about dropping Android 7 through 11. It should be made on its own merits, not as a side effect of a compiler warning.

## Consequences

Two deprecation warnings persist in `OmniTermWidget.kt` for as long as `minSdk` is below 31. Deprecated is not removed: both APIs still function on API 37, and no Play policy forces the change.

The ANR and visibility hazards above remain load-bearing. Any edit to the widget's update path, the factory, or the row model must preserve all three defences — the off-main-thread notify, the non-blocking main-thread branch in `onDataSetChanged()`, and the `@Volatile` row publication. This area has regressed twice before (see the widget configuration hang and the widget row races in the history), and it cannot be verified on the emulator: widget rendering needs a real launcher on a device.

When `minSdk` does reach 31, migrate and delete `OmniTermWidgetService`, `OmniTermWidgetRowFactory` and every `notifyAppWidgetViewDataChanged()` call. That is a real simplification rather than a like-for-like swap: building the items in-process removes the cross-thread handoff entirely, and with it all three hazards.
