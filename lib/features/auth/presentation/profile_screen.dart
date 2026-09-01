import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/animations/reveal.dart';
import '../../../core/haptics/app_haptics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/network_photo.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../../shared/widgets/skeleton.dart';
import '../auth_cubit.dart';
import 'account_panel.dart';
import 'auth_form_parts.dart';
import '../../../shared/widgets/page_body.dart';

/// The signed-in person's own account, whatever their role.
///
/// One screen for customer, staff and admin. The three differ in what they can
/// *do* elsewhere in the app, not in what their own profile is — and a separate
/// admin profile screen would be the same fields maintained twice.
///
/// Reads `/auth/me` through the session rather than fetching again: the user is
/// already in state from startup. A pull-to-refresh re-reads it, which is how a
/// role changed in the admin panel reaches the device without a sign-out.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    super.key,
    this.onGetInTouch,
    this.onOpenMessages,
    this.onManageUsers,
    this.onOpeningHours,
    this.onManageVenue,
    this.onDeliveryAreas,
  });

  /// Opens the contact form. Optional, because the customer app has it on its
  /// own screen and the admin app does not.
  final VoidCallback? onGetInTouch;

  /// Opens the contact inbox. Passed only for an admin.
  ///
  /// Here rather than as a sixth tab: five is already as many as a bar reads
  /// well at, and an inbox is checked a few times a day rather than being one of
  /// the app's main places.
  final VoidCallback? onOpenMessages;

  /// Opens account management. Passed only for an admin — staff have no route to
  /// it, and the API refuses them anyway.
  final VoidCallback? onManageUsers;

  /// Opens the weekly opening hours. Admin only — staff cannot edit them, and
  /// the API refuses them.
  final VoidCallback? onOpeningHours;

  /// Opens tables and sittings. Admin only — the API denies staff both.
  final VoidCallback? onManageVenue;

  /// Admin only: the delivery map, its areas, and what each one charges.
  final VoidCallback? onDeliveryAreas;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: BlocBuilder<AuthCubit, AuthState>(
        builder: (context, state) {
          final user = state.user;
          if (user == null) {
            // Two ways to get here. Mid-restore there *will* be a user in a
            // moment, so a skeleton is honest. During sign-out the shell is
            // being torn down and anything drawn would flash, so draw nothing.
            return state.isRestoring
                ? const ProfileSkeleton()
                : const SizedBox.shrink();
          }

          return RefreshIndicator(
            onRefresh: () => context.read<AuthCubit>().refreshUser(),
            child: ListView(
              padding: pagePadding(
                context,
                top: AppSpacing.x5,
                bottom: AppSpacing.x12 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                _Identity(user: user),
                const SizedBox(height: AppSpacing.x5),
                _DetailsCard(user: user),
                const SizedBox(height: AppSpacing.x5),
                if (onGetInTouch != null) ...[
                  _LinkTile(
                    icon: Icons.mail_outline,
                    title: 'Get in touch',
                    subtitle: 'Questions, feedback or a booking',
                    onTap: onGetInTouch!,
                  ),
                  const SizedBox(height: AppSpacing.x3),
                ],
                if (onOpenMessages != null) ...[
                  _LinkTile(
                    icon: Icons.inbox_outlined,
                    title: 'Messages',
                    subtitle: 'What customers have sent through the website',
                    onTap: onOpenMessages!,
                  ),
                  const SizedBox(height: AppSpacing.x3),
                ],
                if (onManageUsers != null) ...[
                  _LinkTile(
                    icon: Icons.people_outline,
                    title: 'Manage users',
                    subtitle: 'Roles, access and closing accounts',
                    onTap: onManageUsers!,
                  ),
                  const SizedBox(height: AppSpacing.x3),
                ],
                if (onOpeningHours != null) ...[
                  _LinkTile(
                    icon: Icons.schedule_outlined,
                    title: 'Opening hours',
                    subtitle: 'What customers see on the About screen',
                    onTap: onOpeningHours!,
                  ),
                  const SizedBox(height: AppSpacing.x3),
                ],
                if (onManageVenue != null) ...[
                  _LinkTile(
                    icon: Icons.table_restaurant_outlined,
                    title: 'Tables & sittings',
                    subtitle: 'The room, and when it can be booked',
                    onTap: onManageVenue!,
                  ),
                  const SizedBox(height: AppSpacing.x3),
                ],
                if (onDeliveryAreas != null) ...[
                  _LinkTile(
                    icon: Icons.local_shipping_outlined,
                    title: 'Delivery areas',
                    subtitle: 'Where you deliver, and what each area costs',
                    onTap: onDeliveryAreas!,
                  ),
                  const SizedBox(height: AppSpacing.x3),
                ],
                if (onGetInTouch != null ||
                    onOpenMessages != null ||
                    onManageUsers != null ||
                    onOpeningHours != null ||
                    onManageVenue != null ||
                    onDeliveryAreas != null)
                  const SizedBox(height: AppSpacing.x2),
                const AccountPanel(),
              ].revealStaggered(),
            ),
          );
        },
      ),
    );
  }
}

