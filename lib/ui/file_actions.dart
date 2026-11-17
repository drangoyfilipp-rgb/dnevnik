import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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
    final repo = Services.I.repo;
    try {
      final dir = await repo.filesDir();
      Future<File> go() => repo.client.download(a.url, dir, fallbackName: a.name, onProgress: (got, total) {
            progress.value = {...progress.value, a.url: total == null ? -1 : got / total};
          });
      File f;
      try {
        f = await go();
      } on SessionExpired {
        if (!await repo.reloginSilently()) rethrow;
        f = await go();
      }
      await FileIndex.put(a.url, f.path);
      return f;
    } on SessionExpired {
      repo.markSessionExpired();
      messenger?.showSnackBar(const SnackBar(content: Text('Сессия Госуслуг истекла — войдите снова, чтобы скачать файл')));
    } on NotJson {
      // A web page rather than a file (e.g. a link to an online resource): open it in the browser.
      await launchUrl(Uri.parse(a.url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (isOfflineError(e)) {
        messenger?.showSnackBar(SnackBar(content: Text('Нет интернета: «${a.name}» ещё не скачан')));
      } else {
        Diagnostics.instance.error('файл', e);
        messenger?.showSnackBar(SnackBar(content: Text('Не удалось скачать «${a.name}»: $e')));
      }
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

/// Files downloaded earlier (they live in the app's folder and open offline).
class DownloadedFilesScreen extends StatefulWidget {
  const DownloadedFilesScreen({super.key});
  @override
  State<DownloadedFilesScreen> createState() => _DownloadedFilesScreenState();
}

class _DownloadedFilesScreenState extends State<DownloadedFilesScreen> {
  late Future<List<File>> _files = _list();

  Future<List<File>> _list() async {
    final dir = await Services.I.repo.filesDir();
    if (!await dir.exists()) return [];
    final list = await dir.list().where((e) => e is File && !e.path.split('/').last.startsWith('.')).cast<File>().toList();
    list.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Скачанные файлы')),
      body: FutureBuilder<List<File>>(
        future: _files,
        builder: (context, snap) {
          final files = snap.data ?? const <File>[];
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (files.isEmpty) {
            return const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('Пока ничего не скачано')));
          }
          return ListView(children: [
            for (final f in files)
              ListTile(
                leading: Icon(fileIcon(f.path)),
                title: Text(f.path.split('/').last),
                subtitle: Text('${(f.lengthSync() / 1024).ceil()} КБ'),
                onTap: () => OpenFilex.open(f.path),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Поделиться',
                    icon: const Icon(Icons.share_outlined),
                    onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(f.path)])),
                  ),
                  IconButton(
                    tooltip: 'Удалить',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await f.delete();
                      setState(() => _files = _list());
                    },
                  ),
                ]),
              ),
          ]);
        },
      ),
    );
  }
}
