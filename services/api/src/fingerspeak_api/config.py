from __future__ import annotations

from enum import StrEnum
from functools import lru_cache
from typing import Self

from pydantic import AliasChoices, Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Environment(StrEnum):
    development = "development"
    test = "test"
    staging = "staging"
    production = "production"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_prefix="FINGERSPEAK_",
        case_sensitive=False,
        extra="ignore",
        populate_by_name=True,
    )

    app_name: str = "FingerSpeak API"
    environment: Environment = Environment.development
    database_url: str = "postgresql+asyncpg://fingerspeak:fingerspeak@localhost:5432/fingerspeak"
    api_v1_prefix: str = "/v1"
    cors_origins: list[str] = Field(default_factory=lambda: ["http://localhost:3000"])
    cors_allow_credentials: bool = True
    trusted_hosts: list[str] = Field(default_factory=lambda: ["localhost", "127.0.0.1"])
    allow_development_identity: bool = True
    development_identity: str = "local-user"
    gateway_hmac_secret: SecretStr | None = Field(default=None, repr=False)
    gateway_signature_ttl_seconds: int = Field(default=60, ge=5, le=300)
    websocket_max_message_bytes: int = Field(default=4_096, ge=128, le=65_536)
    max_request_body_bytes: int = Field(default=262_144, ge=4_096, le=2_097_152)
    alert_replay_limit: int = Field(default=100, ge=1, le=500)
    device_online_ttl_seconds: int = Field(default=30, ge=5, le=300)
    device_caption_ttl_seconds: int = Field(default=120, ge=10, le=300)
    openai_api_key: SecretStr | None = Field(
        default=None,
        validation_alias=AliasChoices("OPENAI_API_KEY", "FINGERSPEAK_OPENAI_API_KEY"),
        repr=False,
    )
    openai_model: str = Field(default="gpt-5.6-terra", min_length=1, max_length=100)
    openai_vector_store_id: str | None = Field(default=None, min_length=1, max_length=200)
    openai_timeout_seconds: float = Field(default=12.0, ge=1.0, le=30.0)
    openai_max_output_tokens: int = Field(default=500, ge=64, le=2_000)
    log_level: str = "INFO"

    @property
    def docs_enabled(self) -> bool:
        return self.environment is not Environment.production

    @property
    def requires_gateway_signature(self) -> bool:
        return self.environment in {Environment.staging, Environment.production}

    @model_validator(mode="after")
    def validate_security_settings(self) -> Self:
        if self.cors_allow_credentials and (
            not self.cors_origins or any(origin in {"*", "null"} for origin in self.cors_origins)
        ):
            raise ValueError(
                "Credentialed CORS requires explicit non-null FINGERSPEAK_CORS_ORIGINS"
            )
        secret = self.gateway_hmac_secret
        if self.requires_gateway_signature and (
            secret is None or len(secret.get_secret_value().encode("utf-8")) < 32
        ):
            raise ValueError(
                "FINGERSPEAK_GATEWAY_HMAC_SECRET must contain at least 32 bytes in "
                "staging and production"
            )
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
