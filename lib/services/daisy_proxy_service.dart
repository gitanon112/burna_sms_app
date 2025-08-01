import 'package:http/http.dart' as http;
import '../models/service_data.dart';
import '../models/rental.dart';
import 'burna_service.dart';

/// This class now acts as a wrapper around BurnaService
/// to maintain compatibility with existing code
/// Previously it was calling Python backend at localhost:8000
/// Now it uses direct DaisySMS integration via BurnaService
class DaisyProxyService {
  static final DaisyProxyService _instance = DaisyProxyService._internal();
  factory DaisyProxyService() => _instance;
  DaisyProxyService._internal();

  final BurnaService _burnaService = BurnaService();
  
  // Get available services directly from DaisySMS
  Future<ServicesResponse> getAvailableServices() async {
    try {
      return await _burnaService.getAvailableServices();
    } catch (e) {
      throw Exception('Error fetching services: $e');
    }
  }

  // Purchase a phone number directly via DaisySMS
  Future<Rental> purchaseNumber({
    required String serviceCode,
    required String countryCode,
  }) async {
    try {
      return await _burnaService.purchaseNumber(
        serviceCode: serviceCode,
        countryCode: countryCode,
      );
    } catch (e) {
      throw Exception('Error purchasing number: $e');
    }
  }

  // Check SMS for a rental directly via DaisySMS
  Future<Rental> checkSms(String rentalId) async {
    try {
      return await _burnaService.checkSms(rentalId);
    } catch (e) {
      throw Exception('Error checking SMS: $e');
    }
  }

  // Cancel a rental directly via DaisySMS
  Future<bool> cancelRental(String rentalId) async {
    try {
      return await _burnaService.cancelRental(rentalId);
    } catch (e) {
      throw Exception('Error canceling rental: $e');
    }
  }

  // Get pricing for a specific service and country
  Future<Map<String, double>> getPricing(String serviceCode, String countryCode) async {
    try {
      return await _burnaService.getPricing(serviceCode, countryCode);
    } catch (e) {
      throw Exception('Error getting pricing: $e');
    }
  }

  // Utility method to check if a service is available
  Future<bool> isServiceAvailable(String serviceCode, String countryCode) async {
    try {
      return await _burnaService.isServiceAvailable(serviceCode, countryCode);
    } catch (e) {
      return false;
    }
  }

  // Get service statistics
  Future<Map<String, dynamic>> getServiceStats() async {
    try {
      // This endpoint doesn't exist in BurnaService yet
      // For now, return basic stats
      final rentals = await _burnaService.getUserRentals();
      final balance = await _burnaService.getDaisyBalance();
      
      return {
        'total_rentals': rentals.length,
        'active_rentals': rentals.where((r) => r.status == 'active').length,
        'completed_rentals': rentals.where((r) => r.status == 'completed').length,
        'daisy_balance': balance,
      };
    } catch (e) {
      throw Exception('Error fetching stats: $e');
    }
  }

  // Health check for the service
  Future<bool> healthCheck() async {
    try {
      return await _burnaService.healthCheck();
    } catch (e) {
      return false;
    }
  }

  // Start expiry monitoring
  void startExpiryMonitoring() {
    _burnaService.startExpiryMonitoring();
  }

  // Stop expiry monitoring
  void stopExpiryMonitoring() {
    _burnaService.stopExpiryMonitoring();
  }

  // Force check expired rentals
  Future<void> checkExpiredRentals() async {
    await _burnaService.checkExpiredRentals();
  }
}