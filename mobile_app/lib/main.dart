import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UVMonitorAppV2());
}

class UVMonitorAppV2 extends StatefulWidget {
  const UVMonitorAppV2({super.key});

  @override
  State<UVMonitorAppV2> createState() => _UVMonitorAppV2State();
}

class _UVMonitorAppV2State extends State<UVMonitorAppV2> {
  // Default to White/Light Mode as requested, with persistent toggle for Dark Mode
  bool _isDarkMode = false;

  @override
  void initState() {
    super.initState();
    _loadThemePreference();
  }

  Future<void> _loadThemePreference() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isDarkMode = prefs.getBool('uv_dark_mode_v2') ?? false;
      });
    }
  }

  Future<void> _toggleTheme() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _isDarkMode = !_isDarkMode;
    });
    await prefs.setBool('uv_dark_mode_v2', _isDarkMode);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData lightTheme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF5F7FA),
      cardColor: Colors.white,
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF1A73E8),
        secondary: Color(0xFFEA4335),
        surface: Colors.white,
      ),
    );

    final ThemeData darkTheme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF111318),
      cardColor: const Color(0xFF1E2028),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF8AB4F8),
        secondary: Color(0xFFF28B82),
        surface: Color(0xFF1E2028),
      ),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Google Weather Style UV Hub V2',
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: UVMonitorScreenV2(
        isDarkMode: _isDarkMode,
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}

// ================= PIECEWISE WHO CALIBRATION ENGINE =================
class GuvaCalibrationEngine {
  static const List<double> mvThresholds = <double>[
    50.0, 227.0, 318.0, 408.0, 503.0, 606.0,
    696.0, 795.0, 881.0, 976.0, 1079.0, 1170.0
  ];

  static int lookupDiscreteUVI(double mv) {
    final double clamped = mv.clamp(0.0, 1250.0);
    if (clamped < 50.0) return 0;
    for (int uvi = 11; uvi >= 1; uvi--) {
      if (clamped >= mvThresholds[uvi]) return uvi;
    }
    return 0;
  }

  static double calculateCalibratedUVI(double mv) {
    final double clamped = mv.clamp(0.0, 1250.0);
    if (clamped < 50.0) return 0.0;
    if (clamped >= 1170.0) return 11.0 + (clamped - 1170.0) / 91.0;
    for (int i = 0; i < 11; i++) {
      final double vLow = mvThresholds[i];
      final double vHigh = mvThresholds[i + 1];
      if (clamped >= vLow && clamped <= vHigh) {
        return i + (clamped - vLow) / (vHigh - vLow);
      }
    }
    return 0.0;
  }

  static double calculateOldLinearUVI(double mv) => mv.clamp(0.0, 1250.0) / 100.0;

  static String getRiskCategory(double uvi) {
    if (uvi < 3.0) return 'Low';
    if (uvi < 6.0) return 'Moderate';
    if (uvi < 8.0) return 'High';
    if (uvi < 11.0) return 'Very High';
    return 'Extreme';
  }
}

class UVRecord {
  final DateTime timestamp;
  final double mvRaw;
  final double mvMedian;
  final double mvKalman;
  final double mvHybrid;
  final double uviCalibrated;
  final double uviLinearOld;
  final int uviLookupInt;
  final String riskCategory;
  final int rssi;

  UVRecord({
    required this.timestamp,
    required this.mvRaw,
    required this.mvMedian,
    required this.mvKalman,
    required this.mvHybrid,
    required this.uviCalibrated,
    required this.uviLinearOld,
    required this.uviLookupInt,
    required this.riskCategory,
    required this.rssi,
  });

  double getMvByFilter(String filterName) {
    switch (filterName) {
      case 'Median Filter':
        return mvMedian;
      case '1D Kalman Filter':
        return mvKalman;
      case 'Hybrid (Median+Kalman)':
      default:
        return mvHybrid;
    }
  }

  double getUviByFilter(String filterName) {
    return GuvaCalibrationEngine.calculateCalibratedUVI(getMvByFilter(filterName));
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ts': timestamp.toIso8601String(),
        'raw': mvRaw,
        'med': mvMedian,
        'kal': mvKalman,
        'hyb': mvHybrid,
        'uvi_cal': uviCalibrated,
        'uvi_lin': uviLinearOld,
        'uvi_int': uviLookupInt,
        'risk': riskCategory,
        'rssi': rssi,
      };

  factory UVRecord.fromJson(Map<String, dynamic> json) {
    final double hyb = ((json['hyb'] ?? json['kal'] ?? json['mv'] ?? 0.0) as num).toDouble().clamp(0.0, 1250.0);
    final double raw = ((json['raw'] ?? hyb) as num).toDouble().clamp(0.0, 1250.0);
    final double med = ((json['med'] ?? hyb) as num).toDouble().clamp(0.0, 1250.0);
    final double kal = ((json['kal'] ?? hyb) as num).toDouble().clamp(0.0, 1250.0);
    final double uviCal = ((json['uvi_cal'] ?? json['uv'] ?? GuvaCalibrationEngine.calculateCalibratedUVI(hyb)) as num).toDouble();
    return UVRecord(
      timestamp: DateTime.parse(json['ts'].toString()).toLocal(),
      mvRaw: raw,
      mvMedian: med,
      mvKalman: kal,
      mvHybrid: hyb,
      uviCalibrated: uviCal,
      uviLinearOld: ((json['uvi_lin'] ?? (hyb / 100.0)) as num).toDouble(),
      uviLookupInt: ((json['uvi_int'] ?? GuvaCalibrationEngine.lookupDiscreteUVI(hyb)) as num).toInt(),
      riskCategory: (json['risk'] ?? GuvaCalibrationEngine.getRiskCategory(uviCal)).toString(),
      rssi: ((json['rssi'] ?? 0) as num).toInt(),
    );
  }
}

class HourlyBucketStat {
  final int hour;
  final String timeSlot;
  final double peakUvi;
  final double avgMv;
  final int count;
  final String risk;

  HourlyBucketStat({
    required this.hour,
    required this.timeSlot,
    required this.peakUvi,
    required this.avgMv,
    required this.count,
    required this.risk,
  });
}

class GranularTelemetryRow {
  final String time;
  final String uvData;
  final String voltage;

  GranularTelemetryRow({
    required this.time,
    required this.uvData,
    required this.voltage,
  });
}

class ChartDataPoint {
  final String label;
  final double uviFiltered;
  final double uviRaw;
  final double mvFiltered;
  final double mvRaw;

  ChartDataPoint({
    required this.label,
    required this.uviFiltered,
    required this.uviRaw,
    required this.mvFiltered,
    required this.mvRaw,
  });
}

// ================= GOOGLE WEATHER CIRCULAR RAINBOW UV GAUGE =================
class GoogleWeatherUvArcPainter extends CustomPainter {
  final double uvi;
  final bool isDark;

  GoogleWeatherUvArcPainter({required this.uvi, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = min(size.width, size.height) / 2 - 8;
    const double startAngle = 2.35619; // 135 deg
    const double sweepAngle = 4.71239; // 270 deg

    final Paint bgPaint = Paint()
      ..color = isDark ? Colors.white12 : Colors.black12
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      bgPaint,
    );

    final Rect rect = Rect.fromCircle(center: center, radius: radius);
    final Paint gradPaint = Paint()
      ..shader = const SweepGradient(
        startAngle: 0.0,
        endAngle: pi * 2,
        colors: <Color>[
          Color(0xFF4CAF50),
          Color(0xFFFFEB3B),
          Color(0xFFFF9800),
          Color(0xFFF44336),
          Color(0xFF9C27B0),
          Color(0xFF4CAF50),
        ],
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, startAngle, sweepAngle, false, gradPaint);

    // Draw indicator dot on the arc
    final double norm = (uvi.clamp(0.0, 12.0)) / 12.0;
    final double dotAngle = startAngle + norm * sweepAngle;
    final Offset dotPos = Offset(
      center.dx + radius * cos(dotAngle),
      center.dy + radius * sin(dotAngle),
    );

    final Paint dotBorder = Paint()
      ..color = isDark ? const Color(0xFF1E2028) : Colors.white
      ..style = PaintingStyle.fill;
    final Paint dotFill = Paint()
      ..color = isDark ? Colors.white : const Color(0xFF1F2937)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(dotPos, 8, dotBorder);
    canvas.drawCircle(dotPos, 5.5, dotFill);
  }

  @override
  bool shouldRepaint(covariant GoogleWeatherUvArcPainter oldDelegate) =>
      oldDelegate.uvi != uvi || oldDelegate.isDark != isDark;
}

