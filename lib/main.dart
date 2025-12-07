import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

import 'package:intl/date_symbol_data_local.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // 👈 플러터 엔진 바인딩 초기화
  await initializeDateFormatting('ko', '');
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
// 1. Controller (React의 useState, useEffect 로직 담당)
// ---------------------------------------------------------------------------
class HealthController extends GetxController {
  // 상태 변수 (Reactive Variables)
  var heartRate = 72.0.obs;
  var spo2 = 98.0.obs;
  var isConnected = true.obs;
  var lastUpdated = ''.obs;
  
  // 그래프 데이터 (RxList)
  var waveformData = <FlSpot>[].obs;
  double _timeCounter = 0; // x축 시간 증가용

  Timer? _timer;

  @override
  void onInit() {
    super.onInit();
    _generateInitialWaveform();
    _startSimulation();
    _updateTime();
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }

  // 초기 그래프 데이터 생성 (App.tsx: generateInitialWaveform)
  void _generateInitialWaveform() {
    for (int i = 0; i < 50; i++) {
      double value = 50 + sin(i * 0.3) * 30 + Random().nextDouble() * 10;
      waveformData.add(FlSpot(i.toDouble(), value));
    }
    _timeCounter = 50;
  }

  // 실시간 데이터 업데이트 시뮬레이션 (App.tsx: useEffect interval)
  void _startSimulation() {
    _timer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      // 1. 심박수 업데이트 (65-85 범위 제한)
      double hrChange = (Random().nextDouble() - 0.5) * 4;
      heartRate.value = (heartRate.value + hrChange).clamp(65.0, 85.0);

      // 2. SpO2 업데이트 (96-100 범위 제한)
      double spo2Change = (Random().nextDouble() - 0.5) * 0.5;
      spo2.value = (spo2.value + spo2Change).clamp(96.0, 100.0);

      // 3. 그래프 데이터 업데이트
      double lastValue = waveformData.last.y;
      double waveChange = (Random().nextDouble() - 0.5) * 30;
      double newValue = (lastValue + waveChange).clamp(0.0, 100.0);

      // 리스트에 추가하고 앞부분 제거 (슬라이딩 효과)
      waveformData.add(FlSpot(_timeCounter, newValue));
      if (waveformData.length > 50) {
        waveformData.removeAt(0);
      }
      _timeCounter++;
      
      _updateTime();
    });
  }

  void _updateTime() {
    lastUpdated.value = DateFormat('a h:mm:ss', 'ko_KR').format(DateTime.now());
  }
}

// ---------------------------------------------------------------------------
// 2. Main Page (App.tsx UI 구조 변환)
// ---------------------------------------------------------------------------
class HealthDashboardPage extends StatelessWidget {
  const HealthDashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 컨트롤러 주입
    final controller = Get.put(HealthController());

    return Scaffold(
      // 배경 그라데이션 (bg-gradient-to-b from-blue-50 to-white)
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blue.shade50, Colors.white],
            stops: const [0.0, 0.3], // 그라데이션 비율 조절
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
                    Obx(() => Row(
                          children: [
                            Icon(
                              controller.isConnected.value
                                  ? Icons.bluetooth_connected
                                  : Icons.bluetooth_disabled,
                              color: controller.isConnected.value
                                  ? Colors.blue.shade600
                                  : Colors.grey.shade300,
                              size: 24,
                            ),
                            if (controller.isConnected.value)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Text(
                                  "연결됨",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.blue.shade600,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
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
                                  icon: Icons.water_drop, // Activity 아이콘 대체
                                  iconColor: Colors.blue,
                                )),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),

                      // Pulse Waveform Chart Section
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
                                  "맥박 파형",
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
                            // 차트 영역
                            SizedBox(
                              height: 200,
                              child: Obx(() => PulseWaveform(
                                    points: controller.waveformData.toList(),
                                  )),
                            ),
                          ],
                        ),
                      ),

                      // Footer
                      const SizedBox(height: 24),
                      Obx(() => Text(
                            "마지막 업데이트: ${controller.lastUpdated.value}",
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500,
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

// ---------------------------------------------------------------------------
// 3. UI Components (HealthCard.tsx 변환)
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
                  fontSize: 40, // text-5xl 대응
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade900,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: TextStyle(
                  fontSize: 16, // text-lg 대응
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

// ---------------------------------------------------------------------------
// 4. UI Components (PulseWaveform.tsx 변환)
// ---------------------------------------------------------------------------
class PulseWaveform extends StatelessWidget {
  final List<FlSpot> points;

  const PulseWaveform({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        // 차트 설정 (격자, 타이틀, 테두리 제거하여 Clean한 느낌 유지)
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false), // 터치 비활성화
        
        // Y축 범위 (App.tsx와 동일하게 0~100)
        minY: 0,
        maxY: 100,
        
        // X축 범위 (슬라이딩 윈도우 효과를 위해 동적 계산)
        minX: points.isNotEmpty ? points.first.x : 0,
        maxX: points.isNotEmpty ? points.last.x : 50,

        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: true, // 부드러운 곡선 (monotone 대응)
            color: Colors.blue.shade500, // stroke="#3b82f6"
            barWidth: 3, // strokeWidth={2}
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false), // dot={false}
            belowBarData: BarAreaData(show: false),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 0), // 애니메이션 제거 (실시간 성능 위해)
    );
  }
}