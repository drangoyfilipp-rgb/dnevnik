import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/share_format.dart';
import '../services.dart';
import 'file_actions.dart';
import 'widgets.dart';

// ───────────────────────── Лента ─────────────────────────

class FeedTab extends StatelessWidget {
  const FeedTab({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = Services.I.repo;
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final t = Theme.of(context).textTheme;
        final days = repo.allDays();
        final now = today();
        final todayDay = days.where((d) => sameDay(d.date, now)).firstOrNull;
        final upcoming = days
            .where((d) => !d.date.isBefore(now) && d.lessons.any((l) => l.hasHomework))
            .take(6)
            .toList();
        final marks = repo.recentMarks(days: 10);
        final children = <Widget>[];
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Сегодня, ${dayMonth(now)}', style: t.titleMedium),
        ));
        if (todayDay == null || todayDay.lessons.isEmpty) {
          children.add(Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(todayDay?.holiday == true
                ? (todayDay!.holidayText.isEmpty ? 'Выходной' : todayDay.holidayText)
                : (days.isEmpty ? 'Загружаю дневник…' : 'Уроков нет')),
          ));
        } else {
          children.add(Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in todayDay.lessons)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        SizedBox(width: 24, child: Text(l.number, style: t.bodySmall)),
                        SizedBox(width: 92, child: Text(l.time, style: t.bodySmall)),
                        Expanded(child: Text(l.subject)),
                        ...l.marks.map((m) => Padding(padding: const EdgeInsets.only(left: 4), child: MarkChip(mark: m))),
                      ]),
                    ),
                ],
              ),
            ),
          ));
        }
        if (marks.isNotEmpty) {
          children.add(Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Новые оценки', style: t.titleMedium),
          ));
          children.add(Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: Column(children: [
                for (final m in marks.take(12))
                  ListTile(
                    dense: true,
                    leading: MarkChip(mark: m),
                    title: Text(m.subject.isEmpty ? '—' : m.subject),
                    subtitle: m.comment.isEmpty ? null : Text(m.comment),
                    trailing: m.date == null ? null : Text(dayMonth(m.date!), style: t.bodySmall),
                  ),
              ]),
            ),
          ));
        }
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Задано', style: t.titleMedium),
        ));
        if (upcoming.isEmpty) {
          children.add(const Padding(padding: EdgeInsets.all(16), child: Text('Ближайших заданий нет')));
        }
        for (final d in upcoming) {
          children.add(_DayHeader(day: d));
          for (final l in d.lessons.where((l) => l.hasHomework)) {
            children.add(LessonCard(lesson: l, date: d.date));
          }
        }
        children.add(const SizedBox(height: 24));
        return RefreshIndicator(
          onRefresh: repo.refreshAll,
          child: SelectionArea(child: ListView(children: children)),
        );
      },
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day});
  final Day day;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final isToday = sameDay(day.date, today());
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 0),
      child: Row(children: [
        Expanded(
          child: Text('${dayLong(day.date)}${isToday ? ' · сегодня' : ''}',
              style: t.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
        ),
        if (day.lessons.any((l) => l.hasHomework))
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Поделиться заданиями дня',
            icon: const Icon(Icons.share_outlined, size: 20),
            onPressed: () => FileActions.shareText(shareDayText(day)),
          ),
      ]),
    );
  }
}

// ───────────────────────── Расписание ─────────────────────────

class ScheduleTab extends StatefulWidget {
  const ScheduleTab({super.key});
  @override
  State<ScheduleTab> createState() => _ScheduleTabState();
}

class _ScheduleTabState extends State<ScheduleTab> {
  int _delta = 0;
  late DateTime _selected = today();
  final repo = Services.I.repo;

  @override
  void initState() {
    super.initState();
    if (_selected.weekday == DateTime.sunday) {
      _delta = 1;
      _selected = _selected.add(const Duration(days: 1));
    }
    repo.loadWeek(_delta);
  }

