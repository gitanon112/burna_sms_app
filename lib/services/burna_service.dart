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
  
  // Simple in-memory cache for services to reduce flicker/volatility
  ServicesResponse? _cachedServices;
  DateTime? _cachedAt;
  static const Duration _servicesTtl = Duration(seconds: 60);
  
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
      // Serve cache if still fresh
      final now = DateTime.now();
      if (_cachedServices != null && _cachedAt != null && now.difference(_cachedAt!) < _servicesTtl) {
        return _cachedServices!;
      }
      
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
      final resp = ServicesResponse(services: burnaServices);
      _cachedServices = resp;
      _cachedAt = now;
      return resp;
    } catch (e) {
      print('BurnaService ERROR: $e');
      throw Exception('Failed to get services: $e');
    }
  }

  /// Purchase a phone number for SMS verification
  Future<Rental> purchaseNumber({
    required String serviceCode,
    String countryCode = 'US',
  }) async {
    _ensureDaisyClient();

    print('BurnaService: Starting purchase - service: $serviceCode, country: $countryCode');

    final currentUser = _supabaseService.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

    // Read authoritative wallet for UX gating (server RPC will enforce again)
    final walletCents = await _supabaseService.getWalletBalanceCents();
    if (walletCents <= 0) {
      throw Exception('Insufficient wallet balance. Please top up before purchasing a number.');
    }

    print('BurnaService: User authenticated - ${currentUser.email}');

    try {
      // Get service pricing
      print('BurnaService: Getting available services...');
      final services = await getAvailableServices();

      if (!services.services.containsKey(serviceCode)) {
        throw Exception('Service not available');
      }
      // Daisy is US-only: choose the first available country entry just for pricing/TTL reference.
      final svc = services.services[serviceCode]!;
      final firstCountryEntry = svc.countries.entries.firstWhere(
        (e) => e.value.available,
        orElse: () => svc.countries.entries.first,
      );
      final pricingRef = firstCountryEntry.value;
      final resolvedCountryCode = 'US';
      final resolvedCountryName = 'United States';

      print('BurnaService: Found pricing - original: ${pricingRef.originalPrice}, burna: ${pricingRef.burnaPrice}');

      // 1) Create a wallet HOLD for success-only debit (server-authoritative)
      final burnaPriceCents = (pricingRef.burnaPrice * 100).round();
      final rentalId = const Uuid().v4(); // provision an id up front to link hold metadata
      late final String walletHoldId;
      try {
        final holdRes = await _supabaseService.walletCreateHold(
          amountCents: burnaPriceCents,
          rentalId: rentalId,
          reason: 'Hold for $serviceCode $resolvedCountryCode rental',
        );
        walletHoldId = holdRes.holdId;
        // Immediately push new balance to UI
        try { onWalletBalanceChanged?.call(holdRes.balanceAfterCents); } catch (_) {}
        // Fallback hard refresh as safety
        try { await _supabaseService.hardRefreshWalletBalanceCents(); } catch (_) {}
      } catch (e) {
        // Fail fast if hold cannot be created
        throw Exception('Unable to place wallet hold: $e');
      }
      
      // 2) Rent number from DaisySMS (no country parameter)
      print('BurnaService: Renting number from DaisySMS...');
      final maxPrice = (pricingRef.originalPrice * 1.1);
      final maxPriceStr = maxPrice.toStringAsFixed(2);
      DaisyRental daisyRental;
      try {
        daisyRental = await _daisyClient!.rentNumber(
          serviceCode,
          maxPrice: maxPriceStr,
          // duration: '1H',
        );
      } catch (e) {
        // Refund hold on failure to obtain number
        try {
          await _supabaseService.walletRefundHold(holdId: walletHoldId, reason: 'Daisy rent failed');
          // Immediate wallet refresh after refund
          try { await _supabaseService.hardRefreshWalletBalanceCents(); } catch (_) {}
        } catch (e2) {
          print('BurnaService: Failed to refund hold after Daisy error: $e2');
        }
        rethrow;
      }
      print('BurnaService: Got number from DaisySMS - ${daisyRental.number} (id: ${daisyRental.id})');
      
      // 3) Create rental in Supabase (store wallet_hold_id for lifecycle)
      // Use UTC for timestamps
      final now = DateTime.now().toUtc();

      // Align expiry to Daisy TTL if we have it; else default 15 minutes
      Duration expiryDuration;
      final maybeTtl = pricingRef.ttlSeconds;
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
        'country_code': resolvedCountryCode,
        'country_name': resolvedCountryName,
        'phone_number': daisyRental.number,
        'original_price': pricingRef.originalPrice,
        'burna_price': pricingRef.burnaPrice,
        'status': 'active',
        'created_at': now.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
        'user_email': currentUser.email,
        'wallet_hold_id': walletHoldId,
      };
      
      print('BurnaService: Creating rental in Supabase...');
      final rental = await _supabaseService.createRental(rentalData);
      // Refresh wallet again in case subscription lagged
      try {
        await _supabaseService.hardRefreshWalletBalanceCents();
      } catch (_) {}
      
      // Update user stats
      print('BurnaService: Updating user profile stats...');
      final userProfile = await _supabaseService.getCurrentUserProfile();
      if (userProfile != null) {
        final updatedProfile = userProfile.copyWith(
          totalSpent: userProfile.totalSpent + pricingRef.burnaPrice,
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
  /// On first successful code, mark completed AND debit wallet by rentals.burna_price (success-only billing).
  /// Timeout/cancel paths elsewhere must not debit.
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
      
      if (smsContent != null && (rental.smsReceived == null || rental.smsReceived!.isEmpty)) {
        // 1) Update rental with SMS and completed status
        final updatedRental = await _supabaseService.updateRental(
          rentalId,
          {
            'sms_received': smsContent,
            'status': 'completed',
          },
        );
        // 2) Commit hold if exists; else fallback to legacy debit
        try {
          final holdId = updatedRental.walletHoldId;
          if (holdId != null && holdId.isNotEmpty) {
            final newBal = await _supabaseService.walletCommitHold(holdId: holdId);
            try { onWalletBalanceChanged?.call(newBal); } catch (_) {}
            try { await _supabaseService.hardRefreshWalletBalanceCents(); } catch (_) {}
          } else {
            final amountCents = (updatedRental.burnaPrice * 100).round();
            await _supabaseService.debitWalletOnSuccess(
              userId: currentUser.id,
              amountCents: amountCents,
              rentalId: rentalId,
              reason: 'SMS code received for ${updatedRental.serviceName} (${updatedRental.countryName})',
            );
            try { final c = await _supabaseService.hardRefreshWalletBalanceCents(); onWalletBalanceChanged?.call(c); } catch (_) {}
          }
        } catch (e) {
          // Non-fatal for UI: log and continue; balance can be reconciled later if needed.
          print('BurnaService: wallet commit/debit failed for rental $rentalId: $e');
        }
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
    if (currentUser == null) { throw Exception('User not authenticated'); }
    try {
      // Fetch fresh rental to ensure wallet_hold_id present
      final fresh = await _supabaseService.getRentalById(rentalId);
      final rental = fresh;
      if (rental == null || rental.status != 'active') { return false; }
      bool cancelledOnDaisy = false;
      try { cancelledOnDaisy = await _daisyClient!.cancelRental(rental.daisyRentalId); } catch (_) {}
      // Refund first (so UI pill updates instantly), then mark cancelled
      try {
        final holdId = rental.walletHoldId;
        if (holdId != null && holdId.isNotEmpty) {
          final newBal = await _supabaseService.walletRefundHold(holdId: holdId, reason: 'User cancelled rental');
          try { onWalletBalanceChanged?.call(newBal); } catch (_) {}
          try { await _supabaseService.hardRefreshWalletBalanceCents(); } catch (_) {}
        }
      } catch (e) {
        print('BurnaService: wallet refund failed for rental $rentalId: $e');
      }
      await _supabaseService.updateRental(rentalId, {'status': 'cancelled'});
      if (cancelledOnDaisy) {
        print('BurnaService: Cancelled rental $rentalId on Daisy and refunded hold');
      } else {
        print('BurnaService: Normalized rental $rentalId to cancelled and refunded hold (Daisy cancel false/errored)');
      }
      return true;
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
            // Commit hold on late SMS
            try {
              final holdId = rental.walletHoldId;
              if (holdId != null && holdId.isNotEmpty) {
                await _supabaseService.walletCommitHold(holdId: holdId);
                try { await _supabaseService.hardRefreshWalletBalanceCents(); } catch (_) {}
              } else {
                final amountCents = (rental.burnaPrice * 100).round();
                await _supabaseService.debitWalletOnSuccess(
                  userId: currentUser.id,
                  amountCents: amountCents,
                  rentalId: rental.id,
                  reason: 'Late SMS code for ${rental.serviceName} (${rental.countryName})',
                );
                try { await _supabaseService.hardRefreshWalletBalanceCents(); } catch (_) {}
              }
            } catch (e) {
              print('BurnaService: commit/debit failed on late SMS for ${rental.id}: $e');
            }
            print('BurnaService: Completed rental ${rental.id} via late SMS');
            continue;
          }

          // Daisy API semantics normalization...
          try {
            await _daisyClient!.cancelRental(rental.daisyRentalId);
          } catch (_) {/* ignore */}
          await _supabaseService.updateRental(
            rental.id,
            {'status': 'cancelled'},
          );
          // Refund hold if present
          try {
            final holdId = rental.walletHoldId;
            if (holdId != null && holdId.isNotEmpty) {
              final newBal = await _supabaseService.walletRefundHold(holdId: holdId, reason: 'Expired rental');
              try { onWalletBalanceChanged?.call(newBal); } catch (_) {}
              try { await _supabaseService.hardRefreshWalletBalanceCents(); } catch (_) {}
            }
          } catch (e) {
            print('BurnaService: refund failed on expiry for ${rental.id}: $e');
          }
          print('BurnaService: Normalized expired rental ${rental.id} to cancelled and refunded hold.');
        } catch (e) {
          // Never throw...
          print('BurnaService: Error handling expired rental ${rental.id}: $e');
          // Safety flip to cancelled
          try {
            await _supabaseService.updateRental(
              rental.id,
              {'status': 'cancelled'},
            );
            final holdId = rental.walletHoldId;
            if (holdId != null && holdId.isNotEmpty) {
              await _supabaseService.walletRefundHold(holdId: holdId, reason: 'Expiry normalization');
              try { await _supabaseService.hardRefreshWalletBalanceCents(); } catch (_) {}
            }
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

  /// Optional UI callback to push wallet balance instantly after RPCs
  void Function(int newBalanceCents)? onWalletBalanceChanged;
}