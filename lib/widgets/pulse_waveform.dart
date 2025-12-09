import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

class PulseWaveform extends StatelessWidget {
  final List<FlSpot> points;
  const PulseWaveform({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        maxY: 1500,
        minY: -2000,
        clipData: const FlClipData.all(),
        gridData: const FlGridData(show: false),
        titlesData: FlTitlesData(
          show: true, // 타이틀 보이기 활성화

          // 오른쪽과 위쪽 숫자는 보통 필요 없으므로 숨김
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),

          // X축 설정 (아래쪽)
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true, // X축 보이기
              reservedSize: 30, // 글자가 들어갈 공간 확보
              interval: 10, // 10 단위로 숫자 표시 (데이터에 맞춰 조절 필요)
              getTitlesWidget: (value, meta) {
                return Padding(
                  padding: const EdgeInsets.only(top: 5.0),
                  child: Text(
                    (value.toInt()).toString(),
                    style: const TextStyle(fontSize: 12),
                  ),
                );
              },
            ),
          ),

          // Y축 설정 (왼쪽)
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true, // Y축 보이기
              reservedSize: 40, // Y축 글자가 잘리지 않도록 공간 확보 (중요)
              interval: 500, // 필요하면 간격 설정 (없으면 자동)
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toInt().toString(),
                  style: const TextStyle(fontSize: 12),
                );
              },
            ),
          ),
        ),
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