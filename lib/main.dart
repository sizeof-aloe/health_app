import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
// 1. Controller: 블루투스 연결 및 데이터 수신 로직 (수정됨)
// ---------------------------------------------------------------------------
class HealthController extends GetxController {
  // 상태 변수
  var heartRate = 0.0.obs;
  var spo2 = 0.0.obs;
  var isConnected = false.obs;
  var connectionStatus = "연결 끊김".obs;
  var lastUpdated = '-'.obs; // 수신된 시간 문자열 저장
  
  // 그래프 데이터
  var waveformData = <FlSpot>[].obs;
  // X축 값(정수 카운터)에 대응하는 시간 문자열을 저장하는 맵
  var timeLabels = <int, String>{}.obs; 
  
  double _timeCounter = 0;

  // 블루투스 관련 변수
  BluetoothConnection? _connection;
  String _inputBuffer = "";

  @override
  void onInit() {
    super.onInit();
    _requestPermissions();
    _initWaveform();
  }

  @override
  void onClose() {
    _connection?.dispose();
    super.onClose();
  }

  // 초기 그래프 세팅
  void _initWaveform() {
    // 초기에는 데이터가 없으므로 0으로 채우되 시간 라벨은 비워둠
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
    ].request();
  }

  // 연결 로직 (기존과 동일)
  Future<void> connectToDevice(BuildContext context) async {
    if (isConnected.value) {
      _connection?.dispose();
      isConnected.value = false;
      connectionStatus.value = "연결 끊김";
      return;
    }

    bool isEnabled = await FlutterBluetoothSerial.instance.isEnabled ?? false;
    if (!isEnabled) {
      await FlutterBluetoothSerial.instance.requestEnable();
    }

    List<BluetoothDevice> devices = await FlutterBluetoothSerial.instance.getBondedDevices();

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

  void _startConnection(BluetoothDevice device) async {
    try {
      connectionStatus.value = "연결 중...";
      _connection = await BluetoothConnection.toAddress(device.address);
      
      isConnected.value = true;
      connectionStatus.value = "연결됨";
      
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

  // 4. 패킷 해석 (수정됨: 시:분:초,RAW,SPO2,BPM)
  void _parseAndProcess(String packet) {
    if (packet.isEmpty) return;

    try {
      List<String> values = packet.split(',');
      // 데이터 형식이 변경되어 길이가 최소 4개여야 함
      if (values.length >= 4) {
        // [0]: 시간 문자열 (예: 14:30:05)
        String timeStr = values[0];
        // [1]: Raw PPG
        double rawValue = double.parse(values[1]);
        // [2]: SpO2
        double spo2Value = double.parse(values[2]);
        // [3]: BPM
        double bpmValue = double.parse(values[3]);

        // 상태 업데이트
        spo2.value = spo2Value;
        heartRate.value = bpmValue;
        
        // **중요**: Last Updated를 수신된 시간으로 변경
        lastUpdated.value = timeStr; 

        // 그래프 데이터 업데이트 (슬라이딩 윈도우)
        // X축 좌표는 계속 증가하는 정수(_timeCounter)를 사용하고,
        // 해당 정수에 매핑되는 시간 문자열을 timeLabels 맵에 저장합니다.
        waveformData.add(FlSpot(_timeCounter, rawValue));
        timeLabels[_timeCounter.toInt()] = timeStr;

        if (waveformData.length > 50) {
          // 윈도우 밖으로 나가는 데이터의 시간 라벨 제거 (메모리 관리)
          double removedIndex = waveformData[0].x;
          timeLabels.remove(removedIndex.toInt());
          
          waveformData.removeAt(0);
        }
        _timeCounter++;
      }
    } catch (e) {
      print("Parsing Error: $packet / $e");
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
                        padding: const EdgeInsets.only(top: 24, left: 16, right: 24, bottom: 24),
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
                            const Padding(
                              padding: EdgeInsets.only(left: 8.0),
                              child: Text(
                                "맥박 파형 (PPG Raw Data)",
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              height: 220, // X축 라벨을 위해 높이를 약간 늘림
                              child: Obx(() => PulseWaveform(
                                    points: controller.waveformData.toList(),
                                    // 컨트롤러의 타임 라벨 맵을 전달
                                    timeLabels: controller.timeLabels,
                                  )),
                            ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(height: 24),
                      // 수신된 시간 표시 (lastUpdated)
                      Obx(() => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          "측정 시간: ${controller.lastUpdated.value}",
                          style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w500),
                        ),
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

// ---------------------------------------------------------------------------
// 3. Chart Component (수정됨)
// ---------------------------------------------------------------------------
class PulseWaveform extends StatelessWidget {
  final List<FlSpot> points;
  final Map<int, String> timeLabels; // 시간 라벨 맵 추가

  const PulseWaveform({
    super.key, 
    required this.points,
    required this.timeLabels,
  });

  @override
  Widget build(BuildContext context) {
    double minX = points.isNotEmpty ? points.first.x : 0;
    double maxX = points.isNotEmpty ? points.last.x : 50;

    return LineChart(
      LineChartData(
        // 그리드 숨김
        gridData: const FlGridData(show: false),
        
        // 타이틀(축 라벨) 설정
        titlesData: FlTitlesData(
          show: true,
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          // 하단 X축 설정
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30, // 라벨이 표시될 공간 확보
              interval: 1, // 모든 점에 대해 콜백 실행 (아래에서 필터링)
              getTitlesWidget: (value, meta) {
                int index = value.toInt();
                
                // 라벨이 너무 빽빽하지 않게 표시 (예: 10개 데이터마다 1번씩 표시)
                // maxX에 가까운 최근 값도 표시되도록 조정
                bool isInterval = index % 10 == 0;
                
                if (isInterval && timeLabels.containsKey(index)) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      timeLabels[index]!,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 10,
                        fontWeight: FontWeight.bold
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
        
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false), // 터치 비활성화 (실시간이라 성능 위함)
        
        // 데이터 범위
        minX: minX,
        maxX: maxX,
        // minY, maxY는 데이터에 따라 자동 조절됨 (필요시 고정 가능)

        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: true,
            color: Colors.blue.shade500,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: Colors.blue.withOpacity(0.1), // 그래프 아래 은은한 색상 추가
            ),
          ),
        ],
      ),
    );
  }
}