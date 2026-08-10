import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/screens/infra/compose_builder_logic.dart';

void main() {
  const existing = '''name: homelab
services:
  web:
    image: nginx:1.26
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost"]
    ports:
      - "8080:80"
    labels:
      owner: ops
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: app
volumes:
  data:
    external: true
networks:
  edge:
    driver: bridge
''';

  test(
    'parses the editable subset and records long/map syntax as lossless-only',
    () {
      final draft = parseDockerComposeYaml(existing, projectName: 'homelab');

      expect(draft.stackName, 'homelab');
      expect(draft.services.map((service) => service.serviceName), [
        'web',
        'db',
      ]);
      expect(draft.services.first.image, 'nginx:1.26');
      expect(draft.services.first.ports, ['8080:80']);
      expect(draft.services.last.unmodeledArrayKeys, contains('environment'));
      expect(draft.topVolumes.single.external, isTrue);
      expect(draft.topNetworks.single.driver, 'bridge');
    },
  );

  test(
    'surgical rendering changes owned fields and preserves unknown YAML byte content',
    () {
      final baseline = parseDockerComposeYaml(existing, projectName: 'homelab');
      final draft = cloneComposeDraft(baseline);
      draft.services.first.image = 'nginx:1.27';
      draft.services.first.ports.add('8443:443');

      final rendered = renderComposeYaml(draft, baseline);

      expect(rendered, contains('image: nginx:1.27'));
      expect(rendered, contains('      - "8443:443"'));
      expect(
        rendered,
        contains(
          'healthcheck:\n      test: ["CMD", "curl", "-f", "http://localhost"]',
        ),
      );
      expect(rendered, contains('labels:\n      owner: ops'));
      expect(rendered, contains('environment:\n      POSTGRES_DB: app'));
    },
  );

  test(
    'a new service is inserted inside services, before top-level volumes',
    () {
      final baseline = parseDockerComposeYaml(existing, projectName: 'homelab');
      final draft = cloneComposeDraft(baseline)
        ..services.add(
          ComposeServiceDraft(serviceName: 'worker', image: 'busybox:latest'),
        );
      final rendered = renderComposeYaml(draft, baseline);

      expect(
        rendered.indexOf('  worker:'),
        lessThan(rendered.indexOf('\nvolumes:')),
      );
    },
  );

  test(
    'new Podman files emit the supported pod extension and no obsolete version key',
    () {
      final draft = ComposeStackDraft(
        projectName: 'demo',
        stackName: 'demo',
        runtime: 'podman',
        podmanPodEnabled: true,
        podmanPodName: 'demo-pod',
        services: [ComposeServiceDraft(serviceName: 'app', image: 'alpine:3')],
      );

      final yaml = generateDockerComposeYaml(draft);
      expect(
        yaml,
        startsWith('name: demo\nx-podman:\n  in_pod: demo-pod\nservices:'),
      );
      expect(yaml, isNot(contains('version:')));
    },
  );

  test(
    'validation catches deploy-breaking relationships and malformed ports',
    () {
      final draft = ComposeStackDraft(
        services: [
          ComposeServiceDraft(
            serviceName: 'web',
            image: 'nginx',
            ports: ['70000:80'],
            dependsOn: ['db'],
          ),
          ComposeServiceDraft(
            serviceName: 'db',
            image: 'postgres',
            isCommentedOut: true,
          ),
          ComposeServiceDraft(serviceName: 'web', image: 'busybox'),
        ],
      );

      final issues = validateComposeDraft(draft).join('\n');
      expect(issues, contains('invalid port mapping'));
      expect(issues, contains('Duplicate active service name: web'));
      expect(issues, contains('depends on db, which is commented out'));
    },
  );

  /// The Podman rootless controls, ported from `PodmanModifiersEditor` in `ui/ComposeBuilder.kt`.
  ///
  /// Kotlin exposes keep-id as a single switch over the whole stack. Flutter previously required
  /// typing `keep-id` into a free-text field on every service, which is how a stack ends up
  /// half-mapped: rootless Podman needs the mapping everywhere or one container fails at run time.
  group('podman keep-id', () {
    ComposeStackDraft draftWith(List<ComposeServiceDraft> services) =>
        ComposeStackDraft(runtime: 'podman', services: services);

    test('an empty stack is not reported as mapped', () {
      expect(podmanKeepIdEnabled(draftWith([])), isFalse);
    });

    test('reads true only when every rendered service is mapped', () {
      final partly = draftWith([
        ComposeServiceDraft(serviceName: 'web', usernsMode: 'keep-id'),
        ComposeServiceDraft(serviceName: 'db'),
      ]);
      expect(podmanKeepIdEnabled(partly), isFalse);

      partly.services[1].usernsMode = 'keep-id';
      expect(podmanKeepIdEnabled(partly), isTrue);
    });

    test('a commented-out service does not hold the reading false', () {
      // It contributes nothing to the rendered file, so counting it would misreport a stack that is
      // in fact fully mapped.
      final draft = draftWith([
        ComposeServiceDraft(serviceName: 'web', usernsMode: 'keep-id'),
        ComposeServiceDraft(serviceName: 'old', isCommentedOut: true),
      ]);
      expect(podmanKeepIdEnabled(draft), isTrue);
    });

    test('enabling maps every service in one action', () {
      final draft = draftWith([
        ComposeServiceDraft(serviceName: 'web'),
        ComposeServiceDraft(serviceName: 'db'),
        ComposeServiceDraft(serviceName: 'cache'),
      ]);
      setPodmanKeepId(draft, true);
      expect(draft.services.every((s) => s.usernsMode == 'keep-id'), isTrue);
      expect(podmanKeepIdEnabled(draft), isTrue);
    });

    test('disabling clears what it set but keeps a hand-written value', () {
      final draft = draftWith([
        ComposeServiceDraft(serviceName: 'web', usernsMode: 'keep-id'),
        ComposeServiceDraft(serviceName: 'db', usernsMode: 'host'),
      ]);
      setPodmanKeepId(draft, false);
      expect(draft.services[0].usernsMode, '');
      expect(
        draft.services[1].usernsMode,
        'host',
        reason: "a userns_mode the user typed is theirs and must survive the switch",
      );
    });

    test('the mapping reaches the rendered file', () {
      // The switch is only worth anything if it changes the YAML that gets deployed.
      final draft = draftWith([ComposeServiceDraft(serviceName: 'web', image: 'nginx')]);
      setPodmanKeepId(draft, true);
      expect(renderComposeYaml(draft, null), contains('userns_mode: keep-id'));
    });
  });
}
