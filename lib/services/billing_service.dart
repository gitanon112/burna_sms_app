import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class BillingService {
  static final BillingService _instance = BillingService._internal();
  factory BillingService() => _instance;
  BillingService._internal();

  /// Open external Stripe Checkout via Supabase Edge Function (create_checkout_session).
  /// amountCents must be positive. Returns true if the checkout page was opened.
  Future<bool> openExternalCheckout({required int amountCents}) async {
    if (amountCents <= 0) {
      throw ArgumentError('amountCents must be > 0');
    }

    final res = await Supabase.instance.client.functions.invoke(
      'create_checkout_session',
      body: {'amount_cents': amountCents},
    );
    final data = res.data as Map<String, dynamic>?;

    final url = data?['url'] as String?;
    if (url == null || url.isEmpty) {
      throw Exception('No Checkout URL returned from create_checkout_session');
    }

    final uri = Uri.parse(url);

    // iOS compliance: open in Safari, not an in-app webview.
    final can = await canLaunchUrl(uri);
    if (!can) {
      throw Exception('Cannot open Checkout URL');
    }
    // Prefer external application
    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    return opened;
  }
}