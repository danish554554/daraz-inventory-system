import 'package:intl/intl.dart';

class Formatters {
  static final DateFormat _dateTimeFormat = DateFormat('dd MMM yyyy, hh:mm a');
  static final DateFormat _dateFormat = DateFormat('dd MMM yyyy');
  static final NumberFormat _numberFormat = NumberFormat.decimalPattern();
  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00');

  static String dateTime(DateTime? value) {
    if (value == null) return '-';
    return _dateTimeFormat.format(value.toLocal());
  }

  static String date(DateTime? value) {
    if (value == null) return '-';
    return _dateFormat.format(value.toLocal());
  }

  static String quantity(num? value) {
    return _numberFormat.format(value ?? 0);
  }

  static String money(num? value) {
    return _moneyFormat.format(value ?? 0);
  }

  static String durationMs(int? value) {
    final ms = value ?? 0;
    if (ms <= 0) return '0s';
    final seconds = (ms / 1000).round();
    if (seconds < 60) return '${seconds}s';
    final minutes = (seconds / 60).floor();
    final remSeconds = seconds % 60;
    if (minutes < 60) return remSeconds == 0 ? '${minutes}m' : '${minutes}m ${remSeconds}s';
    final hours = (minutes / 60).floor();
    final remMinutes = minutes % 60;
    return remMinutes == 0 ? '${hours}h' : '${hours}h ${remMinutes}m';
  }
}
