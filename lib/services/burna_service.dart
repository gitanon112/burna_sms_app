import 'dart:async';
import 'package:uuid/uuid.dart';
import '../models/rental.dart';
import '../models/service_data.dart';
import 'daisy_sms_client.dart';
import 'supabase_service.dart';

/// Main business service that replaces the Python backend
/// Combines DaisySMS API calls with Supabase database operations
class BurnaService {
  static final BurnaService _instance = BurnaService._internal();
  factory BurnaService() => _instance;
  BurnaService._internal();

  final SupabaseService _supabaseService = SupabaseService();
  DaisySMSClient? _daisyClient;
  Timer? _expiryTimer;
  
  // Business configuration
  static const double markupMultiplier = 2.0;
  // TODO: Inject this from secure config (e.g., remote config, Supabase function, or dotenv in dev)
  static const String daisyApiKey = String.fromEnvironment('DAISY_API_KEY', defaultValue: 'XoEP1JKgg3XRqwq9D6XlfkE3yVTP0n');
  
  // Initialize DaisySMS client
  void _ensureDaisyClient() {
    if (_daisyClient == null) {
      if (daisyApiKey.isEmpty) {
        // Fail fast with clear error to avoid using a leaked key in source
        throw Exception('Daisy API key is not configured. Provide DAISY_API_KEY via --dart-define or secure config.');
      }
      _daisyClient = DaisySMSClient(apiKey: daisyApiKey);
    }
  }

  /// Get available services with Burna pricing (2x markup)
  Future<ServicesResponse> getAvailableServices() async {
    _ensureDaisyClient();
    
    try {
      print('BurnaService: Getting services from DaisySMS...');
      
      // Get services from DaisySMS
      final daisyServices = await _daisyClient!.getServices();
      print('BurnaService: Received ${daisyServices.length} services from DaisySMS');
      
      final burnaServices = <String, ServiceData>{};
      
      for (final entry in daisyServices.entries) {
        final serviceCode = entry.key;
        final countries = entry.value;
        final processedCountries = <String, CountryService>{};

        // Build countries -> CountryService and try to capture a readable service name
        String? inferredServiceName;

        for (final countryEntry in countries.entries) {
          final countryCode = countryEntry.key;
          final pricing = countryEntry.value;
 
          if (!pricing.available) continue;
 
          final originalPrice = pricing.price;
          final burnaPrice = (originalPrice * markupMultiplier).toStringAsFixed(2);
 
          // Use Daisy-provided service name if present on pricing.name
          if ((pricing.name ?? '').trim().isNotEmpty && inferredServiceName == null) {
            inferredServiceName = pricing.name!.trim();
          }
 
          final resolvedCountryName = _getCountryName(countryCode);
 
          processedCountries[countryCode] = CountryService(
            originalPrice: originalPrice,
            burnaPrice: double.parse(burnaPrice),
            available: pricing.available,
            count: pricing.count,
            name: resolvedCountryName,
            ttlSeconds: pricing.ttlSeconds, // from Daisy client
          );
        }

        if (processedCountries.isNotEmpty) {
          final serviceDisplayName =
              (inferredServiceName != null && inferredServiceName.isNotEmpty)
                  ? inferredServiceName
                  : serviceCode.toUpperCase();

          burnaServices[serviceCode] = ServiceData(
            serviceCode: serviceCode,
            name: serviceDisplayName,
            countries: processedCountries,
          );
        }
      }
      
      print('BurnaService: Processed ${burnaServices.length} services with markup');
      
      return ServicesResponse(services: burnaServices);
    } catch (e) {
      print('BurnaService ERROR: $e');
      throw Exception('Failed to get services: $e');
    }
  }

