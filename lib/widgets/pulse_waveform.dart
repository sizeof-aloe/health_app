import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

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