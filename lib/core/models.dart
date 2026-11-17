// Data models of the diary. Plain classes with JSON for the offline cache.

class Attachment {
  final String name;
  final String url; // absolute
  final int size; // bytes, 0 = unknown
  const Attachment({required this.name, required this.url, this.size = 0});

  Map<String, dynamic> toJson() => {'name': name, 'url': url, if (size > 0) 'size': size};
  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
      name: j['name'] as String? ?? '', url: j['url'] as String? ?? '', size: (j['size'] as num?)?.toInt() ?? 0);
}

class Mark {
  final String value; // «5», «4/5», «Н»
  final double weight; // 1 by default
  final String comment;
  final String subject;
  final DateTime? date;
  final String kind; // lesson, hometask, comment …
  final String periodId; // study period (четверть) id from the portal, may be empty
  const Mark({
    required this.value,
    this.weight = 1,
    this.comment = '',
    this.subject = '',
    this.date,
    this.kind = '',
    this.periodId = '',
  });

  /// Numeric value for averages: «5» → 5, «4/5» → 4.5, «5-» → 5, «Н» → null.
  double? get numeric {
    final parts = RegExp(r'[1-5]').allMatches(value).map((m) => int.parse(m.group(0)!)).toList();
    if (parts.isEmpty) return null;
    if (RegExp(r'[^\s1-5/\-+.,]').hasMatch(value)) return null;
    return parts.reduce((a, b) => a + b) / parts.length;
  }

  Map<String, dynamic> toJson() => {
        'v': value,
        'w': weight,
        'c': comment,
        's': subject,
        'd': date?.toIso8601String(),
        'k': kind,
        'p': periodId,
      };
  factory Mark.fromJson(Map<String, dynamic> j) => Mark(
        value: j['v'] as String? ?? '',
        weight: (j['w'] as num?)?.toDouble() ?? 1,
        comment: j['c'] as String? ?? '',
        subject: j['s'] as String? ?? '',
        date: j['d'] == null ? null : DateTime.tryParse(j['d'] as String),
        kind: j['k'] as String? ?? '',
        periodId: j['p'] as String? ?? '',
      );
}

class Lesson {
  final String number;
  final String time;
  final String subject;
  final String topic;
  final String homework;
  final List<Attachment> files;
  final List<Mark> marks;
  final String room;
  final String teacher; // «Иванова А. Б.»
  final String absence; // пропуск (если отмечен)
  final bool isLesson; // false = homework without a lesson in the schedule
  const Lesson({
    this.number = '',
    this.time = '',
    required this.subject,
    this.topic = '',
    this.homework = '',
    this.files = const [],
    this.marks = const [],
    this.room = '',
    this.teacher = '',
    this.absence = '',
    this.isLesson = true,
  });

  Lesson copyWith({String? number, String? time, String? homework, List<Attachment>? files, List<Mark>? marks}) => Lesson(
        number: number ?? this.number,
        time: time ?? this.time,
        subject: subject,
        topic: topic,
        homework: homework ?? this.homework,
        files: files ?? this.files,
        marks: marks ?? this.marks,
        room: room,
        teacher: teacher,
        absence: absence,
        isLesson: isLesson,
      );

