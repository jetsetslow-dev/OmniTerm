import 'package:uuid/uuid.dart';

/// Whether the draft still says what it said when it was opened.
///
/// [rendered] is the YAML the builder would deploy right now. The comparison is against the
/// imported stack's *original text* when there is one, and against an empty draft's rendering
/// otherwise — so opening an existing stack and changing nothing is not "dirty", and neither is an
/// untouched new draft.
///
/// Ported from `isDirty` (`ui/ComposeBuilder.kt:1222`), including its exact-string comparison. A
/// difference in trailing whitespace therefore counts as dirty, which errs towards asking before
/// discarding — the safe direction for a prompt whose other branch destroys work.
bool composeDraftIsDirty({required String rendered, required ComposeStackDraft? baseline}) {
  final initial = baseline?.originalText ?? renderComposeYaml(ComposeStackDraft(), null);
  return rendered != initial;
}

/// Everything the Builder tab needs to come back looking untouched.
///
/// The tab's editing state used to live entirely in its `State`, which Flutter discards the moment
/// the tab stops being built — so switching to Stacks and back, or leaving the screen, silently
/// destroyed an unsaved stack. Kotlin keeps the equivalent on the view model
/// (`AppViewModel.activeComposeDraft`) precisely so edits survive a tab switch.
///
/// Only what the user actually typed is captured. Derived state (validation issues, the editor
/// rebuild counter) is recomputed on restore, so there is one place for it to be wrong rather than
/// two.
class ComposeDraftMemento {
  const ComposeDraftMemento({
    required this.draft,
    required this.baseline,
    required this.rawMode,
    required this.rawText,
    required this.pathText,
  });

  final ComposeStackDraft draft;

  /// The parsed original when a stack was imported, used to render only what changed.
  final ComposeStackDraft? baseline;

  final bool rawMode;
  final String rawText;
  final String pathText;
}

class ComposeServiceDraft {
  String id;
  String serviceName;
  String image;
  String containerName;
  String restart;
  String command;
  String usernsMode;
  bool isCommentedOut;
  bool isExpanded;
  List<String> ports;
  List<String> environment;
  List<String> volumes;
  List<String> networks;
  List<String> dependsOn;

  int srcStart;
  int srcEnd;
  int bodyIndent;
  Map<String, int> scalarLine;
  Map<String, List<int>> arraySpan;

  String anchorName;
  bool inheritsImage;
  List<String> aliasRefs;
  List<String> dependsOnRefs;
  Set<String> unmodeledArrayKeys;

  ComposeServiceDraft({
    String? id,
    this.serviceName = 'app',
    this.image = '',
    this.containerName = '',
    this.restart = '',
    this.command = '',
    this.usernsMode = '',
    this.isCommentedOut = false,
    this.isExpanded = true,
    List<String>? ports,
    List<String>? environment,
    List<String>? volumes,
    List<String>? networks,
    List<String>? dependsOn,
    this.srcStart = -1,
    this.srcEnd = -1,
    this.bodyIndent = -1,
    Map<String, int>? scalarLine,
    Map<String, List<int>>? arraySpan,
    this.anchorName = '',
    this.inheritsImage = false,
    List<String>? aliasRefs,
    List<String>? dependsOnRefs,
    Set<String>? unmodeledArrayKeys,
  }) : id = id ?? const Uuid().v4(),
       ports = ports ?? [],
       environment = environment ?? [],
       volumes = volumes ?? [],
       networks = networks ?? [],
       dependsOn = dependsOn ?? [],
       scalarLine = scalarLine ?? {},
       arraySpan = arraySpan ?? {},
       aliasRefs = aliasRefs ?? [],
       dependsOnRefs = dependsOnRefs ?? [],
       unmodeledArrayKeys = unmodeledArrayKeys ?? {};
}

class TopLevelVolumeDraft {
  String id;
  String name;
  bool external;
  bool isCommentedOut;
  int srcStart;
  int srcEnd;

  TopLevelVolumeDraft({
    String? id,
    this.name = '',
    this.external = false,
    this.isCommentedOut = false,
    this.srcStart = -1,
    this.srcEnd = -1,
  }) : id = id ?? const Uuid().v4();
}

class TopLevelNetworkDraft {
  String id;
  String name;
  String driver;
  bool external;
  bool isCommentedOut;
  int srcStart;
  int srcEnd;

