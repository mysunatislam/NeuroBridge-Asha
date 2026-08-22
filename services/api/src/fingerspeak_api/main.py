from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from fingerspeak_api import __version__
from fingerspeak_api.api.router import api_router
from fingerspeak_api.api.routes.health import router as health_router
from fingerspeak_api.config import Settings, get_settings
from fingerspeak_api.middleware import NoStoreAPIMiddleware, PrivacyBoundaryMiddleware
from fingerspeak_api.services.asha import build_asha_service


def create_app(settings: Settings | None = None) -> FastAPI:
    config = settings or get_settings()
    app = FastAPI(
        title=config.app_name,
        version=__version__,
        description=(
            "FingerSpeak control-plane API. Camera frames, audio, landmarks, biometric templates, "
            "and raw calibration sequences are intentionally out of scope and remain on-device."
        ),
        docs_url="/docs" if config.docs_enabled else None,
        redoc_url="/redoc" if config.docs_enabled else None,
        openapi_url="/openapi.json" if config.docs_enabled else None,
    )
    app.state.settings = config
    app.state.asha_service = build_asha_service(config)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=config.cors_origins,
        allow_credentials=config.cors_allow_credentials,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        # Actor assertion headers are gateway-to-service headers and intentionally not CORS-safe.
        allow_headers=["Authorization", "Content-Type"],
    )
    if config.trusted_hosts:
        app.add_middleware(TrustedHostMiddleware, allowed_hosts=config.trusted_hosts)
    app.add_middleware(PrivacyBoundaryMiddleware, max_body_bytes=config.max_request_body_bytes)
    app.add_middleware(NoStoreAPIMiddleware, api_prefix=config.api_v1_prefix)

    app.include_router(health_router)
    app.include_router(api_router, prefix=config.api_v1_prefix)

    @app.get("/", include_in_schema=False)
    async def service_root() -> dict[str, str]:
        return {
            "service": "fingerspeak-api",
            "version": __version__,
            "privacy_boundary": "on-device inference; no media or landmark uploads",
        }

    return app


app = create_app()
