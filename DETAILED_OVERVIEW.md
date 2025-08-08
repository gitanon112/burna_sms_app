# Burna SMS – Detailed System Overview
Created: 2025-08-05T16:59:52Z
Last Updated: 2025-08-08T00:00:00Z

Summary
- Purpose: Document how the Flutter client, Supabase schema, and Edge Functions integrate for Burna SMS.
- Scope: Data models, services, auth + wallet + rentals flows, Stripe top-ups, iOS redirect, and real-time behavior.
- Sources: Code in burna_sms_app/lib, burnasms-web redirect pages, Supabase tables and Edge Functions via MCP.

Recent Changes
- success.html simplified to immediately deep-link via `com.burnasms.app://checkout/success?cs=...` with minimal fallback UI (auto-open prompt appears sooner on iOS).
- stripe_webhook hardened: API version aligned, missing-signature guard, wallet credit only when `user_id` and positive amount are present, and anomalies logged to `ops_alerts`.
- create_checkout_session already using JWT-derived `user_id`, idempotency key, and aligned API version.

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
- Entry: `lib/main.dart` initializes Supabase and Material3 theme, provides `AuthProvider` and routes via `AuthWrapper`.
- State: `provider` with `AuthProvider` orchestrating sign-in and profile loading via `onAuthStateChange`.
- Services:
  - `SupabaseService`: Auth, Profiles, Rentals CRUD, wallet reads, wallet RPCs (holds/commit/refund/debit), realtime subscriptions (profiles and rentals), Stripe payments history.
  - `BurnaService`: Business orchestration (DaisySMS + Supabase), purchasing numbers with wallet holds, SMS checks, expiry normalization with late-SMS handling, UI wallet push callback.
  - `DaisySMSClient`: Direct HTTP client for DaisySMS handler_api (getBalance, getPricesVerification, getNumber, getStatus, setStatus(8)=cancel).
  - `BillingService`: Calls Edge Function `create_checkout_session` and opens Stripe Checkout in Safari as an external application.
- Screens:
  - `AuthWrapper` switches between Loading, Login, Home based on auth.
  - `HomeScreen`: 3 tabs (Purchase, My Numbers, History). Wallet pill with realtime + refresh. Popular services list (US-only). Stripe Add Funds sheet opens Checkout.
  - Realtime: rentals change channel and wallet balance channel subscribed once; app also refreshes on resume.

2) Data Models (Flutter)
- `models/user.dart`
  - id, email, created_at, updated_at, total_spent, total_rentals, stripe_customer_id, wallet_balance_cents
  - walletBalanceDollars convenience getter
- `models/rental.dart`
  - id, user_id, daisy_rental_id, service_code/name, country_code/name, phone_number (alias number), original_price/burna_price, status, sms_received, created_at, expires_at, stripe_payment_intent_id, user_email, wallet_hold_id
  - helpers: isActive, isCompleted, isCancelled, hasReceivedSms, isExpired (UTC-based)
- `models/service_data.dart`
  - CountryService: original_price, burna_price, available, count, name, ttl_seconds
  - ServiceData: service_code, name, countries map; helpers: availableCountries, totalAvailableCount
  - ServicesResponse: services map; helper: availableServices

3) Supabase Schema (public) – from MCP list_tables (current)
- profiles (rls_enabled: true)
  - Columns: id (uuid PK → auth.users.id), email (unique), created_at (timestamptz now()), updated_at (timestamptz now()), total_spent (numeric default 0), total_rentals (int default 0), stripe_customer_id (text), wallet_balance_cents (int not null default 0)
  - Relationships: users(auth), wallet_ledger, stripe_payments, daisysms_orders, rentals
- rentals (rls_enabled: true)
  - Columns: id (uuid default gen_random_uuid()), user_id (uuid not null), daisy_rental_id (text), service_code/name (text), country_code/name (text), phone_number (text), original_price/burna_price (numeric), status (check ['active','completed','cancelled'] default 'active'), sms_received (text), created_at (timestamptz now()), expires_at (timestamptz), stripe_payment_intent_id (text), user_email (text), daisysms_account_id (uuid), daisysms_order_id (uuid), wallet_hold_id (uuid, link to hold in ledger)
  - FKs: user_id → profiles.id, daisysms_account_id → daisysms_accounts.id, daisysms_order_id → daisysms_orders.id
