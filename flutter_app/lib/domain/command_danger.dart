/// Recognises commands that would be destructive if broadcast across a fleet, ported from
/// `commandDangerHits` in `ui/FleetScreen.kt`.
///
/// **This is a warning, not a block.** The user chose these hosts and is entitled to run whatever
/// they like on them (MIGRATION.md §17) — a broadcast `reboot` across a lab is a legitimate thing to
/// want. What makes it worth flagging is the multiplier: the same typo that costs one host costs
/// forty, and the confirmation dialog is the last point at which that is cheap to notice.
///
/// So this deliberately errs toward matching. A false positive costs one extra glance at a dialog
/// the user was already reading; a false negative costs a fleet.
library;

/// One recognised danger: the pattern that matched and the phrase shown to the user.
typedef _DangerRule = (RegExp pattern, String label);

/// Ordered so the most severe reads first when several match.
final List<_DangerRule> _rules = [
  // `rm -rf`, `rm -fR`, `rm -r -f` — any combination of flags containing r or f.
  (RegExp(r'\brm\s+(-+\w*[rfRF]\w*\s+)+'), 'recursive/forced delete'),
  (RegExp(r'\b(mkfs|wipefs|blkdiscard|mkswap)\b'), 'filesystem format/wipe'),
  (RegExp(r'\b(fdisk|parted|sgdisk|sfdisk)\b'), 'partition table changes'),
  // `of=` is matched anywhere in the same command segment, not only as dd's first operand. The
  // Kotlin used `\bdd\s+\S*of=`, whose `\S*` cannot cross a space — so it matched the unusual
  // `dd of=… if=…` while missing the textbook `dd if=/dev/zero of=/dev/sda`. See §15.5.
  (RegExp(r'\bdd\b[^;&|\n]*\bof='), 'raw write with dd'),
  (RegExp(r'>+\s*/dev/(sd|nvme|mmcblk|vd|hd)'), 'writing directly to a block device'),
  (RegExp(r'\b(shutdown|poweroff|halt)\b'), 'host shutdown'),
  (
    RegExp(
      r'\breboot\b|\binit\s+[06]\b|\bsystemctl\s+(reboot|poweroff|halt|kexec|emergency|rescue)\b',
    ),
    'host reboot/shutdown',
  ),
  (RegExp(r'\b(userdel|groupdel)\b'), 'account deletion'),
  // Same fix as `dd`: the flag may appear after other arguments, so `iptables -t nat -F` — a flush
  // of the NAT table — counts. `(-\w+\s+)*` could not express that.
  (RegExp(r'\biptables\b[^;&|\n]*\s-F\b|\bnft\s+flush\b|\bufw\s+disable\b'), 'firewall teardown'),
  // Only when applied to an absolute path — `chmod 777 ./build` is careless, not catastrophic.
  (RegExp(r'\bchmod\s+(-\w+\s+)*[0-7]*777\s+/\S*'), 'world-writable permission change'),
  (RegExp(r':\s*\(\s*\)\s*\{'), 'fork bomb'),
  (RegExp(r'\btruncate\s+(-\w+\s+)*-s\s*0\b'), 'file truncation'),
];

/// The danger labels matching [command], in severity order. Empty when nothing matched.
List<String> commandDangerHits(String command) => [
  for (final (pattern, label) in _rules)
    if (pattern.hasMatch(command)) label,
];

/// A sentence for the confirmation dialog, or null when [command] looks ordinary.
///
/// Names what was recognised rather than just saying "this looks dangerous": a user who sees
/// "recursive/forced delete" can tell instantly whether that is what they meant.
String? fleetCommandDangerWarning(String command) {
  final hits = commandDangerHits(command);
  if (hits.isEmpty) return null;
  return 'This command looks destructive (${hits.join(', ')}) '
      'and will run on every host listed above.';
}
