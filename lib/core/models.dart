// Data models of the diary. Plain classes with JSON for the offline cache.

class Attachment {
  final String name;
  final String url; // absolute
  const Attachment({required this.name, required this.url});

  Map<String, dynamic> toJson() => {'name': name, 'url': url};
  factory Attachment.fromJson(Map<String, dynamic> j) =>
      Attachment(name: j['name'] as String? ?? '', url: j['url'] as String? ?? '');
}

class Mark {
  final String value; // «5», «4/5», «Н»
  final double weight; // 1 by default
  final String comment;
  final String subject;
  final DateTime? date;
  final String kind; // lesson, hometask, comment …
  const Mark({
    required this.value,
    this.weight = 1,
    this.comment = '',
    this.subject = '',
    this.date,
    this.kind = '',
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
      };
  factory Mark.fromJson(Map<String, dynamic> j) => Mark(
        value: j['v'] as String? ?? '',
        weight: (j['w'] as num?)?.toDouble() ?? 1,
        comment: j['c'] as String? ?? '',
        subject: j['s'] as String? ?? '',
        date: j['d'] == null ? null : DateTime.tryParse(j['d'] as String),
        kind: j['k'] as String? ?? '',
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
  const Lesson({
    this.number = '',
    this.time = '',
    required this.subject,
    this.topic = '',
    this.homework = '',
    this.files = const [],
    this.marks = const [],
  });

  bool get hasHomework => homework.trim().isNotEmpty || files.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'n': number,
        't': time,
        's': subject,
        'tp': topic,
        'h': homework,
        'f': files.map((e) => e.toJson()).toList(),
        'm': marks.map((e) => e.toJson()).toList(),
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
  const FinalsTable({required this.headers, required this.rows, required this.fetchedAt});
  Map<String, dynamic> toJson() => {
        'h': headers,
        'r': rows.map((e) => {'s': e.subject, 'v': e.values}).toList(),
        'f': fetchedAt.toIso8601String(),
      };
  factory FinalsTable.fromJson(Map<String, dynamic> j) => FinalsTable(
        headers: ((j['h'] as List?) ?? const []).map((e) => '$e').toList(),
        rows: ((j['r'] as List?) ?? const []).map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          return FinalsRow(m['s'] as String? ?? '', ((m['v'] as List?) ?? const []).map((x) => '$x').toList());
        }).toList(),
        fetchedAt: DateTime.tryParse(j['f'] as String? ?? '') ?? DateTime.now(),
      );
}

class FinalsRow {
  final String subject;
  final List<String> values;
  const FinalsRow(this.subject, this.values);
}
