// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'alerts_dao.dart';

// ignore_for_file: type=lint
mixin _$AlertsDaoMixin on DatabaseAccessor<AppDatabase> {
  $AlertRulesTable get alertRules => attachedDatabase.alertRules;
  $ActiveAlertsTable get activeAlerts => attachedDatabase.activeAlerts;
  $AlertHistoryTable get alertHistory => attachedDatabase.alertHistory;
  AlertsDaoManager get managers => AlertsDaoManager(this);
}

class AlertsDaoManager {
  final _$AlertsDaoMixin _db;
  AlertsDaoManager(this._db);
  $$AlertRulesTableTableManager get alertRules =>
      $$AlertRulesTableTableManager(_db.attachedDatabase, _db.alertRules);
  $$ActiveAlertsTableTableManager get activeAlerts =>
      $$ActiveAlertsTableTableManager(_db.attachedDatabase, _db.activeAlerts);
  $$AlertHistoryTableTableManager get alertHistory =>
      $$AlertHistoryTableTableManager(_db.attachedDatabase, _db.alertHistory);
}
