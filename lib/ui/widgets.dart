import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/share_format.dart';
import '../services.dart';
import 'file_actions.dart';
import 'login_screen.dart';

const monthsGen = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'
];
const weekdaysFull = ['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье'];
const weekdaysShort = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

String dayLong(DateTime d) => '${weekdaysFull[d.weekday - 1]}, ${d.day} ${monthsGen[d.month - 1]}';
String dayMonth(DateTime d) => '${d.day} ${monthsGen[d.month - 1]}';
bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
DateTime today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

String weekRange(DateTime monday) {
  final end = monday.add(const Duration(days: 6));
  if (monday.month == end.month) return '${monday.day}–${end.day} ${monthsGen[end.month - 1]}';
  return '${dayMonth(monday)} – ${dayMonth(end)}';
}

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'только что';
  if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
  if (d.inHours < 24) return '${d.inHours} ч назад';
  return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
}

Color markColor(BuildContext context, Mark m) {
  final n = m.numeric;
  final c = Theme.of(context).colorScheme;
  if (n == null) return c.surfaceContainerHighest;
  if (n >= 4.5) return Colors.green.shade600;
  if (n >= 3.5) return Colors.lightGreen.shade700;
  if (n >= 2.5) return Colors.orange.shade700;
  return Colors.red.shade600;
}

class MarkChip extends StatelessWidget {
  const MarkChip({super.key, required this.mark, this.showDate = false});
  final Mark mark;
  final bool showDate;
  @override
  Widget build(BuildContext context) {
    final bg = markColor(context, mark);
    final fg = mark.numeric == null ? Theme.of(context).colorScheme.onSurface : Colors.white;
    final tip = [
      if (mark.date != null) dayMonth(mark.date!),
      if (mark.weight != 1) 'вес ${mark.weight % 1 == 0 ? mark.weight.toInt() : mark.weight}',
      if (mark.comment.isNotEmpty) mark.comment,
    ].join(' · ');
    final chip = Container(
      constraints: const BoxConstraints(minWidth: 30),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(mark.value, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
        if (mark.weight != 1)
          Padding(
            padding: const EdgeInsets.only(left: 3),
            child: Text('×${mark.weight % 1 == 0 ? mark.weight.toInt() : mark.weight}',
                style: TextStyle(color: fg.withValues(alpha: 0.85), fontSize: 11)),
          ),
        if (showDate && mark.date != null)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text('${mark.date!.day}.${mark.date!.month.toString().padLeft(2, '0')}',
                style: TextStyle(color: fg.withValues(alpha: 0.85), fontSize: 11)),
          ),
      ]),
    );
    return tip.isEmpty ? chip : Tooltip(message: tip, triggerMode: TooltipTriggerMode.tap, child: chip);
  }
}

class LessonCard extends StatelessWidget {
  const LessonCard({super.key, required this.lesson, required this.date, this.showHomework = true});
  final Lesson lesson;
  final DateTime date;
  final bool showHomework;

  @override
  Widget build(BuildContext context) {
    final compact = Services.I.settings.compact;
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 3 : 5),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showLessonSheet(context, lesson, date),
        child: Padding(
          padding: EdgeInsets.all(compact ? 10 : 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 46,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (lesson.number.isNotEmpty) Text(lesson.number, style: t.titleMedium?.copyWith(color: c.primary)),
                if (lesson.time.isNotEmpty)
                  Text(lesson.time.replaceAll('–', '\n').replaceAll('-', '\n'), style: t.bodySmall),
              ]),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(lesson.subject, style: t.titleMedium)),
                  if (lesson.hasHomework && !showHomework)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: c.secondaryContainer, borderRadius: BorderRadius.circular(6)),
                      child: Text('ДЗ', style: t.labelSmall),
                    ),
                ]),
                if (lesson.topic.isNotEmpty && !compact)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(lesson.topic, style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                if (showHomework && lesson.homework.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(lesson.homework, style: t.bodyMedium, maxLines: compact ? 3 : 8, overflow: TextOverflow.ellipsis),
                  ),
                if (showHomework && lesson.files.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 6), child: AttachmentRow(files: lesson.files)),
                if (lesson.marks.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(spacing: 4, runSpacing: 4, children: lesson.marks.map((m) => MarkChip(mark: m)).toList()),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

Future<void> copyText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано'), duration: Duration(seconds: 1)));
  }
}

