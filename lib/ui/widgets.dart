import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/myschool.dart' show roundedMark;
import '../core/share_format.dart';
import '../core/util.dart';
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
  if (n == null) return c.outline;
  if (n >= 4.5) return Colors.green.shade600;
  if (n >= 3.5) return Colors.teal.shade600;
  if (n >= 2.5) return Colors.orange.shade700;
  return Colors.red.shade600;
}

Color avgColor(BuildContext context, double? a) =>
    a == null ? Theme.of(context).colorScheme.outline : markColor(context, Mark(value: roundedMark(a)));

String fmtAvg(double a) => a.toStringAsFixed(2).replaceAll('.', ',');
String fmtWeight(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();

/// A mark as in the official app: a rounded square, weight as a small badge.
class MarkChip extends StatelessWidget {
  const MarkChip({super.key, required this.mark, this.size = 34, this.forecast = false});
  final Mark mark;
  final double size;
  final bool forecast;
  @override
  Widget build(BuildContext context) {
    final col = markColor(context, mark);
    final tip = [
      if (mark.date != null) dayMonth(mark.date!),
      if (mark.weight != 1) 'вес ${fmtWeight(mark.weight)}',
      if (mark.comment.isNotEmpty) mark.comment,
    ].join(' · ');
    final box = Container(
      constraints: BoxConstraints(minWidth: size, minHeight: size),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: col.withValues(alpha: forecast ? 0.06 : 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: col.withValues(alpha: forecast ? 0.5 : 0.9), width: forecast ? 1 : 1.4),
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(mark.value,
            style: TextStyle(color: col, fontWeight: FontWeight.w700, fontSize: size * 0.45, height: 1.1)),
      ),
    );
    final chip = mark.weight == 1
        ? box
        : Stack(clipBehavior: Clip.none, children: [
            box,
            Positioned(
              right: size < 32 ? -6 : -5,
              bottom: size < 32 ? -6 : -5,
              child: Container(
                width: size < 32 ? 14 : 17,
                height: size < 32 ? 14 : 17,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle),
                child: Text(fmtWeight(mark.weight),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
                        fontSize: size < 32 ? 8.5 : 10,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ]);
    return tip.isEmpty ? chip : Tooltip(message: tip, triggerMode: TooltipTriggerMode.tap, child: chip);
  }
}

/// Lesson number in a tinted circle.
class LessonNumber extends StatelessWidget {
  const LessonNumber(this.number, {super.key});
  final String number;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.primaryContainer, shape: BoxShape.circle),
      child: Text(number.isEmpty ? '•' : number,
          style: TextStyle(color: c.onPrimaryContainer, fontWeight: FontWeight.w700)),
    );
  }
}

class SmallTag extends StatelessWidget {
  const SmallTag(this.text, {super.key, this.icon, this.color});
  final String text;
  final IconData? icon;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final fg = color ?? c.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: color == null ? c.secondaryContainer : color!.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) Padding(padding: const EdgeInsets.only(right: 3), child: Icon(icon, size: 13, color: fg)),
        Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
      ]),
    );
  }
}

String lessonMeta(Lesson l) => [
      if (l.room.isNotEmpty) 'каб. ${l.room}',
      if (l.teacher.isNotEmpty) l.teacher,
    ].join(' · ');

/// Day card row: number + time, subject, room/teacher, homework snippet, files, marks.
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
    final meta = lessonMeta(lesson);
    final times = lesson.time.split(RegExp(r'[–-]'));
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 3 : 4),
      elevation: 0,
      color: c.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showLessonSheet(context, lesson, date),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, compact ? 8 : 12, 12, compact ? 8 : 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 44,
              child: Column(children: [
                lesson.isLesson ? LessonNumber(lesson.number) : Icon(Icons.assignment_outlined, color: c.primary),
                if (lesson.time.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  for (final x in times) Text(x.trim(), style: t.labelSmall?.copyWith(color: c.onSurfaceVariant)),
                ],
              ]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(lesson.subject, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
                  if (lesson.hasHomework && !showHomework) ...[const SizedBox(width: 6), const SmallTag('ДЗ')],
                  if (lesson.absence.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    SmallTag(lesson.absence, color: c.error),
                  ],
                ]),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(meta, style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                  ),
                if (lesson.topic.isNotEmpty && !compact)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(lesson.topic, style: t.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                if (showHomework && lesson.homework.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 6),
                        child: Icon(Icons.home_work_outlined, size: 16, color: c.primary),
                      ),
                      Expanded(
                        child: Text(lesson.homework,
                            style: t.bodyMedium, maxLines: compact ? 2 : 3, overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                  ),
                if (showHomework && lesson.files.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 6), child: AttachmentRow(files: lesson.files)),
              ]),
            ),
            if (lesson.marks.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final m in lesson.marks)
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: MarkChip(mark: m, size: 32)),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Homework item (Задания): subject, text, files, share.
class HomeworkCard extends StatelessWidget {
  const HomeworkCard({super.key, required this.lesson, required this.date, this.showDate = false});
  final Lesson lesson;
  final DateTime date;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final sub = [
      if (showDate) dayLong(date),
      if (lesson.isLesson && lesson.number.isNotEmpty) 'к ${lesson.number} уроку',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 0,
      color: c.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showLessonSheet(context, lesson, date),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(lesson.subject, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  if (sub.isNotEmpty) Text(sub, style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                ]),
              ),
              ...lesson.marks.map((m) => Padding(padding: const EdgeInsets.only(left: 4), child: MarkChip(mark: m, size: 28))),
              IconButton(
                tooltip: 'Поделиться',
                icon: const Icon(Icons.share_outlined, size: 20),
                onPressed: () => shareHomework(context, lesson, date),
              ),
            ]),
            if (lesson.homework.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 10, top: 2),
                child: Text(lesson.homework, style: t.bodyMedium, maxLines: 6, overflow: TextOverflow.ellipsis),
              ),
            if (lesson.files.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 8, right: 10), child: AttachmentRow(files: lesson.files)),
          ]),
        ),
      ),
    );
  }
}

