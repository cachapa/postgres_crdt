import 'package:postgres_crdt/postgres_crdt.dart';

import 'sql_crdt_test.dart';

Future<void> main() async {
  final crdt = await PostgresCrdt.open(
    'testdb',
    username: 'postgres',
    password: 'postgres',
    sslMode: SslMode.disable,
  );

  runSqlCrdtTests(crdt);
}
