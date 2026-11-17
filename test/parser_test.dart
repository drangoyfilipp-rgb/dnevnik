import 'dart:convert';
import 'dart:io';

import 'package:dnevnik/core/models.dart';
import 'package:dnevnik/core/net.dart';
import 'package:dnevnik/core/parser.dart';
import 'package:dnevnik/core/updater.dart';
import 'package:flutter_test/flutter_test.dart';

const weekHtml = '''
<html><body>
<script>window.diaryData = {"user":"12345","teacherFiles":{"777":[{"id":1,"url":"/files/t/ans.pdf","filename":"Ответ учителя.pdf"}]}};
window.dnevnikReview = {};</script>
<div class="dnevnik" id="dnevnikDays">
 <div class="dnevnik-day">
  <div class="dnevnik-day__header"><div class="dnevnik-day__title">Понедельник, 17.11</div></div>
  <div class="dnevnik-day__lessons">
   <div class="dnevnik-lesson">
     <div class="dnevnik-lesson__number">1.</div>
     <div class="dnevnik-lesson__time">08:00 – 08:40</div>
     <div class="dnevnik-lesson__subject"><span class="js-rt_licey-dnevnik-subject">Алгебра</span></div>
     <div class="dnevnik-lesson__topic">Логарифмы</div>
     <div class="dnevnik-lesson__hometask">
        <div class="dnevnik-lesson__task">№ 12.4, 12.5<br>Повторить&nbsp;формулы</div>
        <div class="dnevnik-lesson__attach"><a href="/files/hw/zadanie.pdf">zadanie.pdf</a></div>
        <span data-task_id="777" class="dnevnik-teacher-files__btn"></span>
     </div>
     <div class="dnevnik-lesson__marks">
       <div class="dnevnik-mark" title="Контрольная"><span class="dnevnik-mark__value">5</span><span class="dnevnik-mark__weight">2</span></div>
     </div>
   </div>
   <div class="dnevnik-lesson">
     <div class="dnevnik-lesson__number">2</div>
     <div class="dnevnik-lesson__subject"><span>Физика</span></div>
   </div>
  </div>
 </div>
 <div class="dnevnik-day dnevnik-day--holiday">
  <div class="dnevnik-day__title">Вторник, 18.11</div>
  <div class="dnevnik-day__holiday">Каникулы</div>
 </div>
</div>
<a href="/journal-student-grades-action/u.12345">Оценки</a>
</body></html>
''';

