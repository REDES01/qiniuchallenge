"""Per-connection session: audio buffer, camera frame, conversation history."""

import re

_MAX_HISTORY_TURNS = 5  # each turn = one (user, assistant) pair


class Session:
    def __init__(self) -> None:
        self.history: list[dict] = []
        self.latest_frame_b64: str | None = None
        self._audio: bytearray = bytearray()
        self._cancelled = False

    # ── audio buffer ──────────────────────────────────────────────────────────

    def buffer_audio(self, chunk: bytes) -> None:
        self._audio.extend(chunk)

    def drain_audio(self) -> bytes:
        data = bytes(self._audio)
        self._audio = bytearray()
        return data

    # ── camera ────────────────────────────────────────────────────────────────

    def update_frame(self, frame_b64: str) -> None:
        self.latest_frame_b64 = frame_b64

    # ── conversation history ──────────────────────────────────────────────────

    def add_turn(self, transcript: str, response: str) -> None:
        self.history.append({"role": "user", "content": transcript})
        self.history.append({"role": "assistant", "content": response})
        max_msgs = _MAX_HISTORY_TURNS * 2
        if len(self.history) > max_msgs:
            self.history = self.history[-max_msgs:]

    # ── barge-in cancellation ─────────────────────────────────────────────────

    def cancel(self) -> None:
        self._cancelled = True

    def reset_cancel(self) -> None:
        self._cancelled = False

    @property
    def is_cancelled(self) -> bool:
        return self._cancelled


def split_sentences(text: str) -> list[str]:
    """Split at Chinese sentence-ending punctuation, keeping punctuation attached."""
    parts = re.split(r"([。！？…]+)", text)
    out: list[str] = []
    for i in range(0, len(parts) - 1, 2):
        sentence = (parts[i] + parts[i + 1]).strip()
        if sentence:
            out.append(sentence)
    if parts[-1].strip():
        out.append(parts[-1].strip())
    return out
