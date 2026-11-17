// Parsers for «Госуслуги Моя школа» datamart answers, on SYNTHETIC JSON
// (field names are not documented; two schema variants are covered).
import 'dart:convert';

import 'package:dnevnik/core/bridge.dart';
import 'package:dnevnik/core/myschool.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> item(String type, String status, List<Map<String, dynamic>> data,
        {String hash = 'h1', String? prev, String interval = 'I1'}) =>
    {
      'obj_type': type,
      'student_id': 777001,
      'interval_id': interval,
      'hash': hash,
      'prev_hash': prev,
      'data_status': status,
      'data': data,
    };

void main() {
  group('datamart store', () {
    test('snapshot, delta with delete, actual', () {
      final s = DatamartStore();
      final r = s.applyResponse([
        item('student_marks', 'snapshot', [
          {'obj_id': 'm1', 'value': 5, 'subject_name': 'Алгебра', 'date': '2026-11-10'},
          {'obj_id': 'm2', 'value': 4, 'subject_name': 'Физика', 'date': '2026-11-11'},
        ]),
      ]);
      expect(r.items, 1);
      expect(s.objectsOf('student_marks').length, 2);
      expect(s.studentId, '777001');

      s.applyResponse([
        item('student_marks', 'delta', [
          {'obj_id': 'm2', 'obj_action': 'delete'},
          {'obj_id': 'm3', 'value': 3, 'subject_name': 'Химия', 'date': '2026-11-12'},
        ], hash: 'h2', prev: 'h1'),
      ]);
      expect(s.objectsOf('student_marks').map((o) => o['obj_id']).toSet(), {'m1', 'm3'});
      expect(s.entries.values.single.hash, 'h2');

      s.applyResponse([item('student_marks', 'actual', const [], hash: 'h2')]);
      expect(s.objectsOf('student_marks').length, 2);

      // A delta from another base (web app state) keeps objects but drops our hash.
      s.applyResponse([
        item('student_marks', 'delta', [
          {'obj_id': 'm4', 'value': 5, 'subject_name': 'Химия'},
        ], hash: 'h9', prev: 'hX'),
      ], ourRequest: false);
      expect(s.objectsOf('student_marks').length, 3);
      expect(s.entries.values.single.hash, isNull);
    });

    test('answer wrapped in an object; error status', () {
      final s = DatamartStore();
      final r = s.applyResponse({
        'result': [
          item('student_lessons', 'error', const []),
          item('student_pmarks', 'snapshot', [
            {'id': 1, 'mark': '5', 'subject': 'Алгебра', 'period_name': '1 четверть'},
          ]),
        ]
      });
      expect(r.items, 2);
      expect(r.errors, ['student_lessons: error']);
      expect(s.objectsOf('student_pmarks').length, 1);
    });

    test('learned requests are replayed with stored hashes', () {
      final s = DatamartStore();
      expect(s.buildRequests(), isEmpty);
      s.learnRequest([
        {'obj_type': 'student_lessons', 'student_id': 777001, 'interval_id': 'I1', 'hash': 'web'},
        {'obj_type': 'student_events', 'student_id': 777001, 'hash': null},
      ]);
      s.applyResponse([item('student_lessons', 'snapshot', const [], hash: 'ours')]);
      final bodies = s.buildRequests();
      final first = bodies.first;
      expect(first.length, 1, reason: 'unwanted obj_types are not replayed');
      expect(first.single['interval_id'], 'I1');
      expect(first.single['hash'], 'ours');
      // Other wanted types are asked without interval, with the learned student id.
      final extra = bodies.last.map((i) => i['obj_type']).toSet();
      expect(extra, containsAll(['student_homeworks_materials', 'student_marks', 'student_pmarks', 'student_ymarks']));
      expect(bodies.last.first['student_id'], 777001);

      // JSON round trip keeps everything.
      final back = DatamartStore.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.requests.length, 1);
      expect(back.buildRequests().first.single['hash'], 'ours');
    });

    test('student id from auth/student', () {
      final s = DatamartStore()..learnStudent({'students': [{'id': 42, 'name': 'X'}]});
      expect(s.studentId, '42');
    });
  });

  group('diary from objects', () {
    test('flat schema: lessons + homework by lesson_id + files + marks', () {
      final d = buildDiaryFrom(
        lessons: [
          {'obj_id': 'L2', 'date': '2026-11-17', 'lesson_number': 2, 'time_start': '08:50:00', 'time_end': '09:30:00', 'subject_name': 'Физика'},
          {'obj_id': 'L1', 'date': '2026-11-17', 'lesson_number': 1, 'time_start': '08:00:00', 'time_end': '08:40:00', 'subject_name': 'Алгебра', 'topic': 'Логарифмы'},
          {'obj_id': 'L3', 'date': '2026-11-18', 'lesson_number': 1, 'subject_name': 'История'},
        ],
        homeworks: [
          {
            'obj_id': 'H1',
            'lesson_id': 'L1',
            'subject_name': 'Алгебра',
            'description': '<p>№ 12.4, 12.5</p>',
            'materials': [
              {'file_name': 'Задание.pdf', 'url': '/api/myschool/v1/files/abc'},
            ],
          },
          {'obj_id': 'H2', 'subject_name': 'История', 'date_to': '2026-11-18', 'text': 'Параграф 7'},
          {'obj_id': 'H3', 'subject_name': 'Биология', 'date_to': '2026-11-19', 'text': 'Читать'},
        ],
        marks: [
          {'obj_id': 'M1', 'value': '5', 'weight': 2, 'date': '2026-11-17', 'subject_name': 'Алгебра', 'control_form': 'Контрольная'},
          {'obj_id': 'M2', 'value': 4, 'date': '2026-11-10', 'subject_name': 'Алгебра'},
        ],
      );
      expect(d.days.length, 3);
      final mon = d.days.first;
      expect(mon.date, DateTime(2026, 11, 17));
      expect(mon.lessons.map((l) => l.subject).toList(), ['Алгебра', 'Физика']);
      final alg = mon.lessons.first;
      expect(alg.number, '1');
      expect(alg.time, '08:00–08:40');
      expect(alg.topic, 'Логарифмы');
      expect(alg.homework, '№ 12.4, 12.5');
      expect(alg.files.single.name, 'Задание.pdf');
      expect(alg.files.single.url, 'https://www.gosuslugi.ru/api/myschool/v1/files/abc');
      expect(alg.marks.single.value, '5');
      expect(alg.marks.single.weight, 2);
      expect(alg.marks.single.comment, 'Контрольная');
      expect(d.days[1].lessons.single.homework, 'Параграф 7');
      // Homework without a lesson in the schedule still shows up on its day.
      expect(d.days[2].lessons.single.subject, 'Биология');
      final algMarks = d.subjects.firstWhere((s) => s.subject == 'Алгебра');
      expect(algMarks.marks.map((m) => m.value).toList(), ['4', '5']);
      expect(algMarks.computedAverage, closeTo(14 / 3, 0.001));
      final weeks = d.weeks(DateTime(2026, 11, 17));
      expect(weeks.keys, ['2026-11-16']);
    });

    test('nested schema: subject objects, ISO datetimes, homework by date+subject', () {
      final d = buildDiaryFrom(
        lessons: [
          {
            'id': 'x1',
            'subject': {'id': 9, 'name': 'Русский язык'},
            'start_at': '2026-11-19T09:40:00',
            'end_at': '2026-11-19T10:20:00',
            'number': 3,
          },
        ],
        homeworks: [
          {
            'id': 'hw',
            'discipline': {'title': 'Русский язык'},
            'deadline': '2026-11-19',
            'homework': {'text': 'Упр. 45'},
            'attachments': [
              {'name': 'scan.jpg', 'link': 'https://cdn.example/scan.jpg'},
            ],
          },
        ],
        marks: [
          {'id': 'mm', 'mark': {'value': '4'}, 'lesson_date': '19.11.2026', 'subject': {'name': 'Русский язык'}},
        ],
      );
      final l = d.days.single.lessons.single;
      expect(l.subject, 'Русский язык');
      expect(l.time, '09:40–10:20');
      expect(l.number, '3');
      expect(l.homework, 'Упр. 45');
      expect(l.files.single.url, 'https://cdn.example/scan.jpg');
      expect(l.marks.single.value, '4');
    });

    test('material object itself is a file', () {
      final d = buildDiaryFrom(homeworks: [
        {'obj_id': 'f', 'subject_name': 'ИвД', 'date': '2026-11-20', 'file_name': 'Проект.docx', 'url': '/files/p.docx'},
      ]);
      final l = d.days.single.lessons.single;
      expect(l.files.single.name, 'Проект.docx');
      expect(l.homework, '');
    });

    test('finals from pmarks and ymarks', () {
      final f = buildFinals(pmarks: [
        {'value': 5, 'subject_name': 'Алгебра', 'period_name': '2 четверть'},
        {'value': 4, 'subject_name': 'Алгебра', 'period_name': '1 четверть'},
        {'value': 3, 'subject_name': 'История', '#interval': '555'},
      ], ymarks: [
        {'value': '5', 'subject_name': 'Алгебра'},
      ])!;
      expect(f.headers, ['1 четверть', '2 четверть', 'Период 1', 'Год']);
      final alg = f.rows.firstWhere((r) => r.subject == 'Алгебра');
      expect(alg.values, ['4', '5', '', '5']);
      expect(buildFinals(), isNull);
    });

    test('store → diary end to end', () {
      final s = DatamartStore()
        ..applyResponse([
          item('student_lessons', 'snapshot', [
            {'obj_id': 'L1', 'date': '2026-11-17', 'subject_name': 'Алгебра', 'lesson_number': 1},
          ]),
          item('student_pmarks', 'snapshot', [
            {'obj_id': 'P1', 'value': 5, 'subject_name': 'Алгебра'},
          ], interval: 'Q2'),
        ]);
      final d = buildDiary(s);
      expect(d.days.single.lessons.single.subject, 'Алгебра');
      expect(d.finals!.rows.single.values, ['5']);
    });
  });

  group('helpers', () {
    test('json shape keeps keys and types only', () {
      final shape = shapeText({
        'obj_type': 'student_marks',
        'data': [
          {'value': 5, 'subject_name': 'Алгебра', 'date': '2026-11-10', 'comment': 'Иванов И.', 'id': 123456},
          {'value': '4', 'teacher': null},
        ],
        '1234567': {'x': true},
      });
      expect(shape, contains('subject_name'));
      expect(shape, contains('"str:date"'));
      expect(shape, contains('student_marks'));
      expect(shape, isNot(contains('Алгебра')));
      expect(shape, isNot(contains('Иванов')));
      expect(shape, isNot(contains('123456')));
      expect(shape, isNot(contains('2026')));
    });

    test('mask api path', () {
      expect(maskApiPath('https://www.gosuslugi.ru/api/myschool/v2/customservices/12345?x=1'), '/api/myschool/v2/customservices/#');
      expect(maskApiPath('/api/myschool/v1/files/0f8fad5b-d9cb-469f-a165-70867728950e'), '/api/myschool/v1/files/{uuid}');
    });

    test('shift interval id', () {
      expect(shiftIntervalId('2026-11-16_2026-11-22', 7), '2026-11-23_2026-11-29');
      expect(shiftIntervalId('12345', 7), isNull);
    });

    test('bridge message parsing', () {
      final c = WebCapture.parse(jsonEncode({
        'k': 'fetch',
        'm': 'post',
        'u': 'https://www.gosuslugi.ru/api/myschool/v1/datamart',
        'b': '[{"obj_type":"student_marks","student_id":1}]',
        'h': {'Content-Type': 'application/json', 'X-Foo': 'bar'},
        's': 200,
        't': '[]',
      }))!;
      expect(c.isDatamart, isTrue);
      expect(c.headers['X-Foo'], 'bar');
      expect(DatamartStore.itemsIn(c.requestJson).single['obj_type'], 'student_marks');
      expect(WebCapture.parse('not json'), isNull);
    });
  });
}