  TopLevelNetworkDraft({
    String? id,
    this.name = '',
    this.driver = '',
    this.external = false,
    this.isCommentedOut = false,
    this.srcStart = -1,
    this.srcEnd = -1,
  }) : id = id ?? const Uuid().v4();
}

class ComposeStackDraft {
  String projectName;
  String stackName;
  int stackNameSrcLine;
  List<ComposeServiceDraft> services;
  List<TopLevelVolumeDraft> topVolumes;
  List<TopLevelNetworkDraft> topNetworks;
  int volumesSrcHeader;
  int networksSrcHeader;
  bool hasServicesSection;
  String? originalText;
  String workingDir;
  String fileName;
  String composeFilePath;
  String composeConfigFiles;
  String runtime;
  bool podmanPodEnabled;
  String podmanPodName;
  int xPodmanSrcHeader;
  int xPodmanInPodSrcLine;

  ComposeStackDraft({
    this.projectName = 'my_stack',
    this.stackName = '',
    this.stackNameSrcLine = -1,
    List<ComposeServiceDraft>? services,
    List<TopLevelVolumeDraft>? topVolumes,
    List<TopLevelNetworkDraft>? topNetworks,
    this.volumesSrcHeader = -1,
    this.networksSrcHeader = -1,
    this.hasServicesSection = true,
    this.originalText,
    this.workingDir = '',
    this.fileName = 'docker-compose.yml',
    this.composeFilePath = '',
    this.composeConfigFiles = '',
    this.runtime = '',
    this.podmanPodEnabled = false,
    this.podmanPodName = '',
    this.xPodmanSrcHeader = -1,
    this.xPodmanInPodSrcLine = -1,
  }) : services = services ?? [ComposeServiceDraft()],
       topVolumes = topVolumes ?? [],
       topNetworks = topNetworks ?? [];
}

/// Mutable working copy with source identity preserved for surgical rendering.
ComposeStackDraft cloneComposeDraft(ComposeStackDraft source) => ComposeStackDraft(
  projectName: source.projectName,
  stackName: source.stackName,
  stackNameSrcLine: source.stackNameSrcLine,
  services: [
    for (final service in source.services)
      ComposeServiceDraft(
        id: service.id,
        serviceName: service.serviceName,
        image: service.image,
        containerName: service.containerName,
        restart: service.restart,
        command: service.command,
        usernsMode: service.usernsMode,
        isCommentedOut: service.isCommentedOut,
        isExpanded: service.isExpanded,
        ports: [...service.ports],
        environment: [...service.environment],
        volumes: [...service.volumes],
        networks: [...service.networks],
        dependsOn: [...service.dependsOn],
        srcStart: service.srcStart,
        srcEnd: service.srcEnd,
        bodyIndent: service.bodyIndent,
        scalarLine: {...service.scalarLine},
        arraySpan: {
          for (final entry in service.arraySpan.entries) entry.key: [...entry.value],
        },
        anchorName: service.anchorName,
        inheritsImage: service.inheritsImage,
        aliasRefs: [...service.aliasRefs],
        dependsOnRefs: [...service.dependsOnRefs],
        unmodeledArrayKeys: {...service.unmodeledArrayKeys},
      ),
  ],
  topVolumes: [
    for (final volume in source.topVolumes)
      TopLevelVolumeDraft(
        id: volume.id,
        name: volume.name,
        external: volume.external,
        isCommentedOut: volume.isCommentedOut,
        srcStart: volume.srcStart,
        srcEnd: volume.srcEnd,
      ),
  ],
  topNetworks: [
    for (final network in source.topNetworks)
      TopLevelNetworkDraft(
        id: network.id,
        name: network.name,
        driver: network.driver,
        external: network.external,
        isCommentedOut: network.isCommentedOut,
        srcStart: network.srcStart,
        srcEnd: network.srcEnd,
      ),
  ],
  volumesSrcHeader: source.volumesSrcHeader,
  networksSrcHeader: source.networksSrcHeader,
  hasServicesSection: source.hasServicesSection,
  originalText: source.originalText,
  workingDir: source.workingDir,
  fileName: source.fileName,
  composeFilePath: source.composeFilePath,
  composeConfigFiles: source.composeConfigFiles,
  runtime: source.runtime,
  podmanPodEnabled: source.podmanPodEnabled,
  podmanPodName: source.podmanPodName,
  xPodmanSrcHeader: source.xPodmanSrcHeader,
  xPodmanInPodSrcLine: source.xPodmanInPodSrcLine,
);

