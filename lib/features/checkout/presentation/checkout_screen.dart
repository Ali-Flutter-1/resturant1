import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/animations/motion.dart';
import '../../../core/animations/reveal.dart';
import '../../../core/haptics/app_haptics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/api_error_view.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../auth/auth_cubit.dart';
import '../../cart/cart_cubit.dart';
import '../../orders/domain/customer_order.dart';
import '../../../core/animations/page_transitions.dart';
import '../../delivery/domain/delivery_zone_repository.dart';
import '../../delivery/presentation/delivery_area_screen.dart';
import '../../orders/domain/order_quote.dart';
import '../../orders/domain/order_repository.dart';
import 'checkout_cubit.dart';
import '../../../shared/widgets/page_body.dart';

/// Pricing the basket, then placing the order.
///
/// Every figure on this screen comes from `POST /orders/quote` — the fee, the
/// minimum, the total. Nothing is computed locally, because the server is what
/// charges the customer and a total the app worked out is only ever a guess at
/// what it will say.
class CheckoutScreen extends StatelessWidget {
  const CheckoutScreen({super.key, this.onBack, this.onPlaceOrder});

  final VoidCallback? onBack;

  /// Called once an order exists, with its number, so the caller can leave the
  /// checkout behind.
  final void Function(String orderNumber)? onPlaceOrder;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => CheckoutCubit(
        repository: context.read<OrderRepository>(),
        cart: context.read<CartCubit>(),
        zones: context.read<DeliveryZoneRepository>(),
      )..quote(),
      child: _CheckoutView(onBack: onBack, onPlaceOrder: onPlaceOrder),
    );
  }
}

class _CheckoutView extends StatefulWidget {
  const _CheckoutView({this.onBack, this.onPlaceOrder});

  final VoidCallback? onBack;
  final void Function(String orderNumber)? onPlaceOrder;

  @override
  State<_CheckoutView> createState() => _CheckoutViewState();
}

class _CheckoutViewState extends State<_CheckoutView> {
  late final _name = TextEditingController();
  late final _phone = TextEditingController();
  final _address = TextEditingController();
  final _address2 = TextEditingController();
  final _city = TextEditingController();
  final _postcode = TextEditingController();
  final _deliveryNotes = TextEditingController();
  final _customerNote = TextEditingController();

  Map<String, String> _localErrors = const {};

  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // Prefilled from the signed-in account. Asking somebody their own name in an
    // app they are signed into is a form they have already filled in.
    final user = context.read<AuthCubit>().state.user;
    if (user != null) _name.text = user.displayName;

