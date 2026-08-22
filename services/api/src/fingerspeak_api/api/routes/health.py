from __future__ import annotations

from fastapi import APIRouter, HTTPException, status
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from fingerspeak_api import __version__
from fingerspeak_api.api.dependencies import DBSession
from fingerspeak_api.schemas import HealthRead

router = APIRouter(tags=["health"])


@router.get("/health/live", response_model=HealthRead)
async def live() -> HealthRead:
    return HealthRead(status="ok", service="fingerspeak-api", version=__version__)


@router.get("/health/ready", response_model=HealthRead)
async def ready(db: DBSession) -> HealthRead:
    try:
        await db.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Database is unavailable",
        ) from exc
    return HealthRead(status="ok", service="fingerspeak-api", version=__version__)
