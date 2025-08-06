import 'package:json_annotation/json_annotation.dart';

part 'rental.g.dart';

@JsonSerializable()
class Rental {
  final String id;
  @JsonKey(name: 'user_id')
  final String userId;
  @JsonKey(name: 'daisy_rental_id')
  final String daisyRentalId;
  @JsonKey(name: 'service_code')
  final String serviceCode;
  @JsonKey(name: 'service_name')
  final String serviceName;
  @JsonKey(name: 'country_code')
  final String countryCode;
  @JsonKey(name: 'country_name')
  final String countryName;
  @JsonKey(name: 'phone_number')
  final String phoneNumber;
  
  // Frontend compatibility - alias for phone_number
  String get number => phoneNumber;
  
  @JsonKey(name: 'original_price')
  final double originalPrice;
  @JsonKey(name: 'burna_price')
  final double burnaPrice;
  final String status; // active, completed, cancelled
  @JsonKey(name: 'sms_received')
  final String? smsReceived;
  @JsonKey(name: 'created_at')
  final DateTime createdAt;
  @JsonKey(name: 'expires_at')
  final DateTime expiresAt;
  @JsonKey(name: 'stripe_payment_intent_id')
  final String? stripePaymentIntentId;
  @JsonKey(name: 'user_email')
  final String? userEmail;
  // Wallet hold linkage for success-only billing
  @JsonKey(name: 'wallet_hold_id')
  final String? walletHoldId;

  const Rental({
    required this.id,
    required this.userId,
    required this.daisyRentalId,
    required this.serviceCode,
    required this.serviceName,
    required this.countryCode,
    required this.countryName,
    required this.phoneNumber,
    required this.originalPrice,
    required this.burnaPrice,
    required this.status,
    this.smsReceived,
    required this.createdAt,
    required this.expiresAt,
    this.stripePaymentIntentId,
    this.userEmail,
    this.walletHoldId,
  });

  factory Rental.fromJson(Map<String, dynamic> json) => _$RentalFromJson(json);
  Map<String, dynamic> toJson() => _$RentalToJson(this);

  Rental copyWith({
    String? id,
    String? userId,
    String? daisyRentalId,
    String? serviceCode,
    String? serviceName,
    String? countryCode,
    String? countryName,
    String? phoneNumber,
    double? originalPrice,
    double? burnaPrice,
    String? status,
    String? smsReceived,
    DateTime? createdAt,
    DateTime? expiresAt,
    String? stripePaymentIntentId,
    String? userEmail,
    String? walletHoldId,
  }) {
    return Rental(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      daisyRentalId: daisyRentalId ?? this.daisyRentalId,
      serviceCode: serviceCode ?? this.serviceCode,
      serviceName: serviceName ?? this.serviceName,
      countryCode: countryCode ?? this.countryCode,
      countryName: countryName ?? this.countryName,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      originalPrice: originalPrice ?? this.originalPrice,
      burnaPrice: burnaPrice ?? this.burnaPrice,
      status: status ?? this.status,
      smsReceived: smsReceived ?? this.smsReceived,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      stripePaymentIntentId: stripePaymentIntentId ?? this.stripePaymentIntentId,
      userEmail: userEmail ?? this.userEmail,
      walletHoldId: walletHoldId ?? this.walletHoldId,
    );
  }

  bool get isActive => status == 'active';
  bool get isCompleted => status == 'completed';
  bool get isCancelled => status == 'cancelled';
  bool get hasReceivedSms => smsReceived != null && smsReceived!.isNotEmpty;
  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt.toUtc());
}