/// What the home-screen widget should say, given what the app managed to publish.
///
/// Ported from the widget's three layouts — normal, `omniterm_widget_error`, and
/// `omniterm_widget_loading` (`res/layout/`, strings `widget_load_failed`, `widget_error_hint`,
/// `widget_no_servers`).
///
/// Flutter's widget had **two** of the three: rows, and an empty state. A payload it could not read
/// fell through `runCatching { … }.getOrElse { JSONArray() }` into the empty state, so a user with
/// twelve saved hosts saw "Open OmniTerm to add a host". That is the defect from 53 and 54 again —
/// an error rendered as "you have nothing" — and on a home screen it is worse, because there is no
/// obvious way to ask again.
library;

/// The key the app writes its publish status under.
const String widgetStatusKey = 'payload_status';

/// Written when a sync completed, so the widget can tell "nothing saved" from "nothing published".
const String widgetStatusOk = 'ok';

/// Written when the app could not publish, so the widget stops showing stale emptiness as fact.
const String widgetStatusFailed = 'failed';

/// What the widget should render.
enum WidgetPayloadState {
  /// Rows are available and should be listed.
  rows,

  /// The app has published successfully and there genuinely are no hosts.
  empty,

  /// The app has never published, or its last attempt failed, or the payload cannot be parsed.
  unavailable,
}

/// Decides what the widget shows.
///
/// [status] is what the app last wrote; [parsed] is whether the payload could be read at all;
/// [rowCount] is how many rows came out of it.
///
/// **"Never published" is unavailable, not empty.** A widget added before the app has run once has
/// no idea whether the user has hosts, and guessing "none" puts a false statement on their home
/// screen — which is the one place they cannot correct it.
WidgetPayloadState widgetPayloadState({
  required String? status,
  required bool parsed,
  required int rowCount,
}) {
  if (!parsed || status == null || status == widgetStatusFailed) {
    return WidgetPayloadState.unavailable;
  }
  return rowCount > 0 ? WidgetPayloadState.rows : WidgetPayloadState.empty;
}

/// The message for a state that has no rows to show, or null when rows should be listed.
String? widgetPlaceholderMessage(WidgetPayloadState state) => switch (state) {
  WidgetPayloadState.rows => null,
  WidgetPayloadState.empty => 'Open OmniTerm to add a host',
  // Says what to do, not just what went wrong — a widget has no other affordance.
  WidgetPayloadState.unavailable =>
    'Could not load fleet data. Open OmniTerm, then refresh the widget.',
};
