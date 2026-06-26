# -*- coding: utf-8 -*-
import os
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.routers import projects, boq, master_roll, progress, financial, dashboard

app = FastAPI(
    title="SiteTracker v2 API",
    description="Construction Project Mini SaaS - multi-tenant EVM tracking",
    version="0.1.0",
)

# CORS: allowed origins come from the ALLOWED_ORIGINS env var (comma-
# separated), set in Railway once the Vercel frontend URL is known.
# Defaults to "*" only for local dev, where ALLOWED_ORIGINS is unset.
#
# allow_credentials is intentionally False: auth here is a Bearer token
# in the Authorization header (the Supabase session's access_token),
# not a cookie - credentialed CORS (cookies) isn't in use, and per the
# CORS spec, allow_credentials=True is invalid/ignored by browsers when
# combined with a wildcard origin anyway, so there's no reason to set it.
allowed_origins_env = os.environ.get("ALLOWED_ORIGINS", "*")
allowed_origins = [o.strip() for o in allowed_origins_env.split(",")] if allowed_origins_env != "*" else ["*"]

app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(projects.router, prefix="/api/projects", tags=["projects"])
app.include_router(boq.router, prefix="/api/boq", tags=["boq"])
app.include_router(master_roll.router, prefix="/api/master-roll", tags=["master_roll"])
app.include_router(progress.router, prefix="/api/progress", tags=["progress"])
app.include_router(financial.router, prefix="/api/financial", tags=["financial"])
app.include_router(dashboard.router, prefix="/api/dashboard", tags=["dashboard"])


@app.get("/health")
def health_check():
    return {"status": "ok"}
