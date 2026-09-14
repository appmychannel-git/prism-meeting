#!/usr/bin/env python3
"""
서버측 STT PoC — LiveKit 방에 '자막봇'으로 참가해 참가자 오디오를 Azure Speech로
받아쓰기(STT)하고, 그 텍스트를 기존 앱과 동일한 형식으로 데이터채널에 발행한다.

목적: TV·셋톱·저가 태블릿처럼 기기 자체 음성인식이 없는 곳에서도 자막이 되게 하는
      "서버측 STT"가 우리 지연/정확도/비용 기준에 맞는지 검증(PoC).

핵심 설계 — 클라이언트 무변경:
  앱은 이미 topic 'caption' 으로 온 JSON {sender, text, lang, final} 을 자막으로 표시한다
  (room_screen.dart 의 _onCaptionReceived). 이 봇이 "또 한 명의 참가자"로서 같은 형식으로
  쏘면, 앱은 코드 수정 없이 그대로 자막을 그린다.

동작:
  1) LIVEKIT_API_KEY/SECRET 으로 이 봇의 접속 토큰을 직접 발급(= 서버 없이 붙음)
  2) 지정한 방(--room)에 참가 → 원격 참가자 오디오 트랙 구독
  3) 트랙마다 Azure 연속 인식기 1개 → recognizing(중간)/recognized(확정) 이벤트
  4) 결과를 topic 'caption' 으로 publish (중간=비신뢰, 확정=신뢰)

주의(보안): 키는 절대 코드/채팅에 넣지 말 것. .env 또는 환경변수로만 주입.
"""
import argparse
import asyncio
import json
import logging
import os
import time

from livekit import rtc, api
import azure.cognitiveservices.speech as speechsdk

try:
    from dotenv import load_dotenv
    load_dotenv()  # 같은 폴더의 .env 자동 로드(있으면)
except Exception:
    pass

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("stt-poc")

# ── 환경설정 ────────────────────────────────────────────────────────────────
LIVEKIT_URL = os.environ.get("LIVEKIT_URL", "")           # wss://<프로젝트>.livekit.cloud
LIVEKIT_API_KEY = os.environ.get("LIVEKIT_API_KEY", "")
LIVEKIT_API_SECRET = os.environ.get("LIVEKIT_API_SECRET", "")
AZURE_SPEECH_KEY = os.environ.get("AZURE_SPEECH_KEY", "")
AZURE_SPEECH_REGION = os.environ.get("AZURE_SPEECH_REGION", "")  # 예: koreacentral, eastus
# 인식 후보 언어(자동 감지). 쉼표로 최대 4개. 예: "ko-KR,kk-KZ,ru-RU,en-US"
STT_CANDIDATES = [s.strip() for s in os.environ.get("STT_CANDIDATES", "ko-KR").split(",") if s.strip()]

CAPTION_TOPIC = "caption"      # 앱과 반드시 동일해야 함(room_screen.dart _captionTopic)
BOT_IDENTITY = "captions-bot"
BOT_NAME = "자막"
TARGET_SR = 16000              # Azure 입력용으로 16kHz 모노 리샘플
INTERIM_THROTTLE_MS = 300      # 중간 결과 발행 최소 간격(데이터/비용 절약)


def _lang2(locale: str) -> str:
    """Azure 로케일(ko-KR) → 앱 언어코드(ko)."""
    return (locale or "").split("-")[0].lower()


def build_token(room: str) -> str:
    """이 봇의 방 참가 토큰을 직접 발급(구독+데이터발행 권한)."""
    grant = api.VideoGrants(
        room_join=True, room=room,
        can_subscribe=True, can_publish=True, can_publish_data=True,
    )
    return (
        api.AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
        .with_identity(BOT_IDENTITY)
        .with_name(BOT_NAME)
        .with_grants(grant)
        .to_jwt()
    )


