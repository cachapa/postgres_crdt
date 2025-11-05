import 'dart:async';
import 'dart:collection';

class Mutex {
  var _working = false;
  final _waiters = Queue<Completer<void>>();

  Mutex();

  FutureOr acquire() {
    if (!_working) {
      _working = true;
      return Future.value();
    } else {
      final completer = Completer<void>();
      _waiters.add(completer);
      return completer.future;
    }
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _working = false;
    }
  }
}
