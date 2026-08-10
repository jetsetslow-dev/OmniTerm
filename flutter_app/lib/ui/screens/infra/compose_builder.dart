import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/code_highlighter.dart';
import '../../../domain/stack_summary.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/app_state.dart';
import '../../view_model/infra_view_model.dart';
import '../../widgets/back_interceptor.dart';
import '../../widgets/code_editor.dart';
import '../../widgets/omni_components.dart';
import 'compose_builder_logic.dart';

/// Visual + raw Compose editor, including existing-stack import and fail-safe remote deployment.
class BuilderTab extends StatefulWidget {
  const BuilderTab({super.key});

  @override
  State<BuilderTab> createState() => _BuilderTabState();
}

class _BuilderTabState extends State<BuilderTab> {
  ComposeStackDraft _draft = ComposeStackDraft();
  ComposeStackDraft? _baseline;
  final _path = TextEditingController();
  final _raw = HighlightEditingController(
    language: CodeLanguage.yaml,
    maxChars: 100000,
  );
  bool _rawMode = false;
  int? _serverId;
  int _generation = 0;
  List<String> _issues = const [];
  int _handledEditRequest = 0;

  /// Captured on first attach so [dispose] can park the draft without touching `context`, which is
  /// no longer safe to read by then.
  InfraViewModel? _vm;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final vm = context.read<InfraViewModel>();
    if (!identical(vm, _vm)) {
      _vm = vm;
      // Assigned rather than setState-ed: this runs before the first build, so there is nothing on
      // screen yet to update.
      _restore(vm.composeDraft);
    }
    final serverId = vm.inspectedServer?.id;
    if (_serverId != null && serverId != _serverId) _newDraft();
    _serverId = serverId;
  }

  @override
  void dispose() {
    // Parked before the controllers are torn down — their text is part of what has to survive.
    _vm?.composeDraft = ComposeDraftMemento(
      draft: _draft,
      baseline: _baseline,
      rawMode: _rawMode,
      rawText: _raw.text,
      pathText: _path.text,
    );
    _path.dispose();
    _raw.dispose();
    super.dispose();
  }

  void _restore(ComposeDraftMemento? memento) {
    if (memento == null) return;
    _draft = memento.draft;
    _baseline = memento.baseline;
    _rawMode = memento.rawMode;
    _raw.text = memento.rawText;
    _path.text = memento.pathText;
    // Recomputed rather than stored, so a restored draft cannot disagree with a fresh one about
    // whether it is valid.
    _issues = _rawMode ? const [] : validateComposeDraft(_draft);
    _generation++;
  }

  /// True when the draft differs from what it started as.
  bool get _isDirty =>
      composeDraftIsDirty(rendered: _rendered, baseline: _baseline);

  /// Back on the Builder tab, ported from `ui/ComposeBuilder.kt:1260`.
  ///
  /// Kotlin's comment there records a bug worth not repeating: **Back must end in a visible
  /// navigation, never in state mutation alone.** Clearing the draft leaves the user on the Builder
  /// tab, which immediately rebuilds an empty one — so every press appeared to do nothing and the
  /// tab could not be left. Returning to Stacks breaks that, and also unmounts this handler, so a
  /// second Back reaches app navigation and leaves the screen as expected.
  ///
  /// Kotlin additionally disables its handler while a full-screen code editor is open. Flutter's
  /// raw editor is inline on this tab rather than an overlay, so there is no second handler to race
  /// and no equivalent condition to port.
  bool _handleBack() {
    if (!_isDirty) {
      _exitToStacks();
      return true;
    }
    unawaited(_confirmDiscard());
    return true;
  }

  void _exitToStacks() {
    setState(_newDraft);
    _vm?.activeTab = InfraTab.stacks;
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('infra.builder.discardConfirm'),
        title: const Text('Discard changes?'),
        content: const Text(
          'You have unsaved changes to this stack. Discard them?',
        ),
        actions: [
          TextButton(
            key: const ValueKey('infra.builder.discardConfirm.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('infra.builder.discardConfirm.discard'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              'Discard',
              style: TextStyle(color: OmniColors.red),
            ),
          ),
        ],
      ),
    );
    if (discard == true && mounted) _exitToStacks();
  }

  void _newDraft() {
    _draft = ComposeStackDraft();
    _baseline = null;
    _path.clear();
    _raw.clear();
    _rawMode = false;
    _issues = const [];
    _generation++;
    // "New" has to mean new on the next mount too, or the discarded draft comes straight back.
    _vm?.composeDraft = null;
  }

  String get _rendered =>
      _rawMode ? _raw.text : renderComposeYaml(_draft, _baseline);

  void _changed() {
    setState(() => _issues = validateComposeDraft(_draft));
  }

  String _pathForStack(StackSummary stack) {
    final first = stack.configFiles
        .split(',')
        .map((file) => file.trim())
        .firstWhere(
          (file) => file.isNotEmpty,
          orElse: () => 'docker-compose.yml',
        );
    if (first.startsWith('/') || first.startsWith('~/')) return first;
    return '${stack.workingDir.replaceFirst(RegExp(r'/+$'), '')}/$first';
  }

  Future<void> _load({StackSummary? stack}) async {
    final vm = context.read<InfraViewModel>();
    if (stack != null) _path.text = _pathForStack(stack);
    final text = await vm.readComposeFile(_path.text);
    if (!mounted || text == null) return;
    final path = _path.text.trim();
    final slash = path.lastIndexOf('/');
    final workingDir =
        stack?.workingDir ?? (slash > 0 ? path.substring(0, slash) : '');
    final fileName = slash >= 0 ? path.substring(slash + 1) : path;
    final parsed = parseDockerComposeYaml(
      text,
      projectName: stack?.name ?? _draft.projectName,
      workingDir: workingDir,
      fileName: fileName.isEmpty ? 'docker-compose.yml' : fileName,
      composeFilePath: path,
      composeConfigFiles: stack?.configFiles ?? path,
      runtime: stack?.runtime ?? _draft.runtime,
    );
    setState(() {
      _baseline = parsed;
      _draft = cloneComposeDraft(parsed);
      _raw.text = text;
      _rawMode = false;
      _generation++;
      _issues = validateComposeDraft(_draft);
    });
  }

  void _toggleRaw(bool raw) {
    if (raw == _rawMode) return;
    if (raw) {
      _raw.text = renderComposeYaml(_draft, _baseline);
      setState(() => _rawMode = true);
      return;
    }
    final parsed = parseDockerComposeYaml(
      _raw.text,
      projectName: _draft.projectName,
      workingDir: _draft.workingDir,
      fileName: _draft.fileName,
      composeFilePath: _draft.composeFilePath,
      composeConfigFiles: _draft.composeConfigFiles,
      runtime: _draft.runtime,
    );
    setState(() {
      _baseline = parsed;
      _draft = cloneComposeDraft(parsed);
      _rawMode = false;
      _generation++;
      _issues = validateComposeDraft(_draft);
    });
  }

  Future<void> _preview() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('infra.builder.previewDialog'),
      title: const Text('Compose YAML preview'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: SelectableText(
            _rendered,
            style: const TextStyle(fontFamily: OmniFonts.mono),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('Close'),
        ),
      ],
    ),
  );

  Future<void> _deploy() async {
    final issues = _rawMode ? const <String>[] : validateComposeDraft(_draft);
    if (issues.isNotEmpty) {
      setState(() => _issues = issues);
      return;
    }
    final path = _path.text.trim().isEmpty
        ? '${_draft.workingDir.replaceFirst(RegExp(r'/+$'), '')}/${_draft.fileName}'
        : _path.text.trim();
    if (!path.startsWith('/') && !path.startsWith('~/')) {
      setState(
        () => _issues = const [
          'Compose file path must be absolute (or start with ~/).',
        ],
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('infra.builder.deployConfirm'),
        title: const Text('Deploy stack?'),
        content: Text(
          'OmniTerm will validate the YAML, replace $path atomically, and run Compose up -d. '
          'If startup fails, the previous file is restored.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Deploy'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<InfraViewModel>().deployCompose(
      path: path,
      project: _draft.projectName.trim(),
      yaml: _rendered,
      workingDir: _draft.workingDir,
      configFiles: _draft.composeConfigFiles,
      runtime: _draft.runtime,
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<InfraViewModel>();
    if (vm.composeEditRequest != _handledEditRequest &&
        vm.requestedComposeStack != null) {
      _handledEditRequest = vm.composeEditRequest;
      final requested = vm.requestedComposeStack!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(stack: requested);
      });
    }
    final stacks = vm.stacks
        .where((stack) => stack.canRunComposeActions)
        .toList();
    return BackInterceptor(
      onBack: _handleBack,
      child: ListView(
        key: const ValueKey('infra.builder'),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Compose Builder',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('infra.builder.new'),
                onPressed: () => setState(_newDraft),
                icon: const Icon(Icons.note_add_outlined),
                label: const Text('New'),
              ),
              TextButton.icon(
                onPressed: _preview,
                icon: const Icon(Icons.preview),
                label: const Text('Preview'),
              ),
              FilledButton.icon(
                key: const ValueKey('infra.builder.deploy'),
                onPressed: vm.composeBusy ? null : _deploy,
                icon: const Icon(Icons.rocket_launch, size: 17),
                label: Text(vm.composeBusy ? 'Working…' : 'Deploy'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OmniCard(
            leftAccent: OmniColors.purple,
            child: Column(
              children: [
                if (stacks.isNotEmpty)
                  DropdownButtonFormField<StackSummary>(
                    key: const ValueKey('infra.builder.existingStack'),
                    decoration: const InputDecoration(
                      labelText: 'Edit running stack',
                    ),
                    items: [
                      for (final stack in stacks)
                        DropdownMenuItem(
                          value: stack,
                          child: Text('${stack.name} · ${stack.runtime}'),
                        ),
                    ],
                    onChanged: vm.composeBusy
                        ? null
                        : (stack) => stack == null ? null : _load(stack: stack),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('infra.builder.path'),
                        controller: _path,
                        decoration: const InputDecoration(
                          labelText: 'Absolute compose file path',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      key: const ValueKey('infra.builder.load'),
                      onPressed: vm.composeBusy ? null : _load,
                      icon: const Icon(Icons.download, size: 17),
                      label: const Text('Load'),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Raw YAML',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Switch(
                      key: const ValueKey('infra.builder.rawToggle'),
                      value: _rawMode,
                      onChanged: _toggleRaw,
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (vm.composeError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                vm.composeError!,
                style: const TextStyle(color: OmniColors.red),
              ),
            ),
          if (_issues.isNotEmpty) _IssueCard(issues: _issues),
          const SizedBox(height: 10),
          if (_rawMode)
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.62,
              child: CodeEditor(
                controller: _raw,
                language: CodeLanguage.yaml,
                maxHighlightChars:
                    (context
                                .watch<AppState>()
                                .preferences
                                .editorHighlightLimitKb *
                            1024)
                        .clamp(0, highlightMaxCharsCap),
                textKey: const ValueKey('infra.builder.raw'),
                onChanged: (_) => setState(() {}),
              ),
            )
          else
            _VisualEditor(
              key: ValueKey(_generation),
              draft: _draft,
              onChanged: _changed,
            ),
        ],
      ),
    );
  }
}

class _IssueCard extends StatelessWidget {
  const _IssueCard({required this.issues});
  final List<String> issues;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: OmniCard(
      key: const ValueKey('infra.builder.issues'),
      leftAccent: OmniColors.red,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Fix before deploy',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: OmniColors.red,
            ),
          ),
          for (final issue in issues)
            Text('• $issue', style: const TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );
}

class _VisualEditor extends StatelessWidget {
  const _VisualEditor({
    super.key,
    required this.draft,
    required this.onChanged,
  });
  final ComposeStackDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      OmniCard(
        leftAccent: OmniColors.cyan,
        child: Column(
          children: [
            _field(
              'Project / -p name',
              draft.projectName,
              (value) => draft.projectName = value,
            ),
            _field(
              'Top-level name (optional)',
              draft.stackName,
              (value) => draft.stackName = value,
            ),
            _field(
              'Working directory',
              draft.workingDir,
              (value) => draft.workingDir = value,
            ),
            DropdownButtonFormField<String>(
              key: const ValueKey('infra.builder.runtime'),
              initialValue: draft.runtime,
              decoration: const InputDecoration(labelText: 'Runtime'),
              items: const [
                DropdownMenuItem(value: '', child: Text('Auto detect')),
                DropdownMenuItem(value: 'docker', child: Text('Docker')),
                DropdownMenuItem(value: 'podman', child: Text('Podman')),
              ],
              onChanged: (value) {
                draft.runtime = value ?? '';
                onChanged();
              },
            ),
          ],
        ),
      ),
      if (draft.runtime == 'podman') ...[
        const SizedBox(height: 10),
        _PodmanModifiersCard(draft: draft, onChanged: onChanged),
      ],
      const SizedBox(height: 10),
      Row(
        children: [
          const Expanded(
            child: Text(
              'Services',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          OutlinedButton.icon(
            key: const ValueKey('infra.builder.addService'),
            onPressed: () {
              draft.services.add(
                ComposeServiceDraft(serviceName: 'new_service'),
              );
              onChanged();
            },
            icon: const Icon(Icons.add, size: 17),
            label: const Text('Add service'),
          ),
        ],
      ),
      for (final service in [...draft.services])
        _ServiceCard(
          key: ValueKey(service.id),
          service: service,
          podman: draft.runtime == 'podman',
          onChanged: onChanged,
          onDelete: () {
            draft.services.remove(service);
            onChanged();
          },
        ),
      const SizedBox(height: 10),
      _TopLevelEditor(draft: draft, onChanged: onChanged),
    ],
  );

  Widget _field(String label, String value, ValueChanged<String> write) =>
      TextFormField(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        onChanged: (value) {
          write(value);
          onChanged();
        },
      );
}

/// Podman-only composition controls, ported from `PodmanModifiersEditor` in `ui/ComposeBuilder.kt`.
///
/// Both switches write real Compose/provider settings rather than app-local state: `userns_mode:
/// keep-id` on each service for rootless identity mapping, and `x-podman.in_pod` for pod grouping.
/// The keep-id switch is a bulk edit on purpose — it is the setting a rootless stack needs on *every*
/// service, and setting it one service at a time is how a stack ends up half-mapped.
class _PodmanModifiersCard extends StatelessWidget {
  const _PodmanModifiersCard({required this.draft, required this.onChanged});

  final ComposeStackDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final keepIdEnabled = podmanKeepIdEnabled(draft);

    return OmniCard(
      key: const ValueKey('infra.builder.podman'),
      leftAccent: OmniColors.purple,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Podman modifiers',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontFamily: OmniFonts.mono,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            "Podman runs as the SSH user. Keep-ID maps that user's UID/GID into each container.",
            style: TextStyle(fontSize: 11, color: OmniColors.textMuted),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Rootless keep-ID mapping',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              Switch(
                key: const ValueKey('infra.builder.podman.keepId'),
                value: keepIdEnabled,
                onChanged: (enabled) {
                  setPodmanKeepId(draft, enabled);
                  onChanged();
                },
              ),
            ],
          ),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Group services in a pod',
                      style: TextStyle(fontSize: 12),
                    ),
                    Text(
                      'Services share Podman pod namespaces using x-podman.in_pod.',
                      style: TextStyle(
                        fontSize: 10,
                        color: OmniColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                key: const ValueKey('infra.builder.podman.pod'),
                value: draft.podmanPodEnabled,
                onChanged: (enabled) {
                  draft.podmanPodEnabled = enabled;
                  // Dropping the name with the switch stops a disabled pod's name being written back
                  // out on the next render.
                  if (!enabled) draft.podmanPodName = '';
                  onChanged();
                },
              ),
            ],
          ),
          if (draft.podmanPodEnabled)
            TextFormField(
              key: const ValueKey('infra.builder.podman.podName'),
              initialValue: draft.podmanPodName,
              decoration: const InputDecoration(
                labelText: 'Pod name (optional)',
                hintText: 'pod_<project>',
                helperText:
                    "Blank uses Podman Compose's default pod_<project>.",
              ),
              onChanged: (value) {
                draft.podmanPodName = value.trim();
                onChanged();
              },
            ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatefulWidget {
  const _ServiceCard({
    super.key,
    required this.service,
    required this.podman,
    required this.onChanged,
    required this.onDelete,
  });
  final ComposeServiceDraft service;
  final bool podman;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  @override
  State<_ServiceCard> createState() => _ServiceCardState();
}

class _ServiceCardState extends State<_ServiceCard> {
  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: OmniCard(
        leftAccent: service.isCommentedOut
            ? OmniColors.textMuted
            : OmniColors.green,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: service.isExpanded ? 'Collapse' : 'Expand',
                  onPressed: () =>
                      setState(() => service.isExpanded = !service.isExpanded),
                  icon: Icon(
                    service.isExpanded ? Icons.expand_less : Icons.expand_more,
                  ),
                ),
                Expanded(
                  child: Text(
                    service.serviceName.isEmpty
                        ? 'Unnamed service'
                        : service.serviceName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Tooltip(
                  message: 'Comment this service out without deleting its YAML',
                  child: Switch(
                    value: !service.isCommentedOut,
                    onChanged: (enabled) {
                      service.isCommentedOut = !enabled;
                      widget.onChanged();
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Delete service',
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline, color: OmniColors.red),
                ),
              ],
            ),
            if (service.isExpanded) ...[
              _field(
                'Service name',
                service.serviceName,
                (value) => service.serviceName = value,
              ),
              _field('Image', service.image, (value) => service.image = value),
              _field(
                'Container name',
                service.containerName,
                (value) => service.containerName = value,
              ),
              DropdownButtonFormField<String>(
                initialValue:
                    const {
                      '',
                      'no',
                      'always',
                      'on-failure',
                      'unless-stopped',
                    }.contains(service.restart)
                    ? service.restart
                    : '',
                decoration: const InputDecoration(labelText: 'Restart policy'),
                items: const [
                  DropdownMenuItem(value: '', child: Text('Not set')),
                  DropdownMenuItem(value: 'no', child: Text('No')),
                  DropdownMenuItem(value: 'always', child: Text('Always')),
                  DropdownMenuItem(
                    value: 'on-failure',
                    child: Text('On failure'),
                  ),
                  DropdownMenuItem(
                    value: 'unless-stopped',
                    child: Text('Unless stopped'),
                  ),
                ],
                onChanged: (value) {
                  service.restart = value ?? '';
                  widget.onChanged();
                },
              ),
              _field(
                'Command',
                service.command,
                (value) => service.command = value,
              ),
              if (widget.podman)
                _field(
                  'userns_mode (for rootless: keep-id)',
                  service.usernsMode,
                  (value) => service.usernsMode = value,
                ),
              _list('Ports', service.ports),
              _list('Environment', service.environment),
              _list('Volumes', service.volumes),
              _list('Networks', service.networks),
              _list('Depends on', service.dependsOn),
              if (service.unmodeledArrayKeys.isNotEmpty)
                Text(
                  'Map/long syntax retained in Raw YAML: ${service.unmodeledArrayKeys.join(', ')}',
                  style: const TextStyle(fontSize: 11, color: OmniColors.amber),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _field(String label, String value, ValueChanged<String> write) =>
      TextFormField(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        onChanged: (value) {
          write(value);
          widget.onChanged();
        },
      );

  Widget _list(String label, List<String> values) => TextFormField(
    initialValue: values.join('\n'),
    minLines: 1,
    maxLines: 5,
    style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
    decoration: InputDecoration(labelText: '$label · one item per line'),
    onChanged: (value) {
      values
        ..clear()
        ..addAll(
          value
              .split('\n')
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty),
        );
      widget.onChanged();
    },
  );
}

class _TopLevelEditor extends StatelessWidget {
  const _TopLevelEditor({required this.draft, required this.onChanged});
  final ComposeStackDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => OmniCard(
    leftAccent: OmniColors.amber,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header('Top-level volumes', () {
          draft.topVolumes.add(TopLevelVolumeDraft());
          onChanged();
        }),
        for (final volume in [...draft.topVolumes])
          Row(
            children: [
              Expanded(
                child: _field(
                  'Volume name',
                  volume.name,
                  (value) => volume.name = value,
                ),
              ),
              const Text('External'),
              Checkbox(
                value: volume.external,
                onChanged: (value) {
                  volume.external = value ?? false;
                  onChanged();
                },
              ),
              IconButton(
                onPressed: () {
                  draft.topVolumes.remove(volume);
                  onChanged();
                },
                icon: const Icon(Icons.delete_outline, color: OmniColors.red),
              ),
            ],
          ),
        const Divider(),
        _header('Top-level networks', () {
          draft.topNetworks.add(TopLevelNetworkDraft());
          onChanged();
        }),
        for (final network in [...draft.topNetworks])
          Row(
            children: [
              Expanded(
                child: _field(
                  'Network name',
                  network.name,
                  (value) => network.name = value,
                ),
              ),
              Expanded(
                child: _field(
                  'Driver',
                  network.driver,
                  (value) => network.driver = value,
                ),
              ),
              const Text('External'),
              Checkbox(
                value: network.external,
                onChanged: (value) {
                  network.external = value ?? false;
                  onChanged();
                },
              ),
              IconButton(
                onPressed: () {
                  draft.topNetworks.remove(network);
                  onChanged();
                },
                icon: const Icon(Icons.delete_outline, color: OmniColors.red),
              ),
            ],
          ),
      ],
    ),
  );

  Widget _header(String label, VoidCallback add) => Row(
    children: [
      Expanded(
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      TextButton.icon(
        onPressed: add,
        icon: const Icon(Icons.add, size: 16),
        label: const Text('Add'),
      ),
    ],
  );

  Widget _field(String label, String value, ValueChanged<String> write) =>
      TextFormField(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        onChanged: (value) {
          write(value);
          onChanged();
        },
      );
}
