import 'dart:async';
import 'dart:convert';

import 'package:crdt/crdt.dart';
import 'package:postgres/messages.dart';
import 'package:postgres/postgres.dart';
import 'package:stream_channel/stream_channel.dart';

import 'src/mutex.dart';
import 'src/sql_util.dart';

export 'package:crdt/crdt.dart';
export 'package:postgres/postgres.dart' show Endpoint, SslMode;

class PostgresCrdt extends Crdt {
  final String crdtTable;
  final Map<String, List<String>> _tableIndexes;
  final Connection _connection;
  final Connection _walConnection;

  /// Prevents executions from happening in the middle of a transaction.
  /// This is important since crdt transactions happen asynchronously as result
  /// of changes to the monitored tables.
  final _connectionMutex = Mutex();

  /// Prevents merged records from triggering change events.
  final _mergeTransactions = <int, DateTime>{};
  final _watches = <StreamController<Result>, _Query>{};

  List<String> get tables => _tableIndexes.keys.toList();

  static Future<PostgresCrdt> open(
    Endpoint endpoint, {
    String crdtTable = 'crdt',
    required List<String> tables,
    SslMode? sslMode,
  }) async {
    assert(tables.isNotEmpty);

    // Init source DB connection
    final channel = _ExposedChannel();
    final walConnection = await Connection.open(
      settings: ConnectionSettings(
        sslMode: sslMode,
        replicationMode: ReplicationMode.logical,
        queryMode: QueryMode.simple,
        transformer: channel,
      ),
      endpoint,
    );
    // Init crdt connection
    final connection = await Connection.open(
      settings: ConnectionSettings(sslMode: sslMode),
      endpoint,
    );

    // Get table indexes
    final tableMap = <String, List<String>>{};
    for (final table in tables) {
      tableMap[table] = (await connection.execute('''
        SELECT a.attname AS name
        FROM pg_class AS c
          JOIN pg_index AS i ON c.oid = i.indrelid AND i.indisprimary
          JOIN pg_attribute AS a ON c.oid = a.attrelid AND a.attnum = ANY(i.indkey)
        WHERE c.oid = '$table'::regclass
        ORDER BY a.attnum
      ''')).map((e) => e.first as String).toList();
    }

    // Create crdt table if necessary
    await connection.execute(r'''
      CREATE TABLE IF NOT EXISTS crdt (
        collection varchar(255) NOT NULL,
        id varchar(255) NOT NULL,
        hlc varchar(255) NOT NULL,
        modified varchar(255) NOT NULL,
        node_id varchar(255) GENERATED ALWAYS AS (SUBSTRING(hlc FROM 'Z-\d+-(.*)$')) STORED,
        PRIMARY KEY (collection, id)
      )
    ''');

    // Check if WAL publication exists, and recreate it if necessary
    final publicationTables = (await connection.execute(
      r'SELECT tablename FROM pg_publication_tables WHERE pubname = $1',
      parameters: ['crdt_publication'],
    )).map((e) => e.first as String).toSet();
    if (publicationTables.length != tables.length ||
        publicationTables.difference(tables.toSet()).isNotEmpty) {
      await walConnection.execute(
        'DROP PUBLICATION IF EXISTS crdt_publication',
      );
      await walConnection.execute(
        'CREATE PUBLICATION crdt_publication FOR TABLE ${tableMap.entries.map((e) => '${e.key} (${e.value.join(', ')})').join(', ')}',
      );
      await walConnection.execute(
        'DROP_REPLICATION_SLOT crdt_replication_slot WAIT',
      );
      await walConnection.execute(
        'CREATE_REPLICATION_SLOT crdt_replication_slot LOGICAL pgoutput',
      );
    }

    // Start monitoring changes
    final logPos = await _currentLsn(connection);
    await walConnection.execute('''
      START_REPLICATION SLOT crdt_replication_slot LOGICAL $logPos
      (proto_version '1', publication_names 'crdt_publication')
    ''');

    // Get canonical time
    final canonicalResult =
        (await connection.execute(
              'SELECT MAX(modified) AS hlc FROM $crdtTable',
            )).first.first
            as String?;
    final canonicalTime = canonicalResult == null
        ? Hlc.now(generateNodeId())
        : Hlc.parse(canonicalResult);

    return PostgresCrdt._(
      crdtTable,
      Map.unmodifiable(tableMap),
      connection,
      walConnection,
      await channel.stream,
      await channel.sink,
    )..canonicalTime = canonicalTime;
  }

