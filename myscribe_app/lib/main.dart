import 'package:flutter/material.dart';
import 'package:myscribe_app/services/api_settings_service.dart';
import 'package:myscribe_app/services/database_service.dart';
import 'package:myscribe_app/services/ocr_service.dart';
import 'package:myscribe_app/ui/screens/home_screen.dart';
import 'package:myscribe_app/ui/themes/app_theme.dart';
import 'package:provider/provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Инициализация сервисов
  final apiSettingsService = await ApiSettingsService.create();
  final dbService = DatabaseService.instance;
  final ocrService = OcrService(apiSettings: apiSettingsService);

  // Загрузка модели здесь больше не нужна, так как она на сервере Python.
  // Проверка орфографии отключена, чтобы не вызывать ошибок с assets.

  runApp(
    MyApp(
      apiSettingsService: apiSettingsService,
      databaseService: dbService,
      ocrService: ocrService,
    ),
  );
}

class MyApp extends StatelessWidget {
  final ApiSettingsService apiSettingsService;
  final DatabaseService databaseService;
  final OcrService ocrService;

  const MyApp({
    super.key,
    required this.apiSettingsService,
    required this.databaseService,
    required this.ocrService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Предоставляем сервисы всему приложению
        ChangeNotifierProvider<ApiSettingsService>.value(
          value: apiSettingsService,
        ),
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
