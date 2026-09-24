import 'package:flutter/painting.dart';

/// Combines the phone's accessibility scaling with OmniTerm's Settings preference.
/// Keep the platform curve: Android can scale smaller and larger text differently.
class OmniTextScaler extends TextScaler {
  const OmniTextScaler(this.platform, this.appScale);

  final TextScaler platform;
  final double appScale;

  @override
  double scale(double fontSize) => platform.scale(fontSize) * appScale;

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is OmniTextScaler && other.platform == platform && other.appScale == appScale;

  @override
  int get hashCode => Object.hash(platform, appScale);
}