- wallet_ledger (rls_enabled: true)
  - Columns: id (uuid), user_id (uuid not null), type (check ['CREDIT','DEBIT','RESERVE','REFUND','ADJUST']), status (check ['PENDING','RESERVED','COMMITTED','VOID','FAILED'] default 'COMMITTED'), amount_cents (int > 0), currency (text default 'USD'), balance_after_cents (int), metadata (jsonb), created_at (timestamptz now()), created_by (text default 'system')
  - FK: user_id → profiles.id
- stripe_payments (rls_enabled: true)
  - Columns: id (uuid), user_id (uuid not null), payment_intent_id (text unique), status (text), amount_cents (int), currency (text default 'USD'), raw_event (jsonb), created_at/updated_at (timestamptz now())
  - FK: user_id → profiles.id
- daisysms_accounts (rls_enabled: true)
  - Columns: id (uuid), label (text), api_key (text), active (bool default true), priority (int default 100), max_parallel (int default 20), low_balance_threshold_cents (int default 1000), current_balance_cents (int default 0), last_checked_at (timestamptz)
- daisysms_orders (rls_enabled: true)
  - Columns: id (uuid), daisysms_account_id (uuid), user_id (uuid), rental_id (uuid), service_code (text), country_code (text), external_activation_id (text), price_cents (int), status (check ['REQUESTED','ACTIVE','COMPLETED','CANCELLED','FAILED','REFUNDED']), last_status (text), created_at/updated_at (timestamptz now())
- ops_alerts (rls_enabled: true)
  - Columns: id (uuid), type (check ['DAISY_LOW_BALANCE','DAISY_ERROR','STRIPE_WEBHOOK_ERROR']), target_id (uuid), message (text), severity (text default 'info'), created_at, acknowledged_by (text), acknowledged_at

Notes:
- RLS is enabled broadly (profiles, rentals, wallet_ledger, stripe_payments, daisysms_* , ops_alerts). Policies must allow row-level access for the owner and service-role writes where needed.
- No migrations were returned by `list_migrations` (schema likely managed outside migration history or history not exposed by MCP).

4) Edge Functions – from repository
- create_checkout_session (verify_jwt: likely enabled at deploy; code assumes POST)
  - Creates Stripe Checkout Session (one-time payment) from `amount_cents`; returns `{ url, id }`.
  - success_url/cancel_url currently point to `https://burnasms.com/checkout_redirect/{success|cancel}.html?session_id={CHECKOUT_SESSION_ID}` which attempt to deep link back to the app.
  - Metadata includes `client_reference_id` and `amount_cents`; current code expects optional `user_id` in body but the Flutter client does not pass it. Recommendation: infer user id from JWT and set both `client_reference_id` and `metadata.user_id` server-side.

- stripe_webhook (verify_jwt: false)
  - Uses Stripe SubtleCrypto provider for signature verification against `STRIPE_WEBHOOK_SIGNING_SECRET`.
  - Handles `checkout.session.completed`, `payment_intent.succeeded`, `charge.succeeded`.
  - Upserts `stripe_payments` via PostgREST with service role (`Prefer: resolution=merge-duplicates`).
  - On successful events, calls `rpc/wallet_credit` with `{ p_user_id, p_amount_cents, p_reason }` (requires RPC to exist, SECURITY DEFINER, and to own the balance update + ledger write atomically).

- Note: A separate `create_payment_intent` function was mentioned previously; it is not present in the current repo snapshot and is not used by the Flutter client.

5) End-to-End Flows
A) Authentication
- Client: ['SupabaseService.initialize()'](burna_sms_app/lib/services/supabase_service.dart:15) then ['signInWithGoogle()'](burna_sms_app/lib/services/supabase_service.dart:30) with redirect deep-link com.burnasms.app://auth-callback.
- AuthProvider listens to ['onAuthStateChange'](burna_sms_app/lib/services/auth_provider.dart:27) and loads/creates profile record for the user.

