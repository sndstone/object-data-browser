const settingsSections = <String>[
  'Connections',
  'Transfers & Storage',
  'Performance',
  'Appearance',
  'Safety & Recovery',
  'Benchmark',
  'About & Diagnostics',
];

/// Retain old deep links while consolidating navigation.
String canonicalSettingsSection(String section) => switch (section) {
      'General' => 'Connections',
      'Transfers' || 'Downloads & Temp Storage' => 'Transfers & Storage',
      'Diagnostics' || 'Version Details' => 'About & Diagnostics',
      _ => section,
    };
