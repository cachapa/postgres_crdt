import 'dart:async';
import 'dart:convert';

import 'package:crdt/crdt.dart';
import 'package:postgres/messages.dart';
import 'package:postgres/postgres.dart';
import 'package:stream_channel/stream_channel.dart';

import 'src/sql_util.dart';

class PostgresCrdt extends Crdt {
  final String crdtTable;
  final Map<String, List<String>> _tableIndexes;
  final Connection _connection;

  final _skipTransactions = <int>{};
  final _relations = <int, Relation>{};
  final _watches = <StreamController<Result>, _Query>{};

  List<String> get tables => _tableIndexes.keys.toList();

  PostgresCrdt._(
    this.crdtTable,
    this._tableIndexes,
    this._connection,
    Stream stream,
    StreamSink sink,
  ) {
    assert(_tableIndexes.isNotEmpty);

    List<Record>? records;
    final touchedTables = <String>{};
    stream.listen((msg) async {
      // Handle keep alive messages to keep the connection open
      switch (msg) {
        case PrimaryKeepAliveMessage _:
          if (msg.mustReply) {
            final statusUpdate = StandbyStatusUpdateMessage(
              walWritePosition: msg.walEnd,
            );
            final copyDataMessage = CopyDataMessage(
              statusUpdate.asBytes(encoding: utf8),
            );
            sink.add(copyDataMessage);
          }

        case XLogDataMessage _:
          switch (msg.data) {
            case RelationMessage data:
              _relations[data.relationId] = Relation(data);

            case BeginMessage data:
              // Ignore skipped transactions
              records = _skipTransactions.remove(data.xid) ? null : [];

            case InsertMessage data:
              touchedTables.add(_relations[data.relationId]!.name);
              records?.add(
                Record(
                  _relations[data.relationId]!,
                  data.tuple.columns.map((e) => e.value).toList(),
                ),
              );

            case UpdateMessage data:
              touchedTables.add(_relations[data.relationId]!.name);
              records?.add(
                Record(
                  _relations[data.relationId]!,
                  data.newTuple!.columns.map((e) => e.value).toList(),
                ),
              );

            case DeleteMessage data:
              touchedTables.add(_relations[data.relationId]!.name);
              records?.add(
                Record(
                  _relations[data.relationId]!,
                  data.oldTuple.columns.map((e) => e.value).toList(),
                  isDeleted: true,
                ),
              );

            case CommitMessage data:
              // Trigger watched queries if those tables were touched
              final touchedWatches = _watches.entries.where(
                (e) => e.value.affectedTables
                    .intersection(touchedTables)
                    .isNotEmpty,
              );
              for (final watch in touchedWatches) {
                _emitQuery(watch.key, watch.value);
              }
              touchedTables.clear();

              // Check if this transaction was skipped
              if (records == null) return;

              // Bump canonical time
              canonicalTime = canonicalTime.increment(
                wallTime: data.commitTime,
              );

              for (final record in records!) {
                await _connection.execute(
                  r'''
                    INSERT INTO crdt (collection, id, hlc, modified, is_deleted)
                      VALUES ($1, $2, $3, $4, $5)
                    ON CONFLICT (collection, id) DO
                      UPDATE SET
                        hlc = $3,
                        modified = $4,
                        is_deleted = $5
                    WHERE excluded.hlc > crdt.hlc
                  ''',
                  parameters: [
                    record.table,
                    record.mergedId,
                    canonicalTime.toString(),
                    canonicalTime.toString(),
                    record.isDeleted,
                  ],
                );
              }
          }

        case ErrorResponseMessage _:
          print('errr ${msg.fields.map((e) => e.text).join('. ')}');

        default:
          print(msg);
      }
    });
  }

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

    // Create crdt table if necessary
    connection.execute(r'''
      CREATE TABLE IF NOT EXISTS crdt (
        collection varchar(255) NOT NULL,
        id varchar(255) NOT NULL,
        hlc varchar(255) NOT NULL,
        node_id varchar(255) GENERATED ALWAYS AS (SUBSTRING(hlc FROM 'Z-\d+-(.*)$')) STORED,
        modified varchar(255) NOT NULL,
        is_deleted boolean NOT NULL,
        PRIMARY KEY (collection, id)
      )
    ''');

