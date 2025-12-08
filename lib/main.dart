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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 한국어 날짜 형식 초기화 (에러 방지용 빈 문자열 처리)
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
// 1. Controller: HC-05 자동 연결, 재연결, 데이터 파싱 로직
// ---------------------------------------------------------------------------
class HealthController extends GetxController {
  // [설정] 찾으려는 블루투스 이름 (이 이름과 정확히 일치해야 자동 연결됨)
  static const String TARGET_DEVICE_NAME = "HC-05";

  // --- 상태 변수 ---
  var heartRate = 0.0.obs;
  var spo2 = 0.0.obs;
  var isConnected = false.obs;
  var connectionStatus = "연결 끊김".obs;
  var lastUpdated = '-'.obs;
  
  // --- 그래프 데이터 ---
  var waveformData = <FlSpot>[].obs;
  double _timeCounter = 0;

  // --- 블루투스 관련 변수 ---
  BluetoothConnection? _connection;
  String _inputBuffer = "";
  
  // 스캔/재연결 제어
  var isScanning = false.obs;
  StreamSubscription<BluetoothDiscoveryResult>? _discoveryStreamSubscription;
  Timer? _reconnectTimer;
  bool _isUserIntentionalDisconnect = false; // 사용자가 직접 끊었는지 확인

  @override
  void onInit() {
    super.onInit();
    _requestPermissions(); // 권한 요청
    _initWaveform(); // 그래프 초기화
    
    // 앱 시작 1초 후 자동 연결 시도
    Future.delayed(const Duration(seconds: 1), autoConnect);
  }

  @override
  void onClose() {
    _reconnectTimer?.cancel();
    _discoveryStreamSubscription?.cancel();
    _connection?.dispose();
    super.onClose();
  }

  // 초기 그래프 데이터 (0으로 채움)
  void _initWaveform() {
    for (int i = 0; i < 50; i++) {
      waveformData.add(FlSpot(i.toDouble(), 0));
    }
    _timeCounter = 50;
  }

  // 필수 권한 요청
  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  // -------------------------------------------------------------------------
  // [핵심 로직 1] HC-05 자동 찾기 및 연결
  // -------------------------------------------------------------------------
  void autoConnect() async {
    if (isConnected.value) return;

    _isUserIntentionalDisconnect = false; // 재연결 허용 모드 설정
    connectionStatus.value = "$TARGET_DEVICE_NAME 찾는 중...";

    // 1. 블루투스 활성화 확인
    bool isEnabled = await FlutterBluetoothSerial.instance.isEnabled ?? false;
    if (!isEnabled) {
       // 꺼져있으면 3초 뒤 재시도
       connectionStatus.value = "블루투스 꺼짐. 대기 중...";
       _scheduleReconnect();
       return;
    }

    // 2. [우선순위 1] 이미 페어링(Bonded)된 목록에서 찾기
    List<BluetoothDevice> bondedDevices = await FlutterBluetoothSerial.instance.getBondedDevices();
    try {
      BluetoothDevice target = bondedDevices.firstWhere((d) => d.name == TARGET_DEVICE_NAME);
      print("페어링 목록에서 발견: ${target.name} (${target.address})");
      _startConnection(target); // 발견 즉시 연결
      return;
    } catch (e) {
      // 목록에 없으면 스캔으로 넘어감
      print("페어링 목록에 없음. 스캔 시작.");
    }

    // 3. [우선순위 2] 주변 스캔해서 찾기
    _startScanForTarget();
  }

  // 특정 이름(HC-05)만 찾아서 연결하는 스캔 함수
  void _startScanForTarget() {
    if (isScanning.value) return;
    isScanning.value = true;
    connectionStatus.value = "주변 검색 중...";

    _discoveryStreamSubscription = FlutterBluetoothSerial.instance.startDiscovery().listen((r) {
      if (r.device.name == TARGET_DEVICE_NAME) {
        print("스캔으로 발견! 연결 시도: ${r.device.name}");
        _discoveryStreamSubscription?.cancel(); // 찾았으니 스캔 중지
        isScanning.value = false;
        _startConnection(r.device);
      }
    });

    _discoveryStreamSubscription?.onDone(() {
      isScanning.value = false;
      // 스캔이 끝났는데도 연결이 안 되었다면 재시도
      if (!isConnected.value) {
        connectionStatus.value = "기기 못 찾음. 재시도...";
        _scheduleReconnect();
      }
    });
  }

