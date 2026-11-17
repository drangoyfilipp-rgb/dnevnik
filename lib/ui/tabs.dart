import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/myschool.dart';
import '../core/share_format.dart';
import '../services.dart';
import 'file_actions.dart';
import 'widgets.dart';

String _periodRange(StudyPeriod p) => '${dayMonth(p.start)} — ${dayMonth(p.end)}';

Widget _sectionTitle(BuildContext context, String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 4, 4),
      child: Row(children: [
        Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
        ?trailing,
      ]),
    );

// ───────────────────────── Лента ─────────────────────────

class FeedTab extends StatelessWidget {
  const FeedTab({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = Services.I.repo;
    return ListenableBuilder(
      listenable: Listenable.merge([repo, Services.I.settings]),
      builder: (context, _) {
        final days = repo.allDays();
        final now = today();
        final todayDay = days.where((d) => sameDay(d.date, now) && d.lessons.any((l) => l.isLesson)).firstOrNull;
        final nextDay = days.where((d) => d.date.isAfter(now) && d.lessons.any((l) => l.isLesson)).firstOrNull;
        final upcoming = days.where((d) => d.date.isAfter(now) && d.lessons.any((l) => l.hasHomework)).take(3).toList();
        final marks = repo.recentMarks(days: 10);
        final children = <Widget>[];

        Widget dayCard(Day d) => Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              elevation: 0,
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(children: [
                  for (final l in d.lessons.where((l) => l.isLesson))
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: LessonNumber(l.number),
                      title: Row(children: [
                        Flexible(child: Text(l.subject, style: const TextStyle(fontWeight: FontWeight.w600))),
                        if (l.hasHomework) ...[const SizedBox(width: 6), const SmallTag('ДЗ')],
                      ]),
                      subtitle: Text([if (l.time.isNotEmpty) l.time, if (l.room.isNotEmpty) 'каб. ${l.room}'].join(' · ')),
                      trailing: l.marks.isEmpty
                          ? null
                          : Wrap(spacing: 4, children: l.marks.map((m) => MarkChip(mark: m, size: 28)).toList()),
                      onTap: () => showLessonSheet(context, l, d.date),
                    ),
                ]),
              ),
            );

        if (todayDay != null) {
          children.add(DayHeader(day: todayDay, label: 'Сегодня, ${dayMonth(now)}'));
          children.add(dayCard(todayDay));
        } else {
          children.add(_sectionTitle(context, 'Сегодня, ${dayMonth(now)}'));
          children.add(Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(days.isEmpty
                ? (repo.busy ? 'Загружаю дневник…' : 'Данных пока нет — потяните вниз, чтобы обновить')
                : 'Уроков нет'),
          ));
        }
        if (nextDay != null && (todayDay == null || DateTime.now().hour >= 14)) {
          children.add(DayHeader(day: nextDay));
          children.add(dayCard(nextDay));
        }
        if (marks.isNotEmpty) {
          children.add(_sectionTitle(context, 'Новые оценки'));
          children.add(Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Column(children: [
              for (final m in marks.take(10))
                ListTile(
                  dense: true,
                  leading: MarkChip(mark: m, size: 30),
                  title: Text(m.subject.isEmpty ? '—' : m.subject, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: m.comment.isEmpty ? null : Text(m.comment, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: m.date == null ? null : Text(dayMonth(m.date!), style: Theme.of(context).textTheme.bodySmall),
                ),
            ]),
          ));
        }
        children.add(_sectionTitle(context, 'Задано'));
        if (upcoming.isEmpty) {
          children.add(const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 8), child: Text('Ближайших заданий нет')));
        }
        for (final d in upcoming) {
          children.add(DayHeader(day: d, homeworkOnly: true));
          for (final l in d.lessons.where((l) => l.hasHomework)) {
            children.add(HomeworkCard(lesson: l, date: d.date));
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

  void _step(int days) {
    var d = _selected.add(Duration(days: days));
    if (d.weekday == DateTime.sunday) d = d.add(Duration(days: days > 0 ? 1 : -1));
    final monday = mondayOfNow().add(Duration(days: 7 * _delta));
    final newDelta = _delta + (d.difference(monday).inDays / 7).floor();
    setState(() {
      _selected = d;
      if (newDelta != _delta) {
        _delta = newDelta;
        repo.loadWeek(newDelta);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([repo, Services.I.settings]),
      builder: (context, _) {
        final week = repo.weekAt(_delta);
        final monday = mondayOfNow().add(Duration(days: 7 * _delta));
        final day = week?.days.where((d) => sameDay(d.date, _selected)).firstOrNull;
        final c = Theme.of(context).colorScheme;
        final t = Theme.of(context).textTheme;
        final lessons = day?.lessons ?? const <Lesson>[];
        final showTimeHint = lessons.isNotEmpty &&
            lessons.where((l) => l.isLesson).every((l) => l.time.isEmpty) &&
            Services.I.settings.bells.isEmpty;
        return Column(children: [
          WeekNav(delta: _delta, onChanged: _setWeek),
          SizedBox(
            height: 70,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(6, (i) {
                final d = monday.add(Duration(days: i));
                final sel = sameDay(d, _selected);
                final isToday = sameDay(d, today());
                final dd = week?.days.where((x) => sameDay(x.date, d)).firstOrNull;
                final hasHw = dd?.lessons.any((l) => l.hasHomework) ?? false;
                final hasMarks = dd?.lessons.any((l) => l.marks.isNotEmpty) ?? false;
                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => setState(() => _selected = d),
                  child: Container(
                    width: 50,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: sel ? c.primary : (isToday ? c.primaryContainer : null),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(children: [
                      Text(weekdaysShort[i],
                          style: t.labelSmall?.copyWith(color: sel ? c.onPrimary : c.onSurfaceVariant)),
                      Text('${d.day}',
                          style: t.titleMedium?.copyWith(color: sel ? c.onPrimary : null, fontWeight: FontWeight.w700)),
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        for (final on in [hasHw, hasMarks])
                          if (on)
                            Container(
                              width: 5,
                              height: 5,
                              margin: const EdgeInsets.symmetric(horizontal: 1.5),
                              decoration: BoxDecoration(shape: BoxShape.circle, color: sel ? c.onPrimary : c.primary),
                            ),
                      ]),
                    ]),
                  ),
                );
              }),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: (e) {
                final v = e.primaryVelocity ?? 0;
                if (v.abs() < 300) return;
                _step(v < 0 ? 1 : -1);
              },
              child: RefreshIndicator(
                onRefresh: () => repo.loadWeek(_delta, force: true),
                child: SelectionArea(
                  child: ListView(children: [
                    if (week == null)
                      EmptyState(
                        icon: repo.offline ? Icons.cloud_off : Icons.cloud_download_outlined,
                        text: repo.busy
                            ? 'Загружаю…'
                            : (repo.offline ? 'Нет сохранённых данных за эту неделю' : 'Данных за эту неделю нет'),
                        action: repo.busy
                            ? const CircularProgressIndicator()
                            : (repo.offline
                                ? null
                                : FilledButton.tonal(
                                    onPressed: () => repo.loadWeek(_delta, force: true), child: const Text('Обновить'))),
                      )
                    else if (day == null || day.lessons.isEmpty)
                      EmptyState(
                        icon: Icons.weekend_outlined,
                        text: day?.holiday == true ? (day!.holidayText.isEmpty ? 'Выходной' : day.holidayText) : 'Уроков нет',
                      )
                    else ...[
                      DayHeader(day: day),
                      for (final l in day.lessons) LessonCard(lesson: l, date: day.date),
                    ],
                    if (showTimeHint)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: InkWell(
                          onTap: () => _bellsHint(context),
                          child: Text('Время уроков школа на портале не указала — можно задать звонки в Настройках.',
                              textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                        ),
                      ),
                    if (week != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text('Обновлено ${timeAgo(week.fetchedAt)}', textAlign: TextAlign.center, style: t.bodySmall),
                      ),
                  ]),
                ),
              ),
            ),
          ),
        ]);
      },
    );
  }

  void _bellsHint(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Ещё → Настройки → Расписание звонков'),
      duration: Duration(seconds: 3),
    ));
  }
}

