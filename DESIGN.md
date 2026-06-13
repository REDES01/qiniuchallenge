# AI Multimodal Chat Application — Design Document

**Target market**: Mainland China  
**Date**: 2026-06-13  
**Status**: Planning / Pre-implementation

---

## 1. Overview

A real-time AI chat application that sees through the device camera, hears the user's voice, and responds in natural spoken Chinese. Designed for mainland China — all services must be accessible without VPN, meaning no Google, OpenAI, or other globally-blocked providers.

The core challenge is balancing three tensions simultaneously:
- **Fluency vs latency**: voice must feel like a conversation, not a walkie-talkie
- **Visual accuracy vs cost**: vision API calls are expensive; sending every frame is not viable
- **Edge vs cloud**: on-device is free and private; cloud is more capable but has per-call cost and network latency

---

## 2. User Stories

### US-01 · Natural Voice Conversation
> As a Chinese-speaking user, I want to speak naturally (including mixed Mandarin/dialects/English code-switching) and receive a spoken response within 1–2 seconds of finishing my sentence, so that the interaction feels like a real conversation rather than a query-response system.

**Acceptance criteria**:
- STT handles accented Mandarin and common Mandarin/English code-switching
- First audio byte of TTS response begins playing ≤ 1.5 s after end-of-speech is detected
- The AI does not interrupt itself if the user starts speaking mid-response (barge-in support)

---

### US-02 · Camera-Grounded Q&A
> As a user, I want to point my camera at anything — a product label, a document, an unfamiliar plant, a math problem — and ask a natural language question about it, so I can get contextual help without typing or describing the scene.

**Acceptance criteria**:
- User does not need to say "look at this" — the system passively maintains visual context
- Visual queries ("这是什么？", "上面写的什么？", "怎么算？") are answered using the current camera frame
- OCR accuracy on printed Chinese text ≥ 90% under normal lighting

---

### US-03 · Hands-Free / Wake-Word Activation
> As a user, I want to say a wake word ("你好，小智") so the assistant activates without me needing to tap the screen, enabling truly hands-free use while cooking, driving, or working.

**Acceptance criteria**:
- Wake word detection runs entirely on-device with < 5% false-positive rate
- Microphone is not streamed to cloud before wake word is confirmed
- Battery drain from always-listening mode is acceptable (< 3% per hour on mid-range phone)

---

### US-04 · Proactive Visual Awareness
> As a user, I want the AI to occasionally notice and comment on important things in the camera view that I haven't asked about (e.g., "我注意到这份合同里有一条不寻常的条款"), so the assistant feels genuinely attentive rather than purely reactive.

**Acceptance criteria**:
- Proactive comments are triggered at most once every 30 seconds to avoid being intrusive
- Triggered only when scene content changes significantly (scene-change threshold)
- User can disable proactive mode in settings

---

### US-05 · Multimodal Context Fusion
> As a user, I want the AI to automatically combine what I say with what it sees — without me having to describe my surroundings — so answers are grounded in my actual context.

**Acceptance criteria**:
- Every cloud LLM call includes the most recent camera frame when the query is classified as visual
- The model's response references specific visual details when relevant
- Purely conversational queries (greetings, abstract questions) do NOT send camera frames, saving cost

---

### US-06 · Low-Cost Sustained Use
> As a user, I want to run the assistant for 30+ minutes without it becoming prohibitively expensive for the developer, so the service remains available and affordable.

**Acceptance criteria**:
- Vision API is not called more than ~10× per minute under normal use
- STT is only billed for actual speech segments (silence is filtered at edge)
- A 30-minute session costs less than ¥1 RMB in API fees under typical usage patterns

---

## 3. System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                       CLIENT DEVICE (Mobile / Web)                   │
│                                                                      │
│  Microphone ──► [VAD] ──► [Audio Buffer]                            │
│                                 │ speech only                        │
│  Camera ──► [Frame Sampler] ──► [Scene-Change Detector]             │
│                    1 fps                  │ changed frames only      │
│                                           │                          │
│             [Wake Word Detector (on-device)]                         │
│                    │ activated only after wake word                  │
│                    ▼                                                  │
│             WebSocket / HTTPS stream ────────────────────────────┐   │
└──────────────────────────────────────────────────────────────────┼───┘
                                                                   │
