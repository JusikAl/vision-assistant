"""Prepare SAPI WAV exports for engineering replay; never counted as live acceptance."""
import argparse
import json
import wave
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Directory containing source-0.wav through source-10.wav")
    args = parser.parse_args()
    phrases = ["Начать", "Закончить", "Что впереди?", "Опиши окружение",
               "Не начинай", "Не останавливай", "Как начать работу?",
               "Не надо начинать", "Это начало фильма", "Опиши", "окружение"]
    recordings = []
    for index in range(len(phrases)):
        with wave.open(str(args.directory / f"source-{index}.wav")) as audio:
            assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (1, 2, 16000)
            recordings.append(audio.readframes(audio.getnframes()))
    fixtures = [(f"phrase-{i}", p, recordings[i]) for i, p in enumerate(phrases[:-1])]
    fixtures.append(("paused-describe", phrases[3], recordings[9] + bytes(38400) + recordings[10]))
    fixtures.append(("silence", "(тишина)", bytes(96000)))
    manifest = []
    for name, phrase, pcm in fixtures:
        pcm = (bytes(12800) + pcm + bytes(64000))[:192000]
        path = args.directory / f"{name}.pcm"
        path.write_bytes(pcm)
        manifest.append({"id": name, "expected": phrase,
                         "source": "synthetic; Microsoft Irina Desktop; engineering only",
                         "path": f"/storage/emulated/0/Android/data/com.example.camera/files/vosk72-fixtures/{path.name}"})
    (args.directory / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Prepared {len(manifest)} synthetic fixtures; excluded from live acceptance.")


if __name__ == "__main__":
    main()
