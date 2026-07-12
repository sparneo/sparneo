// lib/model/wallet.dart
import 'dart:math';

class Wallet {
  final String id;
  final String name;
  final DateTime createdAt;

  Wallet({
    required this.id,
    required this.name,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  // --- Sérialisation JSON ---

  factory Wallet.fromJson(Map<String, dynamic> json) {
    return Wallet(
      id: json['id'] ?? '',
      name: json['name'] ?? 'Sans nom',
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  static String generateId() {
    // Microsecondes epoch + suffixe aléatoire en base 36 pour éviter les collisions
    // lors de créations simultanées dans la même milliseconde.
    final suffix = Random().nextInt(0x7FFFFFFF).toRadixString(36).padLeft(6, '0');
    return '${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }
}