  PostgresCrdt._(
    this.crdtTable,
    this._tableIndexes,
    this._connection,
    this._walConnection,
    Stream stream,
    StreamSink sink,
  ) {
    assert(_tableIndexes.isNotEmpty);

    List<_DbEvent>? events;
    stream.listen((msg) async {
      // Handle keep alive messages to keep the connection open
      switch (msg) {
        case PrimaryKeepAliveMessage _:
          if (msg.mustReply) {
            sink.add(
              CopyDataMessage(
                StandbyStatusUpdateMessage(
                  walWritePosition: msg.walEnd,
                ).asBytes(encoding: utf8),
              ),
            );
          }

        case XLogDataMessage dataMessage:
          switch (msg.data) {
            case BeginMessage data:
              // Ignore skipped transactions
              events = _mergeTransactions.containsKey(data.xid) ? null : [];
              // Cleanup known transactions
              final now = DateTime.now();
              _mergeTransactions.removeWhere(
                (key, value) =>
                    key == data.xid ||
                    value.difference(now) > const Duration(minutes: 1),
              );

            case InsertMessage _:
            case UpdateMessage _:
            case DeleteMessage _:
            case TruncateMessage _:
              events?.addAll(
                _DbEvent.fromMessage(
                  dataMessage.data as LogicalReplicationMessage,
                ),
              );

            case CommitMessage data:
              // Check if this transaction part of a merge
              if (events?.isNotEmpty ?? false) {
                // Generate record HLC by applying commit time
                final hlc = canonicalTime.increment(wallTime: data.commitTime);
                // Update crdt table
                await runTx((session) async {
                  for (final event in events!) {
                    // Ensure tables are known
                    await event._resolveTable(session);

                    if (event.isTruncate) {
                      await session.execute('''
                        UPDATE $crdtTable SET
                          hlc = '$hlc',
                          modified = '$hlc'
                        WHERE crdt.collection = '${event.table}'
                      ''');
                    } else {
                      await session.execute('''
                        INSERT INTO $crdtTable (collection, id, hlc, modified)
                          VALUES ('${event.table}', '${event.mergedId}', '$hlc', '$hlc')
                        ON CONFLICT (collection, id) DO
                          UPDATE SET
                            hlc = '$hlc',
                            modified = '$hlc'
                        WHERE excluded.hlc > crdt.hlc
                      ''');
                    }
                  }
                });
                // Update canonical time
                canonicalTime = hlc > canonicalTime ? hlc : canonicalTime;
                // Emit change events
                _emitQueries(events!.map((e) => e.table));
              }
          }

        case ErrorResponseMessage _:
          print('errr ${msg.fields.map((e) => e.text).join('. ')}');

        default:
          print(msg);
      }
    });
  }

  /// Clears out all CRDT records related to the specified collections and
  /// resyncs their data with the current canonical timestamp.
  ///
  /// Useful for when beginning monitoring an already existing database, or when
  /// there are structural changes to the tables that affect the indexes.
  ///
  /// Use with care, since resetting the HLCs will cause the local CRDT to "win"
  /// all collisions.
  Future<void> resetCrdt(Iterable<String> collections) async {
    assert(collections.toSet().difference(tables.toSet()).isEmpty);

    await runTx((session) async {
      for (final table in collections) {
        // Prepare the SQL statement that concatenates ids
        final concatenatedIds = _tableIndexes[table]!
            .map((column) => '$table.$column::varchar(255)')
            .join(" || '::' || ");

        // Delete all records in the specified collection
        await session.execute(r'DELETE FROM $crdtTable WHERE collection = $1');

        // Add CRDT records for all new items in the monitored tables
        await session.execute(
          '''
            INSERT INTO $crdtTable (collection, id, hlc, modified)
              SELECT \$1, $concatenatedIds, \$2, \$2, \$3
              FROM $table
                LEFT JOIN $crdtTable ON $concatenatedIds = $crdtTable.id
                  AND $crdtTable.collection = \$1
              WHERE $crdtTable.id IS NULL
            ON CONFLICT (collection, id) DO
              UPDATE SET
                hlc = \$2,
                modified = \$2,
          ''',
          parameters: [table, '$canonicalTime'],
        );
      }
    });
  }

