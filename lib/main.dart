import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'core/animations/motion.dart';
import 'core/config/app_config.dart';
import 'core/network/api_client.dart';
import 'core/network/connectivity_service.dart';
import 'core/network/token_store.dart';
import 'features/auth/data/api_auth_repository.dart';
import 'features/admin/data/api_admin_contact_repository.dart';
import 'features/admin/data/api_admin_menu_repository.dart';
import 'features/admin/data/api_admin_order_repository.dart';
import 'features/admin/data/api_admin_user_repository.dart';
import 'features/admin/data/api_dashboard_repository.dart';
import 'features/admin/domain/dashboard_repository.dart';
import 'features/admin/domain/admin_contact_repository.dart';
import 'features/admin/domain/admin_order_repository.dart';
import 'features/admin/domain/admin_menu_repository.dart';
import 'features/admin/domain/admin_user_repository.dart';
import 'features/booking/data/api_reservation_repository.dart';
import 'features/booking/data/api_venue_repository.dart';
import 'features/booking/domain/reservation_repository.dart';
import 'firebase_options.dart';
import 'features/notifications/data/api_notification_repository.dart';
import 'features/notifications/data/firebase_push_service.dart';
import 'features/notifications/data/push_coordinator.dart';
import 'features/notifications/domain/notification_repository.dart';
import 'features/notifications/domain/push_service.dart';
import 'features/notifications/presentation/notifications_cubit.dart';
import 'features/hours/data/api_working_hours_repository.dart';
import 'features/hours/domain/working_hours_repository.dart';
import 'features/contact/data/api_contact_repository.dart';
import 'features/contact/domain/contact_repository.dart';
import 'features/menu/data/api_menu_repository.dart';
import 'features/menu/domain/menu_repository.dart';
import 'features/orders/data/api_order_repository.dart';
import 'features/orders/data/demo_order_repository.dart';
import 'features/orders/domain/order_repository.dart';
import 'core/animations/page_transitions.dart';
import 'core/theme/app_spacing.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/auth_cubit.dart';
import 'features/auth/login_screen.dart';
import 'features/cart/cart_cubit.dart';
import 'features/delivery/data/api_admin_delivery_zone_repository.dart';
import 'features/delivery/data/api_delivery_zone_repository.dart';
import 'features/delivery/domain/delivery_zone_repository.dart';
import 'features/shell/admin_shell.dart';
import 'features/shell/customer_shell.dart';
import 'features/welcome/presentation/welcome_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Reads `.env` before anything can ask for a URL. Deliberately awaited: a
  // half-configured client is harder to diagnose than a clear startup failure.
  await AppConfig.load();

  // Composed here rather than behind a service locator: the graph is four
  // objects deep, and one readable wiring site beats indirection that hides
  // which implementation is in play.
  final tokens = TokenStore();
  await tokens.restore();

  final client = ApiClient(tokens: tokens, connectivity: ConnectivityService());
  final auth = AuthCubit(
    repository: ApiAuthRepository(client: client, tokens: tokens),
  );

  // Notifications. The inbox works with or without push; push is what makes the
  // phone light up.
  final notifications = ApiNotificationRepository(client: client);

  // Firebase is only configured for Android so far — iOS still needs its plist
  // and an APNs key. Startup must survive that rather than refusing to run, so a
  // platform with no configuration falls back to the no-op service and the app
  // works minus the OS alerts.
  PushService push = const NoPushService();
  FirebasePushService? firebase;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // Registered before `runApp`, and top-level — see the handler's own note.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    firebase = FirebasePushService();
    await firebase.initialise();
    push = firebase;
  } on Object catch (error) {
    debugPrint('Push is unavailable on this platform: $error');
  }

  final pushes = PushCoordinator(repository: notifications, push: push);
  await pushes.start();

  // One inbox cubit for the whole app. The bell and the inbox screen used to
  // build one each, so marking everything read left the badge showing the old
  // count until the bell happened to be rebuilt.
  final inbox = NotificationsCubit(repository: notifications);

  // App-level too, and hoisted here for the same reason the inbox was: it has
  // to be emptied on sign-out. A basket left in memory belongs to whoever
  // filled it, and the next person to sign in on this phone would otherwise
  // find somebody else's dinner in their cart -- and their address on the
  // checkout screen after it.
  final cart = CartCubit();

  // A push that arrives while the app is open moves the badge without the user
  // opening anything.
  pushes.received.listen((_) => inbox.refreshBadge());

  // A notification that launched a terminated app. Held rather than acted on:
  // there is no session and no navigator yet, and the coordinator hands it over
  // once there is.
  final launch = await firebase?.initialMessage();
  if (launch != null) pushes.holdPending(launch);

  // Registration runs after a session exists, and never blocks anything: a
  // failed registration is retried next launch rather than kept anyone out.
  // The badge is read at the same moment, because until there is a session
  // there is nothing to count.
  auth.onSignedIn = () async {
    inbox.refreshBadge();
    await pushes.register();
  };

  // The device association is removed **before** the logout request, while the
  // access token still works. Skip that and the next person to sign in on this
  // phone receives the previous user's alerts — and the inbox is emptied for
  // the same reason.
  auth.onSigningOut = () async {
    inbox.clear();
    cart.clear();
    await pushes.unregister();
  };

  // Closes the loop: when a refresh finally fails, the app returns to sign-in
  // instead of leaving the user on a screen that will never load again.
  client.onSessionExpired = auth.signOut;

  // Not awaited — the app opens on the splash and swaps to the right shell when
  // the answer arrives, rather than holding a blank screen on a slow network.
  auth.restore();

  runApp(
    TsCafeApp(
      auth: auth,
      menu: ApiMenuRepository(client: client),
      // Demo orders are opt-in through `.env` and off by default — see
      // [AppConfig.useDemoOrders]. Chosen here rather than inside the
      // repository so nothing downstream can serve invented orders.
      adminMenu: ApiAdminMenuRepository(client: client),
      contact: ApiContactRepository(client: client),
      adminContact: ApiAdminContactRepository(client: client),
      adminOrders: ApiAdminOrderRepository(client: client),
      adminUsers: ApiAdminUserRepository(client: client),
      dashboard: ApiDashboardRepository(client: client),
      reservations: ApiReservationRepository(client: client),
      venue: ApiVenueRepository(client: client),
      notifications: notifications,
      inbox: inbox,
      cart: cart,
      workingHours: ApiWorkingHoursRepository(client: client),
      orders: AppConfig.useDemoOrders
          ? DemoOrderRepository()
          : ApiOrderRepository(client: client),
      // Delivery pricing is zone-based and lives entirely on the server: the
      // admin redraws areas and changes fees without an app release.
      deliveryZones: ApiDeliveryZoneRepository(client: client),
      adminDeliveryZones: ApiAdminDeliveryZoneRepository(client: client),
    ),
  );
}

