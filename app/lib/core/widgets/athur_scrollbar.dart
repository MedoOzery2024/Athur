import 'package:flutter/material.dart';

/// A drop-in replacement for [ListView] / [GridView] wrappers that guarantees
/// Athur's global requirement: **every scrollable page exposes a themed
/// scrollbar** without harming small-screen UX.
///
/// Why a wrapper instead of turning on [Scrollbar] everywhere:
/// - Ensures consistent gold-accent styling app-wide.
/// - On touch devices a permanently-drawn scrollbar can cover content, so the
///   thumb is only painted while scrolling or dragging; the theme supplies the
///   colors via [ThemeData.scrollbarTheme].
/// - Keeps controllers owned by the caller when one is supplied, so scroll
///   position can be restored (important for long chat/message lists).
///
/// Usage:
/// ```dart
/// AthurScrollbar(
///   child: ListView.builder(...),
/// )
/// ```
class AthurScrollbar extends StatelessWidget {
  const AthurScrollbar({
    super.key,
    required this.child,
    this.controller,
    this.thickness,
  });

  /// The scrollable (ListView, GridView, SingleChildScrollView, CustomScrollView…).
  final Widget child;

  /// Optional controller. When provided it is also attached to the scrollbar so
  /// dragging the thumb works and position can be restored.
  final ScrollController? controller;

  /// Optional override of the thumb thickness for large screens.
  final double? thickness;

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: controller,
      // Paint only during scroll/drag by default (mobile-friendly), but stay
      // fully interactive.
      thumbVisibility: false,
      interactive: true,
      thickness: thickness,
      radius: const Radius.circular(999),
      child: child,
    );
  }
}

/// A scrollbar variant intended for **fixed long lists on larger screens**
/// (tablet/desktop) where an always-visible track aids usability.
class AthurPersistentScrollbar extends StatelessWidget {
  const AthurPersistentScrollbar({
    super.key,
    required this.child,
    this.controller,
  });

  final Widget child;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      interactive: true,
      thickness: 6,
      radius: const Radius.circular(999),
      child: child,
    );
  }
}