  Future<void> close() async {
    await _walConnection.close();
    await _connection.close();
  }

  @override
  Future<Hlc?> getLastModified({
    String? onlyNodeId,
    String? exceptNodeId,
  }) async {
    assert(onlyNodeId == null || exceptNodeId == null);
    final whereStatement = onlyNodeId != null
        ? r'WHERE node_id = $1'
        : exceptNodeId != null
        ? r'WHERE node_id != $1'
        : '';
    final result = await execute(
      'SELECT max(modified) AS modified FROM $crdtTable $whereStatement',
      parameters: [
        if (onlyNodeId != null) onlyNodeId,
        if (exceptNodeId != null) exceptNodeId,
      ],
    );
    return Hlc.maybeParse(result.first.first as String?);
  }

  @override
  Future<void> merge(dynamic changeset) async {
    assert(changeset is Map<String, dynamic> || changeset is CrdtChangeset);
    if (changeset is Map<String, dynamic>) {
      changeset = CrdtChangeset.parse(changeset);
    }
    // Quit early if there's nothing to do
    if (changeset.recordCount == 0) return;
    // Validate changeset and highest hlc therein
    final highestHlc = validateChangeset(changeset);

    final affectedTables = <String>{};
    await runTx((session) async {
      // Avoid reacting to this transaction when writing to the data tables
      final txId =
          (await session.execute('SELECT txid_current()')).first.first as int;
      _mergeTransactions[txId] = DateTime.now();

      for (final entry in changeset.entries) {
        final table = entry.key;
        final records = entry.value as List<CrdtRecord>;
        assert(_tableIndexes.keys.contains(table));

        for (final record in records) {
          final crdtResult = await session.execute(
            '''
              INSERT INTO $crdtTable (collection, id, hlc, modified)
                VALUES (\$1, \$2, \$3, \$4)
              ON CONFLICT (collection, id) DO
                UPDATE SET
                  hlc = \$3,
                  modified = \$4
                WHERE excluded.hlc > $crdtTable.hlc
            ''',
            parameters: [table, record.id, '${record.hlc}', '$highestHlc'],
          );

          // Apply changes if the CRDT record was updated
          if (crdtResult.affectedRows > 0) {
            affectedTables.add(table);

            if (record.isDeleted) {
              var i = 1;
              final whereClause = _tableIndexes[table]!
                  .map((e) => '$e = \$${i++}')
                  .join(', ');
              await session.execute('''
                  DELETE FROM $table
                  WHERE $whereClause
                ''', parameters: record.id.split('::'));
            } else {
              final data = record.data!;
              final updateStatement = data.keys
                  .where((e) => !_tableIndexes[table]!.contains(e))
                  .map((e) => '$e = \$${data.keys.toList().indexOf(e) + 1}')
                  .join(',\n');
              await session.execute('''
                INSERT INTO $table (${data.keys.join(', ')})
                  VALUES (${List.generate(data.length, (i) => '\$${i + 1}').join(', ')})
                ON CONFLICT (${_tableIndexes[table]!.join(', ')}) DO
                  UPDATE SET $updateStatement
              ''', parameters: data.values.toList());
            }
          }
        }
      }
      // Update canonical time
      canonicalTime = highestHlc;
    });
    // Notify of changed tables
    _emitQueries(affectedTables);
  }

