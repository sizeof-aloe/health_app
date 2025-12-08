import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 한국어 날짜 포맷 초기화 (빈 문자열 처리로 에러 방지)
  await initializeDateFormatting('ko_KR', ""); 
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Health Monitor',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const HealthDashboardPage(),
    );
  }
}

// ---------------------------------------------------------------------------
// 1. Controller: 모든 로직 (블루투스, 파싱, 알림)
// ---------------------------------------------------------------------------
class HealthController extends GetxController {
  // [설정] 연결할 디바이스 이름
  static const String TARGET_DEVICE_NAME = "HC-05";
  
  // [설정] 경고 임계값
  final double LOW_SPO2_THRESHOLD = 90.0;
  final double LOW_HEART_RATE_THRESHOLD = 30.0;
  final double HIGH_HEART_RATE_THRESHOLD = 120.0;
  
  // 상태 변수
  var heartRate = 0.0.obs;
  var spo2 = 0.0.obs;
  var isConnected = false.obs;
  var connectionStatus = "연결 끊김".obs;
  var lastUpdated = '-'.obs;
  
  // 그래프 데이터
  var waveformData = <FlSpot>[].obs;
  double _timeCounter = 0;

  // 블루투스 변수
  BluetoothConnection? _connection;
  String _inputBuffer = "";
  var isScanning = false.obs;
  StreamSubscription<BluetoothDiscoveryResult>? _discoveryStreamSubscription;
  Timer? _reconnectTimer;
  bool _isUserIntentionalDisconnect = false;

  // 알림 및 소리 객체
  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  
  // 경고 쿨다운 (5초)
  DateTime? _lastAlertTime; 
  static const int ALERT_COOLDOWN_SECONDS = 5; 

  @override
  void onInit() {
    super.onInit();
    _requestPermissions(); // 권한 요청
    _initWaveform(); // 그래프 초기화
    _initNotifications(); // 알림 설정 초기화
    
    // 앱 시작 1초 후 자동 연결 시도
    Future.delayed(const Duration(seconds: 1), autoConnect);
  }