B) Wallet Top-up (Stripe)
- UI: HomeScreen "Add funds" prompts for amount.
- Client: `BillingService.openExternalCheckout(amount_cents)` calls Edge Function `create_checkout_session`; receives a Checkout URL and opens in Safari (externalApplication).
- Stripe: User completes payment → `stripe_webhook` receives event, verifies signature, upserts `stripe_payments`, then credits wallet via `wallet_credit` RPC.
- Client: On app resume and via realtime subscription on `profiles`, wallet pill updates (`getWalletBalanceCents` + channel push).

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
  - `SupabaseService.subscribeToWalletChanges` subscribes to Postgres updates on `profiles` row for the user and pushes `wallet_balance_cents` into UI; HomeScreen also refreshes on resume.
- Rentals:
  - Home subscribes to a channel for user’s rentals and runs a light poller with exponential backoff to fetch SMS until completion/expiry. `BurnaService` also monitors expiries and normalizes state.

7) Security Notes and RLS
- profiles.rls_enabled = true (current): Policies should allow users to select their own row and update safe fields only; wallet changes must be server-owned (RPCs/service role only).
- rentals.rls_enabled = true: Policies should scope to `user_id = auth.uid()` for read/write.
- wallet_ledger.rls_enabled = true: Server-only writes via RPCs; users can read their own ledger if desired policy-wise.
- stripe_payments.rls_enabled = true: Insert/update via service-role in webhook; users can read their own rows.
- Edge Functions use service-role key for DB writes; inputs validated; Stripe signature verified using Stripe SDK.

8) Known Gaps and Recommendations (updated)
- Stripe Checkout redirect mismatch (root cause of “not returning to app”):
  - iOS Info.plist registers custom URL scheme `com.burnasms.app` for OAuth callbacks.
  - The hosted redirect pages (`burnasms-web/public/checkout_redirect/success.html` and `cancel.html`) currently attempt to open `burnasms://...` which is NOT registered in Info.plist.
  - Runner entitlements include `applinks:burnasms.com` (for Universal Links), but the domain must host a valid Apple App Site Association (AASA) file to enable auto-open. Without AASA, only the custom scheme fallback will work — and only if the scheme matches.

- Missing `user_id` propagation to Stripe:
  - `create_checkout_session` expects `user_id` in body to set `client_reference_id`/metadata. The Flutter client does not send it. Webhook then may upsert a `stripe_payments` row with `user_id = null` (which violates NOT NULL) or skip wallet credit.
  - Fix: infer user id from the verified JWT in the Edge Function and set it server-side (do not trust client).

- RPC coverage:
  - Client uses wallet RPCs (`wallet_create_hold`, `wallet_commit_hold`, `wallet_refund_hold`, `wallet_debit_success`). Webhook calls `wallet_credit`. Ensure these RPCs exist, are SECURITY DEFINER, validate ownership, and update `profiles.wallet_balance_cents` + insert `wallet_ledger` atomically.

- Realtime duplication:
  - HomeScreen now centralizes wallet/rentals subscriptions appropriately. Keep all realtime subscriptions in `SupabaseService` where possible to avoid duplicates.

- Time handling: App uses UTC for expiry/linger logic consistently. Keep this invariant across DB/Edge Functions.

9) Stripe Checkout Redirect – Diagnosis and Fixes

Problem:
- After successful payment, Stripe redirects the browser to `https://burnasms.com/checkout_redirect/success.html?...`.
- That page tries to deep link to `burnasms://checkout/success?...`, but iOS only recognizes `com.burnasms.app://...` (per Info.plist). Universal Links are declared in entitlements but require AASA on the domain to function.

Two viable fixes (choose A plus B for best UX):

A) Immediate, low-risk fix (custom URL scheme alignment)
- Update the redirect pages to use the existing registered scheme:
  - Use `com.burnasms.app://checkout/success?cs={CHECKOUT_SESSION_ID}` and `com.burnasms.app://checkout/cancel?...` instead of `burnasms://...`.