  void _setWeek(int d) {
    setState(() {
      final diff = d - _delta;
      _delta = d;
      _selected = _selected.add(Duration(days: 7 * diff));
    });
    repo.loadWeek(d);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final week = repo.weekAt(_delta);
        final monday = mondayOfNow().add(Duration(days: 7 * _delta));
        final day = week?.days.where((d) => sameDay(d.date, _selected)).firstOrNull;
        final c = Theme.of(context).colorScheme;
        return Column(children: [
          WeekNav(delta: _delta, onChanged: _setWeek),
          SizedBox(
            height: 64,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(6, (i) {
                final d = monday.add(Duration(days: i));
                final sel = sameDay(d, _selected);
                final isToday = sameDay(d, today());
                final hasHw = week?.days.where((x) => sameDay(x.date, d)).firstOrNull?.lessons.any((l) => l.hasHomework) ?? false;
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _selected = d),
                  child: Container(
                    width: 48,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: sel ? c.primaryContainer : null,
                      borderRadius: BorderRadius.circular(12),
                      border: isToday && !sel ? Border.all(color: c.primary) : null,
                    ),
                    child: Column(children: [
                      Text(weekdaysShort[i], style: Theme.of(context).textTheme.labelSmall),
                      Text('${d.day}', style: Theme.of(context).textTheme.titleMedium),
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: hasHw ? c.primary : Colors.transparent),
                      ),
                    ]),
                  ),
                );
              }),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => repo.loadWeek(_delta, force: true),
              child: SelectionArea(
                child: ListView(children: [
                  if (week == null)
                    EmptyState(
                      icon: Icons.cloud_download_outlined,
                      text: repo.busy ? 'Загружаю…' : 'Неделя ещё не загружена',
                      action: repo.busy
                          ? const CircularProgressIndicator()
                          : FilledButton.tonal(onPressed: () => repo.loadWeek(_delta, force: true), child: const Text('Загрузить')),
                    )
                  else if (day == null || day.lessons.isEmpty)
                    EmptyState(
                      icon: Icons.weekend_outlined,
                      text: day?.holiday == true ? (day!.holidayText.isEmpty ? 'Выходной' : day.holidayText) : 'Уроков нет',
                    )
                  else ...[
                    _DayHeader(day: day),
                    for (final l in day.lessons) LessonCard(lesson: l, date: day.date),
                  ],
                  if (week != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Обновлено ${timeAgo(week.fetchedAt)}',
                          textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                    ),
                ]),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

// ───────────────────────── Задания ─────────────────────────

class HomeworkTab extends StatefulWidget {
  const HomeworkTab({super.key});
  @override
  State<HomeworkTab> createState() => _HomeworkTabState();
}

class _HomeworkTabState extends State<HomeworkTab> {
  int _delta = 0;
  String? _subject;
  final repo = Services.I.repo;
  final settings = Services.I.settings;

  @override
  void initState() {
    super.initState();
    repo.loadWeek(_delta);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([repo, settings]),
      builder: (context, _) {
        final week = repo.weekAt(_delta);
        final allLessons = <(Day, Lesson)>[];
        for (final d in week?.days ?? const <Day>[]) {
          for (final l in d.lessons) {
            if (settings.hwOnlySubjectsWithHw && !l.hasHomework) continue;
            allLessons.add((d, l));
          }
        }
        final subjects = allLessons.map((e) => e.$2.subject).toSet().toList()..sort();
        final items = allLessons.where((e) => _subject == null || e.$2.subject == _subject).toList();
        final children = <Widget>[];
        if (settings.hwByWeek) {
          // By week: grouped by subject.
          final bySubject = <String, List<(Day, Lesson)>>{};
          for (final e in items) {
            bySubject.putIfAbsent(e.$2.subject, () => []).add(e);
          }
          for (final s in bySubject.keys.toList()..sort()) {
            children.add(Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(s, style: Theme.of(context).textTheme.titleSmall),
            ));
            for (final e in bySubject[s]!) {
              children.add(_HwTile(day: e.$1, lesson: e.$2));
            }
          }
        } else {
          Day? last;
          for (final e in items) {
            if (last == null || !sameDay(last.date, e.$1.date)) {
              children.add(_DayHeader(day: e.$1));
              last = e.$1;
            }
            children.add(LessonCard(lesson: e.$2, date: e.$1.date));
          }
        }
        return Column(children: [
          WeekNav(
              delta: _delta,
              onChanged: (d) {
                setState(() => _delta = d);
                repo.loadWeek(d);
              }),
          SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                    label: const Text('Все'), selected: _subject == null, onSelected: (_) => setState(() => _subject = null)),
              ),
              for (final s in subjects)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                      label: Text(s), selected: _subject == s, onSelected: (v) => setState(() => _subject = v ? s : null)),
                ),
            ]),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => repo.loadWeek(_delta, force: true),
              child: SelectionArea(
                child: ListView(children: [
                  if (week == null)
                    EmptyState(
                      icon: Icons.cloud_download_outlined,
                      text: repo.busy ? 'Загружаю…' : 'Неделя ещё не загружена',
                    )
                  else if (items.isEmpty)
                    const EmptyState(icon: Icons.task_alt, text: 'Заданий нет'),
                  ...children,
                  const SizedBox(height: 24),
                ]),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class _HwTile extends StatelessWidget {
  const _HwTile({required this.day, required this.lesson});
  final Day day;
  final Lesson lesson;
  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(lesson.homework.isEmpty ? 'Файлы' : lesson.homework, maxLines: 4, overflow: TextOverflow.ellipsis),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(dayLong(day.date)),
        if (lesson.files.isNotEmpty) AttachmentRow(files: lesson.files),
      ]),
      onTap: () => showLessonSheet(context, lesson, day.date),
    );
  }
}

