# Burna SMS – Detailed System Overview
Created: 2025-08-05T16:59:52Z
Last Updated: 2025-08-05T16:59:52Z

Summary
- Purpose: Document how the Flutter client, Supabase schema, and Edge Functions integrate for Burna SMS.
- Scope: Data models, services, auth + wallet + rentals flows, Stripe top-ups, and real-time behavior.
- Sources: Code in burna_sms_app/lib, Supabase tables and Edge Functions via MCP.

Table of Contents
1. Client Architecture
2. Data Models
3. Supabase Schema
4. Edge Functions
5. End-to-End Flows
6. Real-time and Polling
7. Security Notes and RLS
8. Known Gaps and Recommendations

1) Client Architecture
- Entry: lib/main.dart initializes Supabase and Material3 theme, provides AuthProvider and routes via AuthWrapper.
- State: Provider package with AuthProvider orchestrating sign-in and profile loading.
- Services:
  - SupabaseService: Auth, Profiles, Rentals CRUD, wallet reads, and realtime subscriptions.
  - BurnaService: Business orchestration (DaisySMS + Supabase), purchasing numbers, checking SMS, expiry normalization.
  - DaisySMSClient: Direct HTTP client for DaisySMS handler_api.
  - BillingService: Starts external Stripe Checkout via Edge Function and opens Safari.
- Screens:
  - AuthWrapper switches between Loading, Login, Home based on auth.
  - HomeScreen: 3 tabs (Purchase, My Numbers, History). Wallet pill with live/refresh. US-only curated services.

2) Data Models (Flutter)
- models/user.dart
  - id, email, created_at, updated_at, total_spent, total_rentals, stripe_customer_id, wallet_balance_cents
  - walletBalanceDollars convenience getter
- models/rental.dart
  - id, user_id, daisy_rental_id, service_code, service_name, country_code/name, phone_number (alias number), prices, status, sms_received, created_at, expires_at, stripe_payment_intent_id, user_email
  - helpers: isActive, isCompleted, isCancelled, hasReceivedSms, isExpired (UTC-based)
- models/service_data.dart
  - CountryService: original_price, burna_price, available, count, name, ttl_seconds?
  - ServiceData: service_code, name, countries map; helpers: availableCountries, totalAvailableCount
  - ServicesResponse: services map; helper: availableServices

3) Supabase Schema (public) – via MCP list_tables
- profiles (rls_enabled: false)
  - Columns: id (uuid PK, references auth.users.id), email (unique), created_at (timestamptz default now()), updated_at (timestamptz default now()), total_spent (numeric default 0), total_rentals (int default 0), stripe_customer_id (text), wallet_balance_cents (int not null default 0)
  - Relationships: users(auth), wallet_ledger, stripe_payments, daisysms_orders, rentals
- rentals (rls_enabled: true)
  - Columns: id (uuid default gen_random_uuid()), user_id (uuid not null), daisy_rental_id (text), service_code/name (text), country_code/name (text), phone_number (text), original_price/burna_price (numeric), status (text default 'active' with check: ['active','completed','cancelled']), sms_received (text), created_at (timestamptz default now()), expires_at (timestamptz), stripe_payment_intent_id (text), user_email (text), daisysms_account_id (uuid), daisysms_order_id (uuid)
  - FKs: user_id -> profiles.id, daisysms_account_id -> daisysms_accounts.id, daisysms_order_id -> daisysms_orders.id
- wallet_ledger (rls_enabled: true)
  - Columns: id (uuid), user_id (uuid not null), type (text check ['CREDIT','DEBIT','RESERVE','REFUND','ADJUST']), status (text default 'COMMITTED' check ['PENDING','RESERVED','COMMITTED','VOID','FAILED']), amount_cents (int > 0), currency (text default 'USD'), balance_after_cents (int), metadata (jsonb), created_at (timestamptz now()), created_by (text default 'system')
  - FK: user_id -> profiles.id
- stripe_payments (rls_enabled: true)
  - Columns: id (uuid), user_id (uuid), payment_intent_id (text unique), status (text), amount_cents (int), currency (text default 'USD'), raw_event (jsonb), created_at/updated_at (timestamptz now())
  - FK: user_id -> profiles.id
- daisysms_accounts (rls_enabled: false)
  - Columns: id (uuid), label (text), api_key (text), active (bool default true), priority (int default 100), max_parallel (int default 20), low_balance_threshold_cents (int default 1000), current_balance_cents (int default 0), last_checked_at (timestamptz)
  - FKs: referenced by rentals and daisysms_orders
- daisysms_orders (rls_enabled: false)
  - Columns: id (uuid), daisysms_account_id (uuid), user_id (uuid), rental_id (uuid), service_code (text), country_code (text), external_activation_id (text), price_cents (int), status (enum-ish constraint), last_status (text), created_at/updated_at (timestamptz now())
  - FKs: rental_id -> rentals.id, daisysms_account_id -> daisysms_accounts.id, user_id -> profiles.id
- ops_alerts (rls_enabled: false)
  - Columns: id (uuid), type (text constrained), target_id (uuid), message (text), severity (text default 'info'), created_at, acknowledged_by (text), acknowledged_at

Notes:
- RLS ON: rentals, wallet_ledger, stripe_payments
- RLS OFF: profiles, daisysms_accounts, daisysms_orders, ops_alerts
- No migrations returned by list_migrations, implying schema is managed outside migration history or the MCP endpoint lacks history.

