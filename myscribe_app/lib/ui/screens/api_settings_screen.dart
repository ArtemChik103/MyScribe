import 'package:flutter/material.dart';
import 'package:myscribe_app/config/api_config.dart';
import 'package:myscribe_app/services/api_settings_service.dart';
import 'package:myscribe_app/services/ocr_service.dart';
import 'package:provider/provider.dart';

class ApiSettingsScreen extends StatefulWidget {
  const ApiSettingsScreen({super.key});

  @override
  State<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends State<ApiSettingsScreen> {
  late final TextEditingController _urlController;
  bool _isChecking = false;
  BackendHealth? _health;
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings = Provider.of<ApiSettingsService>(context, listen: false);
    _urlController = TextEditingController(text: settings.effectiveBaseUrl);
    _checkHealth();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _saveUrl(String value) async {
    final settings = Provider.of<ApiSettingsService>(context, listen: false);
    await settings.setCustomBaseUrl(value);
    _urlController.text = settings.effectiveBaseUrl;
    await _checkHealth();
  }

  Future<void> _resetUrl() async {
    final settings = Provider.of<ApiSettingsService>(context, listen: false);
    await settings.resetCustomBaseUrl();
    _urlController.text = settings.effectiveBaseUrl;
    await _checkHealth();
  }

  Future<void> _checkHealth() async {
    if (_isChecking) return;

    setState(() {
      _isChecking = true;
      _error = null;
    });

    try {
      final health = await Provider.of<OcrService>(
        context,
        listen: false,
      ).checkHealth();
      if (!mounted) return;
      setState(() {
        _health = health;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _health = null;
        _error = _toUserError(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isChecking = false;
        });
      }
    }
  }

  String _toUserError(Object error) {
    final message = error.toString();
    return message.startsWith('Exception: ')
        ? message.substring('Exception: '.length)
        : message;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ApiSettingsService>();

    return Scaffold(
      appBar: AppBar(title: const Text('API и сервер')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Backend URL',
              hintText: 'http://127.0.0.1:8000',
              prefixIcon: Icon(Icons.link),
            ),
            onSubmitted: _saveUrl,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _saveUrl(_urlController.text),
                icon: const Icon(Icons.save),
                label: const Text('Сохранить'),
              ),
              OutlinedButton.icon(
                onPressed: () => _saveUrl(ApiConfig.androidTailscaleBaseUrl),
                icon: const Icon(Icons.public),
                label: const Text('Tailscale'),
              ),
              OutlinedButton.icon(
                onPressed: () => _saveUrl(ApiConfig.usbReverseBaseUrl),
                icon: const Icon(Icons.usb),
                label: const Text('USB'),
              ),
              TextButton.icon(
                onPressed: _resetUrl,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Сброс'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _InfoRow(label: 'Активный URL', value: settings.effectiveBaseUrl),
          _InfoRow(
            label: 'Источник',
            value: settings.hasCustomBaseUrl
                ? 'Сохраненная настройка'
                : 'Дефолт платформы или dart-define',
          ),
          const SizedBox(height: 16),
          Text('OCR engine', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<OcrEngine>(
            segments: const [
              ButtonSegment(
                value: OcrEngine.trocr,
                label: Text('TrOCR'),
                icon: Icon(Icons.edit_note),
              ),
              ButtonSegment(
                value: OcrEngine.paddle,
                label: Text('PaddleOCR'),
                icon: Icon(Icons.speed),
              ),
            ],
            selected: {settings.ocrEngine},
            onSelectionChanged: (selection) async {
              await settings.setOcrEngine(selection.first);
              if (!context.mounted) return;
              setState(() {});
            },
          ),
          const SizedBox(height: 8),
          _InfoRow(label: 'TrOCR', value: 'точнее для рукописного, тяжелее'),
          _InfoRow(
            label: 'PaddleOCR',
            value: 'альтернативный быстрый локальный режим, CPU-first',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _isChecking ? null : _checkHealth,
            icon: _isChecking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_sync),
            label: const Text('Проверить сервер'),
          ),
          const SizedBox(height: 16),
          _buildHealthCard(),
        ],
      ),
    );
  }

  Widget _buildHealthCard() {
    final health = _health;
    final error = _error;

    if (_isChecking && health == null && error == null) {
      return const Card(
        child: ListTile(
          leading: CircularProgressIndicator(),
          title: Text('Проверка подключения...'),
        ),
      );
    }

    if (error != null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.cloud_off, color: Colors.redAccent),
          title: const Text('Сервер недоступен'),
          subtitle: Text(error),
        ),
      );
    }

    if (health == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Статус еще не проверялся'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.cloud_done, color: Colors.green),
                SizedBox(width: 8),
                Text(
                  'Сервер доступен',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(label: 'Device', value: health.device),
            _InfoRow(label: 'Default OCR', value: health.defaultEngine),
            _InfoRow(label: 'CUDA', value: health.cudaAvailable ? 'да' : 'нет'),
            _InfoRow(
              label: 'Модель',
              value: health.modelLoaded ? 'загружена' : 'не загружена',
            ),
            _InfoRow(
              label: 'Папка модели',
              value: health.modelPathExists ? 'найдена' : 'не найдена',
            ),
            _InfoRow(
              label: 'Dataset',
              value: health.datasetDirExists && health.labelsFileExists
                  ? 'готов'
                  : 'нужна проверка',
            ),
            _InfoRow(label: 'Batch size', value: '${health.batchSize}'),
            _InfoRow(label: 'Resize', value: '${health.resizeMaxDim}px'),
            const Divider(height: 20),
            _EngineRow(title: 'TrOCR', health: health.engines['trocr']),
            _EngineRow(title: 'PaddleOCR', health: health.engines['paddle']),
          ],
        ),
      ),
    );
  }
}

class _EngineRow extends StatelessWidget {
  final String title;
  final BackendEngineHealth? health;

  const _EngineRow({required this.title, required this.health});

  @override
  Widget build(BuildContext context) {
    final engineHealth = health;
    final value = engineHealth == null
        ? 'нет данных'
        : [
            engineHealth.available ? 'установлен' : 'не установлен',
            engineHealth.loaded ? 'загружен' : 'не загружен',
            engineHealth.device,
            if (engineHealth.lang != null) 'lang=${engineHealth.lang}',
          ].join(' · ');

    return _InfoRow(label: title, value: value);
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: TextStyle(color: Colors.grey[400])),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
