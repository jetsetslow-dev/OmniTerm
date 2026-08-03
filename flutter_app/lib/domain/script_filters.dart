import '../data/app_database.dart';
import '../data/remote_models.dart';

/// Quick-script targeting, ported from `ui/ScriptFilters.kt`.
///
/// A script is offered on a host only when its declared OS and system targets match what the
/// metrics probe actually detected there, so a Proxmox helper never appears on a Raspberry Pi.

const quickScriptOsOptions = <String>['Any', 'Linux', 'FreeBSD', 'Darwin', 'Windows'];

const quickScriptSystemOptions = <String>[
  'Any',
  'Proxmox',
  'CasaOS',
  'Home Assistant',
  'Raspberry Pi',
  'Docker',
];

bool quickScriptMatchesHost(QuickScript script, HostMetrics? metrics) {
  if (!script.availableForQuick) return false;

  final os = metrics?.os ?? '';
  final platforms = metrics?.platforms ?? const <String>{};

  final osMatches = script.targetOs.toLowerCase() == 'any' ||
      script.targetOs.trim().isEmpty ||
      os.toLowerCase() == script.targetOs.toLowerCase() ||
      platforms.contains(script.targetOs.toLowerCase());

  final systemMatches = script.targetSystem.toLowerCase() == 'any' ||
      script.targetSystem.trim().isEmpty ||
      platforms.contains(systemPlatformKey(script.targetSystem));

  // Rows created before targetOs/targetSystem existed carry their targeting in the category name.
  final legacyKey = legacyCategoryPlatformKey(script.category);
  final legacyMatches = legacyKey == null || platforms.contains(legacyKey);

  return osMatches && systemMatches && legacyMatches;
}

/// The platform key implied by a pre-targeting category name, or null when the category says
/// nothing about the host (a user-made "Backups" category must not filter anything out).
String? legacyCategoryPlatformKey(String category) => switch (category) {
      'Linux' => 'linux',
      'FreeBSD' => 'freebsd',
      'Darwin' => 'darwin',
      'Windows' => 'windows',
      'Proxmox' => 'proxmox',
      'CasaOS' => 'casaos',
      'Home Assistant' => 'homeassistant',
      'Raspberry Pi' => 'raspberry',
      _ => null,
    };

/// Maps a display name to the key the metrics probe emits in its `@PLATFORM` section.
String systemPlatformKey(String system) => switch (system) {
      'Home Assistant' => 'homeassistant',
      'Raspberry Pi' => 'raspberry',
      _ => system.toLowerCase().replaceAll(' ', ''),
    };
