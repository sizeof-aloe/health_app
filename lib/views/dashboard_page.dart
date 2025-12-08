import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/health_controller.dart';
import '../widgets/health_card.dart';
import '../widgets/pulse_waveform.dart';

class HealthDashboardPage extends StatelessWidget {
  const HealthDashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 컨트롤러 찾기 (MainPage에서 이미 생성됨)
    final controller = Get.find<HealthController>();

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
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border(bottom: BorderSide(color: Colors.blue.shade100)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "실시간 건강 모니터",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
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

              // Main Content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      // 상태 카드
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

                      // 그래프 영역
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
                                const Text(
                                  "맥박 파형 (Raw Data)",
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
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