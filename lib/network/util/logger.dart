import 'dart:async';
import 'dart:io';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:proxypin/ui/configuration.dart';

class FileOutput extends LogOutput {
  final File file;
  IOSink? _sink;
  final bool _closeSinkOnWrite;
  final int _maxFileSize;
  final int _backupCount;

  // A queue for all write operations
  Future<void> _lastWrite = Future.value();

  FileOutput({
    required this.file,
    bool closeSinkOnWrite = false,
    int maxFileSize = 1024 * 1024 * 5, // 5MB default
    int backupCount = 3,
  })  : _closeSinkOnWrite = closeSinkOnWrite,
        _maxFileSize = maxFileSize,
        _backupCount = backupCount {
    if (!_closeSinkOnWrite) {
      _initSink();
    }
  }

  Future<void> _initSink() async {
    try {
      await file.parent.create(recursive: true);
      _sink = file.openWrite(mode: FileMode.append);
    } catch (e) {
      stderr.writeln('Failed to initialize log file sink: $e');
    }
  }

  @override
  Future<void> output(OutputEvent event) {
    _lastWrite = _lastWrite.then((_) async {
      try {
        if (_closeSinkOnWrite) {
          // Open + write + close for each event
          final tempSink = file.openWrite(mode: FileMode.append);
          for (var line in event.lines) {
            tempSink.writeln('${DateTime.now().toIso8601String()} $line');
          }
          await tempSink.flush();
          await tempSink.close();
        } else {
          if (_sink == null) {
            await _initSink();
          }
          for (var line in event.lines) {
            _sink!.writeln('${DateTime.now().toIso8601String()} $line');
          }
          await _sink!.flush();
        }

        // Check rotation
        if (_maxFileSize > 0 && await file.length() >= _maxFileSize) {
          await _rotateLogFile();
        }
      } catch (e, stackTrace) {
        stderr.writeln('Failed to write to log file: $e\n$stackTrace');
      }
    });

    return _lastWrite;
  }

  Future<void> _rotateLogFile() async {
    try {
      if (!_closeSinkOnWrite) {
        await _sink?.flush();
        await _sink?.close();
        _sink = null;
      }

      // Rotate backups
      for (var i = _backupCount; i > 0; i--) {
        final backupFile = File('${file.path}.$i');
        if (i == 1) {
          if (await file.exists()) {
            await file.copy(backupFile.path);
            await file.delete();
          }
        } else {
          final previousBackup = File('${file.path}.${i - 1}');
          if (await previousBackup.exists()) {
            await previousBackup.rename(backupFile.path);
          }
        }
      }

      if (!_closeSinkOnWrite) {
        await _initSink();
      }
    } catch (e, stackTrace) {
      stderr.writeln('Failed to rotate log file: $e\n$stackTrace');
    }
  }

  @override
  Future<void> destroy() async {
    await _lastWrite; // Ensure all writes finish
    if (!_closeSinkOnWrite) {
      try {
        await _sink?.flush();
        await _sink?.close();
        _sink = null;
      } catch (e) {
        stderr.writeln('Failed to close log file sink: $e');
      }
    }
  }
}

Future<Logger> createLogger() async {
  final Directory appDir = await getApplicationSupportDirectory();
  final Directory logsDir = Directory('${appDir.path}/logs');
  final File logFile = File('${logsDir.path}/app.log');

  return Logger(
    level: AppConfiguration.version.contains('+') ? Level.all : Level.info,
    filter: ProductionFilter(),
    printer: PrettyPrinter(
      methodCount: 3,
      errorMethodCount: 15,
      lineLength: 120,
      colors: true,
      printEmojis: false,
    ),
    output: MultiOutput([
      ConsoleOutput(),
      FileOutput(
        file: logFile,
        maxFileSize: 1024 * 1024 * 2, // 2MB
        backupCount: 2,
        closeSinkOnWrite: false, // Set to true if you want per-write safety over performance
      ),
    ]),
  );
}

late final Logger logger;

Future<void> initLogger() async {
  logger = await createLogger();
}
