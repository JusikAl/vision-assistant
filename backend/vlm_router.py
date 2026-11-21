import asyncio
import contextlib
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, File, Form, HTTPException, Request, UploadFile

from vlm_service import VlmService


def create_vlm_router(service: VlmService):
    router = APIRouter(prefix="/vlm", tags=["scene description"])

    @router.post("/describe")
    async def describe(request: Request, image: Annotated[UploadFile, File()],
                       question: Annotated[str, Form(min_length=1, max_length=500)],
                       request_id: Annotated[str, Form(pattern=r"^[a-zA-Z0-9_-]{1,80}$")],
                       captured_at: Annotated[datetime, Form()]):
        form = await request.form()
        try:
            if len(form.getlist("image")) != 1 or image.content_type != "image/jpeg" or captured_at.tzinfo is None:
                raise HTTPException(400, "Expected JPEG and timezone-aware capture timestamp")
            data = await image.read(service.settings.max_image_bytes + 1)
        finally:
            await form.close()

        async def disconnected():
            while True:
                if await request.is_disconnected():
                    return
                await asyncio.sleep(.1)

        task = asyncio.create_task(service.describe(image=data, question=question, request_id=request_id,
                                                  captured_at=captured_at, owner=request.client.host))
        watcher = asyncio.create_task(disconnected())
        try:
            done, _ = await asyncio.wait([task, watcher], return_when=asyncio.FIRST_COMPLETED)
            if task in done:
                return await task
            task.cancel()
            raise HTTPException(499, "Request cancelled")
        except asyncio.CancelledError:
            raise HTTPException(499, "Request cancelled") from None
        finally:
            task.cancel()
            watcher.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
            with contextlib.suppress(asyncio.CancelledError):
                await watcher

    @router.delete("/requests/{request_id}")
    async def cancel(request_id: str, request: Request):
        return {"request_id": request_id, "cancelled": service.cancel(request_id, request.client.host)}

    return router
