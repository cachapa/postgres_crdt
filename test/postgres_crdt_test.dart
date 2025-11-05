import 'dart:async';

import 'package:postgres/postgres.dart';
import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:test/test.dart';

const monitoredTables = ['users', 'other_users', 'friends', 'purchases'];

Future<void> main() async {
  final endpoint = Endpoint(
    host: 'localhost',
    database: 'testdb',
    username: 'postgres',
    password: 'postgres',
  );
  final sslMode = SslMode.disable;
  final connection = await Connection.open(
    endpoint,
    settings: ConnectionSettings(sslMode: sslMode),
  );
  late PostgresCrdt crdt;

  group('Basic', () {
    setUp(() async {
      await createTables(connection);
      crdt = await PostgresCrdt.open(
        endpoint,
        tables: monitoredTables,
        sslMode: sslMode,
      );
    });

    tearDown(() async => await crdt.close());

    test('Node ID', () {
      expect(crdt.nodeId, isNotEmpty);
    });

    test('Canonical time', () async {
      await insertUser(crdt, 1, 'John Doe');
      await insertUser(crdt, 2, 'Jane Doe');

      final changeset = await crdt.getChangeset();
      final hlc1 = (changeset['users']!.first.hlc);
      final hlc2 = (changeset['users']!.last.hlc);

      expect(hlc2, greaterThan(hlc1));
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

    test('Truncate', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.execute('TRUNCATE users');
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
  });

  group('Changesets', () {
    setUp(() async {
      await createTables(connection);
      crdt = await PostgresCrdt.open(
        endpoint,
        tables: monitoredTables,
        sslMode: sslMode,
      );
    });

    tearDown(() async => await crdt.close());

    test('Full changeset', () async {
      await insertUser(crdt, 1, 'John Doe');
      final changeset = await crdt.getChangeset();
      expect(
        (changeset['users']!.first.data as Map<String, Object?>)['name'],
        'John Doe',
      );
    });

    test('By node id', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.merge({
        'users': [
          {
            'id': '2',
            'hlc': Hlc.now('nodeId'),
            'data': {'id': 2, 'name': 'Jane Doe'},
          },
        ],
      });
      final changeset1 = await crdt.getChangeset(onlyNodeId: 'nodeId');
      expect(changeset1.recordCount, 1);
      expect(changeset1['users']![0].data!['name'], 'Jane Doe');
      final changeset2 = await crdt.getChangeset(onlyNodeId: 'other_node_id');
      expect(changeset2.recordCount, 0);
    });

    test('Except node id', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.merge({
        'users': [
          {
            'id': '2',
            'hlc': Hlc.now('nodeId'),
            'data': {'id': 2, 'name': 'Jane Doe'},
          },
        ],
      });
      final changeset1 = await crdt.getChangeset(exceptNodeId: 'nodeId');
      expect(changeset1.recordCount, 1);
      expect(changeset1['users']![0].data!['name'], 'John Doe');
      final changeset2 = await crdt.getChangeset(exceptNodeId: 'other_node_id');
      expect(changeset2.recordCount, 2);
    });

    test('Modified on', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.merge({
        'users': [
          {
            'id': '2',
            'hlc': Hlc.now('nodeId'),
            'data': {'id': 2, 'name': 'Jane Doe'},
          },
        ],
      });
      final changeset = await crdt.getChangeset(modifiedOn: crdt.canonicalTime);
      expect(changeset.recordCount, 1);
      expect(changeset['users']![0].data!['name'], 'Jane Doe');
    });

    test('Modified after', () async {
      await insertUser(crdt, 1, 'John Doe');
      final hlc = Hlc.now('nodeId');
      await crdt.merge({
        'users': [
          {
            'id': '2',
            'hlc': hlc.increment(),
            'data': {'id': 2, 'name': 'Jane Doe'},
          },
        ],
      });
      final changeset = await crdt.getChangeset(modifiedAfter: hlc);
      expect(changeset.recordCount, 1);
      expect(changeset['users']![0].data!['name'], 'Jane Doe');
    });

    test('Filter entire collections', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.merge({
        'users': [
          {
            'id': '2',
            'hlc': Hlc.now('nodeId'),
            'data': {'id': 2, 'name': 'Jane Doe'},
          },
        ],
        'friends': [
          {
            'id': '1::2',
            'hlc': Hlc.now('nodeId'),
            'data': {'id1': 1, 'id2': 2, 'note': 'BFFs'},
          },
        ],
      });

      final changeset1 = await crdt.getChangeset(
        collectionFilter: {'users': null},
      );
      expect(changeset1.recordCount, 2);
      expect(changeset1['users'], isNotNull);
      expect(changeset1['friends'], isNull);

      final changeset2 = await crdt.getChangeset(
        collectionFilter: {'friends': null},
      );
      expect(changeset2.recordCount, 1);
      expect(changeset2['users'], isNull);
      expect(changeset2['friends']!.first.data, isNotNull);
    });

    test('Filter specific fields', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.merge({
        'users': [
          {
            'id': '2',
            'hlc': Hlc.now('nodeId'),
            'data': {'id': 2, 'name': 'Jane Doe'},
          },
        ],
        'friends': [
          {
            'id': '1::2',
            'hlc': Hlc.now('nodeId'),
            'data': {'id1': 1, 'id2': 2, 'note': 'BFFs'},
          },
          {
            'id': '1::3',
            'hlc': Hlc.now('nodeId'),
            'data': {'id1': 1, 'id2': 3, 'note': 'School buddies'},
          },
        ],
      });

      final changeset1 = await crdt.getChangeset(
        collectionFilter: {
          'users': {'id': 1},
        },
      );
      expect(changeset1.recordCount, 1);
      expect(changeset1['users'], isNotNull);
      expect(changeset1['friends'], isNull);

      final changeset2 = await crdt.getChangeset(
        collectionFilter: {
          'friends': {'id1': '1'},
        },
      );
      expect(changeset2.recordCount, 2);
      expect(changeset2['users'], isNull);
      expect(changeset2['friends'], isNotEmpty);
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

    test('Merge deleted records', () async {
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

    test('Merge large changeset', () async {
      final length = 1000;
      final hlc = Hlc.now('test_node_id');
      final changeset = {
        'users': List.generate(
          length,
          (i) => {
            'id': '$i',
            'hlc': hlc,
            'data': {'id': i, 'name': 'John Doe $i'},
          },
        ),
      };
      await crdt.merge(changeset);

      final result = await crdt.execute('SELECT * FROM users');
      expect(result.length, length);
      expect(result.first, [0, 'John Doe 0']);
      expect(result.last, [length - 1, 'John Doe ${length - 1}']);
    });
  });

  group('Watch', () {
    setUp(() async {
      await createTables(connection);
      crdt = await PostgresCrdt.open(
        endpoint,
        tables: monitoredTables,
        sslMode: sslMode,
      );
    });

    tearDown(() async {
      // Wait for change emissions to complete
      await Future.delayed(Duration(milliseconds: 10));
      await crdt.close();
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
        emitsThrough([
          [1, 'John Doe'],
          [2, 'Jane Doe'],
        ]),
      );
      await crdt.runTx((txn) async {
        await insertUser(txn, 1, 'John Doe');
        await insertUser(txn, 2, 'Jane Doe');
      });
      await streamTest;
    });

    test('Emit on merge', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsThrough([
          [1, 'John Doe'],
        ]),
      );
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
      await connection.runTx((session) async {
        await insertUser(session, 1, 'John Doe');
        await insertPurchase(session, 1, 1, 12);
      });
      await streamTest;
    });
  });
}

