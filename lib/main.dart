import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_native_sms/flutter_native_sms.dart';
import 'package:permission_handler/permission_handler.dart';

// ============================================================
// CONFIGURATION
// ============================================================

const String pollUrl =
    'https://winnersonlineschool.com/winners/poll.php';

const String gatewayKey =
    'winners_gw_9f3a8c2e1b7d4f6a0c8e2d5b9a1f3c7e';

// Poll interval when there is no job.
const int pollSeconds = 20;

// flutter_native_sms:
// 0 = SIM 1
// 1 = SIM 2
//
// TNM is in SIM 2.
const String simSlot = '1';


// ============================================================
// STATE
// ============================================================

final ValueNotifier<List<String>> logs =
    ValueNotifier<List<String>>([]);

final ValueNotifier<String> status =
    ValueNotifier<String>('Starting');

final ValueNotifier<String> lastPoll =
    ValueNotifier<String>('Never');

final ValueNotifier<int> sentCount =
    ValueNotifier<int>(0);

final ValueNotifier<int> failedCount =
    ValueNotifier<int>(0);

final ValueNotifier<bool> paused =
    ValueNotifier<bool>(false);


// ============================================================
// LOG
// ============================================================

void logMessage(String message) {
  final now = DateTime.now();

  final time =
      '${now.hour.toString().padLeft(2, '0')}:'
      '${now.minute.toString().padLeft(2, '0')}:'
      '${now.second.toString().padLeft(2, '0')}';

  final line = '$time  $message';

  debugPrint(line);

  final copy = List<String>.from(logs.value);

  copy.insert(0, line);

  if (copy.length > 300) {
    copy.removeLast();
  }

  logs.value = copy;
}


// ============================================================
// PERMISSIONS
// ============================================================

Future<bool> requestPermissions() async {
  try {
    final smsPermission =
        await Permission.sms.request();

    logMessage(
      'SMS permission: '
      '${smsPermission.isGranted ? "GRANTED" : "DENIED"}',
    );

    final phonePermission =
        await Permission.phone.request();

    logMessage(
      'Phone permission: '
      '${phonePermission.isGranted ? "GRANTED" : "DENIED"}',
    );

    return smsPermission.isGranted &&
        phonePermission.isGranted;
  } catch (e) {
    logMessage(
      'Permission error: $e',
    );

    return false;
  }
}


// ============================================================
// SEND SMS
// ============================================================

Future<bool> sendSms({
  required String phone,
  required String message,
}) async {
  try {
    logMessage(
      'SMS SEND START',
    );

    logMessage(
      'Phone: $phone',
    );

    logMessage(
      'SIM slot: $simSlot',
    );

    logMessage(
      'Message length: ${message.length}',
    );

    final sender =
        FlutterNativeSms();

    await sender.send(
      phone: phone,
      smsBody: message,
      sim: simSlot,
    );

    sentCount.value =
        sentCount.value + 1;

    logMessage(
      'SMS SEND REQUEST ACCEPTED',
    );

    return true;
  } catch (e) {
    failedCount.value =
        failedCount.value + 1;

    logMessage(
      'SMS SEND FAILED: $e',
    );

    return false;
  }
}


// ============================================================
// SERVER RESPONSE
// ============================================================

class SmsJob {
  final String id;
  final String phone;
  final String message;

  SmsJob({
    required this.id,
    required this.phone,
    required this.message,
  });

  factory SmsJob.fromJson(
    Map<String, dynamic> json,
  ) {
    return SmsJob(
      id: json['id']?.toString() ?? '',
      phone: json['phone']?.toString().trim() ?? '',
      message: json['message']?.toString() ?? '',
    );
  }
}


// ============================================================
// POLL SERVER
// ============================================================