class TsCafeApp extends StatelessWidget {
  const TsCafeApp({
    super.key,
    required this.auth,
    required this.cart,
    required this.menu,
    required this.adminMenu,
    required this.contact,
    required this.adminContact,
    required this.adminOrders,
    required this.adminUsers,
    required this.dashboard,
    required this.reservations,
    required this.venue,
    required this.notifications,
    required this.inbox,
    required this.workingHours,
    required this.orders,
    required this.deliveryZones,
    required this.adminDeliveryZones,
  });

  /// Built in `main` so it can be handed the repository and wired to the
  /// client's session-expiry callback before the first frame.
  final AuthCubit auth;

  /// Provided rather than constructed per screen, so every screen that reads
  /// the menu shares one client and one set of interceptors.
  final MenuRepository menu;

  /// Managing the menu, as opposed to reading it. Provided app-wide rather than
  /// only inside the admin shell so the shell stays a plain widget — the role
  /// check in [AppRoot] is what keeps it out of a customer's reach.
  final AdminMenuRepository adminMenu;

  /// The Contact Us form. Needs no session — somebody who cannot sign in is
  /// exactly who most needs to reach the restaurant.
  final ContactRepository contact;

  /// The inbox those messages land in.
  final AdminContactRepository adminContact;

  /// The kitchen queue. Staff and admin share it — the API gives both roles the
  /// same order permissions.
  final AdminOrderRepository adminOrders;

