import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ─────────────────────────────────────────────────────────────────────────────
// KONSTANTA LANTAI
// ─────────────────────────────────────────────────────────────────────────────

const List<String> namaLantai = [
  'G', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11',
];

const List<Map<String, double>> rangeAltitudeLantai = [
  {'min': 36.0, 'max': 38.0}, // G
  {'min': 38.0, 'max': 45.0}, // 1
  {'min': 45.0, 'max': 50.0}, // 2
  {'min': 50.0, 'max': 55.0}, // 3
  {'min': 55.0, 'max': 62.0}, // 4
];

int altitudeKeLantai(double altitude) {
  for (int i = 0; i < rangeAltitudeLantai.length; i++) {
    final min = rangeAltitudeLantai[i]['min']!;
    final max = rangeAltitudeLantai[i]['max']!;
    if (altitude >= min && altitude < max) return i;
  }
  if (altitude < rangeAltitudeLantai.first['min']!) return 0;
  return rangeAltitudeLantai.length - 1;
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKGROUND ISOLATE — onStart dipanggil sistem saat service start
// PENTING: FlutterLocalNotificationsPlugin TIDAK BOLEH dipakai di sini
// ─────────────────────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Init Firebase di background isolate
  await Firebase.initializeApp();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((_) {
      service.setAsBackgroundService();
    });
  }

  String namaPlayer = '';
  String tipeDevice = '';
  Timer? timer;
  DatabaseReference? ref;

  // Terima perintah START dari UI
  service.on('start').listen((data) async {
    if (data == null) return;
    namaPlayer = data['namaPlayer'] ?? '';
    tipeDevice = data['tipeDevice'] ?? '';
    ref = FirebaseDatabase.instance.ref('players/$namaPlayer');
    await ref!.onDisconnect().remove();

    // Update teks notifikasi foreground
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'MR Quiz Tracker',
        content: '$namaPlayer sedang mengirim lokasi...',
      );
    }

    // Kirim posisi pertama langsung
    await _kirimPosisi(service, ref!, namaPlayer, tipeDevice);

    // Timer 500ms
    timer?.cancel();
    timer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      await _kirimPosisi(service, ref!, namaPlayer, tipeDevice);
    });
  });

  // Terima perintah STOP dari UI
  service.on('stop').listen((_) async {
    timer?.cancel();
    timer = null;
    if (ref != null) {
      await ref!.onDisconnect().cancel();
      await ref!.remove();
      ref = null;
    }
    service.stopSelf();
  });
}

// Fungsi kirim posisi GPS ke Firebase — jalan di background isolate
Future<void> _kirimPosisi(
  ServiceInstance service,
  DatabaseReference ref,
  String namaPlayer,
  String tipeDevice,
) async {
  try {
    final posisi = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.bestForNavigation,
    );

    final lantaiBaru = altitudeKeLantai(posisi.altitude);
    final waktuKirim = DateTime.now().millisecondsSinceEpoch;

    await ref.set({
      'lat': posisi.latitude,
      'lng': posisi.longitude,
      'waktu': waktuKirim,
      'nama': namaPlayer,
      'tipe': tipeDevice,
      'lantai': lantaiBaru,
      'lantai_nama': namaLantai[lantaiBaru],
      'altitude_gps': posisi.altitude,
      'ping': 0,
    });

    final ping = DateTime.now().millisecondsSinceEpoch - waktuKirim;

    // Kirim data ke UI lewat event
    service.invoke('update', {
      'lat': posisi.latitude,
      'lng': posisi.longitude,
      'altitude': posisi.altitude,
      'lantai': lantaiBaru,
      'ping': ping,
    });
  } catch (e) {
    debugPrint('Background: Gagal kirim posisi: $e');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// INISIALISASI SERVICE — hanya dipanggil di main isolate
// ─────────────────────────────────────────────────────────────────────────────

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  // Buat notification channel di main isolate (WAJIB sebelum service start)
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'mr_quiz_tracker_channel',
    'MR Quiz Tracker',
    description: 'Notifikasi tracking lokasi aktif',
    importance: Importance.low,
    playSound: false,
  );

  final FlutterLocalNotificationsPlugin notifPlugin =
      FlutterLocalNotificationsPlugin();

  // Init plugin notifikasi
  await notifPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  // Daftarkan channel — ini HARUS di main isolate, bukan di onStart
  final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
      notifPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'mr_quiz_tracker_channel',
      initialNotificationTitle: 'MR Quiz Tracker',
      initialNotificationContent: 'Menunggu tracking dimulai...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await initializeService();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MR Quiz Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F8BEA)),
      ),
      home: const PilihPlayerScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PILIH PLAYER SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class PilihPlayerScreen extends StatefulWidget {
  const PilihPlayerScreen({super.key});
  @override
  State<PilihPlayerScreen> createState() => _PilihPlayerScreenState();
}

