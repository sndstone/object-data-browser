import 'package:flutter/material.dart';

import '../theme/breakpoints.dart';

/// True when controls should expose phone-sized (48 px) hit regions: touch
/// platforms, or any window narrow enough to use the phone layout.
bool usesTouchTargets(BuildContext context) {
  final platform = Theme.of(context).platform;
  return platform == TargetPlatform.android ||
      platform == TargetPlatform.iOS ||
      Breakpoints.isPhone(MediaQuery.sizeOf(context).width);
}
