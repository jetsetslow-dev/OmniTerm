import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/alert_presets.dart';
import '../../data/app_database.dart';
import '../../domain/alert_breach_tracker.dart';
import '../../domain/alert_evaluation.dart';
import '../../domain/alert_notification.dart';
import '../../platform/alert_notifier.dart';
import 'app_state.dart';

/// Which list the Alerts tool is showing.
enum AlertsTab { active, rules, history }

/// The Alerts tool's state and actions, split out of `AlertsToolView` and `evaluateAlertRules` in
/// `ui/AppViewModel.kt`.
///
/// Owns the rule store, the incidents currently firing, the archive, and the sustained-breach
/// tracking that decides when a rule actually fires.
class AlertsViewModel extends ChangeNotifier {
  AlertsViewModel(this._app, {this.notifier});

  final AppState _app;

  /// Posts fired alerts to the notification shade. Null in tests and in any build without one: the
  /// rule still fires and the incident is still recorded, the user just does not get a banner
  /// (Convention 4).
  ///
  /// Without this, the Alerts screen is a dashboard rather than an alerting system — a rule that
  /// only changes a colour on a screen nobody is looking at has not alerted anyone.
  final AlertNotifier? notifier;

  bool get canNotify => notifier != null;

  /// Sustained-window and hysteresis state. Held here rather than in the tracker's own singleton so
  /// it dies with the screen's owner and cannot leak windows between test runs.
  final AlertBreachTracker _tracker = AlertBreachTracker();

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  List<AlertRule> _rules = const [];
  List<ActiveAlert> _activeAlerts = const [];
  List<AlertHistoryRow> _history = const [];

  StreamSubscription<List<AlertRule>>? _rulesSub;
  StreamSubscription<List<ActiveAlert>>? _alertsSub;
  StreamSubscription<List<AlertHistoryRow>>? _historySub;

  bool _alertsEnabled = true;
  bool _presetsEnabled = false;
  bool _busy = false;
  String? _status;

  /// The master switch. With it off, nothing is evaluated at all — existing incidents stay visible
  /// but no new ones are raised and none resolve, because nothing is being measured against.
  bool get alertsEnabled => _alertsEnabled;

  bool get presetsEnabled => _presetsEnabled;
  bool get busy => _busy;
  String? get status => _status;

  void dismissStatus() {
    _status = null;
    notifyListeners();
  }

  Future<void> start() async {
    _rulesSub ??= _app.repository.rulesStream.listen((list) {
      _rules = list;
      _safeNotify();
    });
    _alertsSub ??= _app.repository.activeAlertsStream.listen((list) {
      _activeAlerts = list;
      _safeNotify();
    });
    _historySub ??= _app.repository.alertHistoryStream.listen((list) {
      _history = list;
      _safeNotify();
    });
    _alertsEnabled = (await _app.repository.getSetting('alerts_enabled'))?.toLowerCase() != 'false';
    _presetsEnabled =
        (await _app.repository.getSetting(alertPresetsSetting))?.toLowerCase() == 'true';
    _safeNotify();
    await refreshNotificationsAllowed();
  }

  /// Re-reads whether alerts can reach the shade, without prompting. Called on start and whenever
  /// the app resumes, so a permission granted or revoked in system settings shows up at once — as
  /// Kotlin re-reads it on every resume.
  Future<void> refreshNotificationsAllowed() async {
    final target = notifier;
    if (target == null) return;
    final allowed = await target.notificationsEnabled();
    if (_disposed) return;
    _notificationsAllowed = allowed;
    _safeNotify();
  }

  /// Whether the platform will show notifications; null until read.
  ///
  /// Surfaced so the screen can say that alerts will fire but nothing will appear in the shade —
  /// which is a working feature the user cannot see, and the least obvious kind of broken.
  bool? _notificationsAllowed;

  bool? get notificationsAllowed => _notificationsAllowed;

