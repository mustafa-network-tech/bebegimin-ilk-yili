import 'dart:io';

import 'package:bebegimin_ilk_yili/features/book/data/book_publisher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

// book-artifact-finalize is safe to repeat (staging -> verify, verified ->
// resume, ready -> answer again), so the app retries transient failures with
// the same artifact instead of discarding a rendered book.
void main() {
  Future<int> run(List<Object?> outcomes, {int attempts = 3}) {
    var call = 0;
    return BookPublisher.retryTransient(
      () async {
        final o = outcomes[call++];
        if (o is Object && o is! int) throw o;
        return o! as int;
      },
      attempts: attempts,
      delay: Duration.zero,
    );
  }

  test('a lost reply / 5xx is retried and the published version returned', () async {
    expect(await run([const FunctionException(status: 503), 7]), 7);
    expect(await run([const SocketException('offline'), const FunctionException(status: 500), 3]), 3);
  });

  test('server refusals are final', () async {
    await expectLater(run([const FunctionException(status: 409), 1]), throwsA(isA<FunctionException>()));
    await expectLater(run([const FunctionException(status: 422), 1]), throwsA(isA<FunctionException>()));
  });

  test('gives up after the last attempt', () async {
    await expectLater(
      run([
        const FunctionException(status: 502),
        const FunctionException(status: 502),
        const FunctionException(status: 502),
        1,
      ]),
      throwsA(isA<FunctionException>()),
    );
  });
}
