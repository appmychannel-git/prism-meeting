#!/usr/bin/env python3
"""
저장된 회의록(원문) 파일을 읽어, 각 줄 아래에 엔진별(Google/Azure) 번역을
붙인 새 파일을 만든다. 이미 끝난 회의의 텍스트를 사후 번역할 때 사용.

입력 형식(stt_poc.py 가 저장한 형태):
  [15:28:32] wonny lee (en): Please send the agenda by email.

출력(예, --to ko):
  [15:28:32] wonny lee (en): Please send the agenda by email.
      [Google→ko] 안건을 이메일로 보내주세요.
      [Azure→ko] 안건을 이메일로 보내 주세요.

사용:
  python translate_transcript.py transcripts/파일.txt --to ko
  python translate_transcript.py transcripts/파일.txt --to ko --engines google,azure
  python translate_transcript.py transcripts/파일.txt --to ko,en

번역은 앱과 동일한 토큰서버 /translate 를 호출한다(.env 의 TRANSLATE_URL, 없으면 기본값).
"""
import argparse
import asyncio
import os
import re

import aiohttp

try:
    from dotenv import load_dotenv
    load_dotenv()
except Exception:
    pass

TRANSLATE_URL = os.environ.get(
    "TRANSLATE_URL", "https://prism-token-server.onrender.com/translate")

# [시각] 화자 (lang): 텍스트
LINE_RE = re.compile(r"^\[(\d{2}:\d{2}:\d{2})\]\s+(.*?)\s+\(([a-z]{2})\):\s?(.*)$")

ENGINE_LABEL = {"google": "Google", "azure": "Azure", "deepl": "DeepL"}


async def translate(session, text, target, provider):
    payload = {"text": text, "target": target, "provider": provider}
    try:
        async with session.post(TRANSLATE_URL, json=payload,
                                timeout=aiohttp.ClientTimeout(total=20)) as r:
            if r.status != 200:
                return f"(HTTP {r.status})"
            data = await r.json()
            return (data.get("translatedText") or "").strip() or "(빈 응답)"
    except Exception as e:
        return f"(오류: {e})"


async def run(path, targets, engines):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    out_lines = []
    total = 0
    async with aiohttp.ClientSession() as session:
        for raw in lines:
            line = raw.rstrip("\n")
            m = LINE_RE.match(line)
            out_lines.append(line)
            if not m:
                continue  # 헤더(#)·빈 줄 등은 그대로
            _ts, _sender, lang, text = m.groups()
            if not text.strip():
                continue
            for target in targets:
                if target == lang:
                    continue  # 원문이 이미 그 언어면 건너뜀
                for eng in engines:
                    tr = await translate(session, text, target, eng)
                    label = ENGINE_LABEL.get(eng, eng)
                    out_lines.append(f"      [{label}→{target}] {tr}")
                    total += 1
            print(".", end="", flush=True)

    base, ext = os.path.splitext(path)
    suffix = "_".join(targets)
    out_path = f"{base}_{suffix}{ext or '.txt'}"
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(out_lines) + "\n")
    print(f"\n완료: {total}건 번역 → {os.path.abspath(out_path)}")


def main():
    ap = argparse.ArgumentParser(description="회의록 사후 번역(엔진별)")
    ap.add_argument("file", help="원문 회의록 .txt 경로")
    ap.add_argument("--to", default="ko",
                    help="번역 대상 언어(쉼표). 예: ko  또는  ko,en")
    ap.add_argument("--engines", default="google,azure",
                    help="번역 엔진(쉼표). 예: google,azure  (deepl 준비되면 추가)")
    args = ap.parse_args()
    targets = [s.strip() for s in args.to.split(",") if s.strip()]
    engines = [s.strip() for s in args.engines.split(",") if s.strip()]
    if not os.path.isfile(args.file):
        raise SystemExit(f"파일이 없습니다: {args.file}")
    asyncio.run(run(args.file, targets, engines))


if __name__ == "__main__":
    main()