  Future<void> setAlertsEnabled(bool enabled) async {
    _alertsEnabled = enabled;
    notifyListeners();
    await _app.repository.insertSetting('alerts_enabled', enabled.toString());

    // Asked here rather than at launch: the system prompt arrives with the context that explains
    // it, and a user who never turns alerts on is never interrupted by it. Turning alerts *off*
    // asks nothing.
    if (enabled) {
      _notificationsAllowed = await notifier?.ensurePermission();
      _safeNotify();
    }
  }

  // ── tabs and lists ──────────────────────────────────────────────────────────

  AlertsTab _activeTab = AlertsTab.active;

  AlertsTab get activeTab => _activeTab;

  set activeTab(AlertsTab value) {
    if (_activeTab == value) return;
    _activeTab = value;
    notifyListeners();
  }

  List<AlertRule> get rules => List.unmodifiable(_rules);
  List<AlertHistoryRow> get history => List.unmodifiable(_history);

  /// Firing incidents, newest first — Kotlin's `ORDER BY triggeredTime DESC`.
  List<ActiveAlert> get activeAlerts {
    final list = [..._activeAlerts]..sort((a, b) => b.triggeredTime.compareTo(a.triggeredTime));
    return List.unmodifiable(list);
  }

  /// Incidents that are firing and not muted — what a badge should count.
  int get unmutedCount {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _activeAlerts.where((a) => a.mutedUntil <= now).length;
  }

  /// Hosts a rule can be scoped to.
  List<Server> get hosts => _app.servers;

  /// The host a rule or incident belongs to, or null for a fleet-wide rule.
  Server? serverFor(int serverId) => _app.servers.where((s) => s.id == serverId).firstOrNull;

  /// A label for a rule's scope. Rules with `serverId == 0` apply to every host.
  String scopeLabel(int serverId) {
    if (serverId == 0) return 'All hosts';
    return serverFor(serverId)?.name ?? 'Host #$serverId';
  }

  // ── rules ───────────────────────────────────────────────────────────────────

  /// Saves a rule, inserting when [existing] is null. Returns null on success.
  Future<String?> saveRule({
    AlertRule? existing,
    required String metricName,
    required double thresholdValue,
    required String severity,
    String triggerWindow = '5m',
    int serverId = 0,
    String mountPoint = '/',
    bool enabled = true,
    String notes = '',
  }) async {
    if (!alertMetrics.contains(metricName)) return 'Pick a metric to watch.';
    if (!alertSeverities.contains(severity)) return 'Pick a severity.';
    if (!alertWindows.contains(triggerWindow)) return 'Pick a trigger window.';
    // Kotlin's bounds: a percentage above 100 can never be reached, so the rule would be dead on
    // arrival — worse than one that fires too often, because nothing signals that it is broken.
    final thresholdError = alertCanonicalThresholdError(thresholdValue, metricName);
    if (thresholdError != null) return thresholdError;

    await _app.repository.insertRule(
      AlertRulesCompanion.insert(
        id: existing == null ? const Value.absent() : Value(existing.id),
        serverId: serverId,
        metricName: metricName,
        mountPoint: Value(metricName == 'Disk Usage' ? mountPoint : '/'),
        thresholdValue: thresholdValue,
        severity: severity,
        triggerWindow: Value(triggerWindow),
        enabled: Value(enabled),
        notes: Value(notes),
        // An edited preset keeps its key so a later "disable defaults" still removes it, while its
        // changed threshold makes a backup treat it as the user's and preserve the retune.
        presetKey: Value(existing?.presetKey),
      ),
    );

    if (existing != null) {
      final updated = existing.copyWith(
        metricName: metricName,
        mountPoint: metricName == 'Disk Usage' ? mountPoint : '/',
        thresholdValue: thresholdValue,
        severity: severity,
        triggerWindow: triggerWindow,
        serverId: serverId,
        enabled: enabled,
      );
      if (ruleEditInvalidatesIncident(existing, updated)) {
        // The incident was raised under terms that no longer apply, so keeping it would report a
        // breach against a threshold the rule no longer has.
        await _clearIncidentsForRule(existing.id);
      }
    }

    _status = 'Saved the rule.';
    _safeNotify();
    return null;
  }

