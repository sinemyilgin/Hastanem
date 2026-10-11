// lib/main.dart
// Hastanem — BLE + IMU + Hedef Seçme + Oda Navigasyon

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'beacon_locator.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  runApp(const HospNavApp());
}

class HospNavApp extends StatelessWidget {
  const HospNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hastanem',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const NavHomePage(),
    );
  }
}

class NavHomePage extends StatefulWidget {
  const NavHomePage({super.key});

  @override
  State<NavHomePage> createState() => _NavHomePageState();
}

class _NavHomePageState extends State<NavHomePage> {
  final Map<int, BeaconState> _beaconStates = {
    for (final b in kBeacons) b.minor: BeaconState(b),
  };

  final PositionManager _posManager = PositionManager();
  final FlutterTts _tts = FlutterTts();

  StreamSubscription? _scanSub;
  StreamSubscription? _accelSub;

  bool _isScanning = false;
  double? _posX, _posY;
  String _currentRoom = '';
  String? _targetRoom; // Seçilen hedef oda
  String _statusMsg = 'Başlamak için butona bas';

  static const double _moveThreshold = 11.5;
  static const int _moveCooldown = 800;
  DateTime _lastMoveTime = DateTime.now();
  bool _isMoving = false;

  Future<void> _startScanning() async {
    await _tts.setLanguage('tr-TR');
    await _tts.setSpeechRate(0.5);
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    final allGranted = statuses.values.every(
      (s) => s == PermissionStatus.granted,
    );
    if (!allGranted) {
      setState(() => _statusMsg = 'İzinler gerekli!');
      return;
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      setState(() => _statusMsg = 'Bluetooth kapalı!');
      return;
    }

    setState(() {
      _isScanning = true;
      _statusMsg = 'Taranıyor...';
    });

    await FlutterBluePlus.startScan(
      withServices: [],
      continuousUpdates: true,
      removeIfGone: const Duration(seconds: 5),
      androidScanMode: AndroidScanMode.lowLatency,
    );
    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResult);

