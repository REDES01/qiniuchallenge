# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

AI multimodal chat application: voice input (STT) + camera input (vision) + spoken AI response (TTS). Targets mainland China — all services must be accessible without VPN. See [`DESIGN.md`](DESIGN.md) for full architecture, user stories, and cost-control strategy.

## Running the backend

```bash
cd backend
cp .env.example .env        # fill in XFYUN_* and DASHSCOPE_API_KEY
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

The server listens on `ws://<host>:8000/ws`.

## Running the Flutter client

```bash
cd client
flutter pub get
flutter run                 # connects to the IP set in chat_screen.dart (_kWsUrl)
```

Before running on a real device, edit `lib/screens/chat_screen.dart` and update
`_kWsUrl` to point to the machine running the backend (e.g. `ws://192.168.1.50:8000/ws`).

## Project layout

```
backend/
  main.py          – FastAPI app + WebSocket turn handler
  session.py       – per-connection audio buffer, camera frame, history
  classifier.py    – keyword-based text-vs-visual query classifier
  providers/
    asr.py         – iFlytek IAT (batch-after-EOS)
    llm.py         – Qwen-VL-Plus streaming via DashScope SDK
    tts.py         – iFlytek TTS, MP3 output, in-memory phrase cache

client/lib/
  main.dart
  screens/chat_screen.dart  – UI: camera preview + chat bubbles
  services/
    ws_service.dart     – WebSocket send/receive
    audio_service.dart  – VAD (amplitude-based) + PCM streaming + TTS playback queue
    camera_service.dart – 1 fps capture, 768 px resize, JPEG encode
```

## WebSocket message protocol

Client → Server: `audio_chunk`, `camera_frame`, `end_of_speech`, `barge_in`  
Server → Client: `transcript`, `ai_text`, `tts_audio` (MP3 base64), `response_done`, `error`

All messages are JSON. Audio is PCM 16-bit / 16 kHz / mono. Images are JPEG ≤ 768 px.
