// lib/beacon_locator.dart
// Medyan filtresi + IMU Lock + Histerezis + Oda bazlı tespit

import 'dart:math';

// ─── Beacon tanımları ────────────────────────────────────────────────
class BeaconConfig {
  final String name;
  final int minor;
  final double x, y, z;

  const BeaconConfig({
    required this.name,
    required this.minor,
    required this.x,
    required this.y,
    required this.z,
  });
}

const List<BeaconConfig> kBeacons = [
  BeaconConfig(name: 'Beacon 4', minor: 4, x: 3.90, y: 0.00, z: 1.80),
  BeaconConfig(name: 'Beacon 3', minor: 3, x: 0.00, y: 0.00, z: 1.80),
  BeaconConfig(name: 'Beacon 1', minor: 1, x: 1.95, y: 4.40, z: 1.80),
];

const String kBeaconUUID = '74739aec-f840-2aa9-144c-96df5baded8a';

// ─── Oda tanımları ───────────────────────────────────────────────────
class RoomConfig {
  final String name;
  final double x, y, w, h;
  final int color;

  const RoomConfig({
    required this.name,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.color,
  });

  bool contains(double px, double py) {
    return px >= x && px <= x + w && py >= y && py <= y + h;
  }
}

const double _gap = 0.60;
const double _roomW = (3.90 - _gap) / 2;
const double _roomH = (4.40 - _gap) / 2;
const double _startX = 0.0;

const List<RoomConfig> kRooms = [
  RoomConfig(name: 'Acil Servis', x: _startX,             y: 0.0,         w: _roomW, h: _roomH, color: 0xFFFFEBEE),
  RoomConfig(name: 'Kardiyoloji', x: _startX+_roomW+_gap,  y: 0.0,         w: _roomW, h: _roomH, color: 0xFFE3F2FD),
  RoomConfig(name: 'Radyoloji',   x: _startX,             y: _roomH+_gap, w: _roomW, h: _roomH, color: 0xFFE8F5E9),
  RoomConfig(name: 'Bekleme',     x: _startX+_roomW+_gap,  y: _roomH+_gap, w: _roomW, h: _roomH, color: 0xFFFFF3E0),
];

String getRoomName(double x, double y) {
  for (final room in kRooms) {
    if (room.contains(x, y)) return room.name;
  }
  return 'Koridor';
}

// ─── Medyan Filtresi ─────────────────────────────────────────────────
class MedianFilter {
  final int windowSize;
  final List<double> _buffer = [];

 MedianFilter({this.windowSize = 3});

  double add(double value) {
    _buffer.add(value);
    if (_buffer.length > windowSize) _buffer.removeAt(0);
    final sorted = List<double>.from(_buffer)..sort();
    return sorted[sorted.length ~/ 2];
  }

  void reset() => _buffer.clear();
}

// ─── Kalman Filtresi ─────────────────────────────────────────────────
class KalmanFilter {
  double _estimate;
  double _errorCov;
  final double processNoise;
  final double measurementNoise;

  KalmanFilter({
    double initialEstimate = -65.0,
    double initialError = 1.0,
    this.processNoise = 0.003,
    this.measurementNoise = 12.0,
  })  : _estimate = initialEstimate,
        _errorCov = initialError;

  double filter(double measurement) {
    final predictedError = _errorCov + processNoise;
    final gain = predictedError / (predictedError + measurementNoise);
    _estimate = _estimate + gain * (measurement - _estimate);
    _errorCov = (1 - gain) * predictedError;
    return _estimate;
  }

  void reset() {
    _estimate = -65.0;
    _errorCov = 1.0;
  }
}

// ─── Beacon State ────────────────────────────────────────────────────
class BeaconState {
  final BeaconConfig config;
  final KalmanFilter _kalman = KalmanFilter();
  final MedianFilter _median = MedianFilter(windowSize: 7);

  double? rawRssi;
  double? filteredRssi;
  double? distance;
  DateTime? lastSeen;

  BeaconState(this.config);

  void updateRssi(double rssi) {
    rawRssi = rssi;
    lastSeen = DateTime.now();
    final medianFiltered = _median.add(rssi);
    filteredRssi = _kalman.filter(medianFiltered);
    distance = rssiToDistance(filteredRssi!);
  }

  bool get isStale =>
      lastSeen == null ||
      DateTime.now().difference(lastSeen!).inSeconds > 5;

double rssiToDistance(double rssi) {
    final txPower = config.minor == 1 ? -55.0 :
                    config.minor == 3 ? -55.0 :
                    -60;
    const n = 3.2;
    final d3d = pow(10.0, (txPower - rssi) / (10.0 * n)).toDouble();
    const phoneHeight = 0.9;
    final dz = (config.z - phoneHeight).abs();
    final dHorizontal = sqrt(max(0, d3d * d3d - dz * dz));
    return dHorizontal.clamp(0.1, 30.0);
  }
}

// ─── Histerezis + IMU Lock Konum Yöneticisi ──────────────────────────
class PositionManager {
  double? _lockedX, _lockedY;
  String _currentRoom = '';
  bool _isMoving = false;

  // Histerezis: oda değişmesi için minimum fark (metre)
  static const double roomChangeThreshold = 1.5;

  // IMU Lock: hareket etmiyorsa konumu dondur
  void setMoving(bool moving) {
    _isMoving = moving;
  }

(double, double)? update(List<BeaconState> states) {
  final active = states
      .where((s) => !s.isStale && s.distance != null)
      .toList();

  if (active.isEmpty) return null;

  double sumW = 0, sumWx = 0, sumWy = 0;
  for (final s in active) {
    final w = 1.0 / (s.distance! * s.distance! + 0.1);
    sumW += w;
    sumWx += w * s.config.x;
    sumWy += w * s.config.y;
  }

  final rawX = (sumWx / sumW).clamp(-0.3, 3.2);
  final rawY = (sumWy / sumW).clamp(-0.3, 5.0);
  _currentRoom = getRoomName(rawX, rawY);
  _lockedX = rawX;
  _lockedY = rawY;

  return (rawX, rawY);
}

  String get currentRoom => _currentRoom;
}