  // 알림 초기화
  void _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );

    await _notificationsPlugin.initialize(initializationSettings);
  }

  @override
  void onClose() {
    _reconnectTimer?.cancel();
    _discoveryStreamSubscription?.cancel();
    _connection?.dispose();
    _audioPlayer.dispose();
    super.onClose();
  }

  // 그래프 초기화
  void _initWaveform() {
    for (int i = 0; i < 50; i++) {
      waveformData.add(FlSpot(i.toDouble(), 0));
    }
    _timeCounter = 50;
  }

  // 권한 요청
  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.notification, // 알림 권한 추가
    ].request();
  }

  // -------------------------------------------------------------------------
  // [로직 1] 블루투스 자동 연결 및 재연결
  // -------------------------------------------------------------------------
  void autoConnect() async {
    if (isConnected.value) return;

    _isUserIntentionalDisconnect = false;
    connectionStatus.value = "$TARGET_DEVICE_NAME 찾는 중...";

    bool isEnabled = await FlutterBluetoothSerial.instance.isEnabled ?? false;
    if (!isEnabled) {
       connectionStatus.value = "블루투스 꺼짐. 대기 중...";
       _scheduleReconnect();
       return;
    }

    // 1. 페어링된 목록 확인
    List<BluetoothDevice> bondedDevices = await FlutterBluetoothSerial.instance.getBondedDevices();
    try {
      BluetoothDevice target = bondedDevices.firstWhere((d) => d.name == TARGET_DEVICE_NAME);
      print("페어링 목록 발견: ${target.name}");
      _startConnection(target);
      return;
    } catch (e) {
      print("페어링 목록에 없음. 스캔 시작.");
    }

    // 2. 주변 스캔
    _startScanForTarget();
  }

  void _startScanForTarget() {
    if (isScanning.value) return;
    isScanning.value = true;
    connectionStatus.value = "주변 검색 중...";

    _discoveryStreamSubscription = FlutterBluetoothSerial.instance.startDiscovery().listen((r) {
      if (r.device.name == TARGET_DEVICE_NAME) {
        _discoveryStreamSubscription?.cancel();
        isScanning.value = false;
        _startConnection(r.device);
      }
    });

    _discoveryStreamSubscription?.onDone(() {
      isScanning.value = false;
      if (!isConnected.value) {
        connectionStatus.value = "기기 못 찾음. 재시도...";
        _scheduleReconnect();
      }
    });
  }

  void _startConnection(BluetoothDevice device) async {
    try {
      connectionStatus.value = "연결 시도 중...";
      _connection = await BluetoothConnection.toAddress(device.address);
      
      isConnected.value = true;
      connectionStatus.value = "연결됨";
      _reconnectTimer?.cancel();

      _connection!.input!.listen(_onDataReceived).onDone(() {
        isConnected.value = false;
        if (_isUserIntentionalDisconnect) {
          connectionStatus.value = "연결 종료됨";
        } else {
          connectionStatus.value = "연결 끊김! 재연결...";
          _scheduleReconnect();
        }
      });

    } catch (e) {
      isConnected.value = false;
      connectionStatus.value = "연결 실패. 재시도...";
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), autoConnect);
  }

  void toggleConnection(BuildContext context) {
    if (isConnected.value) {
      _isUserIntentionalDisconnect = true;
      _connection?.dispose();
      isConnected.value = false;
      connectionStatus.value = "연결 종료";
    } else {
      autoConnect();
    }
  }

  // -------------------------------------------------------------------------
  // [로직 2] 데이터 파싱 및 처리
  // -------------------------------------------------------------------------
  void _onDataReceived(Uint8List data) {
    String incomingData = utf8.decode(data);
    _inputBuffer += incomingData;

    while (_inputBuffer.contains('\n')) {
      int index = _inputBuffer.indexOf('\n');
      String packet = _inputBuffer.substring(0, index).trim();
      _inputBuffer = _inputBuffer.substring(index + 1);
      _parseAndProcess(packet);
    }
  }

  void _parseAndProcess(String packet) {
    if (packet.isEmpty) return;
    try {
      List<String> values = packet.split(',');
      double? raw, sp, hr;

      // Case 1: 시간, RAW, SPO2, BPM (4개)
      if (values.length >= 4) {
        raw = double.parse(values[1]);
        sp = double.parse(values[2]);
        hr = double.parse(values[3]);
      } 
      // Case 2: RAW, SPO2, BPM (3개)
      else if (values.length == 3) {
        raw = double.parse(values[0]);
        sp = double.parse(values[1]);
        hr = double.parse(values[2]);
      }

      if (raw != null && sp != null && hr != null) {
        spo2.value = sp;
        heartRate.value = hr;
        
        _updateGraph(raw);
        _checkThresholds(sp, hr); // [New] 경고 체크
      }
    } catch (e) {
      print("Parsing Error: $packet");
    }
  }

  // -------------------------------------------------------------------------
  // [로직 3] 경고 시스템 (소리 + 알림)
  // -------------------------------------------------------------------------
  void _checkThresholds(double currentSpo2, double currentHeartRate) {
    // 쿨다운 체크
    if (_lastAlertTime != null && 
        DateTime.now().difference(_lastAlertTime!).inSeconds < ALERT_COOLDOWN_SECONDS) {
      return; 
    }

    String alertMessage = "";
    bool shouldAlert = false;

    // 센서 노이즈(0~10) 제외하고 위험 범위 체크
    if (currentSpo2 < LOW_SPO2_THRESHOLD && currentSpo2 > 10.0) {
      alertMessage = "위험! 산소포화도 저하 ($currentSpo2%)";
      shouldAlert = true;
    } else if (currentHeartRate < LOW_HEART_RATE_THRESHOLD && currentHeartRate > 10.0) {
      alertMessage = "위험! 서맥 감지 ($currentHeartRate BPM)";
      shouldAlert = true;
    } else if (currentHeartRate > HIGH_HEART_RATE_THRESHOLD) {
      alertMessage = "위험! 빈맥 감지 ($currentHeartRate BPM)";
      shouldAlert = true;
    }

    if (shouldAlert) {
      _triggerAlert(alertMessage);
      _lastAlertTime = DateTime.now();
    }
  }

  Future<void> _triggerAlert(String message) async {
    // 1. 소리 재생
    try {
        await _audioPlayer.play(AssetSource('sounds/alarm.mp3'));
    } catch (e) {
        print("Audio Error: $e");
    }

    // 2. 상단 알림
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'health_alert_channel',
      'Health Alerts',
      channelDescription: 'Vital signs warning',
      importance: Importance.max,
      priority: Priority.high,
      color: Colors.red,
      enableVibration: true,
    );
    await _notificationsPlugin.show(
      0, '건강 위험 감지', message, 
      const NotificationDetails(android: androidDetails),
    );
    
    // 3. 앱 내 스낵바
    Get.snackbar(
      "경고", message,
      backgroundColor: Colors.red,
      colorText: Colors.white,
      snackPosition: SnackPosition.TOP,
      duration: const Duration(seconds: 4),
    );
  }

  void _updateGraph(double rawValue) {
    waveformData.add(FlSpot(_timeCounter, rawValue));
    if (waveformData.length > 50) {
      waveformData.removeAt(0);
    }
    _timeCounter++;
    lastUpdated.value = DateFormat('a h:mm:ss', 'ko_KR').format(DateTime.now());
  }
}