Future<void> insertUser(dynamic crdt, int id, String name) async {
  await crdt.execute(
    r'''
      INSERT INTO users (id, name)
      VALUES ($1, $2)
    ''',
    parameters: [id, name],
  );
  // Wait for the CRDT table to catch up
  await Future.delayed(Duration(milliseconds: 10));
}

Future<void> updateUser(dynamic crdt, int id, String name) async {
  await crdt.execute(
    r'''
    UPDATE users SET name = $2
    WHERE id = $1
  ''',
    parameters: [id, name],
  );
  // Wait for the CRDT table to catch up
  await Future.delayed(Duration(milliseconds: 10));
}

Future<void> deleteUser(PostgresCrdt crdt, int id) async {
  await crdt.execute(r'DELETE FROM users WHERE id = $1', parameters: [id]);
  // Wait for the CRDT table to catch up
  await Future.delayed(Duration(milliseconds: 10));
}

Future<void> insertPurchase(dynamic crdt, int id, int userId, int price) async {
  await crdt.execute(
    r'''
        INSERT INTO purchases (id, user_id, price)
        VALUES ($1, $2, $3)
      ''',
    parameters: [id, userId, price],
  );
  // Wait for the CRDT table to catch up
  await Future.delayed(Duration(milliseconds: 10));
}

Future<void> createTables(Connection connection) async {
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
  await connection.execute('DROP TABLE IF EXISTS friends');
  await connection.execute('''
    CREATE TABLE IF NOT EXISTS friends (
      id1 INTEGER NOT NULL,
      id2 INTEGER NOT NULL,
      note TEXT,
      PRIMARY KEY (id1, id2)
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
}

// Clear all tables. The crdt table last because it will record deletes
Future<void> clearTables(PostgresCrdt crdt) async {
  // await Future.wait(
  //   crdt.tables
  //       .map((table) => 'TRUNCATE $table')
  //       .map((sql) => crdt.execute(sql)),
  // );
  // await Future.delayed(
  //   Duration(milliseconds: 100),
  //   () => crdt.execute('TRUNCATE ${crdt.crdtTable}'),
  // );
}
