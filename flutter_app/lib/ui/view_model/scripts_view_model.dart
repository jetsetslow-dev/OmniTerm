import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/script_presets.dart';
import 'app_state.dart';

/// Which list the Scripts tool is showing.
///
/// The two are genuinely different things sharing one table: a quick script runs on the one host you
/// have selected, a fleet command is broadcast to many. A row can be offered in either, or both.
enum ScriptsTab { quick, fleet }

/// The Quick Scripts tool's state and actions, split out of `QuickScriptsToolView` in
/// `ui/ToolsScreen.kt`.
class ScriptsViewModel extends ChangeNotifier {
  ScriptsViewModel(this._app);

  final AppState _app;

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  List<QuickScript> _scripts = const [];
  StreamSubscription<List<QuickScript>>? _sub;

  bool _fleetPresetsEnabled = false;
  bool _homelabPresetsEnabled = false;
  bool _busy = false;
  String? _status;

  bool get fleetPresetsEnabled => _fleetPresetsEnabled;
  bool get homelabPresetsEnabled => _homelabPresetsEnabled;

  /// True while a preset family is being seeded or removed, so the toggle cannot be double-fired.
  bool get busy => _busy;

  String? get status => _status;

  void dismissStatus() {
    _status = null;
    notifyListeners();
  }

  Future<void> start() async {
    _sub ??= _app.repository.scriptsStream.listen((list) {
      _scripts = list;
      _safeNotify();
    });
    _fleetPresetsEnabled = await _readFlag(fleetPresetsSetting);
    _homelabPresetsEnabled = await _readFlag(homelabPresetsSetting);
    _safeNotify();
  }

  Future<bool> _readFlag(String key) async =>
      (await _app.repository.getSetting(key))?.toLowerCase() == 'true';

  // ── tabs and listing ────────────────────────────────────────────────────────

  ScriptsTab _activeTab = ScriptsTab.quick;

  ScriptsTab get activeTab => _activeTab;

  set activeTab(ScriptsTab value) {
    if (_activeTab == value) return;
    _activeTab = value;
    notifyListeners();
  }

  List<QuickScript> get allScripts => List.unmodifiable(_scripts);

  /// The scripts offered in the active tab.
  List<QuickScript> get visibleScripts => _scripts
      .where((s) => _activeTab == ScriptsTab.quick ? s.availableForQuick : s.availableForFleet)
      .toList();

  /// [visibleScripts] grouped by category, preserving the DAO's ordering within each group.
  ///
  /// A `Map` in Dart keeps insertion order, so iterating the source list once produces categories in
  /// the order they first appear — which is the DAO's `(category, sortOrder, name)`.
  Map<String, List<QuickScript>> get groupedScripts {
    final grouped = <String, List<QuickScript>>{};
    for (final script in visibleScripts) {
      final category = script.category.isEmpty ? 'General' : script.category;
      grouped.putIfAbsent(category, () => []).add(script);
    }
    return grouped;
  }

  // ── editing ─────────────────────────────────────────────────────────────────

