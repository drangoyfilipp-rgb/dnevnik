import 'package:dnevnik/core/models.dart';
import 'package:dnevnik/core/share_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final date = DateTime(2026, 11, 17); // Tuesday

  test('lesson share text is clean', () {
    const l = Lesson(
      subject: 'Алгебра',
      homework: '№ 12.4\n№ 12.4\nСм. https://school.lpr-reg.ru/journal-api-homework-action?action=homework.fetch&task_id=123456789\n'
          'Отправлено из приложения Госуслуги Моя школа',
      files: [
        Attachment(name: 'zadanie.pdf', url: 'u1'),
        Attachment(name: 'zadanie.pdf', url: 'u2'),
      ],
    );
    final s = shareLessonText(l, date);
    expect(s, 'Вт, 17.11 · Алгебра\nДЗ: № 12.4\nСм. school.lpr-reg.ru/…\nФайлы: zadanie.pdf');
  });

  test('short urls are kept', () {
    expect(tidyUrls('см. https://ya.ru/x'), 'см. https://ya.ru/x');
  });

  test('ad lines and blank runs removed', () {
    expect(cleanShareBody('Текст\n\n\n\nОтправлено с помощью ЭлЖур\nЕщё'), 'Текст\n\nЕщё');
  });

  test('day share text', () {
    final d = Day(date: date, title: '', lessons: const [
      Lesson(subject: 'Физика', homework: '§5'),
      Lesson(subject: 'История'),
      Lesson(subject: 'Химия', files: [Attachment(name: 'tabl.xlsx', url: 'x')]),
    ]);
    expect(shareDayText(d), 'Вт, 17.11\n• Физика: §5\n• Химия: (файлы: tabl.xlsx)');
  });

  test('lesson without homework', () {
    expect(shareLessonText(const Lesson(subject: 'ОБЗР'), date), 'Вт, 17.11 · ОБЗР');
  });
}
