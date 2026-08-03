// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $ServersTable extends Servers with TableInfo<$ServersTable, Server> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ServersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hostMeta = const VerificationMeta('host');
  @override
  late final GeneratedColumn<String> host = GeneratedColumn<String>(
    'host',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 22,
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _groupNameMeta = const VerificationMeta(
    'groupName',
  );
  @override
  late final GeneratedColumn<String> groupName = GeneratedColumn<String>(
    'groupName',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'Default',
  );
  static const VerificationMeta _serverColorMeta = const VerificationMeta(
    'serverColor',
  );
  @override
  late final GeneratedColumn<String> serverColor = GeneratedColumn<String>(
    'serverColor',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'Default',
  );
  static const VerificationMeta _authTypeMeta = const VerificationMeta(
    'authType',
  );
  @override
  late final GeneratedColumn<String> authType = GeneratedColumn<String>(
    'authType',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'password',
  );
  static const VerificationMeta _authKeyAliasMeta = const VerificationMeta(
    'authKeyAlias',
  );
  @override
  late final GeneratedColumn<String> authKeyAlias = GeneratedColumn<String>(
    'authKeyAlias',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _authPasswordMeta = const VerificationMeta(
    'authPassword',
  );
  @override
  late final GeneratedColumn<String> authPassword = GeneratedColumn<String>(
    'authPassword',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sudoPasswordMeta = const VerificationMeta(
    'sudoPassword',
  );
  @override
  late final GeneratedColumn<String> sudoPassword = GeneratedColumn<String>(
    'sudoPassword',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _authProfileIdMeta = const VerificationMeta(
    'authProfileId',
  );
  @override
  late final GeneratedColumn<int> authProfileId = GeneratedColumn<int>(
    'authProfileId',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _keepAliveMeta = const VerificationMeta(
    'keepAlive',
  );
  @override
  late final GeneratedColumn<int> keepAlive = GeneratedColumn<int>(
    'keepAlive',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 30,
  );
  static const VerificationMeta _sshCompressionMeta = const VerificationMeta(
    'sshCompression',
  );
  @override
  late final GeneratedColumn<bool> sshCompression = GeneratedColumn<bool>(
    'sshCompression',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("sshCompression" IN (0, 1))',
    ),
    clientDefault: () => false,
  );
  static const VerificationMeta _persistentSessionMeta = const VerificationMeta(
    'persistentSession',
  );
  @override
  late final GeneratedColumn<bool> persistentSession = GeneratedColumn<bool>(
    'persistentSession',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("persistentSession" IN (0, 1))',
    ),
    clientDefault: () => false,
  );
  static const VerificationMeta _proxyCommandMeta = const VerificationMeta(
    'proxyCommand',
  );
  @override
  late final GeneratedColumn<String> proxyCommand = GeneratedColumn<String>(
    'proxyCommand',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _proxyTypeMeta = const VerificationMeta(
    'proxyType',
  );
  @override
  late final GeneratedColumn<String> proxyType = GeneratedColumn<String>(
    'proxyType',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'none',
  );
  static const VerificationMeta _proxyHostMeta = const VerificationMeta(
    'proxyHost',
  );
  @override
  late final GeneratedColumn<String> proxyHost = GeneratedColumn<String>(
    'proxyHost',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _proxyPortMeta = const VerificationMeta(
    'proxyPort',
  );
  @override
  late final GeneratedColumn<int> proxyPort = GeneratedColumn<int>(
    'proxyPort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 0,
  );
  static const VerificationMeta _proxyUserMeta = const VerificationMeta(
    'proxyUser',
  );
  @override
  late final GeneratedColumn<String> proxyUser = GeneratedColumn<String>(
    'proxyUser',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _proxyPasswordMeta = const VerificationMeta(
    'proxyPassword',
  );
  @override
  late final GeneratedColumn<String> proxyPassword = GeneratedColumn<String>(
    'proxyPassword',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _proxyKeyAliasMeta = const VerificationMeta(
    'proxyKeyAlias',
  );
  @override
  late final GeneratedColumn<String> proxyKeyAlias = GeneratedColumn<String>(
    'proxyKeyAlias',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _agentForwardingMeta = const VerificationMeta(
    'agentForwarding',
  );
  @override
  late final GeneratedColumn<bool> agentForwarding = GeneratedColumn<bool>(
    'agentForwarding',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("agentForwarding" IN (0, 1))',
    ),
    clientDefault: () => false,
  );
  static const VerificationMeta _healthScoreMeta = const VerificationMeta(
    'healthScore',
  );
  @override
  late final GeneratedColumn<int> healthScore = GeneratedColumn<int>(
    'healthScore',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 100,
  );
  static const VerificationMeta _lastLatencyMeta = const VerificationMeta(
    'lastLatency',
  );
  @override
  late final GeneratedColumn<int> lastLatency = GeneratedColumn<int>(
    'lastLatency',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 0,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'offline',
  );
  static const VerificationMeta _authStatusMeta = const VerificationMeta(
    'authStatus',
  );
  @override
  late final GeneratedColumn<String> authStatus = GeneratedColumn<String>(
    'authStatus',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'unknown',
  );
  static const VerificationMeta _authErrorMeta = const VerificationMeta(
    'authError',
  );
  @override
  late final GeneratedColumn<String> authError = GeneratedColumn<String>(
    'authError',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    host,
    port,
    username,
    groupName,
    serverColor,
    authType,
    authKeyAlias,
    authPassword,
    sudoPassword,
    authProfileId,
    notes,
    keepAlive,
    sshCompression,
    persistentSession,
    proxyCommand,
    proxyType,
    proxyHost,
    proxyPort,
    proxyUser,
    proxyPassword,
    proxyKeyAlias,
    agentForwarding,
    healthScore,
    lastLatency,
    status,
    authStatus,
    authError,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'servers';
  @override
  VerificationContext validateIntegrity(
    Insertable<Server> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('host')) {
      context.handle(
        _hostMeta,
        host.isAcceptableOrUnknown(data['host']!, _hostMeta),
      );
    } else if (isInserting) {
      context.missing(_hostMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('groupName')) {
      context.handle(
        _groupNameMeta,
        groupName.isAcceptableOrUnknown(data['groupName']!, _groupNameMeta),
      );
    }
    if (data.containsKey('serverColor')) {
      context.handle(
        _serverColorMeta,
        serverColor.isAcceptableOrUnknown(
          data['serverColor']!,
          _serverColorMeta,
        ),
      );
    }
    if (data.containsKey('authType')) {
      context.handle(
        _authTypeMeta,
        authType.isAcceptableOrUnknown(data['authType']!, _authTypeMeta),
      );
    }
    if (data.containsKey('authKeyAlias')) {
      context.handle(
        _authKeyAliasMeta,
        authKeyAlias.isAcceptableOrUnknown(
          data['authKeyAlias']!,
          _authKeyAliasMeta,
        ),
      );
    }
    if (data.containsKey('authPassword')) {
      context.handle(
        _authPasswordMeta,
        authPassword.isAcceptableOrUnknown(
          data['authPassword']!,
          _authPasswordMeta,
        ),
      );
    }
    if (data.containsKey('sudoPassword')) {
      context.handle(
        _sudoPasswordMeta,
        sudoPassword.isAcceptableOrUnknown(
          data['sudoPassword']!,
          _sudoPasswordMeta,
        ),
      );
    }
    if (data.containsKey('authProfileId')) {
      context.handle(
        _authProfileIdMeta,
        authProfileId.isAcceptableOrUnknown(
          data['authProfileId']!,
          _authProfileIdMeta,
        ),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('keepAlive')) {
      context.handle(
        _keepAliveMeta,
        keepAlive.isAcceptableOrUnknown(data['keepAlive']!, _keepAliveMeta),
      );
    }
    if (data.containsKey('sshCompression')) {
      context.handle(
        _sshCompressionMeta,
        sshCompression.isAcceptableOrUnknown(
          data['sshCompression']!,
          _sshCompressionMeta,
        ),
      );
    }
    if (data.containsKey('persistentSession')) {
      context.handle(
        _persistentSessionMeta,
        persistentSession.isAcceptableOrUnknown(
          data['persistentSession']!,
          _persistentSessionMeta,
        ),
      );
    }
    if (data.containsKey('proxyCommand')) {
      context.handle(
        _proxyCommandMeta,
        proxyCommand.isAcceptableOrUnknown(
          data['proxyCommand']!,
          _proxyCommandMeta,
        ),
      );
    }
    if (data.containsKey('proxyType')) {
      context.handle(
        _proxyTypeMeta,
        proxyType.isAcceptableOrUnknown(data['proxyType']!, _proxyTypeMeta),
      );
    }
    if (data.containsKey('proxyHost')) {
      context.handle(
        _proxyHostMeta,
        proxyHost.isAcceptableOrUnknown(data['proxyHost']!, _proxyHostMeta),
      );
    }
    if (data.containsKey('proxyPort')) {
      context.handle(
        _proxyPortMeta,
        proxyPort.isAcceptableOrUnknown(data['proxyPort']!, _proxyPortMeta),
      );
    }
    if (data.containsKey('proxyUser')) {
      context.handle(
        _proxyUserMeta,
        proxyUser.isAcceptableOrUnknown(data['proxyUser']!, _proxyUserMeta),
      );
    }
    if (data.containsKey('proxyPassword')) {
      context.handle(
        _proxyPasswordMeta,
        proxyPassword.isAcceptableOrUnknown(
          data['proxyPassword']!,
          _proxyPasswordMeta,
        ),
      );
    }
    if (data.containsKey('proxyKeyAlias')) {
      context.handle(
        _proxyKeyAliasMeta,
        proxyKeyAlias.isAcceptableOrUnknown(
          data['proxyKeyAlias']!,
          _proxyKeyAliasMeta,
        ),
      );
    }
    if (data.containsKey('agentForwarding')) {
      context.handle(
        _agentForwardingMeta,
        agentForwarding.isAcceptableOrUnknown(
          data['agentForwarding']!,
          _agentForwardingMeta,
        ),
      );
    }
    if (data.containsKey('healthScore')) {
      context.handle(
        _healthScoreMeta,
        healthScore.isAcceptableOrUnknown(
          data['healthScore']!,
          _healthScoreMeta,
        ),
      );
    }
    if (data.containsKey('lastLatency')) {
      context.handle(
        _lastLatencyMeta,
        lastLatency.isAcceptableOrUnknown(
          data['lastLatency']!,
          _lastLatencyMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('authStatus')) {
      context.handle(
        _authStatusMeta,
        authStatus.isAcceptableOrUnknown(data['authStatus']!, _authStatusMeta),
      );
    }
    if (data.containsKey('authError')) {
      context.handle(
        _authErrorMeta,
        authError.isAcceptableOrUnknown(data['authError']!, _authErrorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Server map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Server(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      host: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}host'],
      )!,
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      groupName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}groupName'],
      ),
      serverColor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}serverColor'],
      )!,
      authType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}authType'],
      )!,
      authKeyAlias: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}authKeyAlias'],
      ),
      authPassword: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}authPassword'],
      ),
      sudoPassword: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sudoPassword'],
      )!,
      authProfileId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}authProfileId'],
      ),
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      )!,
      keepAlive: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}keepAlive'],
      )!,
      sshCompression: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}sshCompression'],
      )!,
      persistentSession: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}persistentSession'],
      )!,
      proxyCommand: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}proxyCommand'],
      )!,
      proxyType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}proxyType'],
      )!,
      proxyHost: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}proxyHost'],
      )!,
      proxyPort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}proxyPort'],
      )!,
      proxyUser: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}proxyUser'],
      )!,
      proxyPassword: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}proxyPassword'],
      )!,
      proxyKeyAlias: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}proxyKeyAlias'],
      ),
      agentForwarding: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}agentForwarding'],
      )!,
      healthScore: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}healthScore'],
      )!,
      lastLatency: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}lastLatency'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      authStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}authStatus'],
      )!,
      authError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}authError'],
      ),
    );
  }

  @override
  $ServersTable createAlias(String alias) {
    return $ServersTable(attachedDatabase, alias);
  }
}

class Server extends DataClass implements Insertable<Server> {
  final int id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String? groupName;

  /// "Default", or one of the six named accents; resolved by `OmniColors.serverAccent`.
  final String serverColor;

  /// "password", "key", or "profile".
  final String authType;
  final String? authKeyAlias;
  final String? authPassword;

  /// Optional sudo password for privileged actions; encrypted at the repository boundary.
  /// When set, it is fed to `sudo -S` via stdin so password-protected sudo works.
  final String sudoPassword;
  final int? authProfileId;
  final String notes;

  /// Seconds.
  final int keepAlive;
  final bool sshCompression;

  /// When true, interactive shells launch inside a persistent tmux session so a dropped connection
  /// can reconnect and re-attach the SAME session (long-running commands keep running server-side).
  final bool persistentSession;
  final String proxyCommand;

  /// "none", "http", "socks5", or "ssh" (jump host).
  final String proxyType;
  final String proxyHost;
  final int proxyPort;
  final String proxyUser;
  final String proxyPassword;

  /// Saved SSH key alias for jump-host auth (proxyType == "ssh"); null = password only.
  final String? proxyKeyAlias;

  /// Forward the SSH auth agent to this host (ssh -A) so onward hops can use our key.
  final bool agentForwarding;
  final int healthScore;
  final int lastLatency;

  /// "online", "offline", or "connecting".
  final String status;

  /// Auth state is tracked separately from TCP reachability: a host can be "online" (port
  /// reachable) yet "failed" auth (wrong key/password). Metrics are only shown when
  /// authStatus == "ok". One of "unknown", "ok", "failed".
  final String authStatus;
  final String? authError;
  const Server({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    this.groupName,
    required this.serverColor,
    required this.authType,
    this.authKeyAlias,
    this.authPassword,
    required this.sudoPassword,
    this.authProfileId,
    required this.notes,
    required this.keepAlive,
    required this.sshCompression,
    required this.persistentSession,
    required this.proxyCommand,
    required this.proxyType,
    required this.proxyHost,
    required this.proxyPort,
    required this.proxyUser,
    required this.proxyPassword,
    this.proxyKeyAlias,
    required this.agentForwarding,
    required this.healthScore,
    required this.lastLatency,
    required this.status,
    required this.authStatus,
    this.authError,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['host'] = Variable<String>(host);
    map['port'] = Variable<int>(port);
    map['username'] = Variable<String>(username);
    if (!nullToAbsent || groupName != null) {
      map['groupName'] = Variable<String>(groupName);
    }
    map['serverColor'] = Variable<String>(serverColor);
    map['authType'] = Variable<String>(authType);
    if (!nullToAbsent || authKeyAlias != null) {
      map['authKeyAlias'] = Variable<String>(authKeyAlias);
    }
    if (!nullToAbsent || authPassword != null) {
      map['authPassword'] = Variable<String>(authPassword);
    }
    map['sudoPassword'] = Variable<String>(sudoPassword);
    if (!nullToAbsent || authProfileId != null) {
      map['authProfileId'] = Variable<int>(authProfileId);
    }
    map['notes'] = Variable<String>(notes);
    map['keepAlive'] = Variable<int>(keepAlive);
    map['sshCompression'] = Variable<bool>(sshCompression);
    map['persistentSession'] = Variable<bool>(persistentSession);
    map['proxyCommand'] = Variable<String>(proxyCommand);
    map['proxyType'] = Variable<String>(proxyType);
    map['proxyHost'] = Variable<String>(proxyHost);
    map['proxyPort'] = Variable<int>(proxyPort);
    map['proxyUser'] = Variable<String>(proxyUser);
    map['proxyPassword'] = Variable<String>(proxyPassword);
    if (!nullToAbsent || proxyKeyAlias != null) {
      map['proxyKeyAlias'] = Variable<String>(proxyKeyAlias);
    }
    map['agentForwarding'] = Variable<bool>(agentForwarding);
    map['healthScore'] = Variable<int>(healthScore);
    map['lastLatency'] = Variable<int>(lastLatency);
    map['status'] = Variable<String>(status);
    map['authStatus'] = Variable<String>(authStatus);
    if (!nullToAbsent || authError != null) {
      map['authError'] = Variable<String>(authError);
    }
    return map;
  }

  ServersCompanion toCompanion(bool nullToAbsent) {
    return ServersCompanion(
      id: Value(id),
      name: Value(name),
      host: Value(host),
      port: Value(port),
      username: Value(username),
      groupName: groupName == null && nullToAbsent
          ? const Value.absent()
          : Value(groupName),
      serverColor: Value(serverColor),
      authType: Value(authType),
      authKeyAlias: authKeyAlias == null && nullToAbsent
          ? const Value.absent()
          : Value(authKeyAlias),
      authPassword: authPassword == null && nullToAbsent
          ? const Value.absent()
          : Value(authPassword),
      sudoPassword: Value(sudoPassword),
      authProfileId: authProfileId == null && nullToAbsent
          ? const Value.absent()
          : Value(authProfileId),
      notes: Value(notes),
      keepAlive: Value(keepAlive),
      sshCompression: Value(sshCompression),
      persistentSession: Value(persistentSession),
      proxyCommand: Value(proxyCommand),
      proxyType: Value(proxyType),
      proxyHost: Value(proxyHost),
      proxyPort: Value(proxyPort),
      proxyUser: Value(proxyUser),
      proxyPassword: Value(proxyPassword),
      proxyKeyAlias: proxyKeyAlias == null && nullToAbsent
          ? const Value.absent()
          : Value(proxyKeyAlias),
      agentForwarding: Value(agentForwarding),
      healthScore: Value(healthScore),
      lastLatency: Value(lastLatency),
      status: Value(status),
      authStatus: Value(authStatus),
      authError: authError == null && nullToAbsent
          ? const Value.absent()
          : Value(authError),
    );
  }

  factory Server.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Server(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      host: serializer.fromJson<String>(json['host']),
      port: serializer.fromJson<int>(json['port']),
      username: serializer.fromJson<String>(json['username']),
      groupName: serializer.fromJson<String?>(json['groupName']),
      serverColor: serializer.fromJson<String>(json['serverColor']),
      authType: serializer.fromJson<String>(json['authType']),
      authKeyAlias: serializer.fromJson<String?>(json['authKeyAlias']),
      authPassword: serializer.fromJson<String?>(json['authPassword']),
      sudoPassword: serializer.fromJson<String>(json['sudoPassword']),
      authProfileId: serializer.fromJson<int?>(json['authProfileId']),
      notes: serializer.fromJson<String>(json['notes']),
      keepAlive: serializer.fromJson<int>(json['keepAlive']),
      sshCompression: serializer.fromJson<bool>(json['sshCompression']),
      persistentSession: serializer.fromJson<bool>(json['persistentSession']),
      proxyCommand: serializer.fromJson<String>(json['proxyCommand']),
      proxyType: serializer.fromJson<String>(json['proxyType']),
      proxyHost: serializer.fromJson<String>(json['proxyHost']),
      proxyPort: serializer.fromJson<int>(json['proxyPort']),
      proxyUser: serializer.fromJson<String>(json['proxyUser']),
      proxyPassword: serializer.fromJson<String>(json['proxyPassword']),
      proxyKeyAlias: serializer.fromJson<String?>(json['proxyKeyAlias']),
      agentForwarding: serializer.fromJson<bool>(json['agentForwarding']),
      healthScore: serializer.fromJson<int>(json['healthScore']),
      lastLatency: serializer.fromJson<int>(json['lastLatency']),
      status: serializer.fromJson<String>(json['status']),
      authStatus: serializer.fromJson<String>(json['authStatus']),
      authError: serializer.fromJson<String?>(json['authError']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'host': serializer.toJson<String>(host),
      'port': serializer.toJson<int>(port),
      'username': serializer.toJson<String>(username),
      'groupName': serializer.toJson<String?>(groupName),
      'serverColor': serializer.toJson<String>(serverColor),
      'authType': serializer.toJson<String>(authType),
      'authKeyAlias': serializer.toJson<String?>(authKeyAlias),
      'authPassword': serializer.toJson<String?>(authPassword),
      'sudoPassword': serializer.toJson<String>(sudoPassword),
      'authProfileId': serializer.toJson<int?>(authProfileId),
      'notes': serializer.toJson<String>(notes),
      'keepAlive': serializer.toJson<int>(keepAlive),
      'sshCompression': serializer.toJson<bool>(sshCompression),
      'persistentSession': serializer.toJson<bool>(persistentSession),
      'proxyCommand': serializer.toJson<String>(proxyCommand),
      'proxyType': serializer.toJson<String>(proxyType),
      'proxyHost': serializer.toJson<String>(proxyHost),
      'proxyPort': serializer.toJson<int>(proxyPort),
      'proxyUser': serializer.toJson<String>(proxyUser),
      'proxyPassword': serializer.toJson<String>(proxyPassword),
      'proxyKeyAlias': serializer.toJson<String?>(proxyKeyAlias),
      'agentForwarding': serializer.toJson<bool>(agentForwarding),
      'healthScore': serializer.toJson<int>(healthScore),
      'lastLatency': serializer.toJson<int>(lastLatency),
      'status': serializer.toJson<String>(status),
      'authStatus': serializer.toJson<String>(authStatus),
      'authError': serializer.toJson<String?>(authError),
    };
  }

  Server copyWith({
    int? id,
    String? name,
    String? host,
    int? port,
    String? username,
    Value<String?> groupName = const Value.absent(),
    String? serverColor,
    String? authType,
    Value<String?> authKeyAlias = const Value.absent(),
    Value<String?> authPassword = const Value.absent(),
    String? sudoPassword,
    Value<int?> authProfileId = const Value.absent(),
    String? notes,
    int? keepAlive,
    bool? sshCompression,
    bool? persistentSession,
    String? proxyCommand,
    String? proxyType,
    String? proxyHost,
    int? proxyPort,
    String? proxyUser,
    String? proxyPassword,
    Value<String?> proxyKeyAlias = const Value.absent(),
    bool? agentForwarding,
    int? healthScore,
    int? lastLatency,
    String? status,
    String? authStatus,
    Value<String?> authError = const Value.absent(),
  }) => Server(
    id: id ?? this.id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    groupName: groupName.present ? groupName.value : this.groupName,
    serverColor: serverColor ?? this.serverColor,
    authType: authType ?? this.authType,
    authKeyAlias: authKeyAlias.present ? authKeyAlias.value : this.authKeyAlias,
    authPassword: authPassword.present ? authPassword.value : this.authPassword,
    sudoPassword: sudoPassword ?? this.sudoPassword,
    authProfileId: authProfileId.present
        ? authProfileId.value
        : this.authProfileId,
    notes: notes ?? this.notes,
    keepAlive: keepAlive ?? this.keepAlive,
    sshCompression: sshCompression ?? this.sshCompression,
    persistentSession: persistentSession ?? this.persistentSession,
    proxyCommand: proxyCommand ?? this.proxyCommand,
    proxyType: proxyType ?? this.proxyType,
    proxyHost: proxyHost ?? this.proxyHost,
    proxyPort: proxyPort ?? this.proxyPort,
    proxyUser: proxyUser ?? this.proxyUser,
    proxyPassword: proxyPassword ?? this.proxyPassword,
    proxyKeyAlias: proxyKeyAlias.present
        ? proxyKeyAlias.value
        : this.proxyKeyAlias,
    agentForwarding: agentForwarding ?? this.agentForwarding,
    healthScore: healthScore ?? this.healthScore,
    lastLatency: lastLatency ?? this.lastLatency,
    status: status ?? this.status,
    authStatus: authStatus ?? this.authStatus,
    authError: authError.present ? authError.value : this.authError,
  );
  Server copyWithCompanion(ServersCompanion data) {
    return Server(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      host: data.host.present ? data.host.value : this.host,
      port: data.port.present ? data.port.value : this.port,
      username: data.username.present ? data.username.value : this.username,
      groupName: data.groupName.present ? data.groupName.value : this.groupName,
      serverColor: data.serverColor.present
          ? data.serverColor.value
          : this.serverColor,
      authType: data.authType.present ? data.authType.value : this.authType,
      authKeyAlias: data.authKeyAlias.present
          ? data.authKeyAlias.value
          : this.authKeyAlias,
      authPassword: data.authPassword.present
          ? data.authPassword.value
          : this.authPassword,
      sudoPassword: data.sudoPassword.present
          ? data.sudoPassword.value
          : this.sudoPassword,
      authProfileId: data.authProfileId.present
          ? data.authProfileId.value
          : this.authProfileId,
      notes: data.notes.present ? data.notes.value : this.notes,
      keepAlive: data.keepAlive.present ? data.keepAlive.value : this.keepAlive,
      sshCompression: data.sshCompression.present
          ? data.sshCompression.value
          : this.sshCompression,
      persistentSession: data.persistentSession.present
          ? data.persistentSession.value
          : this.persistentSession,
      proxyCommand: data.proxyCommand.present
          ? data.proxyCommand.value
          : this.proxyCommand,
      proxyType: data.proxyType.present ? data.proxyType.value : this.proxyType,
      proxyHost: data.proxyHost.present ? data.proxyHost.value : this.proxyHost,
      proxyPort: data.proxyPort.present ? data.proxyPort.value : this.proxyPort,
      proxyUser: data.proxyUser.present ? data.proxyUser.value : this.proxyUser,
      proxyPassword: data.proxyPassword.present
          ? data.proxyPassword.value
          : this.proxyPassword,
      proxyKeyAlias: data.proxyKeyAlias.present
          ? data.proxyKeyAlias.value
          : this.proxyKeyAlias,
      agentForwarding: data.agentForwarding.present
          ? data.agentForwarding.value
          : this.agentForwarding,
      healthScore: data.healthScore.present
          ? data.healthScore.value
          : this.healthScore,
      lastLatency: data.lastLatency.present
          ? data.lastLatency.value
          : this.lastLatency,
      status: data.status.present ? data.status.value : this.status,
      authStatus: data.authStatus.present
          ? data.authStatus.value
          : this.authStatus,
      authError: data.authError.present ? data.authError.value : this.authError,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Server(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('username: $username, ')
          ..write('groupName: $groupName, ')
          ..write('serverColor: $serverColor, ')
          ..write('authType: $authType, ')
          ..write('authKeyAlias: $authKeyAlias, ')
          ..write('authPassword: $authPassword, ')
          ..write('sudoPassword: $sudoPassword, ')
          ..write('authProfileId: $authProfileId, ')
          ..write('notes: $notes, ')
          ..write('keepAlive: $keepAlive, ')
          ..write('sshCompression: $sshCompression, ')
          ..write('persistentSession: $persistentSession, ')
          ..write('proxyCommand: $proxyCommand, ')
          ..write('proxyType: $proxyType, ')
          ..write('proxyHost: $proxyHost, ')
          ..write('proxyPort: $proxyPort, ')
          ..write('proxyUser: $proxyUser, ')
          ..write('proxyPassword: $proxyPassword, ')
          ..write('proxyKeyAlias: $proxyKeyAlias, ')
          ..write('agentForwarding: $agentForwarding, ')
          ..write('healthScore: $healthScore, ')
          ..write('lastLatency: $lastLatency, ')
          ..write('status: $status, ')
          ..write('authStatus: $authStatus, ')
          ..write('authError: $authError')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    name,
    host,
    port,
    username,
    groupName,
    serverColor,
    authType,
    authKeyAlias,
    authPassword,
    sudoPassword,
    authProfileId,
    notes,
    keepAlive,
    sshCompression,
    persistentSession,
    proxyCommand,
    proxyType,
    proxyHost,
    proxyPort,
    proxyUser,
    proxyPassword,
    proxyKeyAlias,
    agentForwarding,
    healthScore,
    lastLatency,
    status,
    authStatus,
    authError,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Server &&
          other.id == this.id &&
          other.name == this.name &&
          other.host == this.host &&
          other.port == this.port &&
          other.username == this.username &&
          other.groupName == this.groupName &&
          other.serverColor == this.serverColor &&
          other.authType == this.authType &&
          other.authKeyAlias == this.authKeyAlias &&
          other.authPassword == this.authPassword &&
          other.sudoPassword == this.sudoPassword &&
          other.authProfileId == this.authProfileId &&
          other.notes == this.notes &&
          other.keepAlive == this.keepAlive &&
          other.sshCompression == this.sshCompression &&
          other.persistentSession == this.persistentSession &&
          other.proxyCommand == this.proxyCommand &&
          other.proxyType == this.proxyType &&
          other.proxyHost == this.proxyHost &&
          other.proxyPort == this.proxyPort &&
          other.proxyUser == this.proxyUser &&
          other.proxyPassword == this.proxyPassword &&
          other.proxyKeyAlias == this.proxyKeyAlias &&
          other.agentForwarding == this.agentForwarding &&
          other.healthScore == this.healthScore &&
          other.lastLatency == this.lastLatency &&
          other.status == this.status &&
          other.authStatus == this.authStatus &&
          other.authError == this.authError);
}

class ServersCompanion extends UpdateCompanion<Server> {
  final Value<int> id;
  final Value<String> name;
  final Value<String> host;
  final Value<int> port;
  final Value<String> username;
  final Value<String?> groupName;
  final Value<String> serverColor;
  final Value<String> authType;
  final Value<String?> authKeyAlias;
  final Value<String?> authPassword;
  final Value<String> sudoPassword;
  final Value<int?> authProfileId;
  final Value<String> notes;
  final Value<int> keepAlive;
  final Value<bool> sshCompression;
  final Value<bool> persistentSession;
  final Value<String> proxyCommand;
  final Value<String> proxyType;
  final Value<String> proxyHost;
  final Value<int> proxyPort;
  final Value<String> proxyUser;
  final Value<String> proxyPassword;
  final Value<String?> proxyKeyAlias;
  final Value<bool> agentForwarding;
  final Value<int> healthScore;
  final Value<int> lastLatency;
  final Value<String> status;
  final Value<String> authStatus;
  final Value<String?> authError;
  const ServersCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.host = const Value.absent(),
    this.port = const Value.absent(),
    this.username = const Value.absent(),
    this.groupName = const Value.absent(),
    this.serverColor = const Value.absent(),
    this.authType = const Value.absent(),
    this.authKeyAlias = const Value.absent(),
    this.authPassword = const Value.absent(),
    this.sudoPassword = const Value.absent(),
    this.authProfileId = const Value.absent(),
    this.notes = const Value.absent(),
    this.keepAlive = const Value.absent(),
    this.sshCompression = const Value.absent(),
    this.persistentSession = const Value.absent(),
    this.proxyCommand = const Value.absent(),
    this.proxyType = const Value.absent(),
    this.proxyHost = const Value.absent(),
    this.proxyPort = const Value.absent(),
    this.proxyUser = const Value.absent(),
    this.proxyPassword = const Value.absent(),
    this.proxyKeyAlias = const Value.absent(),
    this.agentForwarding = const Value.absent(),
    this.healthScore = const Value.absent(),
    this.lastLatency = const Value.absent(),
    this.status = const Value.absent(),
    this.authStatus = const Value.absent(),
    this.authError = const Value.absent(),
  });
  ServersCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    required String host,
    this.port = const Value.absent(),
    required String username,
    this.groupName = const Value.absent(),
    this.serverColor = const Value.absent(),
    this.authType = const Value.absent(),
    this.authKeyAlias = const Value.absent(),
    this.authPassword = const Value.absent(),
    this.sudoPassword = const Value.absent(),
    this.authProfileId = const Value.absent(),
    this.notes = const Value.absent(),
    this.keepAlive = const Value.absent(),
    this.sshCompression = const Value.absent(),
    this.persistentSession = const Value.absent(),
    this.proxyCommand = const Value.absent(),
    this.proxyType = const Value.absent(),
    this.proxyHost = const Value.absent(),
    this.proxyPort = const Value.absent(),
    this.proxyUser = const Value.absent(),
    this.proxyPassword = const Value.absent(),
    this.proxyKeyAlias = const Value.absent(),
    this.agentForwarding = const Value.absent(),
    this.healthScore = const Value.absent(),
    this.lastLatency = const Value.absent(),
    this.status = const Value.absent(),
    this.authStatus = const Value.absent(),
    this.authError = const Value.absent(),
  }) : name = Value(name),
       host = Value(host),
       username = Value(username);
  static Insertable<Server> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? host,
    Expression<int>? port,
    Expression<String>? username,
    Expression<String>? groupName,
    Expression<String>? serverColor,
    Expression<String>? authType,
    Expression<String>? authKeyAlias,
    Expression<String>? authPassword,
    Expression<String>? sudoPassword,
    Expression<int>? authProfileId,
    Expression<String>? notes,
    Expression<int>? keepAlive,
    Expression<bool>? sshCompression,
    Expression<bool>? persistentSession,
    Expression<String>? proxyCommand,
    Expression<String>? proxyType,
    Expression<String>? proxyHost,
    Expression<int>? proxyPort,
    Expression<String>? proxyUser,
    Expression<String>? proxyPassword,
    Expression<String>? proxyKeyAlias,
    Expression<bool>? agentForwarding,
    Expression<int>? healthScore,
    Expression<int>? lastLatency,
    Expression<String>? status,
    Expression<String>? authStatus,
    Expression<String>? authError,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (host != null) 'host': host,
      if (port != null) 'port': port,
      if (username != null) 'username': username,
      if (groupName != null) 'groupName': groupName,
      if (serverColor != null) 'serverColor': serverColor,
      if (authType != null) 'authType': authType,
      if (authKeyAlias != null) 'authKeyAlias': authKeyAlias,
      if (authPassword != null) 'authPassword': authPassword,
      if (sudoPassword != null) 'sudoPassword': sudoPassword,
      if (authProfileId != null) 'authProfileId': authProfileId,
      if (notes != null) 'notes': notes,
      if (keepAlive != null) 'keepAlive': keepAlive,
      if (sshCompression != null) 'sshCompression': sshCompression,
      if (persistentSession != null) 'persistentSession': persistentSession,
      if (proxyCommand != null) 'proxyCommand': proxyCommand,
      if (proxyType != null) 'proxyType': proxyType,
      if (proxyHost != null) 'proxyHost': proxyHost,
      if (proxyPort != null) 'proxyPort': proxyPort,
      if (proxyUser != null) 'proxyUser': proxyUser,
      if (proxyPassword != null) 'proxyPassword': proxyPassword,
      if (proxyKeyAlias != null) 'proxyKeyAlias': proxyKeyAlias,
      if (agentForwarding != null) 'agentForwarding': agentForwarding,
      if (healthScore != null) 'healthScore': healthScore,
      if (lastLatency != null) 'lastLatency': lastLatency,
      if (status != null) 'status': status,
      if (authStatus != null) 'authStatus': authStatus,
      if (authError != null) 'authError': authError,
    });
  }

  ServersCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<String>? host,
    Value<int>? port,
    Value<String>? username,
    Value<String?>? groupName,
    Value<String>? serverColor,
    Value<String>? authType,
    Value<String?>? authKeyAlias,
    Value<String?>? authPassword,
    Value<String>? sudoPassword,
    Value<int?>? authProfileId,
    Value<String>? notes,
    Value<int>? keepAlive,
    Value<bool>? sshCompression,
    Value<bool>? persistentSession,
    Value<String>? proxyCommand,
    Value<String>? proxyType,
    Value<String>? proxyHost,
    Value<int>? proxyPort,
    Value<String>? proxyUser,
    Value<String>? proxyPassword,
    Value<String?>? proxyKeyAlias,
    Value<bool>? agentForwarding,
    Value<int>? healthScore,
    Value<int>? lastLatency,
    Value<String>? status,
    Value<String>? authStatus,
    Value<String?>? authError,
  }) {
    return ServersCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      groupName: groupName ?? this.groupName,
      serverColor: serverColor ?? this.serverColor,
      authType: authType ?? this.authType,
      authKeyAlias: authKeyAlias ?? this.authKeyAlias,
      authPassword: authPassword ?? this.authPassword,
      sudoPassword: sudoPassword ?? this.sudoPassword,
      authProfileId: authProfileId ?? this.authProfileId,
      notes: notes ?? this.notes,
      keepAlive: keepAlive ?? this.keepAlive,
      sshCompression: sshCompression ?? this.sshCompression,
      persistentSession: persistentSession ?? this.persistentSession,
      proxyCommand: proxyCommand ?? this.proxyCommand,
      proxyType: proxyType ?? this.proxyType,
      proxyHost: proxyHost ?? this.proxyHost,
      proxyPort: proxyPort ?? this.proxyPort,
      proxyUser: proxyUser ?? this.proxyUser,
      proxyPassword: proxyPassword ?? this.proxyPassword,
      proxyKeyAlias: proxyKeyAlias ?? this.proxyKeyAlias,
      agentForwarding: agentForwarding ?? this.agentForwarding,
      healthScore: healthScore ?? this.healthScore,
      lastLatency: lastLatency ?? this.lastLatency,
      status: status ?? this.status,
      authStatus: authStatus ?? this.authStatus,
      authError: authError ?? this.authError,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (host.present) {
      map['host'] = Variable<String>(host.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (groupName.present) {
      map['groupName'] = Variable<String>(groupName.value);
    }
    if (serverColor.present) {
      map['serverColor'] = Variable<String>(serverColor.value);
    }
    if (authType.present) {
      map['authType'] = Variable<String>(authType.value);
    }
    if (authKeyAlias.present) {
      map['authKeyAlias'] = Variable<String>(authKeyAlias.value);
    }
    if (authPassword.present) {
      map['authPassword'] = Variable<String>(authPassword.value);
    }
    if (sudoPassword.present) {
      map['sudoPassword'] = Variable<String>(sudoPassword.value);
    }
    if (authProfileId.present) {
      map['authProfileId'] = Variable<int>(authProfileId.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (keepAlive.present) {
      map['keepAlive'] = Variable<int>(keepAlive.value);
    }
    if (sshCompression.present) {
      map['sshCompression'] = Variable<bool>(sshCompression.value);
    }
    if (persistentSession.present) {
      map['persistentSession'] = Variable<bool>(persistentSession.value);
    }
    if (proxyCommand.present) {
      map['proxyCommand'] = Variable<String>(proxyCommand.value);
    }
    if (proxyType.present) {
      map['proxyType'] = Variable<String>(proxyType.value);
    }
    if (proxyHost.present) {
      map['proxyHost'] = Variable<String>(proxyHost.value);
    }
    if (proxyPort.present) {
      map['proxyPort'] = Variable<int>(proxyPort.value);
    }
    if (proxyUser.present) {
      map['proxyUser'] = Variable<String>(proxyUser.value);
    }
    if (proxyPassword.present) {
      map['proxyPassword'] = Variable<String>(proxyPassword.value);
    }
    if (proxyKeyAlias.present) {
      map['proxyKeyAlias'] = Variable<String>(proxyKeyAlias.value);
    }
    if (agentForwarding.present) {
      map['agentForwarding'] = Variable<bool>(agentForwarding.value);
    }
    if (healthScore.present) {
      map['healthScore'] = Variable<int>(healthScore.value);
    }
    if (lastLatency.present) {
      map['lastLatency'] = Variable<int>(lastLatency.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (authStatus.present) {
      map['authStatus'] = Variable<String>(authStatus.value);
    }
    if (authError.present) {
      map['authError'] = Variable<String>(authError.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ServersCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('username: $username, ')
          ..write('groupName: $groupName, ')
          ..write('serverColor: $serverColor, ')
          ..write('authType: $authType, ')
          ..write('authKeyAlias: $authKeyAlias, ')
          ..write('authPassword: $authPassword, ')
          ..write('sudoPassword: $sudoPassword, ')
          ..write('authProfileId: $authProfileId, ')
          ..write('notes: $notes, ')
          ..write('keepAlive: $keepAlive, ')
          ..write('sshCompression: $sshCompression, ')
          ..write('persistentSession: $persistentSession, ')
          ..write('proxyCommand: $proxyCommand, ')
          ..write('proxyType: $proxyType, ')
          ..write('proxyHost: $proxyHost, ')
          ..write('proxyPort: $proxyPort, ')
          ..write('proxyUser: $proxyUser, ')
          ..write('proxyPassword: $proxyPassword, ')
          ..write('proxyKeyAlias: $proxyKeyAlias, ')
          ..write('agentForwarding: $agentForwarding, ')
          ..write('healthScore: $healthScore, ')
          ..write('lastLatency: $lastLatency, ')
          ..write('status: $status, ')
          ..write('authStatus: $authStatus, ')
          ..write('authError: $authError')
          ..write(')'))
        .toString();
  }
}

class $MetricHistoryTable extends MetricHistory
    with TableInfo<$MetricHistoryTable, MetricHistoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MetricHistoryTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<int> serverId = GeneratedColumn<int>(
    'serverId',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<int> timestamp = GeneratedColumn<int>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cpuUsageMeta = const VerificationMeta(
    'cpuUsage',
  );
  @override
  late final GeneratedColumn<double> cpuUsage = GeneratedColumn<double>(
    'cpuUsage',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ramUsageMeta = const VerificationMeta(
    'ramUsage',
  );
  @override
  late final GeneratedColumn<double> ramUsage = GeneratedColumn<double>(
    'ramUsage',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _diskUsageMeta = const VerificationMeta(
    'diskUsage',
  );
  @override
  late final GeneratedColumn<double> diskUsage = GeneratedColumn<double>(
    'diskUsage',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _latencyMeta = const VerificationMeta(
    'latency',
  );
  @override
  late final GeneratedColumn<int> latency = GeneratedColumn<int>(
    'latency',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _networkInMeta = const VerificationMeta(
    'networkIn',
  );
  @override
  late final GeneratedColumn<double> networkIn = GeneratedColumn<double>(
    'networkIn',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _networkOutMeta = const VerificationMeta(
    'networkOut',
  );
  @override
  late final GeneratedColumn<double> networkOut = GeneratedColumn<double>(
    'networkOut',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cpuTemperatureCMeta = const VerificationMeta(
    'cpuTemperatureC',
  );
  @override
  late final GeneratedColumn<double> cpuTemperatureC = GeneratedColumn<double>(
    'cpuTemperatureC',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    serverId,
    timestamp,
    cpuUsage,
    ramUsage,
    diskUsage,
    latency,
    networkIn,
    networkOut,
    cpuTemperatureC,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'metric_history';
  @override
  VerificationContext validateIntegrity(
    Insertable<MetricHistoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('serverId')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['serverId']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('cpuUsage')) {
      context.handle(
        _cpuUsageMeta,
        cpuUsage.isAcceptableOrUnknown(data['cpuUsage']!, _cpuUsageMeta),
      );
    } else if (isInserting) {
      context.missing(_cpuUsageMeta);
    }
    if (data.containsKey('ramUsage')) {
      context.handle(
        _ramUsageMeta,
        ramUsage.isAcceptableOrUnknown(data['ramUsage']!, _ramUsageMeta),
      );
    } else if (isInserting) {
      context.missing(_ramUsageMeta);
    }
    if (data.containsKey('diskUsage')) {
      context.handle(
        _diskUsageMeta,
        diskUsage.isAcceptableOrUnknown(data['diskUsage']!, _diskUsageMeta),
      );
    } else if (isInserting) {
      context.missing(_diskUsageMeta);
    }
    if (data.containsKey('latency')) {
      context.handle(
        _latencyMeta,
        latency.isAcceptableOrUnknown(data['latency']!, _latencyMeta),
      );
    } else if (isInserting) {
      context.missing(_latencyMeta);
    }
    if (data.containsKey('networkIn')) {
      context.handle(
        _networkInMeta,
        networkIn.isAcceptableOrUnknown(data['networkIn']!, _networkInMeta),
      );
    } else if (isInserting) {
      context.missing(_networkInMeta);
    }
    if (data.containsKey('networkOut')) {
      context.handle(
        _networkOutMeta,
        networkOut.isAcceptableOrUnknown(data['networkOut']!, _networkOutMeta),
      );
    } else if (isInserting) {
      context.missing(_networkOutMeta);
    }
    if (data.containsKey('cpuTemperatureC')) {
      context.handle(
        _cpuTemperatureCMeta,
        cpuTemperatureC.isAcceptableOrUnknown(
          data['cpuTemperatureC']!,
          _cpuTemperatureCMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MetricHistoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MetricHistoryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}serverId'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}timestamp'],
      )!,
      cpuUsage: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}cpuUsage'],
      )!,
      ramUsage: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}ramUsage'],
      )!,
      diskUsage: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}diskUsage'],
      )!,
      latency: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}latency'],
      )!,
      networkIn: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}networkIn'],
      )!,
      networkOut: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}networkOut'],
      )!,
      cpuTemperatureC: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}cpuTemperatureC'],
      ),
    );
  }

  @override
  $MetricHistoryTable createAlias(String alias) {
    return $MetricHistoryTable(attachedDatabase, alias);
  }
}

