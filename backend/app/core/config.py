"""Runtime configuration, read from the environment (12-factor)."""
from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="APEX_", extra="ignore")

    # --- database ---
    # The API connects as apex_app, NOT as the owner/superuser, because
    # both of those bypass Row Level Security and would defeat the whole
    # tenant-isolation design.
    db_host: str = "127.0.0.1"
    db_port: int = 5432
    db_name: str = "apex_trader"
    db_user: str = "apex_app"
    db_password: str = "apex_app_pw"
    db_pool_min: int = 2
    db_pool_max: int = 16

    # Elevated connection used only by the ingestion worker and the
    # end-of-day batch, which legitimately write across all tenants.
    db_admin_user: str = "apex"
    db_admin_password: str = "apex_dev_pw"

    # --- auth ---
    jwt_secret: str = "change-me-in-production-this-is-a-dev-default"
    jwt_algorithm: str = "HS256"
    access_token_minutes: int = 30
    refresh_token_days: int = 14

    # --- market data feed ---
    # Set APEX_FINNHUB_API_KEY to use the live feed. With no key the
    # system falls back to the deterministic simulator, so the project
    # runs and demos with no network access at all.
    finnhub_api_key: str | None = None
    # auto | yahoo | finnhub | simulator.
    # "auto" picks Finnhub when a key is set, otherwise Yahoo.
    feed_provider: str = "auto"

    # Allow searching a provider for symbols this venue does not list yet,
    # and importing them into reference.instrument on demand.
    allow_instrument_import: bool = True
    # Cap how many instruments can be imported, so a runaway client cannot
    # fill the security master.
    max_instruments: int = 200
    feed_poll_seconds: float = 3.0

    # Demo mode exposes the seeded accounts on the login screen so the
    # UI always matches whatever the seeder actually created. Turn it off
    # for anything resembling production -- it lists real account emails.
    demo_mode: bool = True

    api_title: str = "Apex Trader"
    cors_origins: str = "*"

    @property
    def dsn(self) -> str:
        return (f"postgresql://{self.db_user}:{self.db_password}"
                f"@{self.db_host}:{self.db_port}/{self.db_name}")

    @property
    def admin_dsn(self) -> str:
        return (f"postgresql://{self.db_admin_user}:{self.db_admin_password}"
                f"@{self.db_host}:{self.db_port}/{self.db_name}")


@lru_cache
def get_settings() -> Settings:
    return Settings()
