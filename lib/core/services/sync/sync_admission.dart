/// One request's budget, and its right to keep writing.
///
/// A request used to get its deadline from a `.timeout()` wrapped around the
/// route: that ends the *caller's* wait, not the handler. A handler the deadline
/// had already abandoned kept running — installing a session, writing a
/// checkpoint, landing a file — which is the whole of O2. The deadline has to
/// travel with the work for the work to know it is over.
///
/// The budget starts at **admission** (the instant the listener read the
/// request), not at dequeue. A request that waited behind a long beat has
/// already spent that time; giving it a second full budget is what made
/// "queued for thirty minutes, then ran for thirty more" a legal state.
///
/// Two things a handler can do with one:
///
/// * `check()` — at a commit point, before state changes. Throwing here is the
///   cancellation: everything already committed stays (the writes are
///   idempotent, so the next session redoes them), and nothing after it
///   happens.
/// * `io()` — around every await that could hang forever (a body that stops
///   arriving, a peer that stops reading). This does not cancel the underlying
///   work; it unblocks the handler so its `finally` runs. The work it abandons
///   must be read-only.
///
/// One gate belongs to one request. It is never reset: `remaining` only shrinks.
///
/// The elapsed time is read from a [Stopwatch], not from the wall clock. A
/// budget is how much *work* a request may spend, so an NTP correction — or a
/// phone re-syncing after a tunnel — must not decide that a request which is
/// making progress has run out; the converse, a backward step buying a request
/// extra time, is the same bug from the other side. A stopwatch also cannot be
/// moved by anything outside this process.
library;

class SyncAdmission {
  SyncAdmission({required this.budget, Duration alreadySpent = Duration.zero})
    : _spentBefore = alreadySpent,
      _watch = Stopwatch()..start();

  /// The route's whole budget (see `SyncServer._deadlineFor`).
  final Duration budget;

  /// Time already gone before this gate existed — zero in production, where the
  /// gate is built at admission. It exists so a test can hand a handler a gate
  /// whose budget is already spent, without waiting one out.
  final Duration _spentBefore;

  final Stopwatch _watch;

  bool _lost = false;

  /// Whether the deadline already took this request's right to write.
  bool get isLost => _lost;

  Duration get _spent => _spentBefore + _watch.elapsed;

  /// What is left of the budget, never negative.
  Duration get remaining {
    final left = budget - _spent;
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether this handler may still write. False once the budget is spent, or
  /// once anything declared the request abandoned.
  bool get alive => !_lost && _spent < budget;

  /// Abandons the request. The handler keeps running until its next `check()`
  /// or `io()`, and everything it would have written after that is refused.
  void lose() => _lost = true;

  /// The commit-point guard: call before installing a session, writing a
  /// checkpoint, or landing a file — never inside a transaction.
  ///
  /// Between transactions is the only place a cancellation may happen: half of
  /// one leaves a torn state that is worse than a late write, because nothing
  /// re-plans it.
  void check() {
    if (!alive) throw const SyncAdmissionLost();
  }

  /// Runs [work] with whatever budget is left, abandoning the request when it
  /// runs out. Use it for anything that can wait forever.
  ///
  /// [work] is a callback rather than a future on purpose: a future passed as an
  /// argument has already started, so a gate that refuses it would leave a
  /// running handler whose error nobody is listening to — an unhandled async
  /// error instead of a 504. Called this way, nothing begins until the gate has
  /// agreed to it.
  Future<T> io<T>(Future<T> Function() work) {
    check();
    return work().timeout(
      remaining,
      onTimeout: () {
        lose();
        throw const SyncAdmissionLost();
      },
    );
  }

  /// The same guard for a stream a handler reads or writes chunk by chunk. The
  /// error is delivered as a stream error and the stream closed, so an
  /// `await for` around it throws instead of hanging on a silent socket.
  Stream<T> ioStream<T>(Stream<T> stream) {
    check();
    return stream.timeout(
      remaining,
      onTimeout: (sink) {
        lose();
        sink.addError(const SyncAdmissionLost());
        sink.close();
      },
    );
  }
}

/// The deadline took the request: it must not write, and whatever it was
/// waiting for is abandoned.
class SyncAdmissionLost implements Exception {
  const SyncAdmissionLost();

  @override
  String toString() => 'SyncAdmissionLost';
}
