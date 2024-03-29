Dart implementation of Conflict-free Replicated Data Types (CRDTs) using PostgreSQL.  
This package implements [sql_crdt](https://github.com/cachapa/sql_crdt).

## Setup

Awaiting async functions is extremely important and not doing so can result in all sorts of weird behaviour.  
You can avoid them by activating the `unawaited_futures` linter warning in *analysis_options.yaml*:

```yaml
linter:
  rules:
    unawaited_futures: true
```

This package uses [postgres](https://pub.dev/packages/postgres) and requires a working PostgreSQL instance.

## Usage

Check [example.dart](https://github.com/cachapa/postgres_crdt/blob/master/example/example.dart) for more details.

## Features and bugs

Please file feature requests and bugs in the [issue tracker](https://github.com/cachapa/postgres_crdt/issues).
