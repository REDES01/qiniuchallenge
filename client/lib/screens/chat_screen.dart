import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/audio_service.dart';
import '../services/camera_service.dart';
import '../services/ws_service.dart';

// ── Change to match the machine running the backend ──────────────────────────
const _kWsUrl = 'ws://192.168.1.6:8000/ws';

// ── Keep in sync with camera_service_web.dart ─────────────────────────────────
const _kWebCameraViewType = 'qiniuchallenge-camera';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // Created synchronously in initState so the camera factory is registered
  // before the first widget build frame.
  late final WsService _ws;
  late final AudioService _audio;
  late final CameraService _camera;

  final List<_ChatMessage> _messages = [];
  bool _isSpeaking = false;
  bool _ready = false;
  bool _pttActive = false;   // PTT is now a toggle (click once to start, once to stop)
  String _status = '正在初始化…';
  String? _error;

  // Debug counters — visible in the debug panel
  int _chunksSent = 0;
  String _lastServerMsg = '—';

  final _scrollController = ScrollController();
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _ws = WsService(_kWsUrl);
    _audio = AudioService(_ws);
    _camera = CameraService(_ws);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (!kIsWeb) {
      setState(() => _status = '请求权限…');
      final statuses = await [Permission.microphone, Permission.camera].request();
      if (statuses[Permission.microphone] != PermissionStatus.granted ||
          statuses[Permission.camera] != PermissionStatus.granted) {
        setState(() => _error = '需要麦克风和摄像头权限才能使用本应用。');
        return;
      }
    }

    setState(() => _status = '连接服务器 $_kWsUrl …');
    try {
      await _ws.connect();
    } catch (e) {
      setState(() => _error = '无法连接到服务器：$e\n\n请确认后端已启动并且地址正确。');
      return;
    }

    setState(() => _status = '开启摄像头…');
    try {
      await _camera.init();
    } catch (e) {
      debugPrint('Camera init failed: $e');
    }

    setState(() => _status = '开启麦克风…');
    try {
      await _audio.startListening();
    } catch (e) {
      setState(() => _error = '无法访问麦克风：$e');
      return;
    }

    _camera.startCapturing();
    _subs.add(_ws.messages.listen(_onServerMessage));
    _subs.add(_audio.isSpeakingStream.listen((s) => setState(() => _isSpeaking = s)));

    setState(() {
      _ready = true;
      _status = '就绪';
    });
  }

  void _onServerMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String;
    setState(() => _lastServerMsg = type);

    switch (type) {
      case 'transcript':
        final text = msg['text'] as String;
        setState(() => _messages.add(_ChatMessage(role: _Role.user, text: text)));
        _scrollToBottom();

      case 'ai_text':
        setState(() {
          final text = msg['text'] as String;
          if (_messages.isNotEmpty && _messages.last.role == _Role.assistant) {
            _messages.last.text += text;
          } else {
            _messages.add(_ChatMessage(role: _Role.assistant, text: text));
          }
        });
        _scrollToBottom();

      case 'tts_audio':
        _audio.enqueueAudio(msg['data'] as String);

      case 'response_done':
        break;

      case 'error':
        setState(() => _lastServerMsg = 'error: ${msg['message']}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('错误：${msg['message']}'),
            duration: const Duration(seconds: 8),
          ),
        );
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Toggle PTT: first tap starts recording; second tap ends the turn.
  void _togglePtt() {
    if (!_ready) return;
    if (_pttActive) {
      // Stop: flush audio buffer and signal end of speech
      setState(() {
        _pttActive = false;
        _chunksSent = _audio.pttChunksSent;
      });
      _audio.stopPtt();
    } else {
      setState(() {
        _pttActive = true;
        _chunksSent = 0;
      });
      _audio.startPtt();
    }
  }

  @override
  void dispose() {
    for (final s in _subs) s.cancel();
    _audio.dispose();
    _camera.dispose();
    _ws.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F0F0F),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                const SizedBox(height: 16),
                Text(_error!,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 14, height: 1.5),
                    textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: SafeArea(
        child: Column(
          children: [
            _CameraPreviewCard(controller: _camera.controller),
            _StatusBar(
              isSpeaking: _isSpeaking,
              ready: _ready,
              status: _status,
              pttActive: _pttActive,
              onTogglePtt: _togglePtt,
            ),
            // Debug panel — shows exactly where the pipeline is
            if (kIsWeb)
              _DebugPanel(
                ready: _ready,
                chunksSent: _chunksSent,
                pttActive: _pttActive,
                lastServerMsg: _lastServerMsg,
              ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: _messages.length,
                itemBuilder: (_, i) => _MessageBubble(msg: _messages[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Camera preview ───────────────────────────────────────────────────────────

class _CameraPreviewCard extends StatelessWidget {
  const _CameraPreviewCard({required this.controller});
  final CameraController? controller;

  @override
  Widget build(BuildContext context) {
    final Widget preview;
    if (kIsWeb) {
      preview = const HtmlElementView(viewType: _kWebCameraViewType);
    } else if (controller != null && controller!.value.isInitialized) {
      preview = CameraPreview(controller!);
    } else {
      preview = const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: Colors.white30),
          SizedBox(height: 8),
          Text('摄像头初始化中…',
              style: TextStyle(color: Colors.white30, fontSize: 12)),
        ]),
      );
    }

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.32,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        child: ColoredBox(color: Colors.black, child: preview),
      ),
    );
  }
}