    // Start monitoring source DB
    final logPos = (await walConnection.execute('IDENTIFY_SYSTEM;'))[0][2];
    await walConnection.execute('DROP PUBLICATION IF EXISTS crdt_publication');
    await walConnection.execute(
      'CREATE PUBLICATION crdt_publication FOR TABLE ${tables.join(', ')}',
    );
    await walConnection.execute(
      'CREATE_REPLICATION_SLOT crdt_slot TEMPORARY LOGICAL '
      'pgoutput NOEXPORT_SNAPSHOT',
    );
    await walConnection.execute(
      'START_REPLICATION SLOT crdt_slot LOGICAL $logPos '
      "(proto_version '1', publication_names 'crdt_publication', binary 'false')",
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

    // Get canonical time
    final canonicalResult = (await connection.execute(
      'SELECT MAX(modified) AS hlc FROM $crdtTable',
    ))
        .first
        .first as String?;
    final canonicalTime = canonicalResult == null
        ? Hlc.now(generateNodeId())
        : Hlc.parse(canonicalResult);

    // Sync all changes
    for (final table in tables) {
      final concatenatedIds = tableMap[table]!
          .map((column) => '$table.$column::varchar(255)')
          .join(" || '::' || ");

      // Add CRDT records for all new items in the monitored tables
      await connection.execute('''
        INSERT INTO $crdtTable (collection, id, hlc, modified, is_deleted)
          SELECT '$table', '$concatenatedIds', '$canonicalTime', '$canonicalTime', false
          FROM $table
            LEFT JOIN $crdtTable ON $concatenatedIds = $crdtTable.id
              AND $crdtTable.collection = '$table'
              AND $crdtTable.is_deleted = false
          WHERE $crdtTable.id IS NULL
        ON CONFLICT (collection, id) DO
          UPDATE SET
            hlc = '$canonicalTime',
            modified = '$canonicalTime',
            is_deleted = false
      ''');

      // Mark missing records as deleted on the CRDT table
      await connection.execute('''
        UPDATE $crdtTable SET
          hlc = '$canonicalTime',
          modified = '$canonicalTime',
          is_deleted = true
        FROM (SELECT $crdtTable.id FROM $crdtTable
          LEFT JOIN $table ON $concatenatedIds = $crdtTable.id
        WHERE
          $crdtTable.collection = '$table' AND
          $crdtTable.is_deleted = false AND
          $table.${tableMap[table]!.first} IS NULL
        ) AS subquery
        WHERE $crdtTable.id = subquery.id
      ''');
    }

    return PostgresCrdt._(
      crdtTable,
      Map.unmodifiable(tableMap),
      connection,
      await channel.stream,
      await channel.sink,
    )..canonicalTime = canonicalTime;
  }

  @override
  Future<Hlc> getLastModified({
    String? onlyNodeId,
    String? exceptNodeId,
  }) async {
    assert((onlyNodeId != null) ^ (exceptNodeId != null));
    final whereStatement = onlyNodeId != null
        ? r'WHERE node_id = $1'
        : exceptNodeId != null
            ? r'WHERE node_id != $1'
            : '';
    final result = await _connection.execute(
      'SELECT max(modified) AS modified FROM $crdtTable $whereStatement',
      parameters: [
        if (onlyNodeId != null) onlyNodeId,
        if (exceptNodeId != null) exceptNodeId,
      ],
    );
    final hlcString = result.first.first as String?;
    return hlcString != null ? Hlc.parse(hlcString) : Hlc.zero(nodeId);
  }