  /// Accounts. Admin-only at the API, and reached only from the admin profile —
  /// but provided app-wide for the same reason as [adminMenu].
  final AdminUserRepository adminUsers;

  /// The admin landing screen's figures. Admin only at the API.
  final DashboardRepository dashboard;

  /// Table bookings. One repository for both sides — the customer routes and
  /// the staff sheet share their models, and the backend decides from the token
  /// which of them a caller may actually use.
  final ReservationRepository reservations;

  /// The room and the sitting timetable. Admin only at the API — staff work
  /// reservations but do not change the schedule.
  final VenueRepository venue;

  /// The notification inbox and this installation's push registration.
  final NotificationRepository notifications;

  /// The notification inbox and badge, shared by the bell and the inbox screen.
  final NotificationsCubit inbox;

  /// Held by the app rather than created in `build`, so sign-out can empty it.
  final CartCubit cart;

  /// Opening hours. The read is public — somebody deciding whether to walk over
  /// does not have an account — and only an admin may edit the week.
  final WorkingHoursRepository workingHours;

  /// The signed-in customer's orders. Scoped to the bearer token, so it needs
  /// nothing from the session beyond the client it already shares.
  final OrderRepository orders;
  final DeliveryZoneRepository deliveryZones;
  final AdminDeliveryZoneRepository adminDeliveryZones;

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<MenuRepository>.value(value: menu),
        RepositoryProvider<AdminMenuRepository>.value(value: adminMenu),
        RepositoryProvider<ContactRepository>.value(value: contact),
        RepositoryProvider<AdminContactRepository>.value(value: adminContact),
        RepositoryProvider<AdminOrderRepository>.value(value: adminOrders),
        RepositoryProvider<AdminUserRepository>.value(value: adminUsers),
        RepositoryProvider<DashboardRepository>.value(value: dashboard),
        RepositoryProvider<ReservationRepository>.value(value: reservations),
        RepositoryProvider<VenueRepository>.value(value: venue),
        RepositoryProvider<NotificationRepository>.value(value: notifications),
        RepositoryProvider<WorkingHoursRepository>.value(value: workingHours),
        RepositoryProvider<OrderRepository>.value(value: orders),
        RepositoryProvider<DeliveryZoneRepository>.value(value: deliveryZones),
        RepositoryProvider<AdminDeliveryZoneRepository>.value(
          value: adminDeliveryZones,
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider.value(value: auth),
          BlocProvider.value(value: cart),
          BlocProvider.value(value: inbox),
        ],
        child: ScreenUtilInit(
          designSize: const Size(AppLayout.designWidth, AppLayout.designHeight),
          minTextAdapt: true,
          builder: (context, _) {
            return MaterialApp(
              title: "T's Café",
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: ThemeMode.system,
              home: const AppRoot(),
            );
          },
        ),
      ),
    );
  }
}

/// Decides which side of the app is on screen.
///
/// Three states, in order: the splash while startup settles, then either a
/// shell or sign-in. Because the shell is the whole subtree here, signing out
/// tears it down and signing back in mounts a fresh one — tab state never leaks
/// between sessions or roles.
class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return const SplashGate();
  }
}

