import 'package:json_annotation/json_annotation.dart';

part 'service_data.g.dart';

@JsonSerializable()
class CountryService {
  @JsonKey(name: 'original_price')
  final double originalPrice;
  @JsonKey(name: 'burna_price')
  final double burnaPrice;
  final bool available;
  final int count;
  final String name;
  // Daisy short-term rental TTL in seconds (if known from API)
  @JsonKey(name: 'ttl_seconds')
  final int? ttlSeconds;

  CountryService({
    required this.originalPrice,
    required this.burnaPrice,
    required this.available,
    required this.count,
    required this.name,
    this.ttlSeconds,
  });

  factory CountryService.fromJson(Map<String, dynamic> json) => _$CountryServiceFromJson(json);
  Map<String, dynamic> toJson() => _$CountryServiceToJson(this);
}

@JsonSerializable()
class ServiceData {
  @JsonKey(name: 'service_code')
  final String serviceCode;
  final String name;
  final Map<String, CountryService> countries;

  ServiceData({
    required this.serviceCode,
    required this.name,
    required this.countries,
  });

  factory ServiceData.fromJson(Map<String, dynamic> json) => _$ServiceDataFromJson(json);
  Map<String, dynamic> toJson() => _$ServiceDataToJson(this);

  List<CountryService> get availableCountries {
    return countries.values.where((country) => country.available).toList();
  }
  
  int get totalAvailableCount {
    return availableCountries.fold(0, (sum, country) => sum + country.count);
  }
}

@JsonSerializable()
class ServicesResponse {
  final Map<String, ServiceData> services;

  ServicesResponse({required this.services});

  factory ServicesResponse.fromJson(Map<String, dynamic> json) => _$ServicesResponseFromJson(json);
  Map<String, dynamic> toJson() => _$ServicesResponseToJson(this);

  List<ServiceData> get availableServices {
    return services.values.where((service) => service.availableCountries.isNotEmpty).toList();
  }
}