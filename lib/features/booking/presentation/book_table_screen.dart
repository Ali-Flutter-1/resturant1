import 'package:flutter/material.dart';
import '../../auth/presentation/require_sign_in.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/animations/reveal.dart';
import '../../../core/haptics/app_haptics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/api_error_view.dart';
import '../../../shared/widgets/app_chip.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../../shared/widgets/quantity_stepper.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../auth/auth_cubit.dart';
import '../../auth/session_refresh.dart';
import '../domain/reservation.dart';
import '../domain/reservation_repository.dart';
import 'booking_cubit.dart';
import '../../../shared/widgets/page_body.dart';

/// Requesting a table.
///
/// One screen rather than the guide's four, because the whole flow is short: a
/// party size, a day, a sitting, and who it is for. Splitting that across four
/// pushed routes would mean three back arrows to change a party size.
///
/// The one thing it will not do is call a request a booking. `POST /reservations`
/// answers 201 with a **pending** request that staff must approve, and the
/// screen after it says so in those words.
class BookTableScreen extends StatelessWidget {
  const BookTableScreen({super.key, this.onBack, this.onSeeBookings});

  final VoidCallback? onBack;

  /// Opens the customer's bookings, offered once a request has been made.
  final VoidCallback? onSeeBookings;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          BookingCubit(repository: context.read<ReservationRepository>())
            ..load(),
      child: _BookTableView(onBack: onBack, onSeeBookings: onSeeBookings),
    );
  }
}

class _BookTableView extends StatefulWidget {
  const _BookTableView({this.onBack, this.onSeeBookings});

  final VoidCallback? onBack;
  final VoidCallback? onSeeBookings;

  @override
  State<_BookTableView> createState() => _BookTableViewState();
}

class _BookTableViewState extends State<_BookTableView> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _requests = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Prefilled from the session — the customer already told the app who they
    // are, and asking again is asking them to type their own name.
    final user = context.read<AuthCubit>().state.user;
    if (user != null) _name.text = user.displayName.trim();
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _requests.dispose();
    super.dispose();
  }

  Future<void> _pickDate(BookingCubit cubit, DateTime current) async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(today.year, today.month, today.day),
      // The backend's booking horizon. A picker that offers dates the server
      // refuses with SITTING_TOO_FAR_AHEAD is a picker that wastes a request.
      lastDate: today.add(const Duration(days: 60)),
    );
    if (picked != null) await cubit.setDate(picked);
  }

  Future<void> _submit(BookingCubit cubit) async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();

    if (name.isEmpty || phone.length < 7) {
      showAppSnack(
        context,
        'We need a name and a phone number we can reach you on.',
        isError: true,
      );
      return;
    }

    // Picking a date, a size and a time is all public -- the sittings endpoint
    // does not need a session, and being made to register before seeing
    // whether a table is even free is how somebody decides to ring instead.
    // The account is asked for here, as the booking becomes theirs, and what
    // they have filled in survives: this method carries on where it left off.
    if (!await requireSignIn(context, toContinue: 'to book your table')) return;
    if (!mounted) return;

    AppHaptics.commit();
    final failure = await cubit.submit(
      contactName: name,
      contactPhone: phone,
      specialRequests: _requests.text,
    );
    if (!mounted || failure == null) return;

    showAppSnack(context, failure.message, isError: true);
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<BookingCubit, BookingState>(
      builder: (context, state) {
        final cubit = context.read<BookingCubit>();

        if (state.stage == BookingStage.requested &&
            state.reservation != null) {
          return _RequestSent(
            reservation: state.reservation!,
            onSeeBookings: widget.onSeeBookings,
            onBookAnother: cubit.startAgain,
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Book a table'),
            leading: widget.onBack == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: widget.onBack,
                  ),
            actions: [
              // Reachable without making a booking first. Otherwise the only
              // way to an existing one was to request another.
              if (widget.onSeeBookings != null)
                IconButton(
                  onPressed: widget.onSeeBookings,
                  icon: const Icon(Icons.event_note_outlined),
                  tooltip: 'My bookings',
                ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () => refreshWithSession(context, cubit.load),
            child: ListView(
              padding: pagePadding(
                context,
                top: AppSpacing.x5,
                bottom: AppSpacing.x12 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                _PartyAndDay(
                  state: state,
                  onGuests: cubit.setGuests,
                  onPickDate: () => _pickDate(cubit, state.date),
                ),
                const SizedBox(height: AppSpacing.x5),
                _Sittings(state: state, onSelect: cubit.select),
                const SizedBox(height: AppSpacing.x5),
                _WhoFor(
                  name: _name,
                  phone: _phone,
                  requests: _requests,
                  fieldErrors: state.fieldErrors,
                ),
                const SizedBox(height: AppSpacing.x5),
                _RequestButton(state: state, onSubmit: () => _submit(cubit)),
              ].revealStaggered(),
            ),
          ),
        );
      },
    );
  }
}

