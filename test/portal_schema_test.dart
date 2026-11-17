// Synthetic JSON in the REAL «Госуслуги Моя школа» datamart structure, as seen in the
// build-3 Диагностика export (key names and types only; all values here are made up).
import 'dart:convert';

import 'package:dnevnik/core/models.dart';
import 'package:dnevnik/core/myschool.dart';
import 'package:dnevnik/core/settings.dart';
import 'package:dnevnik/core/share_format.dart';
import 'package:dnevnik/core/util.dart';
import 'package:flutter_test/flutter_test.dart';

import 'portal_fixtures.dart';

void main() {
  final day = [
    lesson('L1', '2026-11-17', 'Русский язык', room: '21'),
    lesson('L2', '2026-11-17', 'Информатика'),
    lesson('L3', '2026-11-17', 'География'),
    lesson('L4', '2026-11-17', 'Русский язык'),
    lesson('L5', '2026-11-17', 'ТИИ', skip: 'sk1'),
    lesson('L6', '2026-11-17', 'Обществознание'),
    lesson('L7', '2026-11-17', 'Обществознание'),
  ];

  DatamartStore store0() => DatamartStore()
    ..applyResponse([
      dm('student_lessons', '2651', day),
      // The same lessons arrive again in an overlapping interval (web app asks both).
      dm('student_lessons', '2652', [...day, lesson('L8', '2026-11-24', 'Алгебра', start: '08:00:00', end: '08:45:00')]),
      dm('student_marks', '2651', [
        mark('M1', '2026-11-17', 'Русский язык', '5', weight: '2', lessonId: 'L1', work: 'Контрольная работа'),
        mark('M2', '2026-11-10', 'Русский язык', '4', weight: null),
        mark('M3', '2026-10-10', 'Русский язык', '3', period: 'P1'),
      ]),
      dm('student_marks', '2652', [mark('M1', '2026-11-17', 'Русский язык', '5', weight: '2', lessonId: 'L1')]),
      dm('student_homeworks_materials', '2651', [
        homework('H1', '2026-11-14', '2026-11-17', 'Информатика', 'Решить задачи 1–5', readyLesson: 'L2', materials: [
          {'name': 'Задачи.pdf', 'size': 20480, 'link': 'https://www.gosuslugi.ru/api/myschool/v1/files/abc', 'id': 'f1'},
        ]),
        homework('H2', '2026-11-14', '2026-11-17', 'Обществознание', 'Читать §17'),
        homework('H3', '2026-11-17', '2026-11-19', 'Биология', 'Таблица'),
      ]),
      dm('student_classes', '2026', [classes()]),
    ]);

  group('real portal structure', () {
    test('placeholder times → numbers only; duplicates removed; room, teacher, absence', () {
      final d = buildDiary(store0(), now: DateTime(2026, 11, 17));
      final tue = d.days.firstWhere((x) => x.date == DateTime(2026, 11, 17));
      expect(tue.lessons.where((l) => l.isLesson).length, 7, reason: 'two intervals carry the same lessons');
      expect(tue.lessons.map((l) => l.subject).take(4).toList(), ['Русский язык', 'Информатика', 'География', 'Русский язык']);
      expect(tue.lessons.map((l) => l.number).take(7).toList(), ['1', '2', '3', '4', '5', '6', '7']);
      expect(tue.lessons.every((l) => l.time.isEmpty), isTrue, reason: 'never a fake 08:30–09:15 for every lesson');
      expect(tue.lessons.first.room, '21');
      expect(tue.lessons.first.teacher, 'Петрова А. И.');
      expect(tue.lessons[4].absence, 'Болезнь');
      expect(d.timesFromBells, isFalse);
    });

    test('bell schedule fills the times', () {
      final d = buildDiary(store0(), bells: ['08:00–08:45', '08:55–09:40'], now: DateTime(2026, 11, 17));
      final tue = d.days.firstWhere((x) => x.date == DateTime(2026, 11, 17));
      expect(tue.lessons[0].time, '08:00–08:45');
      expect(tue.lessons[1].time, '08:55–09:40');
      expect(tue.lessons[2].time, '');
      expect(d.timesFromBells, isTrue);
    });

    test('real distinct times are kept and sorted', () {
      final d = buildDiaryFrom(lessons: [
        lesson('A', '2026-11-18', 'Физика', start: '09:40:00', end: '10:25:00'),
        lesson('B', '2026-11-18', 'Алгебра', start: '08:00:00+03:00', end: '08:45:00+03:00'),
      ]);
      expect(parseLooseDateTime('2026-11-18T00:00:00+03:00'), DateTime(2026, 11, 18));
      final l = d.days.single.lessons;
      expect(l.map((x) => x.subject).toList(), ['Алгебра', 'Физика']);
      expect(l.first.time, '08:00–08:45');
      expect(l.first.number, '1');
      expect(l.last.time, '09:40–10:25');
    });

    test('homework: due lesson, plan_ready_date, materials with size', () {
      final d = buildDiary(store0(), now: DateTime(2026, 11, 17));
      final tue = d.days.firstWhere((x) => x.date == DateTime(2026, 11, 17));
      final inf = tue.lessons[1];
      expect(inf.homework, 'Решить задачи 1–5');
      expect(inf.files.single.name, 'Задачи.pdf');
      expect(inf.files.single.size, 20480);
      expect(inf.files.single.url, 'https://www.gosuslugi.ru/api/myschool/v1/files/abc');
      expect(tue.lessons[5].homework, 'Читать §17', reason: 'linked by date + subject to the first Обществознание');
      expect(tue.lessons[6].homework, '');
      final thu = d.days.firstWhere((x) => x.date == DateTime(2026, 11, 19));
      expect(thu.lessons.single.isLesson, isFalse);
      expect(thu.lessons.single.subject, 'Биология');
    });

    test('marks: mark_value1, weight, work type, lesson link, dedupe, periods', () {
      final d = buildDiary(store0(), now: DateTime(2026, 11, 17));
      final rus = d.subjects.single;
      expect(rus.subject, 'Русский язык');
      expect(rus.marks.map((m) => m.value).toList(), ['3', '4', '5']);
      final five = rus.marks.last;
      expect(five.weight, 2);
      expect(five.comment, 'Контрольная работа');
      expect(five.periodId, 'P2');
      expect(rus.marks[1].weight, 1, reason: 'null weight = 1');
      final tue = d.days.firstWhere((x) => x.date == DateTime(2026, 11, 17));
      expect(tue.lessons.first.marks.single.value, '5');
      expect(d.periods.map((p) => p.label).toList(), ['1 четверть', '2 четверть', '3 четверть', '4 четверть']);
      final p2 = periodAt(d.periods, DateTime(2026, 11, 17))!;
      expect(p2.label, '2 четверть');
      expect(marksInPeriod(rus.marks, p2).map((m) => m.value).toList(), ['4', '5']);
    });

    test('no official finals → forecast per started period and year', () {
      final d = buildDiary(store0(), now: DateTime(2026, 11, 17));
      final f = d.finals!;
      expect(f.forecast, isTrue);
      expect(f.headers, ['1 четверть', '2 четверть', 'Год']);
      final r = f.rows.single;
      // P2: (4×1 + 5×2) / 3 = 4.67 → 5; P1: 3; year: (3 + 4 + 10) / 4 = 4.25 → 4.
      expect(r.values, ['3', '5', '4']);
      expect(r.notes[1], '4.67');
      expect(roundedMark(3.5), '4');
      expect(roundedMark(3.49), '3');
    });

    test('week interval model from stored intervals', () {
      final s = DatamartStore()
        ..applyResponse([
          dm('student_lessons', '2651', [lesson('a', '2026-11-17', 'X')]),
          dm('student_lessons', '2653', [lesson('b', '2026-12-01', 'X')]),
        ]);
      final m = s.weekModel!;
      expect(m.idFor(DateTime(2026, 11, 24)), '2652');
      expect(m.idFor(DateTime(2026, 11, 10)), '2650');

      final ymd = WeekIntervalModel.fit([IntervalSpan('20261116', DateTime(2026, 11, 16), DateTime(2026, 11, 21), 30)])!;
      expect(ymd.idFor(DateTime(2026, 12, 2)), '20261130');

      final epoch = DateTime(2026, 11, 16).millisecondsSinceEpoch ~/ 1000;
      final ep = WeekIntervalModel.fit([IntervalSpan('$epoch', DateTime(2026, 11, 16), DateTime(2026, 11, 20), 30)])!;
      expect(ep.idFor(DateTime(2026, 11, 23)), '${epoch + 604800}');

      // A single opaque id or a month-long interval → no guessing.
      expect(WeekIntervalModel.fit([IntervalSpan('77', DateTime(2026, 11, 16), DateTime(2026, 11, 20), 3)]), isNull);
      expect(WeekIntervalModel.fit([IntervalSpan('5', DateTime(2026, 11, 2), DateTime(2026, 11, 28), 3)]), isNull);
    });

    test('replay: all stored intervals with hashes, chunked; finals only as probes', () {
      final s = store0()
        ..learnRequest([
          {'interval_id': '2651', 'obj_type': 'student_marks', 'student_id': sid},
        ]);
      final bodies = s.buildRequests(chunk: 4);
      final items = bodies.expand((b) => b).toList();
      expect(bodies.every((b) => b.length <= 4), isTrue);
      expect(items.every((i) => (i['interval_id'] ?? '') != ''), isTrue);
      expect(items.where((i) => kFinalObjTypes.contains(i['obj_type'])), isEmpty);
      expect(items.firstWhere((i) => i['obj_type'] == 'student_classes')['hash'], 'H-student_classes-2026');
      expect(items.map((i) => '${i['obj_type']}|${i['interval_id']}').toSet().length, items.length);

      s.currentYear = '2026';
      final probes = s.finalProbes(now: DateTime(2026, 11, 17));
      expect(probes.map((p) => p['obj_type']).toSet(), {'student_pmarks', 'student_ymarks'});
      expect(probes.first['interval_id'], '2026');
      expect(probes.every((p) => p['student_id'] == sid), isTrue);
      for (var round = 0; round < 5; round++) {
        for (final p in s.finalProbes(now: DateTime(2026, 11, 17))) {
          s.failedProbes['${p['obj_type']}|${p['interval_id']}'] = DateTime(2026, 11, 17).toIso8601String();
        }
      }
      expect(s.finalProbes(now: DateTime(2026, 11, 18)), isEmpty);
      expect(s.finalProbes(now: DateTime(2026, 11, 21)), isNotEmpty);
      final back = DatamartStore.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.failedProbes.length, s.failedProbes.length);
      expect(back.currentYear, '2026');
    });

    test('official pmarks are labelled by period_id', () {
      final f = buildFinals(
        pmarks: [
          {'subject_name': 'Алгебра', 'mark_value1': '4', 'period_id': 'P1'},
        ],
        periods: parsePeriods([classes()]),
      )!;
      expect(f.headers, ['1 четверть']);
      expect(f.rows.single.values, ['4']);
    });

    test('summary has no values', () {
      final text = store0().summary();
      expect(text, contains('интервалы недель'));
      expect(text, isNot(contains('Русский')));
      expect(text, isNot(contains('2651')));
    });
  });

  group('share', () {
    test('whole day, subject marks, all marks', () {
      final d = buildDiary(store0(), now: DateTime(2026, 11, 17));
      final tue = d.days.firstWhere((x) => x.date == DateTime(2026, 11, 17));
      final text = shareDayFull(tue);
      expect(text, startsWith('Вт, 17.11\n1. Русский язык, каб. 21'));
      expect(text, contains('2. Информатика\n   ДЗ: Решить задачи 1–5\n   Файлы: Задачи.pdf'));
      expect(text, contains('   Оценки: 5'));
      expect(text, isNot(contains('http')));

      final s = shareSubjectMarks(d.subjects.single, period: '2 четверть');
      expect(s, startsWith('Русский язык · 2 четверть\nОценки: 3, 4, 5×2\nСредний балл: 4,25'));
      expect(s, contains('17.11 — 5 (Контрольная работа, вес 2)'));
      expect(shareAllMarks(d.subjects), 'Оценки\nРусский язык: 3 4 5 — 4,25');
      expect(shareSubjectMarks(const SubjectMarks(subject: 'X', marks: [])), 'X\nОценок нет');
    });
  });

  test('bell schedule parsing', () {
    expect(parseBells('8:00-8:45\n08.55 – 09.40\n\n3) 9:50-10:35'), ['08:00–08:45', '08:55–09:40', '09:50–10:35']);
    expect(parseBells(''), <String>[]);
    expect(parseBells('утро'), isNull);
    expect(parseBells('09:00-08:00'), isNull);
  });
}