  bool get hasHomework => homework.trim().isNotEmpty || files.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'n': number,
        't': time,
        's': subject,
        'tp': topic,
        'h': homework,
        'f': files.map((e) => e.toJson()).toList(),
        'm': marks.map((e) => e.toJson()).toList(),
        'r': room,
        'tc': teacher,
        'ab': absence,
        'il': isLesson,
      };
  factory Lesson.fromJson(Map<String, dynamic> j) => Lesson(
        number: j['n'] as String? ?? '',
        time: j['t'] as String? ?? '',
        subject: j['s'] as String? ?? '',
        topic: j['tp'] as String? ?? '',
        homework: j['h'] as String? ?? '',
        files: ((j['f'] as List?) ?? const [])
            .map((e) => Attachment.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        marks: ((j['m'] as List?) ?? const [])
            .map((e) => Mark.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        room: j['r'] as String? ?? '',
        teacher: j['tc'] as String? ?? '',
        absence: j['ab'] as String? ?? '',
        isLesson: j['il'] as bool? ?? true,
      );
}

class Day {
  final DateTime date;
  final String title; // «Понедельник, 17.11»
  final bool holiday;
  final String holidayText;
  final List<Lesson> lessons;
  const Day({
    required this.date,
    required this.title,
    this.holiday = false,
    this.holidayText = '',
    this.lessons = const [],
  });

  Map<String, dynamic> toJson() => {
        'd': date.toIso8601String(),
        't': title,
        'h': holiday,
        'ht': holidayText,
        'l': lessons.map((e) => e.toJson()).toList(),
      };
  factory Day.fromJson(Map<String, dynamic> j) => Day(
        date: DateTime.parse(j['d'] as String),
        title: j['t'] as String? ?? '',
        holiday: j['h'] as bool? ?? false,
        holidayText: j['ht'] as String? ?? '',
        lessons: ((j['l'] as List?) ?? const [])
            .map((e) => Lesson.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

class Week {
  final DateTime monday;
  final List<Day> days;
  final DateTime fetchedAt;
  const Week({required this.monday, required this.days, required this.fetchedAt});

  Map<String, dynamic> toJson() => {
        'm': monday.toIso8601String(),
        'f': fetchedAt.toIso8601String(),
        'd': days.map((e) => e.toJson()).toList(),
      };
  factory Week.fromJson(Map<String, dynamic> j) => Week(
        monday: DateTime.parse(j['m'] as String),
        fetchedAt: DateTime.parse(j['f'] as String),
        days: ((j['d'] as List?) ?? const [])
            .map((e) => Day.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

class SubjectMarks {
  final String subject;
  final List<Mark> marks;
  final String average; // as shown by the school, may be empty
  const SubjectMarks({required this.subject, required this.marks, this.average = ''});

  double? get computedAverage {
    double sum = 0, w = 0;
    for (final m in marks) {
      final n = m.numeric;
      if (n == null) continue;
      sum += n * m.weight;
      w += m.weight;
    }
    return w == 0 ? null : sum / w;
  }

  Map<String, dynamic> toJson() =>
      {'s': subject, 'a': average, 'm': marks.map((e) => e.toJson()).toList()};
  factory SubjectMarks.fromJson(Map<String, dynamic> j) => SubjectMarks(
        subject: j['s'] as String? ?? '',
        average: j['a'] as String? ?? '',
        marks: ((j['m'] as List?) ?? const [])
            .map((e) => Mark.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

class PeriodLink {
  final String label;
  final String path;
  final bool selected;
  const PeriodLink({required this.label, required this.path, this.selected = false});
  Map<String, dynamic> toJson() => {'l': label, 'p': path, 's': selected};
  factory PeriodLink.fromJson(Map<String, dynamic> j) => PeriodLink(
      label: j['l'] as String? ?? '', path: j['p'] as String? ?? '', selected: j['s'] as bool? ?? false);
}

class GradesPage {
  final List<SubjectMarks> subjects;
  final List<PeriodLink> periods;
  final String periodTitle;
  final DateTime fetchedAt;
  const GradesPage({
    required this.subjects,
    this.periods = const [],
    this.periodTitle = '',
    required this.fetchedAt,
  });
  Map<String, dynamic> toJson() => {
        's': subjects.map((e) => e.toJson()).toList(),
        'p': periods.map((e) => e.toJson()).toList(),
        't': periodTitle,
        'f': fetchedAt.toIso8601String(),
      };
  factory GradesPage.fromJson(Map<String, dynamic> j) => GradesPage(
        subjects: ((j['s'] as List?) ?? const [])
            .map((e) => SubjectMarks.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        periods: ((j['p'] as List?) ?? const [])
            .map((e) => PeriodLink.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        periodTitle: j['t'] as String? ?? '',
        fetchedAt: DateTime.tryParse(j['f'] as String? ?? '') ?? DateTime.now(),
      );
}

/// Final marks: a table with column headers (periods) and one row per subject.
class FinalsTable {
  final List<String> headers; // without the subject column
  final List<FinalsRow> rows;
  final DateTime fetchedAt;
  final bool forecast; // true = computed from current marks (no official final marks yet)
  const FinalsTable({required this.headers, required this.rows, required this.fetchedAt, this.forecast = false});
  Map<String, dynamic> toJson() => {
        'h': headers,
        'r': rows.map((e) => {'s': e.subject, 'v': e.values, 'n': e.notes}).toList(),
        'f': fetchedAt.toIso8601String(),
        'fc': forecast,
      };
  factory FinalsTable.fromJson(Map<String, dynamic> j) => FinalsTable(
        headers: ((j['h'] as List?) ?? const []).map((e) => '$e').toList(),
        rows: ((j['r'] as List?) ?? const []).map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          return FinalsRow(m['s'] as String? ?? '', ((m['v'] as List?) ?? const []).map((x) => '$x').toList(),
              ((m['n'] as List?) ?? const []).map((x) => '$x').toList());
        }).toList(),
        fetchedAt: DateTime.tryParse(j['f'] as String? ?? '') ?? DateTime.now(),
        forecast: j['fc'] as bool? ?? false,
      );
}

class FinalsRow {
  final String subject;
  final List<String> values;
  final List<String> notes; // e.g. the average a forecast is based on
  const FinalsRow(this.subject, this.values, [this.notes = const []]);
}

/// A study period (четверть / полугодие / год) from student_classes.
class StudyPeriod {
  final String id;
  final String label; // «2 четверть»
  final DateTime start;
  final DateTime end;
  final String type; // period_type_code
  final bool study;
  const StudyPeriod({
    required this.id,
    required this.label,
    required this.start,
    required this.end,
    this.type = '',
    this.study = true,
  });
  bool contains(DateTime d) => !d.isBefore(start) && !d.isAfter(end);
  int get days => end.difference(start).inDays + 1;
}