// ───────────────────────── Задания ─────────────────────────

class HomeworkTab extends StatefulWidget {
  const HomeworkTab({super.key});
  @override
  State<HomeworkTab> createState() => _HomeworkTabState();
}

class _HomeworkTabState extends State<HomeworkTab> {
  int _mode = 0; // 0 задано, 1 прошедшие
  String? _subject;
  final repo = Services.I.repo;
  final settings = Services.I.settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([repo, settings]),
      builder: (context, _) {
        final now = today();
        final all = <(Day, Lesson)>[];
        for (final d in repo.allDays()) {
          final upcoming = !d.date.isBefore(now);
          if ((_mode == 0) != upcoming) continue;
          for (final l in d.lessons) {
            if (l.hasHomework) all.add((d, l));
          }
        }
        if (_mode == 1) {
          all.sort((a, b) => b.$1.date.compareTo(a.$1.date));
        }
        final subjects = all.map((e) => e.$2.subject).toSet().toList()..sort();
        if (_subject != null && !subjects.contains(_subject)) _subject = null;
        final items = all.where((e) => _subject == null || e.$2.subject == _subject).toList();
        final children = <Widget>[];
        if (settings.hwByWeek) {
          final bySubject = <String, List<(Day, Lesson)>>{};
          for (final e in items) {
            bySubject.putIfAbsent(e.$2.subject, () => []).add(e);
          }
          for (final s in bySubject.keys.toList()..sort()) {
            children.add(_sectionTitle(context, s));
            for (final e in bySubject[s]!) {
              children.add(HomeworkCard(lesson: e.$2, date: e.$1.date, showDate: true));
            }
          }
        } else {
          Day? last;
          for (final e in items) {
            if (last == null || !sameDay(last.date, e.$1.date)) {
              final dayItems = Day(
                date: e.$1.date,
                title: e.$1.title,
                lessons: e.$1.lessons.where((l) => _subject == null || l.subject == _subject).toList(),
              );
              children.add(DayHeader(day: dayItems, homeworkOnly: true));
              last = e.$1;
            }
            children.add(HomeworkCard(lesson: e.$2, date: e.$1.date));
          }
        }
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('Задано')),
                ButtonSegment(value: 1, label: Text('Прошедшие')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
          if (subjects.length > 1)
            SizedBox(
              height: 46,
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
              onRefresh: repo.refreshAll,
              child: SelectionArea(
                child: ListView(children: [
                  if (items.isEmpty)
                    EmptyState(
                      icon: repo.offline ? Icons.cloud_off : Icons.task_alt,
                      text: repo.busy && repo.allDays().isEmpty
                          ? 'Загружаю…'
                          : (_mode == 0 ? 'Заданий пока нет' : 'Прошедших заданий нет'),
                    ),
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

// ───────────────────────── Оценки ─────────────────────────

class GradesTab extends StatefulWidget {
  const GradesTab({super.key});
  @override
  State<GradesTab> createState() => _GradesTabState();
}

class _GradesTabState extends State<GradesTab> {
  int _mode = 0; // 0 текущие, 1 итоговые
  String? _periodId; // null = current period; '' = весь год
  int? _finalCol;
  final repo = Services.I.repo;
  final settings = Services.I.settings;

  StudyPeriod? _period() {
    final ps = repo.periods;
    if (ps.isEmpty || _periodId == '') return null;
    if (_periodId != null) {
      final p = ps.where((p) => '${p.id}|${p.start}' == _periodId).firstOrNull;
      if (p != null) return p;
    }
    return periodAt(ps, DateTime.now());
  }

  List<SubjectMarks> _subjects(StudyPeriod? p) {
    final all = repo.grades?.subjects ?? repo.marksFromDiary();
    if (p == null) return all;
    return [
      for (final s in all)
        if (marksInPeriod(s.marks, p).isNotEmpty) SubjectMarks(subject: s.subject, marks: marksInPeriod(s.marks, p)),
    ];
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
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('Текущие'), icon: Icon(Icons.grid_view_outlined)),
                ButtonSegment(value: 1, label: Text('Итоговые'), icon: Icon(Icons.emoji_events_outlined)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
          Expanded(child: _mode == 0 ? _current(context) : _finals(context)),
        ]);
      },
    );
  }

  Widget _periodChips(BuildContext context, StudyPeriod? selected) {
    final ps = repo.periods;
    if (ps.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 46,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
        for (final p in ps)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(p.label),
              selected: selected == p,
              onSelected: (_) => setState(() => _periodId = '${p.id}|${p.start}'),
            ),
          ),
        ChoiceChip(label: const Text('Год'), selected: selected == null, onSelected: (_) => setState(() => _periodId = '')),
      ]),
    );
  }

  Widget _current(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final period = _period();
    final subjects = _subjects(period);
    final allMarks = subjects.expand((s) => s.marks).toList();
    final avgs = subjects.map((s) => s.computedAverage).whereType<double>().toList();
    final overall = avgs.isEmpty ? null : avgs.reduce((a, b) => a + b) / avgs.length;
    final periodText = period == null ? (repo.periods.isEmpty ? '' : 'Год') : period.label;
    final children = <Widget>[_periodChips(context, period)];
    if (subjects.isNotEmpty) {
      children.add(Card(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        elevation: 0,
        color: c.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(children: [
            Text(overall == null ? '—' : fmtAvg(overall),
                style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w800, color: avgColor(context, overall))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('средний балл по предметам', style: TextStyle(fontWeight: FontWeight.w600)),
                Text(
                    [
                      if (period != null) _periodRange(period) else if (periodText.isNotEmpty) periodText,
                      '${allMarks.length} оц.',
                    ].join(' · '),
                    style: t.bodySmall),
              ]),
            ),
            IconButton(
              tooltip: 'Поделиться всеми оценками',
              icon: const Icon(Icons.share_outlined),
              onPressed: () => FileActions.shareText(shareAllMarks(subjects, period: periodText)),
            ),
          ]),
        ),
      ));
    }
    if (subjects.isEmpty) {
      children.add(EmptyState(
        icon: Icons.grade_outlined,
        text: repo.busy
            ? 'Загружаю оценки…'
            : (period != null && (repo.grades?.subjects.isNotEmpty ?? false)
                ? 'За ${period.label} оценок пока нет'
                : 'Оценок пока нет. Если в официальном приложении они есть — отправьте «Ещё → Диагностика → Экспорт».'),
        action: repo.busy || repo.offline
            ? null
            : FilledButton.tonal(onPressed: repo.refreshAll, child: const Text('Обновить')),
      ));
    } else if (settings.gradesByDate) {
      allMarks.sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
      for (final m in allMarks) {
        children.add(ListTile(
          leading: MarkChip(mark: m),
          title: Text(m.subject, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: m.comment.isEmpty ? null : Text(m.comment),
          trailing: m.date == null ? null : Text(dayMonth(m.date!), style: t.bodySmall),
        ));
      }
    } else {
      for (final s in subjects) {
        final avg = s.computedAverage;
        children.add(Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          elevation: 0,
          color: c.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => SubjectMarksScreen(subject: s, period: periodText))),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 4, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(s.subject, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
                  if (avg != null)
                    Text(fmtAvg(avg), style: t.titleMedium?.copyWith(color: avgColor(context, avg), fontWeight: FontWeight.w800)),
                  IconButton(
                    tooltip: 'Поделиться',
                    icon: const Icon(Icons.share_outlined, size: 20),
                    onPressed: () => FileActions.shareText(shareSubjectMarks(s, period: periodText)),
                  ),
                ]),
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Wrap(spacing: 8, runSpacing: 8, children: s.marks.map((m) => MarkChip(mark: m)).toList()),
                ),
              ]),
            ),
          ),
        ));
      }
    }
    children.add(const SizedBox(height: 24));
    return RefreshIndicator(
      onRefresh: repo.refreshAll,
      child: SelectionArea(child: ListView(children: children)),
    );
  }

  Widget _finals(BuildContext context) {
    final f = repo.finals;
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    if (f == null || f.rows.isEmpty || f.headers.isEmpty) {
      return RefreshIndicator(
        onRefresh: repo.refreshAll,
        child: ListView(children: [
          EmptyState(
            icon: Icons.emoji_events_outlined,
            text: repo.busy ? 'Загружаю…' : 'Итоговых оценок пока нет',
            action: repo.busy || repo.offline ? null : FilledButton.tonal(onPressed: repo.refreshAll, child: const Text('Обновить')),
          ),
        ]),
      );
    }
    var col = _finalCol;
    if (col == null || col >= f.headers.length) {
      final cur = periodAt(repo.periods, DateTime.now());
      final i = cur == null ? -1 : f.headers.indexOf(cur.label);
      col = i >= 0 ? i : f.headers.length - 1;
    }
    final rows = f.rows.where((r) => col! < r.values.length && r.values[col].isNotEmpty).toList();
    return RefreshIndicator(
      onRefresh: repo.refreshAll,
      child: SelectionArea(
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          SizedBox(
            height: 46,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (var i = 0; i < f.headers.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: Text(f.headers[i]), selected: i == col, onSelected: (_) => setState(() => _finalCol = i)),
                ),
            ]),
          ),
          if (f.forecast)
            Card(
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              elevation: 0,
              color: c.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Icon(Icons.auto_graph, color: c.onSecondaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Прогноз по текущим оценкам (средний балл с весами, округление от ,5). '
                        'Официальные итоговые появятся, когда их выставят.',
                        style: t.bodySmall?.copyWith(color: c.onSecondaryContainer)),
                  ),
                ]),
              ),
            ),
          if (rows.isEmpty) const EmptyState(icon: Icons.emoji_events_outlined, text: 'За этот период оценок нет'),
          for (final r in rows)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              elevation: 0,
              color: c.surfaceContainerLow,
              child: ListTile(
                leading: MarkChip(mark: Mark(value: r.values[col]), forecast: f.forecast),
                title: Text(r.subject, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: col < r.notes.length && r.notes[col].isNotEmpty
                    ? Text('средний ${r.notes[col].replaceAll('.', ',')}')
                    : null,
              ),
            ),
        ]),
      ),
    );
  }
}

