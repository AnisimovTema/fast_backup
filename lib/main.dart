// Flutter Desktop app (Windows/macOS) — простой бэкап с USB
// Поместите этот файл как lib/main.dart в Flutter-проект.
// Добавьте в pubspec.yaml (dependencies):
//   file_picker: ^5.2.5
//   path: ^1.8.3
//   intl: ^0.18.1
//   glob: ^2.0.2
// Затем: flutter config --enable-windows-desktop, flutter config --enable-macos-desktop
// flutter create ., flutter run -d windows (или -d macos)

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';
import 'package:glob/glob.dart';

void main() {
  runApp(const BackupApp());
}

class BackupApp extends StatelessWidget {
  const BackupApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'USB Backup Builder',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const BackupHome(),
      debugShowCheckedModeBanner: false,
    );
  }
}

enum FileState { unchanged, updated, added, deleted }

class FileNode {
  final String name;
  final String relativePath; // relative from source or target root
  final bool isDir;
  FileState state;
  List<FileNode> children = [];
  FileNode({
    required this.name,
    required this.relativePath,
    required this.isDir,
    required this.state,
  });
}

class BackupAction {
  final String relPath;
  final FileState action; // for our purposes: added/updated/unchanged/deleted
  BackupAction(this.relPath, this.action);
}

class IgnorePattern {
  final String raw;
  final bool negation;
  final Glob glob;
  IgnorePattern({
    required this.raw,
    required this.negation,
    required this.glob,
  });
}

class BackupHome extends StatefulWidget {
  const BackupHome({super.key});

  @override
  State<BackupHome> createState() => _BackupHomeState();
}

class _BackupHomeState extends State<BackupHome> {
  String? sourceDir;
  String? targetDir;
  String ignoreContent = '';
  List<IgnorePattern> ignorePatterns = [];
  bool isRunning = false;
  double progress = 0.0;
  String statusText = 'Готов';
  Map<String, FileState> fileStates = {}; // relativePath -> state
  List<String> sourceFiles = [];
  List<String> targetFiles = [];

  // For UI tree
  FileNode? rootNode;

  List<BackupAction> plannedActions = [];

  // log file handle
  IOSink? logSink;

  @override
  void initState() {
    super.initState();
  }

