"""iFlytek TTS WebSocket API — returns MP3 chunks.

Caches synthesized audio for common filler phrases so repeated short
responses don't hit the API each time.
"""

import asyncio
import base64
import hashlib
import hmac
import json
import os
from datetime import datetime
from urllib.parse import urlencode

import websockets

_HOST = "tts-api.xfyun.cn"
_PATH = "/v2/tts"

# Pre-synthesized on first use; keys are the phrase strings.
_CACHE: dict[str, bytes] = {k: b"" for k in [
    "好的",
    "好",
    "嗯",
    "嗯嗯",
    "好的，我来看看。",
    "让我想想。",
    "稍等一下。",
    "我正在查看。",
    "明白了。",
    "没问题。",
    "好的，我知道了。",
    "我不太理解，能再说一次吗？",
    "好的，我理解了。",
    "请问还有什么需要帮助的吗？",
    "请稍等。",
    "嗯，让我想想。",
    "好的，稍等一下。",
    "我来帮你看看。",
    "没问题，稍等。",
    "好的，我看到了。",
]}


def _signed_url() -> str:
    date = datetime.utcnow().strftime("%a, %d %b %Y %H:%M:%S GMT")
    sig_origin = f"host: {_HOST}\ndate: {date}\nGET {_PATH} HTTP/1.1"
    sig = base64.b64encode(
        hmac.new(
            os.environ["XFYUN_API_SECRET"].encode(),
            sig_origin.encode(),
            hashlib.sha256,
        ).digest()
    ).decode()
    auth_origin = (
        f'api_key="{os.environ["XFYUN_API_KEY"]}", '
        f'algorithm="hmac-sha256", '
        f'headers="host date request-line", '
        f'signature="{sig}"'
    )
    auth = base64.b64encode(auth_origin.encode()).decode()
    qs = urlencode({"authorization": auth, "date": date, "host": _HOST})
    return f"wss://{_HOST}{_PATH}?{qs}"


async def _call_api(text: str) -> bytes:
    url = _signed_url()
    chunks: list[bytes] = []

    async with websockets.connect(url) as ws:
        payload = {
            "common": {"app_id": os.environ["XFYUN_APP_ID"]},
            "business": {
                "aue": "lame",       # MP3
                "vcn": "xiaoyan",    # natural female Mandarin voice
                "speed": 55,
                "volume": 80,
                "pitch": 50,
                "tte": "UTF8",
            },
            "data": {
                "status": 2,
                "text": base64.b64encode(text.encode()).decode(),
            },
        }
        await ws.send(json.dumps(payload))

        async for raw in ws:
            msg = json.loads(raw)
            if msg.get("code", 0) != 0:
                raise RuntimeError(f"iFlytek TTS error {msg['code']}: {msg.get('message')}")
            audio_b64 = msg.get("data", {}).get("audio", "")
            if audio_b64:
                chunks.append(base64.b64decode(audio_b64))
            if msg.get("data", {}).get("status") == 2:
                break

    return b"".join(chunks)


async def synthesize(text: str) -> bytes:
    """Return MP3 bytes for *text*. Uses in-memory cache for known phrases."""
    cached = _CACHE.get(text)
    if cached:
        return cached

    audio = await _call_api(text)

    if text in _CACHE:
        _CACHE[text] = audio

    return audio


async def warm_cache() -> None:
    """Pre-synthesize all cache phrases at startup (best-effort, max 3 concurrent)."""
    sem = asyncio.Semaphore(3)

    async def _one(phrase: str) -> None:
        async with sem:
            try:
                audio = await _call_api(phrase)
                if audio:
                    _CACHE[phrase] = audio
            except Exception:
                pass  # non-fatal; phrase will be synthesized on first real use

    await asyncio.gather(*[_one(p) for p in list(_CACHE.keys())])
