#!/usr/bin/env python3
"""
회의 녹화 PoC — LiveKit Room Composite Egress로 회의(그리드 화면+화면공유+오디오)를
MP4로 녹화해 Azure Blob Storage에 저장한다. 앱 수정 없이 스크립트로 시작/종료만 한다.

동작:
  start  : 지정한 방을 그리드 레이아웃 MP4로 녹화 시작 → Azure Blob에 업로드
  stop   : 그 방의 진행 중 녹화를 종료(egress-id 직접 지정도 가능)
  list   : 진행 중인 녹화 목록

주의(보안): 키는 코드/채팅에 넣지 말 것. .env 또는 환경변수로만 주입.
  필요한 값: LIVEKIT_URL/API_KEY/API_SECRET,
            AZURE_STORAGE_ACCOUNT, AZURE_STORAGE_KEY, AZURE_STORAGE_CONTAINER

사용 예:
  python record.py start --room abc-def
  python record.py stop  --room abc-def
  python record.py list
"""
import argparse
import asyncio
import os

from livekit import api

try:
    from dotenv import load_dotenv
    load_dotenv()  # 같은 폴더의 .env 자동 로드(STT 봇과 공유)
except Exception:
    pass

LIVEKIT_URL = os.environ.get("LIVEKIT_URL", "")
LIVEKIT_API_KEY = os.environ.get("LIVEKIT_API_KEY", "")
LIVEKIT_API_SECRET = os.environ.get("LIVEKIT_API_SECRET", "")
AZURE_STORAGE_ACCOUNT = os.environ.get("AZURE_STORAGE_ACCOUNT", "")
AZURE_STORAGE_KEY = os.environ.get("AZURE_STORAGE_KEY", "")
AZURE_STORAGE_CONTAINER = os.environ.get("AZURE_STORAGE_CONTAINER", "recordings")
# 저장 경로 템플릿. {room_name},{time} 은 LiveKit이 치환. 컨테이너 안 상대경로.
FILE_TEMPLATE = os.environ.get(
    "RECORD_FILE_TEMPLATE", "{room_name}/{room_name}-{time}.mp4")


def _http_url() -> str:
    return LIVEKIT_URL.replace("wss://", "https://").replace("ws://", "http://")


def _lkapi() -> "api.LiveKitAPI":
    return api.LiveKitAPI(url=_http_url(), api_key=LIVEKIT_API_KEY,
                          api_secret=LIVEKIT_API_SECRET)


def _check_env(need_azure: bool):
    req = {
        "LIVEKIT_URL": LIVEKIT_URL,
        "LIVEKIT_API_KEY": LIVEKIT_API_KEY,
        "LIVEKIT_API_SECRET": LIVEKIT_API_SECRET,
    }
    if need_azure:
        req["AZURE_STORAGE_ACCOUNT"] = AZURE_STORAGE_ACCOUNT
        req["AZURE_STORAGE_KEY"] = AZURE_STORAGE_KEY
        req["AZURE_STORAGE_CONTAINER"] = AZURE_STORAGE_CONTAINER
    missing = [k for k, v in req.items() if not v]
    if missing:
        raise SystemExit(f"환경변수 없음: {', '.join(missing)} (.env에 설정하세요)")


async def start(room: str, layout: str, audio_only: bool):
    _check_env(need_azure=True)
    lk = _lkapi()
    try:
        # 영상+음성 = MP4 / 음성만 = MP3(파일 확장자도 맞춤).
        base = FILE_TEMPLATE.rsplit(".", 1)[0]
        if audio_only:
            file_type = api.EncodedFileType.MP3
            filepath = base + ".mp3"
        else:
            file_type = api.EncodedFileType.MP4
            filepath = base + ".mp4"
        file_out = api.EncodedFileOutput(
            file_type=file_type,
            filepath=filepath,
            azure=api.AzureBlobUpload(
                account_name=AZURE_STORAGE_ACCOUNT,
                account_key=AZURE_STORAGE_KEY,
                container_name=AZURE_STORAGE_CONTAINER,
            ),
        )
        req = api.RoomCompositeEgressRequest(
            room_name=room,
            layout=layout,          # grid | speaker | single-speaker ...
            audio_only=audio_only,  # True면 오디오만(비용 저렴)
            file_outputs=[file_out],
        )
        info = await lk.egress.start_room_composite_egress(req)
        print("녹화 시작됨")
        print("  egress_id :", info.egress_id)
        print("  room      :", room)
        print("  형식      :", "음성만(MP3)" if audio_only else f"영상+음성(MP4, {layout})")
        print("  저장 경로 :", f"{AZURE_STORAGE_CONTAINER}/{filepath}")
        print("  종료      : python record.py stop --room", room)
    finally:
        await lk.aclose()


async def stop(room: str, egress_id: str):
    _check_env(need_azure=False)
    lk = _lkapi()
    try:
        ids = [egress_id] if egress_id else []
        if not ids:
            resp = await lk.egress.list_egress(
                api.ListEgressRequest(room_name=room, active=True))
            ids = [e.egress_id for e in resp.items]
            if not ids:
                print(f"진행 중인 녹화가 없습니다 (room={room})")
                return
        for eid in ids:
            await lk.egress.stop_egress(api.StopEgressRequest(egress_id=eid))
            print("녹화 종료 요청:", eid, "→ 잠시 후 Azure Blob에 파일 업로드 완료됩니다")
    finally:
        await lk.aclose()


async def list_active(room: str):
    _check_env(need_azure=False)
    lk = _lkapi()
    try:
        kwargs = {"active": True}
        if room:
            kwargs["room_name"] = room
        resp = await lk.egress.list_egress(api.ListEgressRequest(**kwargs))
        if not resp.items:
            print("진행 중인 녹화 없음")
            return
        for e in resp.items:
            print(f"- {e.egress_id}  room={e.room_name}  status={api.EgressStatus.Name(e.status)}")
    finally:
        await lk.aclose()


def main():
    ap = argparse.ArgumentParser(description="회의 녹화 PoC (LiveKit Egress → Azure Blob)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_start = sub.add_parser("start", help="녹화 시작")
    p_start.add_argument("--room", required=True, help="회의 방 코드")
    p_start.add_argument("--layout", default="grid",
                         help="레이아웃: grid(기본)/speaker 등")
    p_start.add_argument("--audio-only", action="store_true",
                         help="오디오만 녹음(비용 저렴)")

    p_stop = sub.add_parser("stop", help="녹화 종료")
    p_stop.add_argument("--room", default="", help="이 방의 진행 중 녹화 종료")
    p_stop.add_argument("--egress-id", default="", help="특정 egress만 종료")

    p_list = sub.add_parser("list", help="진행 중 녹화 목록")
    p_list.add_argument("--room", default="", help="특정 방만")

    args = ap.parse_args()
    if args.cmd == "start":
        asyncio.run(start(args.room, args.layout, args.audio_only))
    elif args.cmd == "stop":
        if not args.room and not args.egress_id:
            ap.error("stop 에는 --room 또는 --egress-id 가 필요합니다.")
        asyncio.run(stop(args.room, args.egress_id))
    elif args.cmd == "list":
        asyncio.run(list_active(args.room))


if __name__ == "__main__":
    main()