  // -------------------------------------------------------------------------
  // [핵심 로직 2] 실제 연결 및 끊김 감지
  // -------------------------------------------------------------------------
  void _startConnection(BluetoothDevice device) async {
    try {
      connectionStatus.value = "연결 시도 중...";
      _connection = await BluetoothConnection.toAddress(device.address);
      
      isConnected.value = true;
      connectionStatus.value = "연결됨 (${device.name})";
      _reconnectTimer?.cancel(); // 재연결 타이머 취소

      // 데이터 수신 리스너 등록
      _connection!.input!.listen(_onDataReceived).onDone(() {
        // [중요] 연결이 끊어졌을 때 실행됨
        isConnected.value = false;
        if (_isUserIntentionalDisconnect) {
          connectionStatus.value = "연결 종료됨";
        } else {
          // 의도치 않게 끊긴 경우 -> 재연결 시도
          connectionStatus.value = "연결 끊김! 재연결...";
          _scheduleReconnect();
        }
      });

    } catch (e) {
      isConnected.value = false;
      connectionStatus.value = "연결 실패. 재시도...";
      print("Connect Error: $e");
      _scheduleReconnect();
    }
  }

  // -------------------------------------------------------------------------
  // [핵심 로직 3] 재연결 스케줄링 (3초 딜레이)
  // -------------------------------------------------------------------------
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    // 3초 뒤에 다시 autoConnect 실행
    _reconnectTimer = Timer(const Duration(seconds: 3), autoConnect);
  }

  // UI 버튼용: 수동 연결/해제 토글
  void toggleConnection(BuildContext context) {
    if (isConnected.value) {
      // 연결 해제 요청
      _isUserIntentionalDisconnect = true; // 재연결 막기
      _connection?.dispose();
      isConnected.value = false;
      connectionStatus.value = "연결 종료";
    } else {
      // 수동 연결 요청 -> 자동 연결 로직 재실행
      autoConnect();
    }
  }

  // -------------------------------------------------------------------------
  // [데이터 처리] 수신 및 파싱
  // -------------------------------------------------------------------------
  void _onDataReceived(Uint8List data) {
    String incomingData = utf8.decode(data);
    _inputBuffer += incomingData;

    // 줄바꿈(\n) 단위로 패킷 분리
    while (_inputBuffer.contains('\n')) {
      int index = _inputBuffer.indexOf('\n');
      String packet = _inputBuffer.substring(0, index).trim();
      _inputBuffer = _inputBuffer.substring(index + 1);
      _parseAndProcess(packet);
    }
  }

  // 패킷 파싱 (포맷: 시간,RAW,SPO2,BPM)
  void _parseAndProcess(String packet) {
    if (packet.isEmpty) return;
    try {
      List<String> values = packet.split(',');
      
      // 케이스 1: 시간 포함 4개 데이터 (예: "21:46:47,607,98,72")
      if (values.length >= 4) {
        // values[0]은 시간이므로 무시하고, [1]부터 사용
        double rawValue = double.parse(values[1]); // RAW
        double spo2Value = double.parse(values[2]); // SpO2
        double bpmValue = double.parse(values[3]); // BPM

        spo2.value = spo2Value;
        heartRate.value = bpmValue;
        _updateGraph(rawValue);
      } 
      // 케이스 2: 3개 데이터만 올 경우 (예: "607,98,72") - 예외 처리
      else if (values.length == 3) {
        double rawValue = double.parse(values[0]);
        double spo2Value = double.parse(values[1]);
        double bpmValue = double.parse(values[2]);

        spo2.value = spo2Value;
        heartRate.value = bpmValue;
        _updateGraph(rawValue);
      }
    } catch (e) {
      print("Parsing Error: $packet / Reason: $e");
    }
  }

  // 그래프 및 시간 업데이트 헬퍼 함수
  void _updateGraph(double rawValue) {
    waveformData.add(FlSpot(_timeCounter, rawValue));
    
    // 데이터 50개 유지 (슬라이딩 윈도우)
    if (waveformData.length > 50) {
      waveformData.removeAt(0);
    }
    _timeCounter++;
    
    lastUpdated.value = DateFormat('a h:mm:ss', 'ko_KR').format(DateTime.now());
  }
}

// ---------------------------------------------------------------------------
// 2. UI Page: 메인 화면
// ---------------------------------------------------------------------------
class HealthDashboardPage extends StatelessWidget {
  const HealthDashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 컨트롤러 주입
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
                    // [연결 버튼] 복잡한 목록 대신 심플한 버튼 하나로 해결
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
                      // Grid Cards (심박수, SpO2)
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

                      // Chart Area
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
                            // 차트 위젯
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
      padding: const EdgeInsets.all(24),
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
              Text(
                value,
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade900,
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
        
        // 데이터가 왼쪽으로 흘러가게 보이도록 X축 범위 자동 조절
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
      duration: const Duration(milliseconds: 0), // 애니메이션 제거 (성능 최적화)
    );
  }
}