  Future<void> setRuleEnabled(AlertRule rule, bool enabled) async {
    await _app.repository.insertRule(rule.copyWith(enabled: enabled).toCompanion(false));
    if (!enabled) {
      // A disabled rule cannot re-evaluate, so leaving its incident would strand a banner that can
      // never resolve on its own.
      await _clearIncidentsForRule(rule.id);
    }
  }

  Future<void> deleteRule(AlertRule rule) async {
    await _clearIncidentsForRule(rule.id);
    await _app.repository.deleteRuleById(rule.id);
    _status = 'Deleted the rule.';
    _safeNotify();
  }

  /// Drops every incident and breach window belonging to [ruleId].
  Future<void> _clearIncidentsForRule(int ruleId) async {
    _tracker.forgetRule(ruleId);
    for (final alert in (await _app.repository.getActiveAlerts()).where(
      (a) => a.ruleId == ruleId,
    )) {
      // Kotlin's `closeAlertsForRule` archives these as resolved whatever the cause.
      await _archive(alert, 'resolved');
      await _app.repository.deleteAlert(alert.id);
      await notifier?.clear(alertNotificationId(alert.ruleId, alert.serverId));
    }
  }

  /// True when [rule] is a default the user has not retuned.
  bool isPristinePresetRule(AlertRule rule) {
    final key = rule.presetKey;
    if (key == null) return false;
    final preset = kAlertPresets.where((p) => p.presetKey == key).firstOrNull;
    if (preset == null) return false;
    return isPristineAlertPreset(preset, rule.thresholdValue, rule.severity);
  }

  // ── default rules ───────────────────────────────────────────────────────────

  Future<void> setPresetsEnabled(bool enabled) async {
    if (_busy) return;
    _busy = true;
    _safeNotify();
    try {
      await _app.repository.inTransaction(() async {
        await _app.repository.insertSetting(alertPresetsSetting, enabled.toString());
        if (enabled) {
          await _seedPresets();
        } else {
          await _removePresets();
        }
      });
      _presetsEnabled = enabled;
      _status = enabled ? 'Added the default rules.' : 'Removed the default rules.';
    } finally {
      _busy = false;
      _safeNotify();
    }
  }

  Future<void> _seedPresets() async {
    final existing = {
      for (final rule in _rules)
        if (rule.presetKey != null) rule.presetKey!: rule,
    };
    for (final preset in kAlertPresets) {
      final current = existing[preset.presetKey];
      await _app.repository.insertRule(
        AlertRulesCompanion.insert(
          // Reusing the row id updates in place, so toggling the family does not accumulate copies.
          id: current == null ? const Value.absent() : Value(current.id),
          serverId: 0,
          metricName: preset.metricName,
          thresholdValue: preset.thresholdValue,
          severity: preset.severity,
          presetKey: Value(preset.presetKey),
        ),
      );
    }
  }

  Future<void> _removePresets() async {
    final keys = kAlertPresets.map((p) => p.presetKey).toSet();
    for (final rule in _rules.where((r) => keys.contains(r.presetKey))) {
      await _clearIncidentsForRule(rule.id);
      await _app.repository.deleteRuleById(rule.id);
    }
  }

  // ── incidents ───────────────────────────────────────────────────────────────

