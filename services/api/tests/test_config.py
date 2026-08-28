import pytest

from fingerspeak_api.config import Settings


def test_blank_optional_environment_settings_are_treated_as_unset() -> None:
    settings = Settings(
        gateway_hmac_secret="",
        openai_api_key="",
        openai_vector_store_id="",
    )

    assert settings.gateway_hmac_secret is None
    assert settings.openai_api_key is None
    assert settings.openai_vector_store_id is None


@pytest.mark.parametrize("blank", ["", "  \t"])
def test_blank_vector_store_environment_value_is_unset(
    monkeypatch: pytest.MonkeyPatch,
    blank: str,
) -> None:
    monkeypatch.setenv("FINGERSPEAK_OPENAI_VECTOR_STORE_ID", blank)

    settings = Settings(_env_file=None)

    assert settings.openai_vector_store_id is None


def test_nonblank_vector_store_environment_value_is_preserved(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("FINGERSPEAK_OPENAI_VECTOR_STORE_ID", "vs_test_123")

    settings = Settings(_env_file=None)

    assert settings.openai_vector_store_id == "vs_test_123"
