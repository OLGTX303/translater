"""Malay→English translation for the Translater app: NLLB-200 600M, int8, on the CPU.

POST /translate  {"text": "...", "source": "ms"}  ->  {"english": "...", "ms": 312}
GET  /health                                       ->  {"ok": true}

/translate needs `Authorization: Bearer <TOKEN>`; TOKEN comes from the environment.
Rate limiting is done by nginx in front (see translate.olgtx.com.conf).
"""
import hmac
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import ctranslate2
import sentencepiece as spm

MODEL = os.environ.get("MODEL_DIR", "/model")
TOKEN = os.environ["TOKEN"]
MAX_BODY = 16_384
MAX_CHARS = 1_000
# Whisper language codes → NLLB codes. Anything else is read as Malay, the app's language.
NLLB = {"ms": "zsm_Latn", "id": "ind_Latn", "en": "eng_Latn", "jw": "jav_Latn",
        "zh": "zho_Hans", "ta": "tam_Taml", "ar": "arb_Arab", "th": "tha_Thai"}

# ponytail: one model instance, calls serialised by CTranslate2; add inter_threads if lines queue up.
translator = ctranslate2.Translator(MODEL, device="cpu", compute_type="int8", inter_threads=1, intra_threads=3)
sp = spm.SentencePieceProcessor(model_file=os.path.join(MODEL, "sentencepiece.bpe.model"))


def translate(text: str, source: str) -> str:
    tokens = [NLLB.get(source, "zsm_Latn")] + sp.encode(text, out_type=str) + ["</s>"]
    result = translator.translate_batch([tokens], target_prefix=[["eng_Latn"]],
                                        beam_size=2, max_decoding_length=256)
    return sp.decode(result[0].hypotheses[0][1:])   # drop the eng_Latn prefix token


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, {"ok": True})
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/translate":
            return self.reply(404, {"error": "not found"})
        expected = f"Bearer {TOKEN}".encode()
        if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), expected):
            return self.reply(401, {"error": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if not 0 < length <= MAX_BODY:
            return self.reply(413, {"error": "body must be 1..16384 bytes"})
        try:
            body = json.loads(self.rfile.read(length))
            text = str(body["text"]).strip()[:MAX_CHARS]
            source = str(body.get("source") or "ms")
        except (ValueError, KeyError, TypeError):
            return self.reply(400, {"error": 'expected {"text": "..."}'})
        if not text:
            return self.reply(400, {"error": "empty text"})
        started = time.monotonic()
        english = translate(text, source)
        self.reply(200, {"english": english, "ms": round((time.monotonic() - started) * 1000)})

    def reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        pass   # never log request text


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8700), Handler).serve_forever()
