class HealthLog {
  final String time;
  final double bpm;
  final double spo2;

  HealthLog({required this.time, required this.bpm, required this.spo2});

  // JSON 변환 (저장용)
  Map<String, dynamic> toJson() => {
        'time': time,
        'bpm': bpm,
        'spo2': spo2,
      };

  // JSON 읽기 (로드용)
  factory HealthLog.fromJson(Map<String, dynamic> json) {
    return HealthLog(
      time: json['time'],
      bpm: json['bpm'],
      spo2: json['spo2'],
    );
  }
}