#!/bin/sh
# Regenerates SelfTest/fast200.mp3: SelfTest/fast.txt (193 Malay words) read at ~200 words per minute.
# The speed test (Settings → Speed test) plays it through the live pipeline. The audio isn't committed
# because it's synthesised by Microsoft's edge-tts voices; run this once before building.
set -e
cd "$(dirname "$0")"
python3 -m pip install --user -q edge-tts
python3 -m edge_tts --voice ms-MY-OsmanNeural --rate=+55% -f fast.txt --write-media fast200.mp3
echo "wrote $(pwd)/fast200.mp3"
