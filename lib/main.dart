import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setMinimumSize(const Size(1200, 760));
  await windowManager.setSize(const Size(1600, 960));
  await windowManager.center();
  runApp(const AgentShellApp());
}

class AgentShellApp extends StatelessWidget {
  const AgentShellApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xffc9ff4a), brightness: Brightness.dark, useMaterial3: true),
        home: const AgentShell(),
      );
}

class AgentShell extends StatefulWidget {
  const AgentShell({super.key});
  @override
  State<AgentShell> createState() => _AgentShellState();
}

class _AgentShellState extends State<AgentShell> {
  static const _buildVersion = '0.6.0';
  final _focus = FocusNode();
  final _logs = <String>[];
  final _tasks = <dynamic>[];
  Process? _backend;
  WebSocketChannel? _socket;
  StreamSubscription? _socketSub;
  final _frameNotifier = ValueNotifier<Uint8List?>(null);
  int _sourceWidth = 1280;
  int _sourceHeight = 720;
  String _state = 'offline';
  String _token = '';
  String _accountId = '1';
  String _llmApiKey = '';
  String _llmBaseUrl = 'https://api.openai.com/v1';
  String _llmModel = 'gpt-4o-mini';
  bool _browserCommandRunning = false;
  bool _disposing = false;
  bool _backendRestarting = false;
  bool _backendReady = false;
  bool _manualMode = false;
  bool _nativeMode = false;
  DateTime _lastMouseMoveSent = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final settings = await _loadSettings();
    _token = settings['local_api_token'] ?? _randomToken();
    _llmApiKey = settings['llm_api_key'] ?? '';
    _llmBaseUrl = settings['llm_base_url'] ?? _llmBaseUrl;
    _llmModel = settings['llm_model'] ?? _llmModel;
    await _saveSettings();
    await _startBackend();
    await _connect();
    await _command('browser/start', {'accountId': _accountId});
  }

  Future<void> _startBackend() async {
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final backendDir = '$appDir\\backend';
    final packaged = File('$backendDir\\node.exe');
    if (packaged.existsSync()) {
      _backend = await Process.start(
        packaged.path,
        ['$backendDir\\dist\\server.js'],
        workingDirectory: backendDir,
        environment: {
          'LOCAL_API_TOKEN': _token,
          'VAULT_SECRET': _token,
          'PLAYWRIGHT_BROWSERS_PATH': '$backendDir\\ms-playwright',
          'LLM_API_KEY': _llmApiKey,
          'LLM_BASE_URL': _llmBaseUrl,
          'LLM_MODEL': _llmModel,
        },
      );
    } else {
      final root = Directory.current.parent.path;
      _backend = await Process.start('npm.cmd', ['run', 'serve'], workingDirectory: root, environment: {
        'LOCAL_API_TOKEN': _token,
        'VAULT_SECRET': _token,
        'LLM_API_KEY': _llmApiKey,
        'LLM_BASE_URL': _llmBaseUrl,
        'LLM_MODEL': _llmModel,
      });
    }
    _backend!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) => _addLog('backend: $line'));
    _backend!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) => _addLog('backend error: $line'));
    unawaited(_backend!.exitCode.then((code) async {
      if (_disposing || _backendRestarting) return;
      _addLog('backend exited with code $code; restarting once');
      if (mounted) setState(() => _state = 'backend stopped');
      _frameNotifier.value = null;
      _backendRestarting = true;
      try {
        await Future<void>.delayed(const Duration(seconds: 1));
        await _startBackend();
        await _connect();
        await _command('browser/start', {'accountId': _accountId});
      } catch (error) {
        _addLog('backend automatic restart failed: $error');
      } finally {
        _backendRestarting = false;
      }
    }));
    await _waitForBackend();
  }

  Future<void> _connect() async {
    await _socketSub?.cancel();
    await _socket?.sink.close();
    _socket = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:8787/ws?token=$_token'));
    _socketSub = _socket!.stream.listen(_onMessage, onError: (error) => _addLog('socket: $error'));
    await _refreshTasks();
  }

  void _onMessage(dynamic raw) {
    final message = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = message['type'];
    final payload = message['payload'] as Map<String, dynamic>? ?? {};
    if (type == 'frame') {
      _sourceWidth = payload['width'] as int;
      _sourceHeight = payload['height'] as int;
      _frameNotifier.value = base64Decode(payload['jpegBase64'] as String);
    } else if (type == 'snapshot') {
      setState(() => _state = '${payload['state']}');
    } else if (type == 'log') {
      _addLog('${payload['timestamp']} [${payload['level']}] ${payload['message']}');
    } else if (type == 'tasks') {
      setState(() { _tasks..clear()..addAll(payload['tasks'] as List? ?? []); });
    } else if (type == 'error') {
      _addLog('error: ${payload['message']}');
    }
  }

  Future<void> _command(String path, [Map<String, dynamic>? body]) async {
    await _sendCommand(path, body, allowRecovery: true);
  }

  Future<void> _sendCommand(String path, Map<String, dynamic>? body, {required bool allowRecovery}) async {
    try {
      final response = await http.post(Uri.parse('http://127.0.0.1:8787/api/$path'),
          headers: {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 60));
      if (mounted && !_backendReady) setState(() => _backendReady = true);
      if (response.statusCode >= 400) _addLog('command $path failed: ${response.body}');
    } catch (error) {
      _addLog('command $path failed: $error');
      if (mounted) setState(() { _backendReady = false; _state = 'backend offline'; });
      if (allowRecovery && !_disposing) {
        final recovered = await _recoverBackend();
        if (recovered) await _sendCommand(path, body, allowRecovery: false);
      }
    }
  }

  Future<void> _waitForBackend() async {
    Object? lastError;
    for (var attempt = 0; attempt < 40; attempt += 1) {
      try {
        final response = await http.get(Uri.parse('http://127.0.0.1:8787/api/health'), headers: {'Authorization': 'Bearer $_token'}).timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) {
          if (mounted) setState(() => _backendReady = true);
          return;
        }
      } catch (error) { lastError = error; }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('Backend did not become ready: $lastError');
  }

  Future<bool> _recoverBackend() async {
    if (_backendRestarting) {
      try { await _waitForBackend(); return true; } catch (_) { return false; }
    }
    _backendRestarting = true;
    try {
      _addLog('recovering local backend');
      _backend?.kill();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _startBackend();
      await _connect();
      return true;
    } catch (error) {
      _addLog('backend recovery failed: $error');
      return false;
    } finally {
      _backendRestarting = false;
    }
  }

  Future<void> _reloadPage() async {
    if (_browserCommandRunning) return;
    setState(() => _browserCommandRunning = true);
    try {
      await _command('browser/reload');
      _addLog('browser page reloaded');
    } finally {
      if (mounted) setState(() => _browserCommandRunning = false);
    }
  }

  Future<void> _startAgent() async {
    if (_llmApiKey.isEmpty) {
      _addLog('LLM API key is empty. Open Settings before Start.');
      await _showSettings();
      return;
    }
    _addLog('agent start requested');
    await _command('agent/start', {
      'accountId': _accountId,
      'dryRun': true,
      'llmApiKey': _llmApiKey,
      'llmBaseUrl': _llmBaseUrl,
      'llmModel': _llmModel,
    });
  }

  Future<void> _openTasks() async {
    _addLog('opening tasks section');
    await _command('browser/open-tasks');
  }

  Future<void> _openProductSearch() async {
    _addLog('opening product search tasks');
    await _command('browser/open-product-search');
  }

  Future<void> _autoOpenProductSearch() async {
    _addLog('automatically opening product-search workspace');
    await _command('browser/auto-product-search');
  }

  Future<void> _openCategory(Map<String, dynamic> category) async {
    final title = '${category['title']}';
    _addLog('opening category: $title');
    await _command('browser/open-category', {'title': title, 'href': category['href']});
  }

  Future<void> _switchPage(String role) async {
    await _command('browser/switch-page', {'role': role});
  }

  Future<void> _toggleManualMode() async {
    final next = !_manualMode;
    await _command('browser/manual-mode', {'enabled': next});
    if (mounted) setState(() => _manualMode = next);
    _addLog(next ? 'manual low-latency takeover enabled' : 'manual takeover disabled');
  }

  Future<void> _toggleNativeMode() async {
    if (_browserCommandRunning) return;
    final next = !_nativeMode;
    setState(() { _browserCommandRunning = true; _nativeMode = next; });
    _frameNotifier.value = null;
    try {
      await _command('browser/mode', {'mode': next ? 'native' : 'embedded', 'accountId': _accountId});
      _addLog(next
          ? 'native Chromium opened; complete CAPTCHA directly in its window'
          : 'returned to embedded streamed browser');
    } finally {
      if (mounted) setState(() => _browserCommandRunning = false);
    }
  }

  Future<void> _restartBrowser() async {
    if (_browserCommandRunning) return;
    setState(() {
      _browserCommandRunning = true;
    });
    _frameNotifier.value = null;
    try {
      await _command('browser/restart', {'accountId': _accountId});
      _addLog('browser fully restarted');
    } finally {
      if (mounted) setState(() => _browserCommandRunning = false);
    }
  }

  Future<void> _showSettings() async {
    final key = TextEditingController(text: _llmApiKey);
    final base = TextEditingController(text: _llmBaseUrl);
    final model = TextEditingController(text: _llmModel);
    final saved = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('LLM SETTINGS'),
      content: SizedBox(width: 520, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: key, obscureText: true, decoration: const InputDecoration(labelText: 'API key')),
        TextField(controller: base, decoration: const InputDecoration(labelText: 'OpenAI-compatible base URL')),
        TextField(controller: model, decoration: const InputDecoration(labelText: 'Vision model')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('SAVE'))],
    ));
    if (saved != true) return;
    _llmApiKey = key.text.trim(); _llmBaseUrl = base.text.trim(); _llmModel = model.text.trim();
    await _saveSettings();
    _addLog('LLM settings saved without restarting browser');
  }

  Future<void> _showAccountImport() async {
    final id = TextEditingController(text: _accountId);
    final cookies = TextEditingController();
    final imported = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('IMPORT ACCOUNT SESSION'),
      content: SizedBox(width: 620, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: id, decoration: const InputDecoration(labelText: 'Account ID')),
        const SizedBox(height: 12),
        TextField(controller: cookies, minLines: 8, maxLines: 14, decoration: const InputDecoration(labelText: 'Cookies JSON array', border: OutlineInputBorder())),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('IMPORT ENCRYPTED'))],
    ));
    if (imported != true) return;
    try {
      final decoded = jsonDecode(cookies.text);
      if (decoded is! List) throw const FormatException('Cookies must be a JSON array');
      final response = await http.post(Uri.parse('http://127.0.0.1:8787/api/accounts/import'), headers: {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'}, body: jsonEncode({'accountId': id.text.trim(), 'cookies': decoded}));
      if (response.statusCode >= 400) throw Exception(response.body);
      setState(() => _accountId = id.text.trim());
      _addLog('account imported into encrypted vault');
    } catch (error) { _addLog('account import failed: $error'); }
  }

  File get _settingsFile {
    final appData = Platform.environment['LOCALAPPDATA'] ?? Directory.current.path;
    return File('$appData\\OzonProfitAgent\\settings.json');
  }

  Future<Map<String, String>> _loadSettings() async {
    try {
      if (!await _settingsFile.exists()) return {};
      return (jsonDecode(await _settingsFile.readAsString()) as Map<String, dynamic>).map((key, value) => MapEntry(key, '$value'));
    } catch (_) { return {}; }
  }

  Future<void> _saveSettings() async {
    await _settingsFile.parent.create(recursive: true);
    await _settingsFile.writeAsString(jsonEncode({
      'local_api_token': _token,
      'llm_api_key': _llmApiKey,
      'llm_base_url': _llmBaseUrl,
      'llm_model': _llmModel,
    }), flush: true);
    if (Platform.isWindows) {
      await Process.run('icacls.exe', [_settingsFile.path, '/inheritance:r', '/grant:r', '${Platform.environment['USERNAME']}:F']);
    }
  }

  Future<void> _refreshTasks() async {
    try {
      final response = await http.get(Uri.parse('http://127.0.0.1:8787/api/tasks'), headers: {'Authorization': 'Bearer $_token'});
      final decoded = jsonDecode(response.body) as List;
      setState(() { _tasks..clear()..addAll(decoded); });
    } catch (_) {}
  }

  void _sendInput(Map<String, dynamic> payload) => _socket?.sink.add(jsonEncode({'type': 'input', 'payload': payload}));

  Offset _mapPointer(Offset local, Size shown) {
    final sourceRatio = _sourceWidth / _sourceHeight;
    final shownRatio = shown.width / shown.height;
    final fittedWidth = shownRatio > sourceRatio ? shown.height * sourceRatio : shown.width;
    final fittedHeight = shownRatio > sourceRatio ? shown.height : shown.width / sourceRatio;
    final dx = (shown.width - fittedWidth) / 2;
    final dy = (shown.height - fittedHeight) / 2;
    return Offset(((local.dx - dx) / fittedWidth * _sourceWidth).clamp(0, _sourceWidth.toDouble()),
        ((local.dy - dy) / fittedHeight * _sourceHeight).clamp(0, _sourceHeight.toDouble()));
  }

  void _addLog(String value) {
    if (!mounted) return;
    setState(() {
      _logs.add(value);
      if (_logs.length > 500) _logs.removeRange(0, _logs.length - 500);
    });
  }

  @override
  void dispose() {
    _disposing = true;
    _socketSub?.cancel();
    _socket?.sink.close();
    _backend?.kill();
    _focus.dispose();
    _frameNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('PROFIT / AGENT WORKSPACE v$_buildVersion'), actions: [
          _StatusChip(state: _state),
          IconButton(onPressed: _backendReady && _state != 'running' ? _startAgent : null, tooltip: 'Start dry run', icon: const Icon(Icons.play_arrow)),
          IconButton(onPressed: _backendReady && _state == 'running' ? () => _command('agent/pause') : null, tooltip: 'Pause agent', icon: const Icon(Icons.pause)),
          IconButton(onPressed: _backendReady && _state == 'paused' ? () => _command('agent/resume') : null, tooltip: 'Resume agent', icon: const Icon(Icons.play_circle_outline)),
          IconButton(onPressed: _backendReady && (_state == 'running' || _state == 'paused') ? () => _command('agent/stop') : null, tooltip: 'Stop agent', icon: const Icon(Icons.stop)),
          IconButton(onPressed: _backendReady ? () => _switchPage('task') : null, tooltip: 'Show pinned task tab', icon: const Icon(Icons.assignment_turned_in_outlined)),
          IconButton(onPressed: _backendReady ? () => _switchPage('search') : null, tooltip: 'Show search tab', icon: const Icon(Icons.public)),
          IconButton(onPressed: _backendReady ? _toggleManualMode : null, tooltip: 'Toggle low-latency manual takeover', icon: Icon(_manualMode ? Icons.speed : Icons.pan_tool_alt_outlined)),
          IconButton(onPressed: _backendReady ? _toggleNativeMode : null, tooltip: 'Toggle native Chromium window', icon: Icon(_nativeMode ? Icons.open_in_browser : Icons.web_asset)),
          IconButton(onPressed: _browserCommandRunning ? null : _reloadPage, tooltip: 'Refresh current page', icon: const Icon(Icons.refresh)),
          if (_browserCommandRunning) const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          IconButton(onPressed: _showSettings, tooltip: 'LLM settings', icon: const Icon(Icons.settings)),
          PopupMenuButton<String>(
            tooltip: 'More actions',
            onSelected: (value) {
              if (value == 'auto') _autoOpenProductSearch();
              if (value == 'tasks') _openTasks();
              if (value == 'matching') _openProductSearch();
              if (value == 'restart') _restartBrowser();
              if (value == 'account') _showAccountImport();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'auto', child: Text('Auto open product search')),
              PopupMenuItem(value: 'tasks', child: Text('Open tasks section')),
              PopupMenuItem(value: 'matching', child: Text('Open product search')),
              PopupMenuItem(value: 'restart', child: Text('Restart Chromium')),
              PopupMenuItem(value: 'account', child: Text('Import account session')),
            ],
          ),
          const SizedBox(width: 12),
        ]),
        body: Row(children: [
          Expanded(flex: 4, child: Column(children: [
            Expanded(child: LayoutBuilder(builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              return Focus(
                focusNode: _focus,
                autofocus: true,
                onKeyEvent: (_, event) {
                  final action = event is KeyDownEvent ? 'down' : event is KeyUpEvent ? 'up' : null;
                  if (event is KeyDownEvent && event.character != null && event.character!.isNotEmpty && !HardwareKeyboard.instance.isControlPressed && !HardwareKeyboard.instance.isAltPressed) {
                    _sendInput({'type': 'text', 'text': event.character});
                  } else if (action != null) {
                    _sendInput({'type': 'key', 'action': action, 'key': event.logicalKey.keyLabel});
                  }
                  return KeyEventResult.handled;
                },
                child: Listener(
                  onPointerDown: (event) { final p = _mapPointer(event.localPosition, size); _sendInput({'type': 'mouse', 'action': 'down', 'x': p.dx, 'y': p.dy}); },
                  onPointerUp: (event) { final p = _mapPointer(event.localPosition, size); _sendInput({'type': 'mouse', 'action': 'up', 'x': p.dx, 'y': p.dy}); },
                  onPointerMove: (event) {
                    final now = DateTime.now();
                    final minimumDelay = _manualMode ? 16 : 50;
                    if (now.difference(_lastMouseMoveSent).inMilliseconds < minimumDelay) return;
                    _lastMouseMoveSent = now;
                    final p = _mapPointer(event.localPosition, size);
                    _sendInput({'type': 'mouse', 'action': 'move', 'x': p.dx, 'y': p.dy});
                  },
                  onPointerSignal: (event) { if (event is PointerScrollEvent) _sendInput({'type': 'wheel', 'deltaX': event.scrollDelta.dx, 'deltaY': event.scrollDelta.dy}); },
                  child: ColoredBox(color: Colors.black, child: Center(child: ValueListenableBuilder<Uint8List?>(
                    valueListenable: _frameNotifier,
                    builder: (_, frame, __) => frame == null
                        ? const Text('Starting unified Chromium...')
                        : Image.memory(frame, fit: BoxFit.contain, gaplessPlayback: true),
                  ))),
                ),
              );
            })),
            SizedBox(height: 210, child: _LogPanel(logs: _logs)),
          ])),
          SizedBox(width: 360, child: _TaskPanel(tasks: _tasks, accountId: _accountId, onAccountChanged: (value) => _accountId = value, onRefresh: _refreshTasks, onOpenTask: _openCategory)),
        ]),
      );
}