/// One subject: all marks with date, kind and weight; average; share.
class SubjectMarksScreen extends StatelessWidget {
  const SubjectMarksScreen({super.key, required this.subject, this.period = ''});
  final SubjectMarks subject;
  final String period;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final avg = subject.computedAverage;
    final marks = subject.marks.toList()..sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
    final text = shareSubjectMarks(subject, period: period);
    return Scaffold(
      appBar: AppBar(
        title: Text(subject.subject),
        actions: [
          IconButton(tooltip: 'Копировать', icon: const Icon(Icons.copy), onPressed: () => copyText(context, text)),
          IconButton(tooltip: 'Поделиться', icon: const Icon(Icons.share_outlined), onPressed: () => FileActions.shareText(text)),
        ],
      ),
      body: SelectionArea(
        child: ListView(children: [
          ListTile(
            title: Text(avg == null ? '—' : fmtAvg(avg),
                style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w800, color: avgColor(context, avg))),
            subtitle: Text(['средний балл', if (period.isNotEmpty) period, '${marks.length} оц.'].join(' · ')),
          ),
          const Divider(height: 1),
          for (final m in marks)
            ListTile(
              leading: MarkChip(mark: m),
              title: Text(m.comment.isEmpty ? 'Оценка' : m.comment),
              subtitle: Text([if (m.date != null) dayLong(m.date!), if (m.weight != 1) 'вес ${fmtWeight(m.weight)}'].join(' · ')),
            ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}
