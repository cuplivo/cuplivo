import 'package:flutter/material.dart';

/// Motion values shared by the conversational surface.
///
/// Keep these restrained: the interface should feel responsive before the
/// user consciously notices an animation.
abstract final class AppMotion {
  static const Duration instant = Duration(milliseconds: 100);
  static const Duration fast = Duration(milliseconds: 170);
  static const Duration standard = Duration(milliseconds: 240);
  static const Duration streamingReveal = Duration(milliseconds: 210);
  static const Duration emphasized = Duration(milliseconds: 320);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve emphasizedEnter = Curves.easeOutBack;
}
