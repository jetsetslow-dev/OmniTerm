// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_data_dao.dart';

// ignore_for_file: type=lint
mixin _$AppDataDaoMixin on DatabaseAccessor<AppDatabase> {
  $SshKeysTable get sshKeys => attachedDatabase.sshKeys;
  $CredentialProfilesTable get credentialProfiles =>
      attachedDatabase.credentialProfiles;
  $QuickScriptsTable get quickScripts => attachedDatabase.quickScripts;
  $PortForwardsTable get portForwards => attachedDatabase.portForwards;
  $WolTargetsTable get wolTargets => attachedDatabase.wolTargets;
  $NetworkSharesTable get networkShares => attachedDatabase.networkShares;
  $StackRegistryTable get stackRegistry => attachedDatabase.stackRegistry;
  $AppSettingsTable get appSettings => attachedDatabase.appSettings;
  $PersistentSessionsTable get persistentSessions =>
      attachedDatabase.persistentSessions;
  AppDataDaoManager get managers => AppDataDaoManager(this);
}

class AppDataDaoManager {
  final _$AppDataDaoMixin _db;
  AppDataDaoManager(this._db);
  $$SshKeysTableTableManager get sshKeys =>
      $$SshKeysTableTableManager(_db.attachedDatabase, _db.sshKeys);
  $$CredentialProfilesTableTableManager get credentialProfiles =>
      $$CredentialProfilesTableTableManager(
        _db.attachedDatabase,
        _db.credentialProfiles,
      );
  $$QuickScriptsTableTableManager get quickScripts =>
      $$QuickScriptsTableTableManager(_db.attachedDatabase, _db.quickScripts);
  $$PortForwardsTableTableManager get portForwards =>
      $$PortForwardsTableTableManager(_db.attachedDatabase, _db.portForwards);
  $$WolTargetsTableTableManager get wolTargets =>
      $$WolTargetsTableTableManager(_db.attachedDatabase, _db.wolTargets);
  $$NetworkSharesTableTableManager get networkShares =>
      $$NetworkSharesTableTableManager(_db.attachedDatabase, _db.networkShares);
  $$StackRegistryTableTableManager get stackRegistry =>
      $$StackRegistryTableTableManager(_db.attachedDatabase, _db.stackRegistry);
  $$AppSettingsTableTableManager get appSettings =>
      $$AppSettingsTableTableManager(_db.attachedDatabase, _db.appSettings);
  $$PersistentSessionsTableTableManager get persistentSessions =>
      $$PersistentSessionsTableTableManager(
        _db.attachedDatabase,
        _db.persistentSessions,
      );
}
