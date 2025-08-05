import 'package:supabase_flutter/supabase_flutter.dart';
import '../constants/app_constants.dart';
import '../models/user.dart' as app_user;
import '../models/rental.dart';
import 'package:flutter/foundation.dart';

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  SupabaseClient get client => Supabase.instance.client;
  
  // Initialize Supabase
  static Future<void> initialize() async {
    await Supabase.initialize(
      url: AppConstants.supabaseUrl,
      anonKey: AppConstants.supabaseAnonKey,
    );
  }

  // Auth helpers
  User? get currentUser => client.auth.currentUser;
  bool get isAuthenticated => currentUser != null;
  
  // Auth state stream
  Stream<AuthState> get authStateStream => client.auth.onAuthStateChange;

  // Authentication methods
  Future<bool> signInWithGoogle() async {
    try {
      await client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: AppConstants.googleOAuthRedirectUrl,
        authScreenLaunchMode: LaunchMode.externalApplication,
        queryParams: {
          // Force Google account chooser even if Safari has an active session
          'prompt': 'select_account',
        },
      );
      // Auth flow completes via onAuthStateChange; if no exception, consider initiated.
      return true;
    } catch (e) {
      print('Google OAuth error: $e');
      return false;
    }
  }

  Future<void> signOut() async {
    await client.auth.signOut();
  }

  // User profile management
  Future<app_user.User?> getCurrentUserProfile() async {
    if (!isAuthenticated) return null;

    debugPrint('SupabaseService.getCurrentUserProfile: querying profiles for user_id=${currentUser!.id}');
    final response = await client
        .from('profiles')
        .select('id,email,created_at,updated_at,total_spent,total_rentals,stripe_customer_id,wallet_balance_cents')
        .eq('id', currentUser!.id)
        .maybeSingle();
    
    if (response == null) {
      debugPrint('SupabaseService.getCurrentUserProfile: no row found for user_id=${currentUser!.id}');
      return null;
    }
    
    try {
      final u = app_user.User.fromJson(response);
      debugPrint('SupabaseService.getCurrentUserProfile: wallet_balance_cents=${u.walletBalanceCents} for user_id=${u.id}');
      return u;
    } catch (e) {
      debugPrint('SupabaseService.getCurrentUserProfile: mapping error: $e');
      rethrow;
    }
  }

  Future<app_user.User> createUserProfile(User authUser) async {
    final userProfile = {
      'id': authUser.id,
      'email': authUser.email!,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'total_spent': 0.0,
      'total_rentals': 0,
      'wallet_balance_cents': 0,
    };

    final response = await client
        .from('profiles')
        .insert(userProfile)
        .select('id,email,created_at,updated_at,total_spent,total_rentals,stripe_customer_id,wallet_balance_cents')
        .single();

    return app_user.User.fromJson(response);
  }

  Future<app_user.User> updateUserProfile(app_user.User user) async {
    // Never push wallet_balance_cents from client; server/webhook controls it.
    final payload = {
      'email': user.email,
      'updated_at': user.updatedAt.toIso8601String(),
      'total_spent': user.totalSpent,
      'total_rentals': user.totalRentals,
      'stripe_customer_id': user.stripeCustomerId,
    };
    final response = await client
        .from('profiles')
        .update(payload)
        .eq('id', user.id)
        .select('id,email,created_at,updated_at,total_spent,total_rentals,stripe_customer_id,wallet_balance_cents')
        .single();
    return app_user.User.fromJson(response);
  }

  // Rental management
  Future<List<Rental>> getUserRentals() async {
    if (!isAuthenticated) return [];

    final response = await client
        .from('rentals')
        .select()
        .eq('user_id', currentUser!.id)
        .order('created_at', ascending: false);

    return response.map<Rental>((json) => Rental.fromJson(json)).toList();
  }

  Future<Rental?> getRentalById(String rentalId) async {
    if (!isAuthenticated) return null;

    final response = await client
        .from('rentals')
        .select()
        .eq('id', rentalId)
        .eq('user_id', currentUser!.id)
        .maybeSingle();

    if (response == null) return null;
    
    return Rental.fromJson(response);
  }

  Future<Rental> createRental(Map<String, dynamic> rentalData) async {
    if (!isAuthenticated) throw Exception('User not authenticated');

    final response = await client
        .from('rentals')
        .insert(rentalData)
        .select()
        .single();

    return Rental.fromJson(response);
  }

  Future<Rental> updateRental(String rentalId, Map<String, dynamic> updates) async {
    if (!isAuthenticated) throw Exception('User not authenticated');

    final response = await client
        .from('rentals')
        .update(updates)
        .eq('id', rentalId)
        .eq('user_id', currentUser!.id)
        .select()
        .single();

    return Rental.fromJson(response);
  }

  Future<void> deleteRental(String rentalId) async {
    if (!isAuthenticated) throw Exception('User not authenticated');

    await client
        .from('rentals')
        .delete()
        .eq('id', rentalId)
        .eq('user_id', currentUser!.id);
  }

  // Real-time subscriptions
  Stream<List<Rental>> watchUserRentals() {
    if (!isAuthenticated) return Stream.value([]);

    return client
        .from('rentals')
        .stream(primaryKey: ['id'])
        .map((data) => data
            .where((json) => json['user_id'] == currentUser!.id)
            .map<Rental>((json) => Rental.fromJson(json))
            .toList());
  }

  Stream<Rental?> watchRental(String rentalId) {
    if (!isAuthenticated) return Stream.value(null);

    return client
        .from('rentals')
        .stream(primaryKey: ['id'])
        .map((data) {
          final rentals = data.where(
            (json) => json['id'] == rentalId && json['user_id'] == currentUser!.id,
          );
          return rentals.isEmpty ? null : Rental.fromJson(rentals.first);
        });
  }

  // Wallet helpers
  Future<int> getWalletBalanceCents() async {
    try {
      if (!isAuthenticated) return 0;
      // Always read directly from DB to avoid any mapping/stale issues
      final raw = await client
          .from('profiles')
          .select('wallet_balance_cents')
          .eq('id', currentUser!.id)
          .maybeSingle();
      final cents = (raw?['wallet_balance_cents'] as num?)?.toInt() ?? 0;
      debugPrint('SupabaseService.getWalletBalanceCents: direct cents=$cents for user_id=${currentUser!.id}');
      return cents;
    } catch (e) {
      debugPrint('getWalletBalanceCents error: $e');
      return 0;
    }
  }
  
  // Stream of wallet changes for current user (server-pushed)
  RealtimeChannel? _walletChannel;
  void subscribeToWalletChanges(void Function(int cents) onChange) {
    if (!isAuthenticated) return;
    _walletChannel?.unsubscribe();
    _walletChannel = client
        .channel('public:profiles:wallet:${currentUser!.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'profiles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: currentUser!.id,
          ),
          callback: (payload) {
            final v = (payload.newRecord['wallet_balance_cents'] as num?)?.toInt();
            if (v != null) onChange(v);
          },
        )
        .subscribe();
  }
  
  void unsubscribeWalletChanges() {
    try {
      _walletChannel?.unsubscribe();
    } catch (_) {}
    _walletChannel = null;
  }

  // Database trigger for rental updates
  void subscribeToRentalChanges(Function(Rental) onRentalUpdated) {
    if (!isAuthenticated) return;

    client
        .channel('public:rentals')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'rentals',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: currentUser!.id,
          ),
          callback: (payload) {
            final rental = Rental.fromJson(payload.newRecord);
            onRentalUpdated(rental);
          },
        )
        .subscribe();
  }
  
  /// Hard wallet refresh that bypasses any in-memory state and forces a non-cached read.
  Future<int> hardRefreshWalletBalanceCents() async {
    if (!isAuthenticated) return 0;
    final raw = await client
        .from('profiles')
        .select('wallet_balance_cents')
        .eq('id', currentUser!.id)
        .maybeSingle();
    final cents = (raw?['wallet_balance_cents'] as num?)?.toInt() ?? 0;
    debugPrint('SupabaseService.hardRefreshWalletBalanceCents: $cents');
    return cents;
  }
  
  String? debugCurrentUserId() {
    final id = currentUser?.id;
    debugPrint('SupabaseService.debugCurrentUserId: $id');
    return id;
  }
}