class TrackTranscriber:
    """원격 참가자 1명의 오디오 트랙 → Azure 연속 인식 → caption 발행."""

    def __init__(self, room: rtc.Room, loop: asyncio.AbstractEventLoop,
                 participant: rtc.RemoteParticipant, track: rtc.Track):
        self.room = room
        self.loop = loop
        self.participant = participant
        self.track = track
        self.sender_name = participant.name or participant.identity
        self._last_interim = 0.0
        self._closed = False

        # Azure 인식기 구성(푸시 스트림 입력).
        speech_config = speechsdk.SpeechConfig(subscription=AZURE_SPEECH_KEY, region=AZURE_SPEECH_REGION)
        fmt = speechsdk.audio.AudioStreamFormat(samples_per_second=TARGET_SR, bits_per_sample=16, channels=1)
        self._push = speechsdk.audio.PushAudioInputStream(stream_format=fmt)
        audio_config = speechsdk.audio.AudioConfig(stream=self._push)

        if len(STT_CANDIDATES) > 1:
            # 다국어 자동 감지(최대 4개 후보)
            auto_cfg = speechsdk.languageconfig.AutoDetectSourceLanguageConfig(languages=STT_CANDIDATES)
            self._rec = speechsdk.SpeechRecognizer(
                speech_config=speech_config,
                auto_detect_source_language_config=auto_cfg,
                audio_config=audio_config,
            )
        else:
            speech_config.speech_recognition_language = STT_CANDIDATES[0]
            self._rec = speechsdk.SpeechRecognizer(speech_config=speech_config, audio_config=audio_config)

        self._rec.recognizing.connect(self._on_recognizing)   # 중간 결과(부분)
        self._rec.recognized.connect(self._on_recognized)     # 확정 결과(문장)
        self._rec.canceled.connect(lambda evt: log.warning("Azure canceled: %s", evt))
        self._rec.start_continuous_recognition_async()
        log.info("▶ transcriber 시작: %s (%s)", self.sender_name, self.participant.identity)

        self._task = asyncio.create_task(self._pump_audio())

    async def _pump_audio(self):
        """LiveKit 오디오 프레임을 16kHz 모노로 받아 Azure 푸시 스트림에 밀어넣는다."""
        stream = rtc.AudioStream(self.track, sample_rate=TARGET_SR, num_channels=1)
        try:
            async for ev in stream:
                if self._closed:
                    break
                # ev.frame.data: int16 PCM (memoryview) → bytes
                self._push.write(bytes(ev.frame.data))
        except Exception as e:
            log.warning("audio pump 종료(%s): %s", self.sender_name, e)
        finally:
            await stream.aclose()

    def _detected_lang(self, result) -> str:
        try:
            if len(STT_CANDIDATES) > 1:
                auto = speechsdk.AutoDetectSourceLanguageResult(result)
                return _lang2(auto.language) or _lang2(STT_CANDIDATES[0])
        except Exception:
            pass
        return _lang2(STT_CANDIDATES[0])

    def _on_recognizing(self, evt):
        text = (evt.result.text or "").strip()
        if not text:
            return
        now = time.monotonic() * 1000
        if now - self._last_interim < INTERIM_THROTTLE_MS:
            return
        self._last_interim = now
        self._publish(text, self._detected_lang(evt.result), final=False)

    def _on_recognized(self, evt):
        if evt.result.reason != speechsdk.ResultReason.RecognizedSpeech:
            return
        text = (evt.result.text or "").strip()
        if not text:
            return
        self._publish(text, self._detected_lang(evt.result), final=True)

    def _publish(self, text: str, lang: str, final: bool):
        """앱과 동일한 형식으로 caption 토픽에 발행(스레드→루프 안전 전달)."""
        payload = json.dumps({
            "sender": self.sender_name,
            "text": text,
            "lang": lang,
            "final": final,
        }).encode("utf-8")

        async def _send():
            try:
                await self.room.local_participant.publish_data(
                    payload, reliable=final, topic=CAPTION_TOPIC,
                )
            except Exception as e:
                log.warning("publish 실패: %s", e)

        # Azure 콜백은 SDK 스레드에서 실행되므로 메인 asyncio 루프로 넘긴다.
        asyncio.run_coroutine_threadsafe(_send(), self.loop)
        log.info("  %s[%s] %s: %s", "★" if final else "·", lang, self.sender_name, text)

    async def aclose(self):
        self._closed = True
        try:
            self._rec.stop_continuous_recognition_async()
        except Exception:
            pass
        try:
            self._push.close()
        except Exception:
            pass


async def run(room_name: str):
    for k, v in {
        "LIVEKIT_URL": LIVEKIT_URL, "LIVEKIT_API_KEY": LIVEKIT_API_KEY,
        "LIVEKIT_API_SECRET": LIVEKIT_API_SECRET, "AZURE_SPEECH_KEY": AZURE_SPEECH_KEY,
        "AZURE_SPEECH_REGION": AZURE_SPEECH_REGION,
    }.items():
        if not v:
            raise SystemExit(f"환경변수 {k} 가 없습니다. .env 또는 환경변수로 설정하세요.")

    loop = asyncio.get_running_loop()
    room = rtc.Room()
    transcribers: dict[str, TrackTranscriber] = {}

    @room.on("track_subscribed")
    def on_track_subscribed(track, publication, participant):
        if track.kind == rtc.TrackKind.KIND_AUDIO and participant.identity != BOT_IDENTITY:
            transcribers[publication.sid] = TrackTranscriber(room, loop, participant, track)

    @room.on("track_unsubscribed")
    def on_track_unsubscribed(track, publication, participant):
        t = transcribers.pop(publication.sid, None)
        if t:
            asyncio.create_task(t.aclose())

    token = build_token(room_name)
    log.info("LiveKit 연결: %s (room=%s)", LIVEKIT_URL, room_name)
    await room.connect(LIVEKIT_URL, token)
    log.info("연결됨. 언어 후보=%s. 참가자가 말하면 자막을 발행합니다. (Ctrl+C 종료)", STT_CANDIDATES)

    stop = asyncio.Event()
    try:
        await stop.wait()
    finally:
        for t in list(transcribers.values()):
            await t.aclose()
        await room.disconnect()


def main():
    ap = argparse.ArgumentParser(description="서버측 STT PoC (LiveKit + Azure Speech)")
    ap.add_argument("--room", required=True, help="자막을 붙일 회의 방 코드(참가자와 동일한 방)")
    args = ap.parse_args()
    try:
        asyncio.run(run(args.room))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
