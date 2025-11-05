import 'package:postgres/postgres.dart';
import 'package:postgres_crdt/postgres_crdt.dart';

Future<void> main() async {
  // Use regular DB connection to create tables for syncing
  final endpoint = Endpoint(
    host: 'localhost',
    database: 'testdb',
    username: 'postgres',
    password: 'postgres',
  );
  final sslMode = SslMode.disable;
  final db = await Connection.open(
    endpoint,
    settings: ConnectionSettings(sslMode: sslMode),
  );

  // await db.execute('DROP TABLE crdt');
  // await db.execute('DROP TABLE users');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER NOT NULL,
      name TEXT,
      PRIMARY KEY (id)
    )
  ''');

  // Initialize CRDT sync
  final crdt = await PostgresCrdt.open(
    endpoint,
    tables: ['users'],
    sslMode: sslMode,
  );

  print('Watching…');

  // print(await crdt.execute('SELECT * FROM crdt'));
  (await crdt.getChangeset())['users']!.forEach(print);

  crdt.watch('SELECT * FROM users').listen(print);

  // exit(0);
}
