/// Seeded identities for preset rows created before the `presetKey` column existed.
///
/// Ported verbatim from `LEGACY_SCRIPT_PRESET_KEYS` / `LEGACY_RULE_PRESETS` in
/// `data/AppDatabase.kt`. These are used only by the 19 → 20 migration, which back-stamps a stable
/// key onto rows the app originally seeded so the "default presets" toggles can later delete
/// exactly what they created rather than matching on mutable name/command text.
///
/// The values are historical facts about databases already on users' devices — they must never be
/// "tidied up". A changed name here means a row silently stops being recognised as a preset.
library;

class LegacyScriptPreset {
  const LegacyScriptPreset(this.key, this.name, this.category, this.familySetting);

  final String key;
  final String name;
  final String category;

  /// The `app_settings` key whose value must be 'true' for this row to be claimed as a preset.
  final String familySetting;
}

const kLegacyScriptPresets = <LegacyScriptPreset>[
  LegacyScriptPreset('fleet.cpu', 'CPU/RAM', 'Fleet', 'fleet_presets'),
  LegacyScriptPreset('fleet.disk', 'Disk', 'Fleet', 'fleet_presets'),
  LegacyScriptPreset('fleet.processes', 'Processes', 'Fleet', 'fleet_presets'),
  LegacyScriptPreset('fleet.services', 'Failed services', 'Fleet', 'fleet_presets'),
  LegacyScriptPreset('fleet.syslog', 'Syslog errors', 'Fleet', 'fleet_presets'),
  LegacyScriptPreset('fleet.containers', 'Containers', 'Fleet', 'fleet_presets'),
  LegacyScriptPreset('fleet.ports', 'Listening ports', 'Fleet', 'fleet_presets'),
  LegacyScriptPreset('fleet.kernel', 'Kernel', 'Fleet', 'fleet_presets'),
  LegacyScriptPreset('homelab.pve_vms', 'PVE: list VMs', 'Proxmox', 'homelab_presets'),
  LegacyScriptPreset(
    'homelab.pve_containers',
    'PVE: list containers',
    'Proxmox',
    'homelab_presets',
  ),
  LegacyScriptPreset('homelab.pve_cluster', 'PVE: cluster status', 'Proxmox', 'homelab_presets'),
  LegacyScriptPreset('homelab.pve_storage', 'PVE: storage status', 'Proxmox', 'homelab_presets'),
  LegacyScriptPreset('homelab.pve_start_vm', 'PVE: start VM <id>', 'Proxmox', 'homelab_presets'),
  LegacyScriptPreset('homelab.pve_stop_vm', 'PVE: stop VM <id>', 'Proxmox', 'homelab_presets'),
  LegacyScriptPreset('homelab.casaos_status', 'CasaOS: status', 'CasaOS', 'homelab_presets'),
  LegacyScriptPreset('homelab.casaos_restart', 'CasaOS: restart', 'CasaOS', 'homelab_presets'),
  LegacyScriptPreset('homelab.casaos_version', 'CasaOS: version', 'CasaOS', 'homelab_presets'),
  LegacyScriptPreset('homelab.ha_info', 'HA: info', 'Home Assistant', 'homelab_presets'),
  LegacyScriptPreset('homelab.ha_core_logs', 'HA: core logs', 'Home Assistant', 'homelab_presets'),
  LegacyScriptPreset(
    'homelab.ha_restart_core',
    'HA: restart core',
    'Home Assistant',
    'homelab_presets',
  ),
  LegacyScriptPreset(
    'homelab.ha_supervisor_logs',
    'HA: supervisor logs',
    'Home Assistant',
    'homelab_presets',
  ),
  LegacyScriptPreset('homelab.temperature', 'Temperature', 'Linux', 'homelab_presets'),
  LegacyScriptPreset('homelab.updates', 'Updates available', 'Homelab', 'homelab_presets'),
  LegacyScriptPreset('homelab.reboot_required', 'Reboot required?', 'Homelab', 'homelab_presets'),
  LegacyScriptPreset('homelab.top_cpu', 'Top 10 by CPU', 'Homelab', 'homelab_presets'),
  LegacyScriptPreset('homelab.docker_stats', 'Docker stats', 'Homelab', 'homelab_presets'),
  LegacyScriptPreset('homelab.disk_usage', 'Disk usage', 'Homelab', 'homelab_presets'),
];

class LegacyRulePreset {
  const LegacyRulePreset(this.key, this.metric, this.threshold, this.severity);

  final String key;
  final String metric;
  final double threshold;
  final String severity;
}

/// Exact pristine alert identities predating `presetKey`.
const kLegacyRulePresets = <LegacyRulePreset>[
  LegacyRulePreset('alert.cpu', 'CPU Usage', 90, 'CRITICAL'),
  LegacyRulePreset('alert.memory', 'Memory Usage', 90, 'CRITICAL'),
  LegacyRulePreset('alert.disk', 'Disk Usage', 90, 'WARNING'),
  LegacyRulePreset('alert.latency', 'Latency', 250, 'WARNING'),
];