/// Day header: «Вторник, 17 ноября · сегодня» + share the whole day.
class DayHeader extends StatelessWidget {
  const DayHeader({super.key, required this.day, this.homeworkOnly = false, this.label});
  final Day day;
  final bool homeworkOnly;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final isToday = sameDay(day.date, today());
    final isTomorrow = sameDay(day.date, today().add(const Duration(days: 1)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 2),
      child: Row(children: [
        Expanded(
          child: Text(label ?? '${dayLong(day.date)}${isToday ? ' · сегодня' : (isTomorrow ? ' · завтра' : '')}',
              style: t.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: homeworkOnly ? 'Поделиться заданиями дня' : 'Поделиться днём',
          icon: const Icon(Icons.share_outlined, size: 20),
          onPressed: () => FileActions.shareText(homeworkOnly ? shareDayText(day) : shareDayFull(day)),
        ),
      ]),
    );
  }
}

Future<void> copyText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано'), duration: Duration(seconds: 1)));
  }
}

/// Share a homework: text only, text + files, or copy.
Future<void> shareHomework(BuildContext context, Lesson l, DateTime date) async {
  final text = shareLessonText(l, date);
  if (l.files.isEmpty) {
    await FileActions.shareText(text);
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.short_text),
          title: const Text('Текст задания'),
          subtitle: const Text('Дата, предмет, задание, названия файлов'),
          onTap: () {
            Navigator.pop(ctx);
            FileActions.shareText(text);
          },
        ),
        ListTile(
          leading: const Icon(Icons.attach_file),
          title: Text(l.files.length == 1 ? 'Текст и файл' : 'Текст и файлы (${l.files.length})'),
          subtitle: const Text('Файлы скачаются и отправятся вместе с текстом'),
          onTap: () {
            Navigator.pop(ctx);
            FileActions.shareFiles(context, l.files, text: text);
          },
        ),
        ListTile(
          leading: const Icon(Icons.copy),
          title: const Text('Копировать текст'),
          onTap: () {
            Navigator.pop(ctx);
            copyText(context, text);
          },
        ),
      ]),
    ),
  );
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
      final meta = lessonMeta(l);
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (ctx, controller) => SelectionArea(
          child: ListView(controller: controller, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
            Text(l.subject, style: t.headlineSmall),
            const SizedBox(height: 4),
            Text(
                [
                  dayLong(date),
                  if (l.isLesson && l.number.isNotEmpty) '${l.number} урок',
                  if (l.time.isNotEmpty) l.time,
                ].join(' · '),
                style: t.bodyMedium),
            if (meta.isNotEmpty) Text(meta, style: t.bodyMedium),
            if (l.absence.isNotEmpty) Text(l.absence, style: t.bodyMedium?.copyWith(color: Theme.of(ctx).colorScheme.error)),
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
              const SizedBox(height: 6),
              for (final m in l.marks)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    MarkChip(mark: m),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Text([
                      if (m.weight != 1) 'вес ${fmtWeight(m.weight)}',
                      if (m.comment.isNotEmpty) m.comment,
                    ].join(' · '))),
                  ]),
                ),
            ],
            const SizedBox(height: 20),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                  onPressed: () => FileActions.shareText(share),
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Поделиться')),
              if (l.files.isNotEmpty)
                OutlinedButton.icon(
                    onPressed: () => FileActions.shareFiles(ctx, l.files, text: share),
                    icon: const Icon(Icons.attach_file),
                    label: Text(l.files.length == 1 ? 'С файлом' : 'С файлами')),
              OutlinedButton.icon(
                  onPressed: () => copyText(ctx, l.homework.isEmpty ? share : l.homework),
                  icon: const Icon(Icons.copy),
                  label: const Text('Копировать')),
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

/// Offline / session banner shown on top of the tabs. Never blocks the cached data.
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final repo = Services.I.repo;
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final c = Theme.of(context).colorScheme;
        final t = Theme.of(context).textTheme;
        final updated = repo.lastSync == null ? 'нет данных' : 'обновлено ${ddmmhhmm(repo.lastSync!)}';
        if (repo.offline) {
          return Material(
            color: c.surfaceContainerHighest,
            child: InkWell(
              onTap: repo.refreshAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(children: [
                  Icon(Icons.cloud_off, size: 16, color: c.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Офлайн · $updated', style: t.bodySmall)),
                ]),
              ),
            ),
          );
        }
        if (repo.sessionExpired) {
          return MaterialBanner(
            backgroundColor: c.errorContainer,
            content: Text('Сессия Госуслуг истекла. Показаны сохранённые данные ($updated).'),
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
            content: Text('${repo.lastError}\nПоказаны сохранённые данные ($updated).', style: t.bodySmall),
            actions: [TextButton(onPressed: repo.refreshAll, child: const Text('Повторить'))],
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}
