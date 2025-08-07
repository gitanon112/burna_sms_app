import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:simple_icons/simple_icons.dart';
import '../services/auth_provider.dart';
import '../services/supabase_service.dart';
import '../services/burna_service.dart';
import '../services/billing_service.dart';
import '../models/user.dart' as app_user;
import '../models/rental.dart';
import '../models/service_data.dart';
import '../constants/app_constants.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/compact_service_tile.dart';
import 'dart:async';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  final SupabaseService _supabaseService = SupabaseService();
  final BurnaService _daisyService = BurnaService();
  final TextEditingController _searchController = TextEditingController();
  
  List<ServiceData> _availableServices = [];
  List<ServiceData> _filteredServices = [];
  List<Rental> _activeRentals = [];
  List<Rental> _historyRentals = [];
  // Linger map: rentalId -> DateTime when it should stop lingering (keep visible in My Numbers)
  final Map<String, DateTime> _lingerUntil = {};
  // Remove old local profile channel field if present and replace with rentals + pollers
  // Re-declare safely, guarding duplicates:
  // The profile channel is retained for backward compatibility but not used.
  // Prefix with underscore and ignore analyzer for unused field.
  // ignore: unused_field
  RealtimeChannel? _profileChannel; // keep if referenced elsewhere but we won't use it now

  // Add (only once): rentals realtime and polling management
  RealtimeChannel? _rentalsChannel;
  final Map<String, Timer> _rentalPollers = {};
  
  // Missing state fields used throughout this file
  int _walletBalanceCents = 0;
  bool _isLoading = false;
  String? _errorMessage;
  String _searchQuery = '';
  bool _showAllServices = false;
  // History toggle state: 'rentals' or 'payments'
  String _historyView = 'rentals';
  List<Map<String, dynamic>> _payments = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);

    // Wire wallet instant updates from BurnaService
    _daisyService.onWalletBalanceChanged = (cents) {
      if (!mounted) return;
      setState(() => _walletBalanceCents = cents);
    };

    _loadInitialData().then((_) {
      // After initial load, align pollers with current active rentals
      _syncRentalPollers();
    });

    _refreshWallet();

    _daisyService.startExpiryMonitoring();

    _subscribeToProfileBalance();
    _subscribeToRentalsRealtime();
  }

  // Helper to refresh wallet pill value; used in initState and menu action
  Future<void> _refreshWallet() async {
    try {
      final cents = await _supabaseService.getWalletBalanceCents();
      if (!mounted) return;
      setState(() {
        _walletBalanceCents = cents;
      });
    } catch (e) {
      // silent fail: UI still works with old value
      debugPrint('refreshWallet error: $e');
    }
  }

  // Add: rentals realtime subscription (only one definition)
  void _subscribeToRentalsRealtime() {
    final uid = _supabaseService.currentUser?.id;
    if (uid == null) return;
    try {
      _rentalsChannel?.unsubscribe();
      _rentalsChannel = Supabase.instance.client
          .channel('public:rentals:$uid')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'rentals',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: uid,
            ),
            callback: (payload) async {
              await _loadActiveRentals();
              _syncRentalPollers();
            },
          )
          .subscribe();
    } catch (_) {
      // ignore
    }
  }

  // Add: create/cleanup pollers for active rentals (use exponential backoff to reduce load)
  void _syncRentalPollers() {
    final activeIds = _activeRentals.map((r) => r.id).toSet();

    // Stop pollers for rentals no longer active or present
    for (final entry in _rentalPollers.entries.toList()) {
      if (!activeIds.contains(entry.key)) {
        entry.value.cancel();
        _rentalPollers.remove(entry.key);
      }
    }

    // Start pollers for active rentals that don't have one
    for (final r in _activeRentals) {
      if (_rentalPollers.containsKey(r.id)) continue;
      if (r.status.toLowerCase() != 'active') continue;

      // Exponential backoff sequence: 3s -> 5s -> 8s -> 12s -> 12s ...
      final backoff = <Duration>[const Duration(seconds: 3), const Duration(seconds: 5), const Duration(seconds: 8), const Duration(seconds: 12)];
      int idx = 0;

      Future<void> tick() async {
        try {
          final updated = await _daisyService.checkSms(r.id);
          if (updated.smsReceived != null && updated.smsReceived!.isNotEmpty) {
            _lingerUntil[updated.id] = DateTime.now().toUtc().add(const Duration(seconds: 60));
            await _loadActiveRentals();
            // Stop polling once completed
            final t = _rentalPollers.remove(updated.id);
            t?.cancel();
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('SMS received: ${updated.smsReceived}'),
                backgroundColor: Colors.green,
              ),
            );
            return;
          }
          final nowUtc = DateTime.now().toUtc();
          if (updated.expiresAt.toUtc().isBefore(nowUtc) || updated.status.toLowerCase() != 'active') {
            final t = _rentalPollers.remove(updated.id);
            t?.cancel();
            await _loadActiveRentals();
            return;
          }
        } catch (_) {
          // ignore transient errors
        } finally {
          // schedule next with capped backoff
          idx = (idx + 1).clamp(0, backoff.length - 1);
          if (_rentalPollers.containsKey(r.id)) {
            // re-schedule using a one-shot timer to vary interval
            final next = Timer(backoff[idx], tick);
            _rentalPollers[r.id] = next;
          }
        }
      }

      // seed first timer
      _rentalPollers[r.id] = Timer(backoff[idx], tick);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _searchController.dispose();

    _daisyService.stopExpiryMonitoring();

    try {
      _rentalsChannel?.unsubscribe();
      _rentalsChannel = null;
    } catch (_) {}
    for (final t in _rentalPollers.values) {
      t.cancel();
    }
    _rentalPollers.clear();

    super.dispose();
  }

  // Ensure _loadActiveRentals remains single definition and uses UTC in linger cleanup.
  // Example patch around linger cleanup:
  // _lingerUntil.removeWhere((_, until) => until.isBefore(DateTime.now()));
  // becomes:
  // _lingerUntil.removeWhere((_, until) => until.isBefore(DateTime.now().toUtc()));

  // Ensure Check SMS button is not referenced anymore in active rentals rendering.
  // Replace calls to _buildEnhancedRentalCard with _buildCompactRentalTile already added earlier.

  // No changes needed to BillingService usage; just ensure import exists at top.
  // Ensure WALLET pill is not referenced anymore in active rentals rendering
  Future<void> _onResumed() async {
    try {
      final cents = await _supabaseService.hardRefreshWalletBalanceCents();
      if (!mounted) return;
      setState(() => _walletBalanceCents = cents);
    } catch (_) {}
    if (!mounted) return;
    await _refreshWallet();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onResumed();
    }
  }


  // Ensure _loveActiveRentals remains single definition and uses UTC in linger cleanup.
  // Example patch around linger cleanup:
  // _lingerUntil.removeWhere((_, until) => until.isBefore(DateTime.now()));
  // becomes:
  // _lingerUntil.removeWhere((_, until) => until.isBefore(DateTime.now().toUtc()));

  // Ensure Check SMS button is not referenced anymore in active rentals rendering.
  // Replace calls to _buildEnhancedRentalCard with _buildCompactRentalTile already added earlier.

  // No changes needed to BillingService usage; just ensure import exists at top.


  // Ensure _loadActiveRentals remains single definition and uses UTC in linger cleanup.
  // Example patch around linger cleanup:
  // _lingerUntil.removeWhere((_, until) => until.isBefore(DateTime.now()));
  // becomes:
  // _lingerUntil.removeWhere((_, until) => until.isBefore(DateTime.now().toUtc()));

  // Ensure Check SMS button is not referenced anymore in active rentals rendering.
  // Replace calls to _buildEnhancedRentalCard with _buildCompactRentalTile already added earlier.

  // No changes needed to BillingService usage; just ensure import exists at top.
  void _subscribeToProfileBalance() {
    _supabaseService.subscribeToWalletChanges((cents) {
      if (!mounted) return;
      setState(() {
        _walletBalanceCents = cents;
      });
    });
  }


  Future<void> _loadInitialData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Load available services and active rentals in parallel
      await Future.wait([
        _loadAvailableServices(),
        _loadActiveRentals(),
        _loadPayments(),
      ]);
      
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading data: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadAvailableServices() async {
    try {
      final servicesResponse = await _daisyService.getAvailableServices();
      setState(() {
        _availableServices = servicesResponse.availableServices;
        _filterServices();
      });
    } catch (e) {
      debugPrint('Error loading services: $e');
    }
  }

  void _filterServices() {
    if (_searchQuery.isEmpty) {
      // When there's no query:
      // - If _showAllServices is true, show all available services (no whitelist)
      // - Otherwise show curated popular subset
      _filteredServices = _showAllServices ? List<ServiceData>.from(_availableServices) : _getPopularServices();
    } else {
      // When there is a query, search across ALL services by name or code (no whitelist gate)
      final q = _searchQuery.toLowerCase();
      _filteredServices = _availableServices.where((service) {
        final name = service.name.toLowerCase();
        final code = service.serviceCode.toLowerCase();
        return name.contains(q) || code.contains(q);
      }).toList();
      _filteredServices.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
  }

  List<String> _popularWhitelist() => ['whatsapp', 'google', 'twitter', 'instagram', 'facebook'];
  List<String> _popularWhitelistByName() => ['whatsapp', 'google', 'twitter', 'instagram', 'facebook'];
  List<ServiceData> _getPopularServices() {
    final allow = _popularWhitelist();
    final out = <ServiceData>[];
    for (final service in _availableServices) {
      final code = service.serviceCode.toLowerCase();
      final name = service.name.toLowerCase();
      // Keep the full countries map so pricing uses true min across availableCountries
      if (allow.contains(code) || _popularWhitelistByName().any((n) => name.contains(n))) {
        out.add(service);
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  void _onSearchChanged(String query) {
    setState(() {
      _searchQuery = query;
      _filterServices();
    });
  }

  void _toggleShowAll() {
    setState(() {
      _showAllServices = !_showAllServices;
      _filterServices();
    });
  }

  Future<void> _loadActiveRentals() async {
    try {
      final rentals = await _supabaseService.getUserRentals();
      final nowUtc = DateTime.now().toUtc();

      // Clean up expired linger windows using UTC
      _lingerUntil.removeWhere((_, until) => until.isBefore(nowUtc));

      final active = rentals.where((r) {
        final status = r.status.toLowerCase();
        final expiresUtc = r.expiresAt.toUtc();
        final expiredByTime = expiresUtc.isBefore(nowUtc);
        final isActive = status == 'active' && !expiredByTime;
        final isCompletedAndLingering = status == 'completed' &&
            _lingerUntil[r.id] != null &&
            _lingerUntil[r.id]!.isAfter(nowUtc);
        return isActive || isCompletedAndLingering;
      }).toList();

      final history = rentals.where((r) {
        final status = r.status.toLowerCase();
        final isCompleted = status == 'completed';
        final isLingering = _lingerUntil[r.id] != null && _lingerUntil[r.id]!.isAfter(nowUtc);
        return isCompleted && !isLingering;
      }).toList();

      if (mounted) {
        setState(() {
          _activeRentals = active;
          _historyRentals = history;
        });
      }
    } catch (e) {
      debugPrint('Error loading rentals: $e');
    }
  }

  Future<void> _loadPayments() async {
    try {
      // Safeguard: method may not exist at runtime if hot-reload mismatch; guard with try
      final rows = await _supabaseService.getUserPayments();
      if (mounted) setState(() => _payments = rows);
    } catch (e) {
      debugPrint('Error loading payments: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final user = authProvider.userProfile;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F1A),
        foregroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [Color(0xFF7C4DFF), Color(0xFF00E5FF)],
            ).createShader(Rect.fromLTWH(0, 0, 200, 70)),
            child: const Text(
              AppConstants.appName,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 22,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
        actions: [
          // Wallet pill
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Container(
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1DE9B6), Color(0xFF00BCD4)],
                ),
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.account_balance_wallet_rounded, color: Colors.black, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    '\$${(_walletBalanceCents / 100).toStringAsFixed(2)}',
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Add funds',
            icon: const Icon(Icons.add_card_rounded, color: Colors.white),
            onPressed: () async {
              // Capture messenger early to avoid context after async gaps
              final messenger = ScaffoldMessenger.of(context);
              // Prompt for any amount in USD
              final controller = TextEditingController(text: '5.00');
              final amount = await showDialog<double?> (
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Add Funds'),
                  content: TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Amount (USD)',
                      hintText: 'e.g. 5.00',
                    ),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Cancel')),
                    ElevatedButton(
                      onPressed: () {
                        final v = double.tryParse(controller.text.trim());
                        Navigator.pop(ctx, v);
                      },
                      child: const Text('Continue'),
                    ),
                  ],
                ),
              );

              if (amount == null) return;
              final cents = (amount * 100).round();
              if (cents <= 0) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('Enter a valid amount'), backgroundColor: Colors.orange),
                );
                return;
              }

              try {
                final opened = await BillingService().openExternalCheckout(amountCents: cents);
                if (opened) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Opening secure Checkout...'), backgroundColor: Colors.blue),
                  );
                }
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text('Unable to open Checkout: $e'), backgroundColor: Colors.red),
                );
              }
            },
          ),
          // Profile circle menu
          PopupMenuButton<String>(
            icon: const CircleAvatar(
              radius: 16,
              backgroundColor: Color(0xFF12192E),
              child: Icon(Icons.person, color: Colors.white),
            ),
            color: const Color(0xFF0F172A),
            elevation: 6,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Color(0x1AFFFFFF)),
            ),
            onSelected: (value) async {
              switch (value) {
                case 'profile':
                  _showProfileDialog(context, user);
                  break;
                case 'refresh':
                  await _loadInitialData();
                  await _refreshWallet();
                  break;
                case 'logout':
                  final authProvider = Provider.of<AuthProvider>(context, listen: false);
                  await authProvider.signOut();
                  break;
              }
            },
            itemBuilder: (BuildContext context) => [
              PopupMenuItem(
                value: 'profile',
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: const [
                    Icon(Icons.person, color: Colors.white70),
                    SizedBox(width: 12),
                    Text('Profile', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'refresh',
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: const [
                    Icon(Icons.refresh, color: Colors.white70),
                    SizedBox(width: 12),
                    Text('Refresh', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'logout',
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: const [
                    Icon(Icons.logout, color: Colors.white70),
                    SizedBox(width: 12),
                    Text('Logout', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF00E5FF),
          labelColor: Colors.white,
          tabs: const [
            Tab(icon: Icon(Icons.shopping_cart), text: 'Purchase'),
            Tab(icon: Icon(Icons.phone), text: 'My Numbers'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? _buildErrorWidget()
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildPurchaseTab(),
                    _buildActiveRentalsTab(),
                    _buildHistoryTab(),
                  ],
                ),
    );
  }

  Widget _buildErrorWidget() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.defaultPadding),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.red.shade400,
            ),
            const SizedBox(height: 16),
            Text(
              'Something went wrong',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadInitialData,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPurchaseTab() {
    // Dark, compact, US-only presentation
    if (_availableServices.isEmpty) {
      return _buildEmptyState(
        icon: Icons.shopping_cart_outlined,
        title: 'No Services Available',
        subtitle: 'Check back later for available phone services',
        actionText: 'Refresh',
        onAction: _loadInitialData,
      );
    }

    // Derive a flat list for display: name, price (min), code
    final items = _filteredServices.map((s) {
      final price = s.availableCountries.isNotEmpty
          ? s.availableCountries.map((c) => c.burnaPrice).reduce((a, b) => a < b ? a : b)
          : 0.0;
      return (s, price);
    }).toList()
      ..sort((a, b) => a.$1.name.toLowerCase().compareTo(b.$1.name.toLowerCase()));

    return RefreshIndicator(
      onRefresh: _loadInitialData,
      child: Column(
        children: [
          // Minimal search on dark bg
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search services',
                hintStyle: const TextStyle(color: Colors.white54),
                prefixIcon: const Icon(Icons.search, color: Colors.white70),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white70),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF111827),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0x1AFFFFFF)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0x33FFFFFF), width: 1.5),
                ),
              ),
            ),
          ),
          if (_searchQuery.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    _showAllServices ? 'All services' : 'Popular services',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _toggleShowAll,
                    child: Text(
                      _showAllServices ? 'Show Popular' : 'Show All',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: items.isEmpty
                ? _buildEmptySearchState()
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final service = items[index].$1;
                      final price = items[index].$2;
                      final icon = _getServiceIcon(service.name);
                      return CompactServiceTile(
                        name: service.name,
                        priceText: '\$${price.toStringAsFixed(2)}',
                        iconData: icon,
                        onTap: () {
                          // US-only offering: bypass country sheet entirely. If US not present, show a toast.
                          // DaisySMS is US-only. Call purchase with service code only; second arg kept for signature but ignored downstream.
                          _purchaseNumber(service.serviceCode, 'US');
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptySearchState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.grey.shade100, Colors.grey.shade200],
                ),
                borderRadius: BorderRadius.circular(60),
              ),
              child: Icon(
                Icons.search_off,
                size: 64,
                color: Colors.grey.shade400,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No services found',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isNotEmpty
                  ? 'Try searching for different keywords like "Google", "Facebook", or "Twitter"'
                  : 'No services are currently available',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey.shade500,
              ),
              textAlign: TextAlign.center,
            ),
            if (_searchQuery.isNotEmpty) ...[
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  _searchController.clear();
                  _onSearchChanged('');
                },
                child: const Text('Clear Search'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActiveRentalsTab() {
    return RefreshIndicator(
      onRefresh: () async {
        await _loadActiveRentals();
        _syncRentalPollers();
      },
      child: _activeRentals.isEmpty
          ? _buildEmptyState(
              icon: Icons.phone_disabled,
              title: 'No Active Rentals',
              subtitle: 'Purchase a phone number to get started and manage your SMS receiving',
              actionText: 'Browse Services',
              onAction: () => _tabController.animateTo(0),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _activeRentals.length,
              itemBuilder: (context, index) {
                final rental = _activeRentals[index];
                return _buildCompactRentalTile(rental);
              },
            ),
    );
  }

  Widget _buildCompactRentalTile(Rental rental) {
    final nowUtc = DateTime.now().toUtc();
    final expiresUtc = rental.expiresAt.toUtc();
    final isExpired = expiresUtc.isBefore(nowUtc);
    final timeRemaining = isExpired ? Duration.zero : expiresUtc.difference(nowUtc);
    final status = rental.status.toLowerCase();
    final displayService = _expandedServiceName(rental.serviceName); // use full name

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: Service name on left, right cluster with US chip, price, time-left
            Row(
              children: [
                Expanded(
                  child: Text(
                    displayService,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ),
                const SizedBox(width: 8),
                _chip('🇺🇸  US'),
                const SizedBox(width: 8),
                _chip('\$${rental.burnaPrice.toStringAsFixed(2)}'),
                const SizedBox(width: 8),
                _chip(
                  status == 'active'
                      ? (isExpired ? 'expired' : '${timeRemaining.inMinutes}m left')
                      : status,
                  color: status == 'active'
                      ? (timeRemaining.inMinutes < 10 ? const Color(0x33FF5252) : const Color(0x3338BDF8))
                      : const Color(0x332196F3),
                  borderColor: status == 'active'
                      ? (timeRemaining.inMinutes < 10 ? const Color(0x66FF5252) : const Color(0x6638BDF8))
                      : const Color(0x662196F3),
                  icon: status == 'active' ? Icons.timer : Icons.check_circle,
                  iconColor: status == 'active'
                      ? (timeRemaining.inMinutes < 10 ? Colors.redAccent : const Color(0xFF38BDF8))
                      : Colors.lightBlueAccent,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Number row + copy button aligned
            Row(
              children: [
                Expanded(
                  child: Text(
                    _formatUsNumberDashed(rental.phoneNumber),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 20, letterSpacing: 0.4),
                  ),
                ),
                const SizedBox(width: 8),
                _squareIconButton(
                  icon: Icons.copy,
                  tooltip: 'Copy number',
                  onTap: () => _copyToClipboard(_digitsOnly(rental.phoneNumber)),
                ),
              ],
            ),
            if (rental.smsReceived != null && rental.smsReceived!.isNotEmpty) ...[
              const SizedBox(height: 12),
              _codeChip(rental.smsReceived!),
            ],
            const SizedBox(height: 12),
            // Actions row
            Row(
              children: [
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: status == 'active' ? () => _cancelRental(rental) : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: status == 'active' ? Colors.red.shade600 : Colors.grey,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: status == 'active' ? 4 : 0,
                  ),
                  icon: const Icon(Icons.cancel, size: 18),
                  label: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryTab() {
    return RefreshIndicator(
      onRefresh: () async {
        await _loadActiveRentals();
        await _loadPayments();
      },
      child: Column(
        children: [
          const SizedBox(height: 8),
          // Segmented toggle
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0x1AFFFFFF)),
            ),
            child: Row(
              children: [
                _segmentButton('Rentals', 'rentals'),
                const SizedBox(width: 6),
                _segmentButton('Payments', 'payments'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _historyView == 'rentals'
                ? (_historyRentals.isEmpty
                    ? _buildEmptyState(
                        icon: Icons.history,
                        title: 'No History Yet',
                        subtitle: 'Your completed and cancelled rentals will appear here',
                        actionText: 'Browse Services',
                        onAction: () => _tabController.animateTo(0),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _historyRentals.length,
                        itemBuilder: (context, index) {
                          final rental = _historyRentals[index];
                          return _buildHistoryRentalTile(rental);
                        },
                      ))
                : (_payments.isEmpty
                    ? _buildEmptyState(
                        icon: Icons.receipt_long,
                        title: 'No Payments Yet',
                        subtitle: 'Your card top-ups will appear here',
                        actionText: 'Add Funds',
                        onAction: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Use + card button to add funds'))),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _payments.length,
                        itemBuilder: (context, index) {
                          final p = _payments[index];
                          return _buildPaymentTile(p);
                        },
                      )),
          ),
        ],
      ),
    );
  }

  Widget _segmentButton(String label, String key) {
    final selected = _historyView == key;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _historyView = key),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF111827) : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0x1AFFFFFF)),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(color: selected ? Colors.white : Colors.white70, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryRentalTile(Rental rental) {
    final created = rental.createdAt.toLocal();
    final dateStr = '${created.year}-${created.month.toString().padLeft(2, '0')}-${created.day.toString().padLeft(2, '0')} ${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';
    final displayService = _expandedServiceName(rental.serviceName);
    final effectiveStatus = rental.status.toLowerCase();
    final statusColor = _getStatusColor(effectiveStatus);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        dense: true,
        visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.15),
          child: Icon(Icons.phone_iphone, color: statusColor),
        ),
        title: Text(
          displayService,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 2),
                  Text(_formatUsNumberDashed(rental.phoneNumber), style: const TextStyle(color: Colors.white70), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text('Date: $dateStr', style: const TextStyle(color: Colors.white54, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text('Price: \$${rental.burnaPrice.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white70), maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (rental.smsReceived != null && rental.smsReceived!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('SMS: ${rental.smsReceived!}', style: const TextStyle(color: Colors.white70), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Compact right-side actions to avoid vertical overflow
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _chip(effectiveStatus.toUpperCase(), color: Colors.transparent, borderColor: statusColor.withValues(alpha: 0.5)),
                const SizedBox(height: 6),
                _squareIconButton(icon: Icons.copy, tooltip: 'Copy number', onTap: () => _copyToClipboard(_digitsOnly(rental.phoneNumber))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentTile(Map<String, dynamic> p) {
    final created = DateTime.tryParse(p['created_at']?.toString() ?? '')?.toLocal();
    final dateStr = created == null ? '' : '${created.year}-${created.month.toString().padLeft(2, '0')}-${created.day.toString().padLeft(2, '0')} ${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';
    final cents = (p['amount_cents'] as num?)?.toInt() ?? 0;
    final status = (p['status']?.toString() ?? '').toLowerCase();
    final statusColor = _getStatusColor(status == 'succeeded' ? 'completed' : status);
    final pi = (p['payment_intent_id']?.toString() ?? '');
    final shortPi = pi.length > 18 ? '${pi.substring(0,18)}...' : pi;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
        minVerticalPadding: 6,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.15),
          child: const Icon(Icons.receipt_long, color: Colors.white),
        ),
        title: Text(
          '\$${(cents / 100).toStringAsFixed(2)}',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
        subtitle: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (dateStr.isNotEmpty)
                    Text(dateStr, style: const TextStyle(color: Colors.white70, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('Status: ${p['status']}', style: const TextStyle(color: Colors.white70, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('Intent: $shortPi', style: const TextStyle(color: Colors.white54, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _chip(
              status.toUpperCase(),
              color: Colors.transparent,
              borderColor: statusColor.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'active':
        return Colors.green;
      case 'completed':
        return Colors.blue;
      case 'cancelled':
        return Colors.orange;
      case 'expired':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    String? actionText,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.grey.shade100, Colors.grey.shade200],
                ),
                borderRadius: BorderRadius.circular(60),
              ),
              child: Icon(
                icon,
                size: 64,
                color: Colors.grey.shade400,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey.shade500,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionText != null && onAction != null) ...[
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: onAction,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(25),
                  ),
                ),
                child: Text(actionText),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _getServiceIcon(String serviceName) {
    final name = serviceName.toLowerCase();

    // Exact brand logos using simple_icons
    if (name.contains('whatsapp')) return SimpleIcons.whatsapp;
    if (name.contains('telegram')) return SimpleIcons.telegram;
    if (name.contains('discord')) return SimpleIcons.discord;
    if (name.contains('instagram')) return SimpleIcons.instagram;
    if (name.contains('facebook')) return SimpleIcons.facebook;
    if (name.contains('twitter') || name.contains('x.com') || name.contains('x ')) return SimpleIcons.x;
    if (name.contains('google')) return SimpleIcons.google;
    if (name.contains('youtube')) return SimpleIcons.youtube;
    if (name.contains('amazon')) return SimpleIcons.amazon;
    if (name.contains('uber')) return SimpleIcons.uber;
    if (name.contains('airbnb')) return SimpleIcons.airbnb;
    if (name.contains('netflix')) return SimpleIcons.netflix;
    if (name.contains('spotify')) return SimpleIcons.spotify;
    if (name.contains('paypal')) return SimpleIcons.paypal;
    if (name.contains('microsoft')) return SimpleIcons.microsoft;
    if (name.contains('apple')) return SimpleIcons.apple;
    if (name.contains('tinder')) return SimpleIcons.tinder;
    if (name.contains('linkedin')) return SimpleIcons.linkedin;
    if (name.contains('github')) return SimpleIcons.github;
    if (name.contains('dropbox')) return SimpleIcons.dropbox;
    if (name.contains('steam')) return SimpleIcons.steam;
    if (name.contains('snapchat')) return SimpleIcons.snapchat;
    if (name.contains('tiktok')) return SimpleIcons.tiktok;
    if (name.contains('pinterest')) return SimpleIcons.pinterest;
    if (name.contains('reddit')) return SimpleIcons.reddit;
    if (name.contains('twitch')) return SimpleIcons.twitch;
    if (name.contains('venmo')) return SimpleIcons.venmo;
    if (name.contains('cashapp')) return SimpleIcons.cashapp;

    // Category-based fallbacks using Material icons
    if (name.contains('bank') || name.contains('finance')) return Icons.account_balance;
    if (name.contains('shop') || name.contains('store')) return Icons.store;
    if (name.contains('food') || name.contains('delivery')) return Icons.restaurant;
    if (name.contains('ride') || name.contains('taxi')) return Icons.directions_car;
    if (name.contains('hotel') || name.contains('travel')) return Icons.hotel;
    if (name.contains('game')) return Icons.sports_esports;
    if (name.contains('crypto') || name.contains('bitcoin')) return Icons.currency_bitcoin;

    return Icons.business;
  }

  Future<void> _purchaseNumber(String serviceCode, String countryCode) async {
    try {
      final rental = await _daisyService.purchaseNumber(
        serviceCode: serviceCode,
        countryCode: countryCode,
      );
      
      // BurnaService.purchaseNumber() already creates the rental in Supabase
      // No need to create it again here
      await _loadActiveRentals();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully purchased ${rental.phoneNumber}'),
            backgroundColor: Colors.green,
          ),
        );
        _tabController.animateTo(1); // Switch to My Numbers tab
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Purchase failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _cancelRental(Rental rental) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Rental'),
        content: const Text('Are you sure you want to cancel this rental? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _daisyService.cancelRental(rental.id);
        
        await _supabaseService.updateRental(rental.id, {'status': 'cancelled'});
        await _loadActiveRentals();
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Rental cancelled'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error cancelling rental: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _showProfileDialog(BuildContext context, app_user.User? user) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0x1AFFFFFF)),
        ),
        title: const Text('Profile', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _profileRow(icon: Icons.email, text: user?.email ?? 'No email'),
            const SizedBox(height: 10),
            _profileRow(icon: Icons.attach_money, text: 'Total Spent: \$${user?.totalSpent.toStringAsFixed(2) ?? '0.00'}'),
            const SizedBox(height: 10),
            _profileRow(icon: Icons.phone_iphone, text: 'Total Rentals: ${user?.totalRentals ?? 0}'),
            const SizedBox(height: 10),
            _profileRow(icon: Icons.calendar_today, text: 'Member since ${user?.createdAt.toLocal().toString().split(' ')[0] ?? 'Unknown'}'),
          ],
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _profileRow({required IconData icon, required String text}) {
    return Row(
      children: [
        Icon(icon, color: Colors.white70),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Colors.white70),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  // Expand known abbreviations to full service names for display
  String _expandedServiceName(String input) {
    final map = <String, String>{
      'fb': 'Facebook',
      'ig': 'Instagram',
      'wa': 'WhatsApp',
      'tg': 'Telegram',
      'tw': 'Twitter',
      'x': 'Twitter',
      'yt': 'YouTube',
      'gv': 'Google Voice',
      'ms': 'Microsoft',
      'gh': 'GitHub',
    };
    final lower = input.trim().toLowerCase();
    return map[lower] ?? input;
  }

  // Small helper chips for right-side cluster
  Widget _chip(String text, {Color? color, Color? borderColor, IconData? icon, Color? iconColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color ?? const Color(0xFF111827),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor ?? const Color(0x1AFFFFFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: iconColor ?? Colors.white70),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: const TextStyle(fontSize: 12, color: Colors.white70, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _squareIconButton({required IconData icon, required String tooltip, required VoidCallback onTap}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white70, size: 20),
        tooltip: tooltip,
      ),
    );
  }

  Widget _codeChip(String code) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x3328A745),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x6628A745)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.sms, color: Color(0xFF28A745), size: 16),
          const SizedBox(width: 8),
          Text(
            code,
            style: const TextStyle(color: Color(0xFF28A745), fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: 0.3),
          ),
          const SizedBox(width: 8),
          _squareIconButton(
            icon: Icons.copy,
            tooltip: 'Copy code',
            onTap: () => _copyToClipboard(code),
          ),
        ],
      ),
    );
  }

  // Format: show dashed 1-AAA-BBB-CCCC for US/E.164-like numbers; fall back to original if not 11 digits starting with '1'
  String _formatUsNumberDashed(String input) {
    final digits = _digitsOnly(input);
    if (digits.length == 11 && digits.startsWith('1')) {
      final a = digits.substring(1, 4);
      final b = digits.substring(4, 7);
      final c = digits.substring(7, 11);
      return '1-$a-$b-$c';
    }
    // If 10 digits, assume US without country code
    if (digits.length == 10) {
      final a = digits.substring(0, 3);
      final b = digits.substring(3, 6);
      final c = digits.substring(6, 10);
      return '$a-$b-$c';
    }
    return input;
  }

  String _digitsOnly(String input) {
    final buf = StringBuffer();
    for (final ch in input.runes) {
      final c = String.fromCharCode(ch);
      if (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57) {
        buf.write(c);
      }
    }
    return buf.toString();
  }
}
