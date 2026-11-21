"""On-demand local Ollama client. No model, camera or image files are owned here."""
import asyncio
import base64
import io
import ipaddress
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

import httpx
from fastapi import HTTPException
from PIL import Image, ImageOps, UnidentifiedImageError

PROMPT = (Path(__file__).parent / "prompts" / "scene_description.txt").read_text(encoding="utf-8")
UNAVAILABLE = "Подробное описание сейчас недоступно"


@dataclass(frozen=True)
class VlmSettings:
    ollama_url: str = "http://127.0.0.1:11434"
    model: str = "qwen3-vl:2b-instruct"
    timeout_seconds: float = 45
    max_image_bytes: int = 768 * 1024
    max_pixels: int = 4_194_304
    max_dimension: int = 768
    max_description: int = 600
    num_ctx: int = 2048
    num_predict: int = 160
    allowed_networks: str = "127.0.0.0/8,::1/128"

    def __post_init__(self):
        url = urlparse(self.ollama_url)
        if url.scheme != "http" or url.hostname not in ("localhost", "127.0.0.1", "::1") or url.username or url.password:
            raise ValueError("Ollama must use a local loopback HTTP endpoint")
        if self.model != "qwen3-vl:2b-instruct":
            raise ValueError("TZ8 requires the measured local qwen3-vl:2b-instruct model")
        if not 1 <= self.timeout_seconds <= 180 or not 1 <= self.max_image_bytes <= 768 * 1024:
            raise ValueError("Invalid VLM resource limits")
        if not 128 <= self.max_dimension <= 768 or not 1 <= self.num_predict <= 160:
            raise ValueError("Invalid VLM image/token limits")

    @classmethod
    def from_env(cls):
        return cls(ollama_url=os.getenv("OLLAMA_BASE_URL", cls.ollama_url),
                   timeout_seconds=float(os.getenv("VLM_TIMEOUT_SECONDS", "45")),
                   max_dimension=int(os.getenv("VLM_MAX_DIMENSION", "768")),
                   num_ctx=int(os.getenv("VLM_NUM_CTX", "2048")),
                   num_predict=int(os.getenv("VLM_NUM_PREDICT", "160")),
                   allowed_networks=os.getenv("VLM_ALLOWED_NETWORKS", cls.allowed_networks))


def prepare_jpeg(data: bytes, settings: VlmSettings) -> tuple[bytes, tuple[int, int]]:
    if not data or len(data) > settings.max_image_bytes:
        raise HTTPException(413 if data else 400, "JPEG size limit exceeded" if data else "Empty JPEG")
    try:
        with Image.open(io.BytesIO(data)) as image:
            if image.format != "JPEG" or image.width * image.height > settings.max_pixels:
                raise ValueError("Expected a bounded JPEG")
            image.verify()
        with Image.open(io.BytesIO(data)) as image:
            image.load()
            image = ImageOps.exif_transpose(image).convert("RGB")
            image.thumbnail((settings.max_dimension, settings.max_dimension))
            output = io.BytesIO()
            image.save(output, "JPEG", quality=85)
            return output.getvalue(), image.size
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError) as error:
        raise HTTPException(400, "Invalid JPEG") from error


def checked_description(text: str, limit: int) -> str:
    text = " ".join(text.split())
    if not text or len(text) > limit or not re.search("[а-яА-ЯёЁ]", text):
        raise HTTPException(503, "Model returned an invalid description")
    # Defense in depth, not a factual correctness guarantee. Reject, do not
    # silently rewrite navigation advice into an apparently trustworthy answer.
    unsafe = (r"(?:путь|проход|дорога).{0,35}(?:свобод|безопас)",
              r"\b(?:идите|пройдите|шагните|поверните|двигайтесь|переходите)\b",
              r"\bможно\s+(?:идти|пройти|двигаться)", r"\d+(?:[.,]\d+)?\s*(?:метр|м\b)")
    if any(re.search(pattern, text, re.I) for pattern in unsafe):
        raise HTTPException(503, "Model returned navigation advice")
    if not re.match(r"На (?:снимке|момент съ[её]мки)", text, re.I):
        text = "На снимке: " + text[0].lower() + text[1:]
    if len(text) > limit:
        raise HTTPException(503, "Model returned an oversized description")
    return text


