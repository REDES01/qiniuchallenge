"""iFlytek Real-Time ASR (IAT) — batch-after-EOS mode.

One WebSocket connection per utterance. Audio is sent in 40 ms PCM chunks
with status 0 (first), 1 (continue), 2 (last), which matches iFlytek's
streaming protocol even though we send post-EOS.
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

_HOST = "iat-api.xfyun.cn"
_PATH = "/v2/iat"
# 40 ms of 16-bit 16 kHz mono audio
_CHUNK_BYTES = 16000 * 2 * 40 // 1000


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


async def recognize(audio_data: bytes) -> str:
    """Send PCM-16/16 kHz/mono audio, return the final Chinese transcript."""
    if not audio_data:
        return ""

    url = _signed_url()
    segments: dict[int, str] = {}
    chunks = [
        audio_data[i : i + _CHUNK_BYTES]
        for i in range(0, len(audio_data), _CHUNK_BYTES)
    ]

    async with websockets.connect(url) as conn:
        async def _send_all() -> None:
            for i, chunk in enumerate(chunks):
                status = 0 if i == 0 else (2 if i == len(chunks) - 1 else 1)
                frame: dict = {
                    "data": {
                        "status": status,
                        "format": "audio/L16;rate=16000",
                        "encoding": "raw",
                        "audio": base64.b64encode(chunk).decode(),
                    }
                }
                if i == 0:
                    frame["common"] = {"app_id": os.environ["XFYUN_APP_ID"]}
                    frame["business"] = {
                        "language": "zh_cn",
                        "domain": "iat",
                        "accent": "mandarin",
                        "dwa": "wpgs",
                    }
                await conn.send(json.dumps(frame))
                await asyncio.sleep(0.04)

        async def _recv_all() -> None:
            async for raw in conn:
                msg = json.loads(raw)
                if msg.get("code", 0) != 0:
                    raise RuntimeError(
                        f"iFlytek ASR error {msg['code']}: {msg.get('message')}"
                    )
                data = msg.get("data", {})
                result = data.get("result")
                if result:
                    text = "".join(
                        cw["w"]
                        for ws_item in result.get("ws", [])
                        for cw in ws_item.get("cw", [])
                    )
                    segments[result.get("sn", 0)] = text
                if data.get("status") == 2:
                    break

        await asyncio.gather(_send_all(), _recv_all())

    return "".join(v for _, v in sorted(segments.items()))
