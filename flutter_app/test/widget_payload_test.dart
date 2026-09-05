import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/widget_payload.dart';

/// What the home-screen widget shows, ported from its three layouts (`res/layout/`, strings
/// `widget_no_servers`, `widget_load_failed`, `widget_error_hint`).
///
/// Flutter's widget had two of the three. A payload it could not read fell through into the empty
/// state, so a user with twelve saved hosts was told to add one — and a home-screen widget gives
/// them no way to ask again.
void main() {
  WidgetPayloadState state({
    String? status = widgetStatusOk,
    bool parsed = true,
    int rowCount = 3,
  }) => widgetPayloadState(status: status, parsed: parsed, rowCount: rowCount);

  group('what the widget shows', () {
    test('a good payload with hosts lists them', () {
      expect(state(), WidgetPayloadState.rows);
    });

    test('a good payload with no hosts is genuinely empty', () {
      expect(state(rowCount: 0), WidgetPayloadState.empty);
    });

    test('a payload that could not be parsed is unavailable, not empty', () {
      // The defect. Twelve hosts and a corrupt payload used to read as "add a host".
      expect(state(parsed: false, rowCount: 0), WidgetPayloadState.unavailable);
    });

    test('a failed publish is unavailable even if old rows are still there', () {
      // A part-way sync must not leave the widget presenting half a fleet as current.
      expect(state(status: widgetStatusFailed, rowCount: 5), WidgetPayloadState.unavailable);
    });

    test('never published is unavailable, not empty', () {
      // A widget added before the app has run once has no idea whether the user has hosts, and
      // guessing "none" puts a false statement somewhere they cannot correct it.
      expect(state(status: null, rowCount: 0), WidgetPayloadState.unavailable);
    });
  });

  group('the placeholder wording', () {
    test('rows have no placeholder', () {
      expect(widgetPlaceholderMessage(WidgetPayloadState.rows), isNull);
    });

    test('empty invites adding a host', () {
      expect(widgetPlaceholderMessage(WidgetPayloadState.empty), contains('add a host'));
    });

    test('unavailable says what to do, not only what went wrong', () {
      // A widget has no other affordance — "error" alone leaves the user stuck.
      final message = widgetPlaceholderMessage(WidgetPayloadState.unavailable)!;
      expect(message, contains('Could not load'));
      expect(message, contains('refresh the widget'));
    });
  });
}