┌──────────────────────────────────────────────────────────────────▼───┐
│                           BACKEND SERVER                              │
│                   (Alibaba Cloud / Tencent Cloud, China region)       │
│                                                                       │
│  ┌──────────────────┐    ┌─────────────────────────────────────────┐ │
│  │  Session Manager  │    │          Orchestration Layer            │ │
│  │  - Conversation   │    │  1. Receive audio chunk                 │ │
│  │    history (5 turns)   │  2. Stream to STT → get transcript      │ │
│  │  - Last frame     │◄──►│  3. Classify: text-only vs visual?      │ │
│  │  - User prefs     │    │  4. Build LLM prompt (text [+ frame])   │ │
│  └──────────────────┘    │  5. Stream LLM response                  │ │
│                           │  6. Stream TTS → send audio to client   │ │
│                           └─────────────────────────────────────────┘ │
│                                     │                                  │
│     ┌───────────────┬───────────────┼───────────────┐                 │
│     ▼               ▼               ▼               ▼                 │
│  [iFlytek STT]  [Qwen-VL-Plus]  [iFlytek TTS]  [Query Classifier]    │
│  Real-time ASR  Multimodal LLM   Streaming TTS   (rule + small LLM)  │
└───────────────────────────────────────────────────────────────────────┘
```

### Data flow (single turn)

1. User speaks → Edge VAD detects speech start, begins buffering audio
2. Edge streams audio chunks over WebSocket to backend
3. Backend pipes audio to **iFlytek Real-Time ASR** (streaming); partial transcripts arrive every ~200 ms
4. Edge VAD detects end-of-speech → sends end-of-utterance signal
5. Final transcript locked; backend runs **Query Classifier** (visual or text-only?)
6. If **visual**: backend fetches latest camera frame sent by edge; includes it in LLM call
7. Backend calls **Qwen-VL-Plus** with [system context, conversation history (last 5 turns), transcript, optional frame]
8. LLM response streams back; backend pipes text chunks to **iFlytek TTS** in real time
9. TTS audio streams back to client and plays immediately (progressive playback)
10. Full response appended to session history

---

## 4. Technology Stack (Mainland China)

| Layer | Chosen Provider | Reason |
|---|---|---|
| STT | **iFlytek Spark ASR** (讯飞实时语音转写) | Best Chinese ASR accuracy, streaming API, dialect support |
| Multimodal LLM | **Qwen-VL-Plus** (Alibaba Cloud) | Strong vision + Chinese language, accessible in China, cost-effective vs Qwen-VL-Max |
| TTS | **iFlytek TTS** (讯飞语音合成) | Most natural Chinese TTS on market; SSML support for prosody control |
| Backend runtime | **Python / FastAPI** | Async WebSocket handling; good SDK support for all above providers |
| Deployment | **Alibaba Cloud ECS** (华东 / 华北) | Co-located with Qwen APIs → lowest latency; ICP-compliant |
| Wake word | **Picovoice Porcupine** or **Snowboy** (on-device) | Runs fully on-device; no network call |
| Edge VAD | **WebRTC VAD** (py-webrtcvad / browser MediaRecorder VAD) | Proven, lightweight |
| Mobile client | **Flutter** | Single codebase iOS + Android; good camera + mic APIs |

### Fallback / alternatives considered

- **GLM-4V** (Zhipu AI): strong competitor to Qwen-VL; can use as failover
- **Baidu ERNIE Bot**: broader ecosystem but weaker vision accuracy benchmarks
- **Azure China (21Vianet)**: GPT-4o accessible via Azure China endpoint, but pricing less predictable and still US-origin model with compliance questions for some enterprise users
- **MiniCPM-V** (on-device): open-source multimodal model that can run on high-end phones — worth evaluating for future offline mode

---

## 5. Cost Control — Strategies

### 5A. All strategies considered (including unimplemented)

#### Edge-side strategies

| ID | Strategy | Estimated Saving | Complexity |
|---|---|---|---|
| E1 | **Voice Activity Detection (VAD)** — only stream audio during detected speech; silence is discarded at edge | 40–70% of STT cost | Low |
| E2 | **Wake-word gate** — microphone not streamed at all until wake word confirmed on-device | Near-zero STT cost during idle | Medium |
| E3 | **Adaptive frame rate** — camera captured at 1 fps baseline; drops to 0.2 fps when scene is static | 50–80% of vision API calls | Low–Medium |
| E4 | **Scene-change detection** — pixel-diff hash between frames; skip upload if Δ < threshold | Additional 30–50% reduction on top of E3 | Medium |
| E5 | **Image downscale before upload** — resize to 768px max side, JPEG Q=75 before sending | Reduces upload bandwidth 70%; smaller token count in vision API | Low |
| E6 | **On-device lightweight vision pre-filter** — use MobileNet/YOLO-Nano to detect if frame contains "interesting" content (face, text, objects) before paying for cloud vision | Avoid cloud vision for empty/dark/blurry frames | High |
| E7 | **Barge-in / interruption detection** — detect user speaking over TTS response; abort current TTS stream and STT re-activates | Avoids wasted TTS synthesis | Medium |

#### Cloud-side strategies

| ID | Strategy | Estimated Saving | Complexity |
|---|---|---|---|
| C1 | **Query classifier — text vs visual** — classify whether query requires camera context; only include image tokens when needed | 30–60% of vision token cost | Low |
| C2 | **Context window pruning** — keep only last 5 conversation turns + system prompt; drop older turns | Prevents linear cost growth per session | Low |
| C3 | **Tiered model selection** — route simple/factual queries to cheaper text-only model (e.g., Qwen-Turbo); reserve VL model for visual queries | 40–60% overall LLM cost | Medium |
| C4 | **TTS response caching** — cache audio for frequently repeated short responses ("好的", "请稍等", "我不太明白") | 5–15% of TTS cost | Low |
| C5 | **Streaming TTS with early termination** — if user barges in, stop TTS generation immediately | Saves cost on unused tokens | Medium |
| C6 | **Conversation summarization** — after 10+ turns, summarize history into a compact context block rather than keeping raw turns | Reduces input token count for long sessions | Medium |
| C7 | **Image caching by perceptual hash** — if the same frame hash has been sent within last 10 s, reuse the last LLM visual analysis | Near-zero cost for static scenes with repeated queries | Medium |

---

### 5B. What is actually implemented (MVP scope)

The following are confirmed for the initial build:

| ID | Strategy | Implementation Notes |
|---|---|---|
| **E1** | VAD at edge | WebRTC VAD in browser / Flutter plugin; 200 ms windows; speech threshold tunable |
| **E3** | Fixed 1 fps frame capture | Camera captures at 1 fps; no adaptive rate yet |
| **E5** | Image downscale before upload | Resize to max 768px on longest side, JPEG Q=80, before WebSocket send |
| **C1** | Query classifier (rule-based) | Keyword matching for visual intent words ("看看", "这是", "上面写", "识别", "扫一下"); non-matching queries skip the image |
| **C2** | Context window pruning | Always send only last 5 turns to LLM |
| **C4** | TTS caching (partial) | Pre-synthesized MP3s for ~20 common filler phrases stored server-side |

The following are **designed but deferred** to a later iteration:

| ID | Strategy | Reason Deferred |
|---|---|---|
| E2 | Wake-word gate | Requires native SDK integration; added in v1.1 |
| E4 | Scene-change detection | Needs perceptual hash library + tuning; v1.1 |
| E6 | On-device vision pre-filter | Requires on-device model deployment pipeline; v2.0 |
| C3 | Tiered model selection | Needs query complexity scoring; v1.1 |
| C5 | Streaming TTS early termination | Depends on barge-in detection (E7); v1.1 |
| C6 | Conversation summarization | Low priority for short sessions; v1.2 |
| C7 | Image caching by perceptual hash | Nice-to-have; v1.1 |

---

## 6. Voice Fluency Design

The hardest UX problem is making voice feel continuous, not chunky. Key design decisions:

### 6.1 Streaming pipeline (critical)
All three stages stream in parallel — STT output feeds LLM input before the sentence is complete, and LLM output feeds TTS before the paragraph is complete. This is the primary lever for latency.

```
Audio in  ──► STT stream ──► [partial transcript] ──►
                                                      LLM stream ──► [partial response] ──►
                                                                                           TTS stream ──► Audio out
