import 'package:json_annotation/json_annotation.dart';

part 'user.g.dart';

@JsonSerializable()
class User {
  final String id;
  final String email;
  @JsonKey(name: 'created_at')
  final DateTime createdAt;
  @JsonKey(name: 'updated_at')
  final DateTime updatedAt;
  @JsonKey(name: 'total_spent')
  final double totalSpent;
  @JsonKey(name: 'total_rentals')
  final int totalRentals;
  @JsonKey(name: 'stripe_customer_id')
  final String? stripeCustomerId;

  // New wallet field from DB
  @JsonKey(name: 'wallet_balance_cents')
  final int walletBalanceCents;

  // Convenience getter for UI
  double get walletBalanceDollars => walletBalanceCents / 100.0;

  User({
    required this.id,
    required this.email,
    required this.createdAt,
    required this.updatedAt,
    this.totalSpent = 0.0,
    this.totalRentals = 0,
    this.stripeCustomerId,
    this.walletBalanceCents = 0,
  });

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
  Map<String, dynamic> toJson() => _$UserToJson(this);

  User copyWith({
    String? id,
    String? email,
    DateTime? createdAt,
    DateTime? updatedAt,
    double? totalSpent,
    int? totalRentals,
    String? stripeCustomerId,
    int? walletBalanceCents,
  }) {
    return User(
      id: id ?? this.id,
      email: email ?? this.email,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      totalSpent: totalSpent ?? this.totalSpent,
      totalRentals: totalRentals ?? this.totalRentals,
      stripeCustomerId: stripeCustomerId ?? this.stripeCustomerId,
      walletBalanceCents: walletBalanceCents ?? this.walletBalanceCents,
    );
  }
}