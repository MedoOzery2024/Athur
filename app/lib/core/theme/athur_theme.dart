import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'athur_colors.dart';
import 'athur_tokens.dart';
import 'athur_typography.dart';

/// Dark system overlay (status/nav bar icons) matching Athur's black chrome.
const SystemUiOverlayStyle athurOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: AthurColors.black,
  systemNavigationBarIconBrightness: Brightness.light,
);

/// Assembles the single dark Athur theme used across the app.
///
/// Design rules encoded here (see project spec):
/// - Black primary background, gold accent.
/// - Modern, premium, dark UI.
/// - Global scrollbars on scrollables, themed with the gold accent.
/// - Accessible touch targets and contrast.
abstract final class AthurTheme {
  AthurTheme._();

  /// The one and only theme. Athur is dark-only by design.
  static ThemeData get dark {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: AthurColors.gold,
      onPrimary: AthurColors.textOnGold,
      primaryContainer: AthurColors.goldDeep,
      onPrimaryContainer: AthurColors.textPrimary,
      secondary: AthurColors.goldBright,
      onSecondary: AthurColors.textOnGold,
      secondaryContainer: AthurColors.goldWash,
      onSecondaryContainer: AthurColors.goldBright,
      error: AthurColors.danger,
      onError: AthurColors.textPrimary,
      surface: AthurColors.surface,
      onSurface: AthurColors.textPrimary,
      surfaceContainerHighest: AthurColors.surfaceElevated,
      onSurfaceVariant: AthurColors.textSecondary,
      outline: AthurColors.border,
      outlineVariant: AthurColors.borderStrong,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: AthurColors.gold,
      onInverseSurface: AthurColors.textOnGold,
    );

    final base = ThemeData.from(
      colorScheme: scheme,
      useMaterial3: true,
      textTheme: AthurTypography.textTheme,
    );

    return base.copyWith(
      scaffoldBackgroundColor: AthurColors.black,
      canvasColor: AthurColors.black,
      splashFactory: InkRipple.splashFactory,
      // --- App bar -----------------------------------------------------------
      appBarTheme: const AppBarTheme(
        backgroundColor: AthurColors.black,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: AthurColors.textPrimary),
        titleTextStyle: AthurTypography.title,
        systemOverlayStyle: athurOverlayStyle,
      ),
      // --- Cards -------------------------------------------------------------
      cardTheme: const CardThemeData(
        color: AthurColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: AthurRadius.rMd),
      ),
      // --- Divider -----------------------------------------------------------
      dividerTheme: const DividerThemeData(
        color: AthurColors.border,
        thickness: 1,
        space: 1,
      ),
      // --- Bottom navigation -------------------------------------------------
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AthurColors.background,
        selectedItemColor: AthurColors.gold,
        unselectedItemColor: AthurColors.textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showUnselectedLabels: true,
        selectedLabelStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
      // --- Filled button (primary CTA = gold) --------------------------------
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AthurColors.gold,
          foregroundColor: AthurColors.textOnGold,
          disabledBackgroundColor: AthurColors.border,
          disabledForegroundColor: AthurColors.textMuted,
          minimumSize: const Size.fromHeight(52),
          textStyle: AthurTypography.button,
          shape: const RoundedRectangleBorder(borderRadius: AthurRadius.rMd),
        ),
      ),
      // --- Outlined button ---------------------------------------------------
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AthurColors.gold,
          side: const BorderSide(color: AthurColors.gold, width: 1.2),
          minimumSize: const Size.fromHeight(52),
          textStyle: AthurTypography.button.copyWith(color: AthurColors.gold),
          shape: const RoundedRectangleBorder(borderRadius: AthurRadius.rMd),
        ),
      ),
      // --- Text button -------------------------------------------------------
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AthurColors.gold,
          textStyle: AthurTypography.button.copyWith(color: AthurColors.gold),
        ),
      ),
      // --- Icon button (accessible 48dp target) ------------------------------
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: AthurColors.textPrimary,
          minimumSize: const Size(48, 48),
        ),
      ),
      // --- Inputs ------------------------------------------------------------
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AthurColors.surfaceInput,
        hintStyle: AthurTypography.bodySecondary.copyWith(
          color: AthurColors.textMuted,
        ),
        labelStyle: AthurTypography.bodySecondary,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AthurSpacing.lg,
          vertical: AthurSpacing.lg,
        ),
        border: const OutlineInputBorder(
          borderRadius: AthurRadius.rMd,
          borderSide: BorderSide(color: AthurColors.border),
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: AthurRadius.rMd,
          borderSide: BorderSide(color: AthurColors.border),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: AthurRadius.rMd,
          borderSide: BorderSide(color: AthurColors.gold, width: 1.4),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: AthurRadius.rMd,
          borderSide: BorderSide(color: AthurColors.danger),
        ),
        focusedErrorBorder: const OutlineInputBorder(
          borderRadius: AthurRadius.rMd,
          borderSide: BorderSide(color: AthurColors.danger, width: 1.4),
        ),
      ),
      // --- Bottom sheet ------------------------------------------------------
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AthurColors.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: AthurColors.surface,
        showDragHandle: true,
        dragHandleColor: AthurColors.borderStrong,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AthurRadius.xl),
          ),
        ),
      ),
      // --- Dialog ------------------------------------------------------------
      dialogTheme: const DialogThemeData(
        backgroundColor: AthurColors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: AthurRadius.rLg),
        titleTextStyle: AthurTypography.title,
        contentTextStyle: AthurTypography.bodySecondary,
      ),
      // --- Snackbar ----------------------------------------------------------
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AthurColors.surfaceElevated,
        contentTextStyle: AthurTypography.body,
        actionTextColor: AthurColors.gold,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: AthurRadius.rSm),
        elevation: 0,
      ),
      // --- Switch / progress -------------------------------------------------
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AthurColors.gold
              : AthurColors.textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AthurColors.goldDeep
              : AthurColors.border,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AthurColors.gold,
        linearTrackColor: AthurColors.border,
        circularTrackColor: AthurColors.border,
      ),
      // --- Scrollbar (global, gold accent) -----------------------------------
      // Applies to every scrollable that renders a Scrollbar with the theme
      // default. Long lists use ScrollbarTheme via AthurScrollable too.
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.dragged)
              ? AthurColors.gold
              : AthurColors.goldDeep.withValues(alpha: 0.6),
        ),
        trackColor: WidgetStateProperty.all(Colors.transparent),
        trackBorderColor: WidgetStateProperty.all(Colors.transparent),
        thickness: WidgetStateProperty.all(4),
        radius: const Radius.circular(AthurRadius.pill),
        crossAxisMargin: 2,
        mainAxisMargin: 2,
        interactive: true,
      ),
      // --- Selection / text --------------------------------------------------
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: AthurColors.gold,
        selectionColor: AthurColors.goldGlow,
        selectionHandleColor: AthurColors.gold,
      ),
      // --- List tiles --------------------------------------------------------
      listTileTheme: const ListTileThemeData(
        iconColor: AthurColors.textSecondary,
        textColor: AthurColors.textPrimary,
        contentPadding: AthurSpacing.tilePadding,
      ),
      // --- Page transitions --------------------------------------------------
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