const _modeledArrays = {'ports', 'environment', 'volumes', 'networks', 'depends_on'};
const _serviceKeys = {
  'build',
  'command',
  'container_name',
  'depends_on',
  'deploy',
  'environment',
  'extends',
  'healthcheck',
  'image',
  'labels',
  'networks',
  'ports',
  'restart',
  'userns_mode',
  'volumes',
};
final _composeName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$');
final _interpolation = RegExp(r'\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*');

String _spaces(int count) => List.filled(count < 0 ? 0 : count, ' ').join();

String _withoutInlineComment(String value) {
  final index = value.indexOf(' #');
  return index > 0 ? value.substring(0, index).trimRight() : value;
}

String _unquote(String value) {
  final trimmed = _withoutInlineComment(value.trim());
  if (trimmed.length >= 2 &&
      ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
          (trimmed.startsWith("'") && trimmed.endsWith("'")))) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

String? _blockKey(String content) {
  if (content.startsWith('-') || !content.contains(':')) return null;
  final key = content.substring(0, content.indexOf(':')).trim();
  if (key.isEmpty || key.contains(' ')) return null;
  final rest = _withoutInlineComment(content.substring(content.indexOf(':') + 1).trim());
  return rest.isEmpty || RegExp(r'^&\S+$').hasMatch(rest) ? key : null;
}

String _anchor(String content) {
  final rest = _withoutInlineComment(content.substring(content.indexOf(':') + 1).trim());
  return rest.startsWith('&') ? rest.substring(1) : '';
}

String _effectiveLine(String raw) {
  final left = raw.trimLeft();
  if (!left.startsWith('#')) return raw;
  final leading = raw.length - left.length;
  var consumed = 0;
  while (consumed < left.length && left[consumed] == '#') {
    consumed++;
  }
  if (consumed < left.length && left[consumed] == ' ') consumed++;
  return '${_spaces(leading + consumed)}${left.substring(consumed)}';
}

