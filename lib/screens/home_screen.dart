import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/auth_provider.dart';
import '../services/supabase_service.dart';
import '../services/burna_service.dart';
import '../services/billing_service.dart';
import '../models/user.dart' as app_user;
import '../models/rental.dart';
import '../models/service_data.dart';
import '../constants/app_constants.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  bool _isLoading = false;
  bool _showAllServices = false;
  String? _errorMessage;
  String _searchQuery = '';

  int _walletBalanceCents = 0;
  RealtimeChannel? _profileChannel;
  
  Future<void> _onResumed() async {
    try {
      final cents = await _supabaseService.hardRefreshWalletBalanceCents();
      if (mounted) {
        setState(() => _walletBalanceCents = cents);
      }
    } catch (_) {}
    await _refreshWallet();
  }

  void _subscribeToProfileBalance() {
    final userId = _supabaseService.currentUser?.id;
    if (userId == null) return;
    try {
      _profileChannel = Supabase.instance.client
        .channel('realtime:profiles_wallet_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'profiles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: userId,
          ),
          callback: (payload) {
            final newRecord = payload.newRecord;
            final cents = (newRecord['wallet_balance_cents'] as num?)?.toInt();
            if (cents != null && mounted) {
              setState(() {
                _walletBalanceCents = cents;
              });
            }
          },
        )
        .subscribe();
    } catch (_) {
      // Non-fatal; UI will still poll when needed.
    }
  }
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    _loadInitialData();
    _refreshWallet();
    
    // Start expiry monitoring for rentals
    _daisyService.startExpiryMonitoring();
    
    _subscribeToProfileBalance();
  }

  Future<void> _refreshWallet() async {
    try {
      final cents = await _supabaseService.getWalletBalanceCents();
      if (mounted) {
        setState(() {
          _walletBalanceCents = cents;
        });
      }
    } catch (_) {}
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _searchController.dispose();
    
    // Stop expiry monitoring when the screen is disposed
    _daisyService.stopExpiryMonitoring();
    
    try {
      _profileChannel?.unsubscribe();
      _profileChannel = null;
    } catch (_) {}
    
    super.dispose();
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
      // Only display curated popular set (USA-only offering)
      _filteredServices = _getPopularServices();
    } else {
      _filteredServices = _availableServices.where((service) {
        final name = service.name.toLowerCase();
        final code = service.serviceCode.toLowerCase();
        final allowed = _popularWhitelist().contains(code) || _popularWhitelistByName().any((n) => name.contains(n));
        return allowed && (name.contains(_searchQuery.toLowerCase()) || code.contains(_searchQuery.toLowerCase()));
      }).toList();
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
      if (allow.contains(code) || _popularWhitelistByName().any((n) => name.contains(n))) {
        final firstEntry = service.countries.entries.isNotEmpty ? service.countries.entries.first : null;
        out.add(ServiceData(
          serviceCode: service.serviceCode,
          name: service.name,
          countries: firstEntry == null ? <String, CountryService>{} : <String, CountryService>{firstEntry.key: firstEntry.value},
        ));
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
      print('HomeScreen: Loaded ${rentals.length} total rentals from Supabase');
      
      final nowUtc = DateTime.now().toUtc();
      // Clean up expired linger windows
      _lingerUntil.removeWhere((_, until) => until.isBefore(DateTime.now()));
      for (final rental in rentals) {
        final expiresUtc = rental.expiresAt.toUtc();
        final expiredFlag = expiresUtc.isBefore(nowUtc);
        final status = rental.status.toLowerCase();
        print('HomeScreen: Rental ${rental.id} - Status: ${rental.status}, Active: ${status == 'active'}, ExpiredByTime(UTC): $expiredFlag, ExpiresAt(UTC): $expiresUtc');
      }

      // My Numbers: show
      // - Active and not expired by time
      // - Completed AND within linger window (show code for 60s)
      final active = rentals.where((r) {
        final status = r.status.toLowerCase();
        final expiresUtc = r.expiresAt.toUtc();
        final expiredByTime = expiresUtc.isBefore(nowUtc);
        final isActive = status == 'active' && !expiredByTime;
        final isCompletedAndLingering = status == 'completed' &&
            _lingerUntil[r.id] != null &&
            _lingerUntil[r.id]!.isAfter(DateTime.now());
        return isActive || isCompletedAndLingering;
      }).toList();

      // History: only successful (completed) and NOT currently lingering.
      // Cancelled or timeout (active but expired) must NOT appear in history per spec.
      final history = rentals.where((r) {
        final status = r.status.toLowerCase();
        final isCompleted = status == 'completed';
        final isLingering = _lingerUntil[r.id] != null &&
            _lingerUntil[r.id]!.isAfter(DateTime.now());
        return isCompleted && !isLingering;
      }).toList();

      print('HomeScreen: Found ${active.length} active rentals; ${history.length} history rentals');

      if (mounted) {
        setState(() {
          _activeRentals = active;
          _historyRentals = history;
        });
      }
    } catch (e) {
      print('HomeScreen: Error loading rentals: $e');
      debugPrint('Error loading rentals: $e');
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
                    color: const Color(0xFF00BCD4).withOpacity(0.3),
                    blurRadius: 12,
                    spreadRadius: 1,
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
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Add funds',
            icon: const Icon(Icons.add_card_rounded, color: Colors.white),
            onPressed: () async {
              // Prompt for any amount in USD
              final controller = TextEditingController(text: '5.00');
              final amount = await showDialog<double?>(
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
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enter a valid amount'), backgroundColor: Colors.orange),
                );
                return;
              }

              try {
                final opened = await BillingService().openExternalCheckout(amountCents: cents);
                if (!mounted) return;
                if (opened) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Opening secure Checkout...'), backgroundColor: Colors.blue),
                  );
                }
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
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
            onSelected: (value) async {
              switch (value) {
                case 'history':
                  _tabController.animateTo(2);
                  break;
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
            itemBuilder: (BuildContext context) => const [
              PopupMenuItem(
                value: 'history',
                child: ListTile(
                  leading: Icon(Icons.history),
                  title: Text('History'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'profile',
                child: ListTile(
                  leading: Icon(Icons.person),
                  title: Text('Profile'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'refresh',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('Refresh'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  leading: Icon(Icons.logout),
                  title: Text('Sign Out'),
                  contentPadding: EdgeInsets.zero,
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
                      return _CompactServiceTile(
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

  // Old complex card replaced by compact dark tile list
  Widget _buildEnhancedServiceCard(ServiceData service) {
    final minPrice = service.availableCountries.isNotEmpty
        ? service.availableCountries.map((c) => c.burnaPrice).reduce((a, b) => a < b ? a : b)
        : 0.0;
    return _CompactServiceTile(
      name: service.name,
      priceText: '\$${minPrice.toStringAsFixed(2)}',
      iconData: _getServiceIcon(service.name),
      onTap: () => _showCountrySelection(service),
    );
  }

  Widget _buildActiveRentalsTab() {
    return RefreshIndicator(
      onRefresh: _loadActiveRentals,
      child: _activeRentals.isEmpty
          ? _buildEmptyState(
              icon: Icons.phone_disabled,
              title: 'No Active Rentals',
              subtitle: 'Purchase a phone number to get started and manage your SMS receiving',
              actionText: 'Browse Services',
              onAction: () => _tabController.animateTo(0),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _activeRentals.length,
              itemBuilder: (context, index) {
                final rental = _activeRentals[index];
                return _buildEnhancedRentalCard(rental);
              },
            ),
    );
  }

  Widget _buildEnhancedRentalCard(Rental rental) {
    // Use UTC now for consistency with DB-stored Z timestamps
    final nowUtc = DateTime.now().toUtc();
    final expiresUtc = rental.expiresAt.toUtc();
    final isExpired = expiresUtc.isBefore(nowUtc);
    final timeRemaining = expiresUtc.difference(nowUtc);
    final statusColor = _getStatusColor(rental.status);
    final hasReceivedSms = rental.smsReceived != null && rental.smsReceived!.isNotEmpty;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white,
            hasReceivedSms ? Colors.green.shade50 : Colors.grey.shade50,
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: statusColor,
                width: 4,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header with status and timer
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            statusColor.withOpacity(0.1),
                            statusColor.withOpacity(0.2),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: statusColor.withOpacity(0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: statusColor,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            rental.status.toUpperCase(),
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    if (!isExpired)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: timeRemaining.inMinutes < 10
                            ? Colors.red.shade100
                            : Colors.orange.shade100,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: timeRemaining.inMinutes < 10
                              ? Colors.red.shade300
                              : Colors.orange.shade300,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.timer,
                              size: 14,
                              color: timeRemaining.inMinutes < 10 ? Colors.red : Colors.orange,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${timeRemaining.inMinutes}m left',
                              style: TextStyle(
                                color: timeRemaining.inMinutes < 10 ? Colors.red : Colors.orange,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                
                const SizedBox(height: 20),
                
                // Phone Number Section
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.blue.shade50, Colors.blue.shade100],
                    ),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.blue.shade400, Colors.blue.shade600],
                          ),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: const Icon(
                          Icons.phone,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Phone Number',
                              style: TextStyle(
                                color: Colors.blue.shade600,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              rental.phoneNumber,
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade800,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.blue.withOpacity(0.2),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: IconButton(
                          onPressed: () => _copyToClipboard(rental.phoneNumber),
                          icon: Icon(Icons.copy, color: Colors.blue.shade600),
                          tooltip: 'Copy number',
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 16),
                
                // Service Info
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.purple.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.purple.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _getServiceIcon(rental.serviceName),
                                  size: 16,
                                  color: Colors.purple.shade600,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Service',
                                  style: TextStyle(
                                    color: Colors.purple.shade600,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              rental.serviceName,
                              style: TextStyle(
                                color: Colors.purple.shade800,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.location_on,
                                  size: 16,
                                  color: Colors.orange.shade600,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Country',
                                  style: TextStyle(
                                    color: Colors.orange.shade600,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              rental.countryName,
                              style: TextStyle(
                                color: Colors.orange.shade800,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                
                // SMS Received Section
                if (hasReceivedSms) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.green.shade100, Colors.green.shade200],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.shade300),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.green.shade400, Colors.green.shade600],
                            ),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: const Icon(
                            Icons.sms,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'SMS Received ✓',
                                style: TextStyle(
                                  color: Colors.green.shade600,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                rental.smsReceived!,
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green.shade800,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.green.withOpacity(0.2),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: IconButton(
                            onPressed: () => _copyToClipboard(rental.smsReceived!),
                            icon: Icon(Icons.copy, color: Colors.green.shade600),
                            tooltip: 'Copy code',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                
                const SizedBox(height: 20),
                
                // Action Buttons
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: rental.status == 'active'
                          ? () => _checkSMS(rental)
                          : null,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          side: BorderSide(
                            color: rental.status == 'active' ? Colors.blue.shade600 : Colors.grey,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.refresh,
                              size: 18,
                              color: rental.status == 'active' ? Colors.blue.shade600 : Colors.grey,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Check SMS',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: rental.status == 'active' ? Colors.blue.shade600 : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: rental.status == 'active'
                          ? () => _cancelRental(rental)
                          : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: rental.status == 'active' ? Colors.red.shade600 : Colors.grey,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          elevation: rental.status == 'active' ? 4 : 0,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.cancel, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              'Cancel',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryTab() {
    return RefreshIndicator(
      onRefresh: _loadActiveRentals,
      child: _historyRentals.isEmpty
          ? _buildEmptyState(
              icon: Icons.history,
              title: 'No History Yet',
              subtitle: 'Your completed and cancelled rentals will appear here',
              actionText: 'Browse Services',
              onAction: () => _tabController.animateTo(0),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _historyRentals.length,
              itemBuilder: (context, index) {
                final rental = _historyRentals[index];
                return _buildHistoryRentalCard(rental);
              },
            ),
    );
  }

  Widget _buildHistoryRentalCard(Rental rental) {
    // If an item is time-expired but status is still 'active', present it as CANCELLED to avoid confusing "ACTIVE in history"
    final nowUtc = DateTime.now().toUtc();
    final isExpiredByTime = rental.expiresAt.toUtc().isBefore(nowUtc);
    final effectiveStatus = (rental.status.toLowerCase() == 'active' && isExpiredByTime) ? 'cancelled' : rental.status;
    final statusColor = _getStatusColor(effectiveStatus);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: statusColor, width: 4)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        leading: CircleAvatar(
          backgroundColor: statusColor.withOpacity(0.15),
          child: Icon(Icons.history, color: statusColor),
        ),
        title: Text(
          rental.phoneNumber,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text('${rental.serviceName} • ${rental.countryName}'),
            const SizedBox(height: 2),
            Text(
              'Status: ${effectiveStatus.toUpperCase()}',
              style: TextStyle(color: statusColor, fontWeight: FontWeight.w600),
            ),
            if (rental.smsReceived != null && rental.smsReceived!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('SMS: ${rental.smsReceived!}'),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Expires: ${rental.expiresAt.toLocal()}',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.copy),
          onPressed: () => _copyToClipboard(rental.phoneNumber),
          tooltip: 'Copy number',
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
    
    // Map service names to appropriate icons
    if (name.contains('whatsapp')) return Icons.chat;
    if (name.contains('telegram')) return Icons.send;
    if (name.contains('discord')) return Icons.discord;
    if (name.contains('instagram')) return Icons.camera_alt;
    if (name.contains('facebook')) return Icons.facebook;
    if (name.contains('twitter') || name.contains('x.com')) return Icons.alternate_email;
    if (name.contains('google')) return Icons.search;
    if (name.contains('amazon')) return Icons.shopping_bag;
    if (name.contains('uber')) return Icons.local_taxi;
    if (name.contains('airbnb')) return Icons.home;
    if (name.contains('netflix')) return Icons.movie;
    if (name.contains('spotify')) return Icons.music_note;
    if (name.contains('paypal')) return Icons.payment;
    if (name.contains('microsoft')) return Icons.computer;
    if (name.contains('apple')) return Icons.phone_iphone;
    if (name.contains('tinder')) return Icons.favorite;
    if (name.contains('linkedin')) return Icons.work;
    if (name.contains('github')) return Icons.code;
    if (name.contains('dropbox')) return Icons.cloud;
    if (name.contains('steam')) return Icons.games;
    
    // Default icons based on common patterns
    if (name.contains('bank') || name.contains('finance')) return Icons.account_balance;
    if (name.contains('shop') || name.contains('store')) return Icons.store;
    if (name.contains('food') || name.contains('delivery')) return Icons.restaurant;
    if (name.contains('ride') || name.contains('taxi')) return Icons.directions_car;
    if (name.contains('hotel') || name.contains('travel')) return Icons.hotel;
    if (name.contains('game')) return Icons.sports_esports;
    if (name.contains('crypto') || name.contains('bitcoin')) return Icons.currency_bitcoin;
    
    // Fallback to service/communication icon
    return Icons.business;
  }

  // Country selection removed for US-only app. Kept for backward compatibility; not shown.
  void _showCountrySelection(ServiceData service) {
    // No-op: always rent with US upstream.
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

  Future<void> _checkSMS(Rental rental) async {
    try {
      final updatedRental = await _daisyService.checkSms(rental.id);
      
      if (updatedRental.smsReceived != null && updatedRental.smsReceived!.isNotEmpty) {
        // Linger successful code in My Numbers for 60s (no extra DB writes here)
        _lingerUntil[updatedRental.id] = DateTime.now().add(const Duration(seconds: 60));
        await _loadActiveRentals();
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('SMS received: ${updatedRental.smsReceived}'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        // no code yet: do nothing special
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No SMS received yet'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error checking SMS: $e'),
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
        title: const Text('Profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.email),
              title: Text(user?.email ?? 'No email'),
              contentPadding: EdgeInsets.zero,
            ),
            ListTile(
              leading: const Icon(Icons.attach_money),
              title: Text('Total Spent: \$${user?.totalSpent.toStringAsFixed(2) ?? '0.00'}'),
              contentPadding: EdgeInsets.zero,
            ),
            ListTile(
              leading: const Icon(Icons.phone),
              title: Text('Total Rentals: ${user?.totalRentals ?? 0}'),
              contentPadding: EdgeInsets.zero,
            ),
            ListTile(
              leading: const Icon(Icons.calendar_today),
              title: Text('Member since ${user?.createdAt.toLocal().toString().split(' ')[0] ?? 'Unknown'}'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
// Compact dark tile widget with US badge
class _CompactServiceTile extends StatelessWidget {
  final String name;
  final String priceText;
  final IconData iconData;
  final VoidCallback onTap;
  const _CompactServiceTile({
    super.key,
    required this.name,
    required this.priceText,
    required this.iconData,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF111827),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(iconData, color: Colors.white70, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        priceText,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111827),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0x1AFFFFFF)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('🇺🇸', style: TextStyle(fontSize: 14)),
                      SizedBox(width: 4),
                      Text('US', style: TextStyle(fontSize: 12, color: Colors.white70)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right, color: Colors.white54),
              ],
            ),
          ),
        ),
      ),
    );
  }
}