4) Edge Functions – via MCP list_edge_functions
- create_payment_intent (verify_jwt: true)
  - Uses SUPABASE_SERVICE_ROLE_KEY to read/update profiles (stripe_customer_id), creates a Stripe PaymentIntent, returns client_secret
  - Mode-aware secrets: STRIPE_MODE (sandbox/live), STRIPE_SECRET_KEY_TEST/LIVE
  - Metadata includes user_id
- stripe_webhook (verify_jwt: false)
  - Signature verification implemented manually (HMAC SHA-256)
  - Handles checkout.session.completed, payment_intent.succeeded
  - Upserts stripe_payments, then credits wallet via RPC wallet_credit (fallback to direct profile + wallet_ledger writes)
- create_checkout_session (verify_jwt: true)
  - Auth via Bearer JWT, ensures Stripe customer on profile, creates Checkout session with client_reference_id = user.id
  - Returns { url } to open in Safari
  - Uses CHECKOUT_SUCCESS_URL/CHECKOUT_CANCEL_URL

5) End-to-End Flows
A) Authentication
- Client: ['SupabaseService.initialize()'](burna_sms_app/lib/services/supabase_service.dart:15) then ['signInWithGoogle()'](burna_sms_app/lib/services/supabase_service.dart:30) with redirect deep-link com.burnasms.app://auth-callback.
- AuthProvider listens to ['onAuthStateChange'](burna_sms_app/lib/services/auth_provider.dart:27) and loads/creates profile record for the user.

B) Wallet Top-up (Stripe)
- UI: HomeScreen "Add funds" prompts for amount.
- Client: ['BillingService.openExternalCheckout'](burna_sms_app/lib/services/billing_service.dart:11) calls Edge Function create_checkout_session with amount_cents and user JWT; receives a URL and opens in Safari.
- Stripe: User pays -> Webhook stripe_webhook receives event, validates signature, upserts stripe_payments, then credits wallet via wallet_credit RPC (fallback to direct profile+ledger update).
- Client: On resume (and realtime subscription), HomeScreen refreshes wallet via ['getWalletBalanceCents'](burna_sms_app/lib/services/supabase_service.dart:256) and updates pill.

C) Purchasing a Number (DaisySMS + Supabase)
- UI: From Purchase Tab, user taps a curated service (US-only).
- Client: ['BurnaService.purchaseNumber'](burna_sms_app/lib/services/burna_service.dart:106)
  - Checks user auth + wallet direct read (authoritative DB query).
  - Loads Daisy services via ['DaisySMSClient.getServices()'](burna_sms_app/lib/services/daisy_sms_client.dart:53) and builds a ServiceData with 2x markup.
  - Rents number via ['getNumber'](burna_sms_app/lib/services/daisy_sms_client.dart:97) (US-only; no country param).
  - Creates rentals row in Supabase with status 'active' and expires_at derived from Daisy TTL or default 15 minutes.
  - Updates profile totals (total_spent += burna_price, total_rentals += 1).
- UI updates active rentals via ['SupabaseService.getUserRentals'](burna_sms_app/lib/services/supabase_service.dart:118).

D) Receiving SMS / Completing Rental
- Manual check: ['BurnaService.checkSms'](burna_sms_app/lib/services/burna_service.dart:219) calls Daisy getStatus; on first code, updates rentals.sms_received and status=completed, then debits wallet success-only via ['SupabaseService.debitWalletOnSuccess'](burna_sms_app/lib/services/supabase_service.dart:211) (RPC preferred, fallback local update+ledger).
- Expiry watcher: ['BurnaService.startExpiryMonitoring'](burna_sms_app/lib/services/burna_service.dart:375) scans every minute; for expired 'active' rentals, it attempts late SMS; if none, cancels locally (and attempts Daisy cancel).

6) Real-time and Polling
- Wallet:
  - Client has two approaches: ['SupabaseService.subscribeToWalletChanges'](burna_sms_app/lib/services/supabase_service.dart:276) with Postgres changes on profiles table; and HomeScreen’s custom channel subscription (should be unified).
  - Also refreshes wallet on app resume and via direct DB read.
- Rentals:
  - SupabaseService offers streams ['watchUserRentals'](burna_sms_app/lib/services/supabase_service.dart:182) and ['watchRental'](burna_sms_app/lib/services/supabase_service.dart:194).
  - HomeScreen periodically refreshes active rentals list; BurnaService monitors for expiry.

7) Security Notes and RLS
- profiles.rls_enabled = false: Profiles table is open to the anon client; this is acceptable only if all updates are strictly scoped by server-side Edge Functions or if client updates are limited and safe. Consider enabling RLS with policies (user can select/update only their row).
- rentals.rls_enabled = true: Good. Ensure policies allow users to only read and mutate their rows. Current client code assumes user_id scoping.
- wallet_ledger.rls_enabled = true: Good; credits from webhook use service role. Client never directly reads ledger here (only profile balance).
- stripe_payments.rls_enabled = true: Good; service-role writes from webhook handled by Edge Function.
- Edge Functions use service-role key; inputs validated; Stripe signature verified.

8) Known Gaps and Recommendations
- Enable RLS for profiles with policies: user_id = auth.uid() for select/update; prevent client updating wallet_balance_cents (server-owned).
- Implement RPCs:
  - wallet_credit and wallet_debit_success on DB to ensure atomicity and audit.
  - Remove client fallback path over time.
- Unify realtime channel naming and subscription through SupabaseService to avoid duplicates.
- Replace invalid Flutter icons (e.g., Icons.discord) with valid Material icons.
- Harden BillingService to check function response types and surface better errors.
- Use UTC consistently for all times; unify linger window logic to UTC.