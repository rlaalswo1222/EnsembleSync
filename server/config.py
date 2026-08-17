import os
from urllib.parse import urlparse

from dotenv import load_dotenv

load_dotenv()

PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "http://localhost:8000").rstrip("/")


def public_url(path: str) -> str:
    return f"{PUBLIC_BASE_URL}/{path.lstrip('/')}"


def normalize_public_url(url: str) -> str:
    path = urlparse(url).path
    return public_url(path) if path else url


def local_upload_path(url: str) -> str:
    path = urlparse(url).path.lstrip("/")
    if not path.startswith("uploads/"):
        raise ValueError("Invalid upload URL")
    return path
