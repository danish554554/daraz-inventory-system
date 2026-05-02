import 'package:flutter/material.dart';

import '../widgets/app_theme.dart';

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.borderColor,
    this.radius = 18,
    this.backgroundColor = Colors.white,
    this.shadow = true,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? borderColor;
  final double radius;
  final Color backgroundColor;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? AppTheme.border),
        boxShadow: shadow
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.035),
                  blurRadius: 14,
                  offset: const Offset(0, 7),
                ),
              ]
            : null,
      ),
      child: child,
    );

    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: card,
      ),
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 10, 16, 96),
    this.onRefresh,
  });

  final Widget child;
  final EdgeInsets padding;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final view = ListView(
      padding: padding,
      physics: const AlwaysScrollableScrollPhysics(),
      children: <Widget>[child],
    );
    return SafeArea(
      child: onRefresh == null
          ? view
          : RefreshIndicator(onRefresh: onRefresh!, child: view),
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.caption,
    this.tint = AppTheme.primarySoft,
    this.iconColor = AppTheme.primary,
    this.trailing,
  });

  final String label;
  final String value;
  final IconData icon;
  final String? caption;
  final Color tint;
  final Color iconColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(13),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
                child: Icon(icon, color: iconColor, size: 16),
              ),
              if (trailing != null)
                Flexible(
                  child: Align(alignment: Alignment.centerRight, child: trailing!),
                ),
            ],
          ),
          const SizedBox(height: 13),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (caption != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              caption!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.success,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.color,
    required this.softColor,
  });

  final String label;
  final Color color;
  final Color softColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: softColor, borderRadius: BorderRadius.circular(20)),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w900),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
  });

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.6,
                ),
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (action != null) ...<Widget>[const SizedBox(width: 10), action!],
      ],
    );
  }
}

class CircleIconButton extends StatelessWidget {
  const CircleIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.background = AppTheme.primary,
    this.foreground = Colors.white,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 38,
      child: FilledButton(
        style: FilledButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: background,
          foregroundColor: foreground,
          shape: const CircleBorder(),
        ),
        onPressed: onPressed,
        child: Icon(icon, size: 19),
      ),
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expanded = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final button = FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: loading ? null : onPressed,
      icon: loading
          ? const SizedBox(
              height: 17,
              width: 17,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : Icon(icon ?? Icons.arrow_forward, size: 17),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
      ),
    );
    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: AppTheme.textPrimary,
        side: const BorderSide(color: AppTheme.border),
        minimumSize: const Size.fromHeight(48),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: onPressed,
      icon: Icon(icon ?? Icons.tune, size: 17, color: AppTheme.primary),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
      ),
    );
  }
}

class MiniIcon extends StatelessWidget {
  const MiniIcon({
    super.key,
    required this.icon,
    this.color = AppTheme.primary,
    this.background = AppTheme.primarySoft,
    this.size = 34,
  });

  final IconData icon;
  final Color color;
  final Color background;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(size / 2.7)),
      child: Icon(icon, size: size * 0.5, color: color),
    );
  }
}

class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.text,
    this.background = AppTheme.primarySoft,
    this.foreground = AppTheme.primary,
    this.icon = Icons.info_outline,
  });

  final String text;
  final Color background;
  final Color foreground;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(14)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 17, color: foreground),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: foreground, fontWeight: FontWeight.w700, fontSize: 12, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.hintText,
    this.labelText,
    this.keyboardType,
    this.obscureText = false,
    this.maxLines = 1,
    this.prefixIcon,
    this.suffix,
    this.onChanged,
    this.enabled = true,
  });

  final TextEditingController? controller;
  final String? hintText;
  final String? labelText;
  final TextInputType? keyboardType;
  final bool obscureText;
  final int maxLines;
  final IconData? prefixIcon;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      maxLines: maxLines,
      onChanged: onChanged,
      enabled: enabled,
      decoration: InputDecoration(
        labelText: labelText,
        hintText: hintText,
        prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 18) : null,
        suffixIcon: suffix,
      ),
    );
  }
}

class ProductImageBox extends StatelessWidget {
  const ProductImageBox({
    super.key,
    required this.imageUrl,
    this.size = 54,
    this.radius = 14,
    this.icon = Icons.inventory_2_outlined,
  });

  final String imageUrl;
  final double size;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl.trim();
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppTheme.softGrey,
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(colors: <Color>[AppTheme.softGrey, Colors.grey.shade300]),
      ),
      child: Icon(icon, color: AppTheme.textMuted, size: size * 0.38),
    );

    if (url.isEmpty) return fallback;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: AppTheme.softGrey,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: const Center(
              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        },
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.inbox_outlined,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        children: <Widget>[
          MiniIcon(icon: icon, size: 42),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.35, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class AppLoader extends StatelessWidget {
  const AppLoader({super.key, this.label = 'Loading...'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(color: AppTheme.primary),
          const SizedBox(height: 14),
          Text(label, style: const TextStyle(color: AppTheme.textMuted, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.highlight = false,
    this.loading = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final bool highlight;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: loading ? null : onTap,
      padding: const EdgeInsets.all(13),
      backgroundColor: highlight ? AppTheme.primary : Colors.white,
      borderColor: highlight ? AppTheme.primary : AppTheme.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          loading
              ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : MiniIcon(
                  icon: icon,
                  color: highlight ? AppTheme.primary : AppTheme.primary,
                  background: highlight ? Colors.white.withValues(alpha: 0.9) : AppTheme.primarySoft,
                ),
          const SizedBox(height: 12),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: highlight ? Colors.white : AppTheme.textPrimary,
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: highlight ? Colors.white.withValues(alpha: 0.82) : AppTheme.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

void showAppSnackBar(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? AppTheme.danger : AppTheme.textPrimary,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
}
