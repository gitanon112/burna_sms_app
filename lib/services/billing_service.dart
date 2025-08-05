import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../constants/app_constants.dart';

class BillingService {
  static final BillingService _instance = BillingService._internal();
  factory BillingService() => _instance;
  BillingService._internal();

  Future<void> initializeStripe() async {
    Stripe.publishableKey = AppConstants.stripePublishableKey;
    await Stripe.instance.applySettings();
  }

  /// Calls Supabase Edge Function to create a PaymentIntent; returns client_secret.
  Future<String> createPaymentIntentClientSecret(int amountCents) async {
    final res = await Supabase.instance.client.functions.invoke(
      'create_payment_intent',
      body: {'amount_cents': amountCents},
    );
    final data = res.data as Map<String, dynamic>;
    final clientSecret = data['client_secret'] as String?;
    if (clientSecret == null) {
      throw Exception('No client_secret returned from create_payment_intent');
    }
    return clientSecret;
  }

  /// Full top-up flow: create PI, init sheet, present.
  Future<void> topUpWalletCents(int amountCents) async {
    final clientSecret = await createPaymentIntentClientSecret(amountCents);

    // flutter_stripe 11.x expects the client secret in SetupPaymentSheetParameters
    await Stripe.instance.initPaymentSheet(
      paymentSheetParameters: SetupPaymentSheetParameters(
        paymentIntentClientSecret: clientSecret,
        merchantDisplayName: AppConstants.appName,
        allowsDelayedPaymentMethods: false,
      ),
    );

    await Stripe.instance.presentPaymentSheet();
  }
}