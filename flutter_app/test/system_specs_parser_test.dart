import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/system_specs.dart';

import 'fixtures/system_specs_fixtures.dart';

/// Each OS family's specs output, as its own tools print it, into the same sections.
///
/// Mirrors `SystemSpecsParserTest` in the Kotlin app, with the same fixtures.
void main() {
  String? value(SystemSpecs specs, SpecKind kind, String label) =>
      specs.section(kind)?.fields.where((f) => f.label == label).firstOrNull?.value;

  SpecItem? item(SystemSpecs specs, SpecKind kind, String titleStart) =>
      specs.section(kind)?.items.where((i) => i.title.startsWith(titleStart)).firstOrNull;

  String? fieldOf(SpecItem? item, String label) =>
      item?.fields.where((f) => f.label == label).firstOrNull?.value;

  test('linux system and cpu read lscpu with its nested groups', () {
    final specs = parseSystemSpecs('Linux', linuxCommon);
    expect(value(specs, SpecKind.system, 'Operating system'), 'Ubuntu 24.04.1 LTS');
    expect(value(specs, SpecKind.system, 'Kernel'), '6.8.0-45-generic');
    expect(value(specs, SpecKind.system, 'Product'), 'OptiPlex 7080');
    expect(
      value(specs, SpecKind.system, 'Virtualization'),
      isNull,
      reason: 'Bare metal says nothing about virtualization',
    );
    expect(value(specs, SpecKind.system, 'Chassis'), 'Desktop');
    expect(value(specs, SpecKind.system, 'Family'), isNull, reason: 'NA is firmware filler');
    expect(specs.uptimeSeconds, 93784);

    expect(
      specs.section(SpecKind.cpu)!.summary,
      'Intel(R) Core(TM) i5-10400 CPU @ 2.90GHz · 6 cores · 12 threads · 4.30 GHz',
    );
    expect(value(specs, SpecKind.cpu, 'L2'), '1.5 MiB (6 instances)');
    expect(value(specs, SpecKind.cpu, 'microcode'), '0xf8');
    expect(
      value(specs, SpecKind.cpu, 'Flags'),
      isNull,
      reason: 'Flags are their own item, not a field',
    );
    expect(item(specs, SpecKind.cpu, 'Vulnerabilities')!.summary, '1 of 2 need mitigation');
    expect(item(specs, SpecKind.cpu, 'Flags')!.summary, '5 flags');
    expect(
      fieldOf(item(specs, SpecKind.cpu, 'Frequency'), 'Now'),
      '800 MHz – 4.30 GHz, average 2.40 GHz across 3 cores',
    );
  });

  test('linux without root says modules and drive health need it', () {
    final specs = parseSystemSpecs('Linux', linuxCommon);
    expect(specs.section(SpecKind.memory)!.notices, [SpecNotice.modulesNeedRoot]);
    expect(specs.section(SpecKind.storage)!.notices, [SpecNotice.driveHealthNeedsRoot]);
    expect(specs.wouldGainFromSudo, isTrue);
    expect(specs.sudoError, isNull);
  });

  test("linux as root lists each memory slot and the drive's smart data", () {
    final specs = parseSystemSpecs('Linux', '$privileged\n$linuxCommon');
    final memory = specs.section(SpecKind.memory)!;
    expect(memory.notices, isEmpty);
    expect(specs.wouldGainFromSudo, isFalse);
    expect(memory.summary, '15.5 GB · 1 of 4 slots used · DDR4 2666 MT/s');
    final dimm1 = item(specs, SpecKind.memory, 'DIMM1')!;
    expect(dimm1.title, 'DIMM1 · BANK 0');
    expect(fieldOf(dimm1, 'Part Number'), 'KHX3200C16D4/16GX');
    expect(
      dimm1.fields.any((f) => f.label == 'Asset Tag'),
      isFalse,
      reason: 'Placeholders are dropped',
    );
    expect(item(specs, SpecKind.memory, 'DIMM2')!.summary, 'Empty');
    expect(value(specs, SpecKind.memory, 'Maximum Capacity'), '128 GB');

    final drive = item(specs, SpecKind.storage, 'nvme0n1')!;
    expect(drive.summary, '476.9 GB · NVMe SSD · NVME · PASSED');
    final labels = drive.fields.map((f) => f.label).toList();
    expect(labels, containsAll(['Percentage Used', 'Power On Hours']));
    expect(
      labels,
      isNot(contains('Model Number')),
      reason: 'The model smartctl repeats is shown once',
    );
    expect(
      labels,
      isNot(contains('Local Time is')),
      reason: "smartctl's clock is not a drive property",
    );
    expect(
      fieldOf(drive, 'nvme0n1p2'),
      '475.9 GB · ext4 · "root disk" · / · 93.6 GB used of 468.0 GB (20%)',
    );
  });

  test('linux storage leaves out loop devices and lists network mounts separately', () {
    final specs = parseSystemSpecs('Linux', linuxCommon);
    expect(item(specs, SpecKind.storage, 'loop0'), isNull);
    expect(
      item(specs, SpecKind.storage, 'sdb'),
      isNull,
      reason: 'An empty card reader is not a drive',
    );
    final efi = fieldOf(item(specs, SpecKind.storage, 'nvme0n1'), 'nvme0n1p1')!;
    expect(efi, isNot(contains('""')), reason: 'An empty label is not shown as ""');
    final other = item(specs, SpecKind.storage, 'Other filesystems')!;
    expect(other.fields.map((f) => f.label), ['/mnt/nas']);
    expect(specs.section(SpecKind.storage)!.summary, '1 drive · 476.9 GB');
  });

  test('linux graphics names each card and adds nvidia-smi detail to its own card', () {
    final specs = parseSystemSpecs('Linux', linuxCommon);
    final intel = item(specs, SpecKind.gpu, 'CometLake');
    expect(fieldOf(intel, 'Driver'), 'i915');
    final nvidia = item(specs, SpecKind.gpu, 'NVIDIA GeForce RTX 3090');
    expect(fieldOf(nvidia, 'Video memory'), '24576 MiB');
    expect(fieldOf(nvidia, 'PCIe link'), 'Gen 4 x16');
    expect(fieldOf(intel, 'VBIOS'), isNull);
  });

  test("linux network shows the adapter's name and skips link-local addresses", () {
    final nic = item(parseSystemSpecs('Linux', linuxCommon), SpecKind.network, 'eno1')!;
    expect(nic.summary, '1 Gb/s · up · 192.168.1.10/24');
    expect(fieldOf(nic, 'Adapter'), 'Ethernet Connection (11) I219-LM');
    expect(fieldOf(nic, 'IPv6'), isNull);
  });

  test("a refused sudo is reported in sudo's own words", () {
    final specs = parseSystemSpecs('Linux', 'sudo: a password is required\n$linuxCommon');
    expect(specs.sudoError, 'sudo: a password is required');
    expect(specs.wouldGainFromSudo, isTrue);
  });

  test('missing tools are named instead of asking for root again', () {
    final specs = parseSystemSpecs(
      'Linux',
      '@PRIV\n@DIMM\n$specsMissing\n@SMART\n$specsMissing\n$linuxCommon',
    );
    expect(specs.section(SpecKind.memory)!.notices, [SpecNotice.modulesToolMissing]);
    expect(specs.section(SpecKind.storage)!.notices, [SpecNotice.driveHealthToolMissing]);
    expect(specs.wouldGainFromSudo, isFalse);
  });

  test('busybox block devices without lsblk still list the drive', () {
    final specs = parseSystemSpecs('Linux', busybox);
    expect(value(specs, SpecKind.system, 'Model'), 'Raspberry Pi 3 Model B Rev 1.2');
    expect(value(specs, SpecKind.cpu, 'Hardware'), 'BCM2835');
    expect(value(specs, SpecKind.cpu, 'model name'), 'ARMv7 Processor rev 4 (v7l)');
    expect(item(specs, SpecKind.storage, 'mmcblk0')!.summary, '29.7 GB · SD/eMMC');
  });

  test('freebsd reads sysctl, kenv, geom, pciconf and ifconfig', () {
    final specs = parseSystemSpecs('FreeBSD', bsd);
    expect(value(specs, SpecKind.system, 'Operating system'), 'FreeBSD 14.1-RELEASE-p5');
    expect(value(specs, SpecKind.system, 'Manufacturer'), 'Supermicro');
    expect(specs.uptimeSeconds, 10000);
    expect(value(specs, SpecKind.cpu, 'Model ID'), '0x9e');
    expect(item(specs, SpecKind.cpu, 'Flags')!.summary, '5 flags');
    expect(specs.section(SpecKind.memory)!.notices, [SpecNotice.modulesToolMissing]);
    final drive = item(specs, SpecKind.storage, 'ada0')!;
    expect(drive.summary, '465.8 GB · SSD · PASSED');
    expect(fieldOf(drive, 'Power On Hours'), '21234');
    expect(
      item(specs, SpecKind.storage, 'Filesystems')!.fields.single.value,
      'zroot/ROOT/default · zfs · 95.4 GB used of 381.5 GB (25%)',
    );
    expect(specs.section(SpecKind.gpu)!.items.single.title, 'CoffeeLake-S GT2 [UHD Graphics P630]');
    final nic = specs.section(SpecKind.network)!.items.single;
    expect(nic.title, 'em0');
    expect(fieldOf(nic, 'Adapter'), 'Ethernet Connection (7) I219-LM');
    expect(nic.summary, '1000baseT · active · 192.168.1.20');
  });

  test("macos reads system_profiler's nested groups", () {
    final specs = parseSystemSpecs('Darwin', mac);
    expect(value(specs, SpecKind.system, 'Operating system'), 'macOS 14.5 (23F79)');
    expect(value(specs, SpecKind.system, 'Model Identifier'), 'MacBookPro18,3');
    expect(
      value(specs, SpecKind.system, 'Chip'),
      isNull,
      reason: 'The chip belongs to the processor section',
    );
    expect(specs.uptimeSeconds, 50000);
    expect(value(specs, SpecKind.cpu, 'Performance cores'), '8');
    expect(value(specs, SpecKind.cpu, 'L2 cache'), '4.0 MB');
    expect(value(specs, SpecKind.memory, 'Type'), 'LPDDR5');
    final volume = item(specs, SpecKind.storage, 'Macintosh HD - Data')!;
    expect(volume.summary, '494.38 GB · APFS · 300.12 GB free');
    expect(fieldOf(volume, 'Physical Drive · S.M.A.R.T. Status'), 'Verified');
    final gpu = specs.section(SpecKind.gpu)!.items.single;
    expect(fieldOf(gpu, 'Displays · Color LCD · Resolution'), '3024 x 1964 Retina');
    expect(specs.section(SpecKind.network)!.items.map((i) => i.title), ['Wi-Fi (en0)']);
  });

  test('windows reads cim records into the same sections', () {
    final specs = parseSystemSpecs('Windows', win);
    expect(value(specs, SpecKind.system, 'Operating system'), 'Microsoft Windows 11 Pro');
    expect(
      value(specs, SpecKind.system, 'Model'),
      isNull,
      reason: 'Firmware placeholders are dropped',
    );
    expect(
      specs.section(SpecKind.cpu)!.summary,
      'AMD Ryzen 7 5800X 8-Core Processor · 8 cores · 16 threads',
    );
    expect(value(specs, SpecKind.cpu, 'L3 cache'), '32.0 MB');
    expect(value(specs, SpecKind.cpu, 'Virtualization in firmware'), 'Enabled');
    expect(specs.section(SpecKind.memory)!.summary, '32.0 GB · 2 of 4 slots used · DDR4 3600 MT/s');
    final dimm = item(specs, SpecKind.memory, 'DIMM_A2');
    expect(fieldOf(dimm, 'Form factor'), 'DIMM');
    expect(fieldOf(dimm, 'Voltage'), '1.35 V');
    expect(fieldOf(item(specs, SpecKind.storage, 'Samsung'), 'Wear'), '2%');
    expect(
      item(specs, SpecKind.storage, 'Volumes')!.fields.single.value,
      'NTFS · 465.2 GB used of 930.4 GB (50%)',
    );
    expect(fieldOf(specs.section(SpecKind.gpu)!.items.single, 'Video memory'), '4 GB or more');
    expect(
      item(specs, SpecKind.network, 'Ethernet')!.summary,
      '2.5 Gb/s · Connected · 192.168.1.40',
    );
  });

  test('each os family gets its own command', () {
    expect(systemSpecsCommand('Linux'), contains('lscpu'));
    expect(
      systemSpecsCommand('Linux'),
      contains('[ -r /proc/device-tree/model ] &&'),
      reason: "A board without a device tree must not print sh's error",
    );
    expect(systemSpecsCommand('FreeBSD 14.1'), contains('geom disk list'));
    expect(systemSpecsCommand('Darwin'), contains('system_profiler'));
    expect(systemSpecsCommand('Windows'), startsWith('powershell'));
    expect(
      systemSpecsCommand('Linux'),
      isNot(contains('sudo')),
      reason: 'Opening the screen never tries sudo',
    );
    final withSudo = systemSpecsCommand('Linux', sudoPassword: 's3cr3t-Pass');
    expect(withSudo, contains("sudo -S -p ''"));
    expect(
      withSudo,
      isNot(contains('s3cr3t-Pass')),
      reason: 'The password goes on stdin, never in the command',
    );
  });

  test('copied text lists every section, device and field', () {
    final text = parseSystemSpecs(
      'Linux',
      linuxCommon,
    ).asText((kind) => kind.name[0].toUpperCase() + kind.name.substring(1));
    expect(text, contains('Cpu — Intel(R) Core(TM) i5-10400'));
    expect(text, contains('    Driver: i915'));
  });
}
