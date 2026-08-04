import '../data/remote_models.dart';

/// Directory listing orders, ported from `SftpSortOption` in `ui/AppViewModel.kt`.
enum SftpSortOption {
  nameAsc('Name A-Z'),
  nameDesc('Name Z-A'),
  modifiedAsc('Modified oldest'),
  modifiedDesc('Modified newest'),
  sizeAsc('Size smallest'),
  sizeDesc('Size largest'),
  typeFoldersFirst('Folders first'),
  typeFilesFirst('Files first');

  const SftpSortOption(this.label);

  final String label;
}

/// Orders a directory listing, ported from `sortEntriesBy`.
///
/// Shared by the SFTP browser and the Shares browser so both agree on what "sorted" means.
///
/// **Directories lead in every mode except [SftpSortOption.typeFilesFirst].** That is deliberate
/// even for size and date: a directory's reported size is its inode's, not its contents', so
/// interleaving them by size would order folders by a number that means nothing to the user.
List<SftpFile> sortEntries(List<SftpFile> entries, SftpSortOption option) {
  // Case-insensitive first so `Apple` and `apple` sit together, then case-sensitive to break the
  // tie — otherwise two names differing only in case would order unpredictably between runs.
  int byName(SftpFile a, SftpFile b) {
    final lower = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return lower != 0 ? lower : a.name.compareTo(b.name);
  }

  int directoriesFirst(SftpFile a, SftpFile b) {
    if (a.isDirectory == b.isDirectory) return 0;
    return a.isDirectory ? -1 : 1;
  }

  int compare(SftpFile a, SftpFile b) {
    if (option == SftpSortOption.typeFilesFirst) {
      final byType = -directoriesFirst(a, b);
      return byType != 0 ? byType : byName(a, b);
    }

    final byType = directoriesFirst(a, b);
    if (byType != 0) return byType;

    return switch (option) {
      SftpSortOption.nameAsc || SftpSortOption.typeFoldersFirst => byName(a, b),
      SftpSortOption.nameDesc => -byName(a, b),
      SftpSortOption.modifiedAsc => _thenName(
          a.modTimeSeconds.compareTo(b.modTimeSeconds), a, b, byName),
      SftpSortOption.modifiedDesc => _thenName(
          b.modTimeSeconds.compareTo(a.modTimeSeconds), a, b, byName),
      SftpSortOption.sizeAsc => _thenName(a.size.compareTo(b.size), a, b, byName),
      SftpSortOption.sizeDesc => _thenName(b.size.compareTo(a.size), a, b, byName),
      SftpSortOption.typeFilesFirst => byName(a, b),
    };
  }

  return [...entries]..sort(compare);
}

/// Falls back to name so equal sizes or timestamps still produce a stable, predictable order.
int _thenName(
  int primary,
  SftpFile a,
  SftpFile b,
  int Function(SftpFile, SftpFile) byName,
) =>
    primary != 0 ? primary : byName(a, b);
