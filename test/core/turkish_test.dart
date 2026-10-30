import 'package:bebegimin_ilk_yili/core/utils/turkish.dart';
import 'package:bebegimin_ilk_yili/core/utils/validators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('genitive suffix with vowel harmony', () {
    expect(Turkish.genitive('Defne'), "Defne'nin");
    expect(Turkish.genitive('Can'), "Can'ın");
    expect(Turkish.genitive('Umut'), "Umut'un");
    expect(Turkish.genitive('Öykü'), "Öykü'nün");
    expect(Turkish.genitive('Ela'), "Ela'nın");
    expect(Turkish.genitive('ILGAZ'), "ILGAZ'ın");
  });

  test('dative suffix', () {
    expect(Turkish.dative('Ege'), "Ege'ye");
    expect(Turkish.dative('Can'), "Can'a");
    expect(Turkish.dative('Defne'), "Defne'ye");
    expect(Turkish.dative('Mert'), "Mert'e");
  });

  test('upper / fold', () {
    expect(Turkish.upper('ilk yılım'), 'İLK YILIM');
    expect(Turkish.fold('İlk Adımım Çığlık'), 'ilk adimim ciglik');
  });

  test('validators', () {
    expect(Validators.email('a@b.co'), isNull);
    expect(Validators.email('nope'), isNotNull);
    expect(Validators.password('kisa1'), isNotNull);
    expect(Validators.password('uzunsifre'), isNotNull);
    expect(Validators.password('Guvenli123'), isNull);
  });
}
