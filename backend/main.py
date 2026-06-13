"""FastAPI WebSocket server — orchestrates ASR → LLM → TTS pipeline.

Message protocol
────────────────
Client → Server (JSON):
  {"type": "audio_chunk",   "data": "<base64 PCM 16-bit 16 kHz mono>"}
  {"type": "camera_frame",  "data": "<base64 JPEG ≤768 px>"}
  {"type": "end_of_speech"}
  {"type": "barge_in"}

Server → Client (JSON):
  {"type": "transcript",  "text": "<str>"}
  {"type": "ai_text",     "text": "<str>"}         # streaming LLM text
  {"type": "tts_audio",   "data": "<base64 MP3>",  "chunk_idx": <int>}
  {"type": "response_done"}
  {"type": "error",       "message": "<str>"}
"""

import asyncio
import base64
import json
import logging

from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from providers.asr import recognize
from providers.llm import generate
from providers.tts import synthesize
from session import Session, split_sentences

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

@asynccontextmanager
async def lifespan(_: FastAPI):
    yield

app = FastAPI(lifespan=lifespan)


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket) -> None:
    await ws.accept()
    session = Session()
    current_turn: asyncio.Task | None = None
    log.info("client connected")

    try:
        while True:
            raw = await ws.receive_text()
            msg = json.loads(raw)

            match msg["type"]:
                case "audio_chunk":
                    session.buffer_audio(base64.b64decode(msg["data"]))
                case "camera_frame":
                    session.update_frame(msg["data"])
                case "end_of_speech":
                    log.info("end_of_speech received, audio buffer=%d bytes", len(session._audio))
                    # Cancel any in-flight turn before starting a new one.
                    if current_turn and not current_turn.done():
                        current_turn.cancel()
                    current_turn = asyncio.create_task(_handle_turn(ws, session))
                case "barge_in":
                    session.cancel()
                    if current_turn and not current_turn.done():
                        current_turn.cancel()
    except WebSocketDisconnect:
        if current_turn:
            current_turn.cancel()
        log.info("client disconnected")


async def _send(ws: WebSocket, payload: dict) -> None:
    await ws.send_text(json.dumps(payload, ensure_ascii=False))


async def _handle_turn(ws: WebSocket, session: Session) -> None:
    session.reset_cancel()
    audio = session.drain_audio()
    if not audio:
        return

    try:
        transcript = await recognize(audio)
        if not transcript.strip():
            return

        await _send(ws, {"type": "transcript", "text": transcript})
        log.info("transcript: %s", transcript)

        frame = session.latest_frame_b64  # always include latest camera frame

        # Pipe LLM chunks into a sentence queue; TTS each sentence as it completes.
        sentence_queue: asyncio.Queue[str | None] = asyncio.Queue()
        full_text_parts: list[str] = []

        async def _llm_to_queue() -> None:
            try:
                buf = ""
                async for chunk in generate(session.history, transcript, frame):
                    if session.is_cancelled:
                        break
                    full_text_parts.append(chunk)
                    buf += chunk
                    await _send(ws, {"type": "ai_text", "text": chunk})

                    sentences = split_sentences(buf)
                    if len(sentences) > 1:
                        for s in sentences[:-1]:
                            await sentence_queue.put(s)
                        buf = sentences[-1]

                if buf.strip() and not session.is_cancelled:
                    await sentence_queue.put(buf.strip())
            except Exception as exc:
                log.exception("LLM error")
                try:
                    await _send(ws, {"type": "error", "message": f"LLM错误: {exc}"})
                except Exception:
                    pass
            finally:
                # Always signal end so the consumer loop never hangs.
                await sentence_queue.put(None)

        llm_task = asyncio.create_task(_llm_to_queue())

        chunk_idx = 0

        while True:
            if session.is_cancelled:
                llm_task.cancel()
                break

            sentence = await sentence_queue.get()

            if sentence is None:
                break

            if session.is_cancelled:
                llm_task.cancel()
                break

            tts_audio = await synthesize(sentence)
            if not session.is_cancelled:
                await _send(ws, {
                    "type": "tts_audio",
                    "data": base64.b64encode(tts_audio).decode(),
                    "chunk_idx": chunk_idx,
                })
                chunk_idx += 1

        if not session.is_cancelled:
            session.add_turn(transcript, "".join(full_text_parts))
            await _send(ws, {"type": "response_done"})

    except Exception as exc:
        log.exception("turn error")
        await _send(ws, {"type": "error", "message": str(exc)})