  /// Purchase a phone number for SMS verification
  Future<Rental> purchaseNumber({
    required String serviceCode,
    required String countryCode,
  }) async {
    _ensureDaisyClient();

    print('BurnaService: Starting purchase - service: $serviceCode, country: $countryCode');

    final currentUser = _supabaseService.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

    // Enforce wallet balance before allowing purchase
    // IMPORTANT: always read the authoritative wallet directly from DB to avoid stale/mapped values
    final walletCents = await _supabaseService.getWalletBalanceCents();
    if (walletCents <= 0) {
      throw Exception('Insufficient wallet balance. Please top up before purchasing a number.');
    }

    print('BurnaService: User authenticated - ${currentUser.email}');

    try {
      // Get service pricing
      print('BurnaService: Getting available services...');
      final services = await getAvailableServices();
      
      if (!services.services.containsKey(serviceCode) ||
          !services.services[serviceCode]!.countries.containsKey(countryCode)) {
        throw Exception('Service or country not available');
      }
      
      final countryInfo = services.services[serviceCode]!.countries[countryCode]!;
      print('BurnaService: Found pricing - original: ${countryInfo.originalPrice}, burna: ${countryInfo.burnaPrice}');
      
      // Rent number from DaisySMS
      print('BurnaService: Renting number from DaisySMS...');
      // Set max_price as originalPrice * 1.1 to avoid surprises; 2 decimals
      final maxPrice = (countryInfo.originalPrice * 1.1);
      final maxPriceStr = maxPrice.toStringAsFixed(2);

      final daisyRental = await _daisyClient!.rentNumber(
        serviceCode,
        country: countryCode,
        maxPrice: maxPriceStr,
        // Optional: support long-term via duration if we later expose via UI
        // duration: '1H',
      );
      
      print('BurnaService: Got number from DaisySMS - ${daisyRental.number} (id: ${daisyRental.id})');
      
      // Create rental in Supabase
      final rentalId = const Uuid().v4();
      // Use UTC for timestamps
      final now = DateTime.now().toUtc();

      // Align expiry to Daisy TTL if we have it; else default 15 minutes
      Duration expiryDuration;
      final maybeTtl = countryInfo.ttlSeconds;
      if (maybeTtl != null && maybeTtl > 0) {
        expiryDuration = Duration(seconds: maybeTtl);
      } else {
        expiryDuration = const Duration(minutes: 15);
      }
      final expiresAt = now.add(expiryDuration);
      
      final rentalData = {
        'id': rentalId,
        'user_id': currentUser.id,
        'daisy_rental_id': daisyRental.id,
        'service_code': serviceCode,
        'service_name': serviceCode.toUpperCase(),
        'country_code': countryCode,
        'country_name': countryInfo.name,
        'phone_number': daisyRental.number,
        'original_price': countryInfo.originalPrice,
        'burna_price': countryInfo.burnaPrice,
        'status': 'active',
        'created_at': now.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
        'user_email': currentUser.email,
      };
      
      print('BurnaService: Creating rental in Supabase...');
      final rental = await _supabaseService.createRental(rentalData);
      
      // Update user stats
      print('BurnaService: Updating user profile stats...');
      final userProfile = await _supabaseService.getCurrentUserProfile();
      if (userProfile != null) {
        final updatedProfile = userProfile.copyWith(
          totalSpent: userProfile.totalSpent + countryInfo.burnaPrice,
          totalRentals: userProfile.totalRentals + 1,
          updatedAt: now,
        );
        await _supabaseService.updateUserProfile(updatedProfile);
      }
      
      print('BurnaService: Purchase complete!');
      return rental;
    } catch (e) {
      print('BurnaService ERROR during purchase: $e');
      throw Exception('Failed to purchase number: $e');
    }
  }

  /// Check for SMS on a rental
  Future<Rental> checkSms(String rentalId) async {
    _ensureDaisyClient();
    
    final currentUser = _supabaseService.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }
    