  @override
  Future<void> merge(dynamic changeset) async {
    assert(changeset is Map<String, dynamic> || changeset is CrdtChangeset);
    if (changeset is Map<String, dynamic>) {
      changeset = CrdtChangeset.parse(changeset);
    }

    // Quit if there's nothing to do
    if (changeset.recordCount == 0) return;

    await _connection.runTx((session) async {
      // Validate changeset and highest hlc therein
      final highestHlc = validateChangeset(changeset);

      final txId =
          (await session.execute('SELECT txid_current()')).first.first as int;
      _skipTransactions.add(txId);

      for (final entry in changeset.entries) {
        final collection = entry.key;
        final records = entry.value;

        for (final record in records) {
          final crdtResult = await session.execute(
            '''
              INSERT INTO $crdtTable (collection, id, hlc, modified, is_deleted)
                VALUES (\$1, \$2, \$3, \$4, \$5)
              ON CONFLICT (collection, id) DO
                UPDATE SET
                  hlc = \$3,
                  modified = \$4,
                  is_deleted = \$5
              WHERE excluded.hlc > $crdtTable.hlc
            ''',
            parameters: [
              collection,
              record.id,
              '${record.hlc}',
              '$canonicalTime',
              record.isDeleted,
            ],
          );

          // Apply changes if the CRDT record was updated
          if (crdtResult.affectedRows > 0) {
            if (record.isDeleted) {
              var i = 1;
              final whereClause = _tableIndexes[collection]!
                  .map((e) => '$e = \$${i++}')
                  .join(', ');
              await session.execute('''
                  DELETE FROM $collection
                  WHERE $whereClause
                ''', parameters: record.id.split('::'));
            } else {
              final data = record.data!;
              final updateStatement = data.keys
                  .where((e) => !_tableIndexes[collection]!.contains(e))
                  .map((e) => '$e = \$${data.keys.toList().indexOf(e) + 1}')
                  .join(',\n');
              await session.execute('''
                INSERT INTO $collection (${data.keys.join(', ')})
                  VALUES (${List.generate(data.length, (i) => '\$${i + 1}').join(', ')})
                ON CONFLICT (${_tableIndexes[collection]!.join(', ')}) DO
                  UPDATE SET $updateStatement
              ''', parameters: data.values.toList());
            }
          }
        }
      }

      canonicalTime = highestHlc;
    });
  }

  @override
  Future<CrdtChangeset> getChangeset({
    Iterable<String>? onlyCollections,
    String? onlyNodeId,
    String? exceptNodeId,
    Hlc? modifiedOn,
    Hlc? modifiedAfter,
  }) async {
    // TODO Implement filters
    final changeset = <String, Iterable<Map<String, dynamic>>>{};
    for (final table in onlyCollections ?? _tableIndexes.keys) {
      final concatenatedIds = _tableIndexes[table]!
          .map((column) => '$table.$column::varchar(255)')
          .join(" || '::' || ");
      changeset[table] = (await _connection.execute(
        '''
          SELECT $crdtTable.id AS _id, $crdtTable.hlc AS _hlc, $table.* FROM $crdtTable
          LEFT JOIN $table ON $concatenatedIds = $crdtTable.id
          WHERE $crdtTable.collection = \$1
        ''',
        parameters: [table],
      ))
          .map((row) => row.toColumnMap())
          .map((e) => {
                'id': e['_id'],
                'hlc': e['_hlc'],
                'data': e[_tableIndexes[table]!.first] == null
                    ? null
                    : (e
                      ..remove('_id')
                      ..remove('_hlc'))
              });
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
    return _connection.execute(
      query,
      parameters: parameters,
      ignoreRows: ignoreRows,
      queryMode: queryMode,
      timeout: timeout,
    );
  }

  Future<R> runTx<R>(
    Future<R> Function(TxSession session) fn, {
    TransactionSettings? settings,
  }) async {
    return _connection.runTx(fn, settings: settings);
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

  Future<void> _emitQuery(
    StreamController<Result> controller,
    _Query query,
  ) async {
    final result = await _connection.execute(
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

class Record {
  final String table;
  final List<Object> ids;
  final bool isDeleted;

  String get mergedId => ids.join('::');

  Record(Relation relation, List<Object?> values, {this.isDeleted = false})
      : table = relation.name,
        ids = relation.indexPositions
            .map((i) => values[i])
            .toList()
            .cast<Object>();

  @override
  String toString() => '${isDeleted ? 'DEL' : 'SET'} $table::$mergedId';
}