  @override
  Future<CrdtChangeset> getChangeset({
    Map<String, Map<String, Object?>?>? collectionFilter,
    String? onlyNodeId,
    String? exceptNodeId,
    Hlc? modifiedOn,
    Hlc? modifiedAfter,
  }) async {
    assert(
      collectionFilter == null ||
          collectionFilter.keys.toSet().difference(tables.toSet()).isEmpty,
      'Unrecognized table(s): ${collectionFilter.keys.toSet().difference(tables.toSet()).join(', ')}.',
    );
    assert(onlyNodeId == null || exceptNodeId == null);
    assert(modifiedOn == null || modifiedAfter == null);

    // Modified times use the local node id
    modifiedOn = modifiedOn?.apply(nodeId: nodeId);
    modifiedAfter = modifiedAfter?.apply(nodeId: nodeId);

    final changeset = <String, Iterable<Map<String, dynamic>>>{};
    for (final table in collectionFilter?.keys ?? tables) {
      final concatenatedIds = _tableIndexes[table]!
          .map((column) => '$table.$column::varchar(255)')
          .join(" || '::' || ");

      final filteredColumns = collectionFilter?[table];
      var i = 1;
      final whereClauses = [
        'WHERE $crdtTable.collection = \$${i++}',
        if (filteredColumns != null)
          ...filteredColumns.keys.map((e) => '$table.$e = \$${i++}'),
        if (onlyNodeId != null) 'node_id = \$${i++}',
        if (exceptNodeId != null) 'node_id != \$${i++}',
        if (modifiedOn != null) 'modified = \$${i++}',
        if (modifiedAfter != null) 'modified > \$${i++}',
      ].join('\n                AND ');

      changeset[table] =
          (await execute(
                '''
                  SELECT $crdtTable.id AS _id, $crdtTable.hlc AS _hlc, $table.*
                    FROM $crdtTable
                    LEFT JOIN $table ON $concatenatedIds = $crdtTable.id
                  $whereClauses
                ''',
                parameters: [
                  table,
                  if (filteredColumns != null) ...filteredColumns.values,
                  if (onlyNodeId != null) onlyNodeId,
                  if (exceptNodeId != null) exceptNodeId,
                  if (modifiedOn != null) '$modifiedOn',
                  if (modifiedAfter != null) '$modifiedAfter',
                ],
              ))
              .map((row) => row.toColumnMap())
              .map(
                (e) => {
                  'id': e['_id'],
                  'hlc': e['_hlc'],
                  'data': e[_tableIndexes[table]!.first] == null
                      ? null
                      : (e
                          ..remove('_id')
                          ..remove('_hlc')),
                },
              );
    }

    return CrdtChangeset.parse(changeset);
  }

  Future<Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
    QueryMode? queryMode,
    Duration? timeout,
  }) async {
    try {
      await _connectionMutex.acquire();
      return await _connection.execute(
        query,
        parameters: parameters,
        ignoreRows: ignoreRows,
        queryMode: queryMode,
        timeout: timeout,
      );
    } finally {
      _connectionMutex.release();
    }
  }

  Future<R> runTx<R>(
    Future<R> Function(TxSession session) fn, {
    TransactionSettings? settings,
  }) async {
    try {
      await _connectionMutex.acquire();
      return await _connection.runTx(fn, settings: settings);
    } finally {
      _connectionMutex.release();
    }
  }

  /// Performs a SQL query that emits whenever changes happen to the affected
  /// tables.
  Stream<Result> watch(
    String sql, {
    Object? Function()? parameters,
    bool ignoreRows = false,
    QueryMode? queryMode,
    Duration? timeout,
  }) {
    late final StreamController<Result> controller;
    controller = StreamController<Result>(
      onListen: () {
        final query = _Query(sql, parameters, ignoreRows, queryMode, timeout);
        _watches[controller] = query;
        _emitQuery(controller, query);
      },
      onCancel: () {
        _watches.remove(controller);
        controller.close();
      },
    );

    return controller.stream;
  }

  void _emitQueries(Iterable<String> affectedTables) {
    // Trigger watched queries for all affected tables
    final affectedWatches = _watches.entries.where(
      (e) => e.value.affectedTables
          .intersection(affectedTables.toSet())
          .isNotEmpty,
    );
    for (final watch in affectedWatches) {
      unawaited(_emitQuery(watch.key, watch.value));
    }
  }

  Future<void> _emitQuery(
    StreamController<Result> controller,
    _Query query,
  ) async {
    final result = await execute(
      query.sql,
      parameters: query.parameters?.call(),
      ignoreRows: query.ignoreRows,
      queryMode: query.queryMode,
      timeout: query.timeout,
    );
    if (!controller.isClosed) {
      controller.add(result);
    } else {
      _watches.remove(controller);
    }
  }

  /// Read the last flush LSN from which to resume replication
  static Future<String> _currentLsn(Connection connection) async =>
      // restart_lsn confirmed_flush_lsn
      (await connection.execute('''
          SELECT restart_lsn::varchar(256) FROM pg_replication_slots
          WHERE slot_name = 'crdt_replication_slot'
        '''))[0][0]
          as String;
}