/// Parses the visual editor's supported Compose subset while retaining source locations.
///
/// Unsupported keys are deliberately ignored here and retained in [ComposeStackDraft.originalText]
/// so [renderComposeYaml] can splice only fields the visual editor owns.
ComposeStackDraft parseDockerComposeYaml(
  String yaml, {
  required String projectName,
  String workingDir = '',
  String fileName = 'docker-compose.yml',
  String composeFilePath = '',
  String composeConfigFiles = '',
  String runtime = '',
}) {
  final lines = yaml.split('\n');
  final draft = ComposeStackDraft(
    projectName: projectName,
    services: [],
    originalText: yaml.isEmpty ? null : yaml,
    workingDir: workingDir,
    fileName: fileName,
    composeFilePath: composeFilePath,
    composeConfigFiles: composeConfigFiles,
    runtime: runtime,
  );
  var section = '';
  var serviceIndent = -1;
  var itemIndent = -1;
  ComposeServiceDraft? service;
  TopLevelVolumeDraft? volume;
  TopLevelNetworkDraft? network;
  String arrayKey = '';
  var arrayStart = -1;
  var arrayIndent = -1;

  void finishService() {
    if (service != null) draft.services.add(service!);
    service = null;
  }

  void finishVolume() {
    if (volume != null) draft.topVolumes.add(volume!);
    volume = null;
  }

  void finishNetwork() {
    if (network != null) draft.topNetworks.add(network!);
    network = null;
  }

  for (var index = 0; index < lines.length; index++) {
    final raw = lines[index];
    if (raw.trim().isEmpty) continue;
    final commented = raw.trimLeft().startsWith('#');
    final effective = _effectiveLine(raw);
    final content = effective.trim();
    final indent = effective.length - effective.trimLeft().length;

    if (indent == 0 && !content.startsWith('-') && content.contains(':')) {
      finishService();
      finishVolume();
      finishNetwork();
      final key = content.substring(0, content.indexOf(':')).trim();
      section = _blockKey(content) ?? '';
      serviceIndent = -1;
      itemIndent = -1;
      if (section == 'services') draft.hasServicesSection = true;
      if (section == 'volumes') draft.volumesSrcHeader = index;
      if (section == 'networks') draft.networksSrcHeader = index;
      if (section == 'x-podman') draft.xPodmanSrcHeader = index;
      if (key == 'name' && section.isEmpty) {
        draft.stackName = _unquote(content.substring(content.indexOf(':') + 1));
        draft.stackNameSrcLine = index;
      }
      continue;
    }

    if (section == 'x-podman' && content.startsWith('in_pod:')) {
      final value = _unquote(content.substring(content.indexOf(':') + 1));
      draft.xPodmanInPodSrcLine = index;
      draft.podmanPodEnabled = value.toLowerCase() != 'false';
      draft.podmanPodName = value == 'true' || value.isEmpty ? '' : value;
      continue;
    }

    if (section == 'volumes') {
      final key = _blockKey(content);
      if (key != null && (itemIndent < 0 || indent == itemIndent || commented)) {
        if (!commented && itemIndent < 0) itemIndent = indent;
        finishVolume();
        volume = TopLevelVolumeDraft(
          name: _unquote(key),
          external: content.contains(RegExp(r'external\s*:\s*true')),
          isCommentedOut: commented,
          srcStart: index,
          srcEnd: index,
        );
      } else if (volume != null) {
        volume!.srcEnd = index;
        if (content.startsWith('external:') &&
            _unquote(content.split(':').skip(1).join(':')) == 'true') {
          volume!.external = true;
        }
      }
      continue;
    }

    if (section == 'networks') {
      final key = _blockKey(content);
      if (key != null && (itemIndent < 0 || indent == itemIndent || commented)) {
        if (!commented && itemIndent < 0) itemIndent = indent;
        finishNetwork();
        network = TopLevelNetworkDraft(
          name: _unquote(key),
          external: content.contains(RegExp(r'external\s*:\s*true')),
          isCommentedOut: commented,
          srcStart: index,
          srcEnd: index,
        );
      } else if (network != null) {
        network!.srcEnd = index;
        final key = content.substringBefore(':');
        final value = _unquote(content.substring(content.indexOf(':') + 1));
        if (key == 'driver') network!.driver = value;
        if (key == 'external' && value == 'true') network!.external = true;
      }
      continue;
    }

    if (section != 'services') continue;
    final blockKey = _blockKey(content);
    final canBeHeader = blockKey != null && !_serviceKeys.contains(blockKey);
    if (canBeHeader && (serviceIndent < 0 || indent == serviceIndent || commented)) {
      if (!commented && serviceIndent < 0) serviceIndent = indent;
      finishService();
      service = ComposeServiceDraft(
        serviceName: _unquote(blockKey),
        isCommentedOut: commented,
        isExpanded: false,
        srcStart: index,
        srcEnd: index,
        anchorName: _anchor(content),
      );
      arrayKey = '';
      continue;
    }

    final current = service;
    if (current == null || (commented && !current.isCommentedOut)) continue;
    current.srcEnd = index;
    if (current.bodyIndent < 0 && indent > serviceIndent && !content.startsWith('-')) {
      current.bodyIndent = indent;
    }
    if (content.startsWith('-')) {
      if (arrayKey.isEmpty) continue;
      final item = _unquote(content.substring(1));
      if (RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]*:\s+\S').hasMatch(item)) {
        current.unmodeledArrayKeys.add(arrayKey);
        current.arraySpan.remove(arrayKey);
        arrayKey = '';
        continue;
      }
      final target = _arrayFor(current, arrayKey);
      target.add(item);
      current.arraySpan[arrayKey] = [arrayStart, index];
      if (arrayKey == 'depends_on') current.dependsOnRefs.add(item);
      continue;
    }
    if (!content.contains(':')) continue;
    final key = content.substring(0, content.indexOf(':')).trim();
    final value = _unquote(content.substring(content.indexOf(':') + 1));
    if (arrayKey.isNotEmpty && indent > arrayIndent) {
      current.unmodeledArrayKeys.add(arrayKey);
      current.arraySpan.remove(arrayKey);
      _arrayFor(current, arrayKey).clear();
    }
    arrayKey = '';
    if (value.isEmpty && _modeledArrays.contains(key)) {
      arrayKey = key;
      arrayStart = index;
      arrayIndent = indent;
      current.arraySpan[key] = [index, index];
      continue;
    }
    switch (key) {
      case 'image':
        current.image = value;
      case 'container_name':
        current.containerName = value;
      case 'restart':
        current.restart = value;
      case 'command':
        current.command = value;
      case 'userns_mode':
        current.usernsMode = value;
      case 'build' || 'extends':
        current.inheritsImage = true;
      case '<<':
        current.inheritsImage = true;
        if (value.startsWith('*')) current.aliasRefs.add(value.substring(1));
    }
    if (const {'image', 'container_name', 'restart', 'command', 'userns_mode'}.contains(key)) {
      current.scalarLine[key] = index;
    }
  }
  finishService();
  finishVolume();
  finishNetwork();
  if (runtime == 'podman' && draft.xPodmanSrcHeader < 0) {
    draft.podmanPodEnabled = true;
  }
  draft.hasServicesSection =
      draft.originalText == null || lines.any((line) => line.trim() == 'services:');
  if (draft.services.isEmpty && draft.originalText == null) {
    draft.services.add(ComposeServiceDraft());
  }
  return draft;
}

