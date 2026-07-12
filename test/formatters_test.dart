import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/utils/formatters.dart';

void main() {
  group('Formatters.formatDoubleWithSign', () {
    test('positive value gets a + prefix', () {
      expect(Formatters.formatDoubleWithSign(3.14), '+3.14');
    });

    test('negative value gets a - prefix', () {
      expect(Formatters.formatDoubleWithSign(-2.5), '-2.50');
    });

    test('zero is treated as positive', () {
      expect(Formatters.formatDoubleWithSign(0.0), '+0.00');
    });

    test('respects custom decimalPlaces', () {
      expect(Formatters.formatDoubleWithSign(1.23456, decimalPlaces: 4), '+1.2346');
    });

    test('large negative value', () {
      expect(Formatters.formatDoubleWithSign(-1000.0), '-1000.00');
    });
  });

  group('Formatters.formatPercentageDouble', () {
    test('positive percentage gets a + prefix and 1 decimal by default', () {
      expect(Formatters.formatPercentageDouble(5.678), '+5.7');
    });

    test('negative percentage gets a - prefix', () {
      expect(Formatters.formatPercentageDouble(-3.4), '-3.4');
    });

    test('zero is treated as positive', () {
      expect(Formatters.formatPercentageDouble(0.0), '+0.0');
    });

    test('respects custom decimalPlaces', () {
      expect(Formatters.formatPercentageDouble(12.3456, decimalPlaces: 2), '+12.35');
    });
  });

  group('Formatters.formatCurrencySymbol', () {
    test('EUR returns €', () {
      expect(Formatters.formatCurrencySymbol('EUR'), '€');
    });

    test('lowercase eur is normalised to EUR', () {
      expect(Formatters.formatCurrencySymbol('eur'), '€');
    });

    test('USD returns \$', () {
      expect(Formatters.formatCurrencySymbol('USD'), '\$');
    });

    test('GBP returns £', () {
      expect(Formatters.formatCurrencySymbol('GBP'), '£');
    });

    test('unknown currency code is returned as-is', () {
      expect(Formatters.formatCurrencySymbol('CHF'), 'CHF');
    });

    test('null returns empty string', () {
      expect(Formatters.formatCurrencySymbol(null), '');
    });
  });

  // Les mises en forme monétaires françaises utilisent des espaces insécables
  // (U+202F pour les milliers, U+00A0 avant le symbole). On les normalise en
  // espaces ordinaires pour des assertions lisibles et robustes.
  String norm(String s) => s
      .replaceAll('\u{202F}', ' ') // narrow no-break space (milliers)
      .replaceAll('\u{00A0}', ' ') // no-break space (avant symbole)
      .trim();

  group('Formatters.formatCurrency (mise en forme FR)', () {
    test('formats EUR value with € symbol', () {
      expect(norm(Formatters.formatCurrency(1234.5, 'EUR')), '1 234,50 €');
    });

    test('formats USD value with \$ symbol', () {
      expect(norm(Formatters.formatCurrency(99.9, 'USD')), '99,90 \$');
    });

    test('formats GBP value with £ symbol', () {
      expect(norm(Formatters.formatCurrency(50.0, 'GBP')), '50,00 £');
    });

    test('groups thousands with a separator', () {
      expect(norm(Formatters.formatCurrency(1000, 'EUR')), '1 000,00 €');
    });

    test('respects custom decimalPlaces', () {
      expect(norm(Formatters.formatCurrency(9.999, 'USD', decimalPlaces: 0)), '10 \$');
    });

    test('null currency falls back to empty symbol', () {
      expect(norm(Formatters.formatCurrency(42.0, null)), '42,00');
    });
  });

  group('Formatters.formatEur / formatEurSigned', () {
    test('formatEur groups thousands and suffixes €', () {
      expect(norm(Formatters.formatEur(153112.95)), '153 112,95 €');
    });

    test('formatEurSigned prefixes + on a positive amount', () {
      expect(norm(Formatters.formatEurSigned(3309.72)), '+3 309,72 €');
    });

    test('formatEurSigned prefixes - on a negative amount', () {
      expect(norm(Formatters.formatEurSigned(-1234.5)), '-1 234,50 €');
    });

    test('formatEurSigned treats zero as positive', () {
      expect(norm(Formatters.formatEurSigned(0)), '+0,00 €');
    });
  });

  group('Formatters.formatPercentFr', () {
    test('positive uses + sign, comma and a % suffix', () {
      expect(norm(Formatters.formatPercentFr(2.2)), '+2,2 %');
    });

    test('negative uses - sign', () {
      expect(norm(Formatters.formatPercentFr(-4.8)), '-4,8 %');
    });

    test('separates the % with a non-breaking space', () {
      expect(Formatters.formatPercentFr(2.2), '+2,2\u{00A0}%');
    });
  });

  group('Formatters.getChangeColor', () {
    test('positive value returns the positive (green) color', () {
      final color = Formatters.getChangeColor(1.0);
      expect(color, const Color(0xFF1B5E20));
    });

    test('zero returns the positive color', () {
      final color = Formatters.getChangeColor(0.0);
      expect(color, const Color(0xFF1B5E20));
    });

    test('negative value returns the negative (red) color', () {
      final color = Formatters.getChangeColor(-0.01);
      expect(color, const Color(0xFFB71C1C));
    });

    test('custom positive/negative colors are respected', () {
      const customPos = Color(0xFF00FF00);
      const customNeg = Color(0xFFFF0000);
      expect(
        Formatters.getChangeColor(5.0, positive: customPos, negative: customNeg),
        customPos,
      );
      expect(
        Formatters.getChangeColor(-5.0, positive: customPos, negative: customNeg),
        customNeg,
      );
    });
  });
}
