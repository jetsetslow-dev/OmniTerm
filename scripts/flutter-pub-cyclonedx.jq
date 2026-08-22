def package_ref($package):
  if $package.source == "hosted" then
    "pkg:pub/\($package.name | @uri)@\($package.version | @uri)"
  elif $package.source == "git" and $git_locks[$package.name] then
    ("git+" + $git_locks[$package.name].url + "@" +
      $git_locks[$package.name].resolvedRef | @uri) as $vcs_url
    | "pkg:generic/dart/\($package.name | @uri)@\($package.version | @uri)?vcs_url=\($vcs_url)"
  else
    "pkg:generic/dart/\($package.name | @uri)@\($package.version | @uri)?source=\($package.source | @uri)"
  end;

def closure($index; $queue; $seen):
  if ($queue | length) == 0 then
    $seen
  else
    $queue[0] as $name
    | if $seen[$name] then
        closure($index; $queue[1:]; $seen)
      else
        closure(
          $index;
          $queue[1:] + ($index[$name].directDependencies // []);
          $seen + {($name): true}
        )
      end
  end;

.root as $root_name
| INDEX(.packages[]; .name) as $index
| $index[$root_name] as $root
| ($root.directDependencies // []) as $direct
| closure($index; $direct; {}) as $runtime
| "pkg:generic/omniterm@\($release_version | @uri)?platform=flutter" as $root_ref
| {
    bomFormat: "CycloneDX",
    specVersion: "1.6",
    serialNumber: $serial_number,
    version: 1,
    metadata: {
      timestamp: $timestamp,
      tools: {
        components: [
          {
            type: "application",
            name: "Dart pub",
            version: $dart_version
          }
        ]
      },
      component: {
        type: "application",
        "bom-ref": $root_ref,
        name: "OmniTerm Flutter",
        version: $release_version,
        purl: $root_ref
      }
    },
    components: [
      $runtime
      | keys[] as $name
      | $index[$name] as $package
      | {
          type: "library",
          "bom-ref": package_ref($package),
          name: $package.name,
          version: $package.version,
          purl: package_ref($package),
          properties: [
            {name: "omniterm:dart:dependency-kind", value: $package.kind},
            {name: "omniterm:dart:source", value: $package.source}
          ] + (if $package.source == "git" and $git_locks[$package.name] then [
            {name: "omniterm:dart:git-url", value: $git_locks[$package.name].url},
            {name: "omniterm:dart:git-commit", value: $git_locks[$package.name].resolvedRef}
          ] else [] end)
        }
    ],
    dependencies: (
      [
        {
          ref: $root_ref,
          dependsOn: [
            $direct[]
            | select($runtime[.])
            | package_ref($index[.])
          ]
        }
      ]
      + [
          $runtime
          | keys[] as $name
          | {
              ref: package_ref($index[$name]),
              dependsOn: [
                ($index[$name].directDependencies // [])[]
                | select($runtime[.])
                | package_ref($index[.])
              ]
            }
        ]
    )
  }