class VlmService:
    def __init__(self, settings=None, transport=None):
        self.settings = settings or VlmSettings.from_env()
        self.transport = transport
        self.jobs = {}  # request_id -> (owning LAN address, task)
        self._lock = asyncio.Lock()

    async def describe(self, *, image, question, request_id, captured_at, owner):
        if self._lock.locked():
            raise HTTPException(429, "VLM busy", headers={"Retry-After": "1"})
        async with self._lock:
            task = asyncio.current_task()
            self.jobs[request_id] = (owner, task)
            started = time.perf_counter()
            try:
                async with asyncio.timeout(self.settings.timeout_seconds):
                    prepared_at = time.perf_counter()
                    jpeg, size = await asyncio.to_thread(prepare_jpeg, image, self.settings)
                    preprocess_ms = (time.perf_counter() - prepared_at) * 1000
                    payload = {
                        "model": self.settings.model, "stream": False, "keep_alive": "10m",
                        "messages": [{"role": "system", "content": PROMPT},
                                     {"role": "user", "content": question,
                                      "images": [base64.b64encode(jpeg).decode("ascii")]}],
                        "options": {"temperature": 0.15, "seed": 7, "num_ctx": self.settings.num_ctx,
                                    "num_predict": self.settings.num_predict},
                    }
                    async with httpx.AsyncClient(transport=self.transport, timeout=self.settings.timeout_seconds, trust_env=False) as client:
                        response = await client.post(self.settings.ollama_url.rstrip("/") + "/api/chat", json=payload)
                        if response.status_code != 200:
                            raise HTTPException(503, UNAVAILABLE)
                        data = response.json()
                    if data.get("done") is not True or data.get("done_reason") == "length":
                        raise HTTPException(503, "Incomplete model response")
                    text = checked_description(data["message"]["content"], self.settings.max_description)
                    return {"request_id": request_id, "status": "success", "description": text,
                            "model": self.settings.model, "captured_at": captured_at.isoformat(),
                            "processing_ms": round((time.perf_counter() - started) * 1000, 2),
                            "preprocessing_ms": round(preprocess_ms, 2), "image_width": size[0], "image_height": size[1],
                            "timings": {key.removesuffix("_duration") + "_ms": round(data.get(key, 0) / 1e6, 2)
                                        for key in ("load_duration", "prompt_eval_duration", "eval_duration", "total_duration")}}
            except (TimeoutError, httpx.TimeoutException) as error:
                raise HTTPException(504, "VLM timeout") from error
            except (httpx.HTTPError, ValueError, KeyError, TypeError) as error:
                raise HTTPException(503, UNAVAILABLE) from error
            finally:
                self.jobs.pop(request_id, None)

    def cancel(self, request_id, owner):
        job = self.jobs.get(request_id)
        if job and job[0] == owner:
            job[1].cancel()
            return True
        return False


class VlmNetworkAndBodyLimit:
    """Restrict VLM to explicitly trusted LANs and cap multipart BEFORE spooling."""
    def __init__(self, app, settings):
        self.app, self.settings = app, settings
        self.networks = [ipaddress.ip_network(value.strip()) for value in settings.allowed_networks.split(",")]

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not scope["path"].startswith("/vlm/"):
            return await self.app(scope, receive, send)
        from starlette.responses import JSONResponse
        try:
            address = ipaddress.ip_address(scope.get("client", ("", 0))[0])
            allowed = any(address in network for network in self.networks)
        except ValueError:
            allowed = False
        if not allowed:
            return await JSONResponse({"detail": "Trusted LAN only"}, status_code=403)(scope, receive, send)
        limit = self.settings.max_image_bytes + 32768  # below UploadFile's 1 MiB spool threshold
        headers = dict(scope["headers"])
        try:
            if int(headers.get(b"content-length", b"0")) > limit:
                return await JSONResponse({"detail": "Image too large"}, status_code=413)(scope, receive, send)
        except ValueError:
            return await JSONResponse({"detail": "Invalid content length"}, status_code=400)(scope, receive, send)
        total = 0

        async def limited_receive():
            nonlocal total
            message = await receive()
            total += len(message.get("body", b""))
            if total > limit:
                raise HTTPException(413, "Image too large")
            return message

        await self.app(scope, limited_receive, send)