// ─── Status bar ───────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.isSpeaking,
    required this.ready,
    required this.status,
    required this.pttActive,
    required this.onTogglePtt,
  });
  final bool isSpeaking;
  final bool ready;
  final String status;
  final bool pttActive;
  final VoidCallback onTogglePtt;

  @override
  Widget build(BuildContext context) {
    final dotColor = !ready
        ? Colors.grey
        : isSpeaking
            ? Colors.redAccent
            : Colors.greenAccent;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 10,
            height: 10,
            decoration:
                BoxDecoration(shape: BoxShape.circle, color: dotColor),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              !ready
                  ? status
                  : isSpeaking
                      ? '正在聆听…'
                      : '待命',
              style:
                  const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          // PTT toggle button (web only — more reliable than hold-to-speak)
          if (kIsWeb)
            ElevatedButton(
              onPressed: onTogglePtt,
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    pttActive ? Colors.redAccent : const Color(0xFF2979FF),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
              child: Text(pttActive ? '■ 停止' : '● 说话'),
            ),
        ],
      ),
    );
  }
}

// ─── Debug panel ─────────────────────────────────────────────────────────────

class _DebugPanel extends StatelessWidget {
  const _DebugPanel({
    required this.ready,
    required this.chunksSent,
    required this.pttActive,
    required this.lastServerMsg,
  });
  final bool ready;
  final int chunksSent;
  final bool pttActive;
  final String lastServerMsg;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF1A1A1A),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        'WS: ${ready ? "✓ connected" : "connecting…"}  '
        '| 音频块: ${pttActive ? "streaming…" : chunksSent}  '
        '| 上条消息: $lastServerMsg',
        style: const TextStyle(
            color: Colors.white38, fontSize: 11, fontFamily: 'monospace'),
      ),
    );
  }
}

// ─── Message bubble ───────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.msg});
  final _ChatMessage msg;

  @override
  Widget build(BuildContext context) {
    final isUser = msg.role == _Role.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color:
              isUser ? const Color(0xFF2979FF) : const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(msg.text,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, height: 1.4)),
      ),
    );
  }
}

// ─── Data ─────────────────────────────────────────────────────────────────────

enum _Role { user, assistant }

class _ChatMessage {
  _ChatMessage({required this.role, required this.text});
  final _Role role;
  String text;
}
