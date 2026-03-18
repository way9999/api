"""API key + JWT verification."""

import secrets
import time
from typing import Optional

import jwt
from fastapi import HTTPException, Request

from ..services.api_key_manager import ApiKeyManager
from ..core import config

_key_manager: Optional[ApiKeyManager] = None
_JWT_SECRET = secrets.token_hex(32)
_JWT_EXPIRE = 86400 * 7  # 7 days


def init_auth(key_manager: ApiKeyManager):
    global _key_manager
    _key_manager = key_manager


def create_login_token(username: str) -> str:
    payload = {"sub": username, "exp": int(time.time()) + _JWT_EXPIRE}
    return jwt.encode(payload, _JWT_SECRET, algorithm="HS256")


def verify_login(username: str, password: str) -> bool:
    return username == config.ADMIN_USERNAME and password == config.ADMIN_PASSWORD


def _extract_token(request: Request) -> Optional[str]:
    auth_header = request.headers.get("authorization", "")
    if auth_header.lower().startswith("bearer "):
        return auth_header[7:].strip()
    return request.headers.get("x-api-key")


async def verify_api_key(request: Request) -> str:
    token = _extract_token(request)
    if not token:
        raise HTTPException(status_code=401, detail="Missing token")
    # Try JWT first
    try:
        payload = jwt.decode(token, _JWT_SECRET, algorithms=["HS256"])
        if payload.get("exp", 0) > time.time():
            return token
    except (jwt.InvalidTokenError, jwt.ExpiredSignatureError):
        pass
    # Fallback to API key
    if _key_manager and _key_manager.validate(token):
        return token
    raise HTTPException(status_code=401, detail="Invalid token")