/// A row that goes somewhere.
class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppSurface.row(
      padding: EdgeInsets.zero,
      clip: true,
      child: ListTile(
        leading: Icon(icon, size: AppIconSize.xl),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right, size: AppIconSize.xl),
        onTap: onTap,
      ),
    );
  }
}

/// Avatar, name, and what the account is allowed to do.
class _Identity extends StatelessWidget {
  const _Identity({required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = user.avatarUrl;

    return Column(
      children: [
        // The photograph where there is one, otherwise a glyph for the role —
        // and the role badge on top either way, so what an account *is* reads at
        // a glance rather than having to be looked up in the label below.
        SizedBox(
          width: 96,
          height: 96,
          child: Stack(
            children: [
              Container(
                width: 88,
                height: 88,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.surfaces.accentContainer,
                ),
                child: avatar == null || avatar.isEmpty
                    ? Center(
                        child: Icon(
                          _avatarIcon(user.role),
                          size: AppIconSize.hero + 4,
                          color: scheme.primary,
                        ),
                      )
                    : NetworkPhoto(
                        url: avatar,
                        errorBuilder: (context, _, _) => Center(
                          child: Icon(
                            _avatarIcon(user.role),
                            size: AppIconSize.hero + 4,
                            color: scheme.primary,
                          ),
                        ),
                      ),
              ),
              if (user.role != UserRole.customer)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: _RoleMark(role: user.role),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.x3),
        Text(
          user.displayName,
          style: context.texts.headlineMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.x1),
        Text(
          user.email,
          style: context.texts.bodyMedium?.copyWith(
            color: context.surfaces.inkMuted,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.x3),
        _RoleBadge(role: user.role),
      ],
    );
  }

  /// The glyph standing in for a missing photograph.
  ///
  /// A customer is a person; staff are the service; an administrator holds the
  /// keys. Initials used to sit here, which read as identity but said nothing
  /// about what the account can do — and on the staff side that is the thing
  /// worth knowing at a glance.
  static IconData _avatarIcon(UserRole role) => switch (role) {
    UserRole.customer => Icons.person,
    UserRole.staff => Icons.room_service,
    UserRole.admin => Icons.admin_panel_settings,
  };
}

/// The small badge on the corner of a staff or admin avatar.
///
/// Customers get none: on a customer's own profile a badge saying "customer"
/// would be decoration. It is the accounts with extra power that are worth
/// marking.
class _RoleMark extends StatelessWidget {
  const _RoleMark({required this.role});

  final UserRole role;

  @override
  Widget build(BuildContext context) {
    final colours = context.orderColors;
    final scheme = Theme.of(context).colorScheme;
    final (icon, background) = switch (role) {
      UserRole.staff => (Icons.room_service, colours.preparing),
      UserRole.admin => (Icons.shield, colours.ready),
      UserRole.customer => (Icons.person, colours.served),
    };

    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        // A ring in the page's own colour, so the badge reads as sitting on top
        // of the avatar rather than punched into it.
        border: Border.all(color: scheme.surface, width: 2),
      ),
      child: Icon(icon, size: AppIconSize.sm, color: Colors.white),
    );
  }
}

/// What the role means, in words rather than a bare label.
///
/// "admin" tells a person nothing about what they can do; staff and admin both
/// see the same shell, so saying which one you are matters.
class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});

  final UserRole role;

  @override
  Widget build(BuildContext context) {
    final colours = context.orderColors;
    final (label, description, foreground, background) = switch (role) {
      UserRole.customer => (
        'Customer',
        'Order, book a table and track your orders',
        colours.served,
        colours.servedContainer,
      ),
      UserRole.staff => (
        'Staff',
        'Work the order queue and update statuses',
        colours.preparing,
        colours.preparingContainer,
      ),
      UserRole.admin => (
        'Administrator',
        'Full access to the menu, orders and the venue',
        colours.ready,
        colours.readyContainer,
      ),
    };

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.x3,
            vertical: AppSpacing.x1 + 2,
          ),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text(label, style: AppTypography.caption(foreground)),
        ),
        const SizedBox(height: AppSpacing.x2),
        Text(
          description,
          textAlign: TextAlign.center,
          style: context.texts.bodySmall?.copyWith(
            color: context.surfaces.inkSoft,
          ),
        ),
      ],
    );
  }
}