// ---------------------------------------------------------------------------
// 2. UI Page
// ---------------------------------------------------------------------------
class HealthDashboardPage extends StatelessWidget {
  const HealthDashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(HealthController());

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blue.shade50, Colors.white],
            stops: const [0.0, 0.3],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // --- Header ---
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border(bottom: BorderSide(color: Colors.blue.shade100)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.monitor_heart, color: Colors.blue.shade600, size: 28),
                        const SizedBox(width: 8),
                        Text(
                          "건강 모니터",
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade900,
                          ),
                        ),
                      ],
                    ),
                    Obx(() => TextButton.icon(
                      onPressed: () => controller.toggleConnection(context),
                      icon: controller.isScanning.value 
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) 
                          : Icon(
                              controller.isConnected.value ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                              color: controller.isConnected.value ? Colors.blue : Colors.grey,
                            ),
                      label: Text(
                        controller.connectionStatus.value,
                        style: TextStyle(
                          color: controller.isConnected.value ? Colors.blue : Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        backgroundColor: controller.isConnected.value ? Colors.blue.shade50 : Colors.transparent,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                    )),
                  ],
                ),
              ),

              // --- Main Content ---
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Obx(() => HealthCard(
                                  title: "심박수",
                                  value: controller.heartRate.value.round().toString(),
                                  unit: "BPM",
                                  icon: Icons.favorite,
                                  iconColor: Colors.redAccent,
                                )),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Obx(() => HealthCard(
                                  title: "혈중 산소",
                                  value: controller.spo2.value.toStringAsFixed(1),
                                  unit: "%",
                                  icon: Icons.water_drop,
                                  iconColor: Colors.blue,
                                )),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),

                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.blue.shade100),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "맥박 파형 (Raw Data)",
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue.shade900,
                                  ),
                                ),
                                Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: const BoxDecoration(
                                        color: Colors.blue,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      "실시간",
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.blue.shade600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              height: 200,
                              child: Obx(() => PulseWaveform(
                                    points: controller.waveformData.toList(),
                                  )),
                            ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(height: 24),
                      Obx(() => Text(
                        "마지막 데이터 수신: ${controller.lastUpdated.value}",
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                      )),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. UI Components
// ---------------------------------------------------------------------------
class HealthCard extends StatelessWidget {
  final String title;
  final String value;
  final String unit;
  final IconData icon;
  final Color iconColor;

  const HealthCard({
    super.key,
    required this.title,
    required this.value,
    required this.unit,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 180,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.blue.shade100),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: iconColor, size: 28),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              SizedBox(
                width: 70,
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue.shade900,
                    fontFeatures: [
                      FontFeature.tabularFigures(),
                    ]
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.blue.shade500,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PulseWaveform extends StatelessWidget {
  final List<FlSpot> points;
  const PulseWaveform({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        minX: points.isNotEmpty ? points.first.x : 0,
        maxX: points.isNotEmpty ? points.last.x : 50,
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: true,
            color: Colors.blue.shade500,
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 0),
    );
  }
}