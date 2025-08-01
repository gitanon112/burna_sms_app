class AppConstants {
  // App Configuration
  static const String appName = 'Burna SMS';
  static const String appVersion = '1.0.0';
  
  // Supabase Configuration (UPDATE THESE WITH YOUR ACTUAL VALUES)
  static const String supabaseUrl = 'https://gbnfwvqlrztzkbbntyqa.supabase.co';
  static const String supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdibmZ3dnFscnp0emtiYm50eXFhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTM5MjQ5MzAsImV4cCI6MjA2OTUwMDkzMH0.yHz1zlwKg9jlARe_rP2U53Nvpj9KRGQp2z0F4kD-sMU';
  
  // Python Backend API Configuration (existing burna-sms backend)
  static const String daisyProxyBaseUrl = 'http://localhost:8000';
  
  // App Settings
  static const double markupMultiplier = 2.0;
  static const int smsCheckIntervalSeconds = 5;
  static const int rentalExpiryHours = 1;
  
  // UI Constants
  static const double defaultPadding = 16.0;
  static const double defaultRadius = 12.0;
  
  // OAuth Redirect URLs (must match iOS Info.plist CFBundleURLSchemes)
  static const String googleOAuthRedirectUrl = 'com.burnasms.app://auth-callback';
}