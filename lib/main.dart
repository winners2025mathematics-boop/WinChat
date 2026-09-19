import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_native_sms/flutter_native_sms.dart';
import 'package:permission_handler/permission_handler.dart';

const String SERVER_URL = 'https://winnersonlineschool.com/winners/get_otp.php';
const String GATEWAY_KEY = 'winners_gw_9f3a8c2e1b7d4f6a0c8e2d5b9a1f3c7e';
const String SIM_SLOT = '0';

final ValueNotifier<List<String>> logNotifier = ValueNotifier<List<String>>([]);

void logLine(String s) {
  final line = '${DateTime.now().toIso8601String().substring(11, 19)}  $s';
  debugPrint(line);
  try {
    final current = List<String>.from(logNotifier.value);
    current.insert(0, line);
    if (current.length > 300) current.removeLast();
    logNotifier.value = current;
  } catch (_) {}
}

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

Future<void> fetchAndSend(String otpId) async {
  logLine('> fetchAndSend START otp_id=$otpId');
  try {
    final hasPermission = await requestSmsPermissions();
    if (!hasPermission) {
      logLine('  X SMS permission denied');
      return;
    }

    final url = Uri.parse('$SERVER_URL?id=$otpId');
    logLine('  GET $url');
    final res = await http
        .get(url, headers: {'X-Gateway-Key': GATEWAY_KEY})
        .timeout(const Duration(seconds: 20));
    logLine('  HTTP ${res.statusCode}');
    logLine('  body: ${res.body}');

    if (res.statusCode != 200) {
      logLine('  X server returned ${res.statusCode}');
      return;
    }

    final dynamic decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      logLine('  X invalid JSON');
      return;
    }

    final phone = decoded['phone']?.toString().trim();
    final msg = decoded['message']?.toString();
    if (phone == null || phone.isEmpty || msg == null || msg.isEmpty) {
      logLine('  X missing phone or message');
      return;
    }

    logLine('  phone=$phone');
    logLine('  msg=${msg.replaceAll('\n', ' / ')}');
    logLine('  sending via SIM $SIM_SLOT...');

    final sender = FlutterNativeSms();
    await sender.send(phone: phone, smsBody: msg, sim: SIM_SLOT);
    logLine('  OK SMS sent to $phone');
  } catch (e, st) {
    logLine('  X EXCEPTION: $e');
    logLine('  $st');
  }
  logLine('< fetchAndSend END');
}

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    debugPrint('BG FCM: ${message.data}');
    final otpId = message.data['otp_id']?.toString();
    if (otpId != null && otpId.isNotEmpty) {
      await fetchAndSend(otpId);
    }
  } catch (e) {
    debugPrint('BG error: $e');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Show UI first
  runApp(const GatewayApp());

  // Then initialize Firebase
  try {
    logLine('Firebase init...');
    await Firebase.initializeApp();
    logLine('Firebase OK');

    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
    logLine('Background handler set');
  } catch (e) {
    logLine('Firebase FAILED: $e');
  }
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
  String _token = 'loading...';
  bool _permissionsGranted = false;
  bool _initStarted = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 300), _init);
  }

  Future<void> _init() async {
    if (_initStarted) return;
    _initStarted = true;

    logLine('--- init start ---');

    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      logLine('FCM permission requested');
    } catch (e) {
      logLine('FCM permission error: $e');
    }

    try {
      _permissionsGranted = await requestSmsPermissions();
      if (mounted) setState(() {});
    } catch (e) {
      logLine('SMS permission error: $e');
    }

    try {
      final token = await FirebaseMessaging.instance.getToken();
      logLine('token=${token != null ? token.substring(0, 30) : "NULL"}...');
      if (mounted) setState(() => _token = token ?? 'null');
    } catch (e) {
      logLine('getToken error: $e');
      if (mounted) setState(() => _token = 'error');
    }

    try {
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
        logLine('TOKEN REFRESHED');
        if (mounted) setState(() => _token = newToken);
      });
    } catch (_) {}

    try {
      FirebaseMessaging.onMessage.listen((RemoteMessage msg) {
        logLine('FOREGROUND FCM: ${msg.data}');
        final otpId = msg.data['otp_id']?.toString();
        if (otpId != null && otpId.isNotEmpty) {
          fetchAndSend(otpId);
        } else {
          logLine('  WARN no otp_id');
        }
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage msg) {
        logLine('NOTIF TAPPED: ${msg.data}');
        final otpId = msg.data['otp_id']?.toString();
        if (otpId != null && otpId.isNotEmpty) fetchAndSend(otpId);
      });

      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        logLine('LAUNCHED FROM NOTIF');
        final otpId = initial.data['otp_id']?.toString();
        if (otpId != null && otpId.isNotEmpty) fetchAndSend(otpId);
      }
    } catch (e) {
      logLine('FCM listener error: $e');
    }

    logLine('--- init done ---');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SMS Gateway'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final ok = await requestSmsPermissions();
              setState(() => _permissionsGranted = ok);
            },
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
            Row(
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
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'FCM TOKEN (paste into sendFCM.php):',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            SelectableText(_token, style: const TextStyle(fontSize: 11)),
            const Divider(height: 24),
            const Text(
              'Activity:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
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
