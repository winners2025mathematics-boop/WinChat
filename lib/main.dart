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
    if (current.length > 200) current.removeLast();
    logNotifier.value = current;
  } catch (_) {}
}

Future<bool> requestSmsPermissions() async {
  final statuses = await [Permission.sms, Permission.phone].request();
  final smsOk = statuses[Permission.sms]?.isGranted ?? false;
  final phoneOk = statuses[Permission.phone]?.isGranted ?? false;
  logLine('Permissions -> SMS: $smsOk  Phone: $phoneOk');
  return smsOk && phoneOk;
}

Future<void> fetchAndSend(String otpId) async {
  logLine('> fetchAndSend START otp_id=$otpId');
  try {
    final hasPermission = await requestSmsPermissions();
    if (!hasPermission) {
      logLine('  X SMS / Phone permission denied');
      return;
    }
    final url = Uri.parse('$SERVER_URL?id=$otpId');
    logLine('  GET $url');
    final res = await http.get(url, headers: {'X-Gateway-Key': GATEWAY_KEY}).timeout(const Duration(seconds: 15));
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
    logLine('  sending SMS via SIM $SIM_SLOT...');
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
  await Firebase.initializeApp();
  debugPrint('BACKGROUND FCM: ${message.data}');
  final otpId = message.data['otp_id']?.toString();
  if (otpId != null && otpId.isNotEmpty) {
    await fetchAndSend(otpId);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
  runApp(const GatewayApp());
}

class GatewayApp extends StatelessWidget {
  const GatewayApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WinChat SMS Gateway',
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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    logLine('init start');
    await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
    logLine('FCM permission requested');
    _permissionsGranted = await requestSmsPermissions();
    if (!_permissionsGranted) {
      logLine('WARN SMS permission missing');
    }
    final token = await FirebaseMessaging.instance.getToken();
    logLine('token=${token?.substring(0, 30)}...');
    setState(() => _token = token ?? 'null');
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      logLine('TOKEN REFRESHED: ${newToken.substring(0, 30)}...');
      setState(() => _token = newToken);
    });
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
      logLine('LAUNCHED FROM NOTIF: ${initial.data}');
      final otpId = initial.data['otp_id']?.toString();
      if (otpId != null && otpId.isNotEmpty) fetchAndSend(otpId);
    }
    logLine('init done');
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
            Row(children: [
              Chip(
                label: Text(
                  _permissionsGranted ? 'SMS OK' : 'SMS Permission Missing',
                  style: const TextStyle(fontSize: 12),
                ),
                backgroundColor: _permissionsGranted ? Colors.green.shade100 : Colors.red.shade100,
              ),
            ]),
            const SizedBox(height: 8),
            const Text('FCM TOKEN (paste into sendFCM.php):', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            SelectableText(_token, style: const TextStyle(fontSize: 11)),
            const Divider(height: 24),
            const Text('Activity:', style: TextStyle(fontWeight: FontWeight.bold)),
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
                          style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'),
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