  /// Evaluates every enabled rule for [server] against [sample].
  ///
  /// Called by the telemetry path once per poll. Returns the incidents raised on this pass, so the
  /// caller can decide whether to notify — this class deliberately does not touch notifications.
  Future<List<ActiveAlert>> evaluate(
    Server server,
    AlertSample sample, {
    int telemetryIntervalMs = 15000,
    int? nowMs,
  }) async {
    if (!_alertsEnabled) return const [];
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final gap = staleGapMs(telemetryIntervalMs);
    final raised = <ActiveAlert>[];

    // Read straight from the store rather than the stream-backed caches. The streams lag their own
    // writes by a microtask, so two evaluations in quick succession — several hosts in one poll, or
    // a host whose incident was raised moments earlier — would not see what this method just wrote,
    // and an incident could be raised twice or never resolved.
    final rules = await _app.repository.getAllRules();
    final active = await _app.repository.getActiveAlerts();

    // A fleet-wide rule (serverId 0) applies to every host alongside that host's own rules.
    final applicable = rules.where(
      (r) => r.enabled && (r.serverId == server.id || r.serverId == 0),
    );

    for (final rule in applicable) {
      final value = currentValueFor(rule, sample);
      final over = value != null && value > rule.thresholdValue;
      final key = (rule.id, server.id);

      final triggered = _tracker.onSample(
        key,
        over: over,
        now: now,
        windowMs: triggerWindowMs(rule.triggerWindow),
        staleGapMs: gap,
      );

      // A fleet-wide rule shares one id across hosts, so the host must be part of the match or one
      // machine's incident would suppress every other machine's.
      final existing = active
          .where((a) => a.ruleId == rule.id && a.serverId == server.id)
          .firstOrNull;
      var currentAlert = existing;
      if (currentAlert != null && value != null && currentAlert.currentValue != value) {
        // Update only the reading. Replacing the whole row would reset acknowledgement or mute
        // state and make a refresh itself change the user's incident actions.
        await _app.repository.updateAlertCurrentValue(currentAlert.id, value);
        final refreshed = currentAlert.copyWith(currentValue: value);
        active[active.indexOf(currentAlert)] = refreshed;
        currentAlert = refreshed;
      }

      if (triggered) {
        final muted = currentAlert != null && currentAlert.mutedUntil > now;
        if (currentAlert == null && !muted) {
          final alert = ActiveAlert(
            id: 0,
            ruleId: rule.id,
            serverId: server.id,
            metricName: rule.metricName,
            currentValue: value ?? 0,
            thresholdValue: rule.thresholdValue,
            severity: rule.severity,
            triggeredTime: now,
            acknowledged: false,
            mutedUntil: 0,
          );
          final id = await _app.repository.insertAlert(
            alert.toCompanion(false).copyWith(id: const Value.absent()),
          );
          final stored = alert.copyWith(id: id);
          active.add(stored);
          raised.add(stored);
          await _notifyRaised(server, rule, stored);
        }
      } else if (!over && _tracker.clearedFor(key) && currentAlert != null) {
        // Resolved — but only after enough consecutive clean samples, so one jittery dip does not
        // flap the incident closed and straight back open.
        await _archive(currentAlert, 'resolved');
        await _app.repository.deleteAlert(currentAlert.id);
        // The banner goes when the incident does. A notification left in the shade for a host that
        // recovered hours ago is how a user learns to swipe them all away unread.
        await notifier?.clear(alertNotificationId(currentAlert.ruleId, currentAlert.serverId));
      }
    }

    return raised;
  }

  /// Acknowledges [alert], recording it in history and clearing its banner as Kotlin does.
  Future<void> acknowledge(ActiveAlert alert) async {
    await _archive(alert, 'acknowledged');
    await notifier?.clear(alertNotificationId(alert.ruleId, alert.serverId));
    await _app.repository.acknowledgeAlert(alert.id);
  }