Future<SmsJob?> pollServer() async {
  try {
    final response = await http
        .get(
          Uri.parse(pollUrl),
          headers: {
            'X-Gateway-Key': gatewayKey,
            'Accept': 'application/json',
          },
        )
        .timeout(
          const Duration(seconds: 30),
        );

    final now = DateTime.now();

    lastPoll.value =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';

    logMessage(
      'HTTP ${response.statusCode}',
    );

    if (response.statusCode != 200) {
      logMessage(
        'SERVER ERROR: ${response.body}',
      );

      return null;
    }

    final body = response.body.trim();

    if (body.isEmpty) {
      logMessage(
        'SERVER: empty response',
      );

      return null;
    }

    dynamic decoded;

    try {
      decoded = jsonDecode(body);
    } catch (e) {
      logMessage(
        'JSON ERROR: $e',
      );

      logMessage(
        'Response: $body',
      );

      return null;
    }

    // --------------------------------------------------------
    // NO JOB
    // --------------------------------------------------------

    if (decoded is List) {
      if (decoded.isEmpty) {
        logMessage(
          'SERVER: no jobs',
        );
      } else {
        logMessage(
          'SERVER returned a list instead of a single job',
        );
      }

      return null;
    }

    // --------------------------------------------------------
    // JOB
    // --------------------------------------------------------

    if (decoded is Map<String, dynamic>) {
      final job =
          SmsJob.fromJson(decoded);

      if (job.id.isEmpty) {
        logMessage(
          'JOB ERROR: missing id',
        );

        return null;
      }

      if (job.phone.isEmpty) {
        logMessage(
          'JOB ${job.id}: missing phone',
        );

        return null;
      }

      if (job.message.isEmpty) {
        logMessage(
          'JOB ${job.id}: missing message',
        );

        return null;
      }

      logMessage(
        'JOB RECEIVED: ${job.id}',
      );

      logMessage(
        'Recipient: ${job.phone}',
      );

      return job;
    }

    logMessage(
      'SERVER: unexpected response format',
    );

    return null;
  } catch (e) {
    logMessage(
      'POLL ERROR: $e',
    );

    return null;
  }
}


// ============================================================
// JOB PROCESSING
// ============================================================

bool processingJob = false;

Future<void> processOneJob() async {
  if (processingJob) {
    logMessage(
      'Another job is already being processed',
    );

    return;
  }

  processingJob = true;

  try {
    final job =
        await pollServer();

    if (job == null) {
      return;
    }

    status.value =
        'Sending';

    final success =
        await sendSms(
      phone: job.phone,
      message: job.message,
    );

    if (success) {
      logMessage(
        'JOB ${job.id}: SEND ACCEPTED',
      );

      status.value =
          'Polling';

      /*
       IMPORTANT:

       Your current poll.php API only returns a job.
       It does not provide a completion endpoint in
       the code you supplied.

       Therefore we cannot safely invent an acknowledgement
       request here.

       poll.php must mark the job completed/claimed on its
       own side, or provide something such as:

       POST /complete.php
       {
         "id": "...",
         "status": "sent"
       }

       Otherwise the same job can potentially be returned
       repeatedly.
      */
    } else {
      logMessage(
        'JOB ${job.id}: SEND FAILED',
      );

      status.value =
          'Send failed';
    }
  } finally {
    processingJob = false;
  }
}


// ============================================================
// POLLING LOOP
// ============================================================

bool loopRunning = false;

Future<void> startPolling() async {
  if (loopRunning) {
    return;
  }

  loopRunning = true;

  status.value =
      'Polling';

  logMessage(
    '================================',
  );

  logMessage(
    'SMS GATEWAY STARTED',
  );

  logMessage(
    'Poll URL: $pollUrl',
  );

  logMessage(
    'Polling interval: $pollSeconds seconds',
  );

  logMessage(
    'SMS SIM: $simSlot',
  );

  logMessage(
    '================================',
  );

  while (loopRunning) {
    if (paused.value) {
      status.value =
          'Paused';

      await Future.delayed(
        const Duration(seconds: 2),
      );

      continue;
    }

    await processOneJob();

    if (!paused.value) {
      status.value =
          'Polling';
    }

    await Future.delayed(
      const Duration(seconds: pollSeconds),
    );
  }
}


// ============================================================
// MAIN
// ============================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    const SmsGatewayApp(),
  );
}


// ============================================================
// APP
// ============================================================

class SmsGatewayApp extends StatelessWidget {
  const SmsGatewayApp({super.key});

  @override
  Widget build(
    BuildContext context,
  ) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SMS Gateway',

      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),

      home: const GatewayHome(),
    );
  }
}


// ============================================================
// HOME
// ============================================================

class GatewayHome extends StatefulWidget {
  const GatewayHome({super.key});

  @override
  State<GatewayHome> createState() =>
      _GatewayHomeState();
}


