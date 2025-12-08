import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/health_log.dart';

class HealthController extends GetxController {
  static const String TARGET_DEVICE_NAME = "HC-05";
  
  final double LOW_SPO2_THRESHOLD = 90.0;
  final double LOW_HEART_RATE_THRESHOLD = 50.0;
  final double HIGH_HEART_RATE_THRESHOLD = 120.0;

  var heartRate = 0.0.obs;
  var spo2 = 0.0.obs;
  var isConnected = false.obs;
  var connectionStatus = "연결 끊김".obs;
  var lastUpdated = '-'.obs;
  
  var waveformData = <FlSpot>[].obs;
  double _timeCounter = 0;

  var logHistory = <HealthLog>[].obs;
  DateTime? _lastSaveTime;

  BluetoothConnection? _connection;
  String _inputBuffer = "";
  var isScanning = false.obs;
  StreamSubscription<BluetoothDiscoveryResult>? _discoveryStreamSubscription;
  Timer? _reconnectTimer;
  bool _isUserIntentionalDisconnect = false;

  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  
  DateTime? _lastAlertTime; 
  static const int ALERT_COOLDOWN_SECONDS = 5; 

  @override
  void onInit() {
    super.onInit();
    _requestPermissions();
    _initWaveform();
    _initNotifications();
    _loadLogs();
    
    Future.delayed(const Duration(seconds: 1), autoConnect);
  }

  @override
  void onClose() {
    _reconnectTimer?.cancel();
    _discoveryStreamSubscription?.cancel();
    _connection?.dispose();
    _audioPlayer.dispose();
    super.onClose();
  }

  void _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
    await _notificationsPlugin.initialize(initializationSettings);
  }

  void _initWaveform() {
    for (int i = 0; i < 50; i++) {
      waveformData.add(FlSpot(i.toDouble(), 0));
    }
    _timeCounter = 50;
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.notification,
    ].request();
  }

  // -------------------------------------------------------------------------
  // [수정됨] 로그 저장 (패킷에서 받은 시간을 사용)
  // -------------------------------------------------------------------------
  Future<void> _saveLog(double bpm, double sp, String packetTime, {bool isEmergency = false}) async {
    // 5초 쿨다운 체크 (긴급상황 제외)
    if (!isEmergency && _lastSaveTime != null && 
        DateTime.now().difference(_lastSaveTime!).inSeconds < 5) {
      return;
    }
    
    _lastSaveTime = DateTime.now(); // 타이머 리셋용 로컬 시간 갱신

    if (bpm < 10 || sp < 10) return;

    // [변경] DateTime.now() 대신 파라미터로 받은 packetTime 사용
    final newLog = HealthLog(
      time: packetTime, 
      bpm: bpm,
      spo2: sp,
    );

    logHistory.insert(0, newLog);
    
    final prefs = await SharedPreferences.getInstance();
    List<String> jsonList = logHistory.map((log) => jsonEncode(log.toJson())).toList();
    await prefs.setStringList('health_logs', jsonList);
    
    if(isEmergency) {
      print("🚨 비상 데이터 긴급 저장 완료! (시간: $packetTime)");
    }
  }

  Future<void> _loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? jsonList = prefs.getStringList('health_logs');
    
    if (jsonList != null) {
      logHistory.value = jsonList
          .map((item) => HealthLog.fromJson(jsonDecode(item)))
          .toList();
    }
  }

  Future<void> clearLogs() async {
    logHistory.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('health_logs');
  }

  // --- 블루투스 로직 ---
  void autoConnect() async {
    if (isConnected.value) return;

    _isUserIntentionalDisconnect = false;
    connectionStatus.value = "$TARGET_DEVICE_NAME 찾는 중...";

    bool isEnabled = await FlutterBluetoothSerial.instance.isEnabled ?? false;
    if (!isEnabled) {
       connectionStatus.value = "블루투스 꺼짐";
       _scheduleReconnect();
       return;
    }

    List<BluetoothDevice> bondedDevices = await FlutterBluetoothSerial.instance.getBondedDevices();
    try {
      BluetoothDevice target = bondedDevices.firstWhere((d) => d.name == TARGET_DEVICE_NAME);
      _startConnection(target);
      return;
    } catch (e) {}
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
        connectionStatus.value = "기기 못 찾음";
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
      connectionStatus.value = "연결 실패";
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

  // -------------------------------------------------------------------------
  // [수정됨] 패킷 파싱 및 시간 추출
  // -------------------------------------------------------------------------
  void _parseAndProcess(String packet) {
    if (packet.isEmpty) return;
    try {
      List<String> values = packet.split(',');
      double? raw, sp, hr;
      String packetTime = ""; // 패킷에서 추출할 시간

      // Case 1: 시간 포함 4개 데이터 (시간, RAW, SPO2, BPM)
      if (values.length >= 4) {
        packetTime = values[0]; // [변경] 0번째 인덱스는 시간
        raw = double.parse(values[1]);
        sp = double.parse(values[2]);
        hr = double.parse(values[3]);
      } 
      // Case 2: 3개 데이터 (혹시 몰라 예외처리) -> 시간은 앱 시간으로 대체
      else if (values.length == 3) {
        packetTime = DateFormat('HH:mm:ss').format(DateTime.now());
        raw = double.parse(values[0]);
        sp = double.parse(values[1]);
        hr = double.parse(values[2]);
      }

      if (raw != null && sp != null && hr != null) {
        spo2.value = sp;
        heartRate.value = hr;
        
        // [변경] 패킷 시간을 UI 업데이트에 반영
        lastUpdated.value = packetTime;
        
        _updateGraph(raw);
        
        // [변경] 경고 체크 및 저장 시 패킷 시간 전달
        _checkThresholds(sp, hr, packetTime);
        _saveLog(hr, sp, packetTime); 
      }
    } catch (e) {
      print("Parsing Error: $packet");
    }
  }

  // -------------------------------------------------------------------------
  // [수정됨] 경고 체크 (packetTime 전달받음)
  // -------------------------------------------------------------------------
  void _checkThresholds(double currentSpo2, double currentHeartRate, String packetTime) {
    if (_lastAlertTime != null && 
        DateTime.now().difference(_lastAlertTime!).inSeconds < ALERT_COOLDOWN_SECONDS) {
      return; 
    }

    String alertMessage = "";
    bool shouldAlert = false;

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
      
      // [변경] 위험 상황 저장 시 패킷 시간 사용
      _saveLog(currentHeartRate, currentSpo2, packetTime, isEmergency: true);
    }
  }

  Future<void> _triggerAlert(String message) async {
    try {
        await _audioPlayer.play(AssetSource('sounds/alert.mp3'));
    } catch (e) {
        print("Audio Error: $e");
    }

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'health_alert_channel',
      'Health Alerts',
      importance: Importance.max,
      priority: Priority.high,
      color: Colors.red,
      enableVibration: true,
    );

    await _notificationsPlugin.show(
      0, '건강 위험 감지', message, 
      const NotificationDetails(android: androidDetails),
    );
    
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
    // lastUpdated는 _parseAndProcess에서 이미 패킷 시간으로 업데이트 했으므로 여기선 생략
  }
}