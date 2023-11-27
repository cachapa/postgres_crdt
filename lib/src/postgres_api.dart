import 'package:postgres/postgres.dart';
import 'package:sql_crdt/sql_crdt.dart';

class PostgresApi extends DatabaseApi {
  final Session _connection;

  PostgresApi(this._connection);

  @override
  Future<Iterable<String>> getTables() async => (await query('''
    SELECT table_name FROM information_schema.tables
    WHERE table_type='BASE TABLE' AND table_schema='public'
  ''')).map((e) => e['table_name'] as String?).whereType<String>();

  @override
  Future<Iterable<String>> getPrimaryKeys(String table) async =>
      (await query('''
        SELECT a.attname AS name
        FROM
          pg_class AS c
          JOIN pg_index AS i ON c.oid = i.indrelid AND i.indisprimary
          JOIN pg_attribute AS a ON c.oid = a.attrelid AND a.attnum = ANY(i.indkey)
        WHERE c.oid = ?1::regclass
      ''', [table])).map((e) => e['name'] as String);

  @override
  Future<void> execute(String sql, [List<Object?>? args]) =>
      _connection.execute(
        Sql.indexed(sql, substitution: '?'),
        parameters: args,
        ignoreRows: true,
      );

  @override
  Future<List<Map<String, Object?>>> query(String sql,
          [List<Object?>? args]) async =>
      (await _connection.execute(
        Sql.indexed(sql, substitution: '?'),
        parameters: args,
      ))
          .map((e) => e.toColumnMap())
          .toList();

  @override
  Future<void> transaction(Future<void> Function(DatabaseApi txn) action) =>
      (_connection as SessionExecutor).runTx((t) => action(PostgresApi(t)));
}
