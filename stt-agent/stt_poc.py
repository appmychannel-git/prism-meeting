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
from datetime import datetime

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
# 인식 후보 언어(자동 감지). 쉼표로 최대 4개. 예: "en-US,ko-KR,ru-RU"
STT_CANDIDATES = [s.strip() for s in os.environ.get("STT_CANDIDATES", "en-US,ko-KR,ru-RU").split(",") if s.strip()]
# 자막봇을 숨김 참가자로(다른 참가자 목록/타일에 안 보이게). 데이터 발행은 그대로 됨.
AGENT_HIDDEN = os.environ.get("AGENT_HIDDEN", "true").lower() != "false"
# 회의록(자막 텍스트) 저장. 방마다 파일 1개, 확정 문장이 나올 때마다 즉시 append.
SAVE_TRANSCRIPT = os.environ.get("SAVE_TRANSCRIPT", "true").lower() != "false"
TRANSCRIPT_DIR = os.environ.get("TRANSCRIPT_DIR", "transcripts")

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
        hidden=AGENT_HIDDEN,  # 숨김: 참가자 목록/타일에 안 보임(데이터는 계속 발행)
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
                 participant: rtc.RemoteParticipant, track: rtc.Track,
                 transcript_path: str | None = None):
        self.room = room
        self.loop = loop
        self.participant = participant
        self.track = track
        self.transcript_path = transcript_path
        self.sender_name = participant.name or participant.identity
        self._last_interim = 0.0
        self._closed = False

        # Azure 인식기 구성(푸시 스트림 입력).
        speech_config = speechsdk.SpeechConfig(subscription=AZURE_SPEECH_KEY, region=AZURE_SPEECH_REGION)
        fmt = speechsdk.audio.AudioStreamFormat(samples_per_second=TARGET_SR, bits_per_sample=16, channels=1)
        self._push = speechsdk.audio.PushAudioInputStream(stream_format=fmt)
        audio_config = speechsdk.audio.AudioConfig(stream=self._push)

        if len(STT_CANDIDATES) > 1:
            # 연속 언어감지: 발화 도중 언어가 바뀌어도(영→한 등) 따라가게.
            # (기본값은 '시작 시 1회'라 한 번 잡힌 언어로 고정됨)
            speech_config.set_property(
                property_id=speechsdk.PropertyId.SpeechServiceConnection_LanguageIdMode,
                value="Continuous")
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
            "speaker": self.participant.identity,  # 실제 화자 식별자(클라 그룹핑용)
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

        # 확정 문장만 회의록 파일에 즉시 기록(중간에 꺼져도 안전).
        if final and self.transcript_path:
            try:
                ts = datetime.now().strftime("%H:%M:%S")
                with open(self.transcript_path, "a", encoding="utf-8") as f:
                    f.write(f"[{ts}] {self.sender_name} ({lang}): {text}\n")
            except Exception as e:
                log.warning("회의록 기록 실패: %s", e)

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


def _check_env():
    for k, v in {
        "LIVEKIT_URL": LIVEKIT_URL, "LIVEKIT_API_KEY": LIVEKIT_API_KEY,
        "LIVEKIT_API_SECRET": LIVEKIT_API_SECRET, "AZURE_SPEECH_KEY": AZURE_SPEECH_KEY,
        "AZURE_SPEECH_REGION": AZURE_SPEECH_REGION,
    }.items():
        if not v:
            raise SystemExit(f"환경변수 {k} 가 없습니다. .env 또는 환경변수로 설정하세요.")


