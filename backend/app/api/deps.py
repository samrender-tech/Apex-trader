"""Shared dependencies: the authenticated principal."""
from __future__ import annotations

from dataclasses import dataclass

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from ..core.security import decode_token

bearer = HTTPBearer(auto_error=False)


@dataclass(frozen=True, slots=True)
class Principal:
    user_id: int
    role: str
    account_id: int | None

    @property
    def is_privileged(self) -> bool:
        return self.role in ("compliance", "admin")


async def current_principal(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
) -> Principal:
    if creds is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing bearer token")
    claims = decode_token(creds.credentials)
    if claims.get("typ") != "access":
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "wrong token type")
    return Principal(int(claims["sub"]), claims.get("role", "trader"), claims.get("acct"))


async def require_compliance(p: Principal = Depends(current_principal)) -> Principal:
    """
    Gate for the surveillance and risk-admin endpoints.

    Note this is defence in DEPTH, not the only defence: surveil.alert has
    an RLS policy that already restricts it to privileged users, so a bug
    here still cannot leak alerts.
    """
    if not p.is_privileged:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "compliance role required")
    return p
