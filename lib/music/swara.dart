import 'dart:math' as math;

/// Carnatic swara identities with just-intonation ratios relative to Sa.
///
/// Shankarabharanam (mēḷakarta 29) uses:
/// Sa, Ri₂ (chatuśruti), Ga₃ (antara), Ma₁ (śuddha), Pa,
/// Da₂ (chatuśruti), Ni₃ (kākali), Sȧ
///
/// Textbook reference frequencies at Sa = 240 Hz:
/// Sa 240, Ri₂ 270, Ga₃ 300, Ma₁ 320, Pa 360, Da₂ 400, Ni₃ 450, Sȧ 480.
enum Swara {
  sa,
  ri1,
  ri2,
  ga2,
  ga3,
  ma1,
  ma2,
  pa,
  da1,
  da2,
  ni2,
  ni3,
  saHigh,
}

extension SwaraTuning on Swara {
  /// Just ratios (22-śruti / samvādi skeleton).
  double get ratio => switch (this) {
        Swara.sa => 1.0,
        Swara.ri1 => 16 / 15,
        Swara.ri2 => 9 / 8,
        Swara.ga2 => 6 / 5,
        Swara.ga3 => 5 / 4,
        Swara.ma1 => 4 / 3,
        Swara.ma2 => 45 / 32,
        Swara.pa => 3 / 2,
        Swara.da1 => 8 / 5,
        Swara.da2 => 5 / 3,
        Swara.ni2 => 9 / 5,
        Swara.ni3 => 15 / 8,
        Swara.saHigh => 2.0,
      };

  /// Cents above Sa (1200 * log2(ratio)).
  double get cents => 1200.0 * (math.log(ratio) / math.ln2);

  /// Absolute frequency for a chosen Sa.
  double hzAt(double saHz) => saHz * ratio;

  String get label => switch (this) {
        Swara.sa => 'Sa',
        Swara.ri1 => 'Ri₁',
        Swara.ri2 => 'Ri₂',
        Swara.ga2 => 'Ga₂',
        Swara.ga3 => 'Ga₃',
        Swara.ma1 => 'Ma₁',
        Swara.ma2 => 'Ma₂',
        Swara.pa => 'Pa',
        Swara.da1 => 'Da₁',
        Swara.da2 => 'Da₂',
        Swara.ni2 => 'Ni₂',
        Swara.ni3 => 'Ni₃',
        Swara.saHigh => 'Sȧ',
      };

  String get fullName => switch (this) {
        Swara.sa => 'Ṣaḍja',
        Swara.ri1 => 'Śuddha ṛṣabha',
        Swara.ri2 => 'Chatuśruti ṛṣabha',
        Swara.ga2 => 'Sādhāraṇa gāndhāra',
        Swara.ga3 => 'Antara gāndhāra',
        Swara.ma1 => 'Śuddha madhyama',
        Swara.ma2 => 'Prati madhyama',
        Swara.pa => 'Pañcama',
        Swara.da1 => 'Śuddha dhaivata',
        Swara.da2 => 'Chatuśruti dhaivata',
        Swara.ni2 => 'Kaiśiki niṣāda',
        Swara.ni3 => 'Kākali niṣāda',
        Swara.saHigh => 'Tāra ṣaḍja',
      };
}
