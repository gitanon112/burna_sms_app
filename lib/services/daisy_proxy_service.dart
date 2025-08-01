import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';
import '../models/service_data.dart';
import '../models/rental.dart';

class DaisyProxyService {
  static final DaisyProxyService _instance = DaisyProxyService._internal();
  factory DaisyProxyService() => _instance;
  DaisyProxyService._internal();

  final String _baseUrl = AppConstants.daisyProxyBaseUrl;
  
  // Get authentication token for API requests
  Future<String?> _getAuthToken() async {
    // This would get the auth token from secure storage or Supabase
    // For now, we'll use a placeholder - this should be implemented when auth is ready
    return 'placeholder-token';
  }

  // Get headers for API requests
  Future<Map<String, String>> _getHeaders() async {
    final token = await _getAuthToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // Get available services from DaisySMS via Python proxy
  Future<ServicesResponse> getAvailableServices() async {
    try {
      final headers = await _getHeaders();
      final response = await http.get(
        Uri.parse('$_baseUrl/api/services'),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        
        // Python API wraps response in {"success": true, "services": {...}}
        if (data['success'] == true && data['services'] != null) {
          return ServicesResponse.fromJson({'services': data['services']});
        } else {
          throw Exception('Invalid services response format');
        }
      } else {
        throw Exception('Failed to get services: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      throw Exception('Error fetching services: $e');
    }
  }

  // Purchase a phone number via Python proxy
  Future<Rental> purchaseNumber({
    required String serviceCode,
    required String countryCode,
  }) async {
    try {
      final headers = await _getHeaders();
      final requestBody = {
        'service': serviceCode,
        'country': countryCode,
      };

      final response = await http.post(
        Uri.parse('$_baseUrl/api/purchase'),
        headers: headers,
        body: json.encode(requestBody),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        
        // Python API wraps response in {"success": true, "rental": {...}}
        if (data['success'] == true && data['rental'] != null) {
          return Rental.fromJson(data['rental']);
        } else {
          throw Exception('Invalid purchase response format');
        }
      } else {
        final errorData = json.decode(response.body);
        throw Exception(errorData['detail'] ?? 'Failed to purchase number');
      }
    } catch (e) {
      throw Exception('Error purchasing number: $e');
    }
  }

  // Check SMS for a rental via Python proxy
  Future<Rental> checkSms(String rentalId) async {
    try {
      final headers = await _getHeaders();
      final response = await http.get(
        Uri.parse('$_baseUrl/api/sms/$rentalId'),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        
        // Python API wraps response in {"success": true, "rental": {...}}
        if (data['success'] == true && data['rental'] != null) {
          return Rental.fromJson(data['rental']);
        } else {
          throw Exception('Invalid SMS check response format');
        }
      } else {
        final errorData = json.decode(response.body);
        throw Exception(errorData['detail'] ?? 'Failed to check SMS');
      }
    } catch (e) {
      throw Exception('Error checking SMS: $e');
    }
  }

  // Cancel a rental via Python proxy
  Future<bool> cancelRental(String rentalId) async {
    try {
      final headers = await _getHeaders();
      final response = await http.post(
        Uri.parse('$_baseUrl/api/cancel/$rentalId'),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        // Python API returns {"success": boolean} directly
        return data['success'] == true;
      } else {
        final errorData = json.decode(response.body);
        throw Exception(errorData['detail'] ?? 'Failed to cancel rental');
      }
    } catch (e) {
      throw Exception('Error canceling rental: $e');
    }
  }

  // Get pricing for a specific service and country
  Future<Map<String, double>> getPricing(String serviceCode, String countryCode) async {
    try {
      final services = await getAvailableServices();
      
      if (services.services.containsKey(serviceCode)) {
        final service = services.services[serviceCode]!;
        if (service.countries.containsKey(countryCode)) {
          final country = service.countries[countryCode]!;
          return {
            'original_price': country.originalPrice,
            'burna_price': country.burnaPrice,
          };
        }
      }
      
      throw Exception('Service or country not available');
    } catch (e) {
      throw Exception('Error getting pricing: $e');
    }
  }

  // Utility method to check if a service is available
  Future<bool> isServiceAvailable(String serviceCode, String countryCode) async {
    try {
      final services = await getAvailableServices();
      
      if (services.services.containsKey(serviceCode)) {
        final service = services.services[serviceCode]!;
        if (service.countries.containsKey(countryCode)) {
          return service.countries[countryCode]!.available;
        }
      }
      
      return false;
    } catch (e) {
      return false;
    }
  }

  // Get service statistics
  Future<Map<String, dynamic>> getServiceStats() async {
    try {
      final headers = await _getHeaders();
      final response = await http.get(
        Uri.parse('$_baseUrl/api/stats'),
        headers: headers,
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to get stats: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error fetching stats: $e');
    }
  }

  // Health check for the proxy service
  Future<bool> healthCheck() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/health'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}