List<String> _arrayFor(ComposeServiceDraft service, String key) => switch (key) {
  'ports' => service.ports,
  'environment' => service.environment,
  'volumes' => service.volumes,
  'networks' => service.networks,
  _ => service.dependsOn,
};

extension on String {
  String substringBefore(String pattern) {
    final index = indexOf(pattern);
    return index < 0 ? this : substring(0, index);
  }
}

bool _validPort(String value) {
  final raw = _unquote(value).replaceAll(_interpolation, '1');
  final parts = raw.split(':');
  final ports = switch (parts.length) {
    1 || 2 => parts,
    3 => parts.sublist(1),
    _ => const <String>[],
  };
  if (ports.isEmpty) return false;
  for (final part in ports) {
    final numeric = part.split('/').first.split('-');
    if (numeric.any((p) => int.tryParse(p) == null || int.parse(p) < 1 || int.parse(p) > 65535)) {
      return false;
    }
  }
  return true;
}

List<String> validateComposeDraft(ComposeStackDraft draft) {
  final issues = <String>[];
  if (!draft.hasServicesSection) {
    issues.add('No services: section. Convert this legacy Compose v1 file in Raw YAML.');
  }
  final active = draft.services.where((service) => !service.isCommentedOut).toList();
  final names = <String, int>{};
  for (var index = 0; index < draft.services.length; index++) {
    final service = draft.services[index];
    if (service.isCommentedOut) continue;
    final label = service.serviceName.trim().isEmpty ? 'Service ${index + 1}' : service.serviceName;
    if (!_composeName.hasMatch(service.serviceName.trim())) {
      issues.add('$label has an invalid service name.');
    }
    if (service.image.trim().isEmpty && !service.inheritsImage) {
      issues.add(
        '$label needs an image in the visual editor. Use Raw YAML for build-only services.',
      );
    }
    for (final port in service.ports.where((value) => value.trim().isNotEmpty)) {
      if (!_validPort(port)) {
        issues.add('$label has an invalid port mapping: $port');
      }
    }
    names.update(service.serviceName.trim(), (count) => count + 1, ifAbsent: () => 1);
  }
  for (final entry in names.entries.where((entry) => entry.key.isNotEmpty && entry.value > 1)) {
    issues.add('Duplicate active service name: ${entry.key}');
  }
  final commented = draft.services
      .where((service) => service.isCommentedOut)
      .map((service) => service.serviceName)
      .toSet();
  for (final service in active) {
    for (final dependency in {...service.dependsOn, ...service.dependsOnRefs}) {
      if (commented.contains(dependency)) {
        issues.add('${service.serviceName} depends on $dependency, which is commented out.');
      }
    }
  }
  final volumeNames = <String>{};
  for (final entry in draft.topVolumes.where((entry) => !entry.isCommentedOut)) {
    final name = entry.name.trim();
    if (!_composeName.hasMatch(name)) {
      issues.add('Top-level volume has an invalid name: $name');
    }
    if (!volumeNames.add(name)) {
      issues.add('Duplicate top-level volume name: $name');
    }
  }
  final networkNames = <String>{};
  for (final entry in draft.topNetworks.where((entry) => !entry.isCommentedOut)) {
    final name = entry.name.trim();
    if (!_composeName.hasMatch(name)) {
      issues.add('Top-level network has an invalid name: $name');
    }
    if (!networkNames.add(name)) {
      issues.add('Duplicate top-level network name: $name');
    }
  }
  for (final network in draft.topNetworks) {
    if (!network.isCommentedOut && network.external && network.driver.isNotEmpty) {
      issues.add('${network.name} cannot set both external: true and driver.');
    }
  }
  if (draft.runtime == 'podman' &&
      draft.podmanPodEnabled &&
      draft.podmanPodName.isNotEmpty &&
      !_composeName.hasMatch(draft.podmanPodName)) {
    issues.add('Pod name has invalid characters.');
  }
  return issues.toSet().toList();
}

