library postgres_crdt;

import 'package:postgres/postgres.dart';
import 'package:sql_crdt/sql_crdt.dart';

import 'src/postgres_api.dart';

export 'package:sql_crdt/sql_crdt.dart';

class PostgresCrdt extends SqlCrdt {
  PostgresCrdt._(super.db);

  /// Open a database connection as a SqlCrdt instance.
  static Future<PostgresCrdt> open(
    String databaseName, {
    String host = 'localhost',
    int port = 5432,
    String? username,
    String? password,
  }) async {
    final db = PostgreSQLConnection(host, port, databaseName,
        username: username, password: password);
    await db.open();

    final crdt = PostgresCrdt._(PostgresApi(db));
    await crdt.init();
    return crdt;
  }
}
