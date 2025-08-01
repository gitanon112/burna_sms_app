// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'service_data.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

CountryService _$CountryServiceFromJson(Map<String, dynamic> json) =>
    CountryService(
      originalPrice: (json['original_price'] as num).toDouble(),
      burnaPrice: (json['burna_price'] as num).toDouble(),
      available: json['available'] as bool,
      count: (json['count'] as num).toInt(),
      name: json['name'] as String,
    );

Map<String, dynamic> _$CountryServiceToJson(CountryService instance) =>
    <String, dynamic>{
      'original_price': instance.originalPrice,
      'burna_price': instance.burnaPrice,
      'available': instance.available,
      'count': instance.count,
      'name': instance.name,
    };

ServiceData _$ServiceDataFromJson(Map<String, dynamic> json) => ServiceData(
  serviceCode: json['service_code'] as String,
  name: json['name'] as String,
  countries: (json['countries'] as Map<String, dynamic>).map(
    (k, e) => MapEntry(k, CountryService.fromJson(e as Map<String, dynamic>)),
  ),
);

Map<String, dynamic> _$ServiceDataToJson(ServiceData instance) =>
    <String, dynamic>{
      'service_code': instance.serviceCode,
      'name': instance.name,
      'countries': instance.countries,
    };

ServicesResponse _$ServicesResponseFromJson(Map<String, dynamic> json) =>
    ServicesResponse(
      services: (json['services'] as Map<String, dynamic>).map(
        (k, e) => MapEntry(k, ServiceData.fromJson(e as Map<String, dynamic>)),
      ),
    );

Map<String, dynamic> _$ServicesResponseToJson(ServicesResponse instance) =>
    <String, dynamic>{'services': instance.services};
