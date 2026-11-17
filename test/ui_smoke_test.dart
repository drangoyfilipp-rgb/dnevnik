// Renders the redesigned screens with synthetic portal data: no layout exceptions,
// the key texts are on screen.
import 'package:dnevnik/core/lock.dart';
import 'package:dnevnik/core/myschool.dart';
import 'package:dnevnik/core/repo.dart';
import 'package:dnevnik/core/settings.dart';
import 'package:dnevnik/core/updater.dart';
import 'package:dnevnik/services.dart';
import 'package:dnevnik/ui/tabs.dart';
import 'package:dnevnik/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'portal_fixtures.dart';

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  late Repo repo;
  late DateTime day;

  setUp(() {
    final settings = AppSettings();
    repo = Repo(settings);
    Services.forTest(settings, repo, LockService(), Updater(settings));
    var d = today();
    if (d.weekday == DateTime.sunday) d = d.add(const Duration(days: 1));
    day = d;
    final next = d.add(Duration(days: d.weekday == DateTime.saturday ? 2 : 1));
    repo.store = DatamartStore()
      ..applyResponse([
        dm('student_lessons', '1', [
          lesson('L1', ymd(d), 'Русский язык', room: '21'),
          lesson('L2', ymd(d), 'Информатика'),
          lesson('L3', ymd(next), 'География'),
        ]),
        dm('student_marks', '1', [
          mark('M1', ymd(d), 'Русский язык', '5', weight: '2', lessonId: 'L1', work: 'Контрольная работа'),
          mark('M2', ymd(d), 'Информатика', '4', lessonId: 'L2'),
        ]),
        dm('student_homeworks_materials', '1', [
          homework('H1', ymd(d), ymd(next), 'География', 'Контурная карта', readyLesson: 'L3', materials: [
            {'name': 'Карта.pdf', 'size': 1000, 'link': 'https://www.gosuslugi.ru/api/myschool/v1/files/x', 'id': 'f'},
          ]),
        ]),
      ]);
    repo.reloadFromStore();
  });

  Future<void> pump(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: w)));
    await t.pump(const Duration(milliseconds: 100));
  }

  testWidgets('schedule day card', (t) async {
    await pump(t, const ScheduleTab());
    expect(t.takeException(), isNull);
    expect(find.text('Русский язык'), findsOneWidget);
    expect(find.text('каб. 21 · Петрова А. И.'), findsOneWidget);
    expect(find.text('5'), findsWidgets);
    expect(find.text('08:30'), findsNothing, reason: 'placeholder times are not shown');
    expect(day.weekday, isNot(DateTime.sunday));
  });

  testWidgets('homework list with file and share button', (t) async {
    await pump(t, const HomeworkTab());
    expect(t.takeException(), isNull);
    expect(find.text('Контурная карта'), findsOneWidget);
    expect(find.text('Карта.pdf'), findsOneWidget);
    expect(find.byTooltip('Поделиться'), findsWidgets);
  });

  testWidgets('marks by subject with average and finals forecast', (t) async {
    await pump(t, const GradesTab());
    expect(t.takeException(), isNull);
    expect(find.text('Русский язык'), findsOneWidget);
    expect(find.text('5,00'), findsOneWidget);
    await t.tap(find.text('Итоговые'));
    await t.pump(const Duration(milliseconds: 100));
    expect(t.takeException(), isNull);
    expect(find.textContaining('Прогноз'), findsOneWidget);
  });

  testWidgets('feed', (t) async {
    await pump(t, const FeedTab());
    expect(t.takeException(), isNull);
    expect(find.text('Новые оценки'), findsOneWidget);
  });
}
