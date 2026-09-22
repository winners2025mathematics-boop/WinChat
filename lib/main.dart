import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_native_sms/flutter_native_sms.dart';
import 'package:permission_handler/permission_handler.dart';

// ==================== CONFIG ====================
const String POLL_URL = 'https://winnersonlineschool.com/winners/poll.php';
const String GATEWAY_KEY = 'winners_gw_9f3a8c2e1b7d4f6a0c8e2d5b9a1f3c7e';
const int POLL_SECONDS = 20;

// SIM slots
const String SIM_AIRTEL = '0'; // Airtel on slot 1
const String SIM_TNM    = '1'; // TNM on slot 2

// ==================== REACTIVE STATE ====================
final ValueNotifier<List<String>> logNotifier = ValueNotifier<List<String>>([]);
final ValueNotifier<String> statusNotifier = ValueNotifier<String>('starting');
final ValueNotifier<String> lastPollNotifier = ValueNotifier<String>('never');
final ValueNotifier<int> sentCountNotifier = ValueNotifier<int>(0);
final ValueNotifier<bool> pausedNotifier = ValueNotifier<bool>(false);

void logLine(String s) {
  final line = '${DateTime.now().toIso8601String().substring(11, 19)}  $s';
  debugPrint(line);
  final current = List<String>.from(logNotifier.value);
  current.insert(0, line);
  if (current.length > 300) current.removeLast();
  logNotifier.value = current;
}

// ==================== NETWORK DETECTION ====================
/// Returns '0' for Airtel, '1' for TNM. Default: '0'.
String detectSim(String phone) {
  final p = phone.replaceAll(RegExp(r'[^0-9]'), '');
  final local = p.startsWith('265') ? '0${p.substring(3)}' : p;

  // TNM: 088, 089
  if (local.startsWith('088') || local.startsWith('089')) {
    return SIM_TNM;
  }

  // Airtel: 098, 099
  if (local.startsWith('098') || local.startsWith('099')) {
    return SIM_AIRTEL;
  }

  // Unknown prefix — fall back to Airtel
  return SIM_AIRTEL;
}

// ==================== PERMISSIONS ====================
Future<bool> requestSmsPermissions() async {
  try {
    final sms = await Permission.sms.request();
    logLine('Perm SMS: ${sms.isGranted ? "OK" : "DENIED"}');
    final phone = await Permission.phone.request();
    logLine('Perm Phone: ${phone.isGranted ? "OK" : "DENIED"}');
    return sms.isGranted && phone.isGranted;
  } catch (e) {
    logLine('Perm exception: $e');
    return false;
  }
}

// ==================== SEND SMS ====================
Future<bool> sendSms(String phone, String message) async {
  try {
    final sim = detectSim(phone);
    final network = sim == SIM_AIRTEL ? 'Airtel' : 'TNM';
    logLine('  sending SMS to $phone via $network (SIM $sim)');

    final sender = FlutterNativeSms();
    await sender.send(phone: phone, smsBody: message, sim: sim);

    logLine('  OK SMS sent to $phone');
    sentCountNotifier.value = sentCountNotifier.value + 1;
    return true;
  } catch (e) {
    logLine('  X SMS send failed: $e');
    return false;
  }
}

// ==================== POLL ONCE ====================
Future<bool> pollOnce() async {
  try {
    final res = await http.get(
      Uri.parse(POLL_URL),
      headers: {'X-Gateway-Key': GATEWAY_KEY},
    ).timeout(const Duration(seconds: 30));

    lastPollNotifier.value = DateTime.now().toIso8601String().substring(11, 19);

    if (res.statusCode != 200) {
      logLine('poll -> HTTP ${res.statusCode}: ${res.body}');
      return false;
    }

    final dynamic decoded = jsonDecode(res.body);

    if (decoded is List && decoded.isEmpty) {
      logLine('poll -> 200 OK, no jobs');
      return false;
    }

    if (decoded is Map<String, dynamic>) {
      final id = decoded['id']?.toString() ?? 'unknown';
      final phone = decoded['phone']?.toString() ?? '';
      final message = decoded['message']?.toString() ?? '';

      if (phone.isEmpty || message.isEmpty) {
        logLine('poll -> 200 OK, malformed job (id=$id)');
        return false;
      }

      logLine('poll -> 200 OK, JOB id=$id');
      logLine('  phone=$phone');
      await sendSms(phone, message);
      return true;
    }

    logLine('poll -> 200 OK, unexpected: ${res.body.substring(0, 80)}');
    return false;
  } catch (e) {
    logLine('poll exception: $e');
    return false;
  }
}

// ==================== POLL LOOP ====================
Future<void> pollingLoop() async {
  while (true) {
    if (pausedNotifier.value) {
      await Future.delayed(const Duration(seconds: 3));
      continue;
    }

    final gotJob = await pollOnce();

    if (gotJob) {
      await Future.delayed(const Duration(milliseconds: 500));
    } else {
      await Future.delayed(const Duration(seconds: POLL_SECONDS));
    }
  }
}

// ==================== MAIN ====================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GatewayApp());
}

class GatewayApp extends StatelessWidget {
  const GatewayApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SMS Gateway',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _permissionsGranted = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 200), _start);
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;

    logLine('--- starting gateway ---');

    try {
      await Permission.notification.request();
      logLine('Notification permission requested');
    } catch (e) {
      logLine('Notification error: $e');
    }

    _permissionsGranted = await requestSmsPermissions();
    if (mounted) setState(() {});
    if (!_permissionsGranted) {
      logLine('X SMS permission missing');
      statusNotifier.value = 'no permission';
      return;
    }

    statusNotifier.value = 'polling';
    logLine('--- polling every $POLL_SECONDS seconds ---');
    logLine('--- dual SIM: Airtel=slot 0, TNM=slot 1 ---');
    pollingLoop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SMS Gateway'),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: pausedNotifier,
            builder: (_, paused, __) => IconButton(
              icon: Icon(paused ? Icons.play_arrow : Icons.pause),
              onPressed: () {
                pausedNotifier.value = !paused;
                logLine(paused ? 'RESUMED' : 'PAUSED');
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => logNotifier.value = [],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Chip(
                  label: Text(
                    _permissionsGranted ? 'SMS OK' : 'SMS Permission Missing',
                    style: const TextStyle(fontSize: 12),
                  ),
                  backgroundColor: _permissionsGranted
                      ? Colors.green.shade100
                      : Colors.red.shade100,
                ),
                ValueListenableBuilder<String>(
                  valueListenable: statusNotifier,
                  builder: (_, s, __) => Chip(
                    label: Text('STATUS: $s',
                        style: const TextStyle(fontSize: 12)),
                    backgroundColor: s == 'polling'
                        ? Colors.blue.shade100
                        : Colors.orange.shade100,
                  ),
                ),
                const Chip(
                  label: Text('Airtel:0  TNM:1',
                      style: TextStyle(fontSize: 12)),
                  backgroundColor: Color(0xFFE0E0E0),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<String>(
                    valueListenable: lastPollNotifier,
                    builder: (_, t, __) => Text('Last poll: $t',
                        style: const TextStyle(fontSize: 12)),
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: sentCountNotifier,
                  builder: (_, c, __) => Text('Sent: $c',
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const Divider(height: 24),
            const Text('Activity:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                color: Colors.black87,
                padding: const EdgeInsets.all(8),
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: logNotifier,
                  builder: (_, lines, __) {
                    return ListView.builder(
                      itemCount: lines.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          lines[i],
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}