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
  /// Returns true if user completed payment; false if cancelled.
  Future<bool> topUpWalletCents(int amountCents) async {
    try {
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

      // If we reach here, user completed the sheet (not necessarily succeeded on Stripe side yet).
      // Confirm (no-op for PaymentSheet 11.x) and return success; webhook will credit wallet.
      return true;
    } on StripeException catch (e) {
      // Suppress visible error when user cancels the sheet.
      // FailureCode.canceled means user closed or canceled the payment sheet.
      final code = e.error.code;
      if (code == FailureCode.Canceled) {
        return false;
      }
      // For other Stripe errors, rethrow to let UI show a concise message.
      rethrow;
    } catch (_) {
      rethrow;
    }
  }
}