String _yamlScalar(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return "''";
  final risky =
      trimmed.startsWith(RegExp(r'[#\-?\:{\[&*!|>@`]')) ||
      trimmed.contains(' #') ||
      trimmed.contains(': ') ||
      const {'null', 'true', 'false'}.contains(trimmed.toLowerCase());
  return risky ? "'${trimmed.replaceAll("'", "''")}'" : trimmed;
}

String _serviceBlock(ComposeServiceDraft service, {required bool podman}) {
  final comment = service.isCommentedOut ? '# ' : '';
  final out = <String>['$comment  ${service.serviceName}:'];
  void scalar(String key, String value) {
    if (value.trim().isNotEmpty) {
      out.add('$comment    $key: ${_yamlScalar(value)}');
    }
  }

  scalar('image', service.image);
  scalar('container_name', service.containerName);
  scalar('restart', service.restart);
  scalar('command', service.command);
  if (podman || service.usernsMode != 'keep-id') {
    scalar('userns_mode', service.usernsMode);
  }
  void list(String key, List<String> values, {bool quote = false}) {
    final present = values.where((value) => value.trim().isNotEmpty).toList();
    if (present.isEmpty) return;
    out.add('$comment    $key:');
    for (final value in present) {
      final rendered = quote ? '"${value.replaceAll('"', r'\"')}"' : _yamlScalar(value);
      out.add('$comment      - $rendered');
    }
  }

  list('ports', service.ports, quote: true);
  list('environment', service.environment);
  list('volumes', service.volumes);
  list('networks', service.networks);
  list('depends_on', service.dependsOn);
  return out.join('\n');
}

String generateDockerComposeYaml(ComposeStackDraft draft) {
  final out = <String>[];
  if (draft.stackName.trim().isNotEmpty) {
    out.add('name: ${_yamlScalar(draft.stackName)}');
  }
  if (draft.runtime == 'podman') {
    final pod = !draft.podmanPodEnabled
        ? 'false'
        : draft.podmanPodName.isEmpty
        ? 'true'
        : _yamlScalar(draft.podmanPodName);
    out.add('x-podman:\n  in_pod: $pod');
  }
  out.add('services:');
  out.addAll(
    draft.services.map((service) => _serviceBlock(service, podman: draft.runtime == 'podman')),
  );
  final volumes = draft.topVolumes.where((entry) => entry.name.trim().isNotEmpty).toList();
  if (volumes.isNotEmpty) {
    out.add('');
    out.add('volumes:');
    for (final volume in volumes) {
      final comment = volume.isCommentedOut ? '# ' : '';
      out.add('$comment  ${volume.name}:');
      if (volume.external) out.add('$comment    external: true');
    }
  }
  final networks = draft.topNetworks.where((entry) => entry.name.trim().isNotEmpty).toList();
  if (networks.isNotEmpty) {
    out.add('');
    out.add('networks:');
    for (final network in networks) {
      final comment = network.isCommentedOut ? '# ' : '';
      out.add('$comment  ${network.name}:');
      if (network.driver.isNotEmpty) {
        out.add('$comment    driver: ${_yamlScalar(network.driver)}');
      }
      if (network.external) out.add('$comment    external: true');
    }
  }
  return '${out.join('\n').trimRight()}\n';
}

