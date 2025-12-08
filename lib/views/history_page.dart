import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/health_controller.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<HealthController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text("측정 기록"),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              Get.defaultDialog(
                title: "기록 삭제",
                middleText: "모든 측정 기록을 삭제하시겠습니까?",
                textConfirm: "삭제",
                textCancel: "취소",
                confirmTextColor: Colors.white,
                onConfirm: () {
                  controller.clearLogs();
                  Get.back();
                },
              );
            },
          )
        ],
      ),
      body: Obx(() {
        if (controller.logHistory.isEmpty) {
          return const Center(child: Text("저장된 기록이 없습니다."));
        }
        return ListView.builder(
          itemCount: controller.logHistory.length,
          itemBuilder: (context, index) {
            final log = controller.logHistory[index];
            final bool isWarning = log.spo2 < 90 || log.bpm > 120 || log.bpm < 50;

            return ListTile(
              leading: CircleAvatar(
                backgroundColor: isWarning ? Colors.red.shade50 : Colors.blue.shade50,
                child: Icon(
                  Icons.monitor_heart, 
                  color: isWarning ? Colors.red : Colors.blue
                ),
              ),
              title: Text(
                log.time, 
                style: const TextStyle(fontWeight: FontWeight.bold)
              ),
              subtitle: Text("심박수: ${log.bpm.round()} BPM  |  SpO2: ${log.spo2}%"),
              trailing: isWarning 
                  ? const Icon(Icons.warning_amber, color: Colors.red)
                  : const Icon(Icons.check_circle_outline, color: Colors.green),
            );
          },
        );
      }),
    );
  }
}