class _StatusChip extends StatelessWidget {
  final String state;
  const _StatusChip({required this.state});
  @override
  Widget build(BuildContext context) => Chip(label: Text(state.toUpperCase()), avatar: Icon(Icons.circle, size: 10, color: state == 'running' ? Colors.lightGreenAccent : Colors.orangeAccent));
}

class _LogPanel extends StatelessWidget {
  final List<String> logs;
  const _LogPanel({required this.logs});
  @override
  Widget build(BuildContext context) => ColoredBox(color: const Color(0xff10120f), child: ListView.builder(padding: const EdgeInsets.all(12), itemCount: logs.length, itemBuilder: (_, i) => SelectableText(logs[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 11))));
}

class _TaskPanel extends StatelessWidget {
  final List<dynamic> tasks;
  final String accountId;
  final ValueChanged<String> onAccountChanged;
  final VoidCallback onRefresh;
  final ValueChanged<Map<String, dynamic>> onOpenTask;
  const _TaskPanel({required this.tasks, required this.accountId, required this.onAccountChanged, required this.onRefresh, required this.onOpenTask});
  @override
  Widget build(BuildContext context) => ColoredBox(color: const Color(0xff171a15), child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('SESSION', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.4)),
    const SizedBox(height: 10),
    TextFormField(initialValue: accountId, decoration: const InputDecoration(labelText: 'Account ID'), onChanged: onAccountChanged),
    const SizedBox(height: 20),
    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('TASKS (${tasks.length})', style: const TextStyle(fontWeight: FontWeight.bold)), IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh))]),
    Expanded(child: ListView.builder(itemCount: tasks.length, itemBuilder: (_, i) { final task = tasks[i] as Map<String, dynamic>; return Card(child: ListTile(title: Text('${task['title']}'), subtitle: Text('${task['reward'] ?? task['shopName']} / ${task['status']}'), trailing: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: () => onOpenTask(task)))); })),
  ])));
}

String _randomToken() => '${DateTime.now().microsecondsSinceEpoch}-${Platform.localHostname}-${ProcessInfo.currentRss}';