/// Renders an existing file surgically, leaving every unmodelled line untouched.
String renderComposeYaml(ComposeStackDraft draft, ComposeStackDraft? baseline) {
  final original = draft.originalText;
  if (original == null || baseline == null) {
    return generateDockerComposeYaml(draft);
  }
  final lines = original.split('\n');
  final slots = <String?>[...lines];
  final after = <int, List<String>>{};
  final before = <String>[];
  void insertAfter(int index, String value) => after.putIfAbsent(index, () => []).add(value);
  final oldServices = {for (final service in baseline.services) service.id: service};
  final kept = draft.services.map((service) => service.id).toSet();
  for (final old in baseline.services.where((service) => !kept.contains(service.id))) {
    for (var line = old.srcStart; line <= old.srcEnd; line++) {
      if (line >= 0 && line < slots.length) slots[line] = null;
    }
  }
  for (final service in draft.services) {
    final old = oldServices[service.id];
    if (old == null) continue;
    if (old.srcStart >= 0 && service.serviceName != old.serviceName) {
      final source = slots[old.srcStart] ?? '';
      slots[old.srcStart] = source.replaceFirst(old.serviceName, service.serviceName);
    }
    if (old.srcStart >= 0 && service.isCommentedOut != old.isCommentedOut) {
      for (var line = old.srcStart; line <= old.srcEnd; line++) {
        final source = line >= 0 && line < slots.length ? slots[line] : null;
        if (source == null) continue;
        slots[line] = service.isCommentedOut
            ? '# ${source.substring((source.length - source.trimLeft().length).clamp(0, 2))}'
            : source.replaceFirst(RegExp(r'^\s*#+ ?'), '');
      }
    }
    final bodyIndent = service.bodyIndent > 0 ? service.bodyIndent : 4;
    void scalar(String key, String value, String oldValue) {
      if (value == oldValue) return;
      final line = old.scalarLine[key];
      if (line != null && line < slots.length) {
        slots[line] = value.trim().isEmpty
            ? null
            : '${_spaces(bodyIndent)}$key: ${_yamlScalar(value)}';
      } else if (value.trim().isNotEmpty) {
        insertAfter(old.srcStart, '${_spaces(bodyIndent)}$key: ${_yamlScalar(value)}');
      }
    }

    scalar('image', service.image, old.image);
    scalar('container_name', service.containerName, old.containerName);
    scalar('restart', service.restart, old.restart);
    scalar('command', service.command, old.command);
    scalar(
      'userns_mode',
      draft.runtime == 'docker' && service.usernsMode == 'keep-id' ? '' : service.usernsMode,
      old.usernsMode,
    );
    void array(String key, List<String> values, List<String> oldValues, {bool quote = false}) {
      if (old.unmodeledArrayKeys.contains(key) || _sameStrings(values, oldValues)) {
        return;
      }
      final cleaned = values.where((value) => value.trim().isNotEmpty).toList();
      final block = <String>[];
      if (cleaned.isNotEmpty) {
        block.add('${_spaces(bodyIndent)}$key:');
        for (final value in cleaned) {
          block.add('${_spaces(bodyIndent + 2)}- ${quote ? '"$value"' : _yamlScalar(value)}');
        }
      }
      final span = old.arraySpan[key];
      if (span != null) {
        for (var line = span.first; line <= span.last; line++) {
          if (line < slots.length) slots[line] = null;
        }
        if (block.isNotEmpty) slots[span.first] = block.join('\n');
      } else if (block.isNotEmpty) {
        insertAfter(old.srcEnd, block.join('\n'));
      }
    }

    array('ports', service.ports, old.ports, quote: true);
    array('environment', service.environment, old.environment);
    array('volumes', service.volumes, old.volumes);
    array('networks', service.networks, old.networks);
    array('depends_on', service.dependsOn, old.dependsOn);
  }
  if (draft.stackName != baseline.stackName) {
    if (baseline.stackNameSrcLine >= 0) {
      slots[baseline.stackNameSrcLine] = draft.stackName.isEmpty
          ? null
          : 'name: ${_yamlScalar(draft.stackName)}';
    } else if (draft.stackName.isNotEmpty) {
      before.add('name: ${_yamlScalar(draft.stackName)}');
    }
  }
  final servicesEnd = baseline.services
      .where((service) => service.srcEnd >= 0)
      .fold<int>(
        lines.indexWhere((line) => line.trim() == 'services:'),
        (end, service) => service.srcEnd > end ? service.srcEnd : end,
      );
  for (final service in draft.services.where((service) => !oldServices.containsKey(service.id))) {
    insertAfter(
      servicesEnd < 0 ? 0 : servicesEnd,
      _serviceBlock(service, podman: draft.runtime == 'podman'),
    );
  }
  final rendered = <String>[...before];
  for (var index = 0; index < slots.length; index++) {
    final line = slots[index];
    if (line != null) rendered.add(line);
    rendered.addAll(after[index] ?? const []);
  }
  var result = rendered.join('\n');
  // Top-level entry edits are less common and may carry arbitrary driver options. Preserve them
  // unless the set actually changed; when it did, regenerate just those sections by reparsing the
  // newly rendered text on the next edit rather than touching unrelated YAML here.
  if (!_sameTopVolumes(draft.topVolumes, baseline.topVolumes) ||
      !_sameTopNetworks(draft.topNetworks, baseline.topNetworks)) {
    result = _replaceTopSections(result, draft);
  }
  return result.endsWith('\n') ? result : '$result\n';
}

