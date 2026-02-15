import 'dart:io';
import 'package:flutter/material.dart';
import 'package:myscribe_app/services/database_service.dart';
import 'package:myscribe_app/services/ocr_service.dart';
import 'package:myscribe_app/ui/screens/home_screen.dart';
import 'package:myscribe_app/ui/themes/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() async {
  // Инициализация базы данных для Windows/Linux (если будете запускать там)
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  WidgetsFlutterBinding.ensureInitialized();

  // Инициализация сервисов
  final dbService = DatabaseService.instance;
  final ocrService = OcrService();
  
  // Загрузка модели здесь больше не нужна, так как она на сервере Python.
  // Проверка орфографии отключена, чтобы не вызывать ошибок с assets.

  runApp(MyApp(
    databaseService: dbService,
    ocrService: ocrService,
  ));
}

class MyApp extends StatelessWidget {
  final DatabaseService databaseService;
  final OcrService ocrService;

  const MyApp({
    super.key,
    required this.databaseService,
    required this.ocrService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Предоставляем сервисы всему приложению
        Provider<DatabaseService>.value(value: databaseService),
        Provider<OcrService>.value(value: ocrService),
      ],
      child: MaterialApp(
        title: 'MyScribe',
        theme: AppTheme.darkTheme,
        debugShowCheckedModeBanner: false,
        home: const HomeScreen(),
      ),
    );
  }
}