void showLessonSheet(BuildContext context, Lesson l, DateTime date) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) {
      final t = Theme.of(ctx).textTheme;
      final share = shareLessonText(l, date, includeTopic: false);
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (ctx, controller) => SelectionArea(
          child: ListView(controller: controller, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
            Text(l.subject, style: t.headlineSmall),
            const SizedBox(height: 4),
            Text([dayLong(date), if (l.number.isNotEmpty) '${l.number} урок', if (l.time.isNotEmpty) l.time].join(' · '),
                style: t.bodyMedium),
            if (l.topic.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Тема', style: t.labelLarge),
              Text(l.topic),
            ],
            const SizedBox(height: 16),
            Text('Домашнее задание', style: t.labelLarge),
            Text(l.homework.isEmpty && l.files.isEmpty ? 'Не задано' : l.homework),
            if (l.files.isNotEmpty) ...[
              const SizedBox(height: 10),
              AttachmentRow(files: l.files),
            ],
            if (l.marks.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Оценки', style: t.labelLarge),
              const SizedBox(height: 4),
              for (final m in l.marks)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    MarkChip(mark: m),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text([
                      if (m.kind == 'hometask') 'за ДЗ',
                      if (m.weight != 1) 'вес ${m.weight % 1 == 0 ? m.weight.toInt() : m.weight}',
                      if (m.comment.isNotEmpty) m.comment,
                    ].join(' · '))),
                  ]),
                ),
            ],
            const SizedBox(height: 20),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: () => copyText(ctx, l.homework.isEmpty ? share : l.homework),
                  icon: const Icon(Icons.copy),
                  label: const Text('Копировать')),
              OutlinedButton.icon(
                  onPressed: () => FileActions.shareText(share),
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Поделиться')),
              if (l.files.isNotEmpty)
                OutlinedButton.icon(
                    onPressed: () => FileActions.shareFiles(ctx, l.files, text: share),
                    icon: const Icon(Icons.attach_file),
                    label: Text(l.files.length == 1 ? 'Отправить файл' : 'Отправить файлы')),
            ]),
          ]),
        ),
      );
    },
  );
}

/// «‹ 17–23 ноября ›» header used by the week-based tabs.
class WeekNav extends StatelessWidget {
  const WeekNav({super.key, required this.delta, required this.onChanged});
  final int delta;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) {
    final monday = mondayOfNow().add(Duration(days: 7 * delta));
    final label = delta == 0 ? 'Эта неделя' : (delta == 1 ? 'Следующая неделя' : (delta == -1 ? 'Прошлая неделя' : ''));
    return Row(children: [
      IconButton(onPressed: () => onChanged(delta - 1), icon: const Icon(Icons.chevron_left), tooltip: 'Назад'),
      Expanded(
        child: GestureDetector(
          onTap: delta == 0 ? null : () => onChanged(0),
          child: Column(children: [
            Text(weekRange(monday), style: Theme.of(context).textTheme.titleSmall),
            if (label.isNotEmpty) Text(label, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
      IconButton(onPressed: () => onChanged(delta + 1), icon: const Icon(Icons.chevron_right), tooltip: 'Вперёд'),
    ]);
  }
}

DateTime mondayOfNow() {
  final t = today();
  return t.subtract(Duration(days: t.weekday - 1));
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 40, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: 12), action!],
      ]),
    );
  }
}

/// Session/offline banner shown on top of the tabs.
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final repo = Services.I.repo;
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final c = Theme.of(context).colorScheme;
        if (repo.sessionExpired) {
          return MaterialBanner(
            backgroundColor: c.errorContainer,
            content: const Text('Сессия школы истекла. Показаны сохранённые данные.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginWebView())),
                child: const Text('Войти'),
              ),
            ],
          );
        }
        if (repo.lastError != null) {
          return MaterialBanner(
            backgroundColor: c.surfaceContainerHighest,
            content: Text('${repo.lastError}${repo.lastSync == null ? '' : '\nОбновлено ${timeAgo(repo.lastSync!)}'}'),
            actions: [TextButton(onPressed: repo.refreshAll, child: const Text('Повторить'))],
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}