    // A quote goes stale while the app is in the background: an admin can
    // change a price, a dish can sell out, and a delivery slot can pass. The
    // totals on screen are what the customer believes they are agreeing to, so
    // coming back re-prices before they can tap Place order on a figure the
    // server would no longer honour.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (!mounted) return;
        final cubit = context.read<CheckoutCubit>();
        // Not while the order is being sent or has been placed -- re-quoting
        // there would either race the submission or re-price a finished order.
        if (cubit.state.stage == CheckoutStage.submitting ||
            cubit.state.stage == CheckoutStage.placed) {
          return;
        }
        cubit.quoteSoon();
      },
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    for (final c in [
      _name,
      _phone,
      _address,
      _address2,
      _city,
      _postcode,
      _deliveryNotes,
      _customerNote,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _place() async {
    FocusScope.of(context).unfocus();
    final cubit = context.read<CheckoutCubit>();
    final isDelivery = cubit.state.isDelivery;

    // Checked here so the common mistakes cost no round trip. The server checks
    // all of it again and its wording wins whenever the two disagree.
    final errors = <String, String>{};
    if (_name.text.trim().isEmpty) {
      errors['contact_name'] = 'We need a name for the order.';
    }
    if (_phone.text.trim().length < 7) {
      errors['contact_phone'] = 'Enter a phone number we can reach you on.';
    }
    if (isDelivery) {
      if (_address.text.trim().isEmpty) {
        errors['address_line1'] = 'Where are we delivering to?';
      }
      if (_city.text.trim().isEmpty) errors['city'] = 'Add the town or city.';
      if (_postcode.text.trim().isEmpty) {
        errors['postcode'] = 'Add the postcode.';
      }
    }

    setState(() => _localErrors = errors);
    if (errors.isNotEmpty) {
      AppHaptics.failure();
      return;
    }

    final failure = await cubit.place(
      contactName: _name.text,
      contactPhone: _phone.text,
      addressLine1: _address.text,
      addressLine2: _address2.text,
      city: _city.text,
      postcode: _postcode.text,
      deliveryNotes: _deliveryNotes.text,
      customerNote: _customerNote.text,
    );
    if (!mounted) return;

    if (failure != null) {
      AppHaptics.failure();
      // The API's own words. Nothing typed is lost, and the same idempotency key
      // is kept — so pressing the button again retries rather than duplicating.
      showAppSnack(context, failure.message, isError: true);
      return;
    }

    final order = cubit.state.placedOrder;
    if (order == null) return;

    // What the customer is told depends on where the money got to, because it
    // decides whether the kitchen has the order at all. A card order that has
    // not been paid for is held back until the payment webhook lands, so
    // telling them it is being prepared would be a lie they act on.
    // A payment attempt that never got as far as a page reports its own
    // reason. Falling through to "still confirming" would describe a payment
    // that was never started.
    final paymentFailure = cubit.state.failure;
    final message = switch (order) {
      _ when !order.isCard => 'Order ${order.reference} placed.',
      _ when !order.isPaid && paymentFailure != null =>
        '${order.reference} placed. ${paymentFailure.message}',
      _ when order.isPaid =>
        "Order ${order.reference} confirmed - we're preparing it.",
      _ when order.paymentStatus == CustomerPaymentStatus.failed =>
        'Your card was declined. Your order is saved - tap Pay to try again.',
      // Placed, unpaid, and the webhook has not arrived within the window.
      // Neither a success nor a failure, and worth saying so exactly.
      _ => "We're still confirming your payment for ${order.reference}.",
    };
    final wentWrong = order.isCard && !order.isPaid;

    wentWrong ? AppHaptics.failure() : AppHaptics.success();
    showAppSnack(context, message, isError: wentWrong);
    widget.onPlaceOrder?.call(order.reference);
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CheckoutCubit, CheckoutState>(
      builder: (context, state) {
        final cubit = context.read<CheckoutCubit>();
        final quote = state.quote;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Checkout'),
            // Null `onBack` yields to `automaticallyImplyLeading`, which
            // supplies a working BackButton whenever the route can pop.
            leading: widget.onBack == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: widget.onBack,
                    tooltip: 'Back',
                  ),
          ),
          body: state.stage == CheckoutStage.failed && state.failure != null
              ? ApiErrorView(
                  failure: state.failure!,
                  onRetry: () => cubit.quote(),
                )
              : ListView(
                  padding: pagePadding(
                    context,
                    top: AppSpacing.x4,
                    bottom: AppSpacing.x12,
                  ),
                  children: [
                    // A menu that changed under the customer. Above everything,
                    // because it explains why the basket or the total is not
                    // what they left it as.
                    if (state.staleMenuNotice != null) ...[
                      _StaleMenuBanner(
                        message: state.failure?.message,
                        recovery: state.staleMenuNotice!,
                      ),
                      const SizedBox(height: AppSpacing.x4),
                    ],
                    _MethodPicker(
                      isDelivery: state.isDelivery,
                      busy: state.stage == CheckoutStage.quoting,
                      onChanged: cubit.setDelivery,
                    ),
                    const SizedBox(height: AppSpacing.x5),

                    _Panel(
                      title: 'Who it is for',
                      child: Column(
                        children: [
                          _Field(
                            label: 'Name',
                            controller: _name,
                            hint: 'Ali Hassan',
                            textCapitalization: TextCapitalization.words,
                            error: _error(state, 'contact_name'),
                          ),
                          const SizedBox(height: AppSpacing.x3),
                          _Field(
                            label: 'Phone',
                            controller: _phone,
                            hint: '07700 900123',
                            keyboardType: TextInputType.phone,
                            // Digits and the punctuation a phone number uses —
                            // the API accepts nothing else.
                            formatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9 +()-]'),
                              ),
                              LengthLimitingTextInputFormatter(30),
                            ],
                            error: _error(state, 'contact_phone'),
                          ),
                        ],
                      ),
                    ),

                    if (state.isDelivery) ...[
                      const SizedBox(height: AppSpacing.x4),
                      _Panel(
                        title: 'Where to',
                        child: Column(
                          children: [
                            _Field(
                              label: 'Address',
                              controller: _address,
                              hint: '12 Example Street',
                              error: _error(state, 'address_line1'),
                            ),
                            const SizedBox(height: AppSpacing.x3),
                            _Field(
                              label: 'Flat, floor (optional)',
                              controller: _address2,
                              hint: 'Flat 4',
                              error: _error(state, 'address_line2'),
                            ),
                            const SizedBox(height: AppSpacing.x3),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: _Field(
                                    label: 'Town or city',
                                    controller: _city,
                                    hint: 'Manchester',
                                    error: _error(state, 'city'),
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.x3),
                                Expanded(
                                  child: _Field(
                                    label: 'Postcode',
                                    controller: _postcode,
                                    hint: 'KW14 7EL',
                                    textCapitalization:
                                        TextCapitalization.characters,
                                    formatters: [
                                      LengthLimitingTextInputFormatter(12),
                                    ],
                                    // What decides the fee and the minimum, so
                                    // it is looked up as it is typed rather
                                    // than at the end.
                                    onChanged: cubit.setPostcode,
                                    error:
                                        state.postcodeError ??
                                        _error(state, 'postcode'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.x3),
                            _Field(
                              label: 'Delivery notes (optional)',
                              controller: _deliveryNotes,
                              hint: 'Gate code, which door…',
                              maxLines: 2,
                              error: _error(state, 'delivery_notes'),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: AppSpacing.x4),
                    _TimingPanel(state: state, onChanged: cubit.setSlot),

                    const SizedBox(height: AppSpacing.x4),
                    _Panel(
                      title: 'Anything else',
                      child: _Field(
                        label: 'Note for the restaurant (optional)',
                        controller: _customerNote,
                        hint: 'Please call on arrival',
                        maxLines: 2,
                        error: _error(state, 'customer_note'),
                      ),
                    ),

                    // What this address costs to deliver to, in the
                    // server's own words. Above the basket because the total
                    // below is unknowable until the zone is.
                    if (state.isDelivery) ...[
                      const SizedBox(height: AppSpacing.x4),
                      _DeliveryZonePanel(
                        state: state,
                        onCollect: () => cubit.setDelivery(false),
                      ),
                    ],

                    const SizedBox(height: AppSpacing.x4),
                    _QuotePanel(
                      quote: quote,
                      isDelivery: state.isDelivery,
                      loading: state.stage == CheckoutStage.quoting,
                      // Editable: the basket was a one-way street once checkout
                      // opened, so a customer who changed their mind about one
                      // item had to go back and find the dish again to remove it.
                      onChangeQuantity: (line, quantity) {
                        context.read<CartCubit>().setQuantity(line, quantity);
                        // Re-priced by the server, not adjusted locally. Removing
                        // a line can drop the basket under the delivery minimum
                        // or change the fee, and only the quote knows that.
                        //
                        // Debounced: a customer settling on a quantity taps
                        // several times in a second, and each tap used to cost
                        // its own round trip.
                        context.read<CheckoutCubit>().quoteSoon();
                      },
                    ),

                    const SizedBox(height: AppSpacing.x5),
                    _PaymentMethodPicker(
                      method: state.paymentMethod,
                      isDelivery: state.isDelivery,
                      onChanged: (method) => context
                          .read<CheckoutCubit>()
                          .setPaymentMethod(method),
                    ),

                    const SizedBox(height: AppSpacing.x5),
                    _PlaceButton(
                      state: state,
                      onPressed: state.canPlace ? _place : null,
                    ),
                  ].revealStaggered(),
                ),
        );
      },
    );
  }

  /// The server's complaint about a field wins over the local one — it knows
  /// things the app cannot.
  String? _error(CheckoutState state, String field) =>
      state.fieldErrors[field] ?? _localErrors[field];
}

/// Delivery or collection.
class _MethodPicker extends StatelessWidget {
  const _MethodPicker({
    required this.isDelivery,
    required this.busy,
    required this.onChanged,
  });

  final bool isDelivery;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _MethodTile(
            icon: Icons.delivery_dining,
            label: 'Delivery',
            selected: isDelivery,
            onTap: busy ? null : () => onChanged(true),
          ),
        ),
        const SizedBox(width: AppSpacing.x3),
        Expanded(
          child: _MethodTile(
            icon: Icons.storefront_outlined,
            label: 'Collection',
            selected: !isDelivery,
            onTap: busy ? null : () => onChanged(false),
          ),
        ),
      ],
    );
  }
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({
    required this.icon,
    required this.label,
    required this.selected,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AnimatedContainer(
          duration: context.motion.fade(Motion.fast),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.x4),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.10)
                : context.surfaces.ground,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected ? scheme.primary : context.surfaces.line,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: AppIconSize.xxl,
                color: selected ? scheme.primary : context.surfaces.inkSoft,
              ),
              const SizedBox(height: AppSpacing.x1),
              Text(
                label,
                style: context.texts.titleMedium?.copyWith(
                  color: selected ? scheme.primary : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// As soon as possible, or a time the kitchen can actually make.
///
/// Sixteen chips in a Wrap is what this was: a wall of numbers with no sense of
/// which were plausible. Now it is two choices, and picking a time opens a list —
/// so the common case (as soon as possible) is one tap and the rare one is not
/// competing with it.
class _TimingPanel extends StatelessWidget {
  const _TimingPanel({required this.state, required this.onChanged});

  final CheckoutState state;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final slots = state.selectableSlots;
    final chosen = state.requestedFor;
    final prep = state.prepMinutes;

    return _Panel(
      title: 'When',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The kitchen's own estimate, stated before the choice — it is the
          // reason some times are missing, and an unexplained gap reads as a bug.
          if (prep != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.x3),
              child: Row(
                children: [
                  Icon(
                    Icons.soup_kitchen_outlined,
                    size: AppIconSize.sm,
                    color: context.surfaces.inkSoft,
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(
                    child: Text(
                      'This order takes about $prep minutes to cook, so earlier '
                      'times are not offered.',
                      style: context.texts.bodySmall?.copyWith(
                        color: context.surfaces.inkSoft,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          _TimeOption(
            label: 'As soon as possible',
            detail: prep == null
                ? 'We start as soon as the order lands'
                : 'Ready in roughly $prep minutes',
            selected: chosen == null,
            onTap: () => onChanged(null),
          ),
          const SizedBox(height: AppSpacing.x2),
          _TimeOption(
            label: chosen == null
                ? 'Choose a time'
                : 'At ${_slotLabel(chosen)}',
            detail: slots.isEmpty
                ? 'No later times available'
                : '${slots.length} '
                      '${slots.length == 1 ? 'time' : 'times'} available',
            selected: chosen != null,
            onTap: slots.isEmpty
                ? null
                : () => _pickSlot(context, slots, chosen, onChanged),
          ),

          if (state.everySlotTooSoon) ...[
            const SizedBox(height: AppSpacing.x3),
            Text(
              // Said rather than left as an empty list: the customer has done
              // nothing wrong, and "as soon as possible" still works.
              'Every later time tonight is inside this order’s cooking time, so '
              'only as soon as possible is available.',
              style: context.texts.bodySmall?.copyWith(
                color: context.surfaces.inkSoft,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static void _pickSlot(
    BuildContext context,
    List<String> slots,
    String? chosen,
    ValueChanged<String?> onChanged,
  ) {
    showAppSheet<void>(
      context: context,
      title: 'Choose a time',
      subtitle: 'The earliest the kitchen can have it ready.',
      child: Builder(
        builder: (sheetContext) => ListView(
          shrinkWrap: true,
          padding: pagePadding(
            context,
            top: 0,
            bottom: AppSpacing.x2 + MediaQuery.paddingOf(sheetContext).bottom,
          ),
          children: [
            for (final slot in slots)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  slot == chosen
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: slot == chosen
                      ? Theme.of(sheetContext).colorScheme.primary
                      : sheetContext.surfaces.inkSoft,
                ),
                title: Text(_slotLabel(slot)),
                subtitle: Text(_slotDay(slot)),
                onTap: () {
                  AppHaptics.selection();
                  onChanged(slot);
                  Navigator.of(sheetContext).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  /// The slot as a local time. What goes back to the API is the untouched string.
  static String _slotLabel(String iso) {
    final when = DateTime.tryParse(iso)?.toLocal();
    if (when == null) return iso;
    return '${when.hour.toString().padLeft(2, '0')}:'
        '${when.minute.toString().padLeft(2, '0')}';
  }

  /// Today or tomorrow, so an 00:30 slot is not mistaken for this morning.
  static String _slotDay(String iso) {
    final when = DateTime.tryParse(iso)?.toLocal();
    if (when == null) return '';
    final now = DateTime.now();
    final day = DateTime(when.year, when.month, when.day);
    final today = DateTime(now.year, now.month, now.day);
    final difference = day.difference(today).inDays;
    if (difference == 0) return 'Today';
    if (difference == 1) return 'Tomorrow';
    return '${when.day}/${when.month}';
  }
}

/// One of the two timing choices.
class _TimeOption extends StatelessWidget {
  const _TimeOption({
    required this.label,
    required this.detail,
    required this.selected,
    this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AnimatedContainer(
          duration: context.motion.fade(Motion.fast),
          padding: const EdgeInsets.all(AppSpacing.x3),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected ? scheme.primary : context.surfaces.line,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: AppIconSize.xl,
                color: selected
                    ? scheme.primary
                    : enabled
                    ? context.surfaces.inkSoft
                    : context.surfaces.line,
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: context.texts.titleMedium?.copyWith(
                        color: enabled ? null : context.surfaces.inkSoft,
                      ),
                    ),
                    Text(
                      detail,
                      style: context.texts.bodySmall?.copyWith(
                        color: context.surfaces.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
              if (enabled && !selected)
                Icon(
                  Icons.chevron_right,
                  size: AppIconSize.xl,
                  color: context.surfaces.inkSoft,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The server's arithmetic, over the basket's own lines.
///
/// The rows come from the cart because that is what can be edited; the money on
/// each row comes from the quote, because the app never prices anything. Where
/// the two disagree — a quote in flight after an edit — the row shows the cached
/// price and the totals below stay on the last figure the server gave.
class _QuotePanel extends StatelessWidget {
  const _QuotePanel({
    required this.quote,
    required this.isDelivery,
    required this.loading,
    required this.onChangeQuantity,
  });

  final OrderQuote? quote;
  final bool isDelivery;
  final bool loading;

  /// Zero removes the line — which is what "minus" on a single item means.
  final void Function(CartLine line, int quantity) onChangeQuantity;

  /// The priced line for a basket line, matched on what the API echoes back.
  ///
  /// `dish_id` and `variant_id` plus the note and spice level, because the same
  /// dish can appear several times with different instructions or different
  /// configurations and those are genuinely separate lines. Without the variant
  /// a basket holding a 12-inch and a 16-inch of one pizza would show the same
  /// price against both.
  QuoteLine? _pricedFor(CartLine line) {
    for (final priced in quote?.lines ?? const <QuoteLine>[]) {
      if (priced.dishId == line.dishId &&
          priced.variantId == line.variantId &&
          priced.notes == line.notes &&
          priced.spiceLevel == line.spiceLevel) {
        return priced;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = context.watch<CartCubit>().state.lines;

    if (quote == null && lines.isEmpty) {
      return _Panel(
        title: 'Your order',
        child: Text(
          loading ? 'Pricing your basket…' : 'Nothing priced yet.',
          style: context.texts.bodyMedium?.copyWith(
            color: context.surfaces.inkSoft,
          ),
        ),
      );
    }

    final priced = quote;
    return _Panel(
      title: 'Your order',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines) ...[
            _BasketRow(
              line: line,
              priced: _pricedFor(line),
              pricePence: _pricedFor(line)?.linePence ?? line.displayLinePence,
              onChangeQuantity: (quantity) => onChangeQuantity(line, quantity),
            ),
            const SizedBox(height: AppSpacing.x3),
          ],
          if (lines.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.x3),
              child: Text(
                'Your basket is empty.',
                style: context.texts.bodyMedium?.copyWith(
                  color: context.surfaces.inkSoft,
                ),
              ),
            ),
          if (priced != null) ...[
            Divider(color: context.surfaces.line),
            _SummaryLine(label: 'Subtotal', value: priced.formattedSubtotal),
            if (isDelivery)
              _SummaryLine(label: 'Delivery', value: priced.formattedFee),
            const SizedBox(height: AppSpacing.x2),
            Row(
              children: [
                Expanded(child: Text('Total', style: context.texts.titleLarge)),
                // Dimmed rather than replaced while a new quote is in flight: a
                // total that vanishes on every tap of "plus" is worse than one
                // that is briefly a moment behind.
                AnimatedOpacity(
                  opacity: loading ? 0.4 : 1,
                  duration: context.motion.fade(Motion.fast),
                  child: Text(
                    priced.formattedTotal,
                    style: AppTypography.money(scheme.onSurface),
                  ),
                ),
              ],
            ),
            if (!priced.meetsMinimum) ...[
              const SizedBox(height: AppSpacing.x3),
              // The exact shortfall, because "minimum not met" leaves the
              // customer to do the arithmetic. The delivery fee does not count.
              Container(
                padding: const EdgeInsets.all(AppSpacing.x3),
                decoration: BoxDecoration(
                  color: context.orderColors.overdueContainer,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: AppIconSize.md,
                      color: context.orderColors.overdue,
                    ),
                    const SizedBox(width: AppSpacing.x2),
                    Expanded(
                      child: Text(
                        'Add ${priced.formattedShortfall} more to reach the '
                        '${OrderQuote.formatPence(priced.minimumOrderPence)} '
                        'delivery minimum.',
                        style: context.texts.bodySmall?.copyWith(
                          color: context.orderColors.overdue,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// One editable basket line.
/// Cash or card.
///
/// Card is the default nudge but not the default choice: switching somebody to
/// paying online without them asking is not a decision a checkout screen gets
/// to make.
/// What delivery costs to this address, or why it cannot be delivered to.
///
/// Everything here is read from the server: the fee, the minimum, and the
/// wording when an address is out of range. Nothing about delivery pricing is
/// hardcoded in the app -- the admin redraws zones and changes prices without
/// a release, and a number baked in here would quietly become a lie.
class _DeliveryZonePanel extends StatelessWidget {
  const _DeliveryZonePanel({required this.state, required this.onCollect});

  final CheckoutState state;

  /// Switches the order to collection, which is the way out of an address we
  /// do not deliver to.
  final VoidCallback onCollect;

  @override
  Widget build(BuildContext context) {
    final surfaces = context.surfaces;
    final colours = context.orderColors;
    final check = state.zoneCheck;

    if (state.checkingPostcode) {
      return _ZoneNotice(
        icon: Icons.local_shipping_outlined,
        tint: surfaces.inkSoft,
        title: 'Checking your postcode…',
      );
    }

    if (state.postcodeError != null) {
      return _ZoneNotice(
        icon: Icons.error_outline,
        tint: colours.overdue,
        title: state.postcodeError!,
      );
    }

    if (check == null) {
      // Not a failure: they simply have not finished typing.
      return _ZoneNotice(
        icon: Icons.local_shipping_outlined,
        tint: surfaces.inkSoft,
        title: 'Add your postcode to see the delivery cost.',
      );
    }

    if (!check.deliverable) {
      return _ZoneNotice(
        icon: Icons.wrong_location_outlined,
        tint: colours.overdue,
        // The server's own sentence, not ours.
        title: check.message,
        // Two ways out, and the map is the one that answers "where *do* you
        // deliver, then" without making them guess postcodes.
        detail: 'See the areas we cover, or switch to collection.',
        action: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            TextButton(
              onPressed: onCollect,
              child: const Text('Collect instead'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                AppPageRoute<void>(builder: (_) => const DeliveryAreaScreen()),
              ),
              child: const Text('See areas'),
            ),
          ],
        ),
      );
    }

    final zone = check.zone!;
    return _ZoneNotice(
      icon: Icons.check_circle_outline,
      tint: colours.ready,
      title: zone.name,
      detail:
          'Minimum order ${OrderQuote.formatPence(zone.minOrderPence)} · '
          'Delivery ${OrderQuote.formatPence(zone.deliveryFeePence)}',
    );
  }
}

class _ZoneNotice extends StatelessWidget {
  const _ZoneNotice({
    required this.icon,
    required this.tint,
    required this.title,
    this.detail,
    this.action,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return AppSurface.row(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Row(
        children: [
          Icon(icon, size: AppIconSize.lg, color: tint),
          const SizedBox(width: AppSpacing.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.texts.titleSmall),
                if (detail != null)
                  Text(
                    detail!,
                    style: context.texts.bodySmall?.copyWith(
                      color: context.surfaces.inkMuted,
                    ),
                  ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _PaymentMethodPicker extends StatelessWidget {
  const _PaymentMethodPicker({
    required this.method,
    required this.isDelivery,
    required this.onChanged,
  });

  final PaymentMethod method;
  final bool isDelivery;
  final ValueChanged<PaymentMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Payment',
      child: Column(
        children: [
          _PaymentOption(
            icon: Icons.payments_outlined,
            title: 'Cash',
            detail: 'Pay when you ${isDelivery ? 'get it' : 'collect'}.',
            selected: method == PaymentMethod.cash,
            onTap: () => onChanged(PaymentMethod.cash),
          ),
          const SizedBox(height: AppSpacing.x3),
          // Advertised, not offered.
          //
          // The card path is built and covered by tests, but the backend
          // cannot reach the payment provider yet -- it returns an order with
          // no payment page. Letting somebody pick this would walk them
          // through checkout into a dead end, so it is shown greyed and every
          // order goes through as cash.
          _PaymentOption(
            icon: Icons.credit_card,
            title: 'Card',
            detail: 'Coming soon. Pay the restaurant directly for now.',
            selected: false,
            enabled: false,
            onTap: null,
          ),
        ],
      ),
    );
  }
}

class _PaymentOption extends StatelessWidget {
  const _PaymentOption({
    required this.icon,
    required this.title,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool selected;
  final VoidCallback? onTap;

  /// False for a method that exists in the app but cannot be used yet. It is
  /// still drawn -- greyed and inert -- because "card is coming" is worth
  /// knowing, and an option that silently disappears looks like a fault.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = enabled ? scheme.onSurface : context.surfaces.inkSoft;
    final accent = enabled ? scheme.primary : context.surfaces.inkSoft;

    return Semantics(
      selected: selected,
      button: true,
      enabled: enabled,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: AnimatedContainer(
            duration: Motion.fast,
            curve: Motion.standard,
            padding: const EdgeInsets.all(AppSpacing.x4),
            decoration: BoxDecoration(
              color: selected
                  ? context.surfaces.accentContainer
                  : context.surfaces.ground,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: selected ? accent : context.surfaces.line,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: AppIconSize.lg,
                  color: selected ? accent : context.surfaces.inkSoft,
                ),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: context.texts.titleSmall?.copyWith(color: ink),
                      ),
                      Text(
                        detail,
                        style: context.texts.bodySmall?.copyWith(
                          color: context.surfaces.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: AppIconSize.lg,
                  color: selected ? scheme.primary : context.surfaces.inkSoft,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BasketRow extends StatelessWidget {
  const _BasketRow({
    required this.line,
    required this.pricePence,
    required this.onChangeQuantity,
    this.priced,
  });

  final CartLine line;

  /// The server's version of this line, once a quote has come back. Its
  /// breakdown wins over the basket's cached one — the guide is explicit that
  /// the quote's selection data is what the wording should come from, because
  /// it is the split that was actually billed.
  final QuoteLine? priced;

  final int pricePence;
  final ValueChanged<int> onChangeQuantity;

  Future<void> _confirmRemove(BuildContext context) async {
    // Only the last one is confirmed. Stepping 3 down to 2 is routine and
    // reversible with the next tap; stepping 1 down to 0 makes the line
    // disappear, and an accidental tap there loses the note with it.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${line.title}?'),
        content: const Text('It will be taken out of your basket.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: context.orderColors.overdue,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      AppHaptics.commit();
      onChangeQuantity(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Spice level and the kitchen note read as one line of small print: both are
    // instructions attached to this item, and stacking them separately made a
    // two-item basket four lines tall.
    final detail = [
      if (line.spiceLevel != null) '${line.spiceLevel!.label} spice',
      if (line.notes != null) line.notes!,
    ].join(' · ');

    // The variant belongs in the title -- "Custom Breakfast (6 Items)" is one
    // thing bought, not a thing plus a footnote.
    final title = priced?.titleWithVariant ?? line.titleWithVariant;

    // Every chosen option, with the ones that cost extra priced. Falls back to
    // the basket's cached summary until the first quote lands, so the row is
    // never blank about what was configured.
    final selections = priced?.selections ?? const <QuoteSelection>[];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.texts.bodyLarge),
              if (selections.isNotEmpty)
                for (final selection in selections)
                  _SelectionLine(selection: selection)
              else if (line.selectionSummary != null)
                Text(
                  line.selectionSummary!,
                  style: context.texts.bodySmall?.copyWith(
                    color: context.surfaces.inkSoft,
                  ),
                ),
              if (detail.isNotEmpty)
                Text(
                  detail,
                  style: context.texts.bodySmall?.copyWith(
                    color: context.surfaces.inkSoft,
                  ),
                ),
              const SizedBox(height: AppSpacing.x2),
              Row(
                children: [
                  _StepIcon(
                    // One item shows a bin rather than a minus, so it is clear
                    // that the next tap removes the line rather than reducing it.
                    icon: line.quantity > 1
                        ? Icons.remove_rounded
                        : Icons.delete_outline_rounded,
                    semanticLabel: line.quantity > 1
                        ? 'One fewer ${line.title}'
                        : 'Remove ${line.title}',
                    // Live while a quote is in flight. The basket, not the
                    // server, owns the quantity -- pricing merely follows it --
                    // so locking the stepper for the length of a round trip
                    // made every tap feel like it cost a second.
                    onPressed: () => line.quantity > 1
                        ? onChangeQuantity(line.quantity - 1)
                        : _confirmRemove(context),
                  ),
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${line.quantity}',
                      textAlign: TextAlign.center,
                      style: context.texts.titleMedium,
                    ),
                  ),
                  _StepIcon(
                    icon: Icons.add_rounded,
                    semanticLabel: 'One more ${line.title}',
                    onPressed: line.quantity >= CartState.maxQuantity
                        ? null
                        : () => onChangeQuantity(line.quantity + 1),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.x2),
        Text(
          OrderQuote.formatPence(pricePence),
          style: context.texts.bodyLarge,
        ),
      ],
    );
  }
}

/// Says that the menu changed while the customer was shopping.
///
/// Two sentences on purpose: the server's own message says what went wrong —
/// it knows which dish and why — and the recovery line says what the app did
/// about it, which the server cannot know.
class _StaleMenuBanner extends StatelessWidget {
  const _StaleMenuBanner({required this.recovery, this.message});

  final String? message;
  final String recovery;

  @override
  Widget build(BuildContext context) {
    final colours = context.orderColors;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.x3),
      decoration: BoxDecoration(
        color: colours.preparingContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.restaurant_menu_outlined,
            size: AppIconSize.md,
            color: colours.preparing,
          ),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: Text(
              [
                if (message != null && message!.trim().isNotEmpty) message!,
                recovery,
              ].join(' '),
              style: context.texts.bodySmall?.copyWith(
                color: colours.preparing,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One chosen option under a basket line.
///
/// An included option is named and left unpriced; a charged one carries its
/// own amount. That contrast is the whole explanation of a 6-item breakfast
/// costing more than £11.95, and it is worth two words per row to make it.
class _SelectionLine extends StatelessWidget {
  const _SelectionLine({required this.selection});

  final QuoteSelection selection;

  @override
  Widget build(BuildContext context) {
    final muted = context.texts.bodySmall?.copyWith(
      color: context.surfaces.inkSoft,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        children: [
          Expanded(child: Text(selection.label, style: muted)),
          if (selection.isCharged) ...[
            const SizedBox(width: AppSpacing.x2),
            Text(
              // Only the charged part. An option with 2 included and 1 extra
              // shows the price of the one extra, which is what was billed.
              '+${OrderQuote.formatPence(selection.totalPence)}',
              style: muted,
            ),
          ],
        ],
      ),
    );
  }
}

class _StepIcon extends StatelessWidget {
  const _StepIcon({
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;

    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: Material(
        color: context.surfaces.ground,
        shape: CircleBorder(side: BorderSide(color: context.surfaces.line)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled
              ? () {
                  AppHaptics.selection();
                  onPressed!();
                }
              : null,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: 34,
            child: Icon(
              icon,
              size: AppIconSize.md,
              color: enabled
                  ? Theme.of(context).colorScheme.primary
                  : context.surfaces.inkSoft,
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: context.texts.bodyMedium?.copyWith(
                color: context.surfaces.inkMuted,
              ),
            ),
          ),
          Text(value, style: context.texts.bodyMedium),
        ],
      ),
    );
  }
}

class _PlaceButton extends StatelessWidget {
  const _PlaceButton({required this.state, this.onPressed});

  final CheckoutState state;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final submitting = state.stage == CheckoutStage.submitting;
    final quote = state.quote;
    // The card wording is a promise about the next screen: tapping this opens
    // Worldpay's page rather than finishing the order outright.
    final verb = state.isCard ? 'Pay' : 'Place order';

    return FilledButton(
      // Disabled while in flight, so a double tap cannot become two attempts —
      // the idempotency key would catch it, but not asking is better.
      onPressed: submitting || state.paying ? null : onPressed,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      child: Text(
        state.paying
            ? 'Confirming your payment…'
            : submitting
            ? 'Placing your order…'
            : quote == null
            ? verb
            : '$verb · ${quote.formattedTotal}',
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppSurface.panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: context.texts.titleLarge),
          const SizedBox(height: AppSpacing.x3),
          child,
        ],
      ),
    );
  }
}

/// A labelled field with a slot for the API's complaint about it.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.onChanged,
    this.hint,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.sentences,
    this.maxLines = 1,
    this.formatters,
    this.error,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final int maxLines;
  final List<TextInputFormatter>? formatters;
  final String? error;

  /// Watched where a field changes what the order costs, rather than only
  /// being read when it is submitted.
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colours = context.orderColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: context.texts.bodySmall),
        const SizedBox(height: AppSpacing.x1),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          textCapitalization: textCapitalization,
          maxLines: maxLines,
          inputFormatters: formatters,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            // Only the border turns: recolouring the whole field makes one wrong
            // character look like a failure of the form.
            enabledBorder: error == null
                ? null
                : OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: colours.overdue),
                  ),
          ),
        ),
        AnimatedSize(
          duration: context.motion.move(Motion.fast),
          alignment: Alignment.topLeft,
          child: error == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.x1),
                  child: Text(
                    error!,
                    style: context.texts.bodySmall?.copyWith(
                      color: colours.overdue,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
