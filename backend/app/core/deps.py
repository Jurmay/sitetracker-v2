# -*- coding: utf-8 -*-
"""
FastAPI dependency: authenticates the incoming request's Bearer token
and yields a Supabase client scoped to that user (so every downstream
query in the route handler is subject to RLS as that real user - never
the service role).
"""
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from supabase import Client

from app.core.supabase_client import get_user_client, get_service_client

bearer_scheme = HTTPBearer()


class CurrentUser:
    def __init__(self, user_id: str, email: str, client: Client):
        self.id = user_id
        self.email = email
        self.client = client  # RLS-scoped client - use this for all queries in the route


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
) -> CurrentUser:
    token = credentials.credentials
    user_client = get_user_client(token)

    try:
        user_response = user_client.auth.get_user(token)
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired authentication token.",
        )

    if not user_response or not user_response.user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired authentication token.",
        )

    return CurrentUser(
        user_id=user_response.user.id,
        email=user_response.user.email,
        client=user_client,
    )


def get_service_db() -> Client:
    """
    For the rare system-level routes that must legitimately bypass RLS
    (e.g. an endpoint pg_cron calls internally to trigger email sends).
    Never used for normal user-facing routes.
    """
    return get_service_client()
