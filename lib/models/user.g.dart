// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

User _$UserFromJson(Map<String, dynamic> json) => User(
  id: json['id'] as String,
  email: json['email'] as String,
  createdAt: DateTime.parse(json['created_at'] as String),
  updatedAt: DateTime.parse(json['updated_at'] as String),
  totalSpent: (json['total_spent'] as num?)?.toDouble() ?? 0.0,
  totalRentals: (json['total_rentals'] as num?)?.toInt() ?? 0,
  stripeCustomerId: json['stripe_customer_id'] as String?,
);

Map<String, dynamic> _$UserToJson(User instance) => <String, dynamic>{
  'id': instance.id,
  'email': instance.email,
  'created_at': instance.createdAt.toIso8601String(),
  'updated_at': instance.updatedAt.toIso8601String(),
  'total_spent': instance.totalSpent,
  'total_rentals': instance.totalRentals,
  'stripe_customer_id': instance.stripeCustomerId,
};
