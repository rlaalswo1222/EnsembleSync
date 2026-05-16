from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
import room_create
import room_enter

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(room_create.router)
app.include_router(room_enter.router)
