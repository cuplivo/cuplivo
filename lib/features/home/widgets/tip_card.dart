import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';

const String kTipIndexKey = 'tip_index_v1';
const int kTipCount = 11;

class TipCard extends StatefulWidget {
  const TipCard({super.key});

  @override
  State<TipCard> createState() => _TipCardState();
}

class _TipCardState extends State<TipCard> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _loadIndex();
  }

  Future<void> _loadIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final idx = prefs.getInt(kTipIndexKey) ?? 0;
    if (mounted) setState(() => _index = idx % kTipCount);
  }

  Future<void> _next() async {
    final newIdx = (_index + 1) % kTipCount;
    setState(() => _index = newIdx);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kTipIndexKey, newIdx);
  }

  String _tipText(AppLocalizations l10n) {
    return switch (_index) {
      0 => l10n.sideDrawerTip1,
      1 => l10n.sideDrawerTip2,
      2 => l10n.sideDrawerTip3,
      3 => l10n.sideDrawerTip4,
      4 => l10n.sideDrawerTip5,
      5 => l10n.sideDrawerTip6,
      6 => l10n.sideDrawerTip7,
      7 => l10n.sideDrawerTip8,
      8 => l10n.sideDrawerTip9,
      9 => l10n.sideDrawerTip10,
      _ => l10n.sideDrawerTip11,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Lucide.Lightbulb, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.sideDrawerTipTitle,
                      style: TextStyle(fontWeight: AppFontWeights.emphasis),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _next,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Lucide.RefreshCw,
                        size: 16,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _tipText(l10n),
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
