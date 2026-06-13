import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

import 'ws_service.dart';

const _kMaxSide = 768;
const _kJpegQuality = 80;

class CameraService {
  CameraService(this._ws);

  final WsService _ws;
  CameraController? _controller;
  Timer? _timer;
  bool _capturing = false;

  CameraController? get controller => _controller;

  Future<void> init() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _controller = CameraController(camera, ResolutionPreset.medium, enableAudio: false);
    await _controller!.initialize();
  }

  void startCapturing() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _captureFrame());
  }

  Future<void> _captureFrame() async {
    if (_capturing || _controller == null || !_controller!.value.isInitialized) return;
    _capturing = true;
    try {
      final xfile = await _controller!.takePicture();
      final raw = await xfile.readAsBytes();
      _ws.sendCameraFrame(_resizeJpeg(raw));
    } catch (_) {
    } finally {
      _capturing = false;
    }
  }

  Uint8List _resizeJpeg(Uint8List input) {
    final decoded = img.decodeImage(input);
    if (decoded == null) return input;
    if (decoded.width <= _kMaxSide && decoded.height <= _kMaxSide) {
      return Uint8List.fromList(img.encodeJpg(decoded, quality: _kJpegQuality));
    }
    final landscape = decoded.width >= decoded.height;
    final resized = landscape
        ? img.copyResize(decoded, width: _kMaxSide)
        : img.copyResize(decoded, height: _kMaxSide);
    return Uint8List.fromList(img.encodeJpg(resized, quality: _kJpegQuality));
  }

  void stopCapturing() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    stopCapturing();
    await _controller?.dispose();
  }
}
