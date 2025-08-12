// lib/main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'features/posture/services/pose_webrtc_service.dart';
import 'features/posture/presentation/widgets/overlays.dart' show PoseFrame; // typing only
import 'features/posture/presentation/widgets/rtc_pose_overlay.dart'
    show PoseOverlayFast; // use the low-latency overlay

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Optional: immersive full-screen
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  final offerUrl = const String.fromEnvironment(
    'POSE_WEBRTC_URL',
    defaultValue: 'http://192.168.100.5:8000/webrtc/offer',
  );

  final poseService = PoseWebRTCService(
    offerUri: Uri.parse(offerUrl),
    facingMode: 'user', // or 'environment'
    idealWidth: 640,
    idealHeight: 480,
    idealFps: 15,
  );

  await poseService.init();
  unawaited(poseService.connect());

  runApp(PoseApp(poseService: poseService));
}

class PoseApp extends StatefulWidget {
  const PoseApp({super.key, required this.poseService});
  final PoseWebRTCService poseService;

  @override
  State<PoseApp> createState() => _PoseAppState();
}

class _PoseAppState extends State<PoseApp> {
  // Assume front camera first (mirrored UI)
  bool _mirror = true;

  // ── Log UI state ───────────────────────────────────────────
  bool _showLogArea = true;
  final _logScrollCtrl = ScrollController();
  String _uiLog = 'Hello world\n';

  void appendLog(String msg) {
    setState(() => _uiLog += '$msg\n');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollCtrl.hasClients) {
        _logScrollCtrl.jumpTo(_logScrollCtrl.position.maxScrollExtent);
      }
    });
  }
  // ───────────────────────────────────────────────────────────

  @override
  void dispose() {
    widget.poseService.close();
    _logScrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.poseService;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Pose WebRTC Demo'),
          actions: [
            IconButton(
              icon: const Icon(Icons.cameraswitch),
              tooltip: 'Switch camera',
              onPressed: () async {
                await svc.switchCamera();
                setState(() => _mirror = !_mirror); // toggle mirror hint
              },
            ),
            IconButton(
              icon: Icon(_showLogArea ? Icons.notes : Icons.notes_outlined),
              tooltip: _showLogArea ? 'Hide log' : 'Show log',
              onPressed: () => setState(() => _showLogArea = !_showLogArea),
            ),
          ],
        ),
        body: Stack(
          children: [
            // 1) FULL-SCREEN LOCAL CAMERA (always visible)
            Positioned.fill(
              child: RTCVideoView(
                svc.localRenderer,
                mirror: _mirror, // front cam => true
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover, // fill screen
              ),
            ),

            // 2) Landmarks overlay — SAME BOX & FIT as the full-screen preview
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary( // <-- add this
                  child: PoseOverlayFast(
                    latest: svc.latestFrame, // ValueNotifier<PoseFrame?>
                    mirror: _mirror,         // must match the preview
                    fit: BoxFit.cover,       // must match objectFit above
                  ),
                ),
              ),
            ),

            // 3) Remote stream as PiP (may appear once server adds a video track)
            Positioned(
              left: 12,
              top: 12,
              width: 144,
              height: 192,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: RTCVideoView(
                  svc.remoteRenderer,
                  mirror: _mirror,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),

            // 4) Simple log/console area (blank space to print any log)
            if (_showLogArea)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 120,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.black54,
                  child: SingleChildScrollView(
                    controller: _logScrollCtrl,
                    child: Text(
                      _uiLog.isEmpty ? ' ' : _uiLog, // blank by default
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
