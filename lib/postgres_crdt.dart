library postgres_crdt;

import 'package:postgres/postgres.dart';
import 'package:sql_crdt/sql_crdt.dart';

import 'src/postgres_api.dart';

export 'package:sql_crdt/sql_crdt.dart';
export 'package:postgres/postgres.dart' show SslMode;

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
}
