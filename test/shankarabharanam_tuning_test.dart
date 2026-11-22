import 'package:carnatic_app/music/shankarabharanam.dart';
import 'package:carnatic_app/music/swara.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Shankarabharanam textbook frequencies at Sa=240 Hz', () {
    final f = Shankarabharanam.frequencies(saHz: 240);
    expect(f[Swara.sa], closeTo(240, 0.01));
    expect(f[Swara.ri2], closeTo(270, 0.01)); // 9/8
    expect(f[Swara.ga3], closeTo(300, 0.01)); // 5/4
    expect(f[Swara.ma1], closeTo(320, 0.01)); // 4/3
    expect(f[Swara.pa], closeTo(360, 0.01)); // 3/2
    expect(f[Swara.da2], closeTo(400, 0.01)); // 5/3
    expect(f[Swara.ni3], closeTo(450, 0.01)); // 15/8
    expect(f[Swara.saHigh], closeTo(480, 0.01)); // 2/1
  });

  test('exact scale phrase uses all seven swaras + tara Sa', () {
    final p = Shankarabharanam.exactScalePhrase();
    final degrees = p.notes.map((n) => n.swara).toSet();
    expect(degrees.containsAll(Shankarabharanam.arohana), isTrue);
    expect(p.notes.every((n) => n.gamaka.name == 'steady'), isTrue);
  });

  test('demo phrase does not put wide kampita on Ga or Ni', () {
    final p = Shankarabharanam.demoPhrase();
    for (final n in p.notes) {
      if (n.swara == Swara.ga3 || n.swara == Swara.ni3) {
        expect(
          n.gamaka.name,
          isNot('kampita'),
          reason: 'Ga/Ni kampita sounds like Kalyāṇi, not Śankarābharaṇam',
        );
      }
    }
    expect(
      p.notes.any((n) => n.swara == Swara.ri2 && n.gamaka.name == 'kampita'),
      isTrue,
    );
    expect(
      p.notes.any((n) => n.swara == Swara.da2 && n.gamaka.name == 'kampita'),
      isTrue,
    );
  });
}