class MetricHistoryRow extends DataClass
    implements Insertable<MetricHistoryRow> {
  final int id;
  final int serverId;
  final int timestamp;
  final double cpuUsage;
  final double ramUsage;
  final double diskUsage;
  final int latency;

  /// KB/s.
  final double networkIn;

  /// KB/s.
  final double networkOut;

  /// Null when the host exposes no readable thermal sensor.
  final double? cpuTemperatureC;
  const MetricHistoryRow({
    required this.id,
    required this.serverId,
    required this.timestamp,
    required this.cpuUsage,
    required this.ramUsage,
    required this.diskUsage,
    required this.latency,
    required this.networkIn,
    required this.networkOut,
    this.cpuTemperatureC,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['serverId'] = Variable<int>(serverId);
    map['timestamp'] = Variable<int>(timestamp);
    map['cpuUsage'] = Variable<double>(cpuUsage);
    map['ramUsage'] = Variable<double>(ramUsage);
    map['diskUsage'] = Variable<double>(diskUsage);
    map['latency'] = Variable<int>(latency);
    map['networkIn'] = Variable<double>(networkIn);
    map['networkOut'] = Variable<double>(networkOut);
    if (!nullToAbsent || cpuTemperatureC != null) {
      map['cpuTemperatureC'] = Variable<double>(cpuTemperatureC);
    }
    return map;
  }

  MetricHistoryCompanion toCompanion(bool nullToAbsent) {
    return MetricHistoryCompanion(
      id: Value(id),
      serverId: Value(serverId),
      timestamp: Value(timestamp),
      cpuUsage: Value(cpuUsage),
      ramUsage: Value(ramUsage),
      diskUsage: Value(diskUsage),
      latency: Value(latency),
      networkIn: Value(networkIn),
      networkOut: Value(networkOut),
      cpuTemperatureC: cpuTemperatureC == null && nullToAbsent
          ? const Value.absent()
          : Value(cpuTemperatureC),
    );
  }

  factory MetricHistoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MetricHistoryRow(
      id: serializer.fromJson<int>(json['id']),
      serverId: serializer.fromJson<int>(json['serverId']),
      timestamp: serializer.fromJson<int>(json['timestamp']),
      cpuUsage: serializer.fromJson<double>(json['cpuUsage']),
      ramUsage: serializer.fromJson<double>(json['ramUsage']),
      diskUsage: serializer.fromJson<double>(json['diskUsage']),
      latency: serializer.fromJson<int>(json['latency']),
      networkIn: serializer.fromJson<double>(json['networkIn']),
      networkOut: serializer.fromJson<double>(json['networkOut']),
      cpuTemperatureC: serializer.fromJson<double?>(json['cpuTemperatureC']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'serverId': serializer.toJson<int>(serverId),
      'timestamp': serializer.toJson<int>(timestamp),
      'cpuUsage': serializer.toJson<double>(cpuUsage),
      'ramUsage': serializer.toJson<double>(ramUsage),
      'diskUsage': serializer.toJson<double>(diskUsage),
      'latency': serializer.toJson<int>(latency),
      'networkIn': serializer.toJson<double>(networkIn),
      'networkOut': serializer.toJson<double>(networkOut),
      'cpuTemperatureC': serializer.toJson<double?>(cpuTemperatureC),
    };
  }

  MetricHistoryRow copyWith({
    int? id,
    int? serverId,
    int? timestamp,
    double? cpuUsage,
    double? ramUsage,
    double? diskUsage,
    int? latency,
    double? networkIn,
    double? networkOut,
    Value<double?> cpuTemperatureC = const Value.absent(),
  }) => MetricHistoryRow(
    id: id ?? this.id,
    serverId: serverId ?? this.serverId,
    timestamp: timestamp ?? this.timestamp,
    cpuUsage: cpuUsage ?? this.cpuUsage,
    ramUsage: ramUsage ?? this.ramUsage,
    diskUsage: diskUsage ?? this.diskUsage,
    latency: latency ?? this.latency,
    networkIn: networkIn ?? this.networkIn,
    networkOut: networkOut ?? this.networkOut,
    cpuTemperatureC: cpuTemperatureC.present
        ? cpuTemperatureC.value
        : this.cpuTemperatureC,
  );
  MetricHistoryRow copyWithCompanion(MetricHistoryCompanion data) {
    return MetricHistoryRow(
      id: data.id.present ? data.id.value : this.id,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      cpuUsage: data.cpuUsage.present ? data.cpuUsage.value : this.cpuUsage,
      ramUsage: data.ramUsage.present ? data.ramUsage.value : this.ramUsage,
      diskUsage: data.diskUsage.present ? data.diskUsage.value : this.diskUsage,
      latency: data.latency.present ? data.latency.value : this.latency,
      networkIn: data.networkIn.present ? data.networkIn.value : this.networkIn,
      networkOut: data.networkOut.present
          ? data.networkOut.value
          : this.networkOut,
      cpuTemperatureC: data.cpuTemperatureC.present
          ? data.cpuTemperatureC.value
          : this.cpuTemperatureC,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MetricHistoryRow(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('timestamp: $timestamp, ')
          ..write('cpuUsage: $cpuUsage, ')
          ..write('ramUsage: $ramUsage, ')
          ..write('diskUsage: $diskUsage, ')
          ..write('latency: $latency, ')
          ..write('networkIn: $networkIn, ')
          ..write('networkOut: $networkOut, ')
          ..write('cpuTemperatureC: $cpuTemperatureC')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    serverId,
    timestamp,
    cpuUsage,
    ramUsage,
    diskUsage,
    latency,
    networkIn,
    networkOut,
    cpuTemperatureC,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MetricHistoryRow &&
          other.id == this.id &&
          other.serverId == this.serverId &&
          other.timestamp == this.timestamp &&
          other.cpuUsage == this.cpuUsage &&
          other.ramUsage == this.ramUsage &&
          other.diskUsage == this.diskUsage &&
          other.latency == this.latency &&
          other.networkIn == this.networkIn &&
          other.networkOut == this.networkOut &&
          other.cpuTemperatureC == this.cpuTemperatureC);
}

class MetricHistoryCompanion extends UpdateCompanion<MetricHistoryRow> {
  final Value<int> id;
  final Value<int> serverId;
  final Value<int> timestamp;
  final Value<double> cpuUsage;
  final Value<double> ramUsage;
  final Value<double> diskUsage;
  final Value<int> latency;
  final Value<double> networkIn;
  final Value<double> networkOut;
  final Value<double?> cpuTemperatureC;
  const MetricHistoryCompanion({
    this.id = const Value.absent(),
    this.serverId = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.cpuUsage = const Value.absent(),
    this.ramUsage = const Value.absent(),
    this.diskUsage = const Value.absent(),
    this.latency = const Value.absent(),
    this.networkIn = const Value.absent(),
    this.networkOut = const Value.absent(),
    this.cpuTemperatureC = const Value.absent(),
  });
  MetricHistoryCompanion.insert({
    this.id = const Value.absent(),
    required int serverId,
    required int timestamp,
    required double cpuUsage,
    required double ramUsage,
    required double diskUsage,
    required int latency,
    required double networkIn,
    required double networkOut,
    this.cpuTemperatureC = const Value.absent(),
  }) : serverId = Value(serverId),
       timestamp = Value(timestamp),
       cpuUsage = Value(cpuUsage),
       ramUsage = Value(ramUsage),
       diskUsage = Value(diskUsage),
       latency = Value(latency),
       networkIn = Value(networkIn),
       networkOut = Value(networkOut);
  static Insertable<MetricHistoryRow> custom({
    Expression<int>? id,
    Expression<int>? serverId,
    Expression<int>? timestamp,
    Expression<double>? cpuUsage,
    Expression<double>? ramUsage,
    Expression<double>? diskUsage,
    Expression<int>? latency,
    Expression<double>? networkIn,
    Expression<double>? networkOut,
    Expression<double>? cpuTemperatureC,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (serverId != null) 'serverId': serverId,
      if (timestamp != null) 'timestamp': timestamp,
      if (cpuUsage != null) 'cpuUsage': cpuUsage,
      if (ramUsage != null) 'ramUsage': ramUsage,
      if (diskUsage != null) 'diskUsage': diskUsage,
      if (latency != null) 'latency': latency,
      if (networkIn != null) 'networkIn': networkIn,
      if (networkOut != null) 'networkOut': networkOut,
      if (cpuTemperatureC != null) 'cpuTemperatureC': cpuTemperatureC,
    });
  }

  MetricHistoryCompanion copyWith({
    Value<int>? id,
    Value<int>? serverId,
    Value<int>? timestamp,
    Value<double>? cpuUsage,
    Value<double>? ramUsage,
    Value<double>? diskUsage,
    Value<int>? latency,
    Value<double>? networkIn,
    Value<double>? networkOut,
    Value<double?>? cpuTemperatureC,
  }) {
    return MetricHistoryCompanion(
      id: id ?? this.id,
      serverId: serverId ?? this.serverId,
      timestamp: timestamp ?? this.timestamp,
      cpuUsage: cpuUsage ?? this.cpuUsage,
      ramUsage: ramUsage ?? this.ramUsage,
      diskUsage: diskUsage ?? this.diskUsage,
      latency: latency ?? this.latency,
      networkIn: networkIn ?? this.networkIn,
      networkOut: networkOut ?? this.networkOut,
      cpuTemperatureC: cpuTemperatureC ?? this.cpuTemperatureC,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (serverId.present) {
      map['serverId'] = Variable<int>(serverId.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<int>(timestamp.value);
    }
    if (cpuUsage.present) {
      map['cpuUsage'] = Variable<double>(cpuUsage.value);
    }
    if (ramUsage.present) {
      map['ramUsage'] = Variable<double>(ramUsage.value);
    }
    if (diskUsage.present) {
      map['diskUsage'] = Variable<double>(diskUsage.value);
    }
    if (latency.present) {
      map['latency'] = Variable<int>(latency.value);
    }
    if (networkIn.present) {
      map['networkIn'] = Variable<double>(networkIn.value);
    }
    if (networkOut.present) {
      map['networkOut'] = Variable<double>(networkOut.value);
    }
    if (cpuTemperatureC.present) {
      map['cpuTemperatureC'] = Variable<double>(cpuTemperatureC.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MetricHistoryCompanion(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('timestamp: $timestamp, ')
          ..write('cpuUsage: $cpuUsage, ')
          ..write('ramUsage: $ramUsage, ')
          ..write('diskUsage: $diskUsage, ')
          ..write('latency: $latency, ')
          ..write('networkIn: $networkIn, ')
          ..write('networkOut: $networkOut, ')
          ..write('cpuTemperatureC: $cpuTemperatureC')
          ..write(')'))
        .toString();
  }
}

class $SshKeysTable extends SshKeys with TableInfo<$SshKeysTable, SshKey> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SshKeysTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _aliasMeta = const VerificationMeta('alias');
  @override
  late final GeneratedColumn<String> alias = GeneratedColumn<String>(
    'alias',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keyTypeMeta = const VerificationMeta(
    'keyType',
  );
  @override
  late final GeneratedColumn<String> keyType = GeneratedColumn<String>(
    'keyType',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _privateKeyMeta = const VerificationMeta(
    'privateKey',
  );
  @override
  late final GeneratedColumn<String> privateKey = GeneratedColumn<String>(
    'privateKey',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _publicKeyMeta = const VerificationMeta(
    'publicKey',
  );
  @override
  late final GeneratedColumn<String> publicKey = GeneratedColumn<String>(
    'publicKey',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fingerprintMeta = const VerificationMeta(
    'fingerprint',
  );
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
    'fingerprint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    alias,
    keyType,
    privateKey,
    publicKey,
    fingerprint,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ssh_keys';
  @override
  VerificationContext validateIntegrity(
    Insertable<SshKey> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('alias')) {
      context.handle(
        _aliasMeta,
        alias.isAcceptableOrUnknown(data['alias']!, _aliasMeta),
      );
    } else if (isInserting) {
      context.missing(_aliasMeta);
    }
    if (data.containsKey('keyType')) {
      context.handle(
        _keyTypeMeta,
        keyType.isAcceptableOrUnknown(data['keyType']!, _keyTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_keyTypeMeta);
    }
    if (data.containsKey('privateKey')) {
      context.handle(
        _privateKeyMeta,
        privateKey.isAcceptableOrUnknown(data['privateKey']!, _privateKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_privateKeyMeta);
    }
    if (data.containsKey('publicKey')) {
      context.handle(
        _publicKeyMeta,
        publicKey.isAcceptableOrUnknown(data['publicKey']!, _publicKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_publicKeyMeta);
    }
    if (data.containsKey('fingerprint')) {
      context.handle(
        _fingerprintMeta,
        fingerprint.isAcceptableOrUnknown(
          data['fingerprint']!,
          _fingerprintMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fingerprintMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SshKey map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SshKey(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      alias: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}alias'],
      )!,
      keyType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}keyType'],
      )!,
      privateKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}privateKey'],
      )!,
      publicKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}publicKey'],
      )!,
      fingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fingerprint'],
      )!,
    );
  }

  @override
  $SshKeysTable createAlias(String alias) {
    return $SshKeysTable(attachedDatabase, alias);
  }
}

class SshKey extends DataClass implements Insertable<SshKey> {
  final int id;
  final String alias;

  /// "RSA", "Ed25519", or "ECDSA".
  final String keyType;
  final String privateKey;
  final String publicKey;
  final String fingerprint;
  const SshKey({
    required this.id,
    required this.alias,
    required this.keyType,
    required this.privateKey,
    required this.publicKey,
    required this.fingerprint,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['alias'] = Variable<String>(alias);
    map['keyType'] = Variable<String>(keyType);
    map['privateKey'] = Variable<String>(privateKey);
    map['publicKey'] = Variable<String>(publicKey);
    map['fingerprint'] = Variable<String>(fingerprint);
    return map;
  }

  SshKeysCompanion toCompanion(bool nullToAbsent) {
    return SshKeysCompanion(
      id: Value(id),
      alias: Value(alias),
      keyType: Value(keyType),
      privateKey: Value(privateKey),
      publicKey: Value(publicKey),
      fingerprint: Value(fingerprint),
    );
  }

  factory SshKey.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SshKey(
      id: serializer.fromJson<int>(json['id']),
      alias: serializer.fromJson<String>(json['alias']),
      keyType: serializer.fromJson<String>(json['keyType']),
      privateKey: serializer.fromJson<String>(json['privateKey']),
      publicKey: serializer.fromJson<String>(json['publicKey']),
      fingerprint: serializer.fromJson<String>(json['fingerprint']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'alias': serializer.toJson<String>(alias),
      'keyType': serializer.toJson<String>(keyType),
      'privateKey': serializer.toJson<String>(privateKey),
      'publicKey': serializer.toJson<String>(publicKey),
      'fingerprint': serializer.toJson<String>(fingerprint),
    };
  }

  SshKey copyWith({
    int? id,
    String? alias,
    String? keyType,
    String? privateKey,
    String? publicKey,
    String? fingerprint,
  }) => SshKey(
    id: id ?? this.id,
    alias: alias ?? this.alias,
    keyType: keyType ?? this.keyType,
    privateKey: privateKey ?? this.privateKey,
    publicKey: publicKey ?? this.publicKey,
    fingerprint: fingerprint ?? this.fingerprint,
  );
  SshKey copyWithCompanion(SshKeysCompanion data) {
    return SshKey(
      id: data.id.present ? data.id.value : this.id,
      alias: data.alias.present ? data.alias.value : this.alias,
      keyType: data.keyType.present ? data.keyType.value : this.keyType,
      privateKey: data.privateKey.present
          ? data.privateKey.value
          : this.privateKey,
      publicKey: data.publicKey.present ? data.publicKey.value : this.publicKey,
      fingerprint: data.fingerprint.present
          ? data.fingerprint.value
          : this.fingerprint,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SshKey(')
          ..write('id: $id, ')
          ..write('alias: $alias, ')
          ..write('keyType: $keyType, ')
          ..write('privateKey: $privateKey, ')
          ..write('publicKey: $publicKey, ')
          ..write('fingerprint: $fingerprint')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, alias, keyType, privateKey, publicKey, fingerprint);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SshKey &&
          other.id == this.id &&
          other.alias == this.alias &&
          other.keyType == this.keyType &&
          other.privateKey == this.privateKey &&
          other.publicKey == this.publicKey &&
          other.fingerprint == this.fingerprint);
}

class SshKeysCompanion extends UpdateCompanion<SshKey> {
  final Value<int> id;
  final Value<String> alias;
  final Value<String> keyType;
  final Value<String> privateKey;
  final Value<String> publicKey;
  final Value<String> fingerprint;
  const SshKeysCompanion({
    this.id = const Value.absent(),
    this.alias = const Value.absent(),
    this.keyType = const Value.absent(),
    this.privateKey = const Value.absent(),
    this.publicKey = const Value.absent(),
    this.fingerprint = const Value.absent(),
  });
  SshKeysCompanion.insert({
    this.id = const Value.absent(),
    required String alias,
    required String keyType,
    required String privateKey,
    required String publicKey,
    required String fingerprint,
  }) : alias = Value(alias),
       keyType = Value(keyType),
       privateKey = Value(privateKey),
       publicKey = Value(publicKey),
       fingerprint = Value(fingerprint);
  static Insertable<SshKey> custom({
    Expression<int>? id,
    Expression<String>? alias,
    Expression<String>? keyType,
    Expression<String>? privateKey,
    Expression<String>? publicKey,
    Expression<String>? fingerprint,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (alias != null) 'alias': alias,
      if (keyType != null) 'keyType': keyType,
      if (privateKey != null) 'privateKey': privateKey,
      if (publicKey != null) 'publicKey': publicKey,
      if (fingerprint != null) 'fingerprint': fingerprint,
    });
  }

  SshKeysCompanion copyWith({
    Value<int>? id,
    Value<String>? alias,
    Value<String>? keyType,
    Value<String>? privateKey,
    Value<String>? publicKey,
    Value<String>? fingerprint,
  }) {
    return SshKeysCompanion(
      id: id ?? this.id,
      alias: alias ?? this.alias,
      keyType: keyType ?? this.keyType,
      privateKey: privateKey ?? this.privateKey,
      publicKey: publicKey ?? this.publicKey,
      fingerprint: fingerprint ?? this.fingerprint,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (alias.present) {
      map['alias'] = Variable<String>(alias.value);
    }
    if (keyType.present) {
      map['keyType'] = Variable<String>(keyType.value);
    }
    if (privateKey.present) {
      map['privateKey'] = Variable<String>(privateKey.value);
    }
    if (publicKey.present) {
      map['publicKey'] = Variable<String>(publicKey.value);
    }
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SshKeysCompanion(')
          ..write('id: $id, ')
          ..write('alias: $alias, ')
          ..write('keyType: $keyType, ')
          ..write('privateKey: $privateKey, ')
          ..write('publicKey: $publicKey, ')
          ..write('fingerprint: $fingerprint')
          ..write(')'))
        .toString();
  }
}

class $CredentialProfilesTable extends CredentialProfiles
    with TableInfo<$CredentialProfilesTable, CredentialProfile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CredentialProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _profileNameMeta = const VerificationMeta(
    'profileName',
  );
  @override
  late final GeneratedColumn<String> profileName = GeneratedColumn<String>(
    'profileName',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _authTypeMeta = const VerificationMeta(
    'authType',
  );
  @override
  late final GeneratedColumn<String> authType = GeneratedColumn<String>(
    'authType',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _passwordMeta = const VerificationMeta(
    'password',
  );
  @override
  late final GeneratedColumn<String> password = GeneratedColumn<String>(
    'password',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _keyAliasMeta = const VerificationMeta(
    'keyAlias',
  );
  @override
  late final GeneratedColumn<String> keyAlias = GeneratedColumn<String>(
    'keyAlias',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _groupNameMeta = const VerificationMeta(
    'groupName',
  );
  @override
  late final GeneratedColumn<String> groupName = GeneratedColumn<String>(
    'groupName',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'General',
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    profileName,
    username,
    authType,
    password,
    keyAlias,
    groupName,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'credential_profiles';
  @override
  VerificationContext validateIntegrity(
    Insertable<CredentialProfile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('profileName')) {
      context.handle(
        _profileNameMeta,
        profileName.isAcceptableOrUnknown(
          data['profileName']!,
          _profileNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_profileNameMeta);
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('authType')) {
      context.handle(
        _authTypeMeta,
        authType.isAcceptableOrUnknown(data['authType']!, _authTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_authTypeMeta);
    }
    if (data.containsKey('password')) {
      context.handle(
        _passwordMeta,
        password.isAcceptableOrUnknown(data['password']!, _passwordMeta),
      );
    }
    if (data.containsKey('keyAlias')) {
      context.handle(
        _keyAliasMeta,
        keyAlias.isAcceptableOrUnknown(data['keyAlias']!, _keyAliasMeta),
      );
    }
    if (data.containsKey('groupName')) {
      context.handle(
        _groupNameMeta,
        groupName.isAcceptableOrUnknown(data['groupName']!, _groupNameMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CredentialProfile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CredentialProfile(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      profileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profileName'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      authType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}authType'],
      )!,
      password: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}password'],
      ),
      keyAlias: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}keyAlias'],
      ),
      groupName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}groupName'],
      )!,
    );
  }

  @override
  $CredentialProfilesTable createAlias(String alias) {
    return $CredentialProfilesTable(attachedDatabase, alias);
  }
}

class CredentialProfile extends DataClass
    implements Insertable<CredentialProfile> {
  final int id;
  final String profileName;
  final String username;

  /// "password" or "key".
  final String authType;
  final String? password;
  final String? keyAlias;
  final String groupName;
  const CredentialProfile({
    required this.id,
    required this.profileName,
    required this.username,
    required this.authType,
    this.password,
    this.keyAlias,
    required this.groupName,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['profileName'] = Variable<String>(profileName);
    map['username'] = Variable<String>(username);
    map['authType'] = Variable<String>(authType);
    if (!nullToAbsent || password != null) {
      map['password'] = Variable<String>(password);
    }
    if (!nullToAbsent || keyAlias != null) {
      map['keyAlias'] = Variable<String>(keyAlias);
    }
    map['groupName'] = Variable<String>(groupName);
    return map;
  }

  CredentialProfilesCompanion toCompanion(bool nullToAbsent) {
    return CredentialProfilesCompanion(
      id: Value(id),
      profileName: Value(profileName),
      username: Value(username),
      authType: Value(authType),
      password: password == null && nullToAbsent
          ? const Value.absent()
          : Value(password),
      keyAlias: keyAlias == null && nullToAbsent
          ? const Value.absent()
          : Value(keyAlias),
      groupName: Value(groupName),
    );
  }

  factory CredentialProfile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CredentialProfile(
      id: serializer.fromJson<int>(json['id']),
      profileName: serializer.fromJson<String>(json['profileName']),
      username: serializer.fromJson<String>(json['username']),
      authType: serializer.fromJson<String>(json['authType']),
      password: serializer.fromJson<String?>(json['password']),
      keyAlias: serializer.fromJson<String?>(json['keyAlias']),
      groupName: serializer.fromJson<String>(json['groupName']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'profileName': serializer.toJson<String>(profileName),
      'username': serializer.toJson<String>(username),
      'authType': serializer.toJson<String>(authType),
      'password': serializer.toJson<String?>(password),
      'keyAlias': serializer.toJson<String?>(keyAlias),
      'groupName': serializer.toJson<String>(groupName),
    };
  }

  CredentialProfile copyWith({
    int? id,
    String? profileName,
    String? username,
    String? authType,
    Value<String?> password = const Value.absent(),
    Value<String?> keyAlias = const Value.absent(),
    String? groupName,
  }) => CredentialProfile(
    id: id ?? this.id,
    profileName: profileName ?? this.profileName,
    username: username ?? this.username,
    authType: authType ?? this.authType,
    password: password.present ? password.value : this.password,
    keyAlias: keyAlias.present ? keyAlias.value : this.keyAlias,
    groupName: groupName ?? this.groupName,
  );
  CredentialProfile copyWithCompanion(CredentialProfilesCompanion data) {
    return CredentialProfile(
      id: data.id.present ? data.id.value : this.id,
      profileName: data.profileName.present
          ? data.profileName.value
          : this.profileName,
      username: data.username.present ? data.username.value : this.username,
      authType: data.authType.present ? data.authType.value : this.authType,
      password: data.password.present ? data.password.value : this.password,
      keyAlias: data.keyAlias.present ? data.keyAlias.value : this.keyAlias,
      groupName: data.groupName.present ? data.groupName.value : this.groupName,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CredentialProfile(')
          ..write('id: $id, ')
          ..write('profileName: $profileName, ')
          ..write('username: $username, ')
          ..write('authType: $authType, ')
          ..write('password: $password, ')
          ..write('keyAlias: $keyAlias, ')
          ..write('groupName: $groupName')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    profileName,
    username,
    authType,
    password,
    keyAlias,
    groupName,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CredentialProfile &&
          other.id == this.id &&
          other.profileName == this.profileName &&
          other.username == this.username &&
          other.authType == this.authType &&
          other.password == this.password &&
          other.keyAlias == this.keyAlias &&
          other.groupName == this.groupName);
}

class CredentialProfilesCompanion extends UpdateCompanion<CredentialProfile> {
  final Value<int> id;
  final Value<String> profileName;
  final Value<String> username;
  final Value<String> authType;
  final Value<String?> password;
  final Value<String?> keyAlias;
  final Value<String> groupName;
  const CredentialProfilesCompanion({
    this.id = const Value.absent(),
    this.profileName = const Value.absent(),
    this.username = const Value.absent(),
    this.authType = const Value.absent(),
    this.password = const Value.absent(),
    this.keyAlias = const Value.absent(),
    this.groupName = const Value.absent(),
  });
  CredentialProfilesCompanion.insert({
    this.id = const Value.absent(),
    required String profileName,
    required String username,
    required String authType,
    this.password = const Value.absent(),
    this.keyAlias = const Value.absent(),
    this.groupName = const Value.absent(),
  }) : profileName = Value(profileName),
       username = Value(username),
       authType = Value(authType);
  static Insertable<CredentialProfile> custom({
    Expression<int>? id,
    Expression<String>? profileName,
    Expression<String>? username,
    Expression<String>? authType,
    Expression<String>? password,
    Expression<String>? keyAlias,
    Expression<String>? groupName,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileName != null) 'profileName': profileName,
      if (username != null) 'username': username,
      if (authType != null) 'authType': authType,
      if (password != null) 'password': password,
      if (keyAlias != null) 'keyAlias': keyAlias,
      if (groupName != null) 'groupName': groupName,
    });
  }

  CredentialProfilesCompanion copyWith({
    Value<int>? id,
    Value<String>? profileName,
    Value<String>? username,
    Value<String>? authType,
    Value<String?>? password,
    Value<String?>? keyAlias,
    Value<String>? groupName,
  }) {
    return CredentialProfilesCompanion(
      id: id ?? this.id,
      profileName: profileName ?? this.profileName,
      username: username ?? this.username,
      authType: authType ?? this.authType,
      password: password ?? this.password,
      keyAlias: keyAlias ?? this.keyAlias,
      groupName: groupName ?? this.groupName,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (profileName.present) {
      map['profileName'] = Variable<String>(profileName.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (authType.present) {
      map['authType'] = Variable<String>(authType.value);
    }
    if (password.present) {
      map['password'] = Variable<String>(password.value);
    }
    if (keyAlias.present) {
      map['keyAlias'] = Variable<String>(keyAlias.value);
    }
    if (groupName.present) {
      map['groupName'] = Variable<String>(groupName.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CredentialProfilesCompanion(')
          ..write('id: $id, ')
          ..write('profileName: $profileName, ')
          ..write('username: $username, ')
          ..write('authType: $authType, ')
          ..write('password: $password, ')
          ..write('keyAlias: $keyAlias, ')
          ..write('groupName: $groupName')
          ..write(')'))
        .toString();
  }
}

class $AlertRulesTable extends AlertRules
    with TableInfo<$AlertRulesTable, AlertRule> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AlertRulesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<int> serverId = GeneratedColumn<int>(
    'serverId',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _metricNameMeta = const VerificationMeta(
    'metricName',
  );
  @override
  late final GeneratedColumn<String> metricName = GeneratedColumn<String>(
    'metricName',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mountPointMeta = const VerificationMeta(
    'mountPoint',
  );
  @override
  late final GeneratedColumn<String> mountPoint = GeneratedColumn<String>(
    'mountPoint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '/',
  );
  static const VerificationMeta _thresholdValueMeta = const VerificationMeta(
    'thresholdValue',
  );
  @override
  late final GeneratedColumn<double> thresholdValue = GeneratedColumn<double>(
    'thresholdValue',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _severityMeta = const VerificationMeta(
    'severity',
  );
  @override
  late final GeneratedColumn<String> severity = GeneratedColumn<String>(
    'severity',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _triggerWindowMeta = const VerificationMeta(
    'triggerWindow',
  );
  @override
  late final GeneratedColumn<String> triggerWindow = GeneratedColumn<String>(
    'triggerWindow',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '5m',
  );
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled" IN (0, 1))',
    ),
    clientDefault: () => true,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _presetKeyMeta = const VerificationMeta(
    'presetKey',
  );
  @override
  late final GeneratedColumn<String> presetKey = GeneratedColumn<String>(
    'presetKey',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    serverId,
    metricName,
    mountPoint,
    thresholdValue,
    severity,
    triggerWindow,
    enabled,
    notes,
    presetKey,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'alert_rules';
  @override
  VerificationContext validateIntegrity(
    Insertable<AlertRule> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('serverId')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['serverId']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('metricName')) {
      context.handle(
        _metricNameMeta,
        metricName.isAcceptableOrUnknown(data['metricName']!, _metricNameMeta),
      );
    } else if (isInserting) {
      context.missing(_metricNameMeta);
    }
    if (data.containsKey('mountPoint')) {
      context.handle(
        _mountPointMeta,
        mountPoint.isAcceptableOrUnknown(data['mountPoint']!, _mountPointMeta),
      );
    }
    if (data.containsKey('thresholdValue')) {
      context.handle(
        _thresholdValueMeta,
        thresholdValue.isAcceptableOrUnknown(
          data['thresholdValue']!,
          _thresholdValueMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_thresholdValueMeta);
    }
    if (data.containsKey('severity')) {
      context.handle(
        _severityMeta,
        severity.isAcceptableOrUnknown(data['severity']!, _severityMeta),
      );
    } else if (isInserting) {
      context.missing(_severityMeta);
    }
    if (data.containsKey('triggerWindow')) {
      context.handle(
        _triggerWindowMeta,
        triggerWindow.isAcceptableOrUnknown(
          data['triggerWindow']!,
          _triggerWindowMeta,
        ),
      );
    }
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('presetKey')) {
      context.handle(
        _presetKeyMeta,
        presetKey.isAcceptableOrUnknown(data['presetKey']!, _presetKeyMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AlertRule map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AlertRule(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}serverId'],
      )!,
      metricName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metricName'],
      )!,
      mountPoint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mountPoint'],
      )!,
      thresholdValue: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}thresholdValue'],
      )!,
      severity: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}severity'],
      )!,
      triggerWindow: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}triggerWindow'],
      )!,
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      )!,
      presetKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}presetKey'],
      ),
    );
  }

  @override
  $AlertRulesTable createAlias(String alias) {
    return $AlertRulesTable(attachedDatabase, alias);
  }
}

class AlertRule extends DataClass implements Insertable<AlertRule> {
  final int id;
  final int serverId;

  /// "CPU Usage", "Memory Usage", "Disk Usage", "Network In", "Network Out", "Latency", or
  /// "Temperature" (which only evaluates on hosts that expose a thermal sensor).
  final String metricName;
  final String mountPoint;
  final double thresholdValue;

  /// "WARNING" or "CRITICAL".
  final String severity;

  /// "2m", "5m", "10m", or "15m".
  final String triggerWindow;
  final bool enabled;

  /// Free-text note documenting why this rule exists / what it watches for.
  final String notes;

  /// Stable identity of the built-in preset this rule was seeded from (e.g. "alert.cpu"), or null
  /// for user-created rules. Survives threshold/severity edits, so the default-rules toggle can
  /// delete exactly what it seeded instead of matching on mutable content.
  final String? presetKey;
  const AlertRule({
    required this.id,
    required this.serverId,
    required this.metricName,
    required this.mountPoint,
    required this.thresholdValue,
    required this.severity,
    required this.triggerWindow,
    required this.enabled,
    required this.notes,
    this.presetKey,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['serverId'] = Variable<int>(serverId);
    map['metricName'] = Variable<String>(metricName);
    map['mountPoint'] = Variable<String>(mountPoint);
    map['thresholdValue'] = Variable<double>(thresholdValue);
    map['severity'] = Variable<String>(severity);
    map['triggerWindow'] = Variable<String>(triggerWindow);
    map['enabled'] = Variable<bool>(enabled);
    map['notes'] = Variable<String>(notes);
    if (!nullToAbsent || presetKey != null) {
      map['presetKey'] = Variable<String>(presetKey);
    }
    return map;
  }

  AlertRulesCompanion toCompanion(bool nullToAbsent) {
    return AlertRulesCompanion(
      id: Value(id),
      serverId: Value(serverId),
      metricName: Value(metricName),
      mountPoint: Value(mountPoint),
      thresholdValue: Value(thresholdValue),
      severity: Value(severity),
      triggerWindow: Value(triggerWindow),
      enabled: Value(enabled),
      notes: Value(notes),
      presetKey: presetKey == null && nullToAbsent
          ? const Value.absent()
          : Value(presetKey),
    );
  }

  factory AlertRule.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AlertRule(
      id: serializer.fromJson<int>(json['id']),
      serverId: serializer.fromJson<int>(json['serverId']),
      metricName: serializer.fromJson<String>(json['metricName']),
      mountPoint: serializer.fromJson<String>(json['mountPoint']),
      thresholdValue: serializer.fromJson<double>(json['thresholdValue']),
      severity: serializer.fromJson<String>(json['severity']),
      triggerWindow: serializer.fromJson<String>(json['triggerWindow']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      notes: serializer.fromJson<String>(json['notes']),
      presetKey: serializer.fromJson<String?>(json['presetKey']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'serverId': serializer.toJson<int>(serverId),
      'metricName': serializer.toJson<String>(metricName),
      'mountPoint': serializer.toJson<String>(mountPoint),
      'thresholdValue': serializer.toJson<double>(thresholdValue),
      'severity': serializer.toJson<String>(severity),
      'triggerWindow': serializer.toJson<String>(triggerWindow),
      'enabled': serializer.toJson<bool>(enabled),
      'notes': serializer.toJson<String>(notes),
      'presetKey': serializer.toJson<String?>(presetKey),
    };
  }

  AlertRule copyWith({
    int? id,
    int? serverId,
    String? metricName,
    String? mountPoint,
    double? thresholdValue,
    String? severity,
    String? triggerWindow,
    bool? enabled,
    String? notes,
    Value<String?> presetKey = const Value.absent(),
  }) => AlertRule(
    id: id ?? this.id,
    serverId: serverId ?? this.serverId,
    metricName: metricName ?? this.metricName,
    mountPoint: mountPoint ?? this.mountPoint,
    thresholdValue: thresholdValue ?? this.thresholdValue,
    severity: severity ?? this.severity,
    triggerWindow: triggerWindow ?? this.triggerWindow,
    enabled: enabled ?? this.enabled,
    notes: notes ?? this.notes,
    presetKey: presetKey.present ? presetKey.value : this.presetKey,
  );
  AlertRule copyWithCompanion(AlertRulesCompanion data) {
    return AlertRule(
      id: data.id.present ? data.id.value : this.id,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      metricName: data.metricName.present
          ? data.metricName.value
          : this.metricName,
      mountPoint: data.mountPoint.present
          ? data.mountPoint.value
          : this.mountPoint,
      thresholdValue: data.thresholdValue.present
          ? data.thresholdValue.value
          : this.thresholdValue,
      severity: data.severity.present ? data.severity.value : this.severity,
      triggerWindow: data.triggerWindow.present
          ? data.triggerWindow.value
          : this.triggerWindow,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      notes: data.notes.present ? data.notes.value : this.notes,
      presetKey: data.presetKey.present ? data.presetKey.value : this.presetKey,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AlertRule(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('metricName: $metricName, ')
          ..write('mountPoint: $mountPoint, ')
          ..write('thresholdValue: $thresholdValue, ')
          ..write('severity: $severity, ')
          ..write('triggerWindow: $triggerWindow, ')
          ..write('enabled: $enabled, ')
          ..write('notes: $notes, ')
          ..write('presetKey: $presetKey')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    serverId,
    metricName,
    mountPoint,
    thresholdValue,
    severity,
    triggerWindow,
    enabled,
    notes,
    presetKey,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AlertRule &&
          other.id == this.id &&
          other.serverId == this.serverId &&
          other.metricName == this.metricName &&
          other.mountPoint == this.mountPoint &&
          other.thresholdValue == this.thresholdValue &&
          other.severity == this.severity &&
          other.triggerWindow == this.triggerWindow &&
          other.enabled == this.enabled &&
          other.notes == this.notes &&
          other.presetKey == this.presetKey);
}

class AlertRulesCompanion extends UpdateCompanion<AlertRule> {
  final Value<int> id;
  final Value<int> serverId;
  final Value<String> metricName;
  final Value<String> mountPoint;
  final Value<double> thresholdValue;
  final Value<String> severity;
  final Value<String> triggerWindow;
  final Value<bool> enabled;
  final Value<String> notes;
  final Value<String?> presetKey;
  const AlertRulesCompanion({
    this.id = const Value.absent(),
    this.serverId = const Value.absent(),
    this.metricName = const Value.absent(),
    this.mountPoint = const Value.absent(),
    this.thresholdValue = const Value.absent(),
    this.severity = const Value.absent(),
    this.triggerWindow = const Value.absent(),
    this.enabled = const Value.absent(),
    this.notes = const Value.absent(),
    this.presetKey = const Value.absent(),
  });
  AlertRulesCompanion.insert({
    this.id = const Value.absent(),
    required int serverId,
    required String metricName,
    this.mountPoint = const Value.absent(),
    required double thresholdValue,
    required String severity,
    this.triggerWindow = const Value.absent(),
    this.enabled = const Value.absent(),
    this.notes = const Value.absent(),
    this.presetKey = const Value.absent(),
  }) : serverId = Value(serverId),
       metricName = Value(metricName),
       thresholdValue = Value(thresholdValue),
       severity = Value(severity);
  static Insertable<AlertRule> custom({
    Expression<int>? id,
    Expression<int>? serverId,
    Expression<String>? metricName,
    Expression<String>? mountPoint,
    Expression<double>? thresholdValue,
    Expression<String>? severity,
    Expression<String>? triggerWindow,
    Expression<bool>? enabled,
    Expression<String>? notes,
    Expression<String>? presetKey,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (serverId != null) 'serverId': serverId,
      if (metricName != null) 'metricName': metricName,
      if (mountPoint != null) 'mountPoint': mountPoint,
      if (thresholdValue != null) 'thresholdValue': thresholdValue,
      if (severity != null) 'severity': severity,
      if (triggerWindow != null) 'triggerWindow': triggerWindow,
      if (enabled != null) 'enabled': enabled,
      if (notes != null) 'notes': notes,
      if (presetKey != null) 'presetKey': presetKey,
    });
  }

  AlertRulesCompanion copyWith({
    Value<int>? id,
    Value<int>? serverId,
    Value<String>? metricName,
    Value<String>? mountPoint,
    Value<double>? thresholdValue,
    Value<String>? severity,
    Value<String>? triggerWindow,
    Value<bool>? enabled,
    Value<String>? notes,
    Value<String?>? presetKey,
  }) {
    return AlertRulesCompanion(
      id: id ?? this.id,
      serverId: serverId ?? this.serverId,
      metricName: metricName ?? this.metricName,
      mountPoint: mountPoint ?? this.mountPoint,
      thresholdValue: thresholdValue ?? this.thresholdValue,
      severity: severity ?? this.severity,
      triggerWindow: triggerWindow ?? this.triggerWindow,
      enabled: enabled ?? this.enabled,
      notes: notes ?? this.notes,
      presetKey: presetKey ?? this.presetKey,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (serverId.present) {
      map['serverId'] = Variable<int>(serverId.value);
    }
    if (metricName.present) {
      map['metricName'] = Variable<String>(metricName.value);
    }
    if (mountPoint.present) {
      map['mountPoint'] = Variable<String>(mountPoint.value);
    }
    if (thresholdValue.present) {
      map['thresholdValue'] = Variable<double>(thresholdValue.value);
    }
    if (severity.present) {
      map['severity'] = Variable<String>(severity.value);
    }
    if (triggerWindow.present) {
      map['triggerWindow'] = Variable<String>(triggerWindow.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (presetKey.present) {
      map['presetKey'] = Variable<String>(presetKey.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AlertRulesCompanion(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('metricName: $metricName, ')
          ..write('mountPoint: $mountPoint, ')
          ..write('thresholdValue: $thresholdValue, ')
          ..write('severity: $severity, ')
          ..write('triggerWindow: $triggerWindow, ')
          ..write('enabled: $enabled, ')
          ..write('notes: $notes, ')
          ..write('presetKey: $presetKey')
          ..write(')'))
        .toString();
  }
}

class $ActiveAlertsTable extends ActiveAlerts
    with TableInfo<$ActiveAlertsTable, ActiveAlert> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ActiveAlertsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _ruleIdMeta = const VerificationMeta('ruleId');
  @override
  late final GeneratedColumn<int> ruleId = GeneratedColumn<int>(
    'ruleId',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<int> serverId = GeneratedColumn<int>(
    'serverId',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _metricNameMeta = const VerificationMeta(
    'metricName',
  );
  @override
  late final GeneratedColumn<String> metricName = GeneratedColumn<String>(
    'metricName',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _currentValueMeta = const VerificationMeta(
    'currentValue',
  );
  @override
  late final GeneratedColumn<double> currentValue = GeneratedColumn<double>(
    'currentValue',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _thresholdValueMeta = const VerificationMeta(
    'thresholdValue',
  );
  @override
  late final GeneratedColumn<double> thresholdValue = GeneratedColumn<double>(
    'thresholdValue',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _severityMeta = const VerificationMeta(
    'severity',
  );
  @override
  late final GeneratedColumn<String> severity = GeneratedColumn<String>(
    'severity',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _triggeredTimeMeta = const VerificationMeta(
    'triggeredTime',
  );
  @override
  late final GeneratedColumn<int> triggeredTime = GeneratedColumn<int>(
    'triggeredTime',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _acknowledgedMeta = const VerificationMeta(
    'acknowledged',
  );
  @override
  late final GeneratedColumn<bool> acknowledged = GeneratedColumn<bool>(
    'acknowledged',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("acknowledged" IN (0, 1))',
    ),
    clientDefault: () => false,
  );
  static const VerificationMeta _mutedUntilMeta = const VerificationMeta(
    'mutedUntil',
  );
  @override
  late final GeneratedColumn<int> mutedUntil = GeneratedColumn<int>(
    'mutedUntil',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 0,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    ruleId,
    serverId,
    metricName,
    currentValue,
    thresholdValue,
    severity,
    triggeredTime,
    acknowledged,
    mutedUntil,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'active_alerts';
  @override
  VerificationContext validateIntegrity(
    Insertable<ActiveAlert> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('ruleId')) {
      context.handle(
        _ruleIdMeta,
        ruleId.isAcceptableOrUnknown(data['ruleId']!, _ruleIdMeta),
      );
    } else if (isInserting) {
      context.missing(_ruleIdMeta);
    }
    if (data.containsKey('serverId')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['serverId']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('metricName')) {
      context.handle(
        _metricNameMeta,
        metricName.isAcceptableOrUnknown(data['metricName']!, _metricNameMeta),
      );
    } else if (isInserting) {
      context.missing(_metricNameMeta);
    }
    if (data.containsKey('currentValue')) {
      context.handle(
        _currentValueMeta,
        currentValue.isAcceptableOrUnknown(
          data['currentValue']!,
          _currentValueMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_currentValueMeta);
    }
    if (data.containsKey('thresholdValue')) {
      context.handle(
        _thresholdValueMeta,
        thresholdValue.isAcceptableOrUnknown(
          data['thresholdValue']!,
          _thresholdValueMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_thresholdValueMeta);
    }
    if (data.containsKey('severity')) {
      context.handle(
        _severityMeta,
        severity.isAcceptableOrUnknown(data['severity']!, _severityMeta),
      );
    } else if (isInserting) {
      context.missing(_severityMeta);
    }
    if (data.containsKey('triggeredTime')) {
      context.handle(
        _triggeredTimeMeta,
        triggeredTime.isAcceptableOrUnknown(
          data['triggeredTime']!,
          _triggeredTimeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_triggeredTimeMeta);
    }
    if (data.containsKey('acknowledged')) {
      context.handle(
        _acknowledgedMeta,
        acknowledged.isAcceptableOrUnknown(
          data['acknowledged']!,
          _acknowledgedMeta,
        ),
      );
    }
    if (data.containsKey('mutedUntil')) {
      context.handle(
        _mutedUntilMeta,
        mutedUntil.isAcceptableOrUnknown(data['mutedUntil']!, _mutedUntilMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ActiveAlert map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ActiveAlert(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      ruleId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ruleId'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}serverId'],
      )!,
      metricName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metricName'],
      )!,
      currentValue: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}currentValue'],
      )!,
      thresholdValue: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}thresholdValue'],
      )!,
      severity: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}severity'],
      )!,
      triggeredTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}triggeredTime'],
      )!,
      acknowledged: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}acknowledged'],
      )!,
      mutedUntil: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}mutedUntil'],
      )!,
    );
  }

  @override
  $ActiveAlertsTable createAlias(String alias) {
    return $ActiveAlertsTable(attachedDatabase, alias);
  }
}

class ActiveAlert extends DataClass implements Insertable<ActiveAlert> {
  final int id;
  final int ruleId;
  final int serverId;
  final String metricName;
  final double currentValue;
  final double thresholdValue;
  final String severity;
  final int triggeredTime;
  final bool acknowledged;

  /// Timestamp; 0 if not muted.
  final int mutedUntil;
  const ActiveAlert({
    required this.id,
    required this.ruleId,
    required this.serverId,
    required this.metricName,
    required this.currentValue,
    required this.thresholdValue,
    required this.severity,
    required this.triggeredTime,
    required this.acknowledged,
    required this.mutedUntil,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['ruleId'] = Variable<int>(ruleId);
    map['serverId'] = Variable<int>(serverId);
    map['metricName'] = Variable<String>(metricName);
    map['currentValue'] = Variable<double>(currentValue);
    map['thresholdValue'] = Variable<double>(thresholdValue);
    map['severity'] = Variable<String>(severity);
    map['triggeredTime'] = Variable<int>(triggeredTime);
    map['acknowledged'] = Variable<bool>(acknowledged);
    map['mutedUntil'] = Variable<int>(mutedUntil);
    return map;
  }

  ActiveAlertsCompanion toCompanion(bool nullToAbsent) {
    return ActiveAlertsCompanion(
      id: Value(id),
      ruleId: Value(ruleId),
      serverId: Value(serverId),
      metricName: Value(metricName),
      currentValue: Value(currentValue),
      thresholdValue: Value(thresholdValue),
      severity: Value(severity),
      triggeredTime: Value(triggeredTime),
      acknowledged: Value(acknowledged),
      mutedUntil: Value(mutedUntil),
    );
  }

  factory ActiveAlert.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ActiveAlert(
      id: serializer.fromJson<int>(json['id']),
      ruleId: serializer.fromJson<int>(json['ruleId']),
      serverId: serializer.fromJson<int>(json['serverId']),
      metricName: serializer.fromJson<String>(json['metricName']),
      currentValue: serializer.fromJson<double>(json['currentValue']),
      thresholdValue: serializer.fromJson<double>(json['thresholdValue']),
      severity: serializer.fromJson<String>(json['severity']),
      triggeredTime: serializer.fromJson<int>(json['triggeredTime']),
      acknowledged: serializer.fromJson<bool>(json['acknowledged']),
      mutedUntil: serializer.fromJson<int>(json['mutedUntil']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'ruleId': serializer.toJson<int>(ruleId),
      'serverId': serializer.toJson<int>(serverId),
      'metricName': serializer.toJson<String>(metricName),
      'currentValue': serializer.toJson<double>(currentValue),
      'thresholdValue': serializer.toJson<double>(thresholdValue),
      'severity': serializer.toJson<String>(severity),
      'triggeredTime': serializer.toJson<int>(triggeredTime),
      'acknowledged': serializer.toJson<bool>(acknowledged),
      'mutedUntil': serializer.toJson<int>(mutedUntil),
    };
  }

  ActiveAlert copyWith({
    int? id,
    int? ruleId,
    int? serverId,
    String? metricName,
    double? currentValue,
    double? thresholdValue,
    String? severity,
    int? triggeredTime,
    bool? acknowledged,
    int? mutedUntil,
  }) => ActiveAlert(
    id: id ?? this.id,
    ruleId: ruleId ?? this.ruleId,
    serverId: serverId ?? this.serverId,
    metricName: metricName ?? this.metricName,
    currentValue: currentValue ?? this.currentValue,
    thresholdValue: thresholdValue ?? this.thresholdValue,
    severity: severity ?? this.severity,
    triggeredTime: triggeredTime ?? this.triggeredTime,
    acknowledged: acknowledged ?? this.acknowledged,
    mutedUntil: mutedUntil ?? this.mutedUntil,
  );
  ActiveAlert copyWithCompanion(ActiveAlertsCompanion data) {
    return ActiveAlert(
      id: data.id.present ? data.id.value : this.id,
      ruleId: data.ruleId.present ? data.ruleId.value : this.ruleId,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      metricName: data.metricName.present
          ? data.metricName.value
          : this.metricName,
      currentValue: data.currentValue.present
          ? data.currentValue.value
          : this.currentValue,
      thresholdValue: data.thresholdValue.present
          ? data.thresholdValue.value
          : this.thresholdValue,
      severity: data.severity.present ? data.severity.value : this.severity,
      triggeredTime: data.triggeredTime.present
          ? data.triggeredTime.value
          : this.triggeredTime,
      acknowledged: data.acknowledged.present
          ? data.acknowledged.value
          : this.acknowledged,
      mutedUntil: data.mutedUntil.present
          ? data.mutedUntil.value
          : this.mutedUntil,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ActiveAlert(')
          ..write('id: $id, ')
          ..write('ruleId: $ruleId, ')
          ..write('serverId: $serverId, ')
          ..write('metricName: $metricName, ')
          ..write('currentValue: $currentValue, ')
          ..write('thresholdValue: $thresholdValue, ')
          ..write('severity: $severity, ')
          ..write('triggeredTime: $triggeredTime, ')
          ..write('acknowledged: $acknowledged, ')
          ..write('mutedUntil: $mutedUntil')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    ruleId,
    serverId,
    metricName,
    currentValue,
    thresholdValue,
    severity,
    triggeredTime,
    acknowledged,
    mutedUntil,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ActiveAlert &&
          other.id == this.id &&
          other.ruleId == this.ruleId &&
          other.serverId == this.serverId &&
          other.metricName == this.metricName &&
          other.currentValue == this.currentValue &&
          other.thresholdValue == this.thresholdValue &&
          other.severity == this.severity &&
          other.triggeredTime == this.triggeredTime &&
          other.acknowledged == this.acknowledged &&
          other.mutedUntil == this.mutedUntil);
}

class ActiveAlertsCompanion extends UpdateCompanion<ActiveAlert> {
  final Value<int> id;
  final Value<int> ruleId;
  final Value<int> serverId;
  final Value<String> metricName;
  final Value<double> currentValue;
  final Value<double> thresholdValue;
  final Value<String> severity;
  final Value<int> triggeredTime;
  final Value<bool> acknowledged;
  final Value<int> mutedUntil;
  const ActiveAlertsCompanion({
    this.id = const Value.absent(),
    this.ruleId = const Value.absent(),
    this.serverId = const Value.absent(),
    this.metricName = const Value.absent(),
    this.currentValue = const Value.absent(),
    this.thresholdValue = const Value.absent(),
    this.severity = const Value.absent(),
    this.triggeredTime = const Value.absent(),
    this.acknowledged = const Value.absent(),
    this.mutedUntil = const Value.absent(),
  });
  ActiveAlertsCompanion.insert({
    this.id = const Value.absent(),
    required int ruleId,
    required int serverId,
    required String metricName,
    required double currentValue,
    required double thresholdValue,
    required String severity,
    required int triggeredTime,
    this.acknowledged = const Value.absent(),
    this.mutedUntil = const Value.absent(),
  }) : ruleId = Value(ruleId),
       serverId = Value(serverId),
       metricName = Value(metricName),
       currentValue = Value(currentValue),
       thresholdValue = Value(thresholdValue),
       severity = Value(severity),
       triggeredTime = Value(triggeredTime);
  static Insertable<ActiveAlert> custom({
    Expression<int>? id,
    Expression<int>? ruleId,
    Expression<int>? serverId,
    Expression<String>? metricName,
    Expression<double>? currentValue,
    Expression<double>? thresholdValue,
    Expression<String>? severity,
    Expression<int>? triggeredTime,
    Expression<bool>? acknowledged,
    Expression<int>? mutedUntil,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (ruleId != null) 'ruleId': ruleId,
      if (serverId != null) 'serverId': serverId,
      if (metricName != null) 'metricName': metricName,
      if (currentValue != null) 'currentValue': currentValue,
      if (thresholdValue != null) 'thresholdValue': thresholdValue,
      if (severity != null) 'severity': severity,
      if (triggeredTime != null) 'triggeredTime': triggeredTime,
      if (acknowledged != null) 'acknowledged': acknowledged,
      if (mutedUntil != null) 'mutedUntil': mutedUntil,
    });
  }

  ActiveAlertsCompanion copyWith({
    Value<int>? id,
    Value<int>? ruleId,
    Value<int>? serverId,
    Value<String>? metricName,
    Value<double>? currentValue,
    Value<double>? thresholdValue,
    Value<String>? severity,
    Value<int>? triggeredTime,
    Value<bool>? acknowledged,
    Value<int>? mutedUntil,
  }) {
    return ActiveAlertsCompanion(
      id: id ?? this.id,
      ruleId: ruleId ?? this.ruleId,
      serverId: serverId ?? this.serverId,
      metricName: metricName ?? this.metricName,
      currentValue: currentValue ?? this.currentValue,
      thresholdValue: thresholdValue ?? this.thresholdValue,
      severity: severity ?? this.severity,
      triggeredTime: triggeredTime ?? this.triggeredTime,
      acknowledged: acknowledged ?? this.acknowledged,
      mutedUntil: mutedUntil ?? this.mutedUntil,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (ruleId.present) {
      map['ruleId'] = Variable<int>(ruleId.value);
    }
    if (serverId.present) {
      map['serverId'] = Variable<int>(serverId.value);
    }
    if (metricName.present) {
      map['metricName'] = Variable<String>(metricName.value);
    }
    if (currentValue.present) {
      map['currentValue'] = Variable<double>(currentValue.value);
    }
    if (thresholdValue.present) {
      map['thresholdValue'] = Variable<double>(thresholdValue.value);
    }
    if (severity.present) {
      map['severity'] = Variable<String>(severity.value);
    }
    if (triggeredTime.present) {
      map['triggeredTime'] = Variable<int>(triggeredTime.value);
    }
    if (acknowledged.present) {
      map['acknowledged'] = Variable<bool>(acknowledged.value);
    }
    if (mutedUntil.present) {
      map['mutedUntil'] = Variable<int>(mutedUntil.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ActiveAlertsCompanion(')
          ..write('id: $id, ')
          ..write('ruleId: $ruleId, ')
          ..write('serverId: $serverId, ')
          ..write('metricName: $metricName, ')
          ..write('currentValue: $currentValue, ')
          ..write('thresholdValue: $thresholdValue, ')
          ..write('severity: $severity, ')
          ..write('triggeredTime: $triggeredTime, ')
          ..write('acknowledged: $acknowledged, ')
          ..write('mutedUntil: $mutedUntil')
          ..write(')'))
        .toString();
  }
}

class $AlertHistoryTable extends AlertHistory
    with TableInfo<$AlertHistoryTable, AlertHistoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AlertHistoryTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _activeAlertIdMeta = const VerificationMeta(
    'activeAlertId',
  );
  @override
  late final GeneratedColumn<int> activeAlertId = GeneratedColumn<int>(
    'activeAlertId',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<int> serverId = GeneratedColumn<int>(
    'serverId',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverNameMeta = const VerificationMeta(
    'serverName',
  );
  @override
  late final GeneratedColumn<String> serverName = GeneratedColumn<String>(
    'serverName',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _metricNameMeta = const VerificationMeta(
    'metricName',
  );
  @override
  late final GeneratedColumn<String> metricName = GeneratedColumn<String>(
    'metricName',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _currentValueMeta = const VerificationMeta(
    'currentValue',
  );
  @override
  late final GeneratedColumn<double> currentValue = GeneratedColumn<double>(
    'currentValue',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _thresholdValueMeta = const VerificationMeta(
    'thresholdValue',
  );
  @override
  late final GeneratedColumn<double> thresholdValue = GeneratedColumn<double>(
    'thresholdValue',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _severityMeta = const VerificationMeta(
    'severity',
  );
  @override
  late final GeneratedColumn<String> severity = GeneratedColumn<String>(
    'severity',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _triggeredTimeMeta = const VerificationMeta(
    'triggeredTime',
  );
  @override
  late final GeneratedColumn<int> triggeredTime = GeneratedColumn<int>(
    'triggeredTime',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _historyTimeMeta = const VerificationMeta(
    'historyTime',
  );
  @override
  late final GeneratedColumn<int> historyTime = GeneratedColumn<int>(
    'historyTime',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    activeAlertId,
    serverId,
    serverName,
    metricName,
    currentValue,
    thresholdValue,
    severity,
    triggeredTime,
    historyTime,
    status,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'alert_history';
  @override
  VerificationContext validateIntegrity(
    Insertable<AlertHistoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('activeAlertId')) {
      context.handle(
        _activeAlertIdMeta,
        activeAlertId.isAcceptableOrUnknown(
          data['activeAlertId']!,
          _activeAlertIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_activeAlertIdMeta);
    }
    if (data.containsKey('serverId')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['serverId']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('serverName')) {
      context.handle(
        _serverNameMeta,
        serverName.isAcceptableOrUnknown(data['serverName']!, _serverNameMeta),
      );
    } else if (isInserting) {
      context.missing(_serverNameMeta);
    }
    if (data.containsKey('metricName')) {
      context.handle(
        _metricNameMeta,
        metricName.isAcceptableOrUnknown(data['metricName']!, _metricNameMeta),
      );
    } else if (isInserting) {
      context.missing(_metricNameMeta);
    }
    if (data.containsKey('currentValue')) {
      context.handle(
        _currentValueMeta,
        currentValue.isAcceptableOrUnknown(
          data['currentValue']!,
          _currentValueMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_currentValueMeta);
    }
    if (data.containsKey('thresholdValue')) {
      context.handle(
        _thresholdValueMeta,
        thresholdValue.isAcceptableOrUnknown(
          data['thresholdValue']!,
          _thresholdValueMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_thresholdValueMeta);
    }
    if (data.containsKey('severity')) {
      context.handle(
        _severityMeta,
        severity.isAcceptableOrUnknown(data['severity']!, _severityMeta),
      );
    } else if (isInserting) {
      context.missing(_severityMeta);
    }
    if (data.containsKey('triggeredTime')) {
      context.handle(
        _triggeredTimeMeta,
        triggeredTime.isAcceptableOrUnknown(
          data['triggeredTime']!,
          _triggeredTimeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_triggeredTimeMeta);
    }
    if (data.containsKey('historyTime')) {
      context.handle(
        _historyTimeMeta,
        historyTime.isAcceptableOrUnknown(
          data['historyTime']!,
          _historyTimeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_historyTimeMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AlertHistoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AlertHistoryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      activeAlertId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}activeAlertId'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}serverId'],
      )!,
      serverName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}serverName'],
      )!,
      metricName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metricName'],
      )!,
      currentValue: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}currentValue'],
      )!,
      thresholdValue: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}thresholdValue'],
      )!,
      severity: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}severity'],
      )!,
      triggeredTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}triggeredTime'],
      )!,
      historyTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}historyTime'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
    );
  }

  @override
  $AlertHistoryTable createAlias(String alias) {
    return $AlertHistoryTable(attachedDatabase, alias);
  }
}

class AlertHistoryRow extends DataClass implements Insertable<AlertHistoryRow> {
  final int id;
  final int activeAlertId;
  final int serverId;
  final String serverName;
  final String metricName;
  final double currentValue;
  final double thresholdValue;
  final String severity;
  final int triggeredTime;
  final int historyTime;
  final String status;
  const AlertHistoryRow({
    required this.id,
    required this.activeAlertId,
    required this.serverId,
    required this.serverName,
    required this.metricName,
    required this.currentValue,
    required this.thresholdValue,
    required this.severity,
    required this.triggeredTime,
    required this.historyTime,
    required this.status,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['activeAlertId'] = Variable<int>(activeAlertId);
    map['serverId'] = Variable<int>(serverId);
    map['serverName'] = Variable<String>(serverName);
    map['metricName'] = Variable<String>(metricName);
    map['currentValue'] = Variable<double>(currentValue);
    map['thresholdValue'] = Variable<double>(thresholdValue);
    map['severity'] = Variable<String>(severity);
    map['triggeredTime'] = Variable<int>(triggeredTime);
    map['historyTime'] = Variable<int>(historyTime);
    map['status'] = Variable<String>(status);
    return map;
  }

  AlertHistoryCompanion toCompanion(bool nullToAbsent) {
    return AlertHistoryCompanion(
      id: Value(id),
      activeAlertId: Value(activeAlertId),
      serverId: Value(serverId),
      serverName: Value(serverName),
      metricName: Value(metricName),
      currentValue: Value(currentValue),
      thresholdValue: Value(thresholdValue),
      severity: Value(severity),
      triggeredTime: Value(triggeredTime),
      historyTime: Value(historyTime),
      status: Value(status),
    );
  }

  factory AlertHistoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AlertHistoryRow(
      id: serializer.fromJson<int>(json['id']),
      activeAlertId: serializer.fromJson<int>(json['activeAlertId']),
      serverId: serializer.fromJson<int>(json['serverId']),
      serverName: serializer.fromJson<String>(json['serverName']),
      metricName: serializer.fromJson<String>(json['metricName']),
      currentValue: serializer.fromJson<double>(json['currentValue']),
      thresholdValue: serializer.fromJson<double>(json['thresholdValue']),
      severity: serializer.fromJson<String>(json['severity']),
      triggeredTime: serializer.fromJson<int>(json['triggeredTime']),
      historyTime: serializer.fromJson<int>(json['historyTime']),
      status: serializer.fromJson<String>(json['status']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'activeAlertId': serializer.toJson<int>(activeAlertId),
      'serverId': serializer.toJson<int>(serverId),
      'serverName': serializer.toJson<String>(serverName),
      'metricName': serializer.toJson<String>(metricName),
      'currentValue': serializer.toJson<double>(currentValue),
      'thresholdValue': serializer.toJson<double>(thresholdValue),
      'severity': serializer.toJson<String>(severity),
      'triggeredTime': serializer.toJson<int>(triggeredTime),
      'historyTime': serializer.toJson<int>(historyTime),
      'status': serializer.toJson<String>(status),
    };
  }

  AlertHistoryRow copyWith({
    int? id,
    int? activeAlertId,
    int? serverId,
    String? serverName,
    String? metricName,
    double? currentValue,
    double? thresholdValue,
    String? severity,
    int? triggeredTime,
    int? historyTime,
    String? status,
  }) => AlertHistoryRow(
    id: id ?? this.id,
    activeAlertId: activeAlertId ?? this.activeAlertId,
    serverId: serverId ?? this.serverId,
    serverName: serverName ?? this.serverName,
    metricName: metricName ?? this.metricName,
    currentValue: currentValue ?? this.currentValue,
    thresholdValue: thresholdValue ?? this.thresholdValue,
    severity: severity ?? this.severity,
    triggeredTime: triggeredTime ?? this.triggeredTime,
    historyTime: historyTime ?? this.historyTime,
    status: status ?? this.status,
  );
  AlertHistoryRow copyWithCompanion(AlertHistoryCompanion data) {
    return AlertHistoryRow(
      id: data.id.present ? data.id.value : this.id,
      activeAlertId: data.activeAlertId.present
          ? data.activeAlertId.value
          : this.activeAlertId,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      serverName: data.serverName.present
          ? data.serverName.value
          : this.serverName,
      metricName: data.metricName.present
          ? data.metricName.value
          : this.metricName,
      currentValue: data.currentValue.present
          ? data.currentValue.value
          : this.currentValue,
      thresholdValue: data.thresholdValue.present
          ? data.thresholdValue.value
          : this.thresholdValue,
      severity: data.severity.present ? data.severity.value : this.severity,
      triggeredTime: data.triggeredTime.present
          ? data.triggeredTime.value
          : this.triggeredTime,
      historyTime: data.historyTime.present
          ? data.historyTime.value
          : this.historyTime,
      status: data.status.present ? data.status.value : this.status,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AlertHistoryRow(')
          ..write('id: $id, ')
          ..write('activeAlertId: $activeAlertId, ')
          ..write('serverId: $serverId, ')
          ..write('serverName: $serverName, ')
          ..write('metricName: $metricName, ')
          ..write('currentValue: $currentValue, ')
          ..write('thresholdValue: $thresholdValue, ')
          ..write('severity: $severity, ')
          ..write('triggeredTime: $triggeredTime, ')
          ..write('historyTime: $historyTime, ')
          ..write('status: $status')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    activeAlertId,
    serverId,
    serverName,
    metricName,
    currentValue,
    thresholdValue,
    severity,
    triggeredTime,
    historyTime,
    status,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AlertHistoryRow &&
          other.id == this.id &&
          other.activeAlertId == this.activeAlertId &&
          other.serverId == this.serverId &&
          other.serverName == this.serverName &&
          other.metricName == this.metricName &&
          other.currentValue == this.currentValue &&
          other.thresholdValue == this.thresholdValue &&
          other.severity == this.severity &&
          other.triggeredTime == this.triggeredTime &&
          other.historyTime == this.historyTime &&
          other.status == this.status);
}

class AlertHistoryCompanion extends UpdateCompanion<AlertHistoryRow> {
  final Value<int> id;
  final Value<int> activeAlertId;
  final Value<int> serverId;
  final Value<String> serverName;
  final Value<String> metricName;
  final Value<double> currentValue;
  final Value<double> thresholdValue;
  final Value<String> severity;
  final Value<int> triggeredTime;
  final Value<int> historyTime;
  final Value<String> status;
  const AlertHistoryCompanion({
    this.id = const Value.absent(),
    this.activeAlertId = const Value.absent(),
    this.serverId = const Value.absent(),
    this.serverName = const Value.absent(),
    this.metricName = const Value.absent(),
    this.currentValue = const Value.absent(),
    this.thresholdValue = const Value.absent(),
    this.severity = const Value.absent(),
    this.triggeredTime = const Value.absent(),
    this.historyTime = const Value.absent(),
    this.status = const Value.absent(),
  });
  AlertHistoryCompanion.insert({
    this.id = const Value.absent(),
    required int activeAlertId,
    required int serverId,
    required String serverName,
    required String metricName,
    required double currentValue,
    required double thresholdValue,
    required String severity,
    required int triggeredTime,
    required int historyTime,
    required String status,
  }) : activeAlertId = Value(activeAlertId),
       serverId = Value(serverId),
       serverName = Value(serverName),
       metricName = Value(metricName),
       currentValue = Value(currentValue),
       thresholdValue = Value(thresholdValue),
       severity = Value(severity),
       triggeredTime = Value(triggeredTime),
       historyTime = Value(historyTime),
       status = Value(status);
  static Insertable<AlertHistoryRow> custom({
    Expression<int>? id,
    Expression<int>? activeAlertId,
    Expression<int>? serverId,
    Expression<String>? serverName,
    Expression<String>? metricName,
    Expression<double>? currentValue,
    Expression<double>? thresholdValue,
    Expression<String>? severity,
    Expression<int>? triggeredTime,
    Expression<int>? historyTime,
    Expression<String>? status,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (activeAlertId != null) 'activeAlertId': activeAlertId,
      if (serverId != null) 'serverId': serverId,
      if (serverName != null) 'serverName': serverName,
      if (metricName != null) 'metricName': metricName,
      if (currentValue != null) 'currentValue': currentValue,
      if (thresholdValue != null) 'thresholdValue': thresholdValue,
      if (severity != null) 'severity': severity,
      if (triggeredTime != null) 'triggeredTime': triggeredTime,
      if (historyTime != null) 'historyTime': historyTime,
      if (status != null) 'status': status,
    });
  }

  AlertHistoryCompanion copyWith({
    Value<int>? id,
    Value<int>? activeAlertId,
    Value<int>? serverId,
    Value<String>? serverName,
    Value<String>? metricName,
    Value<double>? currentValue,
    Value<double>? thresholdValue,
    Value<String>? severity,
    Value<int>? triggeredTime,
    Value<int>? historyTime,
    Value<String>? status,
  }) {
    return AlertHistoryCompanion(
      id: id ?? this.id,
      activeAlertId: activeAlertId ?? this.activeAlertId,
      serverId: serverId ?? this.serverId,
      serverName: serverName ?? this.serverName,
      metricName: metricName ?? this.metricName,
      currentValue: currentValue ?? this.currentValue,
      thresholdValue: thresholdValue ?? this.thresholdValue,
      severity: severity ?? this.severity,
      triggeredTime: triggeredTime ?? this.triggeredTime,
      historyTime: historyTime ?? this.historyTime,
      status: status ?? this.status,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (activeAlertId.present) {
      map['activeAlertId'] = Variable<int>(activeAlertId.value);
    }
    if (serverId.present) {
      map['serverId'] = Variable<int>(serverId.value);
    }
    if (serverName.present) {
      map['serverName'] = Variable<String>(serverName.value);
    }
    if (metricName.present) {
      map['metricName'] = Variable<String>(metricName.value);
    }
    if (currentValue.present) {
      map['currentValue'] = Variable<double>(currentValue.value);
    }
    if (thresholdValue.present) {
      map['thresholdValue'] = Variable<double>(thresholdValue.value);
    }
    if (severity.present) {
      map['severity'] = Variable<String>(severity.value);
    }
    if (triggeredTime.present) {
      map['triggeredTime'] = Variable<int>(triggeredTime.value);
    }
    if (historyTime.present) {
      map['historyTime'] = Variable<int>(historyTime.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AlertHistoryCompanion(')
          ..write('id: $id, ')
          ..write('activeAlertId: $activeAlertId, ')
          ..write('serverId: $serverId, ')
          ..write('serverName: $serverName, ')
          ..write('metricName: $metricName, ')
          ..write('currentValue: $currentValue, ')
          ..write('thresholdValue: $thresholdValue, ')
          ..write('severity: $severity, ')
          ..write('triggeredTime: $triggeredTime, ')
          ..write('historyTime: $historyTime, ')
          ..write('status: $status')
          ..write(')'))
        .toString();
  }
}

class $QuickScriptsTable extends QuickScripts
    with TableInfo<$QuickScriptsTable, QuickScript> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $QuickScriptsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _emojiMeta = const VerificationMeta('emoji');
  @override
  late final GeneratedColumn<String> emoji = GeneratedColumn<String>(
    'emoji',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _commandMeta = const VerificationMeta(
    'command',
  );
  @override
  late final GeneratedColumn<String> command = GeneratedColumn<String>(
    'command',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<String> color = GeneratedColumn<String>(
    'color',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _longRunningMeta = const VerificationMeta(
    'longRunning',
  );
  @override
  late final GeneratedColumn<bool> longRunning = GeneratedColumn<bool>(
    'longRunning',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("longRunning" IN (0, 1))',
    ),
    clientDefault: () => false,
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'General',
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sortOrder',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 0,
  );
  static const VerificationMeta _availableForQuickMeta = const VerificationMeta(
    'availableForQuick',
  );
  @override
  late final GeneratedColumn<bool> availableForQuick = GeneratedColumn<bool>(
    'availableForQuick',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("availableForQuick" IN (0, 1))',
    ),
    clientDefault: () => true,
  );
  static const VerificationMeta _availableForFleetMeta = const VerificationMeta(
    'availableForFleet',
  );
  @override
  late final GeneratedColumn<bool> availableForFleet = GeneratedColumn<bool>(
    'availableForFleet',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("availableForFleet" IN (0, 1))',
    ),
    clientDefault: () => false,
  );
  static const VerificationMeta _targetOsMeta = const VerificationMeta(
    'targetOs',
  );
  @override
  late final GeneratedColumn<String> targetOs = GeneratedColumn<String>(
    'targetOs',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'Any',
  );
  static const VerificationMeta _targetSystemMeta = const VerificationMeta(
    'targetSystem',
  );
  @override
  late final GeneratedColumn<String> targetSystem = GeneratedColumn<String>(
    'targetSystem',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'Any',
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _presetKeyMeta = const VerificationMeta(
    'presetKey',
  );
  @override
  late final GeneratedColumn<String> presetKey = GeneratedColumn<String>(
    'presetKey',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    emoji,
    name,
    command,
    color,
    longRunning,
    category,
    sortOrder,
    availableForQuick,
    availableForFleet,
    targetOs,
    targetSystem,
    notes,
    presetKey,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'quick_scripts';
  @override
  VerificationContext validateIntegrity(
    Insertable<QuickScript> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('emoji')) {
      context.handle(
        _emojiMeta,
        emoji.isAcceptableOrUnknown(data['emoji']!, _emojiMeta),
      );
    } else if (isInserting) {
      context.missing(_emojiMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('command')) {
      context.handle(
        _commandMeta,
        command.isAcceptableOrUnknown(data['command']!, _commandMeta),
      );
    } else if (isInserting) {
      context.missing(_commandMeta);
    }
    if (data.containsKey('color')) {
      context.handle(
        _colorMeta,
        color.isAcceptableOrUnknown(data['color']!, _colorMeta),
      );
    } else if (isInserting) {
      context.missing(_colorMeta);
    }
    if (data.containsKey('longRunning')) {
      context.handle(
        _longRunningMeta,
        longRunning.isAcceptableOrUnknown(
          data['longRunning']!,
          _longRunningMeta,
        ),
      );
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    }
    if (data.containsKey('sortOrder')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sortOrder']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('availableForQuick')) {
      context.handle(
        _availableForQuickMeta,
        availableForQuick.isAcceptableOrUnknown(
          data['availableForQuick']!,
          _availableForQuickMeta,
        ),
      );
    }
    if (data.containsKey('availableForFleet')) {
      context.handle(
        _availableForFleetMeta,
        availableForFleet.isAcceptableOrUnknown(
          data['availableForFleet']!,
          _availableForFleetMeta,
        ),
      );
    }
    if (data.containsKey('targetOs')) {
      context.handle(
        _targetOsMeta,
        targetOs.isAcceptableOrUnknown(data['targetOs']!, _targetOsMeta),
      );
    }
    if (data.containsKey('targetSystem')) {
      context.handle(
        _targetSystemMeta,
        targetSystem.isAcceptableOrUnknown(
          data['targetSystem']!,
          _targetSystemMeta,
        ),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('presetKey')) {
      context.handle(
        _presetKeyMeta,
        presetKey.isAcceptableOrUnknown(data['presetKey']!, _presetKeyMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  QuickScript map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return QuickScript(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      emoji: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}emoji'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      command: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}command'],
      )!,
      color: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}color'],
      )!,
      longRunning: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}longRunning'],
      )!,
      category: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}category'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sortOrder'],
      )!,
      availableForQuick: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}availableForQuick'],
      )!,
      availableForFleet: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}availableForFleet'],
      )!,
      targetOs: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}targetOs'],
      )!,
      targetSystem: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}targetSystem'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      )!,
      presetKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}presetKey'],
      ),
    );
  }

  @override
  $QuickScriptsTable createAlias(String alias) {
    return $QuickScriptsTable(attachedDatabase, alias);
  }
}

class QuickScript extends DataClass implements Insertable<QuickScript> {
  final int id;
  final String emoji;
  final String name;
  final String command;

  /// e.g. "cyan", "green", "amber", "red", "purple", "orange".
  final String color;
  final bool longRunning;
  final String category;
  final int sortOrder;
  final bool availableForQuick;
  final bool availableForFleet;
  final String targetOs;
  final String targetSystem;

  /// Free-text note documenting what this script does / caveats.
  final String notes;

  /// Stable identity of the built-in preset this row was seeded from (e.g. "fleet.cpu"), or null
  /// for user-created scripts. Survives edits to the name/command, so the preset toggles can
  /// delete exactly what they seeded instead of matching on mutable content.
  final String? presetKey;
  const QuickScript({
    required this.id,
    required this.emoji,
    required this.name,
    required this.command,
    required this.color,
    required this.longRunning,
    required this.category,
    required this.sortOrder,
    required this.availableForQuick,
    required this.availableForFleet,
    required this.targetOs,
    required this.targetSystem,
    required this.notes,
    this.presetKey,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['emoji'] = Variable<String>(emoji);
    map['name'] = Variable<String>(name);
    map['command'] = Variable<String>(command);
    map['color'] = Variable<String>(color);
    map['longRunning'] = Variable<bool>(longRunning);
    map['category'] = Variable<String>(category);
    map['sortOrder'] = Variable<int>(sortOrder);
    map['availableForQuick'] = Variable<bool>(availableForQuick);
    map['availableForFleet'] = Variable<bool>(availableForFleet);
    map['targetOs'] = Variable<String>(targetOs);
    map['targetSystem'] = Variable<String>(targetSystem);
    map['notes'] = Variable<String>(notes);
    if (!nullToAbsent || presetKey != null) {
      map['presetKey'] = Variable<String>(presetKey);
    }
    return map;
  }

  QuickScriptsCompanion toCompanion(bool nullToAbsent) {
    return QuickScriptsCompanion(
      id: Value(id),
      emoji: Value(emoji),
      name: Value(name),
      command: Value(command),
      color: Value(color),
      longRunning: Value(longRunning),
      category: Value(category),
      sortOrder: Value(sortOrder),
      availableForQuick: Value(availableForQuick),
      availableForFleet: Value(availableForFleet),
      targetOs: Value(targetOs),
      targetSystem: Value(targetSystem),
      notes: Value(notes),
      presetKey: presetKey == null && nullToAbsent
          ? const Value.absent()
          : Value(presetKey),
    );
  }

  factory QuickScript.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return QuickScript(
      id: serializer.fromJson<int>(json['id']),
      emoji: serializer.fromJson<String>(json['emoji']),
      name: serializer.fromJson<String>(json['name']),
      command: serializer.fromJson<String>(json['command']),
      color: serializer.fromJson<String>(json['color']),
      longRunning: serializer.fromJson<bool>(json['longRunning']),
      category: serializer.fromJson<String>(json['category']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      availableForQuick: serializer.fromJson<bool>(json['availableForQuick']),
      availableForFleet: serializer.fromJson<bool>(json['availableForFleet']),
      targetOs: serializer.fromJson<String>(json['targetOs']),
      targetSystem: serializer.fromJson<String>(json['targetSystem']),
      notes: serializer.fromJson<String>(json['notes']),
      presetKey: serializer.fromJson<String?>(json['presetKey']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'emoji': serializer.toJson<String>(emoji),
      'name': serializer.toJson<String>(name),
      'command': serializer.toJson<String>(command),
      'color': serializer.toJson<String>(color),
      'longRunning': serializer.toJson<bool>(longRunning),
      'category': serializer.toJson<String>(category),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'availableForQuick': serializer.toJson<bool>(availableForQuick),
      'availableForFleet': serializer.toJson<bool>(availableForFleet),
      'targetOs': serializer.toJson<String>(targetOs),
      'targetSystem': serializer.toJson<String>(targetSystem),
      'notes': serializer.toJson<String>(notes),
      'presetKey': serializer.toJson<String?>(presetKey),
    };
  }

  QuickScript copyWith({
    int? id,
    String? emoji,
    String? name,
    String? command,
    String? color,
    bool? longRunning,
    String? category,
    int? sortOrder,
    bool? availableForQuick,
    bool? availableForFleet,
    String? targetOs,
    String? targetSystem,
    String? notes,
    Value<String?> presetKey = const Value.absent(),
  }) => QuickScript(
    id: id ?? this.id,
    emoji: emoji ?? this.emoji,
    name: name ?? this.name,
    command: command ?? this.command,
    color: color ?? this.color,
    longRunning: longRunning ?? this.longRunning,
    category: category ?? this.category,
    sortOrder: sortOrder ?? this.sortOrder,
    availableForQuick: availableForQuick ?? this.availableForQuick,
    availableForFleet: availableForFleet ?? this.availableForFleet,
    targetOs: targetOs ?? this.targetOs,
    targetSystem: targetSystem ?? this.targetSystem,
    notes: notes ?? this.notes,
    presetKey: presetKey.present ? presetKey.value : this.presetKey,
  );
  QuickScript copyWithCompanion(QuickScriptsCompanion data) {
    return QuickScript(
      id: data.id.present ? data.id.value : this.id,
      emoji: data.emoji.present ? data.emoji.value : this.emoji,
      name: data.name.present ? data.name.value : this.name,
      command: data.command.present ? data.command.value : this.command,
      color: data.color.present ? data.color.value : this.color,
      longRunning: data.longRunning.present
          ? data.longRunning.value
          : this.longRunning,
      category: data.category.present ? data.category.value : this.category,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      availableForQuick: data.availableForQuick.present
          ? data.availableForQuick.value
          : this.availableForQuick,
      availableForFleet: data.availableForFleet.present
          ? data.availableForFleet.value
          : this.availableForFleet,
      targetOs: data.targetOs.present ? data.targetOs.value : this.targetOs,
      targetSystem: data.targetSystem.present
          ? data.targetSystem.value
          : this.targetSystem,
      notes: data.notes.present ? data.notes.value : this.notes,
      presetKey: data.presetKey.present ? data.presetKey.value : this.presetKey,
    );
  }

  @override
  String toString() {
    return (StringBuffer('QuickScript(')
          ..write('id: $id, ')
          ..write('emoji: $emoji, ')
          ..write('name: $name, ')
          ..write('command: $command, ')
          ..write('color: $color, ')
          ..write('longRunning: $longRunning, ')
          ..write('category: $category, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('availableForQuick: $availableForQuick, ')
          ..write('availableForFleet: $availableForFleet, ')
          ..write('targetOs: $targetOs, ')
          ..write('targetSystem: $targetSystem, ')
          ..write('notes: $notes, ')
          ..write('presetKey: $presetKey')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    emoji,
    name,
    command,
    color,
    longRunning,
    category,
    sortOrder,
    availableForQuick,
    availableForFleet,
    targetOs,
    targetSystem,
    notes,
    presetKey,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is QuickScript &&
          other.id == this.id &&
          other.emoji == this.emoji &&
          other.name == this.name &&
          other.command == this.command &&
          other.color == this.color &&
          other.longRunning == this.longRunning &&
          other.category == this.category &&
          other.sortOrder == this.sortOrder &&
          other.availableForQuick == this.availableForQuick &&
          other.availableForFleet == this.availableForFleet &&
          other.targetOs == this.targetOs &&
          other.targetSystem == this.targetSystem &&
          other.notes == this.notes &&
          other.presetKey == this.presetKey);
}

class QuickScriptsCompanion extends UpdateCompanion<QuickScript> {
  final Value<int> id;
  final Value<String> emoji;
  final Value<String> name;
  final Value<String> command;
  final Value<String> color;
  final Value<bool> longRunning;
  final Value<String> category;
  final Value<int> sortOrder;
  final Value<bool> availableForQuick;
  final Value<bool> availableForFleet;
  final Value<String> targetOs;
  final Value<String> targetSystem;
  final Value<String> notes;
  final Value<String?> presetKey;
  const QuickScriptsCompanion({
    this.id = const Value.absent(),
    this.emoji = const Value.absent(),
    this.name = const Value.absent(),
    this.command = const Value.absent(),
    this.color = const Value.absent(),
    this.longRunning = const Value.absent(),
    this.category = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.availableForQuick = const Value.absent(),
    this.availableForFleet = const Value.absent(),
    this.targetOs = const Value.absent(),
    this.targetSystem = const Value.absent(),
    this.notes = const Value.absent(),
    this.presetKey = const Value.absent(),
  });
  QuickScriptsCompanion.insert({
    this.id = const Value.absent(),
    required String emoji,
    required String name,
    required String command,
    required String color,
    this.longRunning = const Value.absent(),
    this.category = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.availableForQuick = const Value.absent(),
    this.availableForFleet = const Value.absent(),
    this.targetOs = const Value.absent(),
    this.targetSystem = const Value.absent(),
    this.notes = const Value.absent(),
    this.presetKey = const Value.absent(),
  }) : emoji = Value(emoji),
       name = Value(name),
       command = Value(command),
       color = Value(color);
  static Insertable<QuickScript> custom({
    Expression<int>? id,
    Expression<String>? emoji,
    Expression<String>? name,
    Expression<String>? command,
    Expression<String>? color,
    Expression<bool>? longRunning,
    Expression<String>? category,
    Expression<int>? sortOrder,
    Expression<bool>? availableForQuick,
    Expression<bool>? availableForFleet,
    Expression<String>? targetOs,
    Expression<String>? targetSystem,
    Expression<String>? notes,
    Expression<String>? presetKey,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (emoji != null) 'emoji': emoji,
      if (name != null) 'name': name,
      if (command != null) 'command': command,
      if (color != null) 'color': color,
      if (longRunning != null) 'longRunning': longRunning,
      if (category != null) 'category': category,
      if (sortOrder != null) 'sortOrder': sortOrder,
      if (availableForQuick != null) 'availableForQuick': availableForQuick,
      if (availableForFleet != null) 'availableForFleet': availableForFleet,
      if (targetOs != null) 'targetOs': targetOs,
      if (targetSystem != null) 'targetSystem': targetSystem,
      if (notes != null) 'notes': notes,
      if (presetKey != null) 'presetKey': presetKey,
    });
  }

  QuickScriptsCompanion copyWith({
    Value<int>? id,
    Value<String>? emoji,
    Value<String>? name,
    Value<String>? command,
    Value<String>? color,
    Value<bool>? longRunning,
    Value<String>? category,
    Value<int>? sortOrder,
    Value<bool>? availableForQuick,
    Value<bool>? availableForFleet,
    Value<String>? targetOs,
    Value<String>? targetSystem,
    Value<String>? notes,
    Value<String?>? presetKey,
  }) {
    return QuickScriptsCompanion(
      id: id ?? this.id,
      emoji: emoji ?? this.emoji,
      name: name ?? this.name,
      command: command ?? this.command,
      color: color ?? this.color,
      longRunning: longRunning ?? this.longRunning,
      category: category ?? this.category,
      sortOrder: sortOrder ?? this.sortOrder,
      availableForQuick: availableForQuick ?? this.availableForQuick,
      availableForFleet: availableForFleet ?? this.availableForFleet,
      targetOs: targetOs ?? this.targetOs,
      targetSystem: targetSystem ?? this.targetSystem,
      notes: notes ?? this.notes,
      presetKey: presetKey ?? this.presetKey,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (emoji.present) {
      map['emoji'] = Variable<String>(emoji.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (command.present) {
      map['command'] = Variable<String>(command.value);
    }
    if (color.present) {
      map['color'] = Variable<String>(color.value);
    }
    if (longRunning.present) {
      map['longRunning'] = Variable<bool>(longRunning.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (sortOrder.present) {
      map['sortOrder'] = Variable<int>(sortOrder.value);
    }
    if (availableForQuick.present) {
      map['availableForQuick'] = Variable<bool>(availableForQuick.value);
    }
    if (availableForFleet.present) {
      map['availableForFleet'] = Variable<bool>(availableForFleet.value);
    }
    if (targetOs.present) {
      map['targetOs'] = Variable<String>(targetOs.value);
    }
    if (targetSystem.present) {
      map['targetSystem'] = Variable<String>(targetSystem.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (presetKey.present) {
      map['presetKey'] = Variable<String>(presetKey.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('QuickScriptsCompanion(')
          ..write('id: $id, ')
          ..write('emoji: $emoji, ')
          ..write('name: $name, ')
          ..write('command: $command, ')
          ..write('color: $color, ')
          ..write('longRunning: $longRunning, ')
          ..write('category: $category, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('availableForQuick: $availableForQuick, ')
          ..write('availableForFleet: $availableForFleet, ')
          ..write('targetOs: $targetOs, ')
          ..write('targetSystem: $targetSystem, ')
          ..write('notes: $notes, ')
          ..write('presetKey: $presetKey')
          ..write(')'))
        .toString();
  }
}

class $WolTargetsTable extends WolTargets
    with TableInfo<$WolTargetsTable, WolTarget> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WolTargetsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _macAddressMeta = const VerificationMeta(
    'macAddress',
  );
  @override
  late final GeneratedColumn<String> macAddress = GeneratedColumn<String>(
    'macAddress',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _broadcastIpMeta = const VerificationMeta(
    'broadcastIp',
  );
  @override
  late final GeneratedColumn<String> broadcastIp = GeneratedColumn<String>(
    'broadcastIp',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '192.168.1.255',
  );
  static const VerificationMeta _ipAddressMeta = const VerificationMeta(
    'ipAddress',
  );
  @override
  late final GeneratedColumn<String> ipAddress = GeneratedColumn<String>(
    'ipAddress',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 9,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _lastWokenTimeMeta = const VerificationMeta(
    'lastWokenTime',
  );
  @override
  late final GeneratedColumn<int> lastWokenTime = GeneratedColumn<int>(
    'lastWokenTime',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 0,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    macAddress,
    broadcastIp,
    ipAddress,
    port,
    notes,
    lastWokenTime,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'wol_targets';
  @override
  VerificationContext validateIntegrity(
    Insertable<WolTarget> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('macAddress')) {
      context.handle(
        _macAddressMeta,
        macAddress.isAcceptableOrUnknown(data['macAddress']!, _macAddressMeta),
      );
    } else if (isInserting) {
      context.missing(_macAddressMeta);
    }
    if (data.containsKey('broadcastIp')) {
      context.handle(
        _broadcastIpMeta,
        broadcastIp.isAcceptableOrUnknown(
          data['broadcastIp']!,
          _broadcastIpMeta,
        ),
      );
    }
    if (data.containsKey('ipAddress')) {
      context.handle(
        _ipAddressMeta,
        ipAddress.isAcceptableOrUnknown(data['ipAddress']!, _ipAddressMeta),
      );
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('lastWokenTime')) {
      context.handle(
        _lastWokenTimeMeta,
        lastWokenTime.isAcceptableOrUnknown(
          data['lastWokenTime']!,
          _lastWokenTimeMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  WolTarget map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return WolTarget(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      macAddress: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}macAddress'],
      )!,
      broadcastIp: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}broadcastIp'],
      )!,
      ipAddress: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ipAddress'],
      )!,
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      )!,
      lastWokenTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}lastWokenTime'],
      )!,
    );
  }

  @override
  $WolTargetsTable createAlias(String alias) {
    return $WolTargetsTable(attachedDatabase, alias);
  }
}

class WolTarget extends DataClass implements Insertable<WolTarget> {
  final int id;
  final String name;
  final String macAddress;
  final String broadcastIp;

  /// The host's own IP, used to ping it for live online status on the WoL screen. Optional: empty
  /// means "no status check" (older targets created before this field existed).
  final String ipAddress;
  final int port;
  final String notes;
  final int lastWokenTime;
  const WolTarget({
    required this.id,
    required this.name,
    required this.macAddress,
    required this.broadcastIp,
    required this.ipAddress,
    required this.port,
    required this.notes,
    required this.lastWokenTime,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['macAddress'] = Variable<String>(macAddress);
    map['broadcastIp'] = Variable<String>(broadcastIp);
    map['ipAddress'] = Variable<String>(ipAddress);
    map['port'] = Variable<int>(port);
    map['notes'] = Variable<String>(notes);
    map['lastWokenTime'] = Variable<int>(lastWokenTime);
    return map;
  }

  WolTargetsCompanion toCompanion(bool nullToAbsent) {
    return WolTargetsCompanion(
      id: Value(id),
      name: Value(name),
      macAddress: Value(macAddress),
      broadcastIp: Value(broadcastIp),
      ipAddress: Value(ipAddress),
      port: Value(port),
      notes: Value(notes),
      lastWokenTime: Value(lastWokenTime),
    );
  }

  factory WolTarget.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return WolTarget(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      macAddress: serializer.fromJson<String>(json['macAddress']),
      broadcastIp: serializer.fromJson<String>(json['broadcastIp']),
      ipAddress: serializer.fromJson<String>(json['ipAddress']),
      port: serializer.fromJson<int>(json['port']),
      notes: serializer.fromJson<String>(json['notes']),
      lastWokenTime: serializer.fromJson<int>(json['lastWokenTime']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'macAddress': serializer.toJson<String>(macAddress),
      'broadcastIp': serializer.toJson<String>(broadcastIp),
      'ipAddress': serializer.toJson<String>(ipAddress),
      'port': serializer.toJson<int>(port),
      'notes': serializer.toJson<String>(notes),
      'lastWokenTime': serializer.toJson<int>(lastWokenTime),
    };
  }

  WolTarget copyWith({
    int? id,
    String? name,
    String? macAddress,
    String? broadcastIp,
    String? ipAddress,
    int? port,
    String? notes,
    int? lastWokenTime,
  }) => WolTarget(
    id: id ?? this.id,
    name: name ?? this.name,
    macAddress: macAddress ?? this.macAddress,
    broadcastIp: broadcastIp ?? this.broadcastIp,
    ipAddress: ipAddress ?? this.ipAddress,
    port: port ?? this.port,
    notes: notes ?? this.notes,
    lastWokenTime: lastWokenTime ?? this.lastWokenTime,
  );
  WolTarget copyWithCompanion(WolTargetsCompanion data) {
    return WolTarget(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      macAddress: data.macAddress.present
          ? data.macAddress.value
          : this.macAddress,
      broadcastIp: data.broadcastIp.present
          ? data.broadcastIp.value
          : this.broadcastIp,
      ipAddress: data.ipAddress.present ? data.ipAddress.value : this.ipAddress,
      port: data.port.present ? data.port.value : this.port,
      notes: data.notes.present ? data.notes.value : this.notes,
      lastWokenTime: data.lastWokenTime.present
          ? data.lastWokenTime.value
          : this.lastWokenTime,
    );
  }

  @override
  String toString() {
    return (StringBuffer('WolTarget(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('macAddress: $macAddress, ')
          ..write('broadcastIp: $broadcastIp, ')
          ..write('ipAddress: $ipAddress, ')
          ..write('port: $port, ')
          ..write('notes: $notes, ')
          ..write('lastWokenTime: $lastWokenTime')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    macAddress,
    broadcastIp,
    ipAddress,
    port,
    notes,
    lastWokenTime,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WolTarget &&
          other.id == this.id &&
          other.name == this.name &&
          other.macAddress == this.macAddress &&
          other.broadcastIp == this.broadcastIp &&
          other.ipAddress == this.ipAddress &&
          other.port == this.port &&
          other.notes == this.notes &&
          other.lastWokenTime == this.lastWokenTime);
}

class WolTargetsCompanion extends UpdateCompanion<WolTarget> {
  final Value<int> id;
  final Value<String> name;
  final Value<String> macAddress;
  final Value<String> broadcastIp;
  final Value<String> ipAddress;
  final Value<int> port;
  final Value<String> notes;
  final Value<int> lastWokenTime;
  const WolTargetsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.macAddress = const Value.absent(),
    this.broadcastIp = const Value.absent(),
    this.ipAddress = const Value.absent(),
    this.port = const Value.absent(),
    this.notes = const Value.absent(),
    this.lastWokenTime = const Value.absent(),
  });
  WolTargetsCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    required String macAddress,
    this.broadcastIp = const Value.absent(),
    this.ipAddress = const Value.absent(),
    this.port = const Value.absent(),
    this.notes = const Value.absent(),
    this.lastWokenTime = const Value.absent(),
  }) : name = Value(name),
       macAddress = Value(macAddress);
  static Insertable<WolTarget> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? macAddress,
    Expression<String>? broadcastIp,
    Expression<String>? ipAddress,
    Expression<int>? port,
    Expression<String>? notes,
    Expression<int>? lastWokenTime,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (macAddress != null) 'macAddress': macAddress,
      if (broadcastIp != null) 'broadcastIp': broadcastIp,
      if (ipAddress != null) 'ipAddress': ipAddress,
      if (port != null) 'port': port,
      if (notes != null) 'notes': notes,
      if (lastWokenTime != null) 'lastWokenTime': lastWokenTime,
    });
  }

  WolTargetsCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<String>? macAddress,
    Value<String>? broadcastIp,
    Value<String>? ipAddress,
    Value<int>? port,
    Value<String>? notes,
    Value<int>? lastWokenTime,
  }) {
    return WolTargetsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      macAddress: macAddress ?? this.macAddress,
      broadcastIp: broadcastIp ?? this.broadcastIp,
      ipAddress: ipAddress ?? this.ipAddress,
      port: port ?? this.port,
      notes: notes ?? this.notes,
      lastWokenTime: lastWokenTime ?? this.lastWokenTime,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (macAddress.present) {
      map['macAddress'] = Variable<String>(macAddress.value);
    }
    if (broadcastIp.present) {
      map['broadcastIp'] = Variable<String>(broadcastIp.value);
    }
    if (ipAddress.present) {
      map['ipAddress'] = Variable<String>(ipAddress.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (lastWokenTime.present) {
      map['lastWokenTime'] = Variable<int>(lastWokenTime.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WolTargetsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('macAddress: $macAddress, ')
          ..write('broadcastIp: $broadcastIp, ')
          ..write('ipAddress: $ipAddress, ')
          ..write('port: $port, ')
          ..write('notes: $notes, ')
          ..write('lastWokenTime: $lastWokenTime')
          ..write(')'))
        .toString();
  }
}

class $NetworkSharesTable extends NetworkShares
    with TableInfo<$NetworkSharesTable, NetworkShare> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NetworkSharesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _protocolMeta = const VerificationMeta(
    'protocol',
  );
  @override
  late final GeneratedColumn<String> protocol = GeneratedColumn<String>(
    'protocol',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'SMB',
  );
  static const VerificationMeta _addressMeta = const VerificationMeta(
    'address',
  );
  @override
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
    'address',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 445,
  );
  static const VerificationMeta _sharePathMeta = const VerificationMeta(
    'sharePath',
  );
  @override
  late final GeneratedColumn<String> sharePath = GeneratedColumn<String>(
    'sharePath',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _workgroupMeta = const VerificationMeta(
    'workgroup',
  );
  @override
  late final GeneratedColumn<String> workgroup = GeneratedColumn<String>(
    'workgroup',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _passwordMeta = const VerificationMeta(
    'password',
  );
  @override
  late final GeneratedColumn<String> password = GeneratedColumn<String>(
    'password',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _authProfileIdMeta = const VerificationMeta(
    'authProfileId',
  );
  @override
  late final GeneratedColumn<int> authProfileId = GeneratedColumn<int>(
    'authProfileId',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _anonymousMeta = const VerificationMeta(
    'anonymous',
  );
  @override
  late final GeneratedColumn<bool> anonymous = GeneratedColumn<bool>(
    'anonymous',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("anonymous" IN (0, 1))',
    ),
    clientDefault: () => true,
  );
  static const VerificationMeta _useHttpsMeta = const VerificationMeta(
    'useHttps',
  );
  @override
  late final GeneratedColumn<bool> useHttps = GeneratedColumn<bool>(
    'useHttps',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("useHttps" IN (0, 1))',
    ),
    clientDefault: () => false,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _lastCheckedMeta = const VerificationMeta(
    'lastChecked',
  );
  @override
  late final GeneratedColumn<int> lastChecked = GeneratedColumn<int>(
    'lastChecked',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 0,
  );
  static const VerificationMeta _lastStatusMeta = const VerificationMeta(
    'lastStatus',
  );
  @override
  late final GeneratedColumn<String> lastStatus = GeneratedColumn<String>(
    'lastStatus',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'unknown',
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    protocol,
    address,
    port,
    sharePath,
    workgroup,
    username,
    password,
    authProfileId,
    anonymous,
    useHttps,
    notes,
    lastChecked,
    lastStatus,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'network_shares';
  @override
  VerificationContext validateIntegrity(
    Insertable<NetworkShare> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('protocol')) {
      context.handle(
        _protocolMeta,
        protocol.isAcceptableOrUnknown(data['protocol']!, _protocolMeta),
      );
    }
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    } else if (isInserting) {
      context.missing(_addressMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    }
    if (data.containsKey('sharePath')) {
      context.handle(
        _sharePathMeta,
        sharePath.isAcceptableOrUnknown(data['sharePath']!, _sharePathMeta),
      );
    }
    if (data.containsKey('workgroup')) {
      context.handle(
        _workgroupMeta,
        workgroup.isAcceptableOrUnknown(data['workgroup']!, _workgroupMeta),
      );
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    }
    if (data.containsKey('password')) {
      context.handle(
        _passwordMeta,
        password.isAcceptableOrUnknown(data['password']!, _passwordMeta),
      );
    }
    if (data.containsKey('authProfileId')) {
      context.handle(
        _authProfileIdMeta,
        authProfileId.isAcceptableOrUnknown(
          data['authProfileId']!,
          _authProfileIdMeta,
        ),
      );
    }
    if (data.containsKey('anonymous')) {
      context.handle(
        _anonymousMeta,
        anonymous.isAcceptableOrUnknown(data['anonymous']!, _anonymousMeta),
      );
    }
    if (data.containsKey('useHttps')) {
      context.handle(
        _useHttpsMeta,
        useHttps.isAcceptableOrUnknown(data['useHttps']!, _useHttpsMeta),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('lastChecked')) {
      context.handle(
        _lastCheckedMeta,
        lastChecked.isAcceptableOrUnknown(
          data['lastChecked']!,
          _lastCheckedMeta,
        ),
      );
    }
    if (data.containsKey('lastStatus')) {
      context.handle(
        _lastStatusMeta,
        lastStatus.isAcceptableOrUnknown(data['lastStatus']!, _lastStatusMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  NetworkShare map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return NetworkShare(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      protocol: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}protocol'],
      )!,
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      )!,
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      )!,
      sharePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sharePath'],
      )!,
      workgroup: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}workgroup'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      password: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}password'],
      )!,
      authProfileId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}authProfileId'],
      ),
      anonymous: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}anonymous'],
      )!,
      useHttps: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}useHttps'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      )!,
      lastChecked: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}lastChecked'],
      )!,
      lastStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}lastStatus'],
      )!,
    );
  }

  @override
  $NetworkSharesTable createAlias(String alias) {
    return $NetworkSharesTable(attachedDatabase, alias);
  }
}

