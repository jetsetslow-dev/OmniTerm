import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';

import 'support/fake_secure_storage.dart';

class _FailingRepository extends AppRepository {
  _FailingRepository(super.db, super.secretStore);
  String? failKey;

  @override
  Future<void> insertSetting(String key, String value) async {
    if (key == failKey) throw StateError('Injected write failure');
    await super.insertSetting(key, value);
  }
}

void main() {
  test(
    'failed PIN removal preserves the PIN and controller until the transaction commits',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = _FailingRepository(db, SecretStore(storage: FakeSecureStorage({})));
      final lock = AppLockController(repo);
      addTearDown(() async {
        lock.dispose();
        await db.close();
      });
      await repo.insertSetting('app_pin', '4821');
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertSetting('biometrics_enabled', 'true');
      await lock.load();
      expect(lock.hasStoredPin, isTrue);
      expect(lock.isLocked, isTrue);
      repo.failKey = 'biometrics_enabled';
      await expectLater(lock.clearPin(), throwsStateError);
      expect(lock.hasStoredPin, isTrue, reason: 'A failed clear must not forget the persisted PIN');
      expect(lock.isLocked, isTrue);
      expect(await repo.getSetting('app_pin'), '4821');
      expect(await repo.getSetting('app_lock_enabled'), 'true');
      expect(await repo.getSetting('biometrics_enabled'), 'true');
      repo.failKey = null;
      await lock.clearPin();
      expect(lock.hasStoredPin, isFalse);
      expect(lock.isLocked, isFalse);
      expect(await repo.getSetting('app_pin'), isNull);
      expect(await repo.getSetting('app_lock_enabled'), 'false');
      expect(await repo.getSetting('biometrics_enabled'), 'false');
    },
  );
}
