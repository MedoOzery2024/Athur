import 'package:flutter/material.dart';

import '../constants/athur_assets.dart';
import '../theme/athur_colors.dart';

/// The official Athur brand mark.
///
/// Wraps the single logo asset and exposes the sizes/variants used across the
/// app (splash, auth header, profile, app bar). The logo is never redrawn or
/// recolored — per project rules only the surrounding chrome adapts.
class AthurLogo extends StatelessWidget {
  const AthurLogo({
    super.key,
    this.size = 96,
    this.showGlow = false,
    this.semanticLabel = 'Athur',
  });

  /// Rendered edge length in logical pixels (logo is square).
  final double size;

  /// Adds a soft gold glow behind the mark — used sparingly on hero screens.
  final bool showGlow;

  /// Accessible description for screen readers.
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      AthurAssets.logo,
      width: size,
      height: size,
      fit: BoxFit.contain,
      // The mark is decorative-adjacent; the wrapper carries the semantic label.
      excludeFromSemantics: true,
      filterQuality: FilterQuality.medium,
    );

    if (!showGlow) {
      return Semantics(label: semanticLabel, image: true, child: image);
    }

    return Semantics(
      label: semanticLabel,
      image: true,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AthurColors.goldGlow,
              blurRadius: 42,
              spreadRadius: 2,
            ),
          ],
        ),
        child: image,
      ),
    );
  }
}

/// Wordmark + mark lockup used on splash and auth screens.
class AthurBrandLockup extends StatelessWidget {
  const AthurBrandLockup({
    super.key,
    this.logoSize = 104,
    this.showTagline = true,
  });

  final double logoSize;
  final bool showTagline;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AthurLogo(size: logoSize, showGlow: true),
        const SizedBox(height: 20),
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) =>
              AthurColors.goldSheen.createShader(bounds),
          child: const Text(
            'Athur',
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.5,
              color: Colors.white, // masked by the gold shader
            ),
          ),
        ),
        if (showTagline) ...[
          const SizedBox(height: 8),
          Text(
            'Connect clearly. Communicate freely.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: AthurColors.textMuted, letterSpacing: 0.3),
          ),
        ],
      ],
    );
  }
}
