import 'dart:convert';

import 'package:dnevnik/core/models.dart';
import 'package:dnevnik/core/net.dart';
import 'package:dnevnik/core/updater.dart';
import 'package:dnevnik/core/util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('week json round trip', () {
    final w = Week(
      monday: DateTime(2026, 11, 16),
      fetchedAt: DateTime(2026, 11, 17, 10),
      days: [
        Day(date: DateTime(2026, 11, 16), title: 'Понедельник, 16.11', lessons: [
          const Lesson(subject: 'Алгебра', homework: '№1', files: [Attachment(name: 'a.pdf', url: 'https://x/a.pdf')], marks: [
            Mark(value: '5', weight: 2),
          ]),
        ]),
      ],
    );
    final back = Week.fromJson(jsonDecode(jsonEncode(w.toJson())) as Map<String, dynamic>);
    expect(back.days.single.lessons.single.files.single.name, 'a.pdf');
    expect(back.days.single.lessons.single.marks.single.weight, 2);
  });

  test('mark numeric values', () {
    expect(const Mark(value: '5').numeric, 5);
    expect(const Mark(value: '4/5').numeric, 4.5);
    expect(const Mark(value: 'Н').numeric, isNull);
    expect(const Mark(value: '5-').numeric, 5);
  });

  test('content-disposition file names', () {
    expect(filenameFromContentDisposition("attachment; filename*=UTF-8''%D0%94%D0%97.pdf"), 'ДЗ.pdf');
    expect(filenameFromContentDisposition('attachment; filename="report.docx"'), 'report.docx');
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

  test('loose dates and times', () {
    expect(parseLooseDateTime('2026-11-17'), DateTime(2026, 11, 17));
    expect(parseLooseDateTime('17.11.2026'), DateTime(2026, 11, 17));
    expect(parseLooseDateTime('2026-11-17T08:30:00')!.hour, 8);
    expect(parseLooseDateTime(null), isNull);
    expect(parseLooseTime('8:05:00'), '08:05');
    expect(parseLooseTime('2026-11-17T09:15:00'), '09:15');
    expect(parseLooseTime('2026-11-17'), '');
    expect(mondayOf(DateTime(2026, 11, 22)), DateTime(2026, 11, 16));
    expect(htmlToText('<p>Стр. 12</p><p>№&nbsp;3</p>'), 'Стр. 12\n\n№ 3');
    expect(normSubject('Англ. яз.'), 'англяз');
  });
}
