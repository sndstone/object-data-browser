import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  static const Color lightCanvas = Color(0xFFF7F8F5);
  static const Color lightPanel = Color(0xFFFFFFFF);
  static const Color lightPanelMuted = Color(0xFFF3F5F0);
  static const Color lightRail = Color(0xFF002117);
  static const Color lightRailElevated = Color(0xFF063423);
  static const Color lightAccent = Color(0xFF004D19);
  static const Color lightAccentSoft = Color(0xFFEAF3E4);
  static const Color lightBorder = Color(0xFFDDE3DD);
  static const Color lightText = Color(0xFF141B18);
  static const Color lightMutedText = Color(0xFF5E6A66);

  static const Color darkCanvas = Color(0xFF08110E);
  static const Color darkPanel = Color(0xFF111C18);
  static const Color darkPanelMuted = Color(0xFF18251F);
  static const Color darkRail = Color(0xFF001A12);
  static const Color darkRailElevated = Color(0xFF073322);
  static const Color darkAccent = Color(0xFF8DCC88);
  static const Color darkAccentSoft = Color(0xFF193B27);
  static const Color darkBorder = Color(0xFF2B3A34);
  static const Color darkText = Color(0xFFEAF1EC);
  static const Color darkMutedText = Color(0xFFABB8B1);

  static bool isDesktopPlatform(TargetPlatform platform) {
    return switch (platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux =>
        true,
      _ => false,
    };
  }

  static ThemeData light({
    required int scalePercent,
    required bool desktopCompact,
  }) {
    const baseScheme = ColorScheme(
      brightness: Brightness.light,
      primary: lightAccent,
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: lightAccentSoft,
      onPrimaryContainer: Color(0xFF0F4B16),
      secondary: Color(0xFF4B6158),
      onSecondary: Color(0xFFFFFFFF),
      secondaryContainer: Color(0xFFE3ECE5),
      onSecondaryContainer: Color(0xFF20352C),
      tertiary: Color(0xFF7A6F44),
      onTertiary: Color(0xFFFFFFFF),
      tertiaryContainer: Color(0xFFEDE8D3),
      onTertiaryContainer: Color(0xFF40380E),
      error: Color(0xFFB3261E),
      onError: Colors.white,
      errorContainer: Color(0xFFF9DEDC),
      onErrorContainer: Color(0xFF410E0B),
      surface: lightPanel,
      onSurface: lightText,
      surfaceContainerHighest: lightPanelMuted,
      onSurfaceVariant: lightMutedText,
      outline: Color(0xFF9AA79F),
      outlineVariant: lightBorder,
      shadow: Color(0x1A0C1715),
      scrim: Color(0x66000000),
      inverseSurface: lightRail,
      onInverseSurface: Color(0xFFF3F6F2),
      inversePrimary: Color(0xFF92D18E),
      surfaceTint: lightAccent,
    );
    return _themeFromScheme(
      scheme: baseScheme,
      scalePercent: scalePercent,
      desktopCompact: desktopCompact,
      scaffoldBackground: lightCanvas,
      railBackground: lightRail,
      navigationBarBackground: lightPanel,
      cardColor: lightPanel,
    );
  }

  static ThemeData dark({
    required int scalePercent,
    required bool desktopCompact,
  }) {
    const baseScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: darkAccent,
      onPrimary: Color(0xFF062112),
      primaryContainer: darkAccentSoft,
      onPrimaryContainer: Color(0xFFD5F3D2),
      secondary: Color(0xFFB7C8BE),
      onSecondary: Color(0xFF20352C),
      secondaryContainer: Color(0xFF253D32),
      onSecondaryContainer: Color(0xFFD6E8DE),
      tertiary: Color(0xFFD8CF9C),
      onTertiary: Color(0xFF34300F),
      tertiaryContainer: Color(0xFF47421B),
      onTertiaryContainer: Color(0xFFF1E9B2),
      error: Color(0xFFF2B8B5),
      onError: Color(0xFF601410),
      errorContainer: Color(0xFF8C1D18),
      onErrorContainer: Color(0xFFF9DEDC),
      surface: darkPanel,
      onSurface: darkText,
      surfaceContainerHighest: darkPanelMuted,
      onSurfaceVariant: darkMutedText,
      outline: Color(0xFF7A8981),
      outlineVariant: darkBorder,
      shadow: Color(0x66000000),
      scrim: Color(0x99000000),
      inverseSurface: Color(0xFFE8F2EE),
      onInverseSurface: Color(0xFF15211F),
      inversePrimary: lightAccent,
      surfaceTint: darkAccent,
    );
    return _themeFromScheme(
      scheme: baseScheme,
      scalePercent: scalePercent,
      desktopCompact: desktopCompact,
      scaffoldBackground: darkCanvas,
      railBackground: darkRail,
      navigationBarBackground: darkPanel,
      cardColor: darkPanel,
    );
  }

  static ThemeData _themeFromScheme({
    required ColorScheme scheme,
    required int scalePercent,
    required bool desktopCompact,
    required Color scaffoldBackground,
    required Color railBackground,
    required Color navigationBarBackground,
    required Color cardColor,
  }) {
    final isUltraCompact = scalePercent < 80;
    final cardRadius = isUltraCompact ? 8.0 : (desktopCompact ? 8.0 : 10.0);
    final fieldRadius = isUltraCompact ? 6.0 : (desktopCompact ? 8.0 : 10.0);
    final buttonRadius = isUltraCompact ? 6.0 : (desktopCompact ? 7.0 : 8.0);
    final fieldPadding = isUltraCompact
        ? const EdgeInsets.fromLTRB(10, 14, 10, 8)
        : desktopCompact
            ? const EdgeInsets.fromLTRB(12, 16, 12, 9)
            : const EdgeInsets.fromLTRB(14, 18, 14, 10);
    final buttonPadding = isUltraCompact
        ? const EdgeInsets.symmetric(horizontal: 10, vertical: 7)
        : desktopCompact
            ? const EdgeInsets.symmetric(horizontal: 13, vertical: 8)
            : const EdgeInsets.symmetric(horizontal: 15, vertical: 10);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: _visualDensity(
        scalePercent,
        desktopCompact: desktopCompact,
      ),
      materialTapTargetSize: desktopCompact
          ? MaterialTapTargetSize.shrinkWrap
          : MaterialTapTargetSize.padded,
    );
    final textTheme =
        GoogleFonts.spaceGroteskTextTheme(base.textTheme).copyWith(
      displayLarge: GoogleFonts.sora(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
        fontSize: 58,
        height: 0.98,
        color: scheme.onSurface,
      ),
      displayMedium: GoogleFonts.sora(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
        fontSize: 44,
        height: 1.0,
        color: scheme.onSurface,
      ),
      headlineMedium: GoogleFonts.sora(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
        color: scheme.onSurface,
      ),
      headlineSmall: GoogleFonts.sora(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
        color: scheme.onSurface,
      ),
      titleLarge: GoogleFonts.spaceGrotesk(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
        fontSize: desktopCompact ? 18.0 : 20.0,
        color: scheme.onSurface,
      ),
      titleMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
        fontSize: desktopCompact ? 14.0 : 15.0,
        height: 1.25,
        color: scheme.onSurface,
      ),
      bodyLarge: GoogleFonts.inter(
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
        fontSize: desktopCompact ? 15.0 : 16.0,
        height: 1.4,
      ),
      bodyMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
        fontSize: desktopCompact ? 14.0 : 15.0,
        height: 1.4,
      ),
      bodySmall: GoogleFonts.inter(
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
        fontSize: desktopCompact ? 13.0 : 13.75,
        height: 1.35,
      ),
      labelLarge: GoogleFonts.inter(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
        fontSize: desktopCompact ? 13.25 : 14.0,
        height: 1.2,
        color: scheme.onSurface,
      ),
      labelMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
        fontSize: desktopCompact ? 12.5 : 13.25,
        height: 1.2,
        color: scheme.onSurfaceVariant,
      ),
      labelSmall: GoogleFonts.inter(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
        fontSize: desktopCompact ? 11.75 : 12.5,
        height: 1.2,
        color: scheme.onSurfaceVariant,
      ),
    );

    return base.copyWith(
      textTheme: textTheme,
      scaffoldBackgroundColor: scaffoldBackground,
      canvasColor: scaffoldBackground,
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.8),
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.8),
        thickness: 1,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: railBackground,
        selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
        selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onSurface,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: navigationBarBackground,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => textTheme.labelLarge?.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        isDense: false,
        contentPadding: fieldPadding,
        constraints: BoxConstraints(
          minHeight: isUltraCompact ? 42 : (desktopCompact ? 46 : 50),
        ),
        labelStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
          fontSize: textTheme.labelLarge?.fontSize ?? 14,
          fontWeight: FontWeight.w700,
          height: 1.15,
        ),
        floatingLabelStyle: textTheme.labelLarge?.copyWith(
          color: scheme.primary,
          fontSize: textTheme.labelLarge?.fontSize ?? 14,
          fontWeight: FontWeight.w800,
          height: 1.15,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
          fontWeight: FontWeight.w500,
        ),
        helperStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.78),
          fontSize: textTheme.bodySmall?.fontSize ?? 12.5,
          height: 1.35,
        ),
        helperMaxLines: 3,
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(fieldRadius),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(fieldRadius),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.9),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(fieldRadius),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(fieldRadius),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.48),
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(fieldRadius),
          borderSide: BorderSide(color: scheme.error),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primaryContainer.withValues(alpha: 0.95),
        checkmarkColor: scheme.primary,
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.72),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
        labelStyle: textTheme.labelLarge?.copyWith(color: scheme.onSurface),
        padding: isUltraCompact
            ? const EdgeInsets.symmetric(horizontal: 4, vertical: 0)
            : null,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: buttonPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: buttonPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          fixedSize: Size.square(desktopCompact ? 34 : 38),
          minimumSize: Size.square(desktopCompact ? 34 : 38),
          padding: EdgeInsets.zero,
          tapTargetSize: desktopCompact
              ? MaterialTapTargetSize.shrinkWrap
              : MaterialTapTargetSize.padded,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          padding: WidgetStatePropertyAll(
            desktopCompact
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
                : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            isUltraCompact ? 8 : (desktopCompact ? 10 : 14),
          ),
        ),
        tileColor: scheme.surface.withValues(alpha: 0.4),
        contentPadding: EdgeInsets.symmetric(
          horizontal: isUltraCompact ? 8 : (desktopCompact ? 10 : 12),
          vertical: isUltraCompact ? 1 : (desktopCompact ? 2 : 2),
        ),
        minVerticalPadding: desktopCompact ? 0 : null,
        dense: isUltraCompact,
        selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.52),
        selectedColor: scheme.onPrimaryContainer,
        iconColor: scheme.onSurfaceVariant,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.onSurface,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        labelStyle: textTheme.labelLarge,
        unselectedLabelStyle: textTheme.labelLarge,
        dividerColor: Colors.transparent,
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStatePropertyAll(
          scheme.outlineVariant.withValues(alpha: 0.7),
        ),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.primary;
          }
          return scheme.onSurfaceVariant;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.primaryContainer.withValues(alpha: 0.72);
          }
          return scheme.surfaceContainerHighest.withValues(alpha: 0.72);
        }),
      ),
    );
  }

  static VisualDensity _visualDensity(
    int scalePercent, {
    required bool desktopCompact,
  }) {
    // Allow a wider range so values below 80% produce genuinely denser layouts.
    final baseOffset =
        ((scalePercent - 100) / 10.0).clamp(-4.0, 1.5).toDouble();
    final offset = desktopCompact
        ? (baseOffset - 0.5).clamp(-4.0, 1.0).toDouble()
        : baseOffset;
    return VisualDensity(horizontal: offset, vertical: offset);
  }
}
