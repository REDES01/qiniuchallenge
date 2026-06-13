import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'ws_service.dart';

const kWebCameraViewType = 'qiniuchallenge-camera';
const _kMaxSide = 768;

class CameraService {
  // Static so registerViewFactory is called exactly once per app lifetime.
  static bool _factoryRegistered = false;

  CameraService(this._ws) {
    _video = html.VideoElement()
      ..autoplay = true
      ..muted = true
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover';

    // Register synchronously in the constructor so HtmlElementView can find
    // the factory on the very first widget build.
    if (!_factoryRegistered) {
      ui_web.platformViewRegistry.registerViewFactory(
        kWebCameraViewType,
        (int _) => _video,
      );
      _factoryRegistered = true;
    }
  }

  final WsService _ws;
  late html.VideoElement _video;
  html.CanvasElement? _canvas;
  Timer? _timer;
  bool _capturing = false;

  Null get controller => null;

  Future<void> init() async {
    try {
      final stream = await html.window.navigator.mediaDevices!
          .getUserMedia({'video': true, 'audio': false});
      _video.srcObject = stream;
      // Do NOT await onCanPlay — the element may not be in the DOM yet when
      // init() runs, causing the event to never fire and hanging _bootstrap().
      // The browser will start playback automatically once the element is visible.
    } catch (_) {
      // Camera unavailable; frames silently skipped.
    }
  }

  void startCapturing() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _captureFrame());
  }

  Future<void> _captureFrame() async {
    if (_capturing || _video.videoWidth == 0) return;
    _capturing = true;
    try {
      final vw = _video.videoWidth;
      final vh = _video.videoHeight;
      final scale = _kMaxSide / (vw > vh ? vw : vh);
      final tw = scale < 1.0 ? (vw * scale).round() : vw;
      final th = scale < 1.0 ? (vh * scale).round() : vh;

      _canvas ??= html.CanvasElement(width: tw, height: th);
      if (_canvas!.width != tw || _canvas!.height != th) {
        _canvas!.width = tw;
        _canvas!.height = th;
      }
      _canvas!.context2D.drawImageScaled(_video, 0, 0, tw, th);

      final dataUrl = _canvas!.toDataUrl('image/jpeg', 0.8);
      _ws.sendCameraFrame(base64.decode(dataUrl.split(',').last));
    } finally {
      _capturing = false;
    }
  }

  void stopCapturing() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    stopCapturing();
    final src = _video.srcObject;
    if (src is html.MediaStream) {
      for (final t in src.getTracks()) t.stop();
    }
    _video.srcObject = null;
  }
}
