import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import 'ws_service.dart';

// Voice-activity thresholds.
const _kSpeechDb = -35.0;
const _kSpeechTriggerFrames = 5;  // ~200 ms at 40 ms/frame
const _kSilenceTriggerFrames = 20; // ~800 ms

enum _VadState { idle, speech, trailing }

/// Microphone recording with amplitude-based VAD + MP3 TTS playback queue.
class AudioService {
  AudioService(this._ws);

  final WsService _ws;
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  StreamSubscription<Uint8List>? _recordSub;

  _VadState _vadState = _VadState.idle;
  int _speechFrames = 0;
  int _silenceFrames = 0;
  bool _isPlayingTts = false;
  bool _pttMode = false;
  int _pttChunksSent = 0;
  final _audioQueue = Queue<Uint8List>();

  final _vadController = StreamController<bool>.broadcast();

  /// Emits true when speech starts, false when it ends.
  Stream<bool> get isSpeakingStream => _vadController.stream;

  int get pttChunksSent => _pttChunksSent;

  Future<void> startListening() async {
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _recordSub = stream.listen(_onPcmChunk);
  }

  /// Push-to-talk: bypass VAD, stream every chunk directly.
  void startPtt() {
    _pttChunksSent = 0;
    _pttMode = true;
    _vadState = _VadState.speech;
    _vadController.add(true);
    if (_isPlayingTts) {
      _player.stop();
      _audioQueue.clear();
      _isPlayingTts = false;
      _ws.sendBargeIn();
    }
  }

  /// End PTT: signal end-of-speech and return to VAD mode.
  void stopPtt() {
    if (!_pttMode) return;
    _pttMode = false;
    _vadState = _VadState.idle;
    _speechFrames = 0;
    _silenceFrames = 0;
    _vadController.add(false);
    _ws.sendEndOfSpeech();
  }

  void _onPcmChunk(Uint8List pcm) {
    if (_pttMode) {
      _ws.sendAudioChunk(pcm);
      _pttChunksSent++;
      return;
    }
    final db = _rmsDb(pcm);

    switch (_vadState) {
      case _VadState.idle:
        if (db > _kSpeechDb) {
          _speechFrames++;
          if (_speechFrames >= _kSpeechTriggerFrames) {
            _vadState = _VadState.speech;
            _speechFrames = 0;
            _vadController.add(true);
            if (_isPlayingTts) {
              _player.stop();
              _audioQueue.clear();
              _isPlayingTts = false;
              _ws.sendBargeIn();
            }
          }
        } else {
          _speechFrames = 0;
        }

      case _VadState.speech:
        _ws.sendAudioChunk(pcm);
        if (db < _kSpeechDb) {
          _silenceFrames++;
          if (_silenceFrames >= _kSilenceTriggerFrames) {
            _vadState = _VadState.trailing;
            _silenceFrames = 0;
          }
        } else {
          _silenceFrames = 0;
        }

      case _VadState.trailing:
        _ws.sendAudioChunk(pcm);
        _silenceFrames++;
        if (_silenceFrames >= _kSilenceTriggerFrames ~/ 2) {
          _vadState = _VadState.idle;
          _speechFrames = 0;
          _silenceFrames = 0;
          _vadController.add(false);
          _ws.sendEndOfSpeech();
        }
    }
  }

  /// Enqueue a base64-encoded MP3 for sequential playback.
  void enqueueAudio(String mp3Base64) {
    _audioQueue.add(base64.decode(mp3Base64));
    if (!_isPlayingTts) _playNext();
  }

  Future<void> _playNext() async {
    if (_isPlayingTts) return;
    _isPlayingTts = true;
    while (_audioQueue.isNotEmpty) {
      final bytes = _audioQueue.removeFirst();
      try {
        final uri = Uri.dataFromBytes(bytes, mimeType: 'audio/mpeg');
        await _player.setAudioSource(AudioSource.uri(uri));
        await _player.play();
        await _player.processingStateStream
            .firstWhere((s) => s == ProcessingState.completed);
      } catch (_) {
        // Swallow playback errors; continue to next clip.
      } finally {
        await _player.stop();
      }
    }
    _isPlayingTts = false;
  }

  Future<void> stopListening() async {
    await _recordSub?.cancel();
    await _recorder.stop();
  }

  void dispose() {
    _recordSub?.cancel();
    _recorder.dispose();
    _player.dispose();
    _vadController.close();
  }
}

double _rmsDb(Uint8List pcm) {
  if (pcm.lengthInBytes < 2) return -100.0;
  // Use offsetInBytes + explicit length so the view is correct even when
  // the Uint8List is a sub-view of a larger buffer (common with platform streams).
  final samples = pcm.buffer.asInt16List(pcm.offsetInBytes, pcm.lengthInBytes ~/ 2);
  double sum = 0;
  for (final s in samples) {
    sum += s * s;
  }
  final rms = sqrt(sum / samples.length);
  if (rms == 0) return -100.0;
  return 20 * log(rms / 32768) / log(10);
}
