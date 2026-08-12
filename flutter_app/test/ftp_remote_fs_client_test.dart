import 'package:flutter_test/flutter_test.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:omniterm/data/shares/ftp_remote_fs_client.dart';

void main() {
  test('FTP uses structured MLSD only when the server advertises it', () {
    expect(
      ftpListCommandForFeatures('211-Features:\n MLST type*;size*;modify*;\n211 End'),
      ListCommand.mlsd,
    );
    expect(ftpListCommandForFeatures('211-Features:\n MLSD\n211 End'), ListCommand.mlsd);
  });

  test('FTP falls back to portable LIST when MLSD is unavailable', () {
    expect(
      ftpListCommandForFeatures('211-Features:\n EPSV\n MDTM\n SIZE\n UTF8\n211 End'),
      ListCommand.list,
    );
    expect(ftpListCommandForFeatures('500 Unknown command.'), ListCommand.list);
  });
}
