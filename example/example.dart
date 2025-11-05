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

  await db.execute('DROP TABLE IF EXISTS crdt');
  await db.execute('DROP TABLE IF EXISTS users');
  await db.execute('''
    CREATE TABLE users (
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

  // Insert an entry into the database
  await crdt.execute(
    r'''
    INSERT INTO users (id, name)
    VALUES ($1, $2)
  ''',
    parameters: [1, 'John Doe'],
  );

  // Delete it
  await crdt.execute(r'DELETE FROM users WHERE id = $1', parameters: [1]);

  // Merge a remote dataset
  await crdt.merge({
    'users': [
      {
        'id': '2',
        'hlc': Hlc.now(generateNodeId()).toString(),
        'data': {'id': 2, 'name': 'Jane Doe'},
      },
    ],
  });

  // Queries are simple SQL statements
  final result = await crdt.execute('SELECT * FROM users');
  printRecords('SELECT * FROM users', result);

  // We can also watch for results to a specific query, but be aware that this
  // can be inefficient since it reruns watched queries on every database change
  crdt
      .watch('SELECT id, name FROM users')
      .listen((e) => printRecords('Watch: SELECT id, name FROM users', e));

  // Update the database
  await crdt.execute(
    r'''
      UPDATE users SET name = $1
      WHERE id = $2
    ''',
    parameters: ['Jane Doe', 2],
  );

  // Perform multiple writes inside a transaction so they get the same timestamp
  await crdt.runTx((tx) async {
    // Make sure you use the transaction object (txn)
    // Using [crdt] here will cause a deadlock
    await tx.execute(
      r'''
        INSERT INTO users (id, name)
        VALUES ($1, $2)
      ''',
      parameters: [3, 'Uncle Doe'],
    );
    await tx.execute(
      r'''
        INSERT INTO users (id, name)
        VALUES ($1, $2)
      ''',
      parameters: [4, 'Grandma Doe'],
    );
  });

  // Create a changeset to synchronize with another node
  final changeset = await crdt.getChangeset();
  print(changeset);
  print('> Changeset size: ${changeset.recordCount} record(s)');
  changeset.forEach((key, value) {
    print(key);
    for (var e in value) {
      print('  $e');
    }
  });

  crdt.watch('SELECT * FROM users').listen(print);

  // exit(0);
}

void printRecords(String title, Result records) {
  print('> $title');
  records.forEach(print);
}
