import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'booth_link.dart';
import 'preview_encoder.dart';

const _flashModeKey = 'flash_mode';
const _minFrameGap = Duration(milliseconds: 66);

enum BoothFlash {
  always('แฟลช: ทุกครั้ง', Icons.flash_on, FlashMode.always),
  auto('แฟลช: อัตโนมัติ', Icons.flash_auto, FlashMode.auto),
  off('แฟลช: ปิด', Icons.flash_off, FlashMode.off);

  const BoothFlash(this.label, this.icon, this.mode);
  final String label;
  final IconData icon;
  final FlashMode mode;

  BoothFlash get next => BoothFlash.values[(index + 1) % BoothFlash.values.length];
}

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  late final BoothLink _link = BoothLink(deviceName: 'กล้องมือถือ Android', onCapture: _capture);
  CameraController? _controller;
  CameraDescription? _backCamera;
  String? _cameraError;
  BoothFlash _flash = BoothFlash.always;
  bool _encoding = false;
  bool _capturing = false;
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _link.addListener(_onLinkChanged);
    _loadFlash();
    _link.start();
    _openCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _link.removeListener(_onLinkChanged);
    _link.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      final controller = _controller;
      _controller = null;
      if (mounted) setState(() {});
      controller?.dispose();
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _openCamera();
    }
  }

  void _onLinkChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadFlash() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = BoothFlash.values.where((f) => f.name == prefs.getString(_flashModeKey));
    if (saved.isNotEmpty && mounted) setState(() => _flash = saved.first);
  }

  Future<void> _cycleFlash() async {
    setState(() => _flash = _flash.next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_flashModeKey, _flash.name);
  }

  Future<void> _openCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.where((c) => c.lensDirection == CameraLensDirection.back);
      if (back.isEmpty) throw CameraException('noBackCamera', 'ไม่พบกล้องหลัง');
      _backCamera = back.first;
      final controller = await _startController(_backCamera!, ResolutionPreset.max)
          // Some phones cannot stream frames while also capturing at full sensor size.
          .catchError((Object _) => _startController(_backCamera!, ResolutionPreset.veryHigh));
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _cameraError = null;
      });
    } on CameraException catch (e) {
      if (mounted) setState(() => _cameraError = 'เปิดกล้องไม่ได้: ${e.description ?? e.code}');
    } catch (e) {
      if (mounted) setState(() => _cameraError = 'เปิดกล้องไม่ได้: $e');
    }
  }

  Future<CameraController> _startController(CameraDescription camera, ResolutionPreset preset) async {
    final controller = CameraController(
      camera,
      preset,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await controller.initialize();
      await controller.lockCaptureOrientation(DeviceOrientation.landscapeLeft);
      await controller.startImageStream(_onFrame);
      return controller;
    } catch (_) {
      await controller.dispose();
      rethrow;
    }
  }

  /// The app is locked to landscapeLeft (display rotation 90°), so frames need
  /// the sensor orientation minus that to come out upright.
  int get _frameRotation => ((_backCamera?.sensorOrientation ?? 90) - 90 + 360) % 360;

  void _onFrame(CameraImage image) {
    if (!_link.isConnected || !_link.previewWanted || _encoding || _capturing) return;
    final now = DateTime.now();
    if (now.difference(_lastFrameAt) < _minFrameGap) return;
    _lastFrameAt = now;
    _encoding = true;
    final rgb = sampleYuvToRgb(image);
    encodePreviewJpeg(rgb, _frameRotation)
        .then((frame) => _link.sendPreviewFrame(frame.width, frame.height, frame.jpeg))
        .catchError((Object e) => debugPrint('Preview frame dropped: $e'))
        .whenComplete(() => _encoding = false);
  }

  Future<void> _capture(int id) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      _link.sendCaptureFailed(id, 'กล้องมือถือยังไม่พร้อม');
      return;
    }
    if (_capturing) {
      _link.sendCaptureFailed(id, 'กล้องมือถือกำลังถ่ายอยู่');
      return;
    }
    _capturing = true;
    try {
      await controller.setFlashMode(_flash.mode);
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      _link.sendPhoto(id, bytes);
      unawaited(File(file.path).delete().then((_) {}, onError: (_) {}));
    } on CameraException catch (e) {
      _link.sendCaptureFailed(id, 'ถ่ายรูปไม่สำเร็จ: ${e.description ?? e.code}');
    } finally {
      _capturing = false;
    }
  }

  Future<void> _editAddress() async {
    final input = TextEditingController(text: _link.manualAddress ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ที่อยู่ของตู้'),
        content: TextField(
          controller: input,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'เช่น 192.168.1.20',
            helperText: 'เว้นว่างไว้ = ค้นหาตู้ในวง Wi-Fi เอง',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ยกเลิก')),
          FilledButton(onPressed: () => Navigator.pop(context, input.text), child: const Text('บันทึก')),
        ],
      ),
    );
    if (result != null) await _link.setManualAddress(result);
  }

  String get _statusText {
    if (_link.isConnected) {
      return _link.previewWanted ? 'ต่อกับตู้แล้ว · กำลังส่งภาพ' : 'ต่อกับตู้แล้ว · รอหน้าถ่ายรูป';
    }
    final target = _link.targetAddress;
    return target == null ? 'กำลังค้นหาตู้ใน Wi-Fi…' : 'กำลังต่อกับตู้ $target…';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null && controller.value.isInitialized)
            Center(child: CameraPreview(controller))
          else
            Center(
              child: Text(
                _cameraError ?? 'กำลังเปิดกล้อง…',
                style: const TextStyle(color: Colors.white70, fontSize: 18),
              ),
            ),
          Positioned(
            left: 16,
            top: 16,
            child: _StatusChip(text: _statusText, ok: _link.isConnected),
          ),
          Positioned(
            right: 16,
            top: 16,
            child: Row(
              children: [
                _RoundButton(icon: _flash.icon, label: _flash.label, onPressed: _cycleFlash),
                const SizedBox(width: 8),
                _RoundButton(icon: Icons.settings_ethernet, label: 'ที่อยู่ตู้', onPressed: _editAddress),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text, required this.ok});
  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 12, color: ok ? Colors.greenAccent : Colors.orangeAccent),
            const SizedBox(width: 8),
            Text(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}
