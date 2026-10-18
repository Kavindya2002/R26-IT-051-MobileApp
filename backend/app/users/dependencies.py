from fastapi import Header, HTTPException


def get_access_token(
    authorization: str | None = Header(default=None),
) -> str:

    if not authorization:
        raise HTTPException(
            status_code=401,
            detail="Authorization header is required.",
        )

    if not authorization.lower().startswith("bearer "):
        raise HTTPException(
            status_code=401,
            detail="Authorization header must use Bearer token.",
        )

    token = authorization[7:].strip()

    if not token:
        raise HTTPException(
            status_code=401,
            detail="Access token is required.",
        )

    return token