class NetworkShare extends DataClass implements Insertable<NetworkShare> {
  final int id;
  final String name;

  /// "SMB", "FTP", "SFTP", "NFS", "WEBDAV", or "CUSTOM".
  final String protocol;
  final String address;
  final int port;
  final String sharePath;
  final String workgroup;
  final String username;
  final String password;
  final int? authProfileId;
  final bool anonymous;

  /// WebDAV only: send requests over TLS. Explicit, not inferred from the port — Basic auth over
  /// plain http on a nonstandard TLS port (e.g. Synology 5006) would leak credentials.
  final bool useHttps;
  final String notes;
  final int lastChecked;
  final String lastStatus;
  const NetworkShare({
    required this.id,
    required this.name,
    required this.protocol,
    required this.address,
    required this.port,
    required this.sharePath,
    required this.workgroup,
    required this.username,
    required this.password,
    this.authProfileId,
    required this.anonymous,
    required this.useHttps,
    required this.notes,
    required this.lastChecked,
    required this.lastStatus,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['protocol'] = Variable<String>(protocol);
    map['address'] = Variable<String>(address);
    map['port'] = Variable<int>(port);
    map['sharePath'] = Variable<String>(sharePath);
    map['workgroup'] = Variable<String>(workgroup);
    map['username'] = Variable<String>(username);
    map['password'] = Variable<String>(password);
    if (!nullToAbsent || authProfileId != null) {
      map['authProfileId'] = Variable<int>(authProfileId);
    }
    map['anonymous'] = Variable<bool>(anonymous);
    map['useHttps'] = Variable<bool>(useHttps);
    map['notes'] = Variable<String>(notes);
    map['lastChecked'] = Variable<int>(lastChecked);
    map['lastStatus'] = Variable<String>(lastStatus);
    return map;
  }

  NetworkSharesCompanion toCompanion(bool nullToAbsent) {
    return NetworkSharesCompanion(
      id: Value(id),
      name: Value(name),
      protocol: Value(protocol),
      address: Value(address),
      port: Value(port),
      sharePath: Value(sharePath),
      workgroup: Value(workgroup),
      username: Value(username),
      password: Value(password),
      authProfileId: authProfileId == null && nullToAbsent
          ? const Value.absent()
          : Value(authProfileId),
      anonymous: Value(anonymous),
      useHttps: Value(useHttps),
      notes: Value(notes),
      lastChecked: Value(lastChecked),
      lastStatus: Value(lastStatus),
    );
  }

  factory NetworkShare.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NetworkShare(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      protocol: serializer.fromJson<String>(json['protocol']),
      address: serializer.fromJson<String>(json['address']),
      port: serializer.fromJson<int>(json['port']),
      sharePath: serializer.fromJson<String>(json['sharePath']),
      workgroup: serializer.fromJson<String>(json['workgroup']),
      username: serializer.fromJson<String>(json['username']),
      password: serializer.fromJson<String>(json['password']),
      authProfileId: serializer.fromJson<int?>(json['authProfileId']),
      anonymous: serializer.fromJson<bool>(json['anonymous']),
      useHttps: serializer.fromJson<bool>(json['useHttps']),
      notes: serializer.fromJson<String>(json['notes']),
      lastChecked: serializer.fromJson<int>(json['lastChecked']),
      lastStatus: serializer.fromJson<String>(json['lastStatus']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'protocol': serializer.toJson<String>(protocol),
      'address': serializer.toJson<String>(address),
      'port': serializer.toJson<int>(port),
      'sharePath': serializer.toJson<String>(sharePath),
      'workgroup': serializer.toJson<String>(workgroup),
      'username': serializer.toJson<String>(username),
      'password': serializer.toJson<String>(password),
      'authProfileId': serializer.toJson<int?>(authProfileId),
      'anonymous': serializer.toJson<bool>(anonymous),
      'useHttps': serializer.toJson<bool>(useHttps),
      'notes': serializer.toJson<String>(notes),
      'lastChecked': serializer.toJson<int>(lastChecked),
      'lastStatus': serializer.toJson<String>(lastStatus),
    };
  }

  NetworkShare copyWith({
    int? id,
    String? name,
    String? protocol,
    String? address,
    int? port,
    String? sharePath,
    String? workgroup,
    String? username,
    String? password,
    Value<int?> authProfileId = const Value.absent(),
    bool? anonymous,
    bool? useHttps,
    String? notes,
    int? lastChecked,
    String? lastStatus,
  }) => NetworkShare(
    id: id ?? this.id,
    name: name ?? this.name,
    protocol: protocol ?? this.protocol,
    address: address ?? this.address,
    port: port ?? this.port,
    sharePath: sharePath ?? this.sharePath,
    workgroup: workgroup ?? this.workgroup,
    username: username ?? this.username,
    password: password ?? this.password,
    authProfileId: authProfileId.present
        ? authProfileId.value
        : this.authProfileId,
    anonymous: anonymous ?? this.anonymous,
    useHttps: useHttps ?? this.useHttps,
    notes: notes ?? this.notes,
    lastChecked: lastChecked ?? this.lastChecked,
    lastStatus: lastStatus ?? this.lastStatus,
  );
  NetworkShare copyWithCompanion(NetworkSharesCompanion data) {
    return NetworkShare(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      protocol: data.protocol.present ? data.protocol.value : this.protocol,
      address: data.address.present ? data.address.value : this.address,
      port: data.port.present ? data.port.value : this.port,
      sharePath: data.sharePath.present ? data.sharePath.value : this.sharePath,
      workgroup: data.workgroup.present ? data.workgroup.value : this.workgroup,
      username: data.username.present ? data.username.value : this.username,
      password: data.password.present ? data.password.value : this.password,
      authProfileId: data.authProfileId.present
          ? data.authProfileId.value
          : this.authProfileId,
      anonymous: data.anonymous.present ? data.anonymous.value : this.anonymous,
      useHttps: data.useHttps.present ? data.useHttps.value : this.useHttps,
      notes: data.notes.present ? data.notes.value : this.notes,
      lastChecked: data.lastChecked.present
          ? data.lastChecked.value
          : this.lastChecked,
      lastStatus: data.lastStatus.present
          ? data.lastStatus.value
          : this.lastStatus,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NetworkShare(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('protocol: $protocol, ')
          ..write('address: $address, ')
          ..write('port: $port, ')
          ..write('sharePath: $sharePath, ')
          ..write('workgroup: $workgroup, ')
          ..write('username: $username, ')
          ..write('password: $password, ')
          ..write('authProfileId: $authProfileId, ')
          ..write('anonymous: $anonymous, ')
          ..write('useHttps: $useHttps, ')
          ..write('notes: $notes, ')
          ..write('lastChecked: $lastChecked, ')
          ..write('lastStatus: $lastStatus')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    protocol,
    address,
    port,
    sharePath,
    workgroup,
    username,
    password,
    authProfileId,
    anonymous,
    useHttps,
    notes,
    lastChecked,
    lastStatus,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NetworkShare &&
          other.id == this.id &&
          other.name == this.name &&
          other.protocol == this.protocol &&
          other.address == this.address &&
          other.port == this.port &&
          other.sharePath == this.sharePath &&
          other.workgroup == this.workgroup &&
          other.username == this.username &&
          other.password == this.password &&
          other.authProfileId == this.authProfileId &&
          other.anonymous == this.anonymous &&
          other.useHttps == this.useHttps &&
          other.notes == this.notes &&
          other.lastChecked == this.lastChecked &&
          other.lastStatus == this.lastStatus);
}

class NetworkSharesCompanion extends UpdateCompanion<NetworkShare> {
  final Value<int> id;
  final Value<String> name;
  final Value<String> protocol;
  final Value<String> address;
  final Value<int> port;
  final Value<String> sharePath;
  final Value<String> workgroup;
  final Value<String> username;
  final Value<String> password;
  final Value<int?> authProfileId;
  final Value<bool> anonymous;
  final Value<bool> useHttps;
  final Value<String> notes;
  final Value<int> lastChecked;
  final Value<String> lastStatus;
  const NetworkSharesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.protocol = const Value.absent(),
    this.address = const Value.absent(),
    this.port = const Value.absent(),
    this.sharePath = const Value.absent(),
    this.workgroup = const Value.absent(),
    this.username = const Value.absent(),
    this.password = const Value.absent(),
    this.authProfileId = const Value.absent(),
    this.anonymous = const Value.absent(),
    this.useHttps = const Value.absent(),
    this.notes = const Value.absent(),
    this.lastChecked = const Value.absent(),
    this.lastStatus = const Value.absent(),
  });
  NetworkSharesCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.protocol = const Value.absent(),
    required String address,
    this.port = const Value.absent(),
    this.sharePath = const Value.absent(),
    this.workgroup = const Value.absent(),
    this.username = const Value.absent(),
    this.password = const Value.absent(),
    this.authProfileId = const Value.absent(),
    this.anonymous = const Value.absent(),
    this.useHttps = const Value.absent(),
    this.notes = const Value.absent(),
    this.lastChecked = const Value.absent(),
    this.lastStatus = const Value.absent(),
  }) : name = Value(name),
       address = Value(address);
  static Insertable<NetworkShare> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? protocol,
    Expression<String>? address,
    Expression<int>? port,
    Expression<String>? sharePath,
    Expression<String>? workgroup,
    Expression<String>? username,
    Expression<String>? password,
    Expression<int>? authProfileId,
    Expression<bool>? anonymous,
    Expression<bool>? useHttps,
    Expression<String>? notes,
    Expression<int>? lastChecked,
    Expression<String>? lastStatus,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (protocol != null) 'protocol': protocol,
      if (address != null) 'address': address,
      if (port != null) 'port': port,
      if (sharePath != null) 'sharePath': sharePath,
      if (workgroup != null) 'workgroup': workgroup,
      if (username != null) 'username': username,
      if (password != null) 'password': password,
      if (authProfileId != null) 'authProfileId': authProfileId,
      if (anonymous != null) 'anonymous': anonymous,
      if (useHttps != null) 'useHttps': useHttps,
      if (notes != null) 'notes': notes,
      if (lastChecked != null) 'lastChecked': lastChecked,
      if (lastStatus != null) 'lastStatus': lastStatus,
    });
  }

  NetworkSharesCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<String>? protocol,
    Value<String>? address,
    Value<int>? port,
    Value<String>? sharePath,
    Value<String>? workgroup,
    Value<String>? username,
    Value<String>? password,
    Value<int?>? authProfileId,
    Value<bool>? anonymous,
    Value<bool>? useHttps,
    Value<String>? notes,
    Value<int>? lastChecked,
    Value<String>? lastStatus,
  }) {
    return NetworkSharesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      protocol: protocol ?? this.protocol,
      address: address ?? this.address,
      port: port ?? this.port,
      sharePath: sharePath ?? this.sharePath,
      workgroup: workgroup ?? this.workgroup,
      username: username ?? this.username,
      password: password ?? this.password,
      authProfileId: authProfileId ?? this.authProfileId,
      anonymous: anonymous ?? this.anonymous,
      useHttps: useHttps ?? this.useHttps,
      notes: notes ?? this.notes,
      lastChecked: lastChecked ?? this.lastChecked,
      lastStatus: lastStatus ?? this.lastStatus,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (protocol.present) {
      map['protocol'] = Variable<String>(protocol.value);
    }
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (sharePath.present) {
      map['sharePath'] = Variable<String>(sharePath.value);
    }
    if (workgroup.present) {
      map['workgroup'] = Variable<String>(workgroup.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (password.present) {
      map['password'] = Variable<String>(password.value);
    }
    if (authProfileId.present) {
      map['authProfileId'] = Variable<int>(authProfileId.value);
    }
    if (anonymous.present) {
      map['anonymous'] = Variable<bool>(anonymous.value);
    }
    if (useHttps.present) {
      map['useHttps'] = Variable<bool>(useHttps.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (lastChecked.present) {
      map['lastChecked'] = Variable<int>(lastChecked.value);
    }
    if (lastStatus.present) {
      map['lastStatus'] = Variable<String>(lastStatus.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NetworkSharesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('protocol: $protocol, ')
          ..write('address: $address, ')
          ..write('port: $port, ')
          ..write('sharePath: $sharePath, ')
          ..write('workgroup: $workgroup, ')
          ..write('username: $username, ')
          ..write('password: $password, ')
          ..write('authProfileId: $authProfileId, ')
          ..write('anonymous: $anonymous, ')
          ..write('useHttps: $useHttps, ')
          ..write('notes: $notes, ')
          ..write('lastChecked: $lastChecked, ')
          ..write('lastStatus: $lastStatus')
          ..write(')'))
        .toString();
  }
}

class $AppSettingsTable extends AppSettings
    with TableInfo<$AppSettingsTable, AppSetting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppSetting> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppSetting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppSetting(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $AppSettingsTable createAlias(String alias) {
    return $AppSettingsTable(attachedDatabase, alias);
  }
}

class AppSetting extends DataClass implements Insertable<AppSetting> {
  final String key;
  final String value;
  const AppSetting({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppSettingsCompanion toCompanion(bool nullToAbsent) {
    return AppSettingsCompanion(key: Value(key), value: Value(value));
  }

  factory AppSetting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppSetting(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AppSetting copyWith({String? key, String? value}) =>
      AppSetting(key: key ?? this.key, value: value ?? this.value);
  AppSetting copyWithCompanion(AppSettingsCompanion data) {
    return AppSetting(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppSetting(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppSetting &&
          other.key == this.key &&
          other.value == this.value);
}

class AppSettingsCompanion extends UpdateCompanion<AppSetting> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppSettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppSettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<AppSetting> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppSettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AppSettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PersistentSessionsTable extends PersistentSessions
    with TableInfo<$PersistentSessionsTable, PersistentSession> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PersistentSessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _tmuxNameMeta = const VerificationMeta(
    'tmuxName',
  );
  @override
  late final GeneratedColumn<String> tmuxName = GeneratedColumn<String>(
    'tmuxName',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<int> serverId = GeneratedColumn<int>(
    'serverId',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverNameMeta = const VerificationMeta(
    'serverName',
  );
  @override
  late final GeneratedColumn<String> serverName = GeneratedColumn<String>(
    'serverName',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'createdAt',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _backgroundedAtMeta = const VerificationMeta(
    'backgroundedAt',
  );
  @override
  late final GeneratedColumn<int> backgroundedAt = GeneratedColumn<int>(
    'backgroundedAt',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    tmuxName,
    serverId,
    serverName,
    createdAt,
    backgroundedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'persistent_sessions';
  @override
  VerificationContext validateIntegrity(
    Insertable<PersistentSession> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('tmuxName')) {
      context.handle(
        _tmuxNameMeta,
        tmuxName.isAcceptableOrUnknown(data['tmuxName']!, _tmuxNameMeta),
      );
    } else if (isInserting) {
      context.missing(_tmuxNameMeta);
    }
    if (data.containsKey('serverId')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['serverId']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('serverName')) {
      context.handle(
        _serverNameMeta,
        serverName.isAcceptableOrUnknown(data['serverName']!, _serverNameMeta),
      );
    } else if (isInserting) {
      context.missing(_serverNameMeta);
    }
    if (data.containsKey('createdAt')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['createdAt']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('backgroundedAt')) {
      context.handle(
        _backgroundedAtMeta,
        backgroundedAt.isAcceptableOrUnknown(
          data['backgroundedAt']!,
          _backgroundedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_backgroundedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {tmuxName};
  @override
  PersistentSession map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PersistentSession(
      tmuxName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tmuxName'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}serverId'],
      )!,
      serverName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}serverName'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}createdAt'],
      )!,
      backgroundedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}backgroundedAt'],
      )!,
    );
  }

  @override
  $PersistentSessionsTable createAlias(String alias) {
    return $PersistentSessionsTable(attachedDatabase, alias);
  }
}

class PersistentSession extends DataClass
    implements Insertable<PersistentSession> {
  final String tmuxName;
  final int serverId;
  final String serverName;
  final int createdAt;

  /// When this session was most recently left running in the background. Unlike [createdAt] —
  /// which dates the tmux session itself and survives resume/background cycles — this restarts
  /// every time the user backgrounds the session again, so "backgrounded since" answers "how long
  /// has it been sitting there since I last used it?".
  final int backgroundedAt;
  const PersistentSession({
    required this.tmuxName,
    required this.serverId,
    required this.serverName,
    required this.createdAt,
    required this.backgroundedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['tmuxName'] = Variable<String>(tmuxName);
    map['serverId'] = Variable<int>(serverId);
    map['serverName'] = Variable<String>(serverName);
    map['createdAt'] = Variable<int>(createdAt);
    map['backgroundedAt'] = Variable<int>(backgroundedAt);
    return map;
  }

  PersistentSessionsCompanion toCompanion(bool nullToAbsent) {
    return PersistentSessionsCompanion(
      tmuxName: Value(tmuxName),
      serverId: Value(serverId),
      serverName: Value(serverName),
      createdAt: Value(createdAt),
      backgroundedAt: Value(backgroundedAt),
    );
  }

  factory PersistentSession.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PersistentSession(
      tmuxName: serializer.fromJson<String>(json['tmuxName']),
      serverId: serializer.fromJson<int>(json['serverId']),
      serverName: serializer.fromJson<String>(json['serverName']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      backgroundedAt: serializer.fromJson<int>(json['backgroundedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'tmuxName': serializer.toJson<String>(tmuxName),
      'serverId': serializer.toJson<int>(serverId),
      'serverName': serializer.toJson<String>(serverName),
      'createdAt': serializer.toJson<int>(createdAt),
      'backgroundedAt': serializer.toJson<int>(backgroundedAt),
    };
  }

  PersistentSession copyWith({
    String? tmuxName,
    int? serverId,
    String? serverName,
    int? createdAt,
    int? backgroundedAt,
  }) => PersistentSession(
    tmuxName: tmuxName ?? this.tmuxName,
    serverId: serverId ?? this.serverId,
    serverName: serverName ?? this.serverName,
    createdAt: createdAt ?? this.createdAt,
    backgroundedAt: backgroundedAt ?? this.backgroundedAt,
  );
  PersistentSession copyWithCompanion(PersistentSessionsCompanion data) {
    return PersistentSession(
      tmuxName: data.tmuxName.present ? data.tmuxName.value : this.tmuxName,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      serverName: data.serverName.present
          ? data.serverName.value
          : this.serverName,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      backgroundedAt: data.backgroundedAt.present
          ? data.backgroundedAt.value
          : this.backgroundedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PersistentSession(')
          ..write('tmuxName: $tmuxName, ')
          ..write('serverId: $serverId, ')
          ..write('serverName: $serverName, ')
          ..write('createdAt: $createdAt, ')
          ..write('backgroundedAt: $backgroundedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(tmuxName, serverId, serverName, createdAt, backgroundedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PersistentSession &&
          other.tmuxName == this.tmuxName &&
          other.serverId == this.serverId &&
          other.serverName == this.serverName &&
          other.createdAt == this.createdAt &&
          other.backgroundedAt == this.backgroundedAt);
}

class PersistentSessionsCompanion extends UpdateCompanion<PersistentSession> {
  final Value<String> tmuxName;
  final Value<int> serverId;
  final Value<String> serverName;
  final Value<int> createdAt;
  final Value<int> backgroundedAt;
  final Value<int> rowid;
  const PersistentSessionsCompanion({
    this.tmuxName = const Value.absent(),
    this.serverId = const Value.absent(),
    this.serverName = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.backgroundedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PersistentSessionsCompanion.insert({
    required String tmuxName,
    required int serverId,
    required String serverName,
    required int createdAt,
    required int backgroundedAt,
    this.rowid = const Value.absent(),
  }) : tmuxName = Value(tmuxName),
       serverId = Value(serverId),
       serverName = Value(serverName),
       createdAt = Value(createdAt),
       backgroundedAt = Value(backgroundedAt);
  static Insertable<PersistentSession> custom({
    Expression<String>? tmuxName,
    Expression<int>? serverId,
    Expression<String>? serverName,
    Expression<int>? createdAt,
    Expression<int>? backgroundedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (tmuxName != null) 'tmuxName': tmuxName,
      if (serverId != null) 'serverId': serverId,
      if (serverName != null) 'serverName': serverName,
      if (createdAt != null) 'createdAt': createdAt,
      if (backgroundedAt != null) 'backgroundedAt': backgroundedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PersistentSessionsCompanion copyWith({
    Value<String>? tmuxName,
    Value<int>? serverId,
    Value<String>? serverName,
    Value<int>? createdAt,
    Value<int>? backgroundedAt,
    Value<int>? rowid,
  }) {
    return PersistentSessionsCompanion(
      tmuxName: tmuxName ?? this.tmuxName,
      serverId: serverId ?? this.serverId,
      serverName: serverName ?? this.serverName,
      createdAt: createdAt ?? this.createdAt,
      backgroundedAt: backgroundedAt ?? this.backgroundedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (tmuxName.present) {
      map['tmuxName'] = Variable<String>(tmuxName.value);
    }
    if (serverId.present) {
      map['serverId'] = Variable<int>(serverId.value);
    }
    if (serverName.present) {
      map['serverName'] = Variable<String>(serverName.value);
    }
    if (createdAt.present) {
      map['createdAt'] = Variable<int>(createdAt.value);
    }
    if (backgroundedAt.present) {
      map['backgroundedAt'] = Variable<int>(backgroundedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PersistentSessionsCompanion(')
          ..write('tmuxName: $tmuxName, ')
          ..write('serverId: $serverId, ')
          ..write('serverName: $serverName, ')
          ..write('createdAt: $createdAt, ')
          ..write('backgroundedAt: $backgroundedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PortForwardsTable extends PortForwards
    with TableInfo<$PortForwardsTable, PortForward> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PortForwardsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<int> serverId = GeneratedColumn<int>(
    'serverId',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => 'local',
  );
  static const VerificationMeta _bindHostMeta = const VerificationMeta(
    'bindHost',
  );
  @override
  late final GeneratedColumn<String> bindHost = GeneratedColumn<String>(
    'bindHost',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '127.0.0.1',
  );
  static const VerificationMeta _bindPortMeta = const VerificationMeta(
    'bindPort',
  );
  @override
  late final GeneratedColumn<int> bindPort = GeneratedColumn<int>(
    'bindPort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _destHostMeta = const VerificationMeta(
    'destHost',
  );
  @override
  late final GeneratedColumn<String> destHost = GeneratedColumn<String>(
    'destHost',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    clientDefault: () => '',
  );
  static const VerificationMeta _destPortMeta = const VerificationMeta(
    'destPort',
  );
  @override
  late final GeneratedColumn<int> destPort = GeneratedColumn<int>(
    'destPort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    clientDefault: () => 0,
  );
  static const VerificationMeta _autoStartMeta = const VerificationMeta(
    'autoStart',
  );
  @override
  late final GeneratedColumn<bool> autoStart = GeneratedColumn<bool>(
    'autoStart',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("autoStart" IN (0, 1))',
    ),
    clientDefault: () => false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    serverId,
    name,
    kind,
    bindHost,
    bindPort,
    destHost,
    destPort,
    autoStart,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'port_forwards';
  @override
  VerificationContext validateIntegrity(
    Insertable<PortForward> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('serverId')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['serverId']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    }
    if (data.containsKey('bindHost')) {
      context.handle(
        _bindHostMeta,
        bindHost.isAcceptableOrUnknown(data['bindHost']!, _bindHostMeta),
      );
    }
    if (data.containsKey('bindPort')) {
      context.handle(
        _bindPortMeta,
        bindPort.isAcceptableOrUnknown(data['bindPort']!, _bindPortMeta),
      );
    } else if (isInserting) {
      context.missing(_bindPortMeta);
    }
    if (data.containsKey('destHost')) {
      context.handle(
        _destHostMeta,
        destHost.isAcceptableOrUnknown(data['destHost']!, _destHostMeta),
      );
    }
    if (data.containsKey('destPort')) {
      context.handle(
        _destPortMeta,
        destPort.isAcceptableOrUnknown(data['destPort']!, _destPortMeta),
      );
    }
    if (data.containsKey('autoStart')) {
      context.handle(
        _autoStartMeta,
        autoStart.isAcceptableOrUnknown(data['autoStart']!, _autoStartMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PortForward map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PortForward(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}serverId'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      bindHost: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bindHost'],
      )!,
      bindPort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bindPort'],
      )!,
      destHost: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}destHost'],
      )!,
      destPort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}destPort'],
      )!,
      autoStart: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}autoStart'],
      )!,
    );
  }

  @override
  $PortForwardsTable createAlias(String alias) {
    return $PortForwardsTable(attachedDatabase, alias);
  }
}

class PortForward extends DataClass implements Insertable<PortForward> {
  final int id;
  final int serverId;
  final String name;
  final String kind;
  final String bindHost;
  final int bindPort;
  final String destHost;
  final int destPort;
  final bool autoStart;
  const PortForward({
    required this.id,
    required this.serverId,
    required this.name,
    required this.kind,
    required this.bindHost,
    required this.bindPort,
    required this.destHost,
    required this.destPort,
    required this.autoStart,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['serverId'] = Variable<int>(serverId);
    map['name'] = Variable<String>(name);
    map['kind'] = Variable<String>(kind);
    map['bindHost'] = Variable<String>(bindHost);
    map['bindPort'] = Variable<int>(bindPort);
    map['destHost'] = Variable<String>(destHost);
    map['destPort'] = Variable<int>(destPort);
    map['autoStart'] = Variable<bool>(autoStart);
    return map;
  }

  PortForwardsCompanion toCompanion(bool nullToAbsent) {
    return PortForwardsCompanion(
      id: Value(id),
      serverId: Value(serverId),
      name: Value(name),
      kind: Value(kind),
      bindHost: Value(bindHost),
      bindPort: Value(bindPort),
      destHost: Value(destHost),
      destPort: Value(destPort),
      autoStart: Value(autoStart),
    );
  }

  factory PortForward.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PortForward(
      id: serializer.fromJson<int>(json['id']),
      serverId: serializer.fromJson<int>(json['serverId']),
      name: serializer.fromJson<String>(json['name']),
      kind: serializer.fromJson<String>(json['kind']),
      bindHost: serializer.fromJson<String>(json['bindHost']),
      bindPort: serializer.fromJson<int>(json['bindPort']),
      destHost: serializer.fromJson<String>(json['destHost']),
      destPort: serializer.fromJson<int>(json['destPort']),
      autoStart: serializer.fromJson<bool>(json['autoStart']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'serverId': serializer.toJson<int>(serverId),
      'name': serializer.toJson<String>(name),
      'kind': serializer.toJson<String>(kind),
      'bindHost': serializer.toJson<String>(bindHost),
      'bindPort': serializer.toJson<int>(bindPort),
      'destHost': serializer.toJson<String>(destHost),
      'destPort': serializer.toJson<int>(destPort),
      'autoStart': serializer.toJson<bool>(autoStart),
    };
  }

  PortForward copyWith({
    int? id,
    int? serverId,
    String? name,
    String? kind,
    String? bindHost,
    int? bindPort,
    String? destHost,
    int? destPort,
    bool? autoStart,
  }) => PortForward(
    id: id ?? this.id,
    serverId: serverId ?? this.serverId,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    bindHost: bindHost ?? this.bindHost,
    bindPort: bindPort ?? this.bindPort,
    destHost: destHost ?? this.destHost,
    destPort: destPort ?? this.destPort,
    autoStart: autoStart ?? this.autoStart,
  );
  PortForward copyWithCompanion(PortForwardsCompanion data) {
    return PortForward(
      id: data.id.present ? data.id.value : this.id,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      name: data.name.present ? data.name.value : this.name,
      kind: data.kind.present ? data.kind.value : this.kind,
      bindHost: data.bindHost.present ? data.bindHost.value : this.bindHost,
      bindPort: data.bindPort.present ? data.bindPort.value : this.bindPort,
      destHost: data.destHost.present ? data.destHost.value : this.destHost,
      destPort: data.destPort.present ? data.destPort.value : this.destPort,
      autoStart: data.autoStart.present ? data.autoStart.value : this.autoStart,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PortForward(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('bindHost: $bindHost, ')
          ..write('bindPort: $bindPort, ')
          ..write('destHost: $destHost, ')
          ..write('destPort: $destPort, ')
          ..write('autoStart: $autoStart')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    serverId,
    name,
    kind,
    bindHost,
    bindPort,
    destHost,
    destPort,
    autoStart,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PortForward &&
          other.id == this.id &&
          other.serverId == this.serverId &&
          other.name == this.name &&
          other.kind == this.kind &&
          other.bindHost == this.bindHost &&
          other.bindPort == this.bindPort &&
          other.destHost == this.destHost &&
          other.destPort == this.destPort &&
          other.autoStart == this.autoStart);
}

class PortForwardsCompanion extends UpdateCompanion<PortForward> {
  final Value<int> id;
  final Value<int> serverId;
  final Value<String> name;
  final Value<String> kind;
  final Value<String> bindHost;
  final Value<int> bindPort;
  final Value<String> destHost;
  final Value<int> destPort;
  final Value<bool> autoStart;
  const PortForwardsCompanion({
    this.id = const Value.absent(),
    this.serverId = const Value.absent(),
    this.name = const Value.absent(),
    this.kind = const Value.absent(),
    this.bindHost = const Value.absent(),
    this.bindPort = const Value.absent(),
    this.destHost = const Value.absent(),
    this.destPort = const Value.absent(),
    this.autoStart = const Value.absent(),
  });
  PortForwardsCompanion.insert({
    this.id = const Value.absent(),
    required int serverId,
    required String name,
    this.kind = const Value.absent(),
    this.bindHost = const Value.absent(),
    required int bindPort,
    this.destHost = const Value.absent(),
    this.destPort = const Value.absent(),
    this.autoStart = const Value.absent(),
  }) : serverId = Value(serverId),
       name = Value(name),
       bindPort = Value(bindPort);
  static Insertable<PortForward> custom({
    Expression<int>? id,
    Expression<int>? serverId,
    Expression<String>? name,
    Expression<String>? kind,
    Expression<String>? bindHost,
    Expression<int>? bindPort,
    Expression<String>? destHost,
    Expression<int>? destPort,
    Expression<bool>? autoStart,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (serverId != null) 'serverId': serverId,
      if (name != null) 'name': name,
      if (kind != null) 'kind': kind,
      if (bindHost != null) 'bindHost': bindHost,
      if (bindPort != null) 'bindPort': bindPort,
      if (destHost != null) 'destHost': destHost,
      if (destPort != null) 'destPort': destPort,
      if (autoStart != null) 'autoStart': autoStart,
    });
  }

  PortForwardsCompanion copyWith({
    Value<int>? id,
    Value<int>? serverId,
    Value<String>? name,
    Value<String>? kind,
    Value<String>? bindHost,
    Value<int>? bindPort,
    Value<String>? destHost,
    Value<int>? destPort,
    Value<bool>? autoStart,
  }) {
    return PortForwardsCompanion(
      id: id ?? this.id,
      serverId: serverId ?? this.serverId,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      bindHost: bindHost ?? this.bindHost,
      bindPort: bindPort ?? this.bindPort,
      destHost: destHost ?? this.destHost,
      destPort: destPort ?? this.destPort,
      autoStart: autoStart ?? this.autoStart,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (serverId.present) {
      map['serverId'] = Variable<int>(serverId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (bindHost.present) {
      map['bindHost'] = Variable<String>(bindHost.value);
    }
    if (bindPort.present) {
      map['bindPort'] = Variable<int>(bindPort.value);
    }
    if (destHost.present) {
      map['destHost'] = Variable<String>(destHost.value);
    }
    if (destPort.present) {
      map['destPort'] = Variable<int>(destPort.value);
    }
    if (autoStart.present) {
      map['autoStart'] = Variable<bool>(autoStart.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PortForwardsCompanion(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('bindHost: $bindHost, ')
          ..write('bindPort: $bindPort, ')
          ..write('destHost: $destHost, ')
          ..write('destPort: $destPort, ')
          ..write('autoStart: $autoStart')
          ..write(')'))
        .toString();
  }
}

class $StackRegistryTable extends StackRegistry
    with TableInfo<$StackRegistryTable, StackRegistryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StackRegistryTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<int> serverId = GeneratedColumn<int>(
    'serverId',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _runtimeMeta = const VerificationMeta(
    'runtime',
  );
  @override
  late final GeneratedColumn<String> runtime = GeneratedColumn<String>(
    'runtime',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _projectMeta = const VerificationMeta(
    'project',
  );
  @override
  late final GeneratedColumn<String> project = GeneratedColumn<String>(
    'project',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _workingDirMeta = const VerificationMeta(
    'workingDir',
  );
  @override
  late final GeneratedColumn<String> workingDir = GeneratedColumn<String>(
    'workingDir',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _configFilesMeta = const VerificationMeta(
    'configFiles',
  );
  @override
  late final GeneratedColumn<String> configFiles = GeneratedColumn<String>(
    'configFiles',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastSeenAtMeta = const VerificationMeta(
    'lastSeenAt',
  );
  @override
  late final GeneratedColumn<int> lastSeenAt = GeneratedColumn<int>(
    'lastSeenAt',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    serverId,
    runtime,
    project,
    workingDir,
    configFiles,
    lastSeenAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stack_registry';
  @override
  VerificationContext validateIntegrity(
    Insertable<StackRegistryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('serverId')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['serverId']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('runtime')) {
      context.handle(
        _runtimeMeta,
        runtime.isAcceptableOrUnknown(data['runtime']!, _runtimeMeta),
      );
    } else if (isInserting) {
      context.missing(_runtimeMeta);
    }
    if (data.containsKey('project')) {
      context.handle(
        _projectMeta,
        project.isAcceptableOrUnknown(data['project']!, _projectMeta),
      );
    } else if (isInserting) {
      context.missing(_projectMeta);
    }
    if (data.containsKey('workingDir')) {
      context.handle(
        _workingDirMeta,
        workingDir.isAcceptableOrUnknown(data['workingDir']!, _workingDirMeta),
      );
    } else if (isInserting) {
      context.missing(_workingDirMeta);
    }
    if (data.containsKey('configFiles')) {
      context.handle(
        _configFilesMeta,
        configFiles.isAcceptableOrUnknown(
          data['configFiles']!,
          _configFilesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_configFilesMeta);
    }
    if (data.containsKey('lastSeenAt')) {
      context.handle(
        _lastSeenAtMeta,
        lastSeenAt.isAcceptableOrUnknown(data['lastSeenAt']!, _lastSeenAtMeta),
      );
    } else if (isInserting) {
      context.missing(_lastSeenAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StackRegistryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StackRegistryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}serverId'],
      )!,
      runtime: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}runtime'],
      )!,
      project: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}project'],
      )!,
      workingDir: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}workingDir'],
      )!,
      configFiles: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}configFiles'],
      )!,
      lastSeenAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}lastSeenAt'],
      )!,
    );
  }

  @override
  $StackRegistryTable createAlias(String alias) {
    return $StackRegistryTable(attachedDatabase, alias);
  }
}

class StackRegistryRow extends DataClass
    implements Insertable<StackRegistryRow> {
  final int id;
  final int serverId;

  /// "docker" | "podman" — a stack is owned by exactly one runtime.
  final String runtime;

  /// Compose project name (the `-p` flag).
  final String project;

  /// `com.docker.compose.project.working_dir` (or the first config file's parent).
  final String workingDir;

  /// `com.docker.compose.project.config_files`, comma-separated.
  final String configFiles;
  final int lastSeenAt;
  const StackRegistryRow({
    required this.id,
    required this.serverId,
    required this.runtime,
    required this.project,
    required this.workingDir,
    required this.configFiles,
    required this.lastSeenAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['serverId'] = Variable<int>(serverId);
    map['runtime'] = Variable<String>(runtime);
    map['project'] = Variable<String>(project);
    map['workingDir'] = Variable<String>(workingDir);
    map['configFiles'] = Variable<String>(configFiles);
    map['lastSeenAt'] = Variable<int>(lastSeenAt);
    return map;
  }

  StackRegistryCompanion toCompanion(bool nullToAbsent) {
    return StackRegistryCompanion(
      id: Value(id),
      serverId: Value(serverId),
      runtime: Value(runtime),
      project: Value(project),
      workingDir: Value(workingDir),
      configFiles: Value(configFiles),
      lastSeenAt: Value(lastSeenAt),
    );
  }

  factory StackRegistryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StackRegistryRow(
      id: serializer.fromJson<int>(json['id']),
      serverId: serializer.fromJson<int>(json['serverId']),
      runtime: serializer.fromJson<String>(json['runtime']),
      project: serializer.fromJson<String>(json['project']),
      workingDir: serializer.fromJson<String>(json['workingDir']),
      configFiles: serializer.fromJson<String>(json['configFiles']),
      lastSeenAt: serializer.fromJson<int>(json['lastSeenAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'serverId': serializer.toJson<int>(serverId),
      'runtime': serializer.toJson<String>(runtime),
      'project': serializer.toJson<String>(project),
      'workingDir': serializer.toJson<String>(workingDir),
      'configFiles': serializer.toJson<String>(configFiles),
      'lastSeenAt': serializer.toJson<int>(lastSeenAt),
    };
  }

  StackRegistryRow copyWith({
    int? id,
    int? serverId,
    String? runtime,
    String? project,
    String? workingDir,
    String? configFiles,
    int? lastSeenAt,
  }) => StackRegistryRow(
    id: id ?? this.id,
    serverId: serverId ?? this.serverId,
    runtime: runtime ?? this.runtime,
    project: project ?? this.project,
    workingDir: workingDir ?? this.workingDir,
    configFiles: configFiles ?? this.configFiles,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
  );
  StackRegistryRow copyWithCompanion(StackRegistryCompanion data) {
    return StackRegistryRow(
      id: data.id.present ? data.id.value : this.id,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      runtime: data.runtime.present ? data.runtime.value : this.runtime,
      project: data.project.present ? data.project.value : this.project,
      workingDir: data.workingDir.present
          ? data.workingDir.value
          : this.workingDir,
      configFiles: data.configFiles.present
          ? data.configFiles.value
          : this.configFiles,
      lastSeenAt: data.lastSeenAt.present
          ? data.lastSeenAt.value
          : this.lastSeenAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StackRegistryRow(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('runtime: $runtime, ')
          ..write('project: $project, ')
          ..write('workingDir: $workingDir, ')
          ..write('configFiles: $configFiles, ')
          ..write('lastSeenAt: $lastSeenAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    serverId,
    runtime,
    project,
    workingDir,
    configFiles,
    lastSeenAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StackRegistryRow &&
          other.id == this.id &&
          other.serverId == this.serverId &&
          other.runtime == this.runtime &&
          other.project == this.project &&
          other.workingDir == this.workingDir &&
          other.configFiles == this.configFiles &&
          other.lastSeenAt == this.lastSeenAt);
}

class StackRegistryCompanion extends UpdateCompanion<StackRegistryRow> {
  final Value<int> id;
  final Value<int> serverId;
  final Value<String> runtime;
  final Value<String> project;
  final Value<String> workingDir;
  final Value<String> configFiles;
  final Value<int> lastSeenAt;
  const StackRegistryCompanion({
    this.id = const Value.absent(),
    this.serverId = const Value.absent(),
    this.runtime = const Value.absent(),
    this.project = const Value.absent(),
    this.workingDir = const Value.absent(),
    this.configFiles = const Value.absent(),
    this.lastSeenAt = const Value.absent(),
  });
  StackRegistryCompanion.insert({
    this.id = const Value.absent(),
    required int serverId,
    required String runtime,
    required String project,
    required String workingDir,
    required String configFiles,
    required int lastSeenAt,
  }) : serverId = Value(serverId),
       runtime = Value(runtime),
       project = Value(project),
       workingDir = Value(workingDir),
       configFiles = Value(configFiles),
       lastSeenAt = Value(lastSeenAt);
  static Insertable<StackRegistryRow> custom({
    Expression<int>? id,
    Expression<int>? serverId,
    Expression<String>? runtime,
    Expression<String>? project,
    Expression<String>? workingDir,
    Expression<String>? configFiles,
    Expression<int>? lastSeenAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (serverId != null) 'serverId': serverId,
      if (runtime != null) 'runtime': runtime,
      if (project != null) 'project': project,
      if (workingDir != null) 'workingDir': workingDir,
      if (configFiles != null) 'configFiles': configFiles,
      if (lastSeenAt != null) 'lastSeenAt': lastSeenAt,
    });
  }

  StackRegistryCompanion copyWith({
    Value<int>? id,
    Value<int>? serverId,
    Value<String>? runtime,
    Value<String>? project,
    Value<String>? workingDir,
    Value<String>? configFiles,
    Value<int>? lastSeenAt,
  }) {
    return StackRegistryCompanion(
      id: id ?? this.id,
      serverId: serverId ?? this.serverId,
      runtime: runtime ?? this.runtime,
      project: project ?? this.project,
      workingDir: workingDir ?? this.workingDir,
      configFiles: configFiles ?? this.configFiles,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (serverId.present) {
      map['serverId'] = Variable<int>(serverId.value);
    }
    if (runtime.present) {
      map['runtime'] = Variable<String>(runtime.value);
    }
    if (project.present) {
      map['project'] = Variable<String>(project.value);
    }
    if (workingDir.present) {
      map['workingDir'] = Variable<String>(workingDir.value);
    }
    if (configFiles.present) {
      map['configFiles'] = Variable<String>(configFiles.value);
    }
    if (lastSeenAt.present) {
      map['lastSeenAt'] = Variable<int>(lastSeenAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StackRegistryCompanion(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('runtime: $runtime, ')
          ..write('project: $project, ')
          ..write('workingDir: $workingDir, ')
          ..write('configFiles: $configFiles, ')
          ..write('lastSeenAt: $lastSeenAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ServersTable servers = $ServersTable(this);
  late final $MetricHistoryTable metricHistory = $MetricHistoryTable(this);
  late final $SshKeysTable sshKeys = $SshKeysTable(this);
  late final $CredentialProfilesTable credentialProfiles =
      $CredentialProfilesTable(this);
  late final $AlertRulesTable alertRules = $AlertRulesTable(this);
  late final $ActiveAlertsTable activeAlerts = $ActiveAlertsTable(this);
  late final $AlertHistoryTable alertHistory = $AlertHistoryTable(this);
  late final $QuickScriptsTable quickScripts = $QuickScriptsTable(this);
  late final $WolTargetsTable wolTargets = $WolTargetsTable(this);
  late final $NetworkSharesTable networkShares = $NetworkSharesTable(this);
  late final $AppSettingsTable appSettings = $AppSettingsTable(this);
  late final $PersistentSessionsTable persistentSessions =
      $PersistentSessionsTable(this);
  late final $PortForwardsTable portForwards = $PortForwardsTable(this);
  late final $StackRegistryTable stackRegistry = $StackRegistryTable(this);
  late final Index indexMetricHistoryServerIdTimestamp = Index(
    'index_metric_history_serverId_timestamp',
    'CREATE INDEX index_metric_history_serverId_timestamp ON metric_history (serverId, timestamp)',
  );
  late final Index indexActiveAlertsRuleIdServerId = Index(
    'index_active_alerts_ruleId_serverId',
    'CREATE UNIQUE INDEX index_active_alerts_ruleId_serverId ON active_alerts (ruleId, serverId)',
  );
  late final Index indexAlertHistoryActiveAlertId = Index(
    'index_alert_history_activeAlertId',
    'CREATE UNIQUE INDEX index_alert_history_activeAlertId ON alert_history (activeAlertId)',
  );
  late final Index indexStackRegistryServerIdRuntimeProject = Index(
    'index_stack_registry_serverId_runtime_project',
    'CREATE UNIQUE INDEX index_stack_registry_serverId_runtime_project ON stack_registry (serverId, runtime, project)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    servers,
    metricHistory,
    sshKeys,
    credentialProfiles,
    alertRules,
    activeAlerts,
    alertHistory,
    quickScripts,
    wolTargets,
    networkShares,
    appSettings,
    persistentSessions,
    portForwards,
    stackRegistry,
    indexMetricHistoryServerIdTimestamp,
    indexActiveAlertsRuleIdServerId,
    indexAlertHistoryActiveAlertId,
    indexStackRegistryServerIdRuntimeProject,
  ];
}

typedef $$ServersTableCreateCompanionBuilder =
    ServersCompanion Function({
      Value<int> id,
      required String name,
      required String host,
      Value<int> port,
      required String username,
      Value<String?> groupName,
      Value<String> serverColor,
      Value<String> authType,
      Value<String?> authKeyAlias,
      Value<String?> authPassword,
      Value<String> sudoPassword,
      Value<int?> authProfileId,
      Value<String> notes,
      Value<int> keepAlive,
      Value<bool> sshCompression,
      Value<bool> persistentSession,
      Value<String> proxyCommand,
      Value<String> proxyType,
      Value<String> proxyHost,
      Value<int> proxyPort,
      Value<String> proxyUser,
      Value<String> proxyPassword,
      Value<String?> proxyKeyAlias,
      Value<bool> agentForwarding,
      Value<int> healthScore,
      Value<int> lastLatency,
      Value<String> status,
      Value<String> authStatus,
      Value<String?> authError,
    });
typedef $$ServersTableUpdateCompanionBuilder =
    ServersCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<String> host,
      Value<int> port,
      Value<String> username,
      Value<String?> groupName,
      Value<String> serverColor,
      Value<String> authType,
      Value<String?> authKeyAlias,
      Value<String?> authPassword,
      Value<String> sudoPassword,
      Value<int?> authProfileId,
      Value<String> notes,
      Value<int> keepAlive,
      Value<bool> sshCompression,
      Value<bool> persistentSession,
      Value<String> proxyCommand,
      Value<String> proxyType,
      Value<String> proxyHost,
      Value<int> proxyPort,
      Value<String> proxyUser,
      Value<String> proxyPassword,
      Value<String?> proxyKeyAlias,
      Value<bool> agentForwarding,
      Value<int> healthScore,
      Value<int> lastLatency,
      Value<String> status,
      Value<String> authStatus,
      Value<String?> authError,
    });

class $$ServersTableFilterComposer
    extends Composer<_$AppDatabase, $ServersTable> {
  $$ServersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupName => $composableBuilder(
    column: $table.groupName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverColor => $composableBuilder(
    column: $table.serverColor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authType => $composableBuilder(
    column: $table.authType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authKeyAlias => $composableBuilder(
    column: $table.authKeyAlias,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authPassword => $composableBuilder(
    column: $table.authPassword,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sudoPassword => $composableBuilder(
    column: $table.sudoPassword,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get authProfileId => $composableBuilder(
    column: $table.authProfileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get keepAlive => $composableBuilder(
    column: $table.keepAlive,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get sshCompression => $composableBuilder(
    column: $table.sshCompression,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get persistentSession => $composableBuilder(
    column: $table.persistentSession,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get proxyCommand => $composableBuilder(
    column: $table.proxyCommand,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get proxyType => $composableBuilder(
    column: $table.proxyType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get proxyHost => $composableBuilder(
    column: $table.proxyHost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get proxyPort => $composableBuilder(
    column: $table.proxyPort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get proxyUser => $composableBuilder(
    column: $table.proxyUser,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get proxyPassword => $composableBuilder(
    column: $table.proxyPassword,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get proxyKeyAlias => $composableBuilder(
    column: $table.proxyKeyAlias,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get agentForwarding => $composableBuilder(
    column: $table.agentForwarding,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get healthScore => $composableBuilder(
    column: $table.healthScore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastLatency => $composableBuilder(
    column: $table.lastLatency,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authStatus => $composableBuilder(
    column: $table.authStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authError => $composableBuilder(
    column: $table.authError,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ServersTableOrderingComposer
    extends Composer<_$AppDatabase, $ServersTable> {
  $$ServersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupName => $composableBuilder(
    column: $table.groupName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverColor => $composableBuilder(
    column: $table.serverColor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authType => $composableBuilder(
    column: $table.authType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authKeyAlias => $composableBuilder(
    column: $table.authKeyAlias,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authPassword => $composableBuilder(
    column: $table.authPassword,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sudoPassword => $composableBuilder(
    column: $table.sudoPassword,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get authProfileId => $composableBuilder(
    column: $table.authProfileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get keepAlive => $composableBuilder(
    column: $table.keepAlive,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get sshCompression => $composableBuilder(
    column: $table.sshCompression,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get persistentSession => $composableBuilder(
    column: $table.persistentSession,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get proxyCommand => $composableBuilder(
    column: $table.proxyCommand,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get proxyType => $composableBuilder(
    column: $table.proxyType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get proxyHost => $composableBuilder(
    column: $table.proxyHost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get proxyPort => $composableBuilder(
    column: $table.proxyPort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get proxyUser => $composableBuilder(
    column: $table.proxyUser,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get proxyPassword => $composableBuilder(
    column: $table.proxyPassword,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get proxyKeyAlias => $composableBuilder(
    column: $table.proxyKeyAlias,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get agentForwarding => $composableBuilder(
    column: $table.agentForwarding,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get healthScore => $composableBuilder(
    column: $table.healthScore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastLatency => $composableBuilder(
    column: $table.lastLatency,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authStatus => $composableBuilder(
    column: $table.authStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authError => $composableBuilder(
    column: $table.authError,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ServersTableAnnotationComposer
    extends Composer<_$AppDatabase, $ServersTable> {
  $$ServersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get host =>
      $composableBuilder(column: $table.host, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get groupName =>
      $composableBuilder(column: $table.groupName, builder: (column) => column);

  GeneratedColumn<String> get serverColor => $composableBuilder(
    column: $table.serverColor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get authType =>
      $composableBuilder(column: $table.authType, builder: (column) => column);

  GeneratedColumn<String> get authKeyAlias => $composableBuilder(
    column: $table.authKeyAlias,
    builder: (column) => column,
  );

  GeneratedColumn<String> get authPassword => $composableBuilder(
    column: $table.authPassword,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sudoPassword => $composableBuilder(
    column: $table.sudoPassword,
    builder: (column) => column,
  );

  GeneratedColumn<int> get authProfileId => $composableBuilder(
    column: $table.authProfileId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<int> get keepAlive =>
      $composableBuilder(column: $table.keepAlive, builder: (column) => column);

  GeneratedColumn<bool> get sshCompression => $composableBuilder(
    column: $table.sshCompression,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get persistentSession => $composableBuilder(
    column: $table.persistentSession,
    builder: (column) => column,
  );

  GeneratedColumn<String> get proxyCommand => $composableBuilder(
    column: $table.proxyCommand,
    builder: (column) => column,
  );

  GeneratedColumn<String> get proxyType =>
      $composableBuilder(column: $table.proxyType, builder: (column) => column);

  GeneratedColumn<String> get proxyHost =>
      $composableBuilder(column: $table.proxyHost, builder: (column) => column);

  GeneratedColumn<int> get proxyPort =>
      $composableBuilder(column: $table.proxyPort, builder: (column) => column);

  GeneratedColumn<String> get proxyUser =>
      $composableBuilder(column: $table.proxyUser, builder: (column) => column);

  GeneratedColumn<String> get proxyPassword => $composableBuilder(
    column: $table.proxyPassword,
    builder: (column) => column,
  );

  GeneratedColumn<String> get proxyKeyAlias => $composableBuilder(
    column: $table.proxyKeyAlias,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get agentForwarding => $composableBuilder(
    column: $table.agentForwarding,
    builder: (column) => column,
  );

  GeneratedColumn<int> get healthScore => $composableBuilder(
    column: $table.healthScore,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastLatency => $composableBuilder(
    column: $table.lastLatency,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get authStatus => $composableBuilder(
    column: $table.authStatus,
    builder: (column) => column,
  );

  GeneratedColumn<String> get authError =>
      $composableBuilder(column: $table.authError, builder: (column) => column);
}

class $$ServersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ServersTable,
          Server,
          $$ServersTableFilterComposer,
          $$ServersTableOrderingComposer,
          $$ServersTableAnnotationComposer,
          $$ServersTableCreateCompanionBuilder,
          $$ServersTableUpdateCompanionBuilder,
          (Server, BaseReferences<_$AppDatabase, $ServersTable, Server>),
          Server,
          PrefetchHooks Function()
        > {
  $$ServersTableTableManager(_$AppDatabase db, $ServersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ServersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ServersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ServersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> host = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String?> groupName = const Value.absent(),
                Value<String> serverColor = const Value.absent(),
                Value<String> authType = const Value.absent(),
                Value<String?> authKeyAlias = const Value.absent(),
                Value<String?> authPassword = const Value.absent(),
                Value<String> sudoPassword = const Value.absent(),
                Value<int?> authProfileId = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<int> keepAlive = const Value.absent(),
                Value<bool> sshCompression = const Value.absent(),
                Value<bool> persistentSession = const Value.absent(),
                Value<String> proxyCommand = const Value.absent(),
                Value<String> proxyType = const Value.absent(),
                Value<String> proxyHost = const Value.absent(),
                Value<int> proxyPort = const Value.absent(),
                Value<String> proxyUser = const Value.absent(),
                Value<String> proxyPassword = const Value.absent(),
                Value<String?> proxyKeyAlias = const Value.absent(),
                Value<bool> agentForwarding = const Value.absent(),
                Value<int> healthScore = const Value.absent(),
                Value<int> lastLatency = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> authStatus = const Value.absent(),
                Value<String?> authError = const Value.absent(),
              }) => ServersCompanion(
                id: id,
                name: name,
                host: host,
                port: port,
                username: username,
                groupName: groupName,
                serverColor: serverColor,
                authType: authType,
                authKeyAlias: authKeyAlias,
                authPassword: authPassword,
                sudoPassword: sudoPassword,
                authProfileId: authProfileId,
                notes: notes,
                keepAlive: keepAlive,
                sshCompression: sshCompression,
                persistentSession: persistentSession,
                proxyCommand: proxyCommand,
                proxyType: proxyType,
                proxyHost: proxyHost,
                proxyPort: proxyPort,
                proxyUser: proxyUser,
                proxyPassword: proxyPassword,
                proxyKeyAlias: proxyKeyAlias,
                agentForwarding: agentForwarding,
                healthScore: healthScore,
                lastLatency: lastLatency,
                status: status,
                authStatus: authStatus,
                authError: authError,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                required String host,
                Value<int> port = const Value.absent(),
                required String username,
                Value<String?> groupName = const Value.absent(),
                Value<String> serverColor = const Value.absent(),
                Value<String> authType = const Value.absent(),
                Value<String?> authKeyAlias = const Value.absent(),
                Value<String?> authPassword = const Value.absent(),
                Value<String> sudoPassword = const Value.absent(),
                Value<int?> authProfileId = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<int> keepAlive = const Value.absent(),
                Value<bool> sshCompression = const Value.absent(),
                Value<bool> persistentSession = const Value.absent(),
                Value<String> proxyCommand = const Value.absent(),
                Value<String> proxyType = const Value.absent(),
                Value<String> proxyHost = const Value.absent(),
                Value<int> proxyPort = const Value.absent(),
                Value<String> proxyUser = const Value.absent(),
                Value<String> proxyPassword = const Value.absent(),
                Value<String?> proxyKeyAlias = const Value.absent(),
                Value<bool> agentForwarding = const Value.absent(),
                Value<int> healthScore = const Value.absent(),
                Value<int> lastLatency = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> authStatus = const Value.absent(),
                Value<String?> authError = const Value.absent(),
              }) => ServersCompanion.insert(
                id: id,
                name: name,
                host: host,
                port: port,
                username: username,
                groupName: groupName,
                serverColor: serverColor,
                authType: authType,
                authKeyAlias: authKeyAlias,
                authPassword: authPassword,
                sudoPassword: sudoPassword,
                authProfileId: authProfileId,
                notes: notes,
                keepAlive: keepAlive,
                sshCompression: sshCompression,
                persistentSession: persistentSession,
                proxyCommand: proxyCommand,
                proxyType: proxyType,
                proxyHost: proxyHost,
                proxyPort: proxyPort,
                proxyUser: proxyUser,
                proxyPassword: proxyPassword,
                proxyKeyAlias: proxyKeyAlias,
                agentForwarding: agentForwarding,
                healthScore: healthScore,
                lastLatency: lastLatency,
                status: status,
                authStatus: authStatus,
                authError: authError,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ServersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ServersTable,
      Server,
      $$ServersTableFilterComposer,
      $$ServersTableOrderingComposer,
      $$ServersTableAnnotationComposer,
      $$ServersTableCreateCompanionBuilder,
      $$ServersTableUpdateCompanionBuilder,
      (Server, BaseReferences<_$AppDatabase, $ServersTable, Server>),
      Server,
      PrefetchHooks Function()
    >;
typedef $$MetricHistoryTableCreateCompanionBuilder =
    MetricHistoryCompanion Function({
      Value<int> id,
      required int serverId,
      required int timestamp,
      required double cpuUsage,
      required double ramUsage,
      required double diskUsage,
      required int latency,
      required double networkIn,
      required double networkOut,
      Value<double?> cpuTemperatureC,
    });
typedef $$MetricHistoryTableUpdateCompanionBuilder =
    MetricHistoryCompanion Function({
      Value<int> id,
      Value<int> serverId,
      Value<int> timestamp,
      Value<double> cpuUsage,
      Value<double> ramUsage,
      Value<double> diskUsage,
      Value<int> latency,
      Value<double> networkIn,
      Value<double> networkOut,
      Value<double?> cpuTemperatureC,
    });

class $$MetricHistoryTableFilterComposer
    extends Composer<_$AppDatabase, $MetricHistoryTable> {
  $$MetricHistoryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cpuUsage => $composableBuilder(
    column: $table.cpuUsage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get ramUsage => $composableBuilder(
    column: $table.ramUsage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get diskUsage => $composableBuilder(
    column: $table.diskUsage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get latency => $composableBuilder(
    column: $table.latency,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get networkIn => $composableBuilder(
    column: $table.networkIn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get networkOut => $composableBuilder(
    column: $table.networkOut,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cpuTemperatureC => $composableBuilder(
    column: $table.cpuTemperatureC,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MetricHistoryTableOrderingComposer
    extends Composer<_$AppDatabase, $MetricHistoryTable> {
  $$MetricHistoryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cpuUsage => $composableBuilder(
    column: $table.cpuUsage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get ramUsage => $composableBuilder(
    column: $table.ramUsage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get diskUsage => $composableBuilder(
    column: $table.diskUsage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get latency => $composableBuilder(
    column: $table.latency,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get networkIn => $composableBuilder(
    column: $table.networkIn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get networkOut => $composableBuilder(
    column: $table.networkOut,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cpuTemperatureC => $composableBuilder(
    column: $table.cpuTemperatureC,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MetricHistoryTableAnnotationComposer
    extends Composer<_$AppDatabase, $MetricHistoryTable> {
  $$MetricHistoryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<int> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<double> get cpuUsage =>
      $composableBuilder(column: $table.cpuUsage, builder: (column) => column);

  GeneratedColumn<double> get ramUsage =>
      $composableBuilder(column: $table.ramUsage, builder: (column) => column);

  GeneratedColumn<double> get diskUsage =>
      $composableBuilder(column: $table.diskUsage, builder: (column) => column);

  GeneratedColumn<int> get latency =>
      $composableBuilder(column: $table.latency, builder: (column) => column);

  GeneratedColumn<double> get networkIn =>
      $composableBuilder(column: $table.networkIn, builder: (column) => column);

  GeneratedColumn<double> get networkOut => $composableBuilder(
    column: $table.networkOut,
    builder: (column) => column,
  );

  GeneratedColumn<double> get cpuTemperatureC => $composableBuilder(
    column: $table.cpuTemperatureC,
    builder: (column) => column,
  );
}

class $$MetricHistoryTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MetricHistoryTable,
          MetricHistoryRow,
          $$MetricHistoryTableFilterComposer,
          $$MetricHistoryTableOrderingComposer,
          $$MetricHistoryTableAnnotationComposer,
          $$MetricHistoryTableCreateCompanionBuilder,
          $$MetricHistoryTableUpdateCompanionBuilder,
          (
            MetricHistoryRow,
            BaseReferences<
              _$AppDatabase,
              $MetricHistoryTable,
              MetricHistoryRow
            >,
          ),
          MetricHistoryRow,
          PrefetchHooks Function()
        > {
  $$MetricHistoryTableTableManager(_$AppDatabase db, $MetricHistoryTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MetricHistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MetricHistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MetricHistoryTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> serverId = const Value.absent(),
                Value<int> timestamp = const Value.absent(),
                Value<double> cpuUsage = const Value.absent(),
                Value<double> ramUsage = const Value.absent(),
                Value<double> diskUsage = const Value.absent(),
                Value<int> latency = const Value.absent(),
                Value<double> networkIn = const Value.absent(),
                Value<double> networkOut = const Value.absent(),
                Value<double?> cpuTemperatureC = const Value.absent(),
              }) => MetricHistoryCompanion(
                id: id,
                serverId: serverId,
                timestamp: timestamp,
                cpuUsage: cpuUsage,
                ramUsage: ramUsage,
                diskUsage: diskUsage,
                latency: latency,
                networkIn: networkIn,
                networkOut: networkOut,
                cpuTemperatureC: cpuTemperatureC,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int serverId,
                required int timestamp,
                required double cpuUsage,
                required double ramUsage,
                required double diskUsage,
                required int latency,
                required double networkIn,
                required double networkOut,
                Value<double?> cpuTemperatureC = const Value.absent(),
              }) => MetricHistoryCompanion.insert(
                id: id,
                serverId: serverId,
                timestamp: timestamp,
                cpuUsage: cpuUsage,
                ramUsage: ramUsage,
                diskUsage: diskUsage,
                latency: latency,
                networkIn: networkIn,
                networkOut: networkOut,
                cpuTemperatureC: cpuTemperatureC,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MetricHistoryTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MetricHistoryTable,
      MetricHistoryRow,
      $$MetricHistoryTableFilterComposer,
      $$MetricHistoryTableOrderingComposer,
      $$MetricHistoryTableAnnotationComposer,
      $$MetricHistoryTableCreateCompanionBuilder,
      $$MetricHistoryTableUpdateCompanionBuilder,
      (
        MetricHistoryRow,
        BaseReferences<_$AppDatabase, $MetricHistoryTable, MetricHistoryRow>,
      ),
      MetricHistoryRow,
      PrefetchHooks Function()
    >;
typedef $$SshKeysTableCreateCompanionBuilder =
    SshKeysCompanion Function({
      Value<int> id,
      required String alias,
      required String keyType,
      required String privateKey,
      required String publicKey,
      required String fingerprint,
    });
typedef $$SshKeysTableUpdateCompanionBuilder =
    SshKeysCompanion Function({
      Value<int> id,
      Value<String> alias,
      Value<String> keyType,
      Value<String> privateKey,
      Value<String> publicKey,
      Value<String> fingerprint,
    });

class $$SshKeysTableFilterComposer
    extends Composer<_$AppDatabase, $SshKeysTable> {
  $$SshKeysTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get alias => $composableBuilder(
    column: $table.alias,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get keyType => $composableBuilder(
    column: $table.keyType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get privateKey => $composableBuilder(
    column: $table.privateKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get publicKey => $composableBuilder(
    column: $table.publicKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SshKeysTableOrderingComposer
    extends Composer<_$AppDatabase, $SshKeysTable> {
  $$SshKeysTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get alias => $composableBuilder(
    column: $table.alias,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get keyType => $composableBuilder(
    column: $table.keyType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get privateKey => $composableBuilder(
    column: $table.privateKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get publicKey => $composableBuilder(
    column: $table.publicKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SshKeysTableAnnotationComposer
    extends Composer<_$AppDatabase, $SshKeysTable> {
  $$SshKeysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get alias =>
      $composableBuilder(column: $table.alias, builder: (column) => column);

  GeneratedColumn<String> get keyType =>
      $composableBuilder(column: $table.keyType, builder: (column) => column);

  GeneratedColumn<String> get privateKey => $composableBuilder(
    column: $table.privateKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get publicKey =>
      $composableBuilder(column: $table.publicKey, builder: (column) => column);

  GeneratedColumn<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => column,
  );
}

class $$SshKeysTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SshKeysTable,
          SshKey,
          $$SshKeysTableFilterComposer,
          $$SshKeysTableOrderingComposer,
          $$SshKeysTableAnnotationComposer,
          $$SshKeysTableCreateCompanionBuilder,
          $$SshKeysTableUpdateCompanionBuilder,
          (SshKey, BaseReferences<_$AppDatabase, $SshKeysTable, SshKey>),
          SshKey,
          PrefetchHooks Function()
        > {
  $$SshKeysTableTableManager(_$AppDatabase db, $SshKeysTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SshKeysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SshKeysTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SshKeysTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> alias = const Value.absent(),
                Value<String> keyType = const Value.absent(),
                Value<String> privateKey = const Value.absent(),
                Value<String> publicKey = const Value.absent(),
                Value<String> fingerprint = const Value.absent(),
              }) => SshKeysCompanion(
                id: id,
                alias: alias,
                keyType: keyType,
                privateKey: privateKey,
                publicKey: publicKey,
                fingerprint: fingerprint,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String alias,
                required String keyType,
                required String privateKey,
                required String publicKey,
                required String fingerprint,
              }) => SshKeysCompanion.insert(
                id: id,
                alias: alias,
                keyType: keyType,
                privateKey: privateKey,
                publicKey: publicKey,
                fingerprint: fingerprint,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SshKeysTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SshKeysTable,
      SshKey,
      $$SshKeysTableFilterComposer,
      $$SshKeysTableOrderingComposer,
      $$SshKeysTableAnnotationComposer,
      $$SshKeysTableCreateCompanionBuilder,
      $$SshKeysTableUpdateCompanionBuilder,
      (SshKey, BaseReferences<_$AppDatabase, $SshKeysTable, SshKey>),
      SshKey,
      PrefetchHooks Function()
    >;
typedef $$CredentialProfilesTableCreateCompanionBuilder =
    CredentialProfilesCompanion Function({
      Value<int> id,
      required String profileName,
      required String username,
      required String authType,
      Value<String?> password,
      Value<String?> keyAlias,
      Value<String> groupName,
    });
typedef $$CredentialProfilesTableUpdateCompanionBuilder =
    CredentialProfilesCompanion Function({
      Value<int> id,
      Value<String> profileName,
      Value<String> username,
      Value<String> authType,
      Value<String?> password,
      Value<String?> keyAlias,
      Value<String> groupName,
    });

class $$CredentialProfilesTableFilterComposer
    extends Composer<_$AppDatabase, $CredentialProfilesTable> {
  $$CredentialProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileName => $composableBuilder(
    column: $table.profileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authType => $composableBuilder(
    column: $table.authType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get password => $composableBuilder(
    column: $table.password,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get keyAlias => $composableBuilder(
    column: $table.keyAlias,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupName => $composableBuilder(
    column: $table.groupName,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CredentialProfilesTableOrderingComposer
    extends Composer<_$AppDatabase, $CredentialProfilesTable> {
  $$CredentialProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileName => $composableBuilder(
    column: $table.profileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authType => $composableBuilder(
    column: $table.authType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get password => $composableBuilder(
    column: $table.password,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get keyAlias => $composableBuilder(
    column: $table.keyAlias,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupName => $composableBuilder(
    column: $table.groupName,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CredentialProfilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CredentialProfilesTable> {
  $$CredentialProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileName => $composableBuilder(
    column: $table.profileName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get authType =>
      $composableBuilder(column: $table.authType, builder: (column) => column);

  GeneratedColumn<String> get password =>
      $composableBuilder(column: $table.password, builder: (column) => column);

  GeneratedColumn<String> get keyAlias =>
      $composableBuilder(column: $table.keyAlias, builder: (column) => column);

  GeneratedColumn<String> get groupName =>
      $composableBuilder(column: $table.groupName, builder: (column) => column);
}

class $$CredentialProfilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CredentialProfilesTable,
          CredentialProfile,
          $$CredentialProfilesTableFilterComposer,
          $$CredentialProfilesTableOrderingComposer,
          $$CredentialProfilesTableAnnotationComposer,
          $$CredentialProfilesTableCreateCompanionBuilder,
          $$CredentialProfilesTableUpdateCompanionBuilder,
          (
            CredentialProfile,
            BaseReferences<
              _$AppDatabase,
              $CredentialProfilesTable,
              CredentialProfile
            >,
          ),
          CredentialProfile,
          PrefetchHooks Function()
        > {
  $$CredentialProfilesTableTableManager(
    _$AppDatabase db,
    $CredentialProfilesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CredentialProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CredentialProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CredentialProfilesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> profileName = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> authType = const Value.absent(),
                Value<String?> password = const Value.absent(),
                Value<String?> keyAlias = const Value.absent(),
                Value<String> groupName = const Value.absent(),
              }) => CredentialProfilesCompanion(
                id: id,
                profileName: profileName,
                username: username,
                authType: authType,
                password: password,
                keyAlias: keyAlias,
                groupName: groupName,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String profileName,
                required String username,
                required String authType,
                Value<String?> password = const Value.absent(),
                Value<String?> keyAlias = const Value.absent(),
                Value<String> groupName = const Value.absent(),
              }) => CredentialProfilesCompanion.insert(
                id: id,
                profileName: profileName,
                username: username,
                authType: authType,
                password: password,
                keyAlias: keyAlias,
                groupName: groupName,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CredentialProfilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CredentialProfilesTable,
      CredentialProfile,
      $$CredentialProfilesTableFilterComposer,
      $$CredentialProfilesTableOrderingComposer,
      $$CredentialProfilesTableAnnotationComposer,
      $$CredentialProfilesTableCreateCompanionBuilder,
      $$CredentialProfilesTableUpdateCompanionBuilder,
      (
        CredentialProfile,
        BaseReferences<
          _$AppDatabase,
          $CredentialProfilesTable,
          CredentialProfile
        >,
      ),
      CredentialProfile,
      PrefetchHooks Function()
    >;
typedef $$AlertRulesTableCreateCompanionBuilder =
    AlertRulesCompanion Function({
      Value<int> id,
      required int serverId,
      required String metricName,
      Value<String> mountPoint,
      required double thresholdValue,
      required String severity,
      Value<String> triggerWindow,
      Value<bool> enabled,
      Value<String> notes,
      Value<String?> presetKey,
    });
typedef $$AlertRulesTableUpdateCompanionBuilder =
    AlertRulesCompanion Function({
      Value<int> id,
      Value<int> serverId,
      Value<String> metricName,
      Value<String> mountPoint,
      Value<double> thresholdValue,
      Value<String> severity,
      Value<String> triggerWindow,
      Value<bool> enabled,
      Value<String> notes,
      Value<String?> presetKey,
    });

class $$AlertRulesTableFilterComposer
    extends Composer<_$AppDatabase, $AlertRulesTable> {
  $$AlertRulesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metricName => $composableBuilder(
    column: $table.metricName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mountPoint => $composableBuilder(
    column: $table.mountPoint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get thresholdValue => $composableBuilder(
    column: $table.thresholdValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get triggerWindow => $composableBuilder(
    column: $table.triggerWindow,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get presetKey => $composableBuilder(
    column: $table.presetKey,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AlertRulesTableOrderingComposer
    extends Composer<_$AppDatabase, $AlertRulesTable> {
  $$AlertRulesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metricName => $composableBuilder(
    column: $table.metricName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mountPoint => $composableBuilder(
    column: $table.mountPoint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get thresholdValue => $composableBuilder(
    column: $table.thresholdValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get triggerWindow => $composableBuilder(
    column: $table.triggerWindow,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get presetKey => $composableBuilder(
    column: $table.presetKey,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AlertRulesTableAnnotationComposer
    extends Composer<_$AppDatabase, $AlertRulesTable> {
  $$AlertRulesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get metricName => $composableBuilder(
    column: $table.metricName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mountPoint => $composableBuilder(
    column: $table.mountPoint,
    builder: (column) => column,
  );

  GeneratedColumn<double> get thresholdValue => $composableBuilder(
    column: $table.thresholdValue,
    builder: (column) => column,
  );

  GeneratedColumn<String> get severity =>
      $composableBuilder(column: $table.severity, builder: (column) => column);

  GeneratedColumn<String> get triggerWindow => $composableBuilder(
    column: $table.triggerWindow,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get presetKey =>
      $composableBuilder(column: $table.presetKey, builder: (column) => column);
}

class $$AlertRulesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AlertRulesTable,
          AlertRule,
          $$AlertRulesTableFilterComposer,
          $$AlertRulesTableOrderingComposer,
          $$AlertRulesTableAnnotationComposer,
          $$AlertRulesTableCreateCompanionBuilder,
          $$AlertRulesTableUpdateCompanionBuilder,
          (
            AlertRule,
            BaseReferences<_$AppDatabase, $AlertRulesTable, AlertRule>,
          ),
          AlertRule,
          PrefetchHooks Function()
        > {
  $$AlertRulesTableTableManager(_$AppDatabase db, $AlertRulesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AlertRulesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AlertRulesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AlertRulesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> serverId = const Value.absent(),
                Value<String> metricName = const Value.absent(),
                Value<String> mountPoint = const Value.absent(),
                Value<double> thresholdValue = const Value.absent(),
                Value<String> severity = const Value.absent(),
                Value<String> triggerWindow = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<String?> presetKey = const Value.absent(),
              }) => AlertRulesCompanion(
                id: id,
                serverId: serverId,
                metricName: metricName,
                mountPoint: mountPoint,
                thresholdValue: thresholdValue,
                severity: severity,
                triggerWindow: triggerWindow,
                enabled: enabled,
                notes: notes,
                presetKey: presetKey,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int serverId,
                required String metricName,
                Value<String> mountPoint = const Value.absent(),
                required double thresholdValue,
                required String severity,
                Value<String> triggerWindow = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<String?> presetKey = const Value.absent(),
              }) => AlertRulesCompanion.insert(
                id: id,
                serverId: serverId,
                metricName: metricName,
                mountPoint: mountPoint,
                thresholdValue: thresholdValue,
                severity: severity,
                triggerWindow: triggerWindow,
                enabled: enabled,
                notes: notes,
                presetKey: presetKey,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AlertRulesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AlertRulesTable,
      AlertRule,
      $$AlertRulesTableFilterComposer,
      $$AlertRulesTableOrderingComposer,
      $$AlertRulesTableAnnotationComposer,
      $$AlertRulesTableCreateCompanionBuilder,
      $$AlertRulesTableUpdateCompanionBuilder,
      (AlertRule, BaseReferences<_$AppDatabase, $AlertRulesTable, AlertRule>),
      AlertRule,
      PrefetchHooks Function()
    >;
typedef $$ActiveAlertsTableCreateCompanionBuilder =
    ActiveAlertsCompanion Function({
      Value<int> id,
      required int ruleId,
      required int serverId,
      required String metricName,
      required double currentValue,
      required double thresholdValue,
      required String severity,
      required int triggeredTime,
      Value<bool> acknowledged,
      Value<int> mutedUntil,
    });
typedef $$ActiveAlertsTableUpdateCompanionBuilder =
    ActiveAlertsCompanion Function({
      Value<int> id,
      Value<int> ruleId,
      Value<int> serverId,
      Value<String> metricName,
      Value<double> currentValue,
      Value<double> thresholdValue,
      Value<String> severity,
      Value<int> triggeredTime,
      Value<bool> acknowledged,
      Value<int> mutedUntil,
    });

class $$ActiveAlertsTableFilterComposer
    extends Composer<_$AppDatabase, $ActiveAlertsTable> {
  $$ActiveAlertsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ruleId => $composableBuilder(
    column: $table.ruleId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metricName => $composableBuilder(
    column: $table.metricName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get currentValue => $composableBuilder(
    column: $table.currentValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get thresholdValue => $composableBuilder(
    column: $table.thresholdValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get triggeredTime => $composableBuilder(
    column: $table.triggeredTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get acknowledged => $composableBuilder(
    column: $table.acknowledged,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mutedUntil => $composableBuilder(
    column: $table.mutedUntil,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ActiveAlertsTableOrderingComposer
    extends Composer<_$AppDatabase, $ActiveAlertsTable> {
  $$ActiveAlertsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ruleId => $composableBuilder(
    column: $table.ruleId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metricName => $composableBuilder(
    column: $table.metricName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get currentValue => $composableBuilder(
    column: $table.currentValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get thresholdValue => $composableBuilder(
    column: $table.thresholdValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get triggeredTime => $composableBuilder(
    column: $table.triggeredTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get acknowledged => $composableBuilder(
    column: $table.acknowledged,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mutedUntil => $composableBuilder(
    column: $table.mutedUntil,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ActiveAlertsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ActiveAlertsTable> {
  $$ActiveAlertsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get ruleId =>
      $composableBuilder(column: $table.ruleId, builder: (column) => column);

  GeneratedColumn<int> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get metricName => $composableBuilder(
    column: $table.metricName,
    builder: (column) => column,
  );

  GeneratedColumn<double> get currentValue => $composableBuilder(
    column: $table.currentValue,
    builder: (column) => column,
  );

  GeneratedColumn<double> get thresholdValue => $composableBuilder(
    column: $table.thresholdValue,
    builder: (column) => column,
  );

  GeneratedColumn<String> get severity =>
      $composableBuilder(column: $table.severity, builder: (column) => column);

  GeneratedColumn<int> get triggeredTime => $composableBuilder(
    column: $table.triggeredTime,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get acknowledged => $composableBuilder(
    column: $table.acknowledged,
    builder: (column) => column,
  );

  GeneratedColumn<int> get mutedUntil => $composableBuilder(
    column: $table.mutedUntil,
    builder: (column) => column,
  );
}

class $$ActiveAlertsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ActiveAlertsTable,
          ActiveAlert,
          $$ActiveAlertsTableFilterComposer,
          $$ActiveAlertsTableOrderingComposer,
          $$ActiveAlertsTableAnnotationComposer,
          $$ActiveAlertsTableCreateCompanionBuilder,
          $$ActiveAlertsTableUpdateCompanionBuilder,
          (
            ActiveAlert,
            BaseReferences<_$AppDatabase, $ActiveAlertsTable, ActiveAlert>,
          ),
          ActiveAlert,
          PrefetchHooks Function()
        > {
  $$ActiveAlertsTableTableManager(_$AppDatabase db, $ActiveAlertsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ActiveAlertsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ActiveAlertsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ActiveAlertsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> ruleId = const Value.absent(),
                Value<int> serverId = const Value.absent(),
                Value<String> metricName = const Value.absent(),
                Value<double> currentValue = const Value.absent(),
                Value<double> thresholdValue = const Value.absent(),
                Value<String> severity = const Value.absent(),
                Value<int> triggeredTime = const Value.absent(),
                Value<bool> acknowledged = const Value.absent(),
                Value<int> mutedUntil = const Value.absent(),
              }) => ActiveAlertsCompanion(
                id: id,
                ruleId: ruleId,
                serverId: serverId,
                metricName: metricName,
                currentValue: currentValue,
                thresholdValue: thresholdValue,
                severity: severity,
                triggeredTime: triggeredTime,
                acknowledged: acknowledged,
                mutedUntil: mutedUntil,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int ruleId,
                required int serverId,
                required String metricName,
                required double currentValue,
                required double thresholdValue,
                required String severity,
                required int triggeredTime,
                Value<bool> acknowledged = const Value.absent(),
                Value<int> mutedUntil = const Value.absent(),
              }) => ActiveAlertsCompanion.insert(
                id: id,
                ruleId: ruleId,
                serverId: serverId,
                metricName: metricName,
                currentValue: currentValue,
                thresholdValue: thresholdValue,
                severity: severity,
                triggeredTime: triggeredTime,
                acknowledged: acknowledged,
                mutedUntil: mutedUntil,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ActiveAlertsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ActiveAlertsTable,
      ActiveAlert,
      $$ActiveAlertsTableFilterComposer,
      $$ActiveAlertsTableOrderingComposer,
      $$ActiveAlertsTableAnnotationComposer,
      $$ActiveAlertsTableCreateCompanionBuilder,
      $$ActiveAlertsTableUpdateCompanionBuilder,
      (
        ActiveAlert,
        BaseReferences<_$AppDatabase, $ActiveAlertsTable, ActiveAlert>,
      ),
      ActiveAlert,
      PrefetchHooks Function()
    >;
typedef $$AlertHistoryTableCreateCompanionBuilder =
    AlertHistoryCompanion Function({
      Value<int> id,
      required int activeAlertId,
      required int serverId,
      required String serverName,
      required String metricName,
      required double currentValue,
      required double thresholdValue,
      required String severity,
      required int triggeredTime,
      required int historyTime,
      required String status,
    });
typedef $$AlertHistoryTableUpdateCompanionBuilder =
    AlertHistoryCompanion Function({
      Value<int> id,
      Value<int> activeAlertId,
      Value<int> serverId,
      Value<String> serverName,
      Value<String> metricName,
      Value<double> currentValue,
      Value<double> thresholdValue,
      Value<String> severity,
      Value<int> triggeredTime,
      Value<int> historyTime,
      Value<String> status,
    });

class $$AlertHistoryTableFilterComposer
    extends Composer<_$AppDatabase, $AlertHistoryTable> {
  $$AlertHistoryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get activeAlertId => $composableBuilder(
    column: $table.activeAlertId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverName => $composableBuilder(
    column: $table.serverName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metricName => $composableBuilder(
    column: $table.metricName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get currentValue => $composableBuilder(
    column: $table.currentValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get thresholdValue => $composableBuilder(
    column: $table.thresholdValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get triggeredTime => $composableBuilder(
    column: $table.triggeredTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get historyTime => $composableBuilder(
    column: $table.historyTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AlertHistoryTableOrderingComposer
    extends Composer<_$AppDatabase, $AlertHistoryTable> {
  $$AlertHistoryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get activeAlertId => $composableBuilder(
    column: $table.activeAlertId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverName => $composableBuilder(
    column: $table.serverName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metricName => $composableBuilder(
    column: $table.metricName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get currentValue => $composableBuilder(
    column: $table.currentValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get thresholdValue => $composableBuilder(
    column: $table.thresholdValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get triggeredTime => $composableBuilder(
    column: $table.triggeredTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get historyTime => $composableBuilder(
    column: $table.historyTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AlertHistoryTableAnnotationComposer
    extends Composer<_$AppDatabase, $AlertHistoryTable> {
  $$AlertHistoryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get activeAlertId => $composableBuilder(
    column: $table.activeAlertId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get serverName => $composableBuilder(
    column: $table.serverName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get metricName => $composableBuilder(
    column: $table.metricName,
    builder: (column) => column,
  );

  GeneratedColumn<double> get currentValue => $composableBuilder(
    column: $table.currentValue,
    builder: (column) => column,
  );

  GeneratedColumn<double> get thresholdValue => $composableBuilder(
    column: $table.thresholdValue,
    builder: (column) => column,
  );

  GeneratedColumn<String> get severity =>
      $composableBuilder(column: $table.severity, builder: (column) => column);

  GeneratedColumn<int> get triggeredTime => $composableBuilder(
    column: $table.triggeredTime,
    builder: (column) => column,
  );

  GeneratedColumn<int> get historyTime => $composableBuilder(
    column: $table.historyTime,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);
}

class $$AlertHistoryTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AlertHistoryTable,
          AlertHistoryRow,
          $$AlertHistoryTableFilterComposer,
          $$AlertHistoryTableOrderingComposer,
          $$AlertHistoryTableAnnotationComposer,
          $$AlertHistoryTableCreateCompanionBuilder,
          $$AlertHistoryTableUpdateCompanionBuilder,
          (
            AlertHistoryRow,
            BaseReferences<_$AppDatabase, $AlertHistoryTable, AlertHistoryRow>,
          ),
          AlertHistoryRow,
          PrefetchHooks Function()
        > {
  $$AlertHistoryTableTableManager(_$AppDatabase db, $AlertHistoryTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AlertHistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AlertHistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AlertHistoryTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> activeAlertId = const Value.absent(),
                Value<int> serverId = const Value.absent(),
                Value<String> serverName = const Value.absent(),
                Value<String> metricName = const Value.absent(),
                Value<double> currentValue = const Value.absent(),
                Value<double> thresholdValue = const Value.absent(),
                Value<String> severity = const Value.absent(),
                Value<int> triggeredTime = const Value.absent(),
                Value<int> historyTime = const Value.absent(),
                Value<String> status = const Value.absent(),
              }) => AlertHistoryCompanion(
                id: id,
                activeAlertId: activeAlertId,
                serverId: serverId,
                serverName: serverName,
                metricName: metricName,
                currentValue: currentValue,
                thresholdValue: thresholdValue,
                severity: severity,
                triggeredTime: triggeredTime,
                historyTime: historyTime,
                status: status,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int activeAlertId,
                required int serverId,
                required String serverName,
                required String metricName,
                required double currentValue,
                required double thresholdValue,
                required String severity,
                required int triggeredTime,
                required int historyTime,
                required String status,
              }) => AlertHistoryCompanion.insert(
                id: id,
                activeAlertId: activeAlertId,
                serverId: serverId,
                serverName: serverName,
                metricName: metricName,
                currentValue: currentValue,
                thresholdValue: thresholdValue,
                severity: severity,
                triggeredTime: triggeredTime,
                historyTime: historyTime,
                status: status,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AlertHistoryTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AlertHistoryTable,
      AlertHistoryRow,
      $$AlertHistoryTableFilterComposer,
      $$AlertHistoryTableOrderingComposer,
      $$AlertHistoryTableAnnotationComposer,
      $$AlertHistoryTableCreateCompanionBuilder,
      $$AlertHistoryTableUpdateCompanionBuilder,
      (
        AlertHistoryRow,
        BaseReferences<_$AppDatabase, $AlertHistoryTable, AlertHistoryRow>,
      ),
      AlertHistoryRow,
      PrefetchHooks Function()
    >;
typedef $$QuickScriptsTableCreateCompanionBuilder =
    QuickScriptsCompanion Function({
      Value<int> id,
      required String emoji,
      required String name,
      required String command,
      required String color,
      Value<bool> longRunning,
      Value<String> category,
      Value<int> sortOrder,
      Value<bool> availableForQuick,
      Value<bool> availableForFleet,
      Value<String> targetOs,
      Value<String> targetSystem,
      Value<String> notes,
      Value<String?> presetKey,
    });
typedef $$QuickScriptsTableUpdateCompanionBuilder =
    QuickScriptsCompanion Function({
      Value<int> id,
      Value<String> emoji,
      Value<String> name,
      Value<String> command,
      Value<String> color,
      Value<bool> longRunning,
      Value<String> category,
      Value<int> sortOrder,
      Value<bool> availableForQuick,
      Value<bool> availableForFleet,
      Value<String> targetOs,
      Value<String> targetSystem,
      Value<String> notes,
      Value<String?> presetKey,
    });

class $$QuickScriptsTableFilterComposer
    extends Composer<_$AppDatabase, $QuickScriptsTable> {
  $$QuickScriptsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get emoji => $composableBuilder(
    column: $table.emoji,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get command => $composableBuilder(
    column: $table.command,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get longRunning => $composableBuilder(
    column: $table.longRunning,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get availableForQuick => $composableBuilder(
    column: $table.availableForQuick,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get availableForFleet => $composableBuilder(
    column: $table.availableForFleet,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetOs => $composableBuilder(
    column: $table.targetOs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetSystem => $composableBuilder(
    column: $table.targetSystem,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get presetKey => $composableBuilder(
    column: $table.presetKey,
    builder: (column) => ColumnFilters(column),
  );
}

class $$QuickScriptsTableOrderingComposer
    extends Composer<_$AppDatabase, $QuickScriptsTable> {
  $$QuickScriptsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get emoji => $composableBuilder(
    column: $table.emoji,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get command => $composableBuilder(
    column: $table.command,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get longRunning => $composableBuilder(
    column: $table.longRunning,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get availableForQuick => $composableBuilder(
    column: $table.availableForQuick,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get availableForFleet => $composableBuilder(
    column: $table.availableForFleet,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetOs => $composableBuilder(
    column: $table.targetOs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetSystem => $composableBuilder(
    column: $table.targetSystem,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get presetKey => $composableBuilder(
    column: $table.presetKey,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$QuickScriptsTableAnnotationComposer
    extends Composer<_$AppDatabase, $QuickScriptsTable> {
  $$QuickScriptsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get emoji =>
      $composableBuilder(column: $table.emoji, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get command =>
      $composableBuilder(column: $table.command, builder: (column) => column);

  GeneratedColumn<String> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<bool> get longRunning => $composableBuilder(
    column: $table.longRunning,
    builder: (column) => column,
  );

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<bool> get availableForQuick => $composableBuilder(
    column: $table.availableForQuick,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get availableForFleet => $composableBuilder(
    column: $table.availableForFleet,
    builder: (column) => column,
  );

  GeneratedColumn<String> get targetOs =>
      $composableBuilder(column: $table.targetOs, builder: (column) => column);

  GeneratedColumn<String> get targetSystem => $composableBuilder(
    column: $table.targetSystem,
    builder: (column) => column,
  );

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get presetKey =>
      $composableBuilder(column: $table.presetKey, builder: (column) => column);
}

class $$QuickScriptsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $QuickScriptsTable,
          QuickScript,
          $$QuickScriptsTableFilterComposer,
          $$QuickScriptsTableOrderingComposer,
          $$QuickScriptsTableAnnotationComposer,
          $$QuickScriptsTableCreateCompanionBuilder,
          $$QuickScriptsTableUpdateCompanionBuilder,
          (
            QuickScript,
            BaseReferences<_$AppDatabase, $QuickScriptsTable, QuickScript>,
          ),
          QuickScript,
          PrefetchHooks Function()
        > {
  $$QuickScriptsTableTableManager(_$AppDatabase db, $QuickScriptsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$QuickScriptsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$QuickScriptsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$QuickScriptsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> emoji = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> command = const Value.absent(),
                Value<String> color = const Value.absent(),
                Value<bool> longRunning = const Value.absent(),
                Value<String> category = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<bool> availableForQuick = const Value.absent(),
                Value<bool> availableForFleet = const Value.absent(),
                Value<String> targetOs = const Value.absent(),
                Value<String> targetSystem = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<String?> presetKey = const Value.absent(),
              }) => QuickScriptsCompanion(
                id: id,
                emoji: emoji,
                name: name,
                command: command,
                color: color,
                longRunning: longRunning,
                category: category,
                sortOrder: sortOrder,
                availableForQuick: availableForQuick,
                availableForFleet: availableForFleet,
                targetOs: targetOs,
                targetSystem: targetSystem,
                notes: notes,
                presetKey: presetKey,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String emoji,
                required String name,
                required String command,
                required String color,
                Value<bool> longRunning = const Value.absent(),
                Value<String> category = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<bool> availableForQuick = const Value.absent(),
                Value<bool> availableForFleet = const Value.absent(),
                Value<String> targetOs = const Value.absent(),
                Value<String> targetSystem = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<String?> presetKey = const Value.absent(),
              }) => QuickScriptsCompanion.insert(
                id: id,
                emoji: emoji,
                name: name,
                command: command,
                color: color,
                longRunning: longRunning,
                category: category,
                sortOrder: sortOrder,
                availableForQuick: availableForQuick,
                availableForFleet: availableForFleet,
                targetOs: targetOs,
                targetSystem: targetSystem,
                notes: notes,
                presetKey: presetKey,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$QuickScriptsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $QuickScriptsTable,
      QuickScript,
      $$QuickScriptsTableFilterComposer,
      $$QuickScriptsTableOrderingComposer,
      $$QuickScriptsTableAnnotationComposer,
      $$QuickScriptsTableCreateCompanionBuilder,
      $$QuickScriptsTableUpdateCompanionBuilder,
      (
        QuickScript,
        BaseReferences<_$AppDatabase, $QuickScriptsTable, QuickScript>,
      ),
      QuickScript,
      PrefetchHooks Function()
    >;
typedef $$WolTargetsTableCreateCompanionBuilder =
    WolTargetsCompanion Function({
      Value<int> id,
      required String name,
      required String macAddress,
      Value<String> broadcastIp,
      Value<String> ipAddress,
      Value<int> port,
      Value<String> notes,
      Value<int> lastWokenTime,
    });
typedef $$WolTargetsTableUpdateCompanionBuilder =
    WolTargetsCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<String> macAddress,
      Value<String> broadcastIp,
      Value<String> ipAddress,
      Value<int> port,
      Value<String> notes,
      Value<int> lastWokenTime,
    });

class $$WolTargetsTableFilterComposer
    extends Composer<_$AppDatabase, $WolTargetsTable> {
  $$WolTargetsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get macAddress => $composableBuilder(
    column: $table.macAddress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get broadcastIp => $composableBuilder(
    column: $table.broadcastIp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ipAddress => $composableBuilder(
    column: $table.ipAddress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastWokenTime => $composableBuilder(
    column: $table.lastWokenTime,
    builder: (column) => ColumnFilters(column),
  );
}

class $$WolTargetsTableOrderingComposer
    extends Composer<_$AppDatabase, $WolTargetsTable> {
  $$WolTargetsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get macAddress => $composableBuilder(
    column: $table.macAddress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get broadcastIp => $composableBuilder(
    column: $table.broadcastIp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ipAddress => $composableBuilder(
    column: $table.ipAddress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastWokenTime => $composableBuilder(
    column: $table.lastWokenTime,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$WolTargetsTableAnnotationComposer
    extends Composer<_$AppDatabase, $WolTargetsTable> {
  $$WolTargetsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get macAddress => $composableBuilder(
    column: $table.macAddress,
    builder: (column) => column,
  );

  GeneratedColumn<String> get broadcastIp => $composableBuilder(
    column: $table.broadcastIp,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ipAddress =>
      $composableBuilder(column: $table.ipAddress, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<int> get lastWokenTime => $composableBuilder(
    column: $table.lastWokenTime,
    builder: (column) => column,
  );
}

class $$WolTargetsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $WolTargetsTable,
          WolTarget,
          $$WolTargetsTableFilterComposer,
          $$WolTargetsTableOrderingComposer,
          $$WolTargetsTableAnnotationComposer,
          $$WolTargetsTableCreateCompanionBuilder,
          $$WolTargetsTableUpdateCompanionBuilder,
          (
            WolTarget,
            BaseReferences<_$AppDatabase, $WolTargetsTable, WolTarget>,
          ),
          WolTarget,
          PrefetchHooks Function()
        > {
  $$WolTargetsTableTableManager(_$AppDatabase db, $WolTargetsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WolTargetsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WolTargetsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WolTargetsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> macAddress = const Value.absent(),
                Value<String> broadcastIp = const Value.absent(),
                Value<String> ipAddress = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<int> lastWokenTime = const Value.absent(),
              }) => WolTargetsCompanion(
                id: id,
                name: name,
                macAddress: macAddress,
                broadcastIp: broadcastIp,
                ipAddress: ipAddress,
                port: port,
                notes: notes,
                lastWokenTime: lastWokenTime,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                required String macAddress,
                Value<String> broadcastIp = const Value.absent(),
                Value<String> ipAddress = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<int> lastWokenTime = const Value.absent(),
              }) => WolTargetsCompanion.insert(
                id: id,
                name: name,
                macAddress: macAddress,
                broadcastIp: broadcastIp,
                ipAddress: ipAddress,
                port: port,
                notes: notes,
                lastWokenTime: lastWokenTime,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$WolTargetsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $WolTargetsTable,
      WolTarget,
      $$WolTargetsTableFilterComposer,
      $$WolTargetsTableOrderingComposer,
      $$WolTargetsTableAnnotationComposer,
      $$WolTargetsTableCreateCompanionBuilder,
      $$WolTargetsTableUpdateCompanionBuilder,
      (WolTarget, BaseReferences<_$AppDatabase, $WolTargetsTable, WolTarget>),
      WolTarget,
      PrefetchHooks Function()
    >;
typedef $$NetworkSharesTableCreateCompanionBuilder =
    NetworkSharesCompanion Function({
      Value<int> id,
      required String name,
      Value<String> protocol,
      required String address,
      Value<int> port,
      Value<String> sharePath,
      Value<String> workgroup,
      Value<String> username,
      Value<String> password,
      Value<int?> authProfileId,
      Value<bool> anonymous,
      Value<bool> useHttps,
      Value<String> notes,
      Value<int> lastChecked,
      Value<String> lastStatus,
    });
typedef $$NetworkSharesTableUpdateCompanionBuilder =
    NetworkSharesCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<String> protocol,
      Value<String> address,
      Value<int> port,
      Value<String> sharePath,
      Value<String> workgroup,
      Value<String> username,
      Value<String> password,
      Value<int?> authProfileId,
      Value<bool> anonymous,
      Value<bool> useHttps,
      Value<String> notes,
      Value<int> lastChecked,
      Value<String> lastStatus,
    });

class $$NetworkSharesTableFilterComposer
    extends Composer<_$AppDatabase, $NetworkSharesTable> {
  $$NetworkSharesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get protocol => $composableBuilder(
    column: $table.protocol,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sharePath => $composableBuilder(
    column: $table.sharePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get workgroup => $composableBuilder(
    column: $table.workgroup,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get password => $composableBuilder(
    column: $table.password,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get authProfileId => $composableBuilder(
    column: $table.authProfileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get anonymous => $composableBuilder(
    column: $table.anonymous,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get useHttps => $composableBuilder(
    column: $table.useHttps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastChecked => $composableBuilder(
    column: $table.lastChecked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastStatus => $composableBuilder(
    column: $table.lastStatus,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NetworkSharesTableOrderingComposer
    extends Composer<_$AppDatabase, $NetworkSharesTable> {
  $$NetworkSharesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get protocol => $composableBuilder(
    column: $table.protocol,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sharePath => $composableBuilder(
    column: $table.sharePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get workgroup => $composableBuilder(
    column: $table.workgroup,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get password => $composableBuilder(
    column: $table.password,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get authProfileId => $composableBuilder(
    column: $table.authProfileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get anonymous => $composableBuilder(
    column: $table.anonymous,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get useHttps => $composableBuilder(
    column: $table.useHttps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastChecked => $composableBuilder(
    column: $table.lastChecked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastStatus => $composableBuilder(
    column: $table.lastStatus,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NetworkSharesTableAnnotationComposer
    extends Composer<_$AppDatabase, $NetworkSharesTable> {
  $$NetworkSharesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get protocol =>
      $composableBuilder(column: $table.protocol, builder: (column) => column);

  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get sharePath =>
      $composableBuilder(column: $table.sharePath, builder: (column) => column);

  GeneratedColumn<String> get workgroup =>
      $composableBuilder(column: $table.workgroup, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get password =>
      $composableBuilder(column: $table.password, builder: (column) => column);

  GeneratedColumn<int> get authProfileId => $composableBuilder(
    column: $table.authProfileId,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get anonymous =>
      $composableBuilder(column: $table.anonymous, builder: (column) => column);

  GeneratedColumn<bool> get useHttps =>
      $composableBuilder(column: $table.useHttps, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<int> get lastChecked => $composableBuilder(
    column: $table.lastChecked,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastStatus => $composableBuilder(
    column: $table.lastStatus,
    builder: (column) => column,
  );
}

class $$NetworkSharesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $NetworkSharesTable,
          NetworkShare,
          $$NetworkSharesTableFilterComposer,
          $$NetworkSharesTableOrderingComposer,
          $$NetworkSharesTableAnnotationComposer,
          $$NetworkSharesTableCreateCompanionBuilder,
          $$NetworkSharesTableUpdateCompanionBuilder,
          (
            NetworkShare,
            BaseReferences<_$AppDatabase, $NetworkSharesTable, NetworkShare>,
          ),
          NetworkShare,
          PrefetchHooks Function()
        > {
  $$NetworkSharesTableTableManager(_$AppDatabase db, $NetworkSharesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NetworkSharesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NetworkSharesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NetworkSharesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> protocol = const Value.absent(),
                Value<String> address = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String> sharePath = const Value.absent(),
                Value<String> workgroup = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> password = const Value.absent(),
                Value<int?> authProfileId = const Value.absent(),
                Value<bool> anonymous = const Value.absent(),
                Value<bool> useHttps = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<int> lastChecked = const Value.absent(),
                Value<String> lastStatus = const Value.absent(),
              }) => NetworkSharesCompanion(
                id: id,
                name: name,
                protocol: protocol,
                address: address,
                port: port,
                sharePath: sharePath,
                workgroup: workgroup,
                username: username,
                password: password,
                authProfileId: authProfileId,
                anonymous: anonymous,
                useHttps: useHttps,
                notes: notes,
                lastChecked: lastChecked,
                lastStatus: lastStatus,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                Value<String> protocol = const Value.absent(),
                required String address,
                Value<int> port = const Value.absent(),
                Value<String> sharePath = const Value.absent(),
                Value<String> workgroup = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> password = const Value.absent(),
                Value<int?> authProfileId = const Value.absent(),
                Value<bool> anonymous = const Value.absent(),
                Value<bool> useHttps = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<int> lastChecked = const Value.absent(),
                Value<String> lastStatus = const Value.absent(),
              }) => NetworkSharesCompanion.insert(
                id: id,
                name: name,
                protocol: protocol,
                address: address,
                port: port,
                sharePath: sharePath,
                workgroup: workgroup,
                username: username,
                password: password,
                authProfileId: authProfileId,
                anonymous: anonymous,
                useHttps: useHttps,
                notes: notes,
                lastChecked: lastChecked,
                lastStatus: lastStatus,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NetworkSharesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $NetworkSharesTable,
      NetworkShare,
      $$NetworkSharesTableFilterComposer,
      $$NetworkSharesTableOrderingComposer,
      $$NetworkSharesTableAnnotationComposer,
      $$NetworkSharesTableCreateCompanionBuilder,
      $$NetworkSharesTableUpdateCompanionBuilder,
      (
        NetworkShare,
        BaseReferences<_$AppDatabase, $NetworkSharesTable, NetworkShare>,
      ),
      NetworkShare,
      PrefetchHooks Function()
    >;
typedef $$AppSettingsTableCreateCompanionBuilder =
    AppSettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$AppSettingsTableUpdateCompanionBuilder =
    AppSettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$AppSettingsTableFilterComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppSettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppSettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$AppSettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppSettingsTable,
          AppSetting,
          $$AppSettingsTableFilterComposer,
          $$AppSettingsTableOrderingComposer,
          $$AppSettingsTableAnnotationComposer,
          $$AppSettingsTableCreateCompanionBuilder,
          $$AppSettingsTableUpdateCompanionBuilder,
          (
            AppSetting,
            BaseReferences<_$AppDatabase, $AppSettingsTable, AppSetting>,
          ),
          AppSetting,
          PrefetchHooks Function()
        > {
  $$AppSettingsTableTableManager(_$AppDatabase db, $AppSettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AppSettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => AppSettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppSettingsTable,
      AppSetting,
      $$AppSettingsTableFilterComposer,
      $$AppSettingsTableOrderingComposer,
      $$AppSettingsTableAnnotationComposer,
      $$AppSettingsTableCreateCompanionBuilder,
      $$AppSettingsTableUpdateCompanionBuilder,
      (
        AppSetting,
        BaseReferences<_$AppDatabase, $AppSettingsTable, AppSetting>,
      ),
      AppSetting,
      PrefetchHooks Function()
    >;
typedef $$PersistentSessionsTableCreateCompanionBuilder =
    PersistentSessionsCompanion Function({
      required String tmuxName,
      required int serverId,
      required String serverName,
      required int createdAt,
      required int backgroundedAt,
      Value<int> rowid,
    });
typedef $$PersistentSessionsTableUpdateCompanionBuilder =
    PersistentSessionsCompanion Function({
      Value<String> tmuxName,
      Value<int> serverId,
      Value<String> serverName,
      Value<int> createdAt,
      Value<int> backgroundedAt,
      Value<int> rowid,
    });

class $$PersistentSessionsTableFilterComposer
    extends Composer<_$AppDatabase, $PersistentSessionsTable> {
  $$PersistentSessionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get tmuxName => $composableBuilder(
    column: $table.tmuxName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverName => $composableBuilder(
    column: $table.serverName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get backgroundedAt => $composableBuilder(
    column: $table.backgroundedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PersistentSessionsTableOrderingComposer
    extends Composer<_$AppDatabase, $PersistentSessionsTable> {
  $$PersistentSessionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get tmuxName => $composableBuilder(
    column: $table.tmuxName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverName => $composableBuilder(
    column: $table.serverName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get backgroundedAt => $composableBuilder(
    column: $table.backgroundedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PersistentSessionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PersistentSessionsTable> {
  $$PersistentSessionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get tmuxName =>
      $composableBuilder(column: $table.tmuxName, builder: (column) => column);

  GeneratedColumn<int> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get serverName => $composableBuilder(
    column: $table.serverName,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get backgroundedAt => $composableBuilder(
    column: $table.backgroundedAt,
    builder: (column) => column,
  );
}

class $$PersistentSessionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PersistentSessionsTable,
          PersistentSession,
          $$PersistentSessionsTableFilterComposer,
          $$PersistentSessionsTableOrderingComposer,
          $$PersistentSessionsTableAnnotationComposer,
          $$PersistentSessionsTableCreateCompanionBuilder,
          $$PersistentSessionsTableUpdateCompanionBuilder,
          (
            PersistentSession,
            BaseReferences<
              _$AppDatabase,
              $PersistentSessionsTable,
              PersistentSession
            >,
          ),
          PersistentSession,
          PrefetchHooks Function()
        > {
  $$PersistentSessionsTableTableManager(
    _$AppDatabase db,
    $PersistentSessionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PersistentSessionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PersistentSessionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PersistentSessionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> tmuxName = const Value.absent(),
                Value<int> serverId = const Value.absent(),
                Value<String> serverName = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> backgroundedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PersistentSessionsCompanion(
                tmuxName: tmuxName,
                serverId: serverId,
                serverName: serverName,
                createdAt: createdAt,
                backgroundedAt: backgroundedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String tmuxName,
                required int serverId,
                required String serverName,
                required int createdAt,
                required int backgroundedAt,
                Value<int> rowid = const Value.absent(),
              }) => PersistentSessionsCompanion.insert(
                tmuxName: tmuxName,
                serverId: serverId,
                serverName: serverName,
                createdAt: createdAt,
                backgroundedAt: backgroundedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PersistentSessionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PersistentSessionsTable,
      PersistentSession,
      $$PersistentSessionsTableFilterComposer,
      $$PersistentSessionsTableOrderingComposer,
      $$PersistentSessionsTableAnnotationComposer,
      $$PersistentSessionsTableCreateCompanionBuilder,
      $$PersistentSessionsTableUpdateCompanionBuilder,
      (
        PersistentSession,
        BaseReferences<
          _$AppDatabase,
          $PersistentSessionsTable,
          PersistentSession
        >,
      ),
      PersistentSession,
      PrefetchHooks Function()
    >;
typedef $$PortForwardsTableCreateCompanionBuilder =
    PortForwardsCompanion Function({
      Value<int> id,
      required int serverId,
      required String name,
      Value<String> kind,
      Value<String> bindHost,
      required int bindPort,
      Value<String> destHost,
      Value<int> destPort,
      Value<bool> autoStart,
    });
typedef $$PortForwardsTableUpdateCompanionBuilder =
    PortForwardsCompanion Function({
      Value<int> id,
      Value<int> serverId,
      Value<String> name,
      Value<String> kind,
      Value<String> bindHost,
      Value<int> bindPort,
      Value<String> destHost,
      Value<int> destPort,
      Value<bool> autoStart,
    });

class $$PortForwardsTableFilterComposer
    extends Composer<_$AppDatabase, $PortForwardsTable> {
  $$PortForwardsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bindHost => $composableBuilder(
    column: $table.bindHost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bindPort => $composableBuilder(
    column: $table.bindPort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get destHost => $composableBuilder(
    column: $table.destHost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get destPort => $composableBuilder(
    column: $table.destPort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get autoStart => $composableBuilder(
    column: $table.autoStart,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PortForwardsTableOrderingComposer
    extends Composer<_$AppDatabase, $PortForwardsTable> {
  $$PortForwardsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bindHost => $composableBuilder(
    column: $table.bindHost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bindPort => $composableBuilder(
    column: $table.bindPort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get destHost => $composableBuilder(
    column: $table.destHost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get destPort => $composableBuilder(
    column: $table.destPort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get autoStart => $composableBuilder(
    column: $table.autoStart,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PortForwardsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PortForwardsTable> {
  $$PortForwardsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get bindHost =>
      $composableBuilder(column: $table.bindHost, builder: (column) => column);

  GeneratedColumn<int> get bindPort =>
      $composableBuilder(column: $table.bindPort, builder: (column) => column);

  GeneratedColumn<String> get destHost =>
      $composableBuilder(column: $table.destHost, builder: (column) => column);

  GeneratedColumn<int> get destPort =>
      $composableBuilder(column: $table.destPort, builder: (column) => column);

  GeneratedColumn<bool> get autoStart =>
      $composableBuilder(column: $table.autoStart, builder: (column) => column);
}

class $$PortForwardsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PortForwardsTable,
          PortForward,
          $$PortForwardsTableFilterComposer,
          $$PortForwardsTableOrderingComposer,
          $$PortForwardsTableAnnotationComposer,
          $$PortForwardsTableCreateCompanionBuilder,
          $$PortForwardsTableUpdateCompanionBuilder,
          (
            PortForward,
            BaseReferences<_$AppDatabase, $PortForwardsTable, PortForward>,
          ),
          PortForward,
          PrefetchHooks Function()
        > {
  $$PortForwardsTableTableManager(_$AppDatabase db, $PortForwardsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PortForwardsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PortForwardsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PortForwardsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> serverId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> bindHost = const Value.absent(),
                Value<int> bindPort = const Value.absent(),
                Value<String> destHost = const Value.absent(),
                Value<int> destPort = const Value.absent(),
                Value<bool> autoStart = const Value.absent(),
              }) => PortForwardsCompanion(
                id: id,
                serverId: serverId,
                name: name,
                kind: kind,
                bindHost: bindHost,
                bindPort: bindPort,
                destHost: destHost,
                destPort: destPort,
                autoStart: autoStart,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int serverId,
                required String name,
                Value<String> kind = const Value.absent(),
                Value<String> bindHost = const Value.absent(),
                required int bindPort,
                Value<String> destHost = const Value.absent(),
                Value<int> destPort = const Value.absent(),
                Value<bool> autoStart = const Value.absent(),
              }) => PortForwardsCompanion.insert(
                id: id,
                serverId: serverId,
                name: name,
                kind: kind,
                bindHost: bindHost,
                bindPort: bindPort,
                destHost: destHost,
                destPort: destPort,
                autoStart: autoStart,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PortForwardsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PortForwardsTable,
      PortForward,
      $$PortForwardsTableFilterComposer,
      $$PortForwardsTableOrderingComposer,
      $$PortForwardsTableAnnotationComposer,
      $$PortForwardsTableCreateCompanionBuilder,
      $$PortForwardsTableUpdateCompanionBuilder,
      (
        PortForward,
        BaseReferences<_$AppDatabase, $PortForwardsTable, PortForward>,
      ),
      PortForward,
      PrefetchHooks Function()
    >;
typedef $$StackRegistryTableCreateCompanionBuilder =
    StackRegistryCompanion Function({
      Value<int> id,
      required int serverId,
      required String runtime,
      required String project,
      required String workingDir,
      required String configFiles,
      required int lastSeenAt,
    });
typedef $$StackRegistryTableUpdateCompanionBuilder =
    StackRegistryCompanion Function({
      Value<int> id,
      Value<int> serverId,
      Value<String> runtime,
      Value<String> project,
      Value<String> workingDir,
      Value<String> configFiles,
      Value<int> lastSeenAt,
    });

class $$StackRegistryTableFilterComposer
    extends Composer<_$AppDatabase, $StackRegistryTable> {
  $$StackRegistryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get runtime => $composableBuilder(
    column: $table.runtime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get project => $composableBuilder(
    column: $table.project,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get workingDir => $composableBuilder(
    column: $table.workingDir,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get configFiles => $composableBuilder(
    column: $table.configFiles,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StackRegistryTableOrderingComposer
    extends Composer<_$AppDatabase, $StackRegistryTable> {
  $$StackRegistryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get runtime => $composableBuilder(
    column: $table.runtime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get project => $composableBuilder(
    column: $table.project,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get workingDir => $composableBuilder(
    column: $table.workingDir,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get configFiles => $composableBuilder(
    column: $table.configFiles,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StackRegistryTableAnnotationComposer
    extends Composer<_$AppDatabase, $StackRegistryTable> {
  $$StackRegistryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get runtime =>
      $composableBuilder(column: $table.runtime, builder: (column) => column);

  GeneratedColumn<String> get project =>
      $composableBuilder(column: $table.project, builder: (column) => column);

  GeneratedColumn<String> get workingDir => $composableBuilder(
    column: $table.workingDir,
    builder: (column) => column,
  );

  GeneratedColumn<String> get configFiles => $composableBuilder(
    column: $table.configFiles,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => column,
  );
}

class $$StackRegistryTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $StackRegistryTable,
          StackRegistryRow,
          $$StackRegistryTableFilterComposer,
          $$StackRegistryTableOrderingComposer,
          $$StackRegistryTableAnnotationComposer,
          $$StackRegistryTableCreateCompanionBuilder,
          $$StackRegistryTableUpdateCompanionBuilder,
          (
            StackRegistryRow,
            BaseReferences<
              _$AppDatabase,
              $StackRegistryTable,
              StackRegistryRow
            >,
          ),
          StackRegistryRow,
          PrefetchHooks Function()
        > {
  $$StackRegistryTableTableManager(_$AppDatabase db, $StackRegistryTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StackRegistryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StackRegistryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StackRegistryTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> serverId = const Value.absent(),
                Value<String> runtime = const Value.absent(),
                Value<String> project = const Value.absent(),
                Value<String> workingDir = const Value.absent(),
                Value<String> configFiles = const Value.absent(),
                Value<int> lastSeenAt = const Value.absent(),
              }) => StackRegistryCompanion(
                id: id,
                serverId: serverId,
                runtime: runtime,
                project: project,
                workingDir: workingDir,
                configFiles: configFiles,
                lastSeenAt: lastSeenAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int serverId,
                required String runtime,
                required String project,
                required String workingDir,
                required String configFiles,
                required int lastSeenAt,
              }) => StackRegistryCompanion.insert(
                id: id,
                serverId: serverId,
                runtime: runtime,
                project: project,
                workingDir: workingDir,
                configFiles: configFiles,
                lastSeenAt: lastSeenAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StackRegistryTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $StackRegistryTable,
      StackRegistryRow,
      $$StackRegistryTableFilterComposer,
      $$StackRegistryTableOrderingComposer,
      $$StackRegistryTableAnnotationComposer,
      $$StackRegistryTableCreateCompanionBuilder,
      $$StackRegistryTableUpdateCompanionBuilder,
      (
        StackRegistryRow,
        BaseReferences<_$AppDatabase, $StackRegistryTable, StackRegistryRow>,
      ),
      StackRegistryRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ServersTableTableManager get servers =>
      $$ServersTableTableManager(_db, _db.servers);
  $$MetricHistoryTableTableManager get metricHistory =>
      $$MetricHistoryTableTableManager(_db, _db.metricHistory);
  $$SshKeysTableTableManager get sshKeys =>
      $$SshKeysTableTableManager(_db, _db.sshKeys);
  $$CredentialProfilesTableTableManager get credentialProfiles =>
      $$CredentialProfilesTableTableManager(_db, _db.credentialProfiles);
  $$AlertRulesTableTableManager get alertRules =>
      $$AlertRulesTableTableManager(_db, _db.alertRules);
  $$ActiveAlertsTableTableManager get activeAlerts =>
      $$ActiveAlertsTableTableManager(_db, _db.activeAlerts);
  $$AlertHistoryTableTableManager get alertHistory =>
      $$AlertHistoryTableTableManager(_db, _db.alertHistory);
  $$QuickScriptsTableTableManager get quickScripts =>
      $$QuickScriptsTableTableManager(_db, _db.quickScripts);
  $$WolTargetsTableTableManager get wolTargets =>
      $$WolTargetsTableTableManager(_db, _db.wolTargets);
  $$NetworkSharesTableTableManager get networkShares =>
      $$NetworkSharesTableTableManager(_db, _db.networkShares);
  $$AppSettingsTableTableManager get appSettings =>
      $$AppSettingsTableTableManager(_db, _db.appSettings);
  $$PersistentSessionsTableTableManager get persistentSessions =>
      $$PersistentSessionsTableTableManager(_db, _db.persistentSessions);
  $$PortForwardsTableTableManager get portForwards =>
      $$PortForwardsTableTableManager(_db, _db.portForwards);
  $$StackRegistryTableTableManager get stackRegistry =>
      $$StackRegistryTableTableManager(_db, _db.stackRegistry);
}
