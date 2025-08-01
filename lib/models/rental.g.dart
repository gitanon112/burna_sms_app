// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'rental.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Rental _$RentalFromJson(Map<String, dynamic> json) => Rental(
  id: json['id'] as String,
  userId: json['user_id'] as String,
  daisyRentalId: json['daisy_rental_id'] as String,
  serviceCode: json['service_code'] as String,
  serviceName: json['service_name'] as String,
  countryCode: json['country_code'] as String,
  countryName: json['country_name'] as String,
  phoneNumber: json['phone_number'] as String,
  originalPrice: (json['original_price'] as num).toDouble(),
  burnaPrice: (json['burna_price'] as num).toDouble(),
  status: json['status'] as String,
  smsReceived: json['sms_received'] as String?,
  createdAt: DateTime.parse(json['created_at'] as String),
  expiresAt: DateTime.parse(json['expires_at'] as String),
  stripePaymentIntentId: json['stripe_payment_intent_id'] as String?,
  userEmail: json['user_email'] as String?,
);

Map<String, dynamic> _$RentalToJson(Rental instance) => <String, dynamic>{
  'id': instance.id,
  'user_id': instance.userId,
  'daisy_rental_id': instance.daisyRentalId,
  'service_code': instance.serviceCode,
  'service_name': instance.serviceName,
  'country_code': instance.countryCode,
  'country_name': instance.countryName,
  'phone_number': instance.phoneNumber,
  'original_price': instance.originalPrice,
  'burna_price': instance.burnaPrice,
  'status': instance.status,
  'sms_received': instance.smsReceived,
  'created_at': instance.createdAt.toIso8601String(),
  'expires_at': instance.expiresAt.toIso8601String(),
  'stripe_payment_intent_id': instance.stripePaymentIntentId,
  'user_email': instance.userEmail,
};
