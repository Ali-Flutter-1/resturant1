import '../config/app_config.dart';

/// Every endpoint the Restaurant API exposes, in one place.
///
/// ## Relative, not absolute
///
/// These are paths **relative to `/api/v1`**, because [ApiClient] already sets
/// its Dio `baseUrl` to `'${AppConfig.apiBaseUrl}/api/v1'`. Returning absolute
/// URLs here would produce `…/api/v1/api/v1/dishes` and 404 on every call. Use
/// [absolute] if you ever need a full URL — for a log line, a share link, or a
/// request that bypasses the client.
///
/// [health] is the exception and is deliberately absolute: it lives at the
/// server root, outside the versioned prefix.
///
/// ## Why a constants file at all
///
/// Paths were previously inline in each repository, which is fine until two
/// repositories disagree about one. A single list means a rename is one edit,
/// and it doubles as a map of the backend's surface — including the parts the
/// app does not call yet, so the gap is visible rather than guessed at.
///
/// Only `/auth/*`, `/profile/change-password`, `/categories` and `/dishes*` are
/// wired today. Everything else below is declared and unused; see the repository
/// classes for what is actually reachable.
abstract final class ApiConstants {
  // ---------------------------------------------------------------- plumbing

  /// Host only, from `.env`. No version prefix.
  static String get baseUrl => AppConfig.apiBaseUrl;

  /// The versioned root every path below hangs off.
  static String get apiRoot => '$baseUrl/api/v1';

  /// Turns one of the relative paths below into a full URL.
  static String absolute(String path) => '$apiRoot$path';

  /// Liveness check. Absolute, because it is *not* under `/api/v1`.
  static String get health => '$baseUrl/health';

  // ------------------------------------------------------------------- auth

  static const String register = '/auth/register';
  static const String login = '/auth/login';
  static const String me = '/auth/me';

  /// Single-use. The API rotates it and revokes every session if one is
  /// replayed, which is why refresh is serialised inside [ApiClient].
  static const String refresh = '/auth/refresh';
  static const String logout = '/auth/logout';

  /// Step 1 of the reset: emails a six-digit code. Always answers 200 with the
  /// same message whether or not the address is registered, so the app cannot be
  /// used to discover who has an account.
  static const String forgotPassword = '/auth/forgot-password';

  /// Step 2: exchanges `{email, code}` for a short-lived `reset_token`.
  static const String verifyResetCode = '/auth/verify-reset-code';

  /// Step 3: `{token, new_password}` — the reset token from step 2, never the
  /// six-digit code.
  static const String resetPassword = '/auth/reset-password';

  /// Needs a Google ID token from `google_sign_in`, and a configured
  /// `GOOGLE_CLIENT_ID`.
  static const String google = '/auth/google';

  // ---------------------------------------------------------------- profile

  /// GET is not offered — read the signed-in user through [me].
  /// PATCH updates, DELETE closes the account.
  static const String profile = '/profile';
  static const String changePassword = '/profile/change-password';

  // ------------------------------------------------------- categories (read)

  static const String categories = '/categories';
  static String categoryBySlug(String slug) => '/categories/$slug';

  // ------------------------------------------------------ categories (admin)

  static const String adminCategories = '/admin/categories';
  static String adminCategory(String id) => '/admin/categories/$id';
  static String adminCategoryRestore(String id) =>
      '/admin/categories/$id/restore';

  // ----------------------------------------------------------- dishes (read)

  /// Optional `?category=<slug>`. Sold-out dishes are included with
  /// `is_available: false` rather than omitted.
  static const String dishes = '/dishes';

  /// By id. The API used to address dishes by slug and no longer does.
  static String dish(String id) => '/dishes/$id';

  // ---------------------------------------------------------- dishes (admin)

  static const String adminDishes = '/admin/dishes';

  /// Multipart, up to six files. Returns a `public_id` and `url` per file, which
  /// go straight back as a dish's `images`.
  static const String adminImageUploads = '/admin/uploads/images';
  static String adminDish(String id) => '/admin/dishes/$id';
  static String adminDishRestore(String id) => '/admin/dishes/$id/restore';

  /// The whole configurable structure for one dish — variants, option groups
  /// and the rules between them. PUT **replaces** it atomically; there is no
  /// patch, so a caller must send the complete desired state.
  static String adminDishConfiguration(String id) =>
      '/admin/dishes/$id/configuration';

  /// POST appends uploaded files; PATCH reorders by sending every `public_id`
  /// in the wanted order. The first image is the thumbnail.
  static String adminDishImages(String dishId) =>
      '/admin/dishes/$dishId/images';

  /// DELETE detaches the picture *and* removes the file from Cloudinary. The
  /// `public_id` contains slashes and is sent as part of the path.
  static String adminDishImage(String dishId, String publicId) =>
      '/admin/dishes/$dishId/images/$publicId';

  // ---------------------------------------------------------------- uploads

  /// Generic upload, not attached to a dish. Multipart, key `files`.
  static const String adminUploadImages = '/admin/uploads/images';

  // ---------------------------------------------------------------- contact

  static const String contact = '/contact';
  static const String adminContact = '/admin/contact';
  static String adminContactMessage(String id) => '/admin/contact/$id';

  // ------------------------------------------------------------ admin users

  static const String adminUsers = '/admin/users';

  /// Declared before [adminUser] on purpose: `stats` is a sibling of the id
  /// route, not a user called "stats".
  static const String adminUserStats = '/admin/users/stats';
  static String adminUser(String id) => '/admin/users/$id';

  // ------------------------------------------------------------- delivery

  /// Every active zone, for the map and its legend. Public.
  static const String deliveryZones = '/delivery-zones';

  /// Which zone a postcode falls in. Public, and answers "nowhere" with a 200 —
  /// an address outside the area is a fact, not an error.
  static const String deliveryZoneCheck = '/delivery-zones/check';

  static const String adminDeliveryZones = '/admin/delivery-zones';
  static String adminDeliveryZone(String id) => '/admin/delivery-zones/$id';

  // ------------------------------------------------------- orders (customer)

  /// Prices the basket without creating anything. Call before [orders] so the
  /// app shows the server's total rather than its own arithmetic.
  static const String orderQuote = '/orders/quote';

  /// POST places an order — send [idempotencyKeyHeader]. GET lists the
  /// signed-in customer's orders.
  static const String orders = '/orders';
  static String order(String id) => '/orders/$id';

  /// Only while the order is still `placed`.
  static String orderCancel(String id) => '/orders/$id/cancel';

  /// Asks for a Worldpay page for an unpaid card order.
  ///
  /// Safe to call twice: an unpaid order returns its existing page rather than
  /// a second one, so a customer cannot be charged twice by tapping "Pay" in a
  /// hurry. A *failed* order gets a brand new page with a new reference, which
  /// it must -- Worldpay treats a repeated reference as the same payment, so a
  /// retry on the old URL would go nowhere.
  static String orderPay(String id) => '/orders/$id/pay';

  // ---------------------------------------------------------- orders (admin)

  /// `?open_only=true` is the kitchen queue.
  static const String adminOrders = '/admin/orders';
  static const String adminOrderStats = '/admin/orders/stats';
  static String adminOrder(String id) => '/admin/orders/$id';
  static String adminOrderStatus(String id) => '/admin/orders/$id/status';

  /// The admin landing screen. One request powers the whole thing — no
  /// pagination, no polling.
  static const String adminDashboard = '/admin/dashboard';

  // ----------------------------------------------------------- working hours

  /// Public. Somebody deciding whether to walk over does not have an account.
  static const String workingHours = '/working-hours';

  /// Admin only — staff cannot edit the week.
  static const String adminWorkingHours = '/admin/working-hours';
  static String adminWorkingHoursDay(int weekday) =>
      '/admin/working-hours/$weekday';

  /// A category's logo. Admin only, multipart on the way up.
  static String adminCategoryLogo(String categoryId) =>
      '/admin/categories/$categoryId/logo';

  // ------------------------------------------------------------ notifications

  /// Registering this installation for push. The response never echoes the FCM
  /// token back, and neither should anything here.
  static const String notificationDevices = '/notifications/devices';
  static String notificationDevice(String installationId) =>
      '/notifications/devices/$installationId';

  /// The durable in-app inbox — the reliable record when a push is delayed,
  /// dismissed or never delivered.
  static const String notifications = '/notifications';
  static const String notificationsUnreadCount = '/notifications/unread-count';
  static String notificationRead(String id) => '/notifications/$id/read';
  static const String notificationsReadAll = '/notifications/read-all';

  // ------------------------------------------------- reservations (customer)

  /// `?date=YYYY-MM-DD&guests=N`. Returns unavailable sittings too, each with
  /// an `unavailable_reason` — the API is explicit that they should be greyed
  /// out rather than hidden.
  static const String reservationAvailability = '/reservations/availability';

  static const String reservations = '/reservations';
  static String reservation(String id) => '/reservations/$id';
  static String reservationCancel(String id) => '/reservations/$id/cancel';

  // ---------------------------------------------------- reservations (admin)

  /// The floor plan. Admin only — working the bookings is staff work, but
  /// managing tables is not.
  static const String adminTables = '/admin/tables';
  static String adminTable(String id) => '/admin/tables/$id';
  static String adminTableRestore(String id) => '/admin/tables/$id/restore';

  /// Sittings. `turn_minutes` is both the length of a sitting and the gap
  /// between starts, so generated sittings never overlap.
  static const String adminTableSlots = '/admin/table-slots';
  static const String adminTableSlotsGenerate = '/admin/table-slots/generate';
  static String adminTableSlot(String id) => '/admin/table-slots/$id';

  /// The booking sheet. Admin and staff.
  static const String adminReservations = '/admin/reservations';
  static const String adminReservationStats = '/admin/reservations/stats';
  static String adminReservation(String id) => '/admin/reservations/$id';
  static String adminReservationStatus(String id) =>
      '/admin/reservations/$id/status';

  // ---------------------------------------------------------------- headers

  static const String contentTypeJson = 'application/json';
  static const String acceptHeader = 'application/json';

  /// Send a fresh UUID per checkout. A double-tap then returns the first order
  /// instead of creating a second one.
  static const String idempotencyKeyHeader = 'Idempotency-Key';
}
