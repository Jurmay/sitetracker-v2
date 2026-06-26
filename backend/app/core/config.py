# -*- coding: utf-8 -*-
"""
Application configuration, loaded from environment variables.
Mirrors the SVL project's pattern: Railway sets these as env vars in
production; locally they're loaded from a .env file via python-dotenv.
"""
from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    supabase_url: str
    supabase_anon_key: str
    supabase_service_role_key: str
    supabase_jwt_secret: str  # used to verify incoming user JWTs locally without a round-trip

    resend_api_key: str = ""
    accounts_email_from: str = "noreply@sitetracker.app"

    environment: str = "development"  # 'development' | 'production'

    model_config = SettingsConfigDict(env_file=".env")


@lru_cache
def get_settings() -> Settings:
    return Settings()
