import 'package:supabase_flutter/supabase_flutter.dart';
import '../constants/app_constants.dart';
import '../models/user.dart' as app_user;
import '../models/rental.dart';

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
    final result = await client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: AppConstants.googleOAuthRedirectUrl,
    );
    return result;
  }

  Future<void> signOut() async {
    await client.auth.signOut();
  }

  // User profile management
  Future<app_user.User?> getCurrentUserProfile() async {
    if (!isAuthenticated) return null;

    final response = await client
        .from('users')
        .select()
        .eq('id', currentUser!.id)
        .maybeSingle();
    
    if (response == null) return null;
    
    return app_user.User.fromJson(response);
  }

  Future<app_user.User> createUserProfile(User authUser) async {
    final userProfile = {
      'id': authUser.id,
      'email': authUser.email!,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'total_spent': 0.0,
      'total_rentals': 0,
    };

    final response = await client
        .from('users')
        .insert(userProfile)
        .select()
        .single();

    return app_user.User.fromJson(response);
  }

  Future<app_user.User> updateUserProfile(app_user.User user) async {
    final response = await client
        .from('users')
        .update(user.toJson())
        .eq('id', user.id)
        .select()
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
}