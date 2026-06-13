import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Low-level WebSocket adapter.  Exposes typed send methods and a raw
/// message stream.  Reconnection is intentionally not in scope for MVP.
class WsService {
  WsService(String url) : _url = url;

  final String _url;
  WebSocketChannel? _channel;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _controller.stream;
  bool get isConnected => _channel != null;

  Future<void> connect() async {
    _channel = WebSocketChannel.connect(Uri.parse(_url));
    // .ready throws a WebSocketChannelException if the handshake fails,
    // which lets _bootstrap() catch and surface a meaningful error message.
    await _channel!.ready;
    _channel!.stream.listen(
      (raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        _controller.add(msg);
      },
      onError: (Object err) => _controller.addError(err),
      onDone: () => _channel = null,
    );
  }

  void sendAudioChunk(Uint8List pcmBytes) {
    _send({'type': 'audio_chunk', 'data': base64Encode(pcmBytes)});
  }

  void sendCameraFrame(Uint8List jpegBytes) {
    _send({'type': 'camera_frame', 'data': base64Encode(jpegBytes)});
  }

  void sendEndOfSpeech() => _send({'type': 'end_of_speech'});

  void sendBargeIn() => _send({'type': 'barge_in'});

  void _send(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode(payload));
  }

  Future<void> disconnect() async {
    await _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    disconnect();
    _controller.close();
  }
}
