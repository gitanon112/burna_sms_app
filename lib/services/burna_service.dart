import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/rental.dart';
import '../models/service_data.dart';
import 'daisy_sms_client.dart';
import 'supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../constants/app_constants.dart';

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
  static double get markupMultiplier => AppConstants.markupMultiplier;
  // Inject from secure config (e.g., --dart-define, remote config, or Supabase function)
  // No default key is provided to avoid accidental leakage; configure DAISY_API_KEY at runtime.
  static const String daisyApiKey = String.fromEnvironment('DAISY_API_KEY', defaultValue: '');
  
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
      
      debugPrint('BurnaService: Getting services from DaisySMS...');
      
      // Get services from DaisySMS
      final daisyServices = await _daisyClient!.getServices();
      debugPrint('BurnaService: Received ${daisyServices.length} services from DaisySMS');
      
      final burnaServices = <String, ServiceData>{};
      
      for (final entry in daisyServices.entries) {
        final serviceCode = entry.key;
        final countries = entry.value;
        final processedCountries = <String, CountryService>{};

        // Build countries -> CountryService and try to capture a readable service name
        String? inferredServiceName;

        for (final countryEntry in countries.entries) {
          final pricing = countryEntry.value;

          if (!pricing.available) continue;

          final originalPrice = pricing.price;
          final burnaPrice = (originalPrice * markupMultiplier).toStringAsFixed(2);

          // Use Daisy-provided service name if present on pricing.name
          if ((pricing.name ?? '').trim().isNotEmpty && inferredServiceName == null) {
            inferredServiceName = pricing.name!.trim();
          }

          // US-only offering: present country name as United States for all entries
          processedCountries['US'] = CountryService(
            originalPrice: originalPrice,
            burnaPrice: double.parse(burnaPrice),
            available: pricing.available,
            count: pricing.count,
            name: 'United States',
            ttlSeconds: pricing.ttlSeconds, // from Daisy client
          );
          // Only one country row needed for UI purposes
          break;
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
      
      debugPrint('BurnaService: Processed ${burnaServices.length} services with markup');
      final resp = ServicesResponse(services: burnaServices);
      _cachedServices = resp;
      _cachedAt = now;
      return resp;
    } catch (e) {
      debugPrint('BurnaService ERROR: $e');
      throw Exception('Failed to get services: $e');
    }
  }

  /// Purchase a phone number for SMS verification
  Future<Rental> purchaseNumber({
    required String serviceCode,
    String countryCode = 'US',
  }) async {
    _ensureDaisyClient();

    debugPrint('BurnaService: Starting purchase - service: $serviceCode, country: $countryCode');

    final currentUser = _supabaseService.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

  // Read current wallet for UX gating (server RPC will enforce again)
  final walletCents = await _supabaseService.getWalletBalanceCents();

    debugPrint('BurnaService: User authenticated - ${currentUser.email}');

    try {
  // Get service pricing
      debugPrint('BurnaService: Getting available services...');
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

      debugPrint('BurnaService: Found pricing - original: ${pricingRef.originalPrice}, burna: ${pricingRef.burnaPrice}');

      // Ensure wallet covers the burna price before placing a hold
      final burnaPriceCents = (pricingRef.burnaPrice * 100).round();
      if (walletCents < burnaPriceCents) {
        throw Exception('Insufficient wallet balance (need $burnaPriceCents cents). Please add funds.');
      }

      // 1) Create a wallet HOLD for success-only debit (server-authoritative)
  // Already computed above
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
      debugPrint('BurnaService: Renting number from DaisySMS...');
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
          debugPrint('BurnaService: Failed to refund hold after Daisy error: $e2');
        }
        rethrow;
      }
      debugPrint('BurnaService: Got number from DaisySMS - ${daisyRental.number} (id: ${daisyRental.id})');
      
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
        // Store human-friendly name if available; fallback to uppercased code
        'service_name': svc.name.isNotEmpty ? svc.name : serviceCode.toUpperCase(),
        'country_code': resolvedCountryCode,
        'country_name': resolvedCountryName,
        'phone_number': daisyRental.number,
        'original_price': pricingRef.originalPrice,
        'burna_price': pricingRef.burnaPrice,
        'status': 'active',
        'created_at': now.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
        'wallet_hold_id': walletHoldId,
      };
      
      debugPrint('BurnaService: Creating rental in Supabase...');
      final rental = await _supabaseService.createRental(rentalData);
      // Refresh wallet again in case subscription lagged
      try {
        await _supabaseService.hardRefreshWalletBalanceCents();
      } catch (_) {}
      
  // Do NOT update profile totals here. Totals should only reflect successful rentals (on SMS receipt).
      
      debugPrint('BurnaService: Purchase complete!');
      return rental;
    } catch (e) {
      debugPrint('BurnaService ERROR during purchase: $e');
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
          // Update profile totals on success-only path
          try {
            final profile = await _supabaseService.getCurrentUserProfile();
            if (profile != null) {
              await _supabaseService.updateUserProfile(
                profile.copyWith(
                  totalSpent: profile.totalSpent + updatedRental.burnaPrice,
                  totalRentals: profile.totalRentals + 1,
                  updatedAt: DateTime.now().toUtc(),
                ),
              );
            }
          } catch (e) {
            debugPrint('BurnaService: failed to update profile totals on SMS success: $e');
          }
        } catch (e) {
          // Non-fatal for UI: log and continue; balance can be reconciled later if needed.
          debugPrint('BurnaService: wallet commit/debit failed for rental $rentalId: $e');
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

      // Debug: log current auth role/sub just before refund (if helper RPC exists)
      try {
        final dbg = await Supabase.instance.client.rpc('test_authorization_header');
        // ignore: avoid_print
        debugPrint('Auth debug before refund: role=${dbg['role']}, sub=${dbg['sub']}');
      } catch (_) {
        // ignore: not fatal if helper is not present
      }

      // Refund first (so UI pill updates instantly), then mark cancelled
      try {
        String? holdId = rental.walletHoldId;
        // Fallback: if rental lacks hold id, resolve via RPC by rental_id
        if (holdId == null || holdId.isEmpty) {
          try {
            final res = await Supabase.instance.client.rpc('get_active_hold_for_rental', params: {
              'p_rental_id': rental.id,
            });
            String? parsed;
            if (res is String) {
              parsed = res;
            } else if (res is List && res.isNotEmpty) {
              final first = res.first;
              if (first is String) parsed = first;
              if (first is Map && first['get_active_hold_for_rental'] is String) {
                parsed = first['get_active_hold_for_rental'] as String;
              }
            } else if (res is Map) {
              // Try common keys
              final v = res['get_active_hold_for_rental'] ?? res['hold_id'] ?? res['id'];
              if (v is String) parsed = v;
            }
            holdId = parsed;
          } catch (_) {}
        }
        if (holdId != null && holdId.isNotEmpty) {
          Future<int> doRefund() => _supabaseService.walletRefundHold(holdId: holdId!, reason: 'User cancelled rental');
          int newBal;
          try {
            newBal = await doRefund();
          } catch (e) {
            final msg = e.toString();
            // One-shot retry on common auth/ownership race conditions
            if (msg.contains('unauthorized') || msg.contains('hold_not_found_for_user')) {
              await Future.delayed(const Duration(milliseconds: 650));
              newBal = await doRefund();
            } else {
              rethrow;
            }
          }
          try { onWalletBalanceChanged?.call(newBal); } catch (_) {}
          try { await _supabaseService.hardRefreshWalletBalanceCents(); } catch (_) {}
        }
      } catch (e) {
        debugPrint('BurnaService: wallet refund failed for rental $rentalId: $e');
      }

      await _supabaseService.updateRental(rentalId, {'status': 'cancelled'});
      if (cancelledOnDaisy) {
        debugPrint('BurnaService: Cancelled rental $rentalId on Daisy and refunded hold');
      } else {
        debugPrint('BurnaService: Normalized rental $rentalId to cancelled and refunded hold (Daisy cancel false/errored)');
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
  // Removed (unused): getPricing(serviceCode, countryCode)

  /// Check if a service is available
  // Removed (unused): isServiceAvailable(serviceCode, countryCode)

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
      debugPrint('BurnaService: Checking for expired rentals...');
      final rentals = await _supabaseService.getUserRentals();
      final now = DateTime.now().toUtc();

      // Strict: treat as expired exactly at Daisy TTL boundary (no grace here).
      final expiredRentals = rentals.where((rental) {
        final expiryUtc = rental.expiresAt.toUtc();
        return rental.status.toLowerCase() == 'active' && expiryUtc.isBefore(now);
      }).toList();

      if (expiredRentals.isEmpty) return;

      debugPrint('BurnaService: Found ${expiredRentals.length} expired rentals');

      for (final rental in expiredRentals) {
        bool refundedThisRental = false;
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
              debugPrint('BurnaService: commit/debit failed on late SMS for ${rental.id}: $e');
            }
            // Update profile totals on success-only path (late SMS)
            try {
              final profile = await _supabaseService.getCurrentUserProfile();
              if (profile != null) {
                await _supabaseService.updateUserProfile(
                  profile.copyWith(
                    totalSpent: profile.totalSpent + rental.burnaPrice,
                    totalRentals: profile.totalRentals + 1,
                    updatedAt: DateTime.now().toUtc(),
                  ),
                );
              }
            } catch (e) {
              debugPrint('BurnaService: failed to update profile totals on late SMS: $e');
            }
            debugPrint('BurnaService: Completed rental ${rental.id} via late SMS');
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
              refundedThisRental = true;
            }
          } catch (e) {
            debugPrint('BurnaService: refund failed on expiry for ${rental.id}: $e');
          }
          debugPrint('BurnaService: Normalized expired rental ${rental.id} to cancelled and refunded hold.');
        } catch (e) {
          // Never throw...
          debugPrint('BurnaService: Error handling expired rental ${rental.id}: $e');
          // Safety flip to cancelled
          try {
            await _supabaseService.updateRental(
              rental.id,
              {'status': 'cancelled'},
            );
            final holdId = rental.walletHoldId;
            if (!refundedThisRental && holdId != null && holdId.isNotEmpty) {
              try {
                await _supabaseService.walletRefundHold(holdId: holdId, reason: 'Expiry normalization');
              } catch (_) {/* ignore second-attempt errors */}
              try { await _supabaseService.hardRefreshWalletBalanceCents(); } catch (_) {}
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('BurnaService: Error checking expired rentals: $e');
    }
  }

  /// Force check expired rentals (manual trigger)
  Future<void> checkExpiredRentals() async {
    await _handleExpiredRentals();
  }

  // Removed (unused): _getCountryName

  /// Cleanup resources
  void dispose() {
    stopExpiryMonitoring();
  }

  /// Optional UI callback to push wallet balance instantly after RPCs
  void Function(int newBalanceCents)? onWalletBalanceChanged;
}