- No additional iOS changes required. This brings manual/open-on-tap behavior back (Safari may still require a user gesture to open the scheme; the page already shows an “Open App” button to comply).

B) Proper auto-return (Universal Links)
- Keep `applinks:burnasms.com` in `Runner.entitlements`.
- Host a valid `apple-app-site-association` (AASA) file on `https://burnasms.com/.well-known/apple-app-site-association` (and optionally `https://burnasms.com/apple-app-site-association`) declaring the paths you want (e.g., `/checkout_redirect/*` or cleaner `/ul/*`).
- Change `success_url`/`cancel_url` in `create_checkout_session` to Universal Link paths that the app handles, e.g., `https://burnasms.com/ul/checkout/success?session_id={CHECKOUT_SESSION_ID}`.
- In Flutter, handle incoming links (e.g., with `uni_links` or `app_links`) to trigger a wallet refresh on arrival. The app already refreshes on resume, so link handling can be minimal.

Recommended additional edge-function hardening:
- In `create_checkout_session`, require JWT (verify_jwt), parse `user_id` from the auth context, and set `client_reference_id` + `metadata.user_id` server-side.
- Ensure webhook credits wallet idempotently and logs errors to `ops_alerts` with enough detail for retries.

10) Suggested Simplifications (without breaking current flows)

Stripe & wallet
- Use only Stripe Checkout (remove any unused PaymentIntent creation function). Keep a single `create_checkout_session` entrypoint.
- Server-derive `user_id` in `create_checkout_session` and set both `client_reference_id` and metadata. This makes the webhook deterministic and keeps `stripe_payments.user_id` non-null.
- Switch `success_url` to a Universal Link path once AASA is live; keep the existing HTML redirect pages as a fallback (with scheme fixed as in A).
- Consider adopting Stripe’s official Supabase Stripe Sync Engine for robust event ingestion:
  - Pros: battle-tested schema, idempotent ingestion, typed events, retries.
  - Approach: either adopt the engine’s webhook endpoint and mirror into your existing tables via DB triggers, or migrate to the engine’s tables and query them from the client for Payments history. Wallet credit can still be done by your webhook or a DB trigger on successful payments.

Client
- Keep wallet/rentals realtime subscriptions in `SupabaseService` (one place). HomeScreen already wires them; avoid duplicate channels elsewhere.
- On return from Checkout, you can rely on: (a) realtime wallet update, (b) onResume refresh; optionally parse the inbound deep link to show a friendly “Payment success” toast.

Security & RLS
- Profiles RLS is enabled — add/update policies so users can only select/update their own row and cannot update `wallet_balance_cents` directly (server-only via RPC/service role). Consider a DB view for safe profile fields if needed.
- Ensure wallet RPCs are SECURITY DEFINER, validate `auth.uid()` matches, and include a unique idempotency key to prevent double-commit/refund.

11) Actionable Checklists

Minimum to fix redirect this release (≤30 mins):
- [ ] Change deep link scheme in `burnasms-web/public/checkout_redirect/success.html` and `cancel.html` from `burnasms://...` to `com.burnasms.app://...`.
- [ ] In `create_checkout_session`, derive `user_id` from JWT and set `client_reference_id` and `metadata.user_id` (stop expecting client to pass it).

High-quality follow-up (1–2 hrs):
- [ ] Add AASA to `burnasms.com` and switch `success_url`/`cancel_url` to Universal Links; keep HTML pages as fallback.
- [ ] Add idempotency to wallet RPCs and ensure error surfaces to `ops_alerts`.
- [ ] Optionally evaluate/plan Stripe Sync Engine adoption.

12) Requirements Coverage (current task)
- Flutter app review: Done (Auth, BillingService, BurnaService, SupabaseService, HomeScreen; iOS Info.plist and entitlements).
- Supabase MCP review: Done (tables, RLS state, relationships; migrations not listed by MCP). Edge Functions read and summarized.
- Stripe webhook review: Done; hardened and ensured deterministic user mapping from JWT via Checkout metadata/client_reference_id.
- Updated this overview with findings and concrete fixes to the Stripe redirect, webhook reliability, and simplification plan.