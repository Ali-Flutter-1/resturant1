# T's Café — project context and handover

Written 24 August 2026. Describes the state of the app at commit `845e84d`,
what was built and why, and what is still outstanding.

---

## 1. What this is

A Flutter app for one restaurant, with two faces:

- **Customer** — browse the menu, order for collection or delivery, pay by cash
  or card, track the order, book a table, read past receipts.
- **Admin and staff** — work the live order queue, manage bookings and tables,
  edit the menu, set opening hours, manage accounts, and (admin only) see
  takings.

It talks to a FastAPI backend at
`https://t-cafe-mobile-app-backend-fastapi-afbba65d.fastapicloud.dev`.

### Stack

| Thing | Choice |
|---|---|
| Flutter / Dart | 3.38.4 / 3.10.3 |
| State | `flutter_bloc` cubits, one per feature |
| HTTP | Dio, wrapped in `ApiClient` |
| Navigation | Navigator 1.0, nested per-tab navigators in `TabbedShell` — no routing package |
| Storage | `flutter_secure_storage` for tokens and the cached profile; nothing else persists |
| Push | `firebase_messaging` + `flutter_local_notifications` |
| Maps | `flutter_map` + `latlong2`, `url_launcher` for handoff |

Bundle id `com.tscafe.app` on both platforms. Version `1.0.0+1`.

---

## 2. Rules that came from the API guides

These are not preferences. Breaking any of them is a bug, and several are
enforced by tests.

**Money and ordering**

- Integer pence everywhere. Use `~/` and `%`; never double arithmetic.
- Never send `unit_price_pence`, `line_total_pence`, `subtotal_pence`,
  `delivery_fee_pence`, `total_pence`, `status` or `payment_status` when
  quoting or placing an order. The server prices from `dish_id`; a
  client-supplied price would be forgeable.
- One `Idempotency-Key` per checkout, **reused** on every retry of that
  checkout. A fresh key on retry is how a customer ends up with two orders.
- `POST /reservations` takes **no** idempotency key, so it must never be
  retried automatically.

**Security**

- Never expose `password_hash` or `google_sub`.
- Never put `DATABASE_URL`, `JWT_SECRET`, a Supabase service-role key,
  `FIREBASE_PRIVATE_KEY`, `CRON_SECRET` or the APNs `.p8` in the Flutter app.
- Flutter never connects to Postgres or Supabase directly.
- `reset_token` lives in memory only — never in secure storage, never in a log.
- Never log an FCM token.
- Role checks in Flutter decide **navigation only**. The backend is the
  authority on what anyone may do.

**Errors**

- Branch on `error.code`, display `message`, attach `error.details` to fields.
- Envelope is `{success, message, data}`; pages are
  `{items, page, page_size, total, total_pages}`.

**Time**

- Restaurant-local calendar dates and wall clocks must never be converted
  through the device timezone.

---

## 3. Architecture notes worth knowing before editing

- **`TabbedShell`** holds the per-tab navigators in an `IndexedStack`, so each
  tab keeps its stack. Tabs are built **on first sight** — an unvisited tab has
  no navigator, no cubit and fires no request. This matters: every admin tab
  fetches on build, and eager construction made landing on the shell fire four
  requests at once.
- **`AppNavBar`** is the Android and web tab bar. iOS uses the real `UITabBar`
  via `cupertino_native`, so **nav bar changes do not show on iOS**.
- **Design system**: `AppColors` / `AppSurfaces` / `orderColors`, `AppSpacing`,
  `AppRadius`, `AppIconSize`, `AppTypography`, `Motion`, `AppLayout`.
  `AppSurfaces` is a theme extension, so any test rendering app widgets needs
  `theme: AppTheme.light` or `context.surfaces` is null.
- **`PaymentFlow`** owns the card round trip. Its one rule: a closed sheet is
  not a payment. Only the server, told by Worldpay's webhook, decides.

### Traps this codebase has hit more than once

- `Size.fromHeight(n)` is `Size(infinity, n)` — infinite width inside a `Row`.
  Bitten three times.
- `CrossAxisAlignment.stretch` in a `Row` needs a bounded height; inside a
  `ListView` it has none. Use `IntrinsicHeight`.
- `Color.withValues(alpha: x)` **replaces** the alpha channel. It does not
  scale it. See §5.