/// Name and email, with the name editable.
class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context) {
    return AppSurface.panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Your details', style: context.texts.titleLarge),
              ),
              TextButton.icon(
                onPressed: () => _showEditProfile(context, user),
                icon: const Icon(Icons.edit_outlined, size: AppIconSize.md),
                label: const Text('Edit'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
          _Field(label: 'First name', value: user.firstName),
          _Field(label: 'Last name', value: user.lastName),
          // Shown but not editable — the API refuses to change an email here
          // because it needs verification. The absence of an edit control says
          // that on its own; a line of instructions under every profile does not
          // earn its place.
          _Field(label: 'Email', value: user.email),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: context.texts.bodySmall?.copyWith(
                color: context.surfaces.inkSoft,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.x3),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: context.texts.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }
}

void _showEditProfile(BuildContext context, AuthUser user) {
  final cubit = context.read<AuthCubit>();
  showAppSheet<void>(
    context: context,
    title: 'Edit your details',
    subtitle: 'Your email stays as it is.',
    child: BlocProvider.value(
      value: cubit,
      child: _EditProfileForm(user: user),
    ),
  );
}

class _EditProfileForm extends StatefulWidget {
  const _EditProfileForm({required this.user});

  final AuthUser user;

  @override
  State<_EditProfileForm> createState() => _EditProfileFormState();
}

class _EditProfileFormState extends State<_EditProfileForm> {
  late final _first = TextEditingController(text: widget.user.firstName);
  late final _last = TextEditingController(text: widget.user.lastName);
  Map<String, String> _errors = const {};
  bool _busy = false;

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final errors = <String, String>{};
    final first = AuthRules.name(_first.text, 'first name');
    final last = AuthRules.name(_last.text, 'last name');
    if (first != null) errors['first_name'] = first;
    if (last != null) errors['last_name'] = last;

    setState(() => _errors = errors);
    if (errors.isNotEmpty) {
      AppHaptics.failure();
      return;
    }

    setState(() => _busy = true);
    final error = await context.read<AuthCubit>().updateProfile(
      firstName: _first.text,
      lastName: _last.text,
    );
    if (!mounted) return;

    if (error != null) {
      AppHaptics.failure();
      setState(() {
        _busy = false;
        _errors = {'first_name': error};
      });
      return;
    }

    AppHaptics.success();
    Navigator.of(context).pop();
    showAppSnack(context, 'Your details were updated.');
  }

  @override
  Widget build(BuildContext context) {
    // Scrollable for the same reason as the inbox sheet: the sheet bounds its
    // child's height, so with the keyboard up an unscrollable column puts its
    // own submit button out of reach.
    return SingleChildScrollView(
      padding: pagePadding(
        context,
        top: 0,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.x4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AuthField(
                  label: 'First name',
                  controller: _first,
                  textCapitalization: TextCapitalization.words,
                  autofillHints: const [AutofillHints.givenName],
                  fieldError: _errors['first_name'],
                ),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: AuthField(
                  label: 'Last name',
                  controller: _last,
                  textCapitalization: TextCapitalization.words,
                  autofillHints: const [AutofillHints.familyName],
                  fieldError: _errors['last_name'],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x5),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Saving…' : 'Save changes'),
          ),
        ],
      ),
    );
  }
}