/// An exposed "Channel" that provides a sink and a stream that can be used to send and receive server messages.
class _ExposedChannel implements StreamChannelTransformer<Message, Message> {
  final Completer<StreamChannel<Message>> _completer = Completer();

  /// Use this sink to send messages to the server
  Future<StreamSink> get sink async => (await _completer.future).sink;

  /// Use this stream to listen to messages from the server
  Future<Stream> get stream async => (await _completer.future).stream;

  @override
  StreamChannel<Message> bind(StreamChannel<Message> channel) {
    final broadcast = channel.changeStream(
      (stream) => stream.asBroadcastStream(),
    );
    _completer.complete(broadcast);
    return broadcast;
  }
}

class _Query {
  final String sql;
  final Object? Function()? parameters;
  final bool ignoreRows;
  final QueryMode? queryMode;
  final Duration? timeout;
  final Set<String> affectedTables;

  _Query(
    this.sql,
    this.parameters,
    this.ignoreRows,
    this.queryMode,
    this.timeout,
  ) : affectedTables = SqlUtil.getAffectedTables(sql);

  @override
  String toString() => '$runtimeType: $sql, params: $parameters';
}

class Relation {
  final String name;
  final List<int> indexPositions;

  Relation(RelationMessage msg)
    : name = msg.relationName,
      indexPositions = msg.columns
          .where((e) => e.flags == 1)
          .map((e) => msg.columns.indexOf(e))
          .toList();
}

class _DbEvent {
  static final _tableById = <int, String>{};

  final int _relationId;
  final Iterable<Object?>? _ids;

  String get table => _tableById[_relationId]!;
  Iterable<Object?> get ids => _ids!;
  String get mergedId => ids.join('::');
  bool get isTruncate => _ids == null;

  _DbEvent._(this._relationId, this._ids);

  static Iterable<_DbEvent> fromMessage(LogicalReplicationMessage message) =>
      (switch (message) {
                InsertMessage _ => [(message.relationId, message.tuple)],
                UpdateMessage _ => [
                  if (message.oldTuple != null)
                    (message.relationId, message.oldTuple!),
                  (message.relationId, message.newTuple!),
                ],
                DeleteMessage _ => [(message.relationId, message.oldTuple)],
                TruncateMessage _ => message.relationIds.map((e) => (e, null)),
                _ => throw 'Unsupported message type: ${message.runtimeType}',
              }
              as Iterable<(int, TupleData?)>)
          .map((e) {
            final (relationId, tuple) = e;
            // Get ids from tuple
            final ids = tuple?.columns.map((e) => e.value);
            return _DbEvent._(relationId, ids);
          });

  /// Ensure the relation id => table map exists
  Future<void> _resolveTable(Session connection) async {
    _tableById[_relationId] ??=
        (await connection.execute(
              'SELECT $_relationId::regclass::varchar',
              // (await connection.execute(
              //       'SELECT relname FROM pg_class WHERE oid = $_relationId',
            ))[0][0]
            as String;
  }

  @override
  String toString() => isTruncate
      ? 'Truncate ${_tableById[_relationId] ?? _relationId}'
      : 'SET ${_tableById[_relationId] ?? _relationId}::$mergedId';
}
