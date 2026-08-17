import argparse
import json
import os
import sys

import soundfile as sf
from kokoro_onnx import Kokoro


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--voices", required=True)
    parser.add_argument("--voice", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--speed", type=float, default=1.0)
    args = parser.parse_args()

    request = json.load(sys.stdin)
    text = str(request.get("text", "")).strip()
    if not text:
        raise ValueError("No text was provided for speech synthesis.")

    kokoro = Kokoro(args.model, args.voices)
    samples, sample_rate = kokoro.create(
        text,
        voice=args.voice,
        speed=max(0.75, min(args.speed, 1.25)),
        lang="en-us",
    )
    sf.write(args.output, samples, sample_rate)
    print(json.dumps({"status": "ok", "audio_file": os.path.abspath(args.output)}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"status": "error", "message": str(error)}), file=sys.stderr)
        sys.exit(1)
