import 'package:flutter/material.dart';

/// Money always rendered with an explicit PKR label, per DESIGN.md.
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.amount, {
    super.key,
    this.style,
    this.semanticLabel,
  });

  /// Two-decimal string such as "250.00" or "-450.00".
  final String amount;
  final TextStyle? style;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final text = 'PKR $amount';
    return Text(
      text,
      style: style,
      semanticsLabel: semanticLabel ?? text,
    );
  }
}
