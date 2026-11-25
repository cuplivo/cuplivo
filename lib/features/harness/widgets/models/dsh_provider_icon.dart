import 'package:flutter/material.dart';

import 'package:Cuplivo/shared/widgets/configurable_avatar.dart';
import 'package:Cuplivo/utils/brand_assets.dart';

/// The circular mark of one DeepSeek Harness provider route.
///
/// DSH sends no avatar, so the brand asset Cuplivo already ships for a model or
/// provider name is used when it exists, and a monogram of the display name
/// otherwise (the reference renders letters for routes without a logo). The
/// remote's own name wins over the route id.
class DshProviderIcon extends StatelessWidget {
  const DshProviderIcon({
    super.key,
    required this.providerId,
    required this.displayName,
    this.size = 36,
  });

  final String providerId;
  final String displayName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset =
        BrandAssets.assetForName(displayName) ??
        BrandAssets.assetForName(providerId);
    return ConfigurableAvatar(
      name: displayName.trim().isEmpty ? providerId : displayName,
      fallbackAsset: asset,
      size: size,
      iconScale: 0.72,
      withBackground: true,
    );
  }
}