class RoomSession:
    """방 1개에 자막봇으로 접속해서, 참가자 오디오 트랙마다 Azure STT를 붙인다."""

    def __init__(self, room_name: str, loop: asyncio.AbstractEventLoop):
        self.room_name = room_name
        self.loop = loop
        self.room = rtc.Room()
        self.transcribers: dict[str, TrackTranscriber] = {}
        self.transcript_path: str | None = None

        @self.room.on("track_subscribed")
        def on_track_subscribed(track, publication, participant):
            if track.kind == rtc.TrackKind.KIND_AUDIO and participant.identity != BOT_IDENTITY:
                self.transcribers[publication.sid] = TrackTranscriber(
                    self.room, self.loop, participant, track,
                    transcript_path=self.transcript_path)

        @self.room.on("track_unsubscribed")
        def on_track_unsubscribed(track, publication, participant):
            t = self.transcribers.pop(publication.sid, None)
            if t:
                asyncio.create_task(t.aclose())

    def _init_transcript(self):
        """방 접속 시 회의록 파일 준비(파일명: <방>_<날짜시각>.txt). 헤더 한 줄 기록."""
        if not SAVE_TRANSCRIPT:
            return
        try:
            os.makedirs(TRANSCRIPT_DIR, exist_ok=True)
            safe = "".join(ch if ch.isalnum() or ch in "-_" else "_"
                           for ch in self.room_name)
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            self.transcript_path = os.path.join(TRANSCRIPT_DIR, f"{safe}_{stamp}.txt")
            with open(self.transcript_path, "a", encoding="utf-8") as f:
                f.write(f"# 회의록 room={self.room_name} 시작={datetime.now():%Y-%m-%d %H:%M:%S}\n")
            log.info("회의록 저장 위치: %s", os.path.abspath(self.transcript_path))
        except Exception as e:
            log.warning("회의록 파일 준비 실패(저장 생략): %s", e)
            self.transcript_path = None

    async def connect(self):
        self._init_transcript()
        token = build_token(self.room_name)
        log.info("LiveKit 연결: %s (room=%s)", LIVEKIT_URL, self.room_name)
        await self.room.connect(LIVEKIT_URL, token)

    async def close(self):
        for t in list(self.transcribers.values()):
            await t.aclose()
        self.transcribers.clear()
        try:
            await self.room.disconnect()
        except Exception:
            pass


async def run_single(room_name: str):
    """한 방에만 붙는 모드(--room). 방코드를 미리 알 때."""
    _check_env()
    loop = asyncio.get_running_loop()
    session = RoomSession(room_name, loop)
    await session.connect()
    log.info("연결됨. 언어 후보=%s. 참가자가 말하면 자막을 발행합니다. (Ctrl+C 종료)", STT_CANDIDATES)
    stop = asyncio.Event()
    try:
        await stop.wait()
    finally:
        await session.close()


async def run_watch(poll_sec: float):
    """감시 모드(--watch). 상시 켜두면 새 방이 생길 때마다 자동으로 자막을 시작하고,
    방이 비면 자동으로 정리한다. 방코드를 몰라도 됨."""
    _check_env()
    loop = asyncio.get_running_loop()
    http_url = LIVEKIT_URL.replace("wss://", "https://").replace("ws://", "http://")
    lkapi = api.LiveKitAPI(url=http_url, api_key=LIVEKIT_API_KEY, api_secret=LIVEKIT_API_SECRET)
    active: dict[str, RoomSession] = {}

    log.info("감시 모드 시작: %ds 마다 방 확인. 참가자 있는 방에 자동으로 자막을 붙입니다. (Ctrl+C 종료)", poll_sec)
    try:
        while True:
            try:
                resp = await lkapi.room.list_rooms(api.ListRoomsRequest())
                # 실제 사람이 있는 방만(봇은 hidden이라 num_participants에 안 잡힘)
                live = {r.name for r in resp.rooms if r.num_participants > 0}
            except Exception as e:
                log.warning("방 목록 조회 실패(재시도): %s", e)
                await asyncio.sleep(poll_sec)
                continue

            for name in live - set(active):
                try:
                    session = RoomSession(name, loop)
                    await session.connect()
                    active[name] = session
                    log.info("＋ 새 방 감지 → 자막 시작: %s", name)
                except Exception as e:
                    log.warning("방 접속 실패(%s): %s", name, e)

            for name in set(active) - live:
                session = active.pop(name)
                await session.close()
                log.info("－ 방 종료 → 자막 중지: %s", name)

            await asyncio.sleep(poll_sec)
    finally:
        for session in list(active.values()):
            await session.close()
        await lkapi.aclose()


def main():
    ap = argparse.ArgumentParser(description="서버측 STT PoC (LiveKit + Azure Speech)")
    ap.add_argument("--room", help="자막을 붙일 회의 방 코드(참가자와 동일한 방)")
    ap.add_argument("--watch", action="store_true",
                    help="상시 감시 모드: 새 방이 생기면 자동으로 자막 시작(방코드 불필요)")
    ap.add_argument("--poll", type=float, default=5.0,
                    help="감시 모드에서 방 확인 주기(초, 기본 5)")
    args = ap.parse_args()
    if not args.watch and not args.room:
        ap.error("--room <방코드> 또는 --watch 중 하나가 필요합니다.")
    try:
        if args.watch:
            asyncio.run(run_watch(args.poll))
        else:
            asyncio.run(run_single(args.room))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
