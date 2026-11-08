import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Contract with the booth (photoautomat/lib/services/phone_camera_service.dart):
// the booth serves a WebSocket at ws://<pc>:8765/camera and broadcasts
// "photoautomat-booth:<port>" to UDP 8766 every second so the phone finds it.
// Booth → phone (text JSON): {"type":"preview","enabled":bool}, {"type":"capture","id":n}
// Phone → booth (text JSON): {"type":"hello","name":s}, {"type":"captureFailed","id":n,"message":s}
// Phone → booth (binary):    [1][width u16][height u16][jpeg] live frame
//                            [2][id u32][jpeg]                 full photo
const boothDiscoveryPort = 8766;
const boothBeaconPrefix = 'photoautomat-booth:';
const _manualAddressKey = 'booth_address';

typedef CaptureRequest = Future<void> Function(int id);

class BoothLink extends ChangeNotifier {
  BoothLink({required this.deviceName, required this.onCapture});

  final String deviceName;
  final CaptureRequest onCapture;

  String? manualAddress;
  String? discoveredAddress;
  bool previewWanted = false;
  WebSocket? _socket;
  RawDatagramSocket? _discovery;
  Timer? _reconnect;
  bool _connecting = false;
  bool _closed = false;

  bool get isConnected => _socket != null;
  String? get targetAddress => manualAddress ?? discoveredAddress;

  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    manualAddress = prefs.getString(_manualAddressKey);
    await _listenForBeacons();
    _reconnect = Timer.periodic(const Duration(seconds: 2), (_) => _connect());
    _connect();
    notifyListeners();
  }

  Future<void> setManualAddress(String? address) async {
    final cleaned = address?.trim();
    manualAddress = (cleaned == null || cleaned.isEmpty) ? null : cleaned;
    final prefs = await SharedPreferences.getInstance();
    if (manualAddress == null) {
      await prefs.remove(_manualAddressKey);
    } else {
      await prefs.setString(_manualAddressKey, manualAddress!);
    }
    await _socket?.close();
    _socket = null;
    notifyListeners();
    _connect();
  }

  Future<void> _listenForBeacons() async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, boothDiscoveryPort, reuseAddress: true);
      _discovery = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        final text = utf8.decode(datagram.data, allowMalformed: true);
        if (!text.startsWith(boothBeaconPrefix)) return;
        final port = int.tryParse(text.substring(boothBeaconPrefix.length).trim());
        if (port == null) return;
        final address = '${datagram.address.address}:$port';
        if (address == discoveredAddress) return;
        discoveredAddress = address;
        notifyListeners();
        _connect();
      });
    } catch (e) {
      debugPrint('Booth discovery unavailable: $e');
    }
  }

  Future<void> _connect() async {
    final address = targetAddress;
    if (_closed || _connecting || _socket != null || address == null) return;
    _connecting = true;
    try {
      final hostAndPort = address.contains(':') ? address : '$address:8765';
      final socket = await WebSocket.connect('ws://$hostAndPort/camera').timeout(const Duration(seconds: 3));
      if (_closed) {
        await socket.close();
        return;
      }
      _socket = socket;
      previewWanted = false;
      socket.add(jsonEncode({'type': 'hello', 'name': deviceName}));
      socket.listen(_onMessage, onDone: _onDisconnected, onError: (_) => _onDisconnected(), cancelOnError: true);
      notifyListeners();
    } catch (e) {
      debugPrint('Cannot reach booth at $address: $e');
    } finally {
      _connecting = false;
    }
  }

  void _onDisconnected() {
    if (_socket == null) return;
    _socket = null;
    previewWanted = false;
    notifyListeners();
  }

  void _onMessage(dynamic message) {
    if (message is! String) return;
    final Map<String, dynamic> command;
    try {
      command = jsonDecode(message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (command['type']) {
      case 'preview':
        previewWanted = command['enabled'] == true;
        notifyListeners();
      case 'capture':
        final id = command['id'];
        if (id is int) onCapture(id);
    }
  }

  void sendPreviewFrame(int width, int height, Uint8List jpeg) {
    final header = ByteData(5)
      ..setUint8(0, 1)
      ..setUint16(1, width)
      ..setUint16(3, height);
    _send(header.buffer.asUint8List(), jpeg);
  }

  void sendPhoto(int id, Uint8List jpeg) {
    final header = ByteData(5)
      ..setUint8(0, 2)
      ..setUint32(1, id);
    _send(header.buffer.asUint8List(), jpeg);
  }

  void sendCaptureFailed(int id, String message) {
    _socket?.add(jsonEncode({'type': 'captureFailed', 'id': id, 'message': message}));
  }

  void _send(Uint8List header, Uint8List payload) {
    final socket = _socket;
    if (socket == null) return;
    final packet = Uint8List(header.length + payload.length)
      ..setAll(0, header)
      ..setAll(header.length, payload);
    socket.add(packet);
  }

  @override
  void dispose() {
    _closed = true;
    _reconnect?.cancel();
    _discovery?.close();
    _socket?.close();
    super.dispose();
  }
}
