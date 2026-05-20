from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
import room_create
import room_enter
import score_query
import score_upload
import websocket
import os

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

os.makedirs("uploads/scores", exist_ok=True)
app.mount("/uploads", StaticFiles(directory="uploads"), name="uploads")

app.include_router(room_create.router)
app.include_router(room_enter.router)
app.include_router(score_query.router)
app.include_router(score_upload.router)
app.include_router(websocket.router)