    try {
      // Get rental from database
      final rental = await _supabaseService.getRentalById(rentalId);
      if (rental == null) {
        throw Exception('Rental not found');
      }
      
      // Check SMS from DaisySMS
      final smsContent = await _daisyClient!.getSms(rental.daisyRentalId);
      
      if (smsContent != null && rental.smsReceived == null) {
        // Update rental with SMS
        final updatedRental = await _supabaseService.updateRental(
          rentalId,
          {
            'sms_received': smsContent,
            'status': 'completed',
          },
        );
        return updatedRental;
      }
      
      return rental;
    } catch (e) {
      throw Exception('Failed to check SMS: $e');
    }
  }

  /// Cancel a rental (user-initiated)
  Future<bool> cancelRental(String rentalId) async {
    _ensureDaisyClient();
    
    final currentUser = _supabaseService.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }
    
    try {
      // Get rental from database
      final rental = await _supabaseService.getRentalById(rentalId);
      if (rental == null || rental.status != 'active') {
        return false;
      }
      
      // Cancel on DaisySMS
      final success = await _daisyClient!.cancelRental(rental.daisyRentalId);
      
      if (success) {
        // Update rental status to cancelled per DB constraint
        await _supabaseService.updateRental(
          rentalId,
          {'status': 'cancelled'},
        );
        return true;
      }
      
      return false;
    } catch (e) {
      throw Exception('Failed to cancel rental: $e');
    }
  }

  /// Get user's rentals
  Future<List<Rental>> getUserRentals() async {
    final currentUser = _supabaseService.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }
    
    return _supabaseService.getUserRentals();
  }

  /// Get pricing for a specific service and country
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

  /// Check if a service is available
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

  /// Get DaisySMS balance
  Future<double> getDaisyBalance() async {
    _ensureDaisyClient();
    
    try {
      return await _daisyClient!.getBalance();
    } catch (e) {
      throw Exception('Failed to get balance: $e');
    }
  }

  /// Health check
  Future<bool> healthCheck() async {
    _ensureDaisyClient();
    
    try {
      return await _daisyClient!.healthCheck();
    } catch (e) {
      return false;
    }
  }

  /// Start periodic expiry checking
  void startExpiryMonitoring() {
    _expiryTimer?.cancel();
    _expiryTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      _handleExpiredRentals();
    });
  }

  /// Stop expiry monitoring
  void stopExpiryMonitoring() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
  }

  /// Check and handle expired rentals (system-initiated expiration)
  Future<void> _handleExpiredRentals() async {
    _ensureDaisyClient();
    
    final currentUser = _supabaseService.currentUser;
    if (currentUser == null) return;
    
    try {
      print('BurnaService: Checking for expired rentals...');
      final rentals = await _supabaseService.getUserRentals();
      final now = DateTime.now().toUtc();

      // Strict: treat as expired exactly at Daisy TTL boundary (no grace here).
      final expiredRentals = rentals.where((rental) {
        final expiryUtc = rental.expiresAt.toUtc();
        return rental.status.toLowerCase() == 'active' && expiryUtc.isBefore(now);
      }).toList();

      if (expiredRentals.isEmpty) return;

      print('BurnaService: Found ${expiredRentals.length} expired rentals');

      for (final rental in expiredRentals) {
        try {
          // Try to see if SMS arrived late
          final smsContent = await _daisyClient!.getSms(rental.daisyRentalId);
          if (smsContent != null && smsContent.isNotEmpty) {
            await _supabaseService.updateRental(
              rental.id,
              {
                'sms_received': smsContent,
                'status': 'completed',
              },
            );
            print('BurnaService: Completed rental ${rental.id} via late SMS');
            continue;
          }

          // Daisy API semantics per docs:
          // - NO_ACTIVATION: wrong/missing activation -> treat as not existing on Daisy -> local must not remain 'active'
          // - STATUS_CANCEL/ACCESS_CANCEL: already cancelled on Daisy
          // Because getSms() now swallows 400/NO_ACTIVATION and returns null, we must normalize local state here:
          // 1) First, try to cancel on Daisy. If it returns ACCESS_CANCEL -> success.
          // 2) If cancel fails OR Daisy has no activation, we still flip local to 'cancelled' to converge UI.
          final cancelled = await _daisyClient!.cancelRental(rental.daisyRentalId);
          await _supabaseService.updateRental(
            rental.id,
            {'status': 'cancelled'},
          );
          if (cancelled) {
            print('BurnaService: Auto-cancelled expired rental ${rental.id}');
          } else {
            print('BurnaService: Normalized expired rental ${rental.id} to cancelled (Daisy absent/NO_ACTIVATION).');
          }
        } catch (e) {
          // Never throw; prevent infinite error loop that spams logs
          print('BurnaService: Error handling expired rental ${rental.id}: $e');
          // As a safety, if we consistently fail server calls and TTL is exceeded, mark local as cancelled to avoid UI showing ACTIVE in history.
          try {
            await _supabaseService.updateRental(
              rental.id,
              {'status': 'cancelled'},
            );
          } catch (_) {}
        }
      }
    } catch (e) {
      print('BurnaService: Error checking expired rentals: $e');
    }
  }

  /// Force check expired rentals (manual trigger)
  Future<void> checkExpiredRentals() async {
    await _handleExpiredRentals();
  }

  /// Get country/region name from Daisy code
  String _getCountryName(String countryCode) {
    final countries = const {
      '0': 'Any Country',
      '1': 'United States',
      '7': 'Russia',
      '44': 'United Kingdom',
      '49': 'Germany',
      '33': 'France',
      '39': 'Italy',
      '34': 'Spain',
      '31': 'Netherlands',
      '86': 'China',
      '91': 'India',
      '81': 'Japan',
      '82': 'South Korea',
      '61': 'Australia',
      '55': 'Brazil',
      '52': 'Mexico',
      '380': 'Ukraine',
      '48': 'Poland',
    };
    
    // TODO: Extend with Daisy-specific mapping (e.g., '187') from Daisy documentation.
    return countries[countryCode] ?? 'Region $countryCode';
  }

  /// Cleanup resources
  void dispose() {
    stopExpiryMonitoring();
  }
}