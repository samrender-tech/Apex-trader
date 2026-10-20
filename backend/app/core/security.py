"""JWT issuing/verification and the refresh-token store."""
from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import HTTPException, status

from .config import get_settings


def _now() -> datetime:
    return datetime.now(timezone.utc)


def create_access_token(user_id: int, role: str, account_id: int | None) -> str:
    s = get_settings()
    payload = {
        "sub": str(user_id),
        "role": role,
        "acct": account_id,
        "iat": int(_now().timestamp()),
        "exp": int((_now() + timedelta(minutes=s.access_token_minutes)).timestamp()),
        "typ": "access",
    }
    return jwt.encode(payload, s.jwt_secret, algorithm=s.jwt_algorithm)


def decode_token(token: str) -> dict:
    s = get_settings()
    try:
        return jwt.decode(token, s.jwt_secret, algorithms=[s.jwt_algorithm])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid token")


def new_refresh_token() -> tuple[str, str]:
    """Returns (token, sha256 hash). Only the hash is ever stored."""
    raw = secrets.token_urlsafe(48)
    return raw, hashlib.sha256(raw.encode()).hexdigest()


def hash_refresh_token(raw: str) -> str:
    return hashlib.sha256(raw.encode()).hexdigest()