  Future<void> pickSource() async {
    String? path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Выберите исходную папку (флешка)',
    );
    if (path == null) return;
    setState(() {
      sourceDir = path;
    });
    await loadIgnoreFile();
    await scanBoth();
  }

  Future<void> pickTarget() async {
    String? path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Выберите папку для резервных копий',
    );
    if (path == null) return;
    setState(() {
      targetDir = path;
    });
    await scanBoth();
  }

  Future<void> loadIgnoreFile() async {
    ignorePatterns.clear();
    if (sourceDir == null) return;
    final f = File(p.join(sourceDir!, '.ignore'));
    if (await f.exists()) {
      ignoreContent = await f.readAsString();
      final lines = ignoreContent.split(RegExp(r"?"));
      for (var raw in lines) {
        var line = raw.trim();
        if (line.isEmpty) continue;
        if (line.startsWith('#')) continue;
        var neg = false;
        if (line.startsWith('!')) {
          neg = true;
          line = line.substring(1);
        }
        // Normalize separators to POSIX style for matching against stored relative paths
        final pattern = line.replaceAll('\\', '/');
        // If pattern ends with '/', treat it as directory match and convert to pattern matching anything under it
        var patternForGlob = pattern;
        if (patternForGlob.endsWith('/')) {
          patternForGlob = patternForGlob + '**';
        }
        // Glob supports ** and * and ? and character classes
        try {
          final g = Glob(patternForGlob, recursive: true);
          ignorePatterns.add(IgnorePattern(raw: raw, negation: neg, glob: g));
        } catch (e) {
          // If pattern can't be compiled, skip but keep a comment
          debugPrint('Invalid ignore pattern: $patternForGlob -> $e');
        }
      }
    } else {
      ignoreContent = '';
    }
  }

  bool isIgnored(String relativePath) {
    // normalize to forward slashes for matching
    var rp = relativePath.replaceAll('\\', '/');
    // Git-like behaviour: patterns are applied in order, later patterns override earlier ones
    bool ignored = false;
    for (var ptn in ignorePatterns) {
      if (ptn.glob.matches(rp)) {
        ignored = !ptn.negation ? true : false;
      }
    }
    return ignored;
  }

  Future<void> scanBoth() async {
    if (sourceDir == null || targetDir == null) return;
    fileStates.clear();
    sourceFiles = await _collectFiles(sourceDir!);
    targetFiles = await _collectFiles(targetDir!);

    // mark added/unchanged/updated
    for (var s in sourceFiles) {
      if (isIgnored(s)) continue;
      final targetPath = p.join(targetDir!, s);
      final targetFile = File(targetPath);
      final sourceFile = File(p.join(sourceDir!, s));
      if (!await targetFile.exists()) {
        fileStates[s] = FileState.added;
      } else {
        final sStat = await sourceFile.lastModified();
        final tStat = await targetFile.lastModified();
        if (sStat.millisecondsSinceEpoch == tStat.millisecondsSinceEpoch) {
          fileStates[s] = FileState.unchanged;
        } else {
          fileStates[s] = FileState.updated;
        }
      }
    }

    // mark deleted: files present in target but missing in source
    for (var t in targetFiles) {
      if (isIgnored(t)) continue; // if ignored in source, also ignore
      if (!sourceFiles.contains(t)) {
        fileStates[t] = FileState.deleted;
      }
    }

    // build tree for UI
    rootNode = _buildTree(fileStates.keys.toList());
    setState(() {});
  }

  Future<List<String>> _collectFiles(String root) async {
    final List<String> files = [];
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return files;
    await for (var entity in rootDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        final rel = p.relative(entity.path, from: root);
        final normalized = p.posix.normalize(rel.replaceAll('\\', '/'));
        files.add(normalized);
      }
    }
    return files;
  }

  FileNode _buildTree(List<String> paths) {
    final root = FileNode(
      name: p.basename(sourceDir ?? ''),
      relativePath: '',
      isDir: true,
      state: FileState.unchanged,
    );
    for (var rel in paths) {
      final parts = p.posix.split(rel);
      var cur = root;
      String accum = '';
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        accum = accum == '' ? part : p.posix.join(accum, part);
        final isLast = i == parts.length - 1;
        final existing = cur.children.firstWhere(
          (c) => c.name == part,
          orElse: () => FileNode(
            name: '',
            relativePath: '',
            isDir: true,
            state: FileState.unchanged,
          ),
        );
        if (existing.name == '') {
          final node = FileNode(
            name: part,
            relativePath: accum,
            isDir: !isLast ? true : false,
            state: fileStates[accum] ?? FileState.unchanged,
          );
          cur.children.add(node);
          cur = node;
        } else {
          cur = existing;
        }
      }
    }
    // sort children
    void sortRec(FileNode n) {
      n.children.sort((a, b) {
        if (a.isDir && !b.isDir) return -1;
        if (!a.isDir && b.isDir) return 1;
        return a.name.compareTo(b.name);
      });
      for (var c in n.children) sortRec(c);
    }

    sortRec(root);
    return root;
  }

  /// Подготовка плана бэкапа (не выполняет копирование)
  Future<List<BackupAction>> prepareBackupPlan() async {
    if (sourceDir == null || targetDir == null) return [];
    await loadIgnoreFile();
    final allSource = await _collectFiles(sourceDir!);
    final filtered = allSource.where((s) => !isIgnored(s)).toList();
    final plan = <BackupAction>[];

    for (var rel in filtered) {
      final srcPath = p.join(sourceDir!, rel);
      final dstPath = p.join(targetDir!, rel);
      final dstFile = File(dstPath);
      final srcFile = File(srcPath);
      if (!await dstFile.exists()) {
        plan.add(BackupAction(rel, FileState.added));
      } else {
        final sMod = await srcFile.lastModified();
        final dMod = await dstFile.lastModified();
        if (sMod.millisecondsSinceEpoch != dMod.millisecondsSinceEpoch) {
          plan.add(BackupAction(rel, FileState.updated));
        } else {
          plan.add(BackupAction(rel, FileState.unchanged));
        }
      }
    }

    // deleted in source but exists in target
    final allTarget = await _collectFiles(targetDir!);
    for (var t in allTarget) {
      if (isIgnored(t)) continue;
      if (!allSource.contains(t)) {
        plan.add(BackupAction(t, FileState.deleted));
      }
    }

    // sort plan for nicer presentation
    plan.sort((a, b) => a.relPath.compareTo(b.relPath));
    plannedActions = plan;
    return plan;
  }

  Future<void> startWithPreview() async {
    if (sourceDir == null || targetDir == null) return;
    final plan = await prepareBackupPlan();
    if (!mounted) return;
    // show preview dialog
    final counts = <FileState, int>{};
    for (var p in plan) counts[p.action] = (counts[p.action] ?? 0) + 1;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Предварительный просмотр бэкапа'),
        content: SizedBox(
          width: 600,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Добавлено: ${counts[FileState.added] ?? 0}, Обновлено: ${counts[FileState.updated] ?? 0}, Не изменено: ${counts[FileState.unchanged] ?? 0}, Удалено (в источнике): ${counts[FileState.deleted] ?? 0}',
              ),
              const SizedBox(height: 8),
              const Text('Список действий:'),
              const SizedBox(height: 8),
              Expanded(
                child: Scrollbar(
                  child: ListView.builder(
                    itemCount: plan.length,
                    itemBuilder: (ctx, i) {
                      final it = plan[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          _iconForState(it.action),
                          color: _colorForState(it.action),
                        ),
                        title: Text(it.relPath),
                        trailing: Text(_labelForState(it.action)),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Запустить'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _openLog();
      await executeBackup(plan);
      await _closeLog();
      await scanBoth();
    }
  }

  Future<void> _openLog() async {
    if (targetDir == null) return;
    try {
      final lf = File(p.join(targetDir!, 'backup_log.txt'));
      final sink = lf.openWrite(mode: FileMode.append);
      logSink = sink;
      logSink?.writeln(
        '--- Backup started: ${DateTime.now().toIso8601String()} ---',
      );
    } catch (e) {
      debugPrint('Cannot open log file: $e');
      logSink = null;
    }
  }

  Future<void> _closeLog() async {
    try {
      await logSink?.flush();
      await logSink?.close();
    } catch (_) {}
    logSink = null;
  }

  void _log(String line) {
    final t = DateTime.now().toIso8601String();
    final out = '[$t] $line';
    debugPrint(out);
    try {
      logSink?.writeln(out);
    } catch (_) {}
  }

  Future<void> executeBackup(List<BackupAction> plan) async {
    if (sourceDir == null || targetDir == null) return;
    setState(() {
      isRunning = true;
      progress = 0;
      statusText = 'Выполнение...';
    });

    final actionable = plan
        .where(
          (p) => p.action == FileState.added || p.action == FileState.updated,
        )
        .toList();
    final total = actionable.length;
    int done = 0;

    for (var item in actionable) {
      final rel = item.relPath;
      final srcPath = p.join(sourceDir!, rel);
      final dstPath = p.join(targetDir!, rel);
      final dstFile = File(dstPath);
      final srcFile = File(srcPath);

      // ensure directory exists
      final dstDir = Directory(p.dirname(dstPath));
      if (!await dstDir.exists()) await dstDir.create(recursive: true);

      if (item.action == FileState.added) {
        await _copyFile(srcFile, dstFile);
        _log('Added: $rel');
        fileStates[rel] = FileState.added;
      } else if (item.action == FileState.updated) {
        // rename existing dst to include its last modified date
        if (await dstFile.exists()) {
          final dMod = await dstFile.lastModified();
          final ext = p.extension(dstPath);
          final base = p.basenameWithoutExtension(dstPath);
          final formatted = DateFormat('dd_MM_yyyy').format(dMod);
          final newName = base + '_' + formatted + ext;
          final newPath = p.join(p.dirname(dstPath), newName);
          if (!await File(newPath).exists()) {
            try {
              await dstFile.rename(newPath);
              _log(
                'Renamed old: $rel -> ${p.relative(newPath, from: targetDir)}',
              );
            } catch (e) {
              await dstFile.copy(newPath);
              _log(
                'Copied old: $rel -> ${p.relative(newPath, from: targetDir)} (rename failed)',
              );
            }
          }
        }
        await _copyFile(srcFile, dstFile);
        _log('Updated: $rel');
        fileStates[rel] = FileState.updated;
      }

      done++;
      setState(() {
        progress = total == 0 ? 1.0 : done / total;
        statusText = 'Обработано $done из $total';
      });
      await Future.delayed(const Duration(milliseconds: 10));
    }

    // mark deleted files present in target but not in source
    final allTarget = await _collectFiles(targetDir!);
    final allSource = await _collectFiles(sourceDir!);
    for (var t in allTarget) {
      if (isIgnored(t)) continue;
      if (!allSource.contains(t)) {
        fileStates[t] = FileState.deleted;
        _log('Deleted (in source): $t');
      }
    }

    setState(() {
      isRunning = false;
      statusText = 'Завершено';
      progress = 1.0;
    });
  }

  Future<void> _copyFile(File src, File dst) async {
    // Copy bytes
    await src.copy(dst.path);
    try {
      final mod = await src.lastModified();
      await dst.setLastModified(mod);
    } catch (_) {}
  }

  IconData _iconForState(FileState s) {
    switch (s) {
      case FileState.unchanged:
        return Icons.remove;
      case FileState.added:
        return Icons.add;
      case FileState.updated:
        return Icons.update;
      case FileState.deleted:
        return Icons.delete;
    }
  }

  Color _colorForState(FileState s) {
    switch (s) {
      case FileState.unchanged:
        return Colors.grey;
      case FileState.added:
        return Colors.green;
      case FileState.updated:
        return Colors.amber;
      case FileState.deleted:
        return Colors.red;
    }
  }

  String _labelForState(FileState s) {
    switch (s) {
      case FileState.unchanged:
        return 'Не изменён';
      case FileState.added:
        return 'Добавлен';
      case FileState.updated:
        return 'Обновлён';
      case FileState.deleted:
        return 'Удалён (в источнике)';
    }
  }

  Widget statusIcon(FileState state) {
    switch (state) {
      case FileState.unchanged:
        return const Icon(Icons.circle, color: Colors.grey, size: 14);
      case FileState.added:
        return const Icon(Icons.add_circle, color: Colors.green, size: 18);
      case FileState.updated:
        return const Icon(Icons.update, color: Colors.amber, size: 18);
      case FileState.deleted:
        return const Icon(Icons.remove_circle, color: Colors.red, size: 18);
    }
  }

  Widget statusLeading(FileState state) {
    switch (state) {
      case FileState.unchanged:
        return const Icon(Icons.remove, color: Colors.grey);
      case FileState.added:
        return const Icon(Icons.add, color: Colors.green);
      case FileState.updated:
        return const Icon(Icons.loop, color: Colors.amber);
      case FileState.deleted:
        return const Icon(Icons.remove_circle_outline, color: Colors.red);
    }
  }

  Color stateColor(FileState state) {
    switch (state) {
      case FileState.unchanged:
        return Colors.grey.shade400;
      case FileState.added:
        return Colors.green.shade400;
      case FileState.updated:
        return Colors.amber.shade400;
      case FileState.deleted:
        return Colors.red.shade400;
    }
  }

  Widget buildTreeNode(FileNode node) {
    if (node.isDir) {
      return ExpansionTile(
        title: Row(
          children: [
            Icon(Icons.folder, color: Colors.blue.shade700),
            const SizedBox(width: 8),
            Expanded(child: Text(node.name)),
          ],
        ),
        children: node.children.map(buildTreeNode).toList(),
      );
    } else {
      final state = fileStates[node.relativePath] ?? FileState.unchanged;
      return ListTile(
        dense: true,
        leading: statusLeading(state),
        title: Text(node.name, style: TextStyle(color: stateColor(state))),
        trailing: statusIcon(state),
        subtitle: Text(node.relativePath, style: const TextStyle(fontSize: 11)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Простой бэкап с флешки (Windows/macOS)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Сканировать',
            onPressed: isRunning ? null : scanBoth,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Исходная папка: ${sourceDir ?? '<не выбрано>'}'),
                      const SizedBox(height: 6),
                      Text('Папка для бэкапов: ${targetDir ?? '<не выбрано>'}'),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: isRunning ? null : pickSource,
                  icon: const Icon(Icons.usb),
                  label: const Text('Выбрать источник'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: isRunning ? null : pickTarget,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Выбрать куда'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed:
                      (isRunning || sourceDir == null || targetDir == null)
                      ? null
                      : startWithPreview,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Предпросмотр → Запустить'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: LinearProgressIndicator(value: progress)),
                const SizedBox(width: 12),
                Text(statusText),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: rootNode == null
                    ? const Center(
                        child: Text(
                          'Дерево файлов будет отображено здесь после выбора директорий и сканирования.',
                        ),
                      )
                    : SingleChildScrollView(child: buildTreeNode(rootNode!)),
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  LegendChip(color: Colors.grey.shade400, label: 'Не изменён'),
                  const SizedBox(width: 6),
                  LegendChip(color: Colors.amber.shade400, label: 'Обновлён'),
                  const SizedBox(width: 6),
                  LegendChip(color: Colors.green.shade400, label: 'Добавлен'),
                  const SizedBox(width: 6),
                  LegendChip(
                    color: Colors.red.shade400,
                    label: 'Удалён (в источнике)',
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Файлы .ignore поддерживаются — положите .ignore в корень исходной папки.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LegendChip extends StatelessWidget {
  final Color color;
  final String label;
  const LegendChip({required this.color, required this.label, super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 14, height: 14, color: color),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}