    _accelSub = accelerometerEventStream().listen((event) {
      final mag = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      final now = DateTime.now();
      final wasMoving = _isMoving;

      if (mag > _moveThreshold) {
        _lastMoveTime = now;
        _isMoving = true;
      } else if (now.difference(_lastMoveTime).inMilliseconds > _moveCooldown) {
        _isMoving = false;
      }

      if (wasMoving != _isMoving) {
        _posManager.setMoving(_isMoving);
        setState(() {});
      }
    });
  }

  void _stopScanning() {
    FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    _accelSub?.cancel();
    setState(() {
      _isScanning = false;
      _statusMsg = 'Durduruldu';
    });
  }

  void _onScanResult(List<ScanResult> results) {
    for (final result in results) {
      _processBeacon(result);
    }
    _updatePosition();
  }

  void _processBeacon(ScanResult result) {
    final mfData = result.advertisementData.manufacturerData;
    if (mfData.isEmpty) return;
    final appleData = mfData[0x004C] ?? mfData[0x4C00];
    if (appleData == null || appleData.length < 23) return;
    if (appleData[0] != 0x02 || appleData[1] != 0x15) return;
    final minor = (appleData[20] << 8) | appleData[21];
    if (!_beaconStates.containsKey(minor)) return;
    setState(() {
      _beaconStates[minor]!.updateRssi(result.rssi.toDouble());
    });
  }

 void _updatePosition() {
    final pos = _posManager.update(_beaconStates.values.toList());
    if (pos != null) {
      setState(() {
        _posX = pos.$1;
        _posY = pos.$2;
        _currentRoom = _posManager.currentRoom;

        if (_targetRoom != null && _currentRoom == _targetRoom) {
          if (_statusMsg != '✅ Hedefe ulaştınız!') {
            _tts.speak('Hedefe ulaştınız! $_targetRoom bölümündesiniz.');
          }
          _statusMsg = '✅ Hedefe ulaştınız!';
        } else if (_targetRoom != null) {
          _statusMsg = '🧭 $_targetRoom\'e yönleniyorsunuz';
        } else {
          _statusMsg = _isMoving ? '🚶 Hareket ediliyor' : '📍 Durdu';
        }
      });
    }
  }


  // Hedef oda seçme dialog
  void _showTargetDialog() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Nereye gitmek istiyorsunuz?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ...kRooms.map((room) => ListTile(
                leading: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Color(room.color),
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                title: Text(room.name),
                trailing: _targetRoom == room.name
                    ? const Icon(Icons.check, color: Colors.blue)
                    : null,
                onTap: () {
                  setState(() {
                  _targetRoom = room.name;
                      });
                  _tts.speak('Hedef seçildi. ${room.name} bölümüne gidiyorsunuz.');
                    Navigator.pop(context);
                  },
              )),
              ListTile(
                leading: const Icon(Icons.close, color: Colors.red),
                title: const Text('Hedefi iptal et'),
                onTap: () {
                  setState(() {
                    _targetRoom = null;
                    _statusMsg = 'Hedef iptal edildi';
                  });
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _stopScanning();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final arrivedAtTarget =
        _targetRoom != null && _currentRoom == _targetRoom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hastanem'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
          // Hedef seçme butonu
          IconButton(
            icon: Icon(
              _targetRoom != null ? Icons.flag : Icons.flag_outlined,
              color: _targetRoom != null ? Colors.blue : null,
            ),
            tooltip: 'Hedef seç',
            onPressed: _showTargetDialog,
          ),
          IconButton(
            icon: Icon(_isScanning ? Icons.stop : Icons.play_arrow),
            onPressed: _isScanning ? _stopScanning : _startScanning,
          ),
        ],
      ),
      body: Column(
        children: [
          // Oda ismi + hedef banner
          if (_currentRoom.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: arrivedAtTarget
                  ? Colors.green.shade600
                  : const Color(0xFF1565C0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        arrivedAtTarget
                            ? Icons.check_circle
                            : Icons.location_on,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Şu an: $_currentRoom',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _isMoving ? Colors.green : Colors.orange,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          _isMoving ? '🚶 Hareket' : '⏸ Durdu',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  if (_targetRoom != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.flag, color: Colors.white70, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          arrivedAtTarget
                              ? '✅ $_targetRoom\'e ulaştınız!'
                              : '🧭 Hedef: $_targetRoom',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

          // Durum bandı
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            color: _isScanning
                ? Colors.green.shade50
                : Theme.of(context).colorScheme.surfaceVariant,
            child: Row(
              children: [
                if (_isScanning)
                  const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (_isScanning) const SizedBox(width: 8),
                Expanded(
                  child: Text(_statusMsg,
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),

          // Harita
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Oda haritası',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(width: 8),
                      if (_targetRoom != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade100,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '🎯 $_targetRoom',
                            style: TextStyle(
                                fontSize: 11, color: Colors.blue.shade700),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: GestureDetector(
                      onTapUp: (details) {
                        // Haritaya tıklayınca da hedef seçilebilir
                        _showTargetDialog();
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: CustomPaint(
                            painter: RoomPainter(
                              beaconStates: _beaconStates,
                              posX: _posX,
                              posY: _posY,
                              currentRoom: _currentRoom,
                              targetRoom: _targetRoom,
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Beacon listesi
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Beacon sinyalleri',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  ..._beaconStates.values
                      .map((state) => _BeaconTile(state: state)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Harita Painter ───────────────────────────────────────────────────
class RoomPainter extends CustomPainter {
  final Map<int, BeaconState> beaconStates;
  final double? posX, posY;
  final String currentRoom;
  final String? targetRoom;

static const double roomMinX = -0.3;
static const double roomMaxX = 4.5;
static const double roomMinY = -0.3;
static const double roomMaxY = 5.0;

  RoomPainter({
    required this.beaconStates,
    required this.posX,
    required this.posY,
    required this.currentRoom,
    required this.targetRoom,
  });

  Offset toScreen(double x, double y, Size size) {
    final px = (x - roomMinX) / (roomMaxX - roomMinX) * size.width;
    final py = (1 - (y - roomMinY) / (roomMaxY - roomMinY)) * size.height;
    return Offset(px, py);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.white,
    );

    for (final room in kRooms) {
      final topLeft = toScreen(room.x, room.y + room.h, size);
      final bottomRight = toScreen(room.x + room.w, room.y, size);
      final rect = Rect.fromPoints(topLeft, bottomRight);

      final isCurrent = room.name == currentRoom;
      final isTarget = room.name == targetRoom;

      // Hedef oda hafif vurgulu
      canvas.drawRect(
        rect,
        Paint()
          ..color = isTarget
              ? Colors.blue.shade50
              : Color(room.color),
      );

      canvas.drawRect(
        rect,
        Paint()
          ..color = isCurrent
              ? const Color(0xFF1565C0)
              : isTarget
                  ? Colors.blue.shade300
                  : Colors.grey.shade300
          ..style = PaintingStyle.stroke
          ..strokeWidth = isCurrent || isTarget ? 2.5 : 1,
      );

      final center = Offset(
        (topLeft.dx + bottomRight.dx) / 2,
        (topLeft.dy + bottomRight.dy) / 2,
      );

      // Hedef odaya bayrak emoji ekle
      final label = isTarget ? '🎯 ${room.name}' : room.name;

      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: isCurrent
                ? const Color(0xFF1565C0)
                : isTarget
                    ? Colors.blue.shade700
                    : Colors.grey.shade700,
            fontSize: isCurrent || isTarget ? 11 : 10,
            fontWeight: isCurrent || isTarget
                ? FontWeight.bold
                : FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width - 8);
      tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
    }

    // Beacon'lar
    final colors = [Colors.blue, Colors.orange, Colors.purple];
    int ci = 0;
    for (final state in beaconStates.values) {
      final pos = toScreen(state.config.x, state.config.y, size);
      final color = colors[ci % colors.length];
      ci++;

      if (state.distance != null && !state.isStale) {
        final r = state.distance! / (roomMaxX - roomMinX) * size.width;
        canvas.drawCircle(pos, r, Paint()..color = color.withOpacity(0.05));
        canvas.drawCircle(
            pos,
            r,
            Paint()
              ..color = color.withOpacity(0.18)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1);
      }

      canvas.drawCircle(
          pos, 9, Paint()..color = state.isStale ? Colors.grey : color);

      final tp = TextPainter(
        text: TextSpan(
          text: state.config.name,
          style: TextStyle(
              color: state.isStale ? Colors.grey : color,
              fontSize: 8,
              fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos + const Offset(11, -4));

      if (state.distance != null) {
        final dp = TextPainter(
          text: TextSpan(
            text: '${state.distance!.toStringAsFixed(1)}m',
            style: const TextStyle(color: Colors.grey, fontSize: 8),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        dp.paint(canvas, pos + const Offset(11, 5));
      }
    }

    // Kullanıcı konumu
    if (posX != null && posY != null) {
      final userPos = toScreen(posX!, posY!, size);

      // Hedefe ok çiz
      if (targetRoom != null) {
        final targetRoomConfig =
            kRooms.firstWhere((r) => r.name == targetRoom, orElse: () => kRooms[0]);
        final targetCenter = toScreen(
          targetRoomConfig.x + targetRoomConfig.w / 2,
          targetRoomConfig.y + targetRoomConfig.h / 2,
          size,
        );

        if (currentRoom != targetRoom) {
          // Ok çiz
          final paint = Paint()
            ..color = Colors.blue.shade400
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke;

          // Kesik çizgi
          const dashLen = 8.0;
          const gapLen = 5.0;
          final dx = targetCenter.dx - userPos.dx;
          final dy = targetCenter.dy - userPos.dy;
          final dist = sqrt(dx * dx + dy * dy);
          final ux = dx / dist;
          final uy = dy / dist;
          double traveled = 12.0;
          while (traveled < dist - 12) {
            final start = Offset(
                userPos.dx + ux * traveled, userPos.dy + uy * traveled);
            final end = Offset(
                userPos.dx + ux * (traveled + dashLen),
                userPos.dy + uy * (traveled + dashLen));
            canvas.drawLine(start, end, paint);
            traveled += dashLen + gapLen;
          }

          // Ok ucu
          canvas.drawCircle(
              targetCenter, 6, Paint()..color = Colors.blue.shade300);
        }
      }

      // Kullanıcı noktası
      canvas.drawCircle(
          userPos, 20, Paint()..color = Colors.red.withOpacity(0.15));
      canvas.drawCircle(userPos, 8, Paint()..color = Colors.red);
      canvas.drawCircle(
          userPos,
          8,
          Paint()
            ..color = Colors.white
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke);

      final lp = TextPainter(
        text: TextSpan(
          text: '(${posX!.toStringAsFixed(1)}, ${posY!.toStringAsFixed(1)})',
          style: const TextStyle(
              color: Colors.red, fontSize: 8, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      lp.paint(canvas, userPos + const Offset(11, -4));
    }
  }

  @override
  bool shouldRepaint(RoomPainter old) => true;
}

// ─── Beacon Tile ──────────────────────────────────────────────────────
class _BeaconTile extends StatelessWidget {
  final BeaconState state;
  const _BeaconTile({required this.state});

  @override
  Widget build(BuildContext context) {
    final isActive = !state.isStale;
    final rssi = state.filteredRssi;
    final dist = state.distance;
    final bar = rssi != null ? ((rssi + 90) / 50).clamp(0.0, 1.0) : 0.0;

    return Card(
      margin: const EdgeInsets.only(bottom: 5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive ? Colors.green : Colors.grey,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 76,
              child: Text(state.config.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: bar,
                      minHeight: 5,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation(
                          isActive ? Colors.blue : Colors.grey),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    rssi != null
                        ? '${rssi.toStringAsFixed(1)} dBm'
                        : 'Sinyal yok',
                    style: const TextStyle(fontSize: 9, color: Colors.grey),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                dist != null ? '${dist.toStringAsFixed(1)}m' : '--',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: isActive ? Colors.blue.shade700 : Colors.grey,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}