class UVMonitorScreenV2 extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const UVMonitorScreenV2({
    super.key,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<UVMonitorScreenV2> createState() => _UVMonitorScreenV2State();
}

class _UVMonitorScreenV2State extends State<UVMonitorScreenV2> {
  final TextEditingController _ipController = TextEditingController(text: '192.168.0.117');

  static const String _influxBaseUrl = 'https://us-east-1-1.aws.cloud2.influxdata.com';
  static const String _influxOrg = 'IOT';
  static const String _influxBucket = 'uv_sensor_data';
  static const String _influxToken = 'Dbzt7IHP3G4E4McgOmsRBrZLUaK2fsEgexNVFzYSQI1V2PhqWbL6SFhB64Vg-jOY6HQIu7BibH8jkSQvHqLNWw==';

  Timer? _pollTimer;
  Timer? _influxSyncTimer;
  MqttServerClient? _mqttClient;

  bool _isConnected = false;
  bool _isMqttCloudConnected = false;
  bool _isInfluxCloudConnected = false;
  bool _isSimulating = false;
  String _status = 'Ready • Tap Connect for Live Sensor Stream';
  final int _selectedPollSeconds = 5;

  String _selectedFilter = 'Hybrid (Median+Kalman)';
  bool _overlayRawOnChart = false;
  final List<String> _filterOptions = <String>[
    'Hybrid (Median+Kalman)',
    '1D Kalman Filter',
    'Median Filter',
  ];

  final List<double> _winBuf = <double>[];
  double _kalX = 0.0, _kalP = 1.0;
  double _hybX = 0.0, _hybP = 1.0;

  UVRecord? _latestRecord;
  int _packetCount = 0;

  final List<UVRecord> _liveRecords = <UVRecord>[];
  List<UVRecord> _allHistoryRecords = <UVRecord>[];

  String _periodMode = 'Date';
  int _selectedYear = DateTime.now().year;
  int _selectedMonth = DateTime.now().month;
  int _selectedWeek = ((DateTime.now().day - 1) ~/ 7) + 1;
  int _selectedDay = DateTime.now().day;

  String _chartGranularity = 'Hours';
  String _timeGranularity = 'Seconds';

  static const List<String> _monthNames = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  static const List<String> _weekdayShort = <String>[
    'M', 'T', 'W', 'T', 'F', 'S', 'S'
  ];

  // Gradient colors matching the WHO UV Index bell-curve reference image
  static const List<Color> _whoGradientColors = <Color>[
    Color(0xFF2ECC71), // Low (0-2) Green
    Color(0xFFF1C40F), // Moderate (3-5) Yellow
    Color(0xFFE67E22), // High (6-7) Orange
    Color(0xFFE84393), // Very High / Extreme (8-11+) Red-Pink/Magenta
  ];

  @override
  void initState() {
    super.initState();
    _loadSavedHistory();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _influxSyncTimer?.cancel();
    _mqttClient?.disconnect();
    _ipController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedHistory() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String>? savedJson = prefs.getStringList('uv_history_logs_v5_clean');
    if (savedJson != null) {
      setState(() {
        _allHistoryRecords = savedJson
            .map((String str) => UVRecord.fromJson(jsonDecode(str) as Map<String, dynamic>))
            .toList();
        if (_allHistoryRecords.isNotEmpty) {
          _liveRecords.addAll(_allHistoryRecords.length > 60
              ? _allHistoryRecords.sublist(_allHistoryRecords.length - 60)
              : _allHistoryRecords);
          _latestRecord = _allHistoryRecords.last;
        }
      });
    }
  }

  Future<void> _saveRecordToHistory(UVRecord record) async {
    final bool exists = _allHistoryRecords.any((UVRecord r) =>
        (r.timestamp.difference(record.timestamp).inSeconds).abs() < 1);
    if (!exists) {
      _allHistoryRecords.add(record);
      _allHistoryRecords.sort((UVRecord a, UVRecord b) => a.timestamp.compareTo(b.timestamp));
      if (_allHistoryRecords.length > 8000) _allHistoryRecords.removeAt(0);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> encoded = _allHistoryRecords.map((UVRecord r) => jsonEncode(r.toJson())).toList();
      await prefs.setStringList('uv_history_logs_v5_clean', encoded);
    }
  }

  Future<void> _syncFromInfluxDbCloud() async {
    try {
      const String fluxQuery = '''
from(bucket: "$_influxBucket")
  |> range(start: -24h)
  |> filter(fn: (r) => r["_measurement"] == "uv_measurement")
  |> filter(fn: (r) => r["_field"] == "voltage_raw_mv" or r["_field"] == "voltage_median_mv" or r["_field"] == "voltage_kalman_mv" or r["_field"] == "voltage_hybrid_mv" or r["_field"] == "uv_index_estimated")
  |> pivot(rowKey:["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> sort(columns: ["_time"], desc: false)
  |> tail(n: 120)
''';

      final Uri uri = Uri.parse('$_influxBaseUrl/api/v2/query?org=$_influxOrg');
      final http.Response response = await http.post(
        uri,
        headers: <String, String>{
          'Authorization': 'Token $_influxToken',
          'Content-Type': 'application/vnd.flux',
          'Accept': 'application/csv',
        },
        body: fluxQuery,
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200 && response.body.trim().isNotEmpty) {
        if (mounted) setState(() => _isInfluxCloudConnected = true);
        _parseInfluxCsvResponse(response.body);
      }
    } catch (_) {
      if (mounted) setState(() => _isInfluxCloudConnected = false);
    }
  }

  void _parseInfluxCsvResponse(String csvBody) {
    final List<String> lines = const LineSplitter().convert(csvBody);
    if (lines.length < 2) return;

    List<String>? headers;
    for (final String rawLine in lines) {
      final String line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final List<String> cols = line.split(',');
      if (cols.contains('_time') && cols.contains('voltage_hybrid_mv')) {
        headers = cols;
        continue;
      }
      if (headers == null || cols.length < headers.length) continue;

      final Map<String, String> rowMap = <String, String>{};
      for (int i = 0; i < headers.length; i++) {
        rowMap[headers[i]] = cols[i];
      }

      final DateTime? ts = DateTime.tryParse(rowMap['_time'] ?? '')?.toLocal();
      if (ts == null) continue;

      final double raw = (double.tryParse(rowMap['voltage_raw_mv'] ?? '') ?? 0.0).clamp(0.0, 1250.0);
      final double med = (double.tryParse(rowMap['voltage_median_mv'] ?? '') ?? raw).clamp(0.0, 1250.0);
      final double kal = (double.tryParse(rowMap['voltage_kalman_mv'] ?? '') ?? raw).clamp(0.0, 1250.0);
      final double hyb = (double.tryParse(rowMap['voltage_hybrid_mv'] ?? '') ?? raw).clamp(0.0, 1250.0);
      final double uviEst = double.tryParse(rowMap['uv_index_estimated'] ?? '') ?? GuvaCalibrationEngine.calculateCalibratedUVI(hyb);

      final UVRecord rec = UVRecord(
        timestamp: ts,
        mvRaw: raw,
        mvMedian: med,
        mvKalman: kal,
        mvHybrid: hyb,
        uviCalibrated: uviEst,
        uviLinearOld: GuvaCalibrationEngine.calculateOldLinearUVI(hyb),
        uviLookupInt: GuvaCalibrationEngine.lookupDiscreteUVI(hyb),
        riskCategory: GuvaCalibrationEngine.getRiskCategory(uviEst),
        rssi: 0,
      );

      final bool alreadyExists = _allHistoryRecords.any((UVRecord r) =>
          (r.timestamp.difference(rec.timestamp).inSeconds).abs() < 2);
      if (!alreadyExists) {
        _allHistoryRecords.add(rec);
        if (mounted) {
          setState(() {
            _latestRecord = rec;
            _liveRecords.add(rec);
            if (_liveRecords.length > 60) _liveRecords.removeAt(0);
          });
        }
      }
    }
  }

  Future<void> _connectHiveMqCloud() async {
    final String clientId = 'flutter_uv_v2_${Random().nextInt(99999)}';
    _mqttClient = MqttServerClient.withPort('broker.hivemq.com', clientId, 1883);
    _mqttClient!.keepAlivePeriod = 30;
    _mqttClient!.autoReconnect = true;
    _mqttClient!.onConnected = () {
      if (mounted) setState(() => _isMqttCloudConnected = true);
      _mqttClient!.subscribe('venkat_iot/sensors/uv/node_01', MqttQos.atMostOnce);
    };
    _mqttClient!.onDisconnected = () {
      if (mounted) setState(() => _isMqttCloudConnected = false);
    };

    try {
      await _mqttClient!.connect();
      _mqttClient!.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
        if (!_isConnected || _isSimulating) return;
        final MqttPublishMessage recMess = c[0].payload as MqttPublishMessage;
        final String payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        _parseIncomingJson(payload, source: 'HiveMQ Cloud');
      });
    } catch (_) {
      if (mounted) setState(() => _isMqttCloudConnected = false);
    }
  }

  void _toggleConnection() {
    setState(() {
      _isSimulating = false;
      _isConnected = !_isConnected;
    });

    if (_isConnected) {
      if (!_isMqttCloudConnected) _connectHiveMqCloud();
      _syncFromInfluxDbCloud();
      _fetchLocalHttp();

      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(
        Duration(seconds: _selectedPollSeconds),
        (_) => _fetchLocalHttp(),
      );

      _influxSyncTimer?.cancel();
      _influxSyncTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _syncFromInfluxDbCloud(),
      );

      setState(() => _status = 'Syncing via HiveMQ, InfluxDB & Local HTTP...');
    } else {
      _pollTimer?.cancel();
      _influxSyncTimer?.cancel();
      setState(() => _status = 'Telemetry Paused');
    }
  }

  Future<void> _fetchLocalHttp() async {
    final String ip = _ipController.text.trim();
    if (ip.isEmpty) return;
    try {
      final http.Response response = await http
          .get(Uri.parse('http://$ip/data'))
          .timeout(const Duration(milliseconds: 2200));

      if (response.statusCode == 200) {
        _parseIncomingJson(response.body, source: 'Local Wi-Fi ($ip)');
      }
    } catch (_) {
      if (_isMqttCloudConnected && mounted) {
        setState(() => _status = 'Connected remotely via HiveMQ/InfluxDB');
      }
    }
  }

  void _parseIncomingJson(String body, {required String source}) {
    try {
      final Map<String, dynamic> data = jsonDecode(body) as Map<String, dynamic>;
      final double raw = (double.tryParse((data['mv_raw'] ?? data['sensor_mv'] ?? '0').toString()) ?? 0.0).clamp(0.0, 1250.0);
      final int rssi = int.tryParse((data['rssi_dbm'] ?? '0').toString()) ?? 0;

      if (data.containsKey('mv_hybrid')) {
        final double med = (double.tryParse(data['mv_median'].toString()) ?? raw).clamp(0.0, 1250.0);
        final double kal = (double.tryParse(data['mv_kalman'].toString()) ?? raw).clamp(0.0, 1250.0);
        final double hyb = (double.tryParse(data['mv_hybrid'].toString()) ?? raw).clamp(0.0, 1250.0);
        _recordSample(raw, med, kal, hyb, rssi, source: source);
      } else {
        _compute3FiltersLocallyAndRecord(raw, rssi, source: source);
      }
    } catch (_) {}
  }

  void _compute3FiltersLocallyAndRecord(double rawInput, int rssi, {required String source}) {
    final double raw = rawInput.clamp(0.0, 1250.0);
    _winBuf.add(raw);
    if (_winBuf.length > 9) _winBuf.removeAt(0);

    final List<double> sorted = List<double>.from(_winBuf)..sort();
    final double med = sorted[sorted.length ~/ 2].clamp(0.0, 1250.0);

    if (_packetCount == 0) _kalX = raw;
    _kalP += 0.05;
    final double kG = _kalP / (_kalP + 2.5);
    _kalX = (_kalX + kG * (raw - _kalX)).clamp(0.0, 1250.0);
    _kalP = (1.0 - kG) * _kalP;

    if (_packetCount == 0) _hybX = med;
    _hybP += 0.05;
    final double hG = _hybP / (_hybP + 1.5);
    _hybX = (_hybX + hG * (med - _hybX)).clamp(0.0, 1250.0);
    _hybP = (1.0 - hG) * _hybP;

    _recordSample(raw, med, _kalX, _hybX, rssi, source: source);
  }

  void _recordSample(double raw, double med, double kal, double hyb, int rssi, {required String source}) {
    if (!mounted) return;

    final double clampedRaw = raw.clamp(0.0, 1250.0);
    final double clampedMed = med.clamp(0.0, 1250.0);
    final double clampedKal = kal.clamp(0.0, 1250.0);
    final double clampedHyb = hyb.clamp(0.0, 1250.0);

    final double uviCal = GuvaCalibrationEngine.calculateCalibratedUVI(clampedHyb);
    final double uviLin = GuvaCalibrationEngine.calculateOldLinearUVI(clampedHyb);
    final int uviInt = GuvaCalibrationEngine.lookupDiscreteUVI(clampedHyb);
    final String risk = GuvaCalibrationEngine.getRiskCategory(uviCal);

    final UVRecord rec = UVRecord(
      timestamp: DateTime.now(),
      mvRaw: clampedRaw,
      mvMedian: clampedMed,
      mvKalman: clampedKal,
      mvHybrid: clampedHyb,
      uviCalibrated: uviCal,
      uviLinearOld: uviLin,
      uviLookupInt: uviInt,
      riskCategory: risk,
      rssi: rssi,
    );

    setState(() {
      _latestRecord = rec;
      _packetCount++;
      _status = '$source • #$_packetCount';
      _liveRecords.add(rec);
      if (_liveRecords.length > 60) _liveRecords.removeAt(0);
    });

    _saveRecordToHistory(rec);
  }

  void _toggleDemoStream() {
    _pollTimer?.cancel();
    _influxSyncTimer?.cancel();
    setState(() {
      _isConnected = false;
      _isSimulating = !_isSimulating;
      if (_isSimulating) {
        _chartGranularity = 'Seconds';
        _generateDemoPoint();
        _pollTimer = Timer.periodic(
          Duration(seconds: _selectedPollSeconds),
          (_) => _generateDemoPoint(),
        );
      } else {
        _status = 'Demo Stopped';
      }
    });
  }

  void _generateDemoPoint() {
    final Random rng = Random();
    // Simulate a realistic solar bell-curve wave up to UVI 9-10 (980 mV)
    final double phase = (_packetCount % 24) / 24.0;
    final double bellCurve = sin(phase * pi);
    final double baseMv = 40.0 + (bellCurve * bellCurve) * 940.0;
    final double whiteNoise = (rng.nextDouble() - 0.5) * 35.0;
    final double wifiSpike = (rng.nextInt(5) == 0) ? 140.0 : 0.0;
    final double raw = (baseMv + whiteNoise + wifiSpike).clamp(0.0, 1250.0);
    _compute3FiltersLocallyAndRecord(raw, -48, source: 'WHO Bell-Curve Simulation');
  }

  double _calcFilterStdDev(String filterName) {
    if (_liveRecords.length < 3) return 0.0;
    final List<double> vals = _liveRecords.map((UVRecord r) => r.getMvByFilter(filterName)).toList();
    final List<double> diffs = <double>[];
    for (int i = 1; i < vals.length; i++) {
      diffs.add(vals[i] - vals[i - 1]);
    }
    final double mean = diffs.reduce((double a, double b) => a + b) / diffs.length;
    final double variance = diffs
            .map((double d) => pow(d - mean, 2).toDouble())
            .reduce((double a, double b) => a + b) /
        diffs.length;
    return sqrt(variance);
  }

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  List<UVRecord> _getFilteredRecords() {
    return _allHistoryRecords.where((UVRecord r) {
      final DateTime ts = r.timestamp;
      if (_periodMode == 'Year') {
        return ts.year == _selectedYear;
      } else if (_periodMode == 'Month') {
        return ts.year == _selectedYear && ts.month == _selectedMonth;
      } else if (_periodMode == 'Week') {
        final int wk = ((ts.day - 1) ~/ 7) + 1;
        return ts.year == _selectedYear && ts.month == _selectedMonth && wk == _selectedWeek;
      } else {
        return ts.year == _selectedYear && ts.month == _selectedMonth && ts.day == _selectedDay;
      }
    }).toList();
  }

  List<HourlyBucketStat> _get24HrList({bool sortDescending = true}) {
    final Iterable<UVRecord> dayRecords = _allHistoryRecords.where((UVRecord r) =>
        r.timestamp.year == _selectedYear &&
        r.timestamp.month == _selectedMonth &&
        r.timestamp.day == _selectedDay);

    final Map<int, List<UVRecord>> byHour = <int, List<UVRecord>>{
      for (int h = 0; h < 24; h++) h: <UVRecord>[]
    };
    for (final UVRecord r in dayRecords) {
      byHour[r.timestamp.hour]?.add(r);
    }

    final List<HourlyBucketStat> list24 = <HourlyBucketStat>[];
    for (int h = 0; h < 24; h++) {
      final List<UVRecord> items = byHour[h]!;
      double peakUvi = 0.0;
      double avgMv = 0.0;
      if (items.isNotEmpty) {
        for (final UVRecord item in items) {
          final double u = item.getUviByFilter(_selectedFilter);
          if (u > peakUvi) peakUvi = u;
          avgMv += item.getMvByFilter(_selectedFilter);
        }
        avgMv /= items.length;
      }
      list24.add(HourlyBucketStat(
        hour: h,
        timeSlot: '${h.toString().padLeft(2, '0')}:00',
        peakUvi: peakUvi,
        avgMv: avgMv,
        count: items.length,
        risk: GuvaCalibrationEngine.getRiskCategory(peakUvi),
      ));
    }

    if (sortDescending) {
      list24.sort((HourlyBucketStat a, HourlyBucketStat b) => b.peakUvi.compareTo(a.peakUvi));
    }
    return list24;
  }

  // ================= DYNAMIC GRAPH AGGREGATION =================
  List<ChartDataPoint> _getAggregatedChartPoints() {
    final List<UVRecord> source = _getFilteredRecords();

    // If user is in 'Date' & 'Hours' mode, render a 24-hour solar profile like the WHO UV screenshot
    if (_periodMode == 'Date' && _chartGranularity == 'Hours') {
      final List<HourlyBucketStat> hrs = _get24HrList(sortDescending: false);
      final bool hasAnyData = hrs.any((HourlyBucketStat h) => h.count > 0);
      if (!hasAnyData) return <ChartDataPoint>[];
      return hrs.map((HourlyBucketStat h) {
        return ChartDataPoint(
          label: '${h.hour}',
          uviFiltered: h.peakUvi,
          uviRaw: h.peakUvi,
          mvFiltered: h.avgMv,
          mvRaw: h.avgMv,
        );
      }).toList();
    }

    if (source.isEmpty) return <ChartDataPoint>[];

    final Map<String, List<UVRecord>> bucketed = <String, List<UVRecord>>{};
    for (final UVRecord r in source) {
      String key;
      if (_chartGranularity == 'Seconds') {
        key = DateFormat('HH:mm:ss').format(r.timestamp);
      } else if (_chartGranularity == 'Minutes') {
        key = DateFormat('HH:mm').format(r.timestamp);
      } else if (_chartGranularity == 'Hours') {
        key = DateFormat('MM-dd HH:00').format(r.timestamp);
      } else if (_chartGranularity == 'Days') {
        key = DateFormat('MM-dd').format(r.timestamp);
      } else if (_chartGranularity == 'Months') {
        key = DateFormat('yyyy-MM').format(r.timestamp);
      } else {
        key = DateFormat('yyyy').format(r.timestamp);
      }
      bucketed.putIfAbsent(key, () => <UVRecord>[]).add(r);
    }

    final List<ChartDataPoint> points = <ChartDataPoint>[];
    bucketed.forEach((String key, List<UVRecord> recs) {
      final double avgRawMv = (recs.map((UVRecord r) => r.mvRaw).reduce((double a, double b) => a + b) / recs.length).clamp(0.0, 1250.0);
      final double avgFiltMv = (recs.map((UVRecord r) => r.getMvByFilter(_selectedFilter)).reduce((double a, double b) => a + b) / recs.length).clamp(0.0, 1250.0);
      points.add(ChartDataPoint(
        label: key,
        uviFiltered: GuvaCalibrationEngine.calculateCalibratedUVI(avgFiltMv),
        uviRaw: GuvaCalibrationEngine.calculateCalibratedUVI(avgRawMv),
        mvFiltered: avgFiltMv,
        mvRaw: avgRawMv,
      ));
    });

    points.sort((ChartDataPoint a, ChartDataPoint b) => a.label.compareTo(b.label));
    return points;
  }

  List<GranularTelemetryRow> _getGranularityTableRows({bool unlimited = false}) {
    final List<UVRecord> source = _getFilteredRecords();
    if (source.isEmpty) return <GranularTelemetryRow>[];

    final Map<String, List<UVRecord>> bucketed = <String, List<UVRecord>>{};
    for (final UVRecord r in source.reversed) {
      String key;
      if (_timeGranularity == 'Seconds') {
        key = DateFormat('yyyy-MM-dd HH:mm:ss').format(r.timestamp);
      } else if (_timeGranularity == 'Minutes') {
        key = DateFormat('yyyy-MM-dd HH:mm').format(r.timestamp);
      } else if (_timeGranularity == 'Hours') {
        key = DateFormat('yyyy-MM-dd HH:00').format(r.timestamp);
      } else {
        key = DateFormat('yyyy-MM-dd').format(r.timestamp);
      }
      bucketed.putIfAbsent(key, () => <UVRecord>[]).add(r);
    }

    final Iterable<MapEntry<String, List<UVRecord>>> entries =
        unlimited ? bucketed.entries : bucketed.entries.take(150);

    return entries.map((MapEntry<String, List<UVRecord>> e) {
      final List<UVRecord> recs = e.value;
      final double avgMv = (recs.map((UVRecord r) => r.getMvByFilter(_selectedFilter)).reduce((double a, double b) => a + b) / recs.length).clamp(0.0, 1250.0);
      final double avgUvi = GuvaCalibrationEngine.calculateCalibratedUVI(avgMv);
      return GranularTelemetryRow(
        time: e.key,
        uvData: '${avgUvi.toStringAsFixed(2)} UVI (${GuvaCalibrationEngine.getRiskCategory(avgUvi)})',
        voltage: '${avgMv.toStringAsFixed(1)} mV',
      );
    }).toList();
  }

  // ================= FULL GRAPH DATA EXPORT (NO SCREENSHOT CLIPPING) =================
  Future<void> _downloadFullGraphDataCsv() async {
    final List<ChartDataPoint> points = _getAggregatedChartPoints();
    if (points.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No graph data in current period to export!')),
      );
      return;
    }

    final StringBuffer csv = StringBuffer();
    csv.writeln('Time_Bucket ($_chartGranularity),Calibrated_UVI ($_selectedFilter),Raw_UVI,Filtered_mV,Raw_mV,WHO_Risk_Level');
    for (final ChartDataPoint pt in points) {
      final String risk = GuvaCalibrationEngine.getRiskCategory(pt.uviFiltered);
      csv.writeln(
        '${pt.label},'
        '${pt.uviFiltered.toStringAsFixed(3)},'
        '${pt.uviRaw.toStringAsFixed(3)},'
        '${pt.mvFiltered.toStringAsFixed(2)},'
        '${pt.mvRaw.toStringAsFixed(2)},'
        '$risk',
      );
    }

    final Directory dir = await getTemporaryDirectory();
    final File file = File('${dir.path}/full_uv_graph_data_${_chartGranularity.toLowerCase()}_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv');
    await file.writeAsString(csv.toString());
    await Share.shareXFiles(<XFile>[XFile(file.path)], text: 'Full UV Graph Dataset ($_chartGranularity - $_selectedFilter)');
  }

  // Renders 100% of data points onto an offscreen full-width high-res canvas (NOT a screen screenshot!)
  Future<void> _exportFullCanvasGraphPng() async {
    final List<ChartDataPoint> points = _getAggregatedChartPoints();
    if (points.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No graph data available to render!')),
      );
      return;
    }

    try {
      final int n = points.length;
      final double width = max(1400.0, n * 64.0 + 180.0);
      const double height = 680.0;
      const double leftPad = 100.0;
      const double rightPad = 70.0;
      const double topPad = 110.0;
      const double bottomPad = 90.0;
      final double plotW = width - leftPad - rightPad;
      final double plotH = height - topPad - bottomPad;

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));

      // Background
      final Paint bgPaint = Paint()..color = const Color(0xFF14161D);
      canvas.drawRect(Rect.fromLTWH(0, 0, width, height), bgPaint);

      // Header text
      _drawCanvasText(
        canvas,
        'World Health Organization UVI — Full Sensor Graph Export ($_selectedFilter • $_chartGranularity)',
        const Offset(leftPad, 28),
        fontSize: 22,
        bold: true,
        color: Colors.white,
      );
      _drawCanvasText(
        canvas,
        'Exported: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now())}  |  Total Plotted Buckets: $n  |  Range: 0 - 1250 mV Clamped',
        const Offset(leftPad, 62),
        fontSize: 14,
        color: Colors.white70,
      );

      // Horizontal WHO grid lines (0..12)
      final Paint gridPaint = Paint()
        ..color = Colors.white.withOpacity(0.12)
        ..strokeWidth = 1.0;

      final Map<int, String> whoLabels = <int, String>{
        1: 'Low',
        3: 'Moderate',
        6: 'High',
        8: 'Very High',
        11: 'Extreme',
      };

      for (int u = 0; u <= 12; u++) {
        final double y = topPad + plotH * (1.0 - (u / 12.0));
        canvas.drawLine(Offset(leftPad, y), Offset(leftPad + plotW, y), gridPaint);
        _drawCanvasText(
          canvas,
          '$u',
          Offset(leftPad + plotW + 14, y - 8),
          fontSize: 13,
          color: Colors.white60,
        );
        if (whoLabels.containsKey(u)) {
          _drawCanvasText(
            canvas,
            whoLabels[u]!,
            Offset(18, y - 10),
            fontSize: 13,
            bold: true,
            color: Colors.white70,
          );
        }
      }

      // Compute Coordinates
      final List<Offset> coords = <Offset>[];
      double peakUvi = -1.0;
      int peakIdx = 0;

      for (int i = 0; i < n; i++) {
        final double x = n == 1 ? leftPad + plotW / 2 : leftPad + (i / (n - 1)) * plotW;
        final double uviClamped = points[i].uviFiltered.clamp(0.0, 12.0);
        final double y = topPad + plotH * (1.0 - (uviClamped / 12.0));
        coords.add(Offset(x, y));

        if (points[i].uviFiltered > peakUvi) {
          peakUvi = points[i].uviFiltered;
          peakIdx = i;
        }
      }

      // Build smooth cubic path
      final Path linePath = Path();
      final Path fillPath = Path();
      if (coords.isNotEmpty) {
        linePath.moveTo(coords.first.dx, coords.first.dy);
        fillPath.moveTo(coords.first.dx, topPad + plotH);
        fillPath.lineTo(coords.first.dx, coords.first.dy);

        for (int i = 0; i < coords.length - 1; i++) {
          final Offset p0 = coords[i];
          final Offset p1 = coords[i + 1];
          final double ctrlX = (p0.dx + p1.dx) / 2;
          linePath.cubicTo(ctrlX, p0.dy, ctrlX, p1.dy, p1.dx, p1.dy);
          fillPath.cubicTo(ctrlX, p0.dy, ctrlX, p1.dy, p1.dx, p1.dy);
        }
        fillPath.lineTo(coords.last.dx, topPad + plotH);
        fillPath.close();
      }

      // Fill under curve with WHO gradient
      final Paint fillPaint = Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, topPad + plotH),
          Offset(0, topPad),
          <Color>[
            const Color(0xFF2ECC71).withOpacity(0.55),
            const Color(0xFFF1C40F).withOpacity(0.65),
            const Color(0xFFE67E22).withOpacity(0.75),
            const Color(0xFFE84393).withOpacity(0.85),
          ],
          <double>[0.0, 0.35, 0.65, 1.0],
        )
        ..style = PaintingStyle.fill;
      canvas.drawPath(fillPath, fillPaint);

      // Stroke Curve with WHO gradient
      final Paint strokePaint = Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, topPad + plotH),
          Offset(0, topPad),
          _whoGradientColors,
          <double>[0.0, 0.35, 0.65, 1.0],
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(linePath, strokePaint);

      // Draw X-axis labels & top integer UVI badges
      final int labelStep = max(1, n ~/ 24);
      for (int i = 0; i < n; i++) {
        final Offset pt = coords[i];
        if (i % labelStep == 0 || i == n - 1) {
          _drawCanvasText(
            canvas,
            points[i].label,
            Offset(pt.dx - 20, topPad + plotH + 18),
            fontSize: 12,
            color: Colors.white70,
          );
          _drawCanvasText(
            canvas,
            points[i].uviFiltered.round().toString(),
            Offset(pt.dx - 5, topPad - 24),
            fontSize: 12,
            bold: true,
            color: Colors.white70,
          );
        }
      }

      // Highlight Peak Dot
      if (coords.isNotEmpty) {
        final Offset pk = coords[peakIdx];
        canvas.drawCircle(pk, 8, Paint()..color = const Color(0xFFE84393));
        canvas.drawCircle(pk, 4, Paint()..color = Colors.black);
        _drawCanvasText(
          canvas,
          'Peak: ${peakUvi.toStringAsFixed(1)}',
          Offset(pk.dx - 28, pk.dy - 26),
          fontSize: 13,
          bold: true,
          color: Colors.white,
        );
      }

      final ui.Picture picture = recorder.endRecording();
      final ui.Image img = await picture.toImage(width.toInt(), height.toInt());
      final ByteData? byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final Directory dir = await getTemporaryDirectory();
      final File file = File('${dir.path}/full_uv_gradient_graph_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());
      await Share.shareXFiles(<XFile>[XFile(file.path)], text: 'Full High-Res WHO UV Index Gradient Graph ($_selectedFilter)');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export Error: $e')));
    }
  }

  void _drawCanvasText(
    Canvas canvas,
    String text,
    Offset offset, {
    double fontSize = 12,
    bool bold = false,
    Color color = Colors.white,
  }) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  Future<void> _downloadGranularityCsv() async {
    final List<GranularTelemetryRow> rows = _getGranularityTableRows(unlimited: true);
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data in current selection to download!')),
      );
      return;
    }

    final StringBuffer csv = StringBuffer();
    csv.writeln('Time ($_timeGranularity),UV_Index_Calibrated,Voltage_mV,Filter_Used');
    for (final GranularTelemetryRow r in rows) {
      csv.writeln('${r.time},${r.uvData},${r.voltage},$_selectedFilter');
    }

    final Directory dir = await getTemporaryDirectory();
    final File file = File('${dir.path}/uv_${_timeGranularity.toLowerCase()}_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv');
    await file.writeAsString(csv.toString());
    await Share.shareXFiles(<XFile>[XFile(file.path)], text: 'Full UV Sensor Data ($_timeGranularity Granularity)');
  }

  Future<void> _download3FilterComparisonCsv() async {
    final List<UVRecord> list = _getFilteredRecords().isNotEmpty ? _getFilteredRecords() : _allHistoryRecords;
    if (list.isEmpty) return;

    final StringBuffer csv = StringBuffer();
    csv.writeln('Timestamp,Raw_mV,Median_mV,Kalman_mV,Hybrid_MedKal_mV,UVI_Calibrated,UVI_Lookup_Int,UVI_Linear_Old,Risk_Category');

    final DateFormat df = DateFormat('yyyy-MM-dd HH:mm:ss');
    for (final UVRecord r in list) {
      csv.writeln(
        '${df.format(r.timestamp)},'
        '${r.mvRaw.clamp(0.0, 1250.0).toStringAsFixed(2)},'
        '${r.mvMedian.clamp(0.0, 1250.0).toStringAsFixed(2)},'
        '${r.mvKalman.clamp(0.0, 1250.0).toStringAsFixed(2)},'
        '${r.mvHybrid.clamp(0.0, 1250.0).toStringAsFixed(2)},'
        '${r.uviCalibrated.toStringAsFixed(3)},'
        '${r.uviLookupInt},'
        '${r.uviLinearOld.toStringAsFixed(3)},'
        '${r.riskCategory}',
      );
    }

    final Directory dir = await getTemporaryDirectory();
    final File file = File('${dir.path}/uv_3filter_comparison_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv');
    await file.writeAsString(csv.toString());
    await Share.shareXFiles(<XFile>[XFile(file.path)], text: '3-Filter UV Comparison Dataset (Hybrid, Kalman, Median)');
  }

  Future<void> _showPhoneStyleWiFiDialog() async {
    final TextEditingController ssidCtrl = TextEditingController();
    final TextEditingController passCtrl = TextEditingController();
    final TextEditingController influxUrlCtrl = TextEditingController();
    final TextEditingController influxTokCtrl = TextEditingController();
    List<dynamic> scannedNetworks = <dynamic>[];
    bool scanning = true;

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setDialogState) {
          if (scanning) {
            scanning = false;
            final String ip = _ipController.text.trim();
            http
                .get(Uri.parse('http://$ip/scan'))
                .timeout(const Duration(seconds: 4))
                .then((http.Response res) {
              if (res.statusCode == 200) {
                final Map<String, dynamic> data = jsonDecode(res.body) as Map<String, dynamic>;
                setDialogState(() {
                  scannedNetworks = (data['networks'] as List<dynamic>?) ?? <dynamic>[];
                });
              }
            }).catchError((Object _) {});
          }

          return AlertDialog(
            title: const Row(
              children: <Widget>[
                Icon(Icons.wifi_rounded, color: Color(0xFF1A73E8)),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Connect ESP32 to Wi-Fi', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (scannedNetworks.isNotEmpty) ...<Widget>[
                    const Text('Available Networks Found by ESP32:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 110,
                      width: double.maxFinite,
                      child: ListView.builder(
                        itemCount: scannedNetworks.length,
                        itemBuilder: (BuildContext _, int i) {
                          final Map<String, dynamic> net = scannedNetworks[i] as Map<String, dynamic>;
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.network_wifi, size: 18),
                            title: Text('${net['ssid']}', style: const TextStyle(fontSize: 12)),
                            trailing: Text('${net['rssi']} dBm', style: const TextStyle(fontSize: 10)),
                            onTap: () {
                              setDialogState(() {
                                ssidCtrl.text = net['ssid'].toString();
                              });
                            },
                          );
                        },
                      ),
                    ),
                    const Divider(),
                  ],
                  TextField(
                    controller: ssidCtrl,
                    decoration: const InputDecoration(labelText: 'Wi-Fi / Hotspot Name (SSID)', isDense: true, border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Wi-Fi Password', isDense: true, border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  const Text('Optional InfluxDB Cloud Override:', style: TextStyle(fontSize: 11)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: influxUrlCtrl,
                    decoration: const InputDecoration(labelText: 'InfluxDB Write URL', isDense: true, border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: influxTokCtrl,
                    decoration: const InputDecoration(labelText: 'InfluxDB API Token', isDense: true, border: OutlineInputBorder()),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  final String ip = _ipController.text.trim();
                  final NavigatorState nav = Navigator.of(ctx);
                  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
                  try {
                    await http.post(
                      Uri.parse('http://$ip/wifi'),
                      body: <String, String>{
                        'ssid': ssidCtrl.text.trim(),
                        'pass': passCtrl.text,
                        'influx_url': influxUrlCtrl.text.trim(),
                        'influx_token': influxTokCtrl.text.trim(),
                      },
                    );
                    nav.pop();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Saved! ESP32 is reconnecting & syncing via HiveMQ Cloud.')),
                    );
                  } catch (e) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Tip: Connect phone to "ESP32_UV_WiFi_Setup" AP (IP 192.168.4.1) if changing networks.')),
                    );
                  }
                },
                child: const Text('Connect ESP32'),
              ),
            ],
          );
        },
      ),
    );
  }

  Color _getRiskColor(double uvi) {
    if (uvi < 3.0) return const Color(0xFF2ECC71);
    if (uvi < 6.0) return const Color(0xFFF39C12);
    if (uvi < 8.0) return const Color(0xFFE67E22);
    if (uvi < 11.0) return const Color(0xFFE84393);
    return const Color(0xFF8E44AD);
  }

  String _getSunProtectionWindowText(List<HourlyBucketStat> hrs, double currentUvi) {
    final List<int> activeHours = hrs
        .where((HourlyBucketStat h) => h.peakUvi >= 3.0)
        .map((HourlyBucketStat h) => h.hour)
        .toList()
      ..sort();
    if (activeHours.isNotEmpty) {
      final String start = '${activeHours.first.toString().padLeft(2, '0')}:00';
      final String end = '${(activeHours.last + 1).clamp(0, 23).toString().padLeft(2, '0')}:00';
      return 'Sun protection recommended from $start to $end.';
    }
    if (currentUvi >= 3.0) {
      return 'Sun protection recommended right now (UVI ≥ 3).';
    }
    return 'UV levels are currently low. Minimal sun protection needed.';
  }

  List<DateTime> _get7DayStripDates() {
    final int maxDay = _daysInMonth(_selectedYear, _selectedMonth);
    final int safeDay = _selectedDay.clamp(1, maxDay);
    final DateTime selectedDate = DateTime(_selectedYear, _selectedMonth, safeDay);
    return List<DateTime>.generate(7, (int i) => selectedDate.subtract(Duration(days: 3 - i)));
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = widget.isDarkMode;
    final Color cardBg = isDark ? const Color(0xFF1E2028) : Colors.white;
    final Color subtleBorder = isDark ? Colors.white12 : const Color(0xFFE5E7EB);
    final Color primaryText = isDark ? Colors.white : const Color(0xFF111827);
    final Color secondaryText = isDark ? Colors.white70 : const Color(0xFF4B5563);

    final double activeMv = (_latestRecord?.getMvByFilter(_selectedFilter) ?? 0.0).clamp(0.0, 1250.0);
    final double activeUvi = GuvaCalibrationEngine.calculateCalibratedUVI(activeMv);
    final int discreteUvi = GuvaCalibrationEngine.lookupDiscreteUVI(activeMv);
    final String activeRisk = GuvaCalibrationEngine.getRiskCategory(activeUvi);
    final Color activeColor = _getRiskColor(activeUvi);

    final List<HourlyBucketStat> hourlyRanked = _get24HrList(sortDescending: true);
    final List<HourlyBucketStat> hourlyChronological = _get24HrList(sortDescending: false);
    final double maxDayUvi = hourlyRanked.isNotEmpty ? max(hourlyRanked.first.peakUvi, activeUvi) : activeUvi;

    final List<GranularTelemetryRow> granularRows = _getGranularityTableRows();
    final List<ChartDataPoint> chartPoints = _getAggregatedChartPoints();

    int peakSpotIndex = 0;
    double maxChartUvi = -1.0;
    for (int i = 0; i < chartPoints.length; i++) {
      if (chartPoints[i].uviFiltered > maxChartUvi) {
        maxChartUvi = chartPoints[i].uviFiltered;
        peakSpotIndex = i;
      }
    }

    final int currentYear = DateTime.now().year;
    final List<int> yearOptions = List<int>.generate((currentYear - 2020) + 1, (int i) => 2020 + i);
    final int maxDays = _daysInMonth(_selectedYear, _selectedMonth);
    if (_selectedDay > maxDays) _selectedDay = maxDays;

    final DateTime selectedFullDate = DateTime(_selectedYear, _selectedMonth, _selectedDay);
    final List<DateTime> stripDates = _get7DayStripDates();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: cardBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: <Widget>[
            Icon(Icons.wb_sunny_outlined, color: activeColor, size: 22),
            const SizedBox(width: 8),
            Text(
              'UV Index',
              style: TextStyle(color: primaryText, fontWeight: FontWeight.w800, fontSize: 18),
            ),
          ],
        ),
        actions: <Widget>[
          // Theme Mode Toggle Button (White Mode <-> Dark Mode)
          IconButton(
            tooltip: isDark ? 'Switch to White (Light) Mode' : 'Switch to Dark Mode',
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_outlined,
              color: isDark ? const Color(0xFFFBBF24) : const Color(0xFF374151),
            ),
            onPressed: widget.onToggleTheme,
          ),
          IconButton(
            tooltip: 'Configure ESP32 Wi-Fi',
            icon: Icon(Icons.wifi_rounded, color: primaryText),
            onPressed: _showPhoneStyleWiFiDialog,
          ),
          IconButton(
            tooltip: 'Sync InfluxDB Cloud',
            icon: const Icon(Icons.cloud_sync_outlined, color: Color(0xFF1A73E8)),
            onPressed: _syncFromInfluxDbCloud,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: FilledButton.tonalIcon(
              onPressed: _toggleDemoStream,
              icon: Icon(
                _isSimulating ? Icons.stop_circle_outlined : Icons.auto_graph_rounded,
                size: 18,
              ),
              label: Text(_isSimulating ? 'Stop' : 'Demo'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // ================= 1. GOOGLE WEATHER 7-DAY CALENDAR STRIP =================
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: subtleBorder),
                ),
                child: Column(
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: stripDates.map((DateTime dt) {
                        final bool isSelected = dt.year == _selectedYear &&
                            dt.month == _selectedMonth &&
                            dt.day == _selectedDay;
                        final String wkLetter = _weekdayShort[dt.weekday - 1];
                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              _periodMode = 'Date';
                              _selectedYear = dt.year;
                              _selectedMonth = dt.month;
                              _selectedDay = dt.day;
                            });
                          },
                          child: Column(
                            children: <Widget>[
                              Text(
                                wkLetter,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: secondaryText,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isSelected
                                      ? (isDark ? Colors.white : const Color(0xFF111827))
                                      : Colors.transparent,
                                ),
                                child: Text(
                                  '${dt.day}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected
                                        ? (isDark ? Colors.black : Colors.white)
                                        : primaryText,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      DateFormat('EEEE, d MMMM yyyy').format(selectedFullDate),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: secondaryText),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ================= 2. GOOGLE WEATHER HERO PILL + RAINBOW UV GAUGE =================
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: subtleBorder),
                  boxShadow: isDark
                      ? <BoxShadow>[]
                      : <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(Icons.location_on_outlined, size: 16, color: secondaryText),
                              const SizedBox(width: 4),
                              Text(
                                'ESP32-C3 Edge Sensor • GPIO2',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: secondaryText),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'UV ${activeUvi.toStringAsFixed(1)}',
                            style: TextStyle(
                              fontSize: 44,
                              fontWeight: FontWeight.w900,
                              color: primaryText,
                              letterSpacing: -1.0,
                            ),
                          ),
                          Text(
                            activeRisk,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: activeColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Filtered: ${activeMv.toStringAsFixed(1)} mV  •  Raw: ${(_latestRecord?.mvRaw ?? 0.0).clamp(0.0, 1250.0).toStringAsFixed(1)} mV',
                            style: TextStyle(fontSize: 12, color: secondaryText),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      children: <Widget>[
                        SizedBox(
                          width: 96,
                          height: 96,
                          child: CustomPaint(
                            painter: GoogleWeatherUvArcPainter(uvi: activeUvi, isDark: isDark),
                            child: Center(
                              child: Text(
                                '$discreteUvi',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                  color: primaryText,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Max UV: ${maxDayUvi.toStringAsFixed(1)}',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: secondaryText),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ================= 3. WHO UV INDEX BELL-CURVE GRADIENT GRAPH CARD =================
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: subtleBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // Top header exactly like the reference screenshot
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            RichText(
                              text: TextSpan(
                                children: <InlineSpan>[
                                  TextSpan(
                                    text: '${activeUvi.round()} ',
                                    style: TextStyle(
                                      fontSize: 32,
                                      fontWeight: FontWeight.w900,
                                      color: primaryText,
                                    ),
                                  ),
                                  TextSpan(
                                    text: activeRisk,
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w600,
                                      color: secondaryText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'World Health Organization UVI',
                              style: TextStyle(fontSize: 12, color: secondaryText),
                            ),
                          ],
                        ),
                        // Granularity pill selector + Full Export Menu
                        Row(
                          children: <Widget>[
                            Container(
                              height: 34,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF2C2F3A) : const Color(0xFFF3F4F6),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: _chartGranularity,
                                  icon: Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: primaryText),
                                  items: <String>['Seconds', 'Minutes', 'Hours', 'Days', 'Months', 'Years']
                                      .map((String unit) => DropdownMenuItem<String>(
                                            value: unit,
                                            child: Text(
                                              unit,
                                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: primaryText),
                                            ),
                                          ))
                                      .toList(),
                                  onChanged: (String? v) {
                                    if (v != null) setState(() => _chartGranularity = v);
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            PopupMenuButton<String>(
                              tooltip: 'Export Full Unclipped Graph Data',
                              icon: Icon(Icons.download_rounded, color: primaryText),
                              onSelected: (String val) {
                                if (val == 'csv') {
                                  _downloadFullGraphDataCsv();
                                } else {
                                  _exportFullCanvasGraphPng();
                                }
                              },
                              itemBuilder: (BuildContext _) => <PopupMenuEntry<String>>[
                                const PopupMenuItem<String>(
                                  value: 'csv',
                                  child: ListTile(
                                    leading: Icon(Icons.table_chart_outlined),
                                    title: Text('Download Full Graph Data (CSV)'),
                                    subtitle: Text('All plotted points, UVI & mV (No truncation)'),
                                    dense: true,
                                  ),
                                ),
                                const PopupMenuItem<String>(
                                  value: 'png',
                                  child: ListTile(
                                    leading: Icon(Icons.panorama_horizontal_outlined),
                                    title: Text('Export Full Unclipped Canvas (PNG)'),
                                    subtitle: Text('Renders entire timeline offscreen (Not a screenshot)'),
                                    dense: true,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Top row of integer UVI values across the graph (matching screenshot)
                    if (chartPoints.isNotEmpty)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: chartPoints.take(24).map((ChartDataPoint pt) {
                            return Container(
                              width: 34,
                              alignment: Alignment.center,
                              child: Text(
                                '${pt.uviFiltered.round()}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: secondaryText,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    const SizedBox(height: 6),

                    // WHO Gradient Bell-Curve Chart Container
                    Container(
                      height: 255,
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF15171E) : const Color(0xFFF9FAFB),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: subtleBorder),
                      ),
                      child: chartPoints.isEmpty
                          ? Center(
                              child: Text(
                                'Tap "Demo" or "Connect" to view the live WHO UV Gradient Curve.',
                                style: TextStyle(color: secondaryText, fontSize: 12),
                              ),
                            )
                          : SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: max(
                                  MediaQuery.of(context).size.width - 64,
                                  chartPoints.length * (_chartGranularity == 'Hours' ? 28.0 : 48.0),
                                ),
                                child: LineChart(
                                  LineChartData(
                                    minY: 0,
                                    maxY: 12,
                                    clipData: const FlClipData.all(),
                                    gridData: FlGridData(
                                      show: true,
                                      drawVerticalLine: true,
                                      horizontalInterval: 1,
                                      verticalInterval: _chartGranularity == 'Hours' ? 6 : 1,
                                      getDrawingHorizontalLine: (double v) => FlLine(
                                        color: isDark
                                            ? Colors.white.withOpacity(0.07)
                                            : Colors.black.withOpacity(0.07),
                                        strokeWidth: 1,
                                      ),
                                      getDrawingVerticalLine: (double v) => FlLine(
                                        color: isDark
                                            ? Colors.white.withOpacity(0.06)
                                            : Colors.black.withOpacity(0.06),
                                        strokeWidth: 1,
                                      ),
                                    ),
                                    borderData: FlBorderData(show: false),
                                    extraLinesData: ExtraLinesData(
                                      horizontalLines: <HorizontalLine>[
                                        _whoBandLabelLine(1, 'Low', isDark),
                                        _whoBandLabelLine(3, 'Moderate', isDark),
                                        _whoBandLabelLine(6, 'High', isDark),
                                        _whoBandLabelLine(8, 'Very High', isDark),
                                        _whoBandLabelLine(11, 'Extreme', isDark),
                                      ],
                                    ),
                                    titlesData: FlTitlesData(
                                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                      rightTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: true,
                                          reservedSize: 26,
                                          interval: 1,
                                          getTitlesWidget: (double val, TitleMeta meta) {
                                            final int v = val.round();
                                            if (v < 0 || v > 12) return const SizedBox.shrink();
                                            return Padding(
                                              padding: const EdgeInsets.only(left: 6.0),
                                              child: Text(
                                                '$v',
                                                style: TextStyle(fontSize: 10, color: secondaryText),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                      bottomTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: true,
                                          reservedSize: 24,
                                          interval: _chartGranularity == 'Hours' ? 6 : 1,
                                          getTitlesWidget: (double val, TitleMeta meta) {
                                            final int idx = val.toInt();
                                            if (idx >= 0 && idx < chartPoints.length) {
                                              return Padding(
                                                padding: const EdgeInsets.only(top: 6.0),
                                                child: Text(
                                                  chartPoints[idx].label,
                                                  style: TextStyle(fontSize: 10, color: secondaryText),
                                                ),
                                              );
                                            }
                                            return const SizedBox.shrink();
                                          },
                                        ),
                                      ),
                                    ),
                                    lineBarsData: <LineChartBarData>[
                                      if (_overlayRawOnChart)
                                        LineChartBarData(
                                          spots: chartPoints
                                              .asMap()
                                              .entries
                                              .map((MapEntry<int, ChartDataPoint> e) =>
                                                  FlSpot(e.key.toDouble(), e.value.uviRaw.clamp(0.0, 12.0)))
                                              .toList(),
                                          isCurved: false,
                                          color: Colors.grey.withOpacity(0.55),
                                          barWidth: 1.5,
                                          dashArray: <int>[4, 4],
                                          dotData: const FlDotData(show: false),
                                        ),
                                      // Main WHO Gradient Curve
                                      LineChartBarData(
                                        spots: chartPoints
                                            .asMap()
                                            .entries
                                            .map((MapEntry<int, ChartDataPoint> e) =>
                                                FlSpot(e.key.toDouble(), e.value.uviFiltered.clamp(0.0, 12.0)))
                                            .toList(),
                                        isCurved: true,
                                        curveSmoothness: 0.32,
                                        preventCurveOverShooting: true,
                                        barWidth: 3.5,
                                        gradient: const LinearGradient(
                                          begin: Alignment.bottomCenter,
                                          end: Alignment.topCenter,
                                          colors: _whoGradientColors,
                                          stops: <double>[0.0, 0.35, 0.65, 1.0],
                                        ),
                                        belowBarData: BarAreaData(
                                          show: true,
                                          gradient: LinearGradient(
                                            begin: Alignment.bottomCenter,
                                            end: Alignment.topCenter,
                                            colors: <Color>[
                                              const Color(0xFF2ECC71).withOpacity(0.38),
                                              const Color(0xFFF1C40F).withOpacity(0.48),
                                              const Color(0xFFE67E22).withOpacity(0.58),
                                              const Color(0xFFE84393).withOpacity(0.68),
                                            ],
                                            stops: const <double>[0.0, 0.35, 0.65, 1.0],
                                          ),
                                        ),
                                        dotData: FlDotData(
                                          show: true,
                                          checkToShowDot: (FlSpot spot, LineChartBarData barData) =>
                                              spot.x.toInt() == peakSpotIndex && spot.y > 0,
                                          getDotPainter: (FlSpot spot, double pct, LineChartBarData bar, int idx) =>
                                              FlDotCirclePainter(
                                            radius: 5.5,
                                            color: isDark ? Colors.black : Colors.white,
                                            strokeWidth: 3.0,
                                            strokeColor: const Color(0xFFE84393),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      DateFormat('d MMMM yyyy').format(selectedFullDate),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: primaryText),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _getSunProtectionWindowText(hourlyChronological, activeUvi),
                      style: TextStyle(fontSize: 13, color: secondaryText),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ================= 4. GOOGLE WEATHER HOURLY FORECAST STRIP =================
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: subtleBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(Icons.schedule_rounded, size: 18, color: secondaryText),
                        const SizedBox(width: 6),
                        Text(
                          'Hourly UV Forecast & Sensor Log',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: primaryText),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: hourlyChronological.map((HourlyBucketStat h) {
                          final Color c = _getRiskColor(h.peakUvi);
                          return Container(
                            width: 62,
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF15171E) : const Color(0xFFF9FAFB),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: subtleBorder),
                            ),
                            child: Column(
                              children: <Widget>[
                                Text(
                                  h.peakUvi.toStringAsFixed(1),
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: primaryText),
                                ),
                                const SizedBox(height: 8),
                                Icon(
                                  h.peakUvi >= 3.0 ? Icons.wb_sunny_rounded : Icons.wb_twilight_rounded,
                                  color: c,
                                  size: 20,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${h.avgMv.round()}mV',
                                  style: TextStyle(fontSize: 10, color: secondaryText),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  h.timeSlot,
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: secondaryText),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ================= 5. GOOGLE WEATHER PERSONAL UV INSIGHTS & WHO GUIDE =================
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: subtleBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(Icons.auto_awesome_rounded, size: 18, color: activeColor),
                        const SizedBox(width: 6),
                        Text(
                          'Personal UV Protection Insights',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: primaryText),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _insightBullet(
                      title: 'Wear sunblock',
                      body: activeUvi >= 3.0
                          ? 'Apply broad-spectrum SPF 30+ sunscreen and reapply every 2 hours while outdoors.'
                          : 'UV Index is below 3. Sunscreen is optional unless outdoors for extended periods.',
                      primaryText: primaryText,
                      secondaryText: secondaryText,
                    ),
                    const SizedBox(height: 8),
                    _insightBullet(
                      title: 'Clothing & Shade',
                      body: activeUvi >= 6.0
                          ? 'High/Very High UV detected. Wear a wide-brimmed sunhat, UV-blocking sunglasses, and seek shade between 10 AM and 4 PM.'
                          : 'Lightweight breathable clothing and sunglasses recommended for bright daylight.',
                      primaryText: primaryText,
                      secondaryText: secondaryText,
                    ),
                    const Divider(height: 22),
                    Text(
                      'About the UV Index',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: primaryText),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'The World Health Organization\'s UV index (UVI) measures ultraviolet radiation. The higher the UVI, the greater the potential for skin and eye damage, and the faster harm can occur.',
                      style: TextStyle(fontSize: 12, height: 1.45, color: secondaryText),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ================= 6. SENSOR CONNECTION & 3-TIER DSP FILTER LAB =================
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: subtleBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'ESP32-C3 Telemetry & 3-Tier DSP Filter Lab',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: primaryText),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _ipController,
                            style: TextStyle(color: primaryText, fontWeight: FontWeight.bold, fontSize: 13),
                            decoration: InputDecoration(
                              labelText: 'ESP32 Local IP (or 192.168.4.1 Setup)',
                              prefixIcon: const Icon(Icons.router_outlined, size: 18),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _isConnected ? const Color(0xFFEA4335) : const Color(0xFF1A73E8),
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                          ),
                          onPressed: _toggleConnection,
                          child: Text(_isConnected ? 'Stop' : 'Connect', style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Expanded(
                          child: Text(_status, style: TextStyle(fontSize: 11, color: secondaryText), overflow: TextOverflow.ellipsis),
                        ),
                        Row(
                          children: <Widget>[
                            _statusChip('InfluxDB', _isInfluxCloudConnected),
                            const SizedBox(width: 6),
                            _statusChip('HiveMQ', _isMqttCloudConnected),
                          ],
                        ),
                      ],
                    ),
                    const Divider(height: 18),
                    Row(
                      children: <Widget>[
                        const Icon(Icons.tune_rounded, size: 18),
                        const SizedBox(width: 6),
                        Text('Active DSP:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primaryText)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _selectedFilter,
                              isExpanded: true,
                              items: _filterOptions
                                  .map((String f) => DropdownMenuItem<String>(
                                        value: f,
                                        child: Text(f, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                      ))
                                  .toList(),
                              onChanged: (String? val) {
                                if (val != null) setState(() => _selectedFilter = val);
                              },
                            ),
                          ),
                        ),
                        Checkbox(
                          value: _overlayRawOnChart,
                          onChanged: (bool? v) => setState(() => _overlayRawOnChart = v ?? false),
                        ),
                        Text('Raw Overlay', style: TextStyle(fontSize: 11, color: secondaryText)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _filterOptions.map((String fName) {
                          final double sigma = _calcFilterStdDev(fName);
                          final double val = (_latestRecord?.getMvByFilter(fName) ?? 0.0).clamp(0.0, 1250.0);
                          final bool isSelected = _selectedFilter == fName;
                          return Container(
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF1A73E8).withOpacity(0.12)
                                  : (isDark ? const Color(0xFF15171E) : const Color(0xFFF3F4F6)),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected ? const Color(0xFF1A73E8) : subtleBorder,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(fName, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: primaryText)),
                                Text('${val.toStringAsFixed(1)} mV  (σ=${sigma.toStringAsFixed(2)})', style: TextStyle(fontSize: 11, color: secondaryText)),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ================= 7. PERIOD FILTER & 24-HOUR RANKING =================
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: subtleBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Historical Period Filter & 24-Hour Peak Ranking', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: primaryText)),
                    const SizedBox(height: 8),
                    Row(
                      children: <String>['Date', 'Week', 'Month', 'Year'].map((String mode) {
                        final bool selected = _periodMode == mode;
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2.0),
                            child: ChoiceChip(
                              label: SizedBox(
                                width: double.infinity,
                                child: Text(mode, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              ),
                              selected: selected,
                              onSelected: (bool _) => setState(() => _periodMode = mode),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        _buildDropdownChip<int>(
                          label: 'Year',
                          value: _selectedYear,
                          items: yearOptions.map((int y) => DropdownMenuItem<int>(value: y, child: Text('$y'))).toList(),
                          onChanged: (int? val) => setState(() => _selectedYear = val ?? currentYear),
                          subtleBorder: subtleBorder,
                        ),
                        if (_periodMode != 'Year')
                          _buildDropdownChip<int>(
                            label: 'Month',
                            value: _selectedMonth,
                            items: List<DropdownMenuItem<int>>.generate(12, (int i) => DropdownMenuItem<int>(value: i + 1, child: Text(_monthNames[i]))),
                            onChanged: (int? val) => setState(() => _selectedMonth = val ?? 1),
                            subtleBorder: subtleBorder,
                          ),
                        if (_periodMode == 'Week')
                          _buildDropdownChip<int>(
                            label: 'Week',
                            value: _selectedWeek,
                            items: List<DropdownMenuItem<int>>.generate(5, (int i) => DropdownMenuItem<int>(value: i + 1, child: Text('Week ${i + 1}'))),
                            onChanged: (int? val) => setState(() => _selectedWeek = val ?? 1),
                            subtleBorder: subtleBorder,
                          ),
                        if (_periodMode == 'Date')
                          _buildDropdownChip<int>(
                            label: 'Date',
                            value: _selectedDay,
                            items: List<DropdownMenuItem<int>>.generate(maxDays, (int i) => DropdownMenuItem<int>(value: i + 1, child: Text('${i + 1} ${_monthNames[_selectedMonth - 1]}'))),
                            onChanged: (int? val) => setState(() => _selectedDay = val ?? 1),
                            subtleBorder: subtleBorder,
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 190,
                      child: ListView.builder(
                        itemCount: hourlyRanked.length,
                        itemBuilder: (BuildContext ctx, int idx) {
                          final HourlyBucketStat hr = hourlyRanked[idx];
                          final bool isTop = idx == 0 && hr.peakUvi > 0;
                          return Container(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: isTop
                                  ? const Color(0xFFE84393).withOpacity(0.12)
                                  : (isDark ? const Color(0xFF15171E) : const Color(0xFFF9FAFB)),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isTop ? const Color(0xFFE84393) : subtleBorder,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: <Widget>[
                                Text(
                                  isTop ? '★ #1 Peak Hour (${hr.timeSlot})' : '#${idx + 1}  ${hr.timeSlot}',
                                  style: TextStyle(fontSize: 12, fontWeight: isTop ? FontWeight.w800 : FontWeight.w600, color: primaryText),
                                ),
                                Text(
                                  'UVI ${hr.peakUvi.toStringAsFixed(2)}  •  ${hr.avgMv.toStringAsFixed(1)} mV',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _getRiskColor(hr.peakUvi)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // ================= 8. TELEMETRY DATA TABLE & FULL EXPORTS =================
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: subtleBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Text('Telemetry Data Log', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: primaryText)),
                        DropdownButton<String>(
                          value: _timeGranularity,
                          items: <String>['Seconds', 'Minutes', 'Hours', 'Day']
                              .map((String unit) => DropdownMenuItem<String>(
                                    value: unit,
                                    child: Text(unit, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                  ))
                              .toList(),
                          onChanged: (String? v) {
                            if (v != null) setState(() => _timeGranularity = v);
                          },
                        ),
                      ],
                    ),
                    SizedBox(
                      height: 190,
                      width: double.infinity,
                      child: granularRows.isEmpty
                          ? Center(child: Text('No records for this period yet.', style: TextStyle(color: secondaryText, fontSize: 12)))
                          : SingleChildScrollView(
                              child: DataTable(
                                columnSpacing: 16,
                                columns: const <DataColumn>[
                                  DataColumn(label: Text('Time')),
                                  DataColumn(label: Text('UV Index')),
                                  DataColumn(label: Text('Voltage')),
                                ],
                                rows: granularRows.map((GranularTelemetryRow row) {
                                  return DataRow(cells: <DataCell>[
                                    DataCell(Text(row.time, style: const TextStyle(fontSize: 11))),
                                    DataCell(Text(row.uvData, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                                    DataCell(Text(row.voltage, style: const TextStyle(fontSize: 11))),
                                  ]);
                                }).toList(),
                              ),
                            ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _downloadFullGraphDataCsv,
                            icon: const Icon(Icons.timeline_rounded, size: 18),
                            label: const Text('Full Graph Data CSV', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: _download3FilterComparisonCsv,
                            icon: const Icon(Icons.analytics_outlined, size: 18),
                            label: const Text('3-Filter Dataset CSV', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _exportFullCanvasGraphPng,
                        icon: const Icon(Icons.panorama_outlined, size: 18),
                        label: const Text('Export Full Unclipped WHO Gradient Graph (High-Res PNG)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  HorizontalLine _whoBandLabelLine(double yVal, String label, bool isDark) {
    return HorizontalLine(
      y: yVal,
      color: isDark ? Colors.white.withOpacity(0.14) : Colors.black.withOpacity(0.12),
      strokeWidth: 1,
      label: HorizontalLineLabel(
        show: true,
        alignment: Alignment.topLeft,
        padding: const EdgeInsets.only(left: 4, bottom: 2),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white60 : Colors.black54,
        ),
        labelResolver: (HorizontalLine _) => label,
      ),
    );
  }

  Widget _insightBullet({
    required String title,
    required String body,
    required Color primaryText,
    required Color secondaryText,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 6.0, right: 10.0),
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: primaryText, shape: BoxShape.circle),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: primaryText)),
              const SizedBox(height: 2),
              Text(body, style: TextStyle(fontSize: 12, height: 1.35, color: secondaryText)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusChip(String name, bool online) {
    final Color c = online ? const Color(0xFF2ECC71) : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$name: ${online ? "ONLINE" : "Wait"}',
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: c),
      ),
    );
  }

  Widget _buildDropdownChip<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    required Color subtleBorder,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: subtleBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('$label: ', style: const TextStyle(fontSize: 11)),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1A73E8)),
              items: items,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}