/// Holds the splash for [minimumDuration], then hands over.
///
/// Two things have to finish before the app can commit to a screen: the stored
/// session has to be checked, and the splash has to have been visible long
/// enough to read. Whichever takes longer wins.
///
/// The minimum matters more than it looks. Session restore off a warm keychain
/// takes a few milliseconds, so without a floor the splash would flash for one
/// frame — worse than not having one. The maximum matters too: a slow network
/// must not hold the app on a branding screen indefinitely, so once the delay is
/// up and restore is still running, the user goes to sign-in and the shell
/// swaps in behind them if the session turns out to be good.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  /// Long enough to read the logo and the line under it, short enough not to
  /// feel like a loading screen.
  static const Duration minimumDuration = Duration(seconds: 2);

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  Timer? _timer;
  bool _elapsed = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(SplashGate.minimumDuration, () {
      if (mounted) setState(() => _elapsed = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthCubit, AuthState>(
      buildWhen: (a, b) => a.role != b.role || a.hasRestored != b.hasRestored,
      builder: (context, state) {
        // `hasRestored` rather than `isRestoring`: a device with no stored
        // session never issues the request, so waiting on the request itself
        // would hand over before the answer was known.
        final waiting = !_elapsed || !state.hasRestored;

        final child = switch (waiting ? null : state.role) {
          UserRole.customer => const SessionWatcher(child: CustomerShell()),
          // Staff share the admin shell. What they may do inside it is narrower
          // — see `UserRole.canManageVenue` — but the shape of their app is the
          // staff-facing one, not the customer's.
          UserRole.staff ||
          UserRole.admin => const SessionWatcher(child: AdminShell()),
          null => waiting ? const WelcomeScreen() : const _SignedOutFlow(),
        };

        return AnimatedSwitcher(
          duration: context.motion.fade(Motion.base),
          child: KeyedSubtree(
            // Keyed on what is showing, not on the role alone: splash and
            // sign-in are both role-null, and without this the cross-fade
            // between them would not happen.
            key: ValueKey(waiting ? 'splash' : state.role),
            child: child,
          ),
        );
      },
    );
  }
}

/// Re-reads `/auth/me` while a shell is on screen.
///
/// Roles and access change on the server, from a different device: an admin
/// promotes somebody to staff, or deactivates an account. Nothing told this app
/// about it. `ProfileScreen` has pull-to-refresh, so the change appeared there
/// and nowhere else — the promoted user kept the customer tab bar until they
/// happened to visit Profile and pull, and a deactivated user kept browsing
/// until some unrelated screen's request failed and signed them out mid-tap.
///
/// So the session is re-read when the app comes back to the foreground, which is
/// where a change made elsewhere is most likely to have happened, and once when a
/// shell mounts. [AuthCubit.refreshUser] does the rest: adopting a new role makes
/// [SplashGate] swap shells, and a refusal ends the session cleanly.
///
/// Deliberately not a poll. A timer would mean a request every N seconds for a
/// change that happens a few times a year, and the app already discovers a dead
/// session the moment any request 401s.
class SessionWatcher extends StatefulWidget {
  const SessionWatcher({super.key, required this.child});

  final Widget child;

  @override
  State<SessionWatcher> createState() => _SessionWatcherState();
}

class _SessionWatcherState extends State<SessionWatcher> {
  AppLifecycleListener? _listener;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onResume: _revalidate);
    // Once on mount: the shell has just been built from a restored session, and
    // the role in it may already be stale.
    WidgetsBinding.instance.addPostFrameCallback((_) => _revalidate());
  }

  void _revalidate() {
    if (!mounted) return;
    final auth = context.read<AuthCubit>();
    if (!auth.state.isSignedIn) return;
    auth.refreshUser();
  }

  @override
  void dispose() {
    _listener?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Sign-in on its own navigator, so Register can be pushed and popped without
/// involving either shell.
///
/// Sign-in is the root here rather than a screen pushed over Welcome: the
/// splash is not somewhere to go back to, and leaving it on the stack put a
/// back arrow on sign-in that led nowhere useful.
class _SignedOutFlow extends StatelessWidget {
  const _SignedOutFlow();

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (settings) => AppPageRoute<void>(
        settings: settings,
        builder: (context) => const LoginScreen(),
      ),
    );
  }
}
