import 'dart:async';

import 'package:crdt/crdt.dart';
import 'package:postgres/postgres.dart';
import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:test/test.dart';

Future<void> main() async {
  final endpoint = Endpoint(
    host: 'localhost',
    database: 'testdb',
    username: 'cachapa',
    password: 'password',
  );
  final sslMode = SslMode.disable;
  final connection = await Connection.open(
    endpoint,
    settings: ConnectionSettings(sslMode: sslMode),
  );
  await connection.execute('DROP TABLE IF EXISTS crdt');
  await connection.execute('DROP TABLE IF EXISTS users');
  await connection.execute('''
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER NOT NULL,
      name TEXT,
      PRIMARY KEY (id)
    )
  ''');
  await connection.execute('DROP TABLE IF EXISTS other_users');
  await connection.execute('''
    CREATE TABLE IF NOT EXISTS other_users (
      id INTEGER NOT NULL,
      name TEXT,
      PRIMARY KEY (id)
    )
  ''');
  await connection.execute('DROP TABLE IF EXISTS purchases');
  await connection.execute('''
    CREATE TABLE IF NOT EXISTS purchases (
      id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      price INTEGER NOT NULL,
      PRIMARY KEY (id)
    )
  ''');

  final crdt = await PostgresCrdt.open(
    endpoint,
    tables: ['users', 'other_users', 'purchases'],
    sslMode: sslMode,
  );

  group('Basic', () {
    tearDown(() async {
      await clearTables(crdt);
    });

    test('Node ID', () {
      expect(crdt.nodeId, isNotEmpty);
    });

    test('Canonical time', () async {
      await insertUser(crdt, 1, 'John Doe');
      final can1 = crdt.canonicalTime;
      await insertUser(crdt, 2, 'Jane Doe');
      final can2 = crdt.canonicalTime;

      final changeset = await crdt.getChangeset();
      final hlc1 = (changeset['users']!.first.hlc);
      final hlc2 = (changeset['users']!.last.hlc);

      expect(can2, greaterThan(can1));
      expect(hlc2, greaterThan(hlc1));
      expect(can1, hlc1);
      expect(can2, hlc2);
      expect(hlc2, crdt.canonicalTime);
    });

    test('Get last modified', () async {
      await crdt.merge({
        'users': [
          {
            'id': '1',
            'hlc': Hlc.now('node1'),
            'data': {'id': 1, 'name': 'John Doe'},
          },
        ],
      });
      final hlc1 = crdt.canonicalTime;
      await crdt.merge({
        'other_users': [
          {
            'id': '1',
            'hlc': Hlc.now('node2'),
            'data': {'id': 1, 'name': 'Jane Doe'},
          },
        ],
      });
      final hlc2 = crdt.canonicalTime;
      expect(await crdt.getLastModified(), hlc2);
      expect(await crdt.getLastModified(onlyNodeId: 'node1'), hlc1);
      expect(await crdt.getLastModified(exceptNodeId: 'node2'), hlc1);
    });

    test('Insert', () async {
      await insertUser(crdt, 1, 'John Doe');
      final result = await crdt.execute('SELECT * FROM users');
      expect(result, [
        [1, 'John Doe'],
      ]);
    });

    test('Update', () async {
      await insertUser(crdt, 1, 'John Doe');
      final insertHlc = crdt.canonicalTime;
      await updateUser(crdt, 1, 'Jane Doe');
      final result = await crdt.execute('SELECT * FROM users');
      expect(result, [
        [1, 'Jane Doe'],
      ]);
      expect(crdt.canonicalTime, greaterThan(insertHlc));
    });

    test('Upsert', () async {
      await insertUser(crdt, 1, 'John Doe');
      final insertHlc = crdt.canonicalTime;
      await crdt.execute(
        r'''
          INSERT INTO users (id, name) VALUES ($1, $2)
          ON CONFLICT (id) DO UPDATE SET name = $2
        ''',
        parameters: [1, 'Jane Doe'],
      );
      final result = await crdt.execute('SELECT * FROM users');
      expect(result, [
        [1, 'Jane Doe'],
      ]);
      expect(crdt.canonicalTime, greaterThan(insertHlc));
    });

    test('Delete', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.execute('DELETE FROM users WHERE id = 1');
      final result = await crdt.execute('SELECT * FROM users');
      expect(result, isEmpty);
      final changeset = await crdt.getChangeset();
      expect(changeset['users']!.first.isDeleted, isTrue);
    });

    test('Transaction', () async {
      await crdt.runTx((txn) async {
        await insertUser(txn, 1, 'John Doe');
        await insertUser(txn, 2, 'Jane Doe');
      });
      final result = await crdt.execute('SELECT * FROM users');
      expect(result, [
        [1, 'John Doe'],
        [2, 'Jane Doe'],
      ]);
      final changeset = await crdt.getChangeset();
      expect(changeset['users']!.first.hlc, changeset['users']!.last.hlc);
    });

    test('Changeset', () async {
      await insertUser(crdt, 1, 'John Doe');
      final changeset = await crdt.getChangeset();
      expect(
        (changeset['users']!.first.data as Map<String, Object?>)['name'],
        'John Doe',
      );
    });

    test('Simple merge', () async {
      final hlc = Hlc.now('test_node_id');
      await crdt.merge({
        'users': [
          {
            'id': '1',
            'hlc': hlc,
            'data': {'id': 1, 'name': 'John Doe'},
          },
        ],
      });
      final result = await crdt.execute('SELECT * FROM users');
      expect(result, [
        [1, 'John Doe'],
      ]);
      final changeset = await crdt.getChangeset();
      expect(changeset['users']!.first.hlc, hlc);
      expect(crdt.canonicalTime.apply(nodeId: 'test_node_id'), hlc);
    });

    test('Merge newer records', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.merge({
        'users': [
          {
            'id': '1',
            'hlc': Hlc.now('test_node_id'),
            'data': {'id': 1, 'name': 'Jane Doe'},
          },
        ],
      });
      final result = await crdt.execute('SELECT * FROM users');
      expect(result, [
        [1, 'Jane Doe'],
      ]);
    });

    test('Skip merging older records', () async {
      final hlc = Hlc.now('test_node_id');
      await insertUser(crdt, 1, 'John Doe');
      // print(await crdt.getChangeset());
      await crdt.merge({
        'users': [
          {
            'id': '1',
            'hlc': hlc,
            'data': {'id': 1, 'name': 'Jane Doe'},
          },
          {
            'id': '2',
            'hlc': hlc,
            'data': {'id': 2, 'name': 'Jenny Doe'},
          },
        ],
      });
      final result = await crdt.execute('SELECT * FROM users');
      expect(result, [
        [1, 'John Doe'],
        [2, 'Jenny Doe'],
      ]);
    });

    test('Merge deleted', () async {
      await insertUser(crdt, 1, 'John Doe');

      final hlc = Hlc.now('test_node_id');
      await crdt.merge({
        'users': [
          {'id': '1', 'hlc': hlc, 'data': null},
        ],
      });
      final result = await crdt.execute('SELECT * FROM users');
      expect(result, isEmpty);
    });

    test('Merge changeset with multiple tables', () async {
      final length = 10;
      final hlc = Hlc.now('test_node_id');
      final inputChangeset = {
        'users': List.generate(
          length,
          (i) => {
            'id': '$i',
            'hlc': hlc,
            'data': {'id': i, 'name': 'John Doe $i'},
          },
        ),
        'other_users': List.generate(
          length,
          (i) => {
            'id': '$i',
            'hlc': hlc,
            'data': {'id': i, 'name': 'John Doe $i'},
          },
        ),
      };
      await crdt.merge(inputChangeset);

      final outputChangeset = await crdt.getChangeset();
      final result1 = await crdt.execute('SELECT * FROM users');
      expect(result1.length, length);
      expect(result1.first, [0, 'John Doe 0']);
      expect(outputChangeset['users']!.first.hlc, hlc);
      expect(result1.last, [9, 'John Doe 9']);
      expect(outputChangeset['users']!.last.hlc, hlc);

      final result2 = await crdt.execute('SELECT * FROM other_users');
      expect(result2.length, length);
      expect(result2.first, [0, 'John Doe 0']);
      expect(outputChangeset['other_users']!.first.hlc, hlc);
      expect(result2.last, [9, 'John Doe 9']);
      expect(outputChangeset['other_users']!.last.hlc, hlc);
    });
  });

  group('Write from query', () {
    tearDown(() async => await clearTables(crdt));

    test('Insert from select', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.execute('''
        INSERT INTO other_users (id, name)
        SELECT id, name FROM users
      ''');
      final result1 = await crdt.execute('SELECT * FROM users');
      final result2 = await crdt.execute('SELECT * FROM other_users');
      expect(result1, result2);
    });
  });

  group('Watch', () {
    tearDown(() async {
      await clearTables(crdt);
    });

    test('Emit on watch', () async {
      await insertUser(crdt, 1, 'John Doe');
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emits([
          [1, 'John Doe'],
        ]),
      );
      await streamTest;
    });

    test('Emit on insert', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [],
          [
            [1, 'John Doe'],
          ],
        ]),
      );
      await insertUser(crdt, 1, 'John Doe');
      await streamTest;
    });

    test('Emit on update', () async {
      await insertUser(crdt, 1, 'John Doe');
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [
            [1, 'John Doe'],
          ],
          [
            [1, 'Jane Doe'],
          ],
        ]),
      );
      await updateUser(crdt, 1, 'Jane Doe');
      await streamTest;
    });

    test('Emit on delete', () async {
      await insertUser(crdt, 1, 'John Doe');
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [
            [1, 'John Doe'],
          ],
          [],
        ]),
      );
      await deleteUser(crdt, 1);
      await streamTest;
    });

    test('Emit on transaction', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [],
          [
            [1, 'John Doe'],
            [2, 'Jane Doe'],
          ],
        ]),
      );
      await Future.delayed(Duration(milliseconds: 1));
      await crdt.runTx((txn) async {
        await insertUser(txn, 1, 'John Doe');
        await insertUser(txn, 2, 'Jane Doe');
      });
      await streamTest;
    });

    test('Emit on merge', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [],
          [
            [1, 'John Doe'],
          ],
        ]),
      );
      await Future.delayed(Duration(milliseconds: 1));
      await crdt.merge({
        'users': [
          {
            'id': '1',
            'hlc': Hlc.now('test_node_id'),
            'data': {'id': 1, 'name': 'John Doe'},
          },
        ],
      });
      await streamTest;
    });

    test('Emit only on selected table', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [],
          [
            [1, 'John Doe'],
          ],
        ]),
      );
      await insertPurchase(crdt, 1, 1, 12);
      await insertUser(crdt, 1, 'John Doe');
      await streamTest;
    });

    test('Emit on all selected tables', () async {
      final streamTest = expectLater(
        crdt.watch('''
          SELECT users.name, price FROM users
            LEFT JOIN purchases ON users.id = user_id
        '''),
        emitsInOrder([
          [],
          [
            ['John Doe', 12],
          ],
        ]),
      );
      // await Future.delayed(Duration(milliseconds: 1));
      await connection.runTx((session) async {
        await insertUser(session, 1, 'John Doe');
        await insertPurchase(session, 1, 1, 12);
      });
      await streamTest;
    });
  });
}

FutureOr<void> insertUser(dynamic crdt, int id, String name) => crdt.execute(
  r'''
      INSERT INTO users (id, name)
      VALUES ($1, $2)
    ''',
  parameters: [id, name],
);

Future<void> updateUser(PostgresCrdt crdt, int id, String name) => crdt.execute(
  r'''
    UPDATE users SET name = $2
    WHERE id = $1
  ''',
  parameters: [id, name],
);

Future<void> deleteUser(PostgresCrdt crdt, int id) =>
    crdt.execute(r'DELETE FROM users WHERE id = $1', parameters: [id]);

Future<void> insertPurchase(dynamic crdt, int id, int userId, int price) =>
    crdt.execute(
      r'''
        INSERT INTO purchases (id, user_id, price)
        VALUES ($1, $2, $3)
      ''',
      parameters: [id, userId, price],
    );

// Clear all tables. The crdt table last because it will record deletes
Future<void> clearTables(PostgresCrdt crdt) async {
  await Future.wait(
    crdt.tables
        .map((table) => 'TRUNCATE $table')
        .map((sql) => crdt.execute(sql)),
  );
  await Future.delayed(
    Duration(milliseconds: 1),
    () => crdt.execute('TRUNCATE ${crdt.crdtTable}'),
  );
}
