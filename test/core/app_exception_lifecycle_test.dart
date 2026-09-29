import 'package:bebegimin_ilk_yili/core/errors/app_exception.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('locked archive refusal maps to a permanent permission error', () {
    const error = PostgrestException(message: 'baby lifecycle is locked', code: '55000', hint: 'lifecycle_locked');
    final mapped = AppException.from(error);
    expect(mapped.kind, AppErrorKind.permission);
    expect(mapped.message, contains('kilitlendi'));
    expect(AppException.isLifecycleLocked(error), isTrue);
  });

  test('birth date changes outside the correction RPC are explained', () {
    const error = PostgrestException(message: 'birth date', code: '55000', hint: 'birth_date_requires_admin');
    final mapped = AppException.from(error);
    expect(mapped.kind, AppErrorKind.permission);
    expect(mapped.message, contains('destek'));
    expect(AppException.isLifecycleLocked(error), isFalse);
  });

  test('other server errors are not treated as lifecycle locks', () {
    const error = PostgrestException(message: 'new row violates row-level security policy', code: '42501');
    expect(AppException.isLifecycleLocked(error), isFalse);
    expect(AppException.from(error).kind, AppErrorKind.permission);
  });
}
