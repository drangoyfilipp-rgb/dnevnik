import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/diagnostics.dart';
import '../core/models.dart';
import '../core/net.dart';
import '../services.dart';

/// Download index: url → saved path (so a second tap opens instantly, offline too).
class FileIndex {
  static Map<String, String>? _map;
  static Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/files.json');

  static Future<Map<String, String>> load() async {
    if (_map != null) return _map!;
    try {
      final f = await _file();
      _map = await f.exists() ? Map<String, String>.from(jsonDecode(await f.readAsString()) as Map) : {};
    } catch (_) {
      _map = {};
    }
    return _map!;
  }

  static Future<void> put(String url, String path) async {
    final m = await load();
    m[url] = path;
    await (await _file()).writeAsString(jsonEncode(m));
  }

  static Future<File?> existing(String url) async {
    final p = (await load())[url];
    if (p == null) return null;
    final f = File(p);
    return await f.exists() && await f.length() > 0 ? f : null;
  }
}

class FileActions {
  static final ValueNotifier<Map<String, double>> progress = ValueNotifier({});

  static Future<File?> fetch(BuildContext context, Attachment a, {bool redownload = false}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!redownload) {
      final have = await FileIndex.existing(a.url);
      if (have != null) return have;
    }
    progress.value = {...progress.value, a.url: 0};
    try {
      final dir = await Services.I.repo.filesDir();
      final f = await Services.I.repo.client.download(a.url, dir, fallbackName: a.name, onProgress: (got, total) {
        progress.value = {...progress.value, a.url: total == null ? -1 : got / total};
      });
      await FileIndex.put(a.url, f.path);
      return f;
    } on SessionExpired {
      Services.I.repo.markSessionExpired();
      messenger?.showSnackBar(const SnackBar(content: Text('Сессия истекла — войдите снова, чтобы скачать файл')));
    } catch (e) {
      Diagnostics.instance.error('файл', e);
      messenger?.showSnackBar(SnackBar(content: Text('Не удалось скачать «${a.name}»: $e')));
    } finally {
      progress.value = Map.of(progress.value)..remove(a.url);
    }
    return null;
  }

  /// One tap: download (if needed) and open with an installed app.
  static Future<void> open(BuildContext context, Attachment a) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final f = await fetch(context, a);
    if (f == null) return;
    final r = await OpenFilex.open(f.path);
    if (r.type != ResultType.done) {
      messenger?.showSnackBar(SnackBar(
        content: Text(r.type == ResultType.noAppToOpen ? 'Нет приложения для этого файла' : 'Не открылся: ${r.message}'),
        action: SnackBarAction(label: 'Поделиться', onPressed: () => shareFiles(context, [a])),
      ));
    }
  }

  static Future<void> shareFiles(BuildContext context, List<Attachment> files, {String? text}) async {
    final out = <XFile>[];
    for (final a in files) {
      if (!context.mounted) return;
      final f = await fetch(context, a);
      if (f != null) out.add(XFile(f.path));
    }
    if (out.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: out, text: text));
  }

  static Future<void> shareText(String text, {String? subject}) =>
      SharePlus.instance.share(ShareParams(text: text, subject: subject));
}

IconData fileIcon(String name) {
  final n = name.toLowerCase();
  if (RegExp(r'\.(jpe?g|png|gif|webp|heic)$').hasMatch(n)) return Icons.image_outlined;
  if (n.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
  if (RegExp(r'\.(docx?|odt|rtf|txt)$').hasMatch(n)) return Icons.description_outlined;
  if (RegExp(r'\.(pptx?|odp)$').hasMatch(n)) return Icons.slideshow_outlined;
  if (RegExp(r'\.(xlsx?|ods|csv)$').hasMatch(n)) return Icons.table_chart_outlined;
  if (RegExp(r'\.(mp3|m4a|wav|ogg)$').hasMatch(n)) return Icons.audiotrack_outlined;
  if (RegExp(r'\.(mp4|mov|avi|mkv)$').hasMatch(n)) return Icons.movie_outlined;
  return Icons.attach_file;
}

/// A file chip: tap = open, long press = share.
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({super.key, required this.file});
  final Attachment file;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: FileActions.progress,
      builder: (context, prog, _) {
        final p = prog[file.url];
        return ActionChip(
          avatar: p == null
              ? Icon(fileIcon(file.name), size: 18)
              : SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, value: p < 0 ? null : p)),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 230),
            child: Text(file.name, overflow: TextOverflow.ellipsis),
          ),
          tooltip: 'Открыть · удерживайте, чтобы поделиться',
          onPressed: p == null ? () => FileActions.open(context, file) : null,
        );
      },
    );
  }
}

class AttachmentRow extends StatelessWidget {
  const AttachmentRow({super.key, required this.files});
  final List<Attachment> files;
  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 6, runSpacing: 4, children: [
      for (final f in files)
        GestureDetector(
          onLongPress: () => FileActions.shareFiles(context, [f]),
          child: AttachmentChip(file: f),
        ),
    ]);
  }
}
