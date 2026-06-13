"""Rule-based visual-intent classifier.

Returns True when the user's query likely references what the camera sees,
so the frame is included in the LLM call. False → text-only call (cheaper).
"""

_VISUAL_KEYWORDS = frozenset({
    "看", "看看", "帮我看", "能看", "看到", "看一下",
    "这是", "那是", "这个", "那个", "这里", "那里",
    "什么东西", "什么字", "上面写", "里面有", "面前", "眼前",
    "图片", "图像", "画面", "屏幕", "照片", "拍",
    "识别", "扫", "扫一下", "读", "读一下",
    "翻译", "是什么", "显示", "有什么",
})


def is_visual_query(text: str) -> bool:
    return any(kw in text for kw in _VISUAL_KEYWORDS)