void main() {
  final now = DateTime(2026, 11, 17);

  test('parses a week page', () {
    final r = parseWeek(weekHtml, now: now);
    expect(r.loginPage, isFalse);
    expect(r.days.length, 2);
    final d = r.days.first;
    expect(d.date, DateTime(2026, 11, 17));
    expect(d.lessons.length, 2);
    final l = d.lessons.first;
    expect(l.subject, 'Алгебра');
    expect(l.number, '1');
    expect(l.time, '08:00–08:40');
    expect(l.topic, 'Логарифмы');
    expect(l.homework, '№ 12.4, 12.5\nПовторить формулы');
    expect(l.files.map((f) => f.name), ['zadanie.pdf', 'Ответ учителя.pdf']);
    expect(l.files.first.url, 'https://school.lpr-reg.ru/files/hw/zadanie.pdf');
    expect(l.marks.single.value, '5');
    expect(l.marks.single.weight, 2);
    expect(l.marks.single.comment, 'Контрольная');
    expect(d.lessons[1].subject, 'Физика');
    expect(d.lessons[1].hasHomework, isFalse);
    expect(r.days[1].holiday, isTrue);
    expect(r.days[1].holidayText, 'Каникулы');
  });

  test('week json round trip', () {
    final r = parseWeek(weekHtml, now: now);
    final w = Week(monday: mondayOf(r.days.first.date), days: r.days, fetchedAt: now);
    final back = Week.fromJson(w.toJson());
    expect(back.days.first.lessons.first.files.length, 2);
    expect(back.days.first.lessons.first.marks.first.weight, 2);
  });

  test('pupil id', () {
    expect(findPupilId(weekHtml), 'u.12345');
  });

  test('day title year follows school year', () {
    expect(parseDayTitle('Пятница, 05.09', now: DateTime(2027, 2, 1)), DateTime(2026, 9, 5));
    expect(parseDayTitle('Пятница, 05.02', now: DateTime(2026, 11, 1)), DateTime(2027, 2, 5));
    expect(parseAnyDate('2026-10-03'), DateTime(2026, 10, 3));
  });

  test('login page is detected', () {
    final src = File('test/fixtures/authorize.html').readAsStringSync();
    expect(looksLikeLoginPage(src), isTrue);
    expect(parseWeek(src).loginPage, isTrue);
    expect(looksLikeLoginPage(weekHtml), isFalse);
  });

  test('grades: mark_date variant', () {
    const html = '''<div>
      <div mark_date="2026-11-10" name="Алгебра">5</div>
      <div mark_date="12.11" name="Алгебра">4</div>
      <div mark_date="13.11" name="История">Н</div>
      <a class="active" href="/journal-student-grades-action/u.1/sp.II+четверть">II четверть</a>
      <a href="/journal-student-grades-action/u.1/sp.I+четверть">I четверть</a>
    </div>''';
    final g = parseGrades(html, now: now);
    expect(g.subjects.length, 2);
    final alg = g.subjects.firstWhere((s) => s.subject == 'Алгебра');
    expect(alg.marks.length, 2);
    expect(alg.computedAverage, 4.5);
    expect(alg.marks.first.date, DateTime(2026, 11, 10));
    expect(g.periods.length, 2);
    expect(g.periods.first.selected, isTrue);
  });

  test('grades: table variant', () {
    const html = '''<table>
      <tr><th>Предмет</th><th>Оценки</th><th>Средний</th></tr>
      <tr><td>Физика</td><td>5 4 Н 3</td><td>4,00</td></tr>
      <tr><td>Химия</td><td></td><td></td></tr>
    </table>''';
    final g = parseGrades(html, now: now);
    expect(g.subjects.length, 1);
    expect(g.subjects.single.marks.map((m) => m.value), ['5', '4', 'Н', '3']);
    expect(g.subjects.single.average, '4,00');
  });

  test('finals table', () {
    const html = '''<table>
      <tr><th>Предмет</th><th>1 четверть</th><th>2 четверть</th><th>Год</th></tr>
      <tr><td>Алгебра</td><td>5</td><td></td><td></td></tr>
      <tr><td>История</td><td>4</td><td></td><td></td></tr>
    </table>''';
    final f = parseFinals(html);
    expect(f.headers, ['1 четверть', '2 четверть', 'Год']);
    expect(f.rows.length, 2);
    expect(f.rows.first.values.first, '5');
  });

  test('mark numeric values', () {
    expect(const Mark(value: '5').numeric, 5);
    expect(const Mark(value: '4/5').numeric, 4.5);
    expect(const Mark(value: 'Н').numeric, isNull);
    expect(const Mark(value: '5-').numeric, 5);
  });

  test('sanitized structure has no personal text', () {
    final s = sanitizedStructure(weekHtml);
    expect(s, contains('div.dnevnik-lesson'));
    expect(s, contains('vars=diaryData,dnevnikReview'));
    expect(s, isNot(contains('Алгебра')));
    expect(s, isNot(contains('Логарифмы')));
    expect(s, isNot(contains('12345')));
    expect(s, isNot(contains('Ответ учителя')));
  });

  test('content-disposition file names', () {
    expect(filenameFromContentDisposition("attachment; filename*=UTF-8''%D0%94%D0%97.pdf"), 'ДЗ.pdf');
    expect(filenameFromContentDisposition('attachment; filename="report.docx"'), 'report.docx');
    // UTF-8 bytes sent as Latin-1
    final mojibake = String.fromCharCodes(utf8.encode('Тест.pdf'));
    expect(filenameFromContentDisposition('attachment; filename="$mojibake"'), 'Тест.pdf');
    expect(filenameFromContentDisposition(null), isNull);
    expect(safeFileName('a/b:c?.pdf'), 'a_b_c_.pdf');
  });

  test('update helpers', () {
    expect(buildFromTag('build-12'), 12);
    expect(buildFromTag('v1.0'), isNull);
    final assets = [
      {'name': 'dnevnik-universal.apk', 'browser_download_url': 'u'},
      {'name': 'dnevnik-arm64.apk', 'browser_download_url': 'a'},
    ];
    expect(pickAsset(assets, arm64: true), 'a');
    expect(pickAsset(assets, arm64: false), 'u');
  });
}
