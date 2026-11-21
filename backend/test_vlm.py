import asyncio
import base64
import io
from datetime import datetime, timezone

import httpx
import pytest
from fastapi import FastAPI
from PIL import Image

from vlm_router import create_vlm_router
from vlm_service import VlmNetworkAndBodyLimit, VlmService, VlmSettings


def jpeg(size=(64, 32), fmt="JPEG"):
    target = io.BytesIO()
    Image.new("RGB", size, "green").save(target, fmt)
    return target.getvalue()


def request_fields(request_id="test-1"):
    return {"request_id": request_id, "question": "Опиши окружение", "captured_at": datetime.now(timezone.utc).isoformat()}


def response(text="На снимке видны зелёная стена и окно."):
    return httpx.Response(200, json={"done": True, "done_reason": "stop", "message": {"content": text}, "load_duration": 2_000_000})


def run_check(check, handler=lambda request: response(), address="127.0.0.1"):
    async def run():
        service = VlmService(transport=httpx.MockTransport(handler))
        app = FastAPI()
        app.add_middleware(VlmNetworkAndBodyLimit, settings=service.settings)
        app.include_router(create_vlm_router(service))
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app, client=(address, 1234)), base_url="http://test") as client:
            await check(client, service)
    asyncio.run(run())


def test_real_jpeg_reaches_chat_and_correlates_result():
    import json
    def handler(request):
        data = json.loads(request.content)
        assert request.url.path == "/api/chat" and data["stream"] is False
        assert data["model"] == "qwen3-vl:2b-instruct"
        image = Image.open(io.BytesIO(base64.b64decode(data["messages"][1]["images"][0])))
        assert image.size == (64, 32)
        return response()

    async def check(client, _):
        fields = request_fields()
        result = await client.post("/vlm/describe", data=fields, files={"image": ("frame.jpg", jpeg(), "image/jpeg")})
        assert result.status_code == 200
        assert result.json()["request_id"] == fields["request_id"]
        assert result.json()["timings"]["load_ms"] == 2
    run_check(check, handler)


@pytest.mark.parametrize("data,content_type,status", [
    (b"", "image/jpeg", 400), (b"broken", "image/jpeg", 400),
    (jpeg(fmt="PNG"), "image/jpeg", 400), (jpeg(), "image/png", 400),
    (bytes(800_000), "image/jpeg", 413), (jpeg((3000, 2000)), "image/jpeg", 400),
])
def test_invalid_images_never_reach_ollama(data, content_type, status):
    async def check(client, _):
        result = await client.post("/vlm/describe", data=request_fields(), files={"image": ("bad.jpg", data, content_type)})
        assert result.status_code == status
    def handler(_):
        pytest.fail("Invalid image reached Ollama")
    run_check(check, handler)


@pytest.mark.parametrize("text", ["", "English text only", "я" * 601, "Путь свободен и безопасен.", "Идите вперёд.", "Дверь в 5 метрах."])
def test_empty_overlong_or_navigation_advice_rejected(text):
    async def check(client, _):
        result = await client.post("/vlm/describe", data=request_fields(), files={"image": ("f.jpg", jpeg(), "image/jpeg")})
        assert result.status_code == 503
    run_check(check, lambda request: response(text))


@pytest.mark.parametrize("kind,status", [("unavailable", 503), ("timeout", 504), ("missing_model", 503)])
def test_upstream_errors(kind, status):
    def handler(request):
        if kind == "unavailable":
            raise httpx.ConnectError("offline")
        if kind == "timeout":
            raise httpx.ReadTimeout("slow")
        return httpx.Response(404, json={"error": "missing model"})
    async def check(client, _):
        result = await client.post("/vlm/describe", data=request_fields(), files={"image": ("f.jpg", jpeg(), "image/jpeg")})
        assert result.status_code == status
    run_check(check, handler)


def test_untrusted_network_denied():
    async def check(client, _):
        result = await client.post("/vlm/describe", data=request_fields(), files={"image": ("f.jpg", jpeg(), "image/jpeg")})
        assert result.status_code == 403
    run_check(check, address="8.8.8.8")


def test_parallel_request_and_cancel_release_slot_for_reconnect():
    ready = asyncio.Event()
    gate = asyncio.Event()
    async def handler(request):
        ready.set()
        await gate.wait()
        return response()
    async def check(client, service):
        async def post(id):
            return await client.post("/vlm/describe", data=request_fields(id), files={"image": ("f.jpg", jpeg(), "image/jpeg")})
        first = asyncio.create_task(post("first"))
        await ready.wait()
        assert (await post("second")).status_code == 429
        assert (await client.delete("/vlm/requests/first")).json()["cancelled"] is True
        assert (await first).status_code == 499
        assert not service.jobs
        gate.set()
        assert (await post("third")).status_code == 200
    run_check(check, handler)


def test_only_one_image_and_timezone_required():
    async def check(client, _):
        fields = request_fields()
        fields["captured_at"] = "2026-11-20T12:00:00"
        assert (await client.post("/vlm/describe", data=fields, files={"image": ("f.jpg", jpeg(), "image/jpeg")})).status_code == 400
        assert (await client.post("/vlm/describe", data=request_fields(), files=[("image", ("1.jpg", jpeg(), "image/jpeg")), ("image", ("2.jpg", jpeg(), "image/jpeg"))])).status_code == 400
    run_check(check)


def test_loopback_and_fixed_model_required():
    with pytest.raises(ValueError):
        VlmSettings(ollama_url="https://ollama.com")
    with pytest.raises(ValueError):
        VlmSettings(model="qwen3-vl:235b-cloud")


def test_chunked_oversize_body_is_rejected_before_file_spooling():
    async def check(client, _):
        body = (b'--bound\r\nContent-Disposition: form-data; name="image"; filename="f.jpg"\r\n'
                b'Content-Type: image/jpeg\r\n\r\n' + bytes(900_000) + b'\r\n--bound--\r\n')
        async def chunks():
            for offset in range(0, len(body), 16384):
                yield body[offset:offset+16384]
        result = await client.post('/vlm/describe', content=chunks(),
                                   headers={'Content-Type': 'multipart/form-data; boundary=bound'})
        assert result.status_code == 413
    run_check(check)
