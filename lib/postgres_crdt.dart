import 'package:postgres/postgres.dart';
import 'package:sql_crdt/sql_crdt.dart';

import 'src/postgres_api.dart';

export 'package:postgres/postgres.dart' show SslMode;
export 'package:sql_crdt/sql_crdt.dart';

class PostgresCrdt extends SqlCrdt {
  PostgresCrdt._(super.db);

  /// Open a database connection as a SqlCrdt instance.
  ///
  /// Use [sslMode] to specify the connection security with Postgres.
  ///
  /// Use [maxConnectionAge] to control how often the connection should reset.
  /// Because of an ongoing memory leak, this defaults to one day.
  /// Set to [null] to disable.
  static Future<PostgresCrdt> open(
    String databaseName, {
    String host = 'localhost',
    int port = 5432,
    String? username,
    String? password,
    SslMode? sslMode,
    Duration? maxConnectionAge = const Duration(days: 1),
  }) async {
    final db = Pool.withEndpoints(
      [
        Endpoint(
          host: host,
          port: port,
          database: databaseName,
          username: username,
          password: password,
        )
      ],
      settings: PoolSettings(
        sslMode: sslMode,
        maxConnectionAge: maxConnectionAge,
      ),
    );

    final crdt = PostgresCrdt._(PostgresApi(db));
    await crdt.init();
    return crdt;
  }

  @override
  Future<Iterable<String>> getTables() async => (await query('''
    SELECT table_name FROM information_schema.tables
    WHERE table_type='BASE TABLE' AND table_schema='public'
  ''')).map((e) => e['table_name'] as String?).whereType<String>();

  @override
  Future<Iterable<String>> getTableKeys(String table) async => (await query('''
    SELECT a.attname AS name
    FROM
      pg_class AS c
      JOIN pg_index AS i ON c.oid = i.indrelid AND i.indisprimary
      JOIN pg_attribute AS a ON c.oid = a.attrelid AND a.attnum = ANY(i.indkey)
    WHERE c.oid = ?1::regclass
  ''', [table])).map((e) => e['name'] as String);
}