class _GatewayHomeState
    extends State<GatewayHome> {

  bool permissionsGranted = false;
  bool started = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance
        .addPostFrameCallback(
      (_) => initialize(),
    );
  }


  Future<void> initialize() async {
    if (started) {
      return;
    }

    started = true;

    logMessage(
      'Initializing SMS Gateway...',
    );

    try {
      await Permission.notification.request();
    } catch (_) {}

    permissionsGranted =
        await requestPermissions();

    if (mounted) {
      setState(() {});
    }

    if (!permissionsGranted) {
      status.value =
          'Permission denied';

      logMessage(
        'Gateway NOT started',
      );

      logMessage(
        'SMS permissions are required',
      );

      return;
    }

    logMessage(
      'All required permissions available',
    );

    await startPolling();
  }


  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(

      appBar: AppBar(
        title: const Text(
          'SMS Gateway',
        ),

        actions: [

          ValueListenableBuilder<bool>(
            valueListenable: paused,

            builder:
                (context, isPaused, child) {

              return IconButton(
                tooltip: isPaused
                    ? 'Resume'
                    : 'Pause',

                icon: Icon(
                  isPaused
                      ? Icons.play_arrow
                      : Icons.pause,
                ),

                onPressed: () {

                  paused.value =
                      !paused.value;

                  logMessage(
                    paused.value
                        ? 'GATEWAY PAUSED'
                        : 'GATEWAY RESUMED',
                  );
                },
              );
            },
          ),

          IconButton(
            tooltip: 'Clear logs',

            icon: const Icon(
              Icons.delete_outline,
            ),

            onPressed: () {
              logs.value = [];
            },
          ),
        ],
      ),


      body: Padding(
        padding:
            const EdgeInsets.all(12),

        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.stretch,

          children: [

            // =================================================
            // STATUS CHIPS
            // =================================================

            Wrap(
              spacing: 8,
              runSpacing: 6,

              children: [

                Chip(
                  label: Text(
                    permissionsGranted
                        ? 'SMS OK'
                        : 'SMS Permission Missing',
                  ),
                ),

                ValueListenableBuilder<String>(
                  valueListenable: status,

                  builder:
                      (context, value, child) {

                    return Chip(
                      label: Text(
                        'STATUS: $value',
                      ),
                    );
                  },
                ),

                const Chip(
                  label: Text(
                    'TNM • SIM 2',
                  ),
                ),

              ],
            ),


            const SizedBox(
              height: 8,
            ),


            // =================================================
            // COUNTERS
            // =================================================

            Row(
              children: [

                Expanded(
                  child:
                      ValueListenableBuilder<String>(
                    valueListenable:
                        lastPoll,

                    builder:
                        (context, value, child) {

                      return Text(
                        'Last poll: $value',
                        style:
                            const TextStyle(
                          fontSize: 12,
                        ),
                      );
                    },
                  ),
                ),

                ValueListenableBuilder<int>(
                  valueListenable:
                      sentCount,

                  builder:
                      (context, value, child) {

                    return Text(
                      'Accepted: $value',
                      style:
                          const TextStyle(
                        fontSize: 12,
                      ),
                    );
                  },
                ),

                const SizedBox(
                  width: 12,
                ),

                ValueListenableBuilder<int>(
                  valueListenable:
                      failedCount,

                  builder:
                      (context, value, child) {

                    return Text(
                      'Failed: $value',
                      style:
                          const TextStyle(
                        fontSize: 12,
                      ),
                    );
                  },
                ),

              ],
            ),


            const Divider(
              height: 24,
            ),


            // =================================================
            // LOG TITLE
            // =================================================

            const Text(
              'Activity',
              style: TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),


            const SizedBox(
              height: 5,
            ),


            // =================================================
            // LOG WINDOW
            // =================================================

            Expanded(
              child: Container(

                color:
                    Colors.black87,

                padding:
                    const EdgeInsets.all(8),

                child:
                    ValueListenableBuilder<
                        List<String>>(
                  valueListenable:
                      logs,

                  builder:
                      (context, lines, child) {

                    if (lines.isEmpty) {
                      return const Center(
                        child: Text(
                          'Waiting...',
                          style: TextStyle(
                            color:
                                Colors.white54,
                            fontFamily:
                                'monospace',
                          ),
                        ),
                      );
                    }

                    return ListView.builder(

                      itemCount:
                          lines.length,

                      itemBuilder:
                          (context, index) {

                        return Padding(
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            vertical: 1,
                          ),

                          child: Text(
                            lines[index],

                            style:
                                const TextStyle(
                              color:
                                  Colors.greenAccent,
                              fontSize: 11,
                              fontFamily:
                                  'monospace',
                            ),
                          ),
                        );
                      },
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