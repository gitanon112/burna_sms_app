import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';
import '../models/user.dart' as app_user;

enum AuthStatus { loading, authenticated, unauthenticated }

class AuthProvider with ChangeNotifier {
  final ISupabaseService _supabaseService;
  
  AuthStatus _status = AuthStatus.loading;
  app_user.User? _userProfile;
  String? _errorMessage;
  
  AuthStatus get status => _status;
  app_user.User? get userProfile => _userProfile;
  bool get isAuthenticated => _status == AuthStatus.authenticated;
  bool get isLoading => _status == AuthStatus.loading;
  String? get errorMessage => _errorMessage;

  AuthProvider({ISupabaseService? supabaseService}) : _supabaseService = supabaseService ?? SupabaseService() {
    _initialize();
  }

  Future<void> _initialize() async {
    // Listen to auth state changes
    _supabaseService.authStateStream.listen(_handleAuthStateChange);
    
    // Check current auth status
    await _checkCurrentAuth();
  }

  void _handleAuthStateChange(AuthState authState) {
    switch (authState.event) {
      case AuthChangeEvent.initialSession:
        _handleInitialSession(authState.session);
        break;
      case AuthChangeEvent.signedIn:
        _handleSignedIn(authState.session);
        break;
      case AuthChangeEvent.signedOut:
        _handleSignedOut();
        break;
      case AuthChangeEvent.tokenRefreshed:
        // User session was refreshed
        break;
      case AuthChangeEvent.userUpdated:
        _handleUserUpdated(authState.session);
        break;
      case AuthChangeEvent.passwordRecovery:
        // Handle password recovery if needed
        break;
      // AuthChangeEvent.userDeleted is deprecated; treat same as signed out.
      // ignore: deprecated_member_use
      case AuthChangeEvent.userDeleted:
        _handleSignedOut();
        break;
      case AuthChangeEvent.mfaChallengeVerified:
        // Handle MFA if implemented
        break;
    }
  }

  Future<void> _checkCurrentAuth() async {
    try {
      _status = AuthStatus.loading;
      _errorMessage = null;
      notifyListeners();

      if (_supabaseService.isAuthenticated) {
        await _loadUserProfile();
        _status = AuthStatus.authenticated;
      } else {
        _status = AuthStatus.unauthenticated;
      }
    } catch (e) {
      _status = AuthStatus.unauthenticated;
      _errorMessage = 'Error checking authentication: $e';
    }
    
    notifyListeners();
  }

  void _handleInitialSession(Session? session) {
    if (session != null) {
      _handleSignedIn(session);
    } else {
      _handleSignedOut();
    }
  }

  Future<void> _handleSignedIn(Session? session) async {
    if (session?.user != null) {
      try {
        await _loadUserProfile();
        _status = AuthStatus.authenticated;
        _errorMessage = null;
      } catch (e) {
        _status = AuthStatus.unauthenticated;
        _errorMessage = 'Error loading user profile: $e';
      }
    } else {
      _status = AuthStatus.unauthenticated;
    }
    
    notifyListeners();
  }

  void _handleSignedOut() {
    _status = AuthStatus.unauthenticated;
    _userProfile = null;
    _errorMessage = null;
    notifyListeners();
  }

  void _handleUserUpdated(Session? session) {
    if (session?.user != null) {
      // Reload user profile when user data is updated
      _loadUserProfile();
    }
  }

  Future<void> _loadUserProfile() async {
    try {
      _userProfile = await _supabaseService.getCurrentUserProfile();
      
      // If user profile doesn't exist, create it
      if (_userProfile == null && _supabaseService.currentUser != null) {
        _userProfile = await _supabaseService.createUserProfile(_supabaseService.currentUser!);
      }
    } catch (e) {
      // If profile creation/loading fails, we still consider the user authenticated
      // but without profile data
      debugPrint('Error loading user profile: $e');
    }
  }

  // Authentication methods
  Future<bool> signInWithGoogle() async {
    try {
      // Do not leave the app in a global loading state; launch OAuth and immediately
      // keep the app in unauthenticated state until Supabase emits a signedIn event.
      _errorMessage = null;
      notifyListeners();

      final launched = await _supabaseService.signInWithGoogle();

      // Immediately ensure the wrapper shows the login/home instead of a spinner
      // while the external OAuth flow is in progress or cancelled.
      _status = AuthStatus.unauthenticated;
      notifyListeners();

      if (launched) {
        // When/if the user completes OAuth, onAuthStateChange(signedIn) will flip state.
        return true;
      }
      _errorMessage = 'Google sign-in failed to start';
      return false;
    } catch (e) {
      _status = AuthStatus.unauthenticated;
      _errorMessage = 'Sign-in error: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> signOut() async {
    try {
      await _supabaseService.signOut();
      // The auth state change listener will handle updating the state
    } catch (e) {
      _errorMessage = 'Sign-out error: $e';
      notifyListeners();
    }
  }

  // User profile methods
  Future<void> updateUserProfile(app_user.User updatedUser) async {
    try {
      _userProfile = await _supabaseService.updateUserProfile(updatedUser);
      notifyListeners();
    } catch (e) {
      _errorMessage = 'Error updating profile: $e';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> refreshUserProfile() async {
    if (_supabaseService.isAuthenticated) {
      await _loadUserProfile();
      notifyListeners();
    }
  }

  // Error handling
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  // Utility methods
  String? get userEmail => _supabaseService.currentUser?.email;
  String? get userId => _supabaseService.currentUser?.id;

  // Dispose method for cleanup
}