- An unbounded `Center` expands to fill whatever it is offered — as a sheet's
  loading placeholder, that makes the sheet grow.
- `AppLifecycleListener` asserts the real sequence
  `resumed → inactive → hidden → paused`.
- `AppSheet` pads only its title block; each sheet brings its own gutter and
  bottom inset.

---

## 4. What was built in this session

**Analytics dashboard** — gradient hero card for today's takings, week and
month beneath at half the weight, a queue bar split by how much of the open
queue each stage holds, three section labels, and a dashboard-shaped skeleton.
Deliberately not framed as a comparison: a month can start mid-week, so
`today <= week <= month` is not guaranteed.

**Notifications** — the bell and the inbox screen each built their own cubit,
so "mark all read" never moved the badge. One app-level cubit now, cleared on
sign-out, refreshed when a push arrives. Inbox pages 15 at a time.

**Android bottom nav** — rebuilt to the requested shape: the selected tab is a
pill carrying its label beside the icon, the rest are bare glyphs, and the pill
grows into the width the others give up. One 200ms `easeOutCubic` controller
drives every part, so nothing drifts out of sync. Tap ripple removed (it read
as a second unexplained colour and outlived the move); a press dip replaces it.
Hidden labels still live in `Semantics` and tooltips.

**Card payment** — `payment_method` is a real choice at checkout. The flow gets
a page (asking `/orders/{id}/pay` if placement produced none), checks the URL
is https, opens it in a Custom Tab / `SFSafariViewController`, then asks the
server what happened on the guide's schedule. Retry is safe: an unpaid order
returns its existing page, a declined one gets a fresh page. Copy never claims
the kitchen has an unpaid card order.

**Cancellation** — the customer cancel was sending **no body at all** against a
route whose `requestBody` is required, so it failed every time on the live API.
It now always sends `{"reason": …}`, with an optional reason field in the
confirm sheet. Cancelling is limited to `status == placed` **and** the server's
`can_cancel` — the server can veto but can no longer widen the window. Admin
cancel/reject cannot submit a blank note.

**Offline session** — startup treated *any* `/auth/me` failure as "signed out",
including no network, so a valid token was thrown away in a dead spot. Only a
401 signs out now; anything else falls back to a cached profile written beside
the tokens. The cache is built from the `AuthUser` model, not the response, so
`password_hash` and `google_sub` cannot reach the device even if the server
starts sending them.

**Also**: table booking end to end; admin venue, users and working hours;
category rename / delete / logo with a pencil affordance on the chip; add-dish
draft that survives a dismissed sheet; prep-time fields widened; order and
reservation sheets no longer grow while closing; repeated taps no longer stack
sheets; Directions now routes instead of showing your own location; Privacy
Policy and Terms screens linked from register.

---

## 5. Bugs worth remembering

**Dark-mode nav label invisible.** The pill's fill was
`accentContainer.withValues(alpha: t)`. `withValues` replaces alpha rather than
scaling it, so the dark palette's 13% crimson wash became **fully opaque
`#E4646B`** — the exact colour the label is drawn in. Light mode was unaffected
because its container is opaque already. Every logical check said the label
rendered correctly at full alpha, because it did; the two colours only collide
once composited. It was found by rendering the bar to a golden PNG and looking
at it.

**Cancel sent no body.** Covered above. Found by reading the deployed
`openapi.json` rather than the integration guide, which described a different
prefix (`/api/orders/...` vs the deployed `/api/v1/orders/...`).

**Directions showed the customer's own location.** The Apple URL carried both
`daddr` and `q`. Apple Maps reads `q` as a search, runs it, and ignores the
rest.

**The basket survived sign-out.** `CartCubit` was created in `build` and never
cleared, so the next person to sign in inherited the previous user's order and
their address at checkout.

---

## 6. Security posture

Fixed this session: arbitrary-scheme URL launch in the payment flow (now
https-only); the basket surviving sign-out; Android `allowBackup` defaulting to
true (now false, with `data_extraction_rules.xml` for Android 12+, verified in
the built APK).

Verified sound: tokens in Keystore/Keychain via `flutter_secure_storage` 11 and
never in a URL, query or log; no FCM token logged; no `reset_token` persisted;
`Random.secure()` for idempotency keys; single-flight 401 refresh; no secrets
in `lib/` or `.env`; no WebView or JS bridge; nothing written to the clipboard.

Outstanding: the backend has **no rate limiting on login**.

---

## 7. Testing

`flutter analyze` clean across the project. **619 tests** in 32 files, all
passing. Line coverage roughly 74%.

Weakest areas by coverage: `features/contact` (0%), `features/shell` (15%),
`main.dart` (25%).

Conventions worth keeping:

- Tests state the rule, not the implementation — the comment says what breaks
  in the real world if the assertion fails.
- Widget tests need `theme: AppTheme.light`.
- The nav bar's test harness must actually move the selection; a static one
  passes while proving nothing.
- `TweenAnimationBuilder` reports its starting value on the frame the rebuild
  happens, so mid-animation assertions need `pump()` then `pump(duration)`.
- The dish-editor draft is session-scoped, so tests call `resetDishDraft()` in
  `setUp`.

---

## 8. Outstanding

### Not started

**Pagination** — admin orders, admin reservations, generate-sittings, and the
dish lists on both the admin and customer sides. Each has its own cubit and
screen. The API already returns `{items, page, page_size, total, total_pages}`,
and the notifications inbox is a working reference implementation.

### Blocked on someone else

| Item | What is needed |
|---|---|
| **Card payment** | The backend returns no `payment_url`, from placement *and* from `/pay`. Per the guide that means Worldpay is unreachable — most likely `WORLDPAY_*` env vars are not set on the deployment. The app side is complete and tested. |
| **iOS push** | Apple ID login is rejected; needs a paid Developer Program membership, an explicit App ID for `com.tscafe.app` with Push Notifications, and the APNs `.p8` in Firebase. `CODE_SIGN_ENTITLEMENTS` is commented out on Release at `ios/Runner.xcodeproj/project.pbxproj:736` with a restore note. **iOS push does not work in any configuration until this is restored.** |
| **Play release** | Release still signs with the **debug key** (`android/app/build.gradle.kts:42`). Play also needs an **AAB**, not the split APKs. Needs your keystore; its passwords must not go in the repo. |
| **Google Sign-In** | Not implemented in the app at all — no `google_sign_in` package, no button, `GOOGLE_CLIENT_ID` empty, and `google-services.json` has **zero `oauth_client` entries**. The backend endpoint and the cubit method exist. Needs SHA-1 fingerprints registered (debug, upload **and** Play App Signing) and the file re-downloaded. |

Debug SHA-1, for Firebase:
`63:5C:9F:D7:F1:21:FF:6A:1B:33:D1:F4:4B:39:53:55:AD:30:89:C8`

### Flagged, awaiting a decision

- **Money formats inconsistently.** Two `formatPence` implementations: the
  dashboard groups thousands, `order_quote.dart` does not, so checkout shows
  `£1234.50` where the dashboard shows `£1,234.50`. Four more sites use double
  division. Small fix.
- **Android notification icon** renders as a white blob; needs a monochrome
  `ic_notification` drawable.
- **`RestaurantLocation` holds placeholder values** — SW1A 1AA and its
  coordinates. The Directions button routes to whatever is in there.
- **Map tiles** come from OSM's public server. Fine for testing, not for
  production volume.
- **`minifyEnabled` / `shrinkResources`** are off. Smaller APK and less
  trivially readable Java; needs ProGuard rules checked against the plugins.
- **The nav bar's `BackdropFilter`** blurs full width every frame beneath a
  surface that is 94% opaque — a real GPU cost for about 6% of what you see.
- **Startup**: `Firebase.initializeApp`, the local-notifications setup and
  `getInitialMessage` all run **before `runApp`**, so nothing renders until
  they finish. Deferring them would need the push coordinator to tolerate not
  existing yet, which risks skipping registration on first launch. Not done
  because the cost was never measured — the wireless VM service connection to
  the iPhone would not hold long enough for `--trace-startup`.

---

## 9. Store listing

Release notes for the first release are at
`android/fastlane/metadata/android/en-GB/changelogs/1.txt` (421 of Play's 500
characters). They deliberately **omit card payment**, because it cannot
complete until the backend reaches Worldpay, and promising it would earn
one-star reviews. The line to add once it works:

> Pay by card in the app, or with cash when you collect.

Still to write, if you want them: the 80-character short description and the
4,000-character full description.