// ───────────────────────── Оценки ─────────────────────────

class GradesTab extends StatefulWidget {
  const GradesTab({super.key});
  @override
  State<GradesTab> createState() => _GradesTabState();
}

class _GradesTabState extends State<GradesTab> {
  int _mode = 0; // 0 предметы, 1 итоговые
  final repo = Services.I.repo;
  final settings = Services.I.settings;

  @override
  void initState() {
    super.initState();
    if (repo.grades == null) repo.loadGrades();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([repo, settings]),
      builder: (context, _) {
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Текущие'), icon: Icon(Icons.list_alt)),
                ButtonSegment(value: 1, label: Text('Итоговые'), icon: Icon(Icons.emoji_events_outlined)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) {
                setState(() => _mode = s.first);
                if (_mode == 1 && repo.finals == null) repo.loadFinals();
              },
            ),
          ),
          Expanded(child: _mode == 0 ? _current(context) : _finals(context)),
        ]);
      },
    );
  }

  Widget _current(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final page = repo.grades;
    var subjects = page?.subjects ?? const <SubjectMarks>[];
    var fromDiary = false;
    if (subjects.isEmpty) {
      subjects = repo.marksFromDiary();
      fromDiary = subjects.isNotEmpty;
    }
    final avgs = subjects.map((s) => s.computedAverage).whereType<double>().toList();
    final overall = avgs.isEmpty ? null : avgs.reduce((a, b) => a + b) / avgs.length;
    final children = <Widget>[];
    if (page != null && page.periods.isNotEmpty) {
      children.add(SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final p in page.periods)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(label: Text(p.label), selected: p.selected, onSelected: (_) => repo.loadGrades(periodPath: p.path)),
            ),
        ]),
      ));
    }
    if (overall != null) {
      children.add(Card(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: ListTile(
          leading: const Icon(Icons.insights_outlined),
          title: Text('Средний балл: ${overall.toStringAsFixed(2)}'),
          subtitle: Text([
            if (page != null && page.periodTitle.isNotEmpty && !fromDiary) page.periodTitle,
            if (fromDiary) 'посчитано по загруженным неделям дневника',
            '${subjects.length} предм.',
          ].join(' · ')),
        ),
      ));
    }
    if (subjects.isEmpty) {
      children.add(EmptyState(
        icon: Icons.grade_outlined,
        text: repo.busy ? 'Загружаю оценки…' : 'Оценок пока нет. Если в официальном приложении они есть — откройте «Ещё → Диагностика».',
        action: repo.busy ? null : FilledButton.tonal(onPressed: () => repo.loadGrades(), child: const Text('Обновить')),
      ));
    } else if (settings.gradesByDate) {
      final all = subjects.expand((s) => s.marks).toList()
        ..sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
      for (final m in all) {
        children.add(ListTile(
          leading: MarkChip(mark: m),
          title: Text(m.subject),
          subtitle: m.comment.isEmpty ? null : Text(m.comment),
          trailing: m.date == null ? null : Text(dayMonth(m.date!), style: t.bodySmall),
        ));
      }
    } else {
      for (final s in subjects) {
        final avg = s.computedAverage;
        children.add(Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(s.subject, style: t.titleMedium)),
                if (s.average.isNotEmpty || avg != null)
                  Text(s.average.isNotEmpty ? s.average : avg!.toStringAsFixed(2),
                      style: t.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 4, runSpacing: 4, children: s.marks.map((m) => MarkChip(mark: m)).toList()),
            ]),
          ),
        ));
      }
    }
    children.add(const SizedBox(height: 24));
    return RefreshIndicator(
      onRefresh: () => repo.loadGrades(),
      child: SelectionArea(child: ListView(children: children)),
    );
  }

  Widget _finals(BuildContext context) {
    final f = repo.finals;
    final t = Theme.of(context).textTheme;
    if (f == null || f.rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: repo.loadFinals,
        child: ListView(children: [
          EmptyState(
            icon: Icons.emoji_events_outlined,
            text: repo.busy ? 'Загружаю…' : 'Итоговых оценок пока нет',
            action: repo.busy ? null : FilledButton.tonal(onPressed: repo.loadFinals, child: const Text('Обновить')),
          ),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: repo.loadFinals,
      child: SelectionArea(
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          for (final r in f.rows)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.subject, style: t.titleMedium),
                  const SizedBox(height: 6),
                  Wrap(spacing: 12, runSpacing: 6, children: [
                    for (var i = 0; i < r.values.length; i++)
                      if (r.values[i].isNotEmpty)
                        Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(i < f.headers.length ? f.headers[i] : '${i + 1}', style: t.labelSmall),
                          MarkChip(mark: Mark(value: r.values[i])),
                        ]),
                  ]),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}
