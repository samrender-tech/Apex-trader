"""Registration, login, refresh, logout."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, EmailStr, Field

from ..core import db
from ..core.config import get_settings
from ..core.security import (create_access_token, hash_refresh_token,
                             new_refresh_token)
from .deps import Principal, current_principal

router = APIRouter(prefix="/auth", tags=["auth"])


class RegisterIn(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    full_name: str = Field(min_length=2, max_length=120)
    account_kind: str = Field(default="cash", pattern="^(cash|margin)$")
    opening_deposit: int = Field(default=100_000, ge=0, le=10_000_000)


class LoginIn(BaseModel):
    email: EmailStr
    password: str


class TokenOut(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    user_id: int
    account_id: int | None
    role: str
    full_name: str


@router.post("/register", status_code=201)
async def register(body: RegisterIn, request: Request):
    """
    Create a user, their trading account, and fund it from the bank.

    The deposit is a BALANCED ledger entry (bank -> trader), not an UPDATE
    to a balance column -- so even account opening obeys double entry.
    """
    async with db.acquire_admin() as conn:
        async with conn.transaction():
            try:
                user_id = await conn.fetchval("""
                    INSERT INTO identity.app_user
                        (email,password_hash,full_name,kyc_state,kyc_verified_at)
                    VALUES ($1, identity.hash_password($2), $3, 'verified', now())
                    RETURNING user_id;
                """, str(body.email), body.password, body.full_name)
            except asyncpg.UniqueViolationError:
                raise HTTPException(status.HTTP_409_CONFLICT, "email already registered")

            account_id = await conn.fetchval("""
                INSERT INTO trading.account (account_no,user_id,kind,leverage)
                VALUES ('APX-'||lpad($1::bigint::text,6,'0'), $1::bigint,
                        $2::trading.account_kind, $3::numeric)
                RETURNING account_id;
            """, user_id, body.account_kind, 4.0 if body.account_kind == "margin" else 1.0)

            if body.opening_deposit > 0:
                await conn.execute("""
                    SELECT ledger.post_entry('deposit','Opening deposit',
                        ARRAY[ ROW((SELECT account_id FROM trading.account
                                     WHERE system_code='EXTERNAL_CASH'),
                                   'cash',NULL,$1::money_amt,'bank debit')::ledger.leg,
                               ROW($2::bigint,'cash',NULL,$3::money_amt,'credit')::ledger.leg ]);
                """, -body.opening_deposit, account_id, body.opening_deposit)

    return {"user_id": user_id, "account_id": account_id,
            "message": "registered; use /auth/login to obtain a token"}


@router.post("/login", response_model=TokenOut)
async def login(body: LoginIn, request: Request):
    """
    Authenticate.

    The credential check, the failed-attempt lockout and the forensic log
    all happen inside identity.authenticate() in a single transaction, so
    there is no code path through this API that can skip the lockout.
    """
    ip = request.client.host if request.client else None
    async with db.acquire_admin() as conn:
        try:
            rec = await conn.fetchrow(
                "SELECT * FROM identity.authenticate($1,$2,$3::inet,$4)",
                str(body.email), body.password, ip,
                request.headers.get("user-agent"))
        except asyncpg.PostgresError as exc:
            # 28P01 == invalid_password. Deliberately returns the same
            # generic message for unknown-user and wrong-password, so the
            # endpoint is not a user-enumeration oracle.
            if getattr(exc, "sqlstate", None) == "28P01":
                raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid credentials")
            raise

        if rec is None:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid credentials")

        account_id = await conn.fetchval(
            "SELECT account_id FROM trading.account WHERE user_id=$1 ORDER BY account_id LIMIT 1",
            rec["user_id"])

        raw, hashed = new_refresh_token()
        s = get_settings()
        await conn.execute("""
            INSERT INTO identity.user_session
                (user_id,token_hash,expires_at,ip_address,user_agent)
            VALUES ($1,$2,$3,$4::inet,$5);
        """, rec["user_id"], hashed,
             datetime.now(timezone.utc) + timedelta(days=s.refresh_token_days),
             ip, request.headers.get("user-agent"))

    return TokenOut(
        access_token=create_access_token(rec["user_id"], rec["role"], account_id),
        refresh_token=raw, user_id=rec["user_id"], account_id=account_id,
        role=rec["role"], full_name=rec["full_name"])


class RefreshIn(BaseModel):
    refresh_token: str


@router.post("/refresh", response_model=TokenOut)
async def refresh(body: RefreshIn):
    async with db.acquire_admin() as conn:
        rec = await conn.fetchrow("""
            SELECT s.session_id, u.user_id, u.role, u.full_name
              FROM identity.user_session s
              JOIN identity.app_user u USING (user_id)
             WHERE s.token_hash = $1
               AND s.revoked_at IS NULL
               AND s.expires_at > now()
               AND u.is_active;
        """, hash_refresh_token(body.refresh_token))
        if rec is None:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid or expired refresh token")

        account_id = await conn.fetchval(
            "SELECT account_id FROM trading.account WHERE user_id=$1 ORDER BY account_id LIMIT 1",
            rec["user_id"])

        # Refresh-token ROTATION: the old token is revoked as the new one
        # is issued, so a stolen token is usable at most once.
        raw, hashed = new_refresh_token()
        s = get_settings()
        async with conn.transaction():
            await conn.execute(
                "UPDATE identity.user_session SET revoked_at=now() WHERE session_id=$1",
                rec["session_id"])
            await conn.execute("""
                INSERT INTO identity.user_session (user_id,token_hash,expires_at)
                VALUES ($1,$2,$3);
            """, rec["user_id"], hashed,
                 datetime.now(timezone.utc) + timedelta(days=s.refresh_token_days))

    return TokenOut(
        access_token=create_access_token(rec["user_id"], rec["role"], account_id),
        refresh_token=raw, user_id=rec["user_id"], account_id=account_id,
        role=rec["role"], full_name=rec["full_name"])


@router.post("/logout", status_code=204)
async def logout(body: RefreshIn, p: Principal = Depends(current_principal)):
    async with db.acquire_admin() as conn:
        await conn.execute("""
            UPDATE identity.user_session SET revoked_at = now()
             WHERE token_hash = $1 AND user_id = $2 AND revoked_at IS NULL;
        """, hash_refresh_token(body.refresh_token), p.user_id)


@router.get("/demo-accounts")
async def demo_accounts():
    """
    The seeded demo logins, read from the database.

    The login screen used to hardcode this list, which meant reseeding
    with different accounts left the UI offering names that no longer
    existed. Serving it from the database makes drift impossible.

    Returns an empty list when demo mode is off; it exposes account
    emails, which is fine for a seeded demo and not for anything else.
    """
    if not get_settings().demo_mode:
        return {"demo_mode": False, "password": None, "accounts": []}

    async with db.acquire_admin() as conn:
        recs = await conn.fetch("""
            SELECT u.email, u.full_name, u.role::text AS role,
                   a.base_currency, a.kind::text AS kind,
                   a.allow_short_selling,
                   c.symbol AS currency_symbol,
                   EXISTS (SELECT 1 FROM social.strategy s
                            WHERE s.owner_user_id = u.user_id) AS publishes_strategy,
                   EXISTS (SELECT 1 FROM surveil.alert al
                            WHERE al.account_id = a.account_id) AS is_flagged
              FROM identity.app_user u
              JOIN trading.account a USING (user_id)
              LEFT JOIN reference.currency c ON c.code = a.base_currency
             WHERE u.is_active
             ORDER BY
               CASE u.role WHEN 'trader' THEN 0 WHEN 'compliance' THEN 1 ELSE 2 END,
               u.user_id;
        """)
    return {"demo_mode": True, "password": "Apex@2026", "accounts": db.rows(recs)}


@router.get("/me")
async def me(p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        user = await conn.fetchrow("""
            SELECT user_id, public_id, email, full_name, role, kyc_state,
                   created_at, last_login_at
              FROM identity.app_user WHERE user_id = $1;
        """, p.user_id)
        accounts = await conn.fetch("""
            SELECT * FROM analytics.v_account_summary WHERE user_id = $1;
        """, p.user_id)
    return {"user": db.row(user), "accounts": db.rows(accounts)}
