import 'package:uuid/uuid.dart';

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
  })  : id = id ?? const Uuid().v4(),
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
  })  : services = services ?? [ComposeServiceDraft()],
        topVolumes = topVolumes ?? [],
        topNetworks = topNetworks ?? [];
}