  /// Saves a script, inserting when [existing] is null. Returns null on success.
  Future<String?> saveScript({
    QuickScript? existing,
    required String name,
    required String command,
    String emoji = '»',
    String color = 'cyan',
    String category = 'General',
    String notes = '',
    bool longRunning = false,
    bool availableForQuick = true,
    bool availableForFleet = false,
    String targetOs = 'Any',
    String targetSystem = 'Any',
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return 'Name is required.';
    if (command.trim().isEmpty) return 'Command is required.';
    if (!availableForQuick && !availableForFleet) {
      // A script in neither list is invisible everywhere — almost certainly not what was meant.
      return 'Offer this script in Quick scripts, Fleet commands, or both.';
    }

    await _app.repository.insertScript(
      _companion(
        id: existing?.id,
        emoji: emoji.trim().isEmpty ? '»' : emoji.trim(),
        name: trimmedName,
        command: command.trim(),
        color: color,
        longRunning: longRunning,
        category: category.trim().isEmpty ? 'General' : category.trim(),
        sortOrder: existing?.sortOrder ?? 0,
        availableForQuick: availableForQuick,
        availableForFleet: availableForFleet,
        targetOs: targetOs,
        targetSystem: targetSystem,
        notes: notes,
        // An edited preset keeps its key, so a later "disable" still removes it — but because its
        // text no longer matches, a backup now treats it as the user's and preserves the edit.
        presetKey: existing?.presetKey,
      ),
    );
    _status = "Saved '$trimmedName'.";
    _safeNotify();
    return null;
  }

  Future<void> deleteScript(QuickScript script) async {
    await _app.repository.deleteScriptById(script.id);
    _status = "Deleted '${script.name}'.";
    _safeNotify();
  }

  /// True when [script] is a preset the user has not touched.
  ///
  /// Shown on the card so it is obvious that turning the family off will take it away, and that an
  /// edit makes it permanently theirs.
  bool isPristinePresetScript(QuickScript script) {
    final key = script.presetKey;
    if (key == null) return false;
    final preset = kAllScriptPresets.where((p) => p.presetKey == key).firstOrNull;
    if (preset == null) return false;
    return isPristinePreset(preset, script.name, script.command);
  }

  // ── preset families ─────────────────────────────────────────────────────────

  /// Turns a preset family on or off.
  ///
  /// Enabling **re-seeds**, which resets any edits to those rows — the toggle's confirmation says
  /// so. Disabling removes only rows still carrying a preset key.
  Future<void> setPresetsEnabled({required bool fleet, required bool enabled}) async {
    if (_busy) return;
    _busy = true;
    _safeNotify();

    final presets = fleet ? kFleetPresets : kHomelabPresets;
    final setting = fleet ? fleetPresetsSetting : homelabPresetsSetting;

    try {
      // One transaction: a half-seeded family with the flag already flipped would show an "on"
      // toggle over a partial list, and re-toggling would not repair it.
      await _app.repository.inTransaction(() async {
        await _app.repository.insertSetting(setting, enabled.toString());
        if (enabled) {
          await _reseed(presets);
        } else {
          await _removePresets(presets);
        }
      });
      if (fleet) {
        _fleetPresetsEnabled = enabled;
      } else {
        _homelabPresetsEnabled = enabled;
      }
      _status = enabled
          ? 'Added ${presets.length} preset scripts.'
          : 'Removed the preset scripts.';
    } finally {
      _busy = false;
      _safeNotify();
    }
  }

  /// Replaces every row carrying one of these preset keys with the seeded version.
  Future<void> _reseed(List<ScriptPreset> presets) async {
    final existing = {
      for (final script in _scripts)
        if (script.presetKey != null) script.presetKey!: script,
    };
    for (final preset in presets) {
      final current = existing[preset.presetKey];
      await _app.repository.insertScript(
        _companion(
          // Reusing the existing row id updates in place rather than accumulating duplicates each
          // time the family is toggled back on.
          id: current?.id,
          emoji: preset.emoji,
          name: preset.name,
          command: preset.command,
          color: preset.color,
          category: preset.category,
          sortOrder: preset.sortOrder,
          availableForQuick: preset.availableForQuick,
          availableForFleet: preset.availableForFleet,
          presetKey: preset.presetKey,
        ),
      );
    }
  }

  /// Deletes the rows this family seeded, matched by key rather than by name or command.
  ///
  /// Matching on text would miss a renamed row and — worse — could delete a user's own script that
  /// happened to share a name.
  Future<void> _removePresets(List<ScriptPreset> presets) async {
    final keys = presets.map((p) => p.presetKey).toSet();
    for (final script in _scripts.where((s) => keys.contains(s.presetKey))) {
      await _app.repository.deleteScriptById(script.id);
    }
  }

  /// Reorders [script] within its category.
  Future<void> moveScript(QuickScript script, int newSortOrder) async {
    await _app.repository
        .insertScript(script.copyWith(sortOrder: newSortOrder).toCompanion(false));
  }

  /// Sets whether [script] appears in the Fleet broadcast picker.
  Future<void> setAvailableForFleet(QuickScript script, bool value) async {
    if (!value && !script.availableForQuick) return;
    await _app.repository
        .insertScript(script.copyWith(availableForFleet: value).toCompanion(false));
  }

  /// Sets whether [script] appears in the per-host Quick Scripts row.
  Future<void> setAvailableForQuick(QuickScript script, bool value) async {
    if (!value && !script.availableForFleet) return;
    await _app.repository
        .insertScript(script.copyWith(availableForQuick: value).toCompanion(false));
  }

  /// The scripts the Fleet screen offers as broadcast presets.
  ///
  /// Sorted the way the Kotlin's picker sorted them: by explicit order, then name.
  List<QuickScript> get fleetPresetScripts {
    final list = _scripts.where((s) => s.availableForFleet).toList()
      ..sort((a, b) {
        final order = a.sortOrder.compareTo(b.sortOrder);
        return order != 0 ? order : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return List.unmodifiable(list);
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}

/// Builds the row companion.
///
/// A null [id] means "new": it is left absent so SQLite assigns one. Passing a literal 0 instead
/// would be taken as a real rowid and, under `InsertMode.replace`, every new script would overwrite
/// the previous one — the §15.3 defect, in a different table.
QuickScriptsCompanion _companion({
  int? id,
  required String emoji,
  required String name,
  required String command,
  required String color,
  required String category,
  int sortOrder = 0,
  bool longRunning = false,
  bool availableForQuick = true,
  bool availableForFleet = false,
  String targetOs = 'Any',
  String targetSystem = 'Any',
  String notes = '',
  String? presetKey,
}) =>
    QuickScriptsCompanion.insert(
      id: id == null || id == 0 ? const Value.absent() : Value(id),
      emoji: emoji,
      name: name,
      command: command,
      color: color,
      longRunning: Value(longRunning),
      category: Value(category),
      sortOrder: Value(sortOrder),
      availableForQuick: Value(availableForQuick),
      availableForFleet: Value(availableForFleet),
      targetOs: Value(targetOs),
      targetSystem: Value(targetSystem),
      notes: Value(notes),
      presetKey: Value(presetKey),
    );
