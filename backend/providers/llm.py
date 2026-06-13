"""DashScope 百炼 (dashscope.aliyuncs.com) — Qwen-VL via OpenAI-compatible async API."""

import os
from typing import AsyncGenerator

from openai import AsyncOpenAI

_SYSTEM_PROMPT = (
    "你是一个智能语音助手，可以看到用户的摄像头画面，也能听到用户说话。"
    "请用自然、口语化的中文回答，语句简洁，适合语音朗读。"
    "如果涉及图像内容，请准确描述你看到的，对不确定的内容要明确说明。"
    "不要使用 Markdown 格式，不要使用列表或标题。"
)

# qwen-vl-plus supports both text and images; use qwen-vl-max for higher quality.
_MODEL = "qwen-vl-plus"


def _get_client() -> AsyncOpenAI:
    return AsyncOpenAI(
        api_key=os.environ["DASHSCOPE_API_KEY"],
        base_url="https://dashscope.aliyuncs.com/compatible-mode/v1",
    )


def _build_messages(
    history: list[dict],
    transcript: str,
    frame_b64: str | None,
) -> list[dict]:
    messages: list[dict] = [{"role": "system", "content": _SYSTEM_PROMPT}]
    messages.extend(history)

    # Current user turn — optional image + text
    if frame_b64:
        content: list[dict] = [
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{frame_b64}"}},
            {"type": "text", "text": transcript},
        ]
    else:
        content = [{"type": "text", "text": transcript}]

    messages.append({"role": "user", "content": content})
    return messages


async def generate(
    history: list[dict],
    transcript: str,
    frame_b64: str | None,
) -> AsyncGenerator[str, None]:
    messages = _build_messages(history, transcript, frame_b64)
    stream = await _get_client().chat.completions.create(
        model=os.environ.get("DASHSCOPE_MODEL", _MODEL),
        messages=messages,
        stream=True,
        max_tokens=512,
    )
    async for chunk in stream:
        delta = chunk.choices[0].delta.content
        if delta:
            yield delta