class _PilihPlayerScreenState extends State<PilihPlayerScreen> {
  int? playerDipilih;
  String? tipeDipilih;
  Set<int> playersAktif = {};
  StreamSubscription? _subscription;
  bool sedangLoading = false;

  @override
  void initState() {
    super.initState();
    _listenToActivePlayers();
  }

  void _listenToActivePlayers() {
    _subscription =
        FirebaseDatabase.instance.ref('players').onValue.listen((event) {
      final data = event.snapshot.value;
      final Set<int> active = {};
      if (data is Map) {
        data.forEach((key, value) {
          if (value != null) {
            final match = RegExp(r'^player(\d+)$').firstMatch(key.toString());
            if (match != null) {
              final num = int.tryParse(match.group(1) ?? '');
              if (num != null) active.add(num);
            }
          }
        });
      }
      if (mounted) {
        setState(() {
          playersAktif = active;
          if (playerDipilih != null && playersAktif.contains(playerDipilih)) {
            playerDipilih = null;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'MR Quiz Tracker',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF2F8BEA),
        foregroundColor: Colors.white,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Image.asset(
              'assets/images/Logo_MallAdventureFix.png',
              height: 40,
              fit: BoxFit.contain,
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pilih nomor player:',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(15, (i) {
                    final nomor = i + 1;
                    final dipilih = playerDipilih == nomor;
                    final isOccupied = playersAktif.contains(nomor);
                    return GestureDetector(
                      onTap: isOccupied
                          ? null
                          : () => setState(() => playerDipilih = nomor),
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: dipilih
                              ? const Color(0xFF2F8BEA)
                              : (isOccupied
                                  ? Colors.red[100]
                                  : Colors.grey[200]),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: dipilih
                                ? const Color(0xFF2F8BEA)
                                : (isOccupied ? Colors.red : Colors.grey),
                            width: isOccupied ? 1.5 : 1,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            'P$nomor',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: dipilih
                                  ? Colors.white
                                  : (isOccupied
                                      ? Colors.red[800]
                                      : Colors.black87),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 28),
                const Text(
                  'Bergabung sebagai:',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _tombolTipe(
                          'hololens', 'HoloLens', 'Lingkaran', Colors.blue),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _tombolTipe(
                          'mobile', 'Mobile', 'Segitiga', Colors.green),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: (playerDipilih != null &&
                            tipeDipilih != null &&
                            !sedangLoading)
                        ? _mulaiTracking
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2F8BEA),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Mulai Tracking',
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: TextButton.icon(
                    onPressed: sedangLoading ? null : _resetSemuaPlayer,
                    icon: const Icon(Icons.refresh, color: Colors.red),
                    label: const Text(
                      'Reset Semua Player',
                      style: TextStyle(
                          color: Colors.red, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (sedangLoading)
            Container(
              color: Colors.black.withOpacity(0.3),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Future<void> _resetSemuaPlayer() async {
    final konfirmasi = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset Semua Player?'),
        content:
            const Text('Ini akan menghapus semua status player di Firebase.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reset',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (konfirmasi != true) return;
    setState(() => sedangLoading = true);
    try {
      await FirebaseDatabase.instance.ref('players').remove();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Berhasil mereset semua player!'),
            backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Gagal mereset player: $e'),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => sedangLoading = false);
    }
  }

  Future<void> _mulaiTracking() async {
    final nomor = playerDipilih!;
    final tipe = tipeDipilih!;
    final ref = FirebaseDatabase.instance.ref('players/player$nomor');

    setState(() => sedangLoading = true);

    try {
      final result = await ref.runTransaction((currentData) {
        if (currentData != null) return Transaction.abort();
        return Transaction.success({
          'nama': 'player$nomor',
          'tipe': tipe,
          'status': 'reserved',
        });
      });

      if (mounted) setState(() => sedangLoading = false);

      if (result.committed) {
        await ref.onDisconnect().remove();
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => LokasiScreen(
                namaPlayer: 'player$nomor',
                tipeDevice: tipe,
              ),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Player ini baru saja diambil oleh HP lain!'),
              backgroundColor: Colors.red));
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => sedangLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Gagal memilih player: $e'),
            backgroundColor: Colors.red));
      }
    }
  }

  Widget _tombolTipe(
      String tipe, String label, String ikonLabel, Color warna) {
    final dipilih = tipeDipilih == tipe;
    return GestureDetector(
      onTap: () => setState(() => tipeDipilih = tipe),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: dipilih ? warna.withOpacity(0.15) : Colors.grey[100],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: dipilih ? warna : Colors.grey,
            width: dipilih ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            tipe == 'hololens'
                ? Image.asset('assets/images/MR_Icon.png',
                    width: 36, height: 36, fit: BoxFit.contain)
                : Image.asset('assets/images/Mobile_Icon.png',
                    width: 36, height: 36, fit: BoxFit.contain),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Ikon: $ikonLabel',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SEGITIGA PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class SegitigaPainter extends CustomPainter {
  final Color color;
  SegitigaPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// LOKASI SCREEN — UI listen event dari background service
// ─────────────────────────────────────────────────────────────────────────────

class LokasiScreen extends StatefulWidget {
  final String namaPlayer;
  final String tipeDevice;

  const LokasiScreen({
    super.key,
    required this.namaPlayer,
    required this.tipeDevice,
  });

  @override
  State<LokasiScreen> createState() => _LokasiScreenState();
}

class _LokasiScreenState extends State<LokasiScreen> {
  bool sedangKirim = false;
  int lantaiSekarang = 0;
  double altitudeGPS = 0;
  double latSekarang = 0;
  double lngSekarang = 0;
  int? pingMs;
  StreamSubscription? _updateSubscription;

  final _service = FlutterBackgroundService();

  @override
  void dispose() {
    _updateSubscription?.cancel();
    super.dispose();
  }

  // Listen update dari background isolate ke UI
  void _listenUpdate() {
    _updateSubscription = _service.on('update').listen((data) {
      if (data == null || !mounted) return;
      setState(() {
        latSekarang = (data['lat'] as num).toDouble();
        lngSekarang = (data['lng'] as num).toDouble();
        altitudeGPS = (data['altitude'] as num).toDouble();
        lantaiSekarang = data['lantai'] as int;
        pingMs = data['ping'] as int;
      });
    });
  }

  Future<bool> mintaIzinGPS() async {
  bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Aktifkan GPS di pengaturan HP!'),
          backgroundColor: Colors.red));
    }
    return false;
  }

  LocationPermission izin = await Geolocator.checkPermission();
  if (izin == LocationPermission.denied) {
    izin = await Geolocator.requestPermission();
  }
  if (izin == LocationPermission.deniedForever) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Izin lokasi ditolak permanen. Buka pengaturan HP.'),
          backgroundColor: Colors.red));
    }
    return false;
  }

  // Minta izin background ("Izinkan setiap saat") untuk tracking saat layar mati
  if (izin == LocationPermission.whileInUse) {
    izin = await Geolocator.requestPermission();
  }

  return izin == LocationPermission.always ||
      izin == LocationPermission.whileInUse;
}
  void mulaiKirimLokasi() async {
    bool boleh = await mintaIzinGPS();
    if (!boleh) return;

    // Start background service
    await _service.startService();

    // Beri jeda singkat agar service siap menerima event
    await Future.delayed(const Duration(milliseconds: 300));

    // Kirim perintah start dengan data player
    _service.invoke('start', {
      'namaPlayer': widget.namaPlayer,
      'tipeDevice': widget.tipeDevice,
    });

    setState(() => sedangKirim = true);
    _listenUpdate();
  }

  Future<void> keluarDanPutusKoneksi() async {
    final konfirmasi = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Keluar?',
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text(
          'Lokasi ${widget.namaPlayer.toUpperCase()} akan dihapus dari dashboard.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal',
                  style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))),
            child: const Text('Keluar'),
          ),
        ],
      ),
    );

    if (konfirmasi != true) return;

    // Kirim perintah stop ke background service
    _service.invoke('stop');
    _updateSubscription?.cancel();

    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const PilihPlayerScreen()),
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isHoloLens = widget.tipeDevice == 'hololens';
    final warna = isHoloLens ? Colors.blue : Colors.green;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.namaPlayer.toUpperCase()} · '
          '${isHoloLens ? "HoloLens" : "Mobile"}',
        ),
        backgroundColor: warna,
        foregroundColor: Colors.white,
        actions: sedangKirim
            ? [
                if (pingMs != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _pingColor(pingMs!).withOpacity(0.25),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: _pingColor(pingMs!).withOpacity(0.7)),
                        ),
                        child: Text(
                          '${pingMs}ms',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: _pingColor(pingMs!),
                              fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  ),
                IconButton(
                    onPressed: keluarDanPutusKoneksi,
                    icon: const Icon(Icons.logout),
                    tooltip: 'Keluar & Putus Koneksi'),
              ]
            : null,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: !sedangKirim
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    isHoloLens
                        ? Container(
                            width: 70,
                            height: 70,
                            decoration: const BoxDecoration(
                                shape: BoxShape.circle, color: Colors.blue))
                        : CustomPaint(
                            size: const Size(70, 70),
                            painter: SegitigaPainter(color: Colors.green)),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: mulaiKirimLokasi,
                        style: ElevatedButton.styleFrom(
                            backgroundColor: warna,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        child: const Text('Mulai Kirim Lokasi',
                            style: TextStyle(fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              )
            : Column(
                children: [
                  isHoloLens
                      ? Container(
                          width: 50,
                          height: 50,
                          decoration: const BoxDecoration(
                              shape: BoxShape.circle, color: Colors.blue))
                      : CustomPaint(
                          size: const Size(50, 50),
                          painter: SegitigaPainter(color: Colors.green)),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    decoration: BoxDecoration(
                      color: Colors.orange[50],
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.orange, width: 2),
                    ),
                    child: Column(
                      children: [
                        const Text('🏢 LANTAI',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.orange,
                                letterSpacing: 3)),
                        Text(
                          namaLantai[lantaiSekarang],
                          style: const TextStyle(
                              fontSize: 96,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange,
                              height: 1),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        _infoRow('Latitude', latSekarang.toStringAsFixed(6)),
                        const Divider(height: 16),
                        _infoRow(
                            'Longitude', lngSekarang.toStringAsFixed(6)),
                        const Divider(height: 16),
                        _infoRow('Altitude GPS',
                            '${altitudeGPS.toStringAsFixed(1)} m'),
                        const Divider(height: 16),
                        _infoRow(
                            'Ping', pingMs != null ? '$pingMs ms' : '–'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (pingMs != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 16),
                      decoration: BoxDecoration(
                        color: _pingColor(pingMs!).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _pingColor(pingMs!)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.network_ping,
                              color: _pingColor(pingMs!), size: 16),
                          const SizedBox(width: 8),
                          Text(
                            'Ping ke Firebase: $pingMs ms  ${_pingLabel(pingMs!)}',
                            style: TextStyle(
                                color: _pingColor(pingMs!),
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: warna.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: warna),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.circle, color: warna, size: 10),
                        const SizedBox(width: 8),
                        Text('Lokasi sedang dikirim ke dashboard',
                            style: TextStyle(color: warna, fontSize: 13)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: keluarDanPutusKoneksi,
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Keluar & Putus Koneksi'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12))),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Color _pingColor(int ms) {
    if (ms < 300) return Colors.green;
    if (ms < 800) return Colors.orange;
    return Colors.red;
  }

  String _pingLabel(int ms) {
    if (ms < 300) return '🟢 Bagus';
    if (ms < 800) return '🟡 Sedang';
    return '🔴 Lambat';
  }

  Widget _infoRow(String label, String nilai) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 13, color: Colors.grey)),
        Text(nilai,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace')),
      ],
    );
  }
}