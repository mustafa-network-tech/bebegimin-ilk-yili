import 'package:flutter/material.dart';

import '../utils/dates.dart';

/// Tappable date field (calendar dates, no time zone).
class DateField extends StatelessWidget {
  const DateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.firstDate,
    required this.lastDate,
    this.helper,
    this.icon = Icons.event_outlined,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;
  final DateTime firstDate;
  final DateTime lastDate;
  final String? helper;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        final initial = value ?? lastDate;
        final picked = await showDatePicker(
          context: context,
          initialDate: initial.isBefore(firstDate) ? firstDate : (initial.isAfter(lastDate) ? lastDate : initial),
          firstDate: firstDate,
          lastDate: lastDate,
          helpText: label,
        );
        if (picked != null) onChanged(Dates.dateOnly(picked));
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon), helperText: helper, helperMaxLines: 2),
        child: Text(value == null ? 'Seçin' : Dates.longWithWeekday(value!)),
      ),
    );
  }
}

class TimeField extends StatelessWidget {
  const TimeField({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final TimeOfDay? value;
  final ValueChanged<TimeOfDay?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        final picked = await showTimePicker(context: context, initialTime: value ?? TimeOfDay.now());
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.schedule_rounded),
          suffixIcon: value == null
              ? null
              : IconButton(tooltip: 'Saati kaldır', icon: const Icon(Icons.close_rounded), onPressed: () => onChanged(null)),
        ),
        child: Text(value == null ? 'İsteğe bağlı' : value!.format(context)),
      ),
    );
  }
}

TimeOfDay? parseSqlTime(String? v) {
  if (v == null || v.length < 5) return null;
  return TimeOfDay(hour: int.parse(v.substring(0, 2)), minute: int.parse(v.substring(3, 5)));
}
