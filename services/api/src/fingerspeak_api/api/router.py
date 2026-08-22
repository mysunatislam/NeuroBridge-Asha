from fastapi import APIRouter

from fingerspeak_api.api.routes import asha, devices, events, model_versions, profiles, sessions

api_router = APIRouter()
api_router.include_router(asha.router)
api_router.include_router(devices.router)
api_router.include_router(profiles.router)
api_router.include_router(sessions.router)
api_router.include_router(events.router)
api_router.include_router(model_versions.router)
