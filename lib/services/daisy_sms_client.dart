import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// Direct DaisySMS API client for Flutter
/// Ported from burna-sms/backend/daisy_client.py
class DaisySMSClient {
  final String apiKey;
  final String baseUrl = 'https://daisysms.com/stubs/handler_api.php';

  DaisySMSClient({required this.apiKey});

  /// Make HTTP request to DaisySMS API
  Future<String> _makeRequest(String action, {Map<String, String>? extraParams}) async {
    final params = {
      'api_key': apiKey,
      'action': action,
      ...?extraParams,
    };

    final uri = Uri.parse(baseUrl).replace(queryParameters: params);
    
    debugPrint('DaisySMS Request: ${uri.toString()}');

    try {
      final response = await http.get(uri);
      
      debugPrint('DaisySMS Response (${response.statusCode}): ${response.body}');
      
      if (response.statusCode == 200) {
        return response.body;
      } else {
        throw Exception('DaisySMS API request failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      throw Exception('Error making DaisySMS request: $e');
    }
  }

  /// Get current DaisySMS balance
  Future<double> getBalance() async {
    final response = await _makeRequest('getBalance');
    
    if (response.startsWith('ACCESS_BALANCE:')) {
      final balanceStr = response.split(':')[1];
      return double.parse(balanceStr);
    }
    
    throw Exception('Failed to get balance: $response');
  }

  /// Get available services with pricing from DaisySMS
  /// Also surfaces human-friendly service and country names when provided by Daisy.
  Future<Map<String, Map<String, ServicePricing>>> getServices() async {
    final response = await _makeRequest('getPricesVerification');
    try {
      final data = json.decode(response) as Map<String, dynamic>;
      final services = <String, Map<String, ServicePricing>>{};
  
      for (final entry in data.entries) {
        final serviceCode = entry.key;
        final countries = entry.value as Map<String, dynamic>;
        final serviceCountries = <String, ServicePricing>{};
  
        for (final countryEntry in countries.entries) {
          final countryCode = countryEntry.key;
          final countryData = countryEntry.value as Map<String, dynamic>;
  
          // Daisy responses typically include:
          // name, ttl, count, cost, repeatable at the country level.
          final serviceName = (countryData['name']?.toString() ?? '').trim();
          final price = double.tryParse(countryData['cost']?.toString() ?? '0') ?? 0.0;
          final count = int.tryParse(countryData['count']?.toString() ?? '') ?? (countryData['count'] as int? ?? 0);
          final available = count > 0;
          // ttl is in seconds per API docs
          final ttl = int.tryParse(countryData['ttl']?.toString() ?? '') ?? (countryData['ttl'] as int? ?? 0);
  
          serviceCountries[countryCode] = ServicePricing(
            price: price,
            available: available,
            count: count,
            name: serviceName.isNotEmpty ? serviceName : null,
            ttlSeconds: ttl > 0 ? ttl : null,
          );
        }
  
        if (serviceCountries.isNotEmpty) {
          services[serviceCode] = serviceCountries;
        }
      }
  
      return services;
    } catch (e) {
      throw Exception('Failed to parse services response: $e');
    }
  }

  /// Rent a number from DaisySMS
  /// Supports max_price, duration (e.g., '12H','1D'), auto_renew ('0'/'1'), carriers, areas.
  Future<DaisyRental> rentNumber(
    String service, {
    String? maxPrice,
    String? duration,
    String? autoRenew,
    String? carriers,
    String? areas,
    String? number,
  }) async {
    // DaisySMS is US-only; do NOT send any 'country' parameter.
    final params = <String, String>{
      'service': service,
    };
    if (maxPrice != null) params['max_price'] = maxPrice;
    if (duration != null) params['duration'] = duration;
    if (autoRenew != null) params['auto_renew'] = autoRenew;
    if (carriers != null) params['carriers'] = carriers;
    if (areas != null) params['areas'] = areas;
    if (number != null) params['number'] = number;

    final response = await _makeRequest('getNumber', extraParams: params);

    if (response.startsWith('ACCESS_NUMBER:')) {
      final parts = response.split(':');
      if (parts.length >= 3) {
        return DaisyRental(
          id: parts[1],
          number: parts[2],
          service: service,
          country: 'US',
        );
      }
    }

    // Surface Daisy errors directly to aid debugging (e.g., NO_NUMBERS, NO_MONEY, MAX_PRICE_EXCEEDED)
    throw Exception('Failed to rent number: $response');
  }

  /// Check for SMS on rented number
  Future<String?> getSms(String rentalId) async {
    try {
      final response = await _makeRequest('getStatus', extraParams: {
        'id': rentalId,
      });

      if (response.startsWith('STATUS_OK:')) {
        final colonIndex = response.indexOf(':');
        return colonIndex != -1 ? response.substring(colonIndex + 1) : null;
      }

      // Waiting states
      if (response == 'STATUS_WAIT_CODE' || response == 'STATUS_WAIT_RETRY' || response == 'STATUS_WAITING') {
        return null;
      }

      // Cancellation/termination states -> no code
      if (response == 'STATUS_CANCEL' || response == 'ACCESS_CANCEL' || response == 'NO_ACTIVATION' || response == 'ACCESS_READY') {
        return null;
      }

      // Unknown status: just log and return null
      debugPrint('DaisySMS getStatus for $rentalId: $response');
      return null;
    } catch (e) {
      // Swallow network/400s here and treat as no message yet, to avoid crashing expiry handler loops
      debugPrint('DaisySMS getStatus error for $rentalId: $e');
      return null;
    }
  }

  /// Cancel a rental on DaisySMS
  Future<bool> cancelRental(String rentalId) async {
    final response = await _makeRequest('setStatus', extraParams: {
      'id': rentalId,
      'status': '8', // Cancel status
    });

    return response == 'ACCESS_CANCEL';
  }

  /// Health check - test if API key is working
  Future<bool> healthCheck() async {
    try {
      await getBalance();
      return true;
    } catch (e) {
      debugPrint('DaisySMS health check failed: $e');
      return false;
    }
  }
}

/// Service pricing information from DaisySMS
class ServicePricing {
  final double price;
  final bool available;
  final int count;
  // Optional human-friendly service name from Daisy (per-country entry)
  final String? name;
  // TTL in seconds for short-term rental, when provided by Daisy
  final int? ttlSeconds;

  const ServicePricing({
    required this.price,
    required this.available,
    required this.count,
    this.name,
    this.ttlSeconds,
  });

  @override
  String toString() => 'ServicePricing(price: $price, available: $available, count: $count, name: $name, ttlSeconds: $ttlSeconds)';
}

/// DaisySMS rental information
class DaisyRental {
  final String id;
  final String number;
  final String service;
  final String country; // logical country label; Daisy is US-only

  const DaisyRental({
    required this.id,
    required this.number,
    required this.service,
    required this.country,
  });

  @override
  String toString() => 'DaisyRental(id: $id, number: $number, service: $service, country: $country)';
}