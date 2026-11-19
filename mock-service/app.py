"""Mock downstream lookup service protected by HTTP Basic Auth."""
import os
import re
import secrets
import time

from fastapi import Depends, FastAPI, HTTPException, Query, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials

SERVICE_NAME = os.environ["SERVICE_NAME"]
BASIC_USER = os.environ["BASIC_USER"]
BASIC_PASSWORD = os.environ["BASIC_PASSWORD"]
REFERENCE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
# Simulated downstream latency. Also keeps runs long enough for flowctl's live log view,
# which misses runs that finish in under ~100 ms (flowctl 0.16.0 waitForLogger race).
RESPONSE_DELAY_SECONDS = float(os.environ.get("RESPONSE_DELAY_SECONDS", "0"))

app = FastAPI(title=f"mock {SERVICE_NAME}")
basic = HTTPBasic(auto_error=False)


def authenticate(credentials: HTTPBasicCredentials | None = Depends(basic)) -> None:
    valid = credentials is not None and (
        secrets.compare_digest(credentials.username.encode(), BASIC_USER.encode())
        & secrets.compare_digest(credentials.password.encode(), BASIC_PASSWORD.encode())
    )
    if not valid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
            headers={"WWW-Authenticate": f'Basic realm="{SERVICE_NAME}"'},
        )


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/api/lookup", dependencies=[Depends(authenticate)])
def lookup(reference: str | None = Query(default=None)) -> dict:
    time.sleep(RESPONSE_DELAY_SECONDS)
    if reference is None or not REFERENCE_PATTERN.fullmatch(reference):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="reference is required and must match ^[A-Za-z0-9_-]{1,64}$",
        )
    return {
        "service": SERVICE_NAME,
        "reference": reference,
        "status": "FOUND",
        "description": "Mock lookup completed",
    }