```

Target: first audio playback begins ≤ 1.5 s from end-of-speech detection.

### 6.2 Sentence-boundary chunking for TTS
Do not wait for the full LLM response. Split at natural sentence boundaries (。！？…) and synthesize each chunk independently. Play chunk N while synthesizing chunk N+1.

### 6.3 Filler audio
If LLM latency causes a gap > 800 ms before first sentence, insert a natural filler ("嗯…", "让我想想…") to prevent silence that feels like a system error.

### 6.4 Prosody via SSML
Use iFlytek's SSML support to control:
- Speaking rate (default 1.0×, slow down for reading long text, speed up for short confirmations)
- Pause insertion between logical paragraphs
- Emphasis on key terms

### 6.5 Barge-in
When the user speaks while TTS is playing:
1. Client detects speech via VAD
2. Client immediately sends `barge-in` event over WebSocket
3. Server aborts TTS stream and LLM generation
4. System re-enters listening mode within < 200 ms

---

## 7. Visual Accuracy Design

### 7.1 Frame quality budget
- Minimum 480p capture; 720p preferred
- Avoid heavy compression artifacts: JPEG Q < 70 is too lossy for text recognition
- Stabilize capture: request camera auto-focus lock when user is holding phone steady

### 7.2 When to send a frame
The query classifier uses two signals:
1. **Lexical trigger**: query contains visual-intent vocabulary
2. **Implicit visual context**: if conversation history shows the user has been asking about their environment, default to including the frame

### 7.3 Multi-frame context (future, v1.2)
For dynamic scenes (user walking through a store, etc.), send 3 frames at 2-second intervals instead of 1, letting the LLM reason about motion and change.

### 7.4 Prompt engineering for vision
System prompt instructs Qwen-VL to:
- Prioritize text/characters visible in the image over hallucinated content
- Express uncertainty explicitly ("图片中文字不清晰，我尝试读取为…") rather than confabulating
- Output structured information (ingredient lists, formulas) when recognizing structured content

---

## 8. China Compliance Notes

- All cloud infrastructure hosted in **mainland China regions** (not Hong Kong)
- App must obtain **ICP 备案** before public release
- Voice data storage must comply with **《个人信息保护法》(PIPL)**; do not retain raw audio beyond session duration without explicit user consent
- Camera frames are processed in memory only; not persisted to cloud storage
- Privacy policy must be displayed in-app before first use
- Real-name verification (实名认证) may be required depending on app classification (IM / AI services)

---

## 9. Implementation Roadmap

### v1.0 — MVP
- [x] Flutter client: microphone + camera capture
- [x] Edge VAD (WebRTC VAD)
- [x] 1 fps fixed frame capture + 768px downscale
- [x] FastAPI backend with WebSocket session handling
- [x] iFlytek Real-Time ASR integration (streaming)
- [x] Rule-based query classifier (text vs visual)
- [x] Qwen-VL-Plus integration with 5-turn context window
- [x] iFlytek TTS with sentence-boundary chunking
- [x] Pre-synthesized filler audio
- [x] Common-phrase TTS cache (~20 phrases)

### v1.1 — Cost & UX refinement
- [ ] Scene-change detection (perceptual hash)
- [ ] Adaptive frame rate (0.2 fps static → 2 fps motion)
- [ ] Wake-word gate (Picovoice Porcupine)
- [ ] Tiered model: Qwen-Turbo for text-only, Qwen-VL-Plus for visual
- [ ] Barge-in support + TTS early termination
- [ ] Perceptual-hash image cache (10 s window)

### v1.2 — Intelligence depth
- [ ] Multi-frame context for dynamic scenes
- [ ] Conversation summarization after 10 turns
- [ ] Proactive visual awareness (scene-change triggered, max 1/30 s)
- [ ] SSML prosody tuning per response type
- [ ] GLM-4V as failover for Qwen-VL outages

### v2.0 — On-device intelligence
- [ ] On-device wake word + on-device lightweight vision (MobileNet pre-filter)
- [ ] Optional fully offline mode for supported high-end devices (MiniCPM-V)
- [ ] Streaming latency < 1 s target with edge inference assist