/// How many, and which day.
class _PartyAndDay extends StatelessWidget {
  const _PartyAndDay({
    required this.state,
    required this.onGuests,
    required this.onPickDate,
  });

  final BookingState state;
  final ValueChanged<int> onGuests;
  final VoidCallback onPickDate;

  @override
  Widget build(BuildContext context) {
    return AppSurface.row(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your party', style: context.texts.titleMedium),
          const SizedBox(height: AppSpacing.x3),
          QuantityStepper(
            value: state.guests,
            onChanged: onGuests,
            min: 1,
            // The API's ceiling. Offering 31 would offer a refusal.
            max: BookingCubit.maxGuests,
            trailingLabel: 'Guests',
          ),
          const SizedBox(height: AppSpacing.x4),
          Text('Which day', style: context.texts.titleMedium),
          const SizedBox(height: AppSpacing.x3),
          OutlinedButton.icon(
            onPressed: onPickDate,
            icon: const Icon(Icons.calendar_month_outlined),
            label: Text(_dayLabel(state.date)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ),
    );
  }
}

/// The day's sittings, table by table.
class _Sittings extends StatelessWidget {
  const _Sittings({required this.state, required this.onSelect});

  final BookingState state;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    if (state.isLoading && state.availability == null) {
      // Inside the screen's own ListView, so it must not try to scroll.
      return const MessageListSkeleton(rows: 3, shrinkWrap: true);
    }

    if (state.stage == BookingStage.failure && state.failure != null) {
      return ApiErrorView(
        failure: state.failure!,
        onRetry: () => context.read<BookingCubit>().load(),
      );
    }

    final availability = state.availability;
    if (availability == null) return const SizedBox.shrink();

    if (!availability.hasAnySitting) {
      return _Nothing(
        title: 'No sittings that day',
        body:
            'The restaurant has not opened this date for bookings yet. Try '
            'another day.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Choose a table', style: context.texts.titleMedium),
            ),
            if (state.isLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.x1),
        Text(
          'Times that cannot be booked are shown with the reason, so the day '
          'reads as a schedule.',
          style: context.texts.bodySmall?.copyWith(
            color: context.surfaces.inkSoft,
          ),
        ),
        const SizedBox(height: AppSpacing.x3),
        for (final table in availability.tables) ...[
          _TableCard(
            table: table,
            selectedSlotId: state.selectedSlotId,
            onSelect: onSelect,
          ),
          const SizedBox(height: AppSpacing.x3),
        ],
      ],
    );
  }
}

class _TableCard extends StatelessWidget {
  const _TableCard({
    required this.table,
    required this.selectedSlotId,
    required this.onSelect,
  });