bool _sameStrings(List<String> first, List<String> second) =>
    first.length == second.length &&
    List.generate(first.length, (i) => first[i] == second[i]).every((value) => value);

bool _sameTopVolumes(List<TopLevelVolumeDraft> first, List<TopLevelVolumeDraft> second) =>
    first.length == second.length &&
    List.generate(
      first.length,
      (i) =>
          first[i].name == second[i].name &&
          first[i].external == second[i].external &&
          first[i].isCommentedOut == second[i].isCommentedOut,
    ).every((value) => value);

bool _sameTopNetworks(List<TopLevelNetworkDraft> first, List<TopLevelNetworkDraft> second) =>
    first.length == second.length &&
    List.generate(
      first.length,
      (i) =>
          first[i].name == second[i].name &&
          first[i].driver == second[i].driver &&
          first[i].external == second[i].external &&
          first[i].isCommentedOut == second[i].isCommentedOut,
    ).every((value) => value);

String _replaceTopSections(String yaml, ComposeStackDraft draft) {
  final lines = yaml.split('\n');
  final kept = <String>[];
  var skipping = false;
  for (final line in lines) {
    final top = line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#');
    if (top && (line.trim() == 'volumes:' || line.trim() == 'networks:')) {
      skipping = true;
      continue;
    }
    if (skipping && top) skipping = false;
    if (!skipping) kept.add(line);
  }
  final seed = ComposeStackDraft(
    projectName: draft.projectName,
    services: [],
    topVolumes: draft.topVolumes,
    topNetworks: draft.topNetworks,
  );
  final generated = generateDockerComposeYaml(seed);
  final topAt = generated.indexOf('\nvolumes:');
  final networkAt = generated.indexOf('\nnetworks:');
  final start = [
    topAt,
    networkAt,
  ].where((index) => index >= 0).fold<int>(generated.length, (a, b) => a < b ? a : b);
  final suffix = start < generated.length ? generated.substring(start).trim() : '';
  return '${kept.join('\n').trimRight()}${suffix.isEmpty ? '' : '\n\n$suffix'}';
}

bool composeRawEditsDiffer(String rawText, ComposeStackDraft draft, ComposeStackDraft? baseline) =>
    rawText != renderComposeYaml(draft, baseline);

/// Whether the stack is fully rootless-mapped, i.e. every rendered service carries
/// `userns_mode: keep-id`.
///
/// Commented-out services are excluded: they contribute nothing to the rendered file, so letting one
/// hold the reading false would misreport a stack that is in fact fully mapped. An empty stack is
/// not "mapped" — there is nothing to map.
bool podmanKeepIdEnabled(ComposeStackDraft draft) {
  final active = draft.services.where((s) => !s.isCommentedOut);
  return active.isNotEmpty && active.every((s) => s.usernsMode == 'keep-id');
}

/// Sets or clears `userns_mode: keep-id` across every service in [draft].
///
/// A bulk edit on purpose: rootless Podman needs the mapping on *every* service, and applying it one
/// service at a time is how a stack ends up half-mapped and fails at run time for one container only.
///
/// Clearing only removes the value this control sets. A `userns_mode` the user typed themselves is
/// theirs and must survive the switch being turned off.
void setPodmanKeepId(ComposeStackDraft draft, bool enabled) {
  for (final service in draft.services) {
    if (enabled) {
      service.usernsMode = 'keep-id';
    } else if (service.usernsMode == 'keep-id') {
      service.usernsMode = '';
    }
  }
}
