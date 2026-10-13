from fastapi import FastAPI, UploadFile, File
from ultralytics import YOLO
from PIL import Image
import io

app = FastAPI()
model = YOLO("yolo26n.pt")

@app.post("/detect")
async def detect(file: UploadFile = File(...)):
    image_bytes = await file.read()
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")

    results = model.predict(image, verbose=False)
    detections = []

    for result in results:
        for box in result.boxes:
            detections.append({
                "class_name": result.names[int(box.cls[0])],
                "confidence": round(float(box.conf[0]), 3),
                "bbox": [
                    round(float(x), 2)
                    for x in box.xyxy[0].tolist()
                ]
            })

    return {"detections": detections}
