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
// 1. Controller: 블루투스 연결 및 데이터 수신 로직
// ---------------------------------------------------------------------------
class HealthController extends GetxController {
  // 상태 변수
  var heartRate = 0.0.obs;
  var spo2 = 0.0.obs;
  var isConnected = false.obs;
  var connectionStatus = "연결 끊김".obs;
  var lastUpdated = '-'.obs;
  
  // 그래프 데이터
  var waveformData = <FlSpot>[].obs;
  double _timeCounter = 0;

  // 블루투스 관련 변수
  BluetoothConnection? _connection;
  String _inputBuffer = ""; // 수신 데이터 버퍼

  @override
  void onInit() {
    super.onInit();
    _requestPermissions(); // 앱 시작 시 권한 요청
    _initWaveform(); // 그래프 초기화 (빈 데이터)
  }

  @override
  void onClose() {
    _connection?.dispose();
    super.onClose();
  }

  // 초기 그래프 세팅
  void _initWaveform() {
    for (int i = 0; i < 50; i++) {
      waveformData.add(FlSpot(i.toDouble(), 0));
    }
    _timeCounter = 50;
  }

  // 권한 요청 함수
  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  // 1. 디바이스 선택 및 연결 함수 (UI에서 호출)
  Future<void> connectToDevice(BuildContext context) async {
    // 이미 연결된 경우 해제
    if (isConnected.value) {
      _connection?.dispose();
      isConnected.value = false;
      connectionStatus.value = "연결 끊김";
      return;
    }

    // 블루투스 켜져있는지 확인
    bool isEnabled = await FlutterBluetoothSerial.instance.isEnabled ?? false;
    if (!isEnabled) {
      await FlutterBluetoothSerial.instance.requestEnable();
    }

    // 페어링된 기기 목록 가져오기
    List<BluetoothDevice> devices = await FlutterBluetoothSerial.instance.getBondedDevices();

    // 기기 선택 다이얼로그 표시
    BluetoothDevice? selectedDevice = await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("기기 선택"),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: ListView.builder(
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                return ListTile(
                  title: Text(device.name ?? "Unknown Device"),
                  subtitle: Text(device.address),
                  onTap: () {
                    Navigator.pop(context, device);
                  },
                );
              },
            ),
          ),
        );
      },
    );

    if (selectedDevice != null) {
      _startConnection(selectedDevice);
    }
  }

  // 2. 실제 연결 수행
  void _startConnection(BluetoothDevice device) async {
    try {
      connectionStatus.value = "연결 중...";
      _connection = await BluetoothConnection.toAddress(device.address);
      
      isConnected.value = true;
      connectionStatus.value = "연결됨";
      
      // 데이터 수신 리스너 등록
      _connection!.input!.listen(_onDataReceived).onDone(() {
        isConnected.value = false;
        connectionStatus.value = "연결 종료";
      });

    } catch (e) {
      isConnected.value = false;
      connectionStatus.value = "연결 실패";
      print("Connection Error: $e");
    }
  }

  // 3. 데이터 수신 및 파싱 (핵심 로직)
  void _onDataReceived(Uint8List data) {
    // 1. 들어온 바이트 데이터를 문자열로 변환하여 버퍼에 추가
    String incomingData = utf8.decode(data);
    _inputBuffer += incomingData;

    // 2. 줄바꿈 문자(\n)가 있는지 확인
    while (_inputBuffer.contains('\n')) {
      int index = _inputBuffer.indexOf('\n');
      String packet = _inputBuffer.substring(0, index).trim(); // 한 줄 추출
      _inputBuffer = _inputBuffer.substring(index + 1); // 버퍼에서 제거

      _parseAndProcess(packet);
    }
  }

  // 4. 패킷 해석 (포맷: RAW,SPO2,BPM)
  void _parseAndProcess(String packet) {
    if (packet.isEmpty) return;

    try {
      List<String> values = packet.split(',');
      if (values.length >= 3) {
        // 데이터 파싱
        double rawValue = double.parse(values[0]); // 그래프용
        double spo2Value = double.parse(values[1]); // SpO2
        double bpmValue = double.parse(values[2]); // 심박수

        // 상태 업데이트
        spo2.value = spo2Value;
        heartRate.value = bpmValue;
        
        // 그래프 데이터 업데이트 (슬라이딩 윈도우)
        waveformData.add(FlSpot(_timeCounter, rawValue));
        if (waveformData.length > 50) {
          waveformData.removeAt(0);
        }
        _timeCounter++;

        // 시간 업데이트 (너무 자주하면 성능 저하되므로 가끔씩 해도 됨)
        lastUpdated.value = DateFormat('a h:mm:ss', 'ko_KR').format(DateTime.now());
      }
    } catch (e) {
      // 파싱 에러 무시 (노이즈 데이터 등)
      print("Parsing Error: $packet");
    }
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
                        const Text(
                          "건강 모니터",
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    // 블루투스 연결 버튼
                    Obx(() => TextButton.icon(
                      onPressed: () => controller.connectToDevice(context),
                      icon: Icon(
                        controller.isConnected.value ? Icons.bluetooth_connected : Icons.bluetooth,
                        color: controller.isConnected.value ? Colors.blue : Colors.grey,
                      ),
                      label: Text(
                        controller.connectionStatus.value,
                        style: TextStyle(
                          color: controller.isConnected.value ? Colors.blue : Colors.grey,
                        ),
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
                      // Grid Cards
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

                      // Chart
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
                            const Text(
                              "맥박 파형 (PPG Raw Data)",
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
                        "Last Update: ${controller.lastUpdated.value}",
                        style: const TextStyle(color: Colors.grey),
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

// (하단에 HealthCard, PulseWaveform 클래스는 기존과 동일하게 유지하거나 필요시 복사하세요)
// 공간 절약을 위해 아래 컴포넌트 코드는 생략하지 않고 포함합니다.

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
      height: 150,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.blue.shade100),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: iconColor, size: 28),
          const SizedBox(height: 8),
          Text(title, style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.blue.shade900)),
              Text(unit, style: TextStyle(fontSize: 14, color: Colors.blue.shade500, fontWeight: FontWeight.bold)),
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
    // Y축 범위를 데이터에 맞춰 자동 조절하고 싶으면 minY/maxY를 제거하거나 동적으로 계산하세요.
    // 여기서는 Raw Data 범위가 0~1024 라고 가정하고 대략적으로 잡습니다.
    return LineChart(
      LineChartData(
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        // Raw Data 값 범위에 따라 수정 필요 (예: 0~1024)
        // minY: 0, 
        // maxY: 1024, 
        minX: points.isNotEmpty ? points.first.x : 0,
        maxX: points.isNotEmpty ? points.last.x : 50,
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: true,
            color: Colors.blue.shade500,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ),
        ],
      ),
    );
  }
}