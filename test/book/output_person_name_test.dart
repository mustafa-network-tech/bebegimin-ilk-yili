import 'package:bebegimin_ilk_yili/features/family/domain/relation.dart';
import 'package:flutter_test/flutter_test.dart';

// Decision P-11 (2026-10-02): people are named "Name + relation" in every
// official output. The same vectors are tested in SQL
// (supabase/tests/99n_output_person_names_test.sql, the film) and in the
// output worker (workers/output/tests/html_unit.test.ts, the offline HTML).
void main() {
  test('book: Name + relation, the same vectors as the film and the offline HTML', () {
    expect(outputPersonName('Esra', Relation.teyze, null), 'Esra Teyzesi');
    expect(outputPersonName('Ahmet', Relation.amca, null), 'Ahmet Amcası');
    expect(outputPersonName('Elif', Relation.anne, null), 'Elif Annesi');
    expect(outputPersonName('Deniz', Relation.diger, 'Vaftiz annesi'), 'Deniz Vaftiz annesi');
    expect(outputPersonName('Deniz', Relation.diger, null), 'Deniz');
    expect(outputPersonName('  ', Relation.teyze, null), 'Teyzesi');
  });
}