  Future<void> acknowledgeAll() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final alert in (await _app.repository.getActiveAlerts()).where(
      (alert) => !alert.acknowledged && alert.mutedUntil < now,
    )) {
      await acknowledge(alert);
    }
  }

  /// Silences [alert] for [duration].
  ///
  /// Muting keeps the incident visible but stops it re-raising — the point is to stop being told
  /// about something you already know, not to pretend it is fixed.
  Future<void> mute(ActiveAlert alert, Duration duration) async {
    final until = DateTime.now().millisecondsSinceEpoch + duration.inMilliseconds;
    await _archive(alert, 'muted');
    await notifier?.clear(alertNotificationId(alert.ruleId, alert.serverId));
    await _app.repository.muteAlert(alert.id, until);
  }

  /// Ends a mute early. Like Kotlin's `unmuteAlert`, an unacknowledged incident re-posts its banner.
  Future<void> unmute(ActiveAlert alert) async {
    await _app.repository.muteAlert(alert.id, 0);
    await _archive(alert.copyWith(mutedUntil: 0), 'unmuted');
    if (!_alertsEnabled || alert.acknowledged) return;
    final target = notifier;
    final server = serverFor(alert.serverId);
    final rule = _rules.where((r) => r.id == alert.ruleId).firstOrNull;
    if (target == null || server == null || rule == null) return;
    try {
      await _post(target, server, rule, alert);
    } catch (_) {
      // The incident stays listed either way.
    }
  }

  /// Dismisses [alert] without waiting for it to resolve.
  Future<void> dismiss(ActiveAlert alert) async {
    _tracker.forget((alert.ruleId, alert.serverId));
    await _archive(alert, 'dismissed');
    await _app.repository.deleteAlert(alert.id);
    await notifier?.clear(alertNotificationId(alert.ruleId, alert.serverId));
  }

  /// Posts the banner for a newly raised incident.
  ///
  /// Guarded here rather than only inside the notifier: the incident is already recorded by this
  /// point, and a notification service that throws must not abort the evaluation loop and take
  /// every *other* rule's result down with it. The banner is a courtesy; the incident is the record.
  Future<void> _notifyRaised(Server server, AlertRule rule, ActiveAlert alert) async {
    final target = notifier;
    if (target == null) return;
    try {
      await _post(target, server, rule, alert);
    } catch (_) {
      // Nothing to recover: the alert is stored and visible in the app either way.
    }
  }

  Future<void> _post(AlertNotifier target, Server server, AlertRule rule, ActiveAlert alert) =>
      target.post(
        buildAlertNotification(
          ruleId: rule.id,
          serverId: server.id,
          // The host's real name, not a masked one: "hide addresses" is for a shared screen, and a
          // notification the user cannot attribute to a machine is useless at 3am.
          serverName: server.name,
          severity: rule.severity,
          metricName: rule.metricName,
          mountPoint: rule.mountPoint,
          value: alert.currentValue,
          threshold: rule.thresholdValue,
          system: _app.measurementSystem,
        ),
      );

  Future<void> _archive(ActiveAlert alert, String status) async {
    await _app.repository.insertAlertHistory(
      AlertHistoryCompanion.insert(
        activeAlertId: alert.id,
        serverId: alert.serverId,
        // Denormalised on purpose: an archive entry must stay readable after the host is deleted,
        // and a dangling id would render as a number nobody can identify.
        serverName: serverFor(alert.serverId)?.name ?? 'server',
        metricName: alert.metricName,
        currentValue: alert.currentValue,
        thresholdValue: alert.thresholdValue,
        severity: alert.severity,
        triggeredTime: alert.triggeredTime,
        historyTime: DateTime.now().millisecondsSinceEpoch,
        status: status,
      ),
    );
    // Applied on every insert, as Kotlin does at `AppViewModel.kt:10845`. Without it the "Alert
    // history limit" setting does nothing at all and the table grows for the life of the install —
    // a monitoring app archives an incident every time one resolves.
    await _app.repository.pruneAlertHistoryForServer(alert.serverId, _app.alertHistoryLimit);
  }

  /// Applies the retention cap to every host.
  ///
  /// Needed because the per-host prune only runs when that host archives something: lowering the
  /// setting, or restoring a backup full of history, would otherwise leave the excess in place
  /// indefinitely. Kotlin prunes at both points too (`AppViewModel.kt:10536` and `:11804`).
  Future<void> applyHistoryRetention() =>
      _app.repository.pruneAlertHistoryPerServer(_app.alertHistoryLimit);

  Future<void> clearHistory() async {
    await _app.repository.clearAlertHistory();
    _status = 'Cleared the history.';
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    _rulesSub?.cancel();
    _alertsSub?.cancel();
    _historySub?.cancel();
    super.dispose();
  }
}