  final AvailabilityTable table;
  final String? selectedSlotId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return AppSurface.row(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(table.name, style: context.texts.titleMedium),
              ),
              AppChip.outlined(label: 'Seats ${table.seats}'),
            ],
          ),
          if (table.areaLabel.isNotEmpty || table.description != null) ...[
            const SizedBox(height: 2),
            Text(
              [
                if (table.areaLabel.isNotEmpty) table.areaLabel,
                if (table.description != null) table.description!,
              ].join(' · '),
              style: context.texts.bodySmall?.copyWith(
                color: context.surfaces.inkSoft,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.x3),
          if (table.sittings.isEmpty)
            Text(
              'No sittings for this table.',
              style: context.texts.bodySmall?.copyWith(
                color: context.surfaces.inkSoft,
              ),
            )
          else
            Wrap(
              spacing: AppSpacing.x2,
              runSpacing: AppSpacing.x2,
              children: [
                for (final sitting in table.sittings)
                  _SittingChip(
                    sitting: sitting,
                    seats: table.seats,
                    selected: sitting.slotId == selectedSlotId,
                    onTap: sitting.isAvailable
                        ? () {
                            AppHaptics.selection();
                            onSelect(sitting.slotId);
                          }
                        : null,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// One sitting. Disabled ones stay, with their reason.
class _SittingChip extends StatelessWidget {
  const _SittingChip({
    required this.sitting,
    required this.seats,
    required this.selected,
    this.onTap,
  });

  final AvailabilitySitting sitting;
  final int seats;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;

    // "Seats up to 4" rather than a bare "Too small": the customer's next move
    // is to reduce the party or pick another table, and the number is what tells
    // them which.
    final reason = switch (sitting.unavailableReason) {
      UnavailableReason.tooSmall => 'Seats up to $seats',
      final other => other?.label,
    };

    return Semantics(
      button: enabled,
      selected: selected,
      enabled: enabled,
      child: Material(
        color: selected
            ? scheme.primary
            : enabled
            ? context.surfaces.ground
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x3,
              vertical: AppSpacing.x2,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: selected ? scheme.primary : context.surfaces.line,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sitting.label,
                  style: context.texts.titleSmall?.copyWith(
                    color: selected
                        ? scheme.onPrimary
                        : enabled
                        ? null
                        : context.surfaces.inkSoft,
                  ),
                ),
                if (!enabled && reason != null)
                  Text(
                    reason,
                    style: context.texts.labelSmall?.copyWith(
                      color: context.surfaces.inkSoft,
                    ),
                  )
                else if (enabled && !sitting.isFree)
                  Text(
                    formatBookingPrice(sitting.pricePence),
                    style: context.texts.labelSmall?.copyWith(
                      color: selected ? scheme.onPrimary : scheme.primary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Contact details.
class _WhoFor extends StatelessWidget {
  const _WhoFor({
    required this.name,
    required this.phone,
    required this.requests,
    required this.fieldErrors,
  });

  final TextEditingController name;
  final TextEditingController phone;
  final TextEditingController requests;
  final Map<String, String> fieldErrors;

  @override
  Widget build(BuildContext context) {
    return AppSurface.row(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Who it is for', style: context.texts.titleMedium),
          const SizedBox(height: AppSpacing.x3),
          _Field(
            label: 'Name',
            controller: name,
            hint: 'Ali Hassan',
            error: fieldErrors['contact_name'],
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: AppSpacing.x3),
          _Field(
            label: 'Phone',
            controller: phone,
            hint: '07700 900123',
            keyboardType: TextInputType.phone,
            error: fieldErrors['contact_phone'],
            // Digits and the punctuation phone numbers actually carry — the API
            // accepts 7 to 30 characters of exactly this.
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\- ]')),
              LengthLimitingTextInputFormatter(30),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          _Field(
            label: 'Anything we should know (optional)',
            controller: requests,
            hint: 'Birthday, high chair, step-free access…',
            maxLines: 3,
            error: fieldErrors['special_requests'],
            inputFormatters: [LengthLimitingTextInputFormatter(500)],
          ),
          const SizedBox(height: AppSpacing.x2),
          Text(
            // Said plainly, because the guide is explicit that special requests
            // are not a guarantee — and a customer who books step-free access
            // and does not get it has been misled by this field.
            'We will do our best, but these are requests rather than promises.',
            style: context.texts.bodySmall?.copyWith(
              color: context.surfaces.inkSoft,
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.error,
    this.keyboardType,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final String? error;
  final TextInputType? keyboardType;
  final int maxLines;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.texts.bodySmall?.copyWith(
            color: context.surfaces.inkSoft,
          ),
        ),
        const SizedBox(height: AppSpacing.x1),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          maxLines: maxLines,
          textCapitalization: textCapitalization,
          inputFormatters: inputFormatters,
          decoration: InputDecoration(
            hintText: hint,
            // The API's own complaint about this field, attached to it rather
            // than shown as a general error the customer has to map back.
            errorText: error,
          ),
        ),
      ],
    );
  }
}

class _RequestButton extends StatelessWidget {
  const _RequestButton({required this.state, required this.onSubmit});

  final BookingState state;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final sitting = state.selectedSitting;
    final table = state.selectedTable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sitting != null && table != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.x3),
            child: Text(
              '${table.name} at ${sitting.label} on ${_dayLabel(state.date)}, '
              '${state.guests == 1 ? '1 guest' : '${state.guests} guests'}',
              textAlign: TextAlign.center,
              style: context.texts.bodyMedium,
            ),
          ),
        FilledButton(
          // Disabled until a sitting is chosen, and while the request is with
          // the server — a second tap has no idempotency key to protect it.
          onPressed: state.canSubmit ? onSubmit : null,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: state.isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  state.selectedSlotId == null
                      ? 'Choose a sitting'
                      : 'Request this table',
                ),
        ),
        const SizedBox(height: AppSpacing.x2),
        Text(
          // The single most important sentence on the screen. A 201 is a
          // request, not a table.
          'This sends a request. The restaurant confirms it, and we will hold '
          'the table until they do.',
          textAlign: TextAlign.center,
          style: context.texts.bodySmall?.copyWith(
            color: context.surfaces.inkSoft,
          ),
        ),
      ],
    );
  }
}

/// After a successful request.
class _RequestSent extends StatelessWidget {
  const _RequestSent({
    required this.reservation,
    required this.onBookAnother,
    this.onSeeBookings,
  });

  final ReservationDetail reservation;
  final VoidCallback onBookAnother;
  final VoidCallback? onSeeBookings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colours = context.orderColors;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Request sent'),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: pagePadding(
          context,
          top: AppSpacing.x8,
          bottom: AppSpacing.x12 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Icon(
            Icons.mark_email_read_outlined,
            size: AppIconSize.hero,
            color: scheme.primary,
          ),
          const SizedBox(height: AppSpacing.x4),
          Text(
            'Awaiting approval',
            textAlign: TextAlign.center,
            style: context.texts.headlineLarge,
          ),
          const SizedBox(height: AppSpacing.x2),
          Text(
            'Your table is held while the restaurant reviews this. We will '
            'update your booking as soon as they answer.',
            textAlign: TextAlign.center,
            style: context.texts.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.x5),
          Container(
            padding: const EdgeInsets.all(AppSpacing.x4),
            decoration: BoxDecoration(
              color: colours.preparingContainer,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Column(
              children: [
                Text(
                  'Reference',
                  style: context.texts.bodySmall?.copyWith(
                    color: colours.preparing,
                  ),
                ),
                // The one thing they need if they ring up, so it is the
                // largest text on the screen.
                Text(
                  reservation.reference,
                  style: AppTypography.money(colours.preparing),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x4),
          _SummaryRow(label: 'Table', value: reservation.tableName),
          _SummaryRow(
            label: 'When',
            value:
                '${_dayLabel(reservation.serviceDate)}, '
                '${reservation.timeLabel}',
          ),
          _SummaryRow(label: 'Party', value: reservation.guestLabel),
          if (!reservation.pricePence.isNegative && reservation.pricePence > 0)
            _SummaryRow(
              label: 'Table price',
              value: formatBookingPrice(reservation.pricePence),
            ),
          const SizedBox(height: AppSpacing.x6),
          if (onSeeBookings != null)
            FilledButton(
              onPressed: onSeeBookings,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              child: const Text('See my bookings'),
            ),
          const SizedBox(height: AppSpacing.x2),
          TextButton(
            onPressed: onBookAnother,
            child: const Text('Book another table'),
          ),
        ].revealStaggered(),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: context.texts.bodyMedium?.copyWith(
                color: context.surfaces.inkSoft,
              ),
            ),
          ),
          Text(value, style: context.texts.titleSmall),
        ],
      ),
    );
  }
}

class _Nothing extends StatelessWidget {
  const _Nothing({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.x6),
      decoration: BoxDecoration(
        color: context.surfaces.ground,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: context.surfaces.line),
      ),
      child: Column(
        children: [
          Icon(
            Icons.event_busy_outlined,
            size: AppIconSize.hero,
            color: context.surfaces.inkSoft,
          ),
          const SizedBox(height: AppSpacing.x3),
          Text(title, style: context.texts.titleMedium),
          const SizedBox(height: AppSpacing.x1),
          Text(
            body,
            textAlign: TextAlign.center,
            style: context.texts.bodySmall?.copyWith(
              color: context.surfaces.inkSoft,
            ),
          ),
        ],
      ),
    );
  }
}

/// `Thu 20 Aug`, and "Today"/"Tomorrow" where those are clearer.
String _dayLabel(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final difference = DateTime(
    date.year,
    date.month,
    date.day,
  ).difference(today).inDays;
  if (difference == 0) return 'Today';
  if (difference == 1) return 'Tomorrow';

  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${days[date.weekday - 1]} ${date.day} ${months[date.month - 1]}';
}
