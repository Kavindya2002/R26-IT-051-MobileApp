from fastapi import HTTPException

from app.core.supabase import (
    supabase_admin,
    supabase_client,
)

from app.users.schemas import (
    RegisterRequest,
    LoginRequest,
    UpdateUserRequest,
    UserRole,
)


class UserService:

    # =====================================================
    # REGISTER
    # =====================================================

    @staticmethod
    def register(
        request: RegisterRequest,
    ):

        # "Do NOT allow arbitrary users to self-assign ELDER role."
        # Adding ELDER to the UserRole enum (app/users/schemas.py) was
        # necessary so an elder's linked account can carry that role,
        # but it would otherwise also let anyone calling this PUBLIC
        # endpoint directly (bypassing the Flutter app's own
        # register_screen.dart, which never offers ELDER in its
        # dropdown) pass role="ELDER" and create an unlinked elder
        # account for themselves. The only legitimate way to create an
        # ELDER account is ElderService.create()/update(), called by
        # an authenticated caregiver for one of their own elder
        # profiles — see app/elders/service.py.
        if request.role == UserRole.ELDER:
            raise HTTPException(
                status_code=403,
                detail=(
                    "Elder accounts cannot be self-registered. "
                    "A caregiver must grant app access from the "
                    "elder's profile."
                ),
            )

        auth_user = None

        try:

            # ------------------------------------------------
            # Create Supabase Auth user
            # ------------------------------------------------

            auth_response = (
                supabase_admin
                .auth
                .admin
                .create_user(
                    {
                        "email": request.email,
                        "password": request.password,
                        "email_confirm": True,

                        "user_metadata": {
                            "name": request.name,
                        },

                        "app_metadata": {
                            "role": request.role.value,
                        },
                    }
                )
            )

            auth_user = auth_response.user

            if auth_user is None:
                raise HTTPException(
                    status_code=400,
                    detail=(
                        "Authentication account "
                        "could not be created."
                    ),
                )

            user_id = str(auth_user.id)

            # ------------------------------------------------
            # Create public.users record
            # ------------------------------------------------

            user_data = {
                "id": user_id,
                "name": request.name,
                "email": request.email,
                "phone": request.phone,
                "role": request.role.value,
                "address": request.address,
                "relationship": request.relationship,
                "priority": request.priority,
            }

            db_response = (
                supabase_admin
                .table("users")
                .insert(user_data)
                .execute()
            )

            if not db_response.data:
                raise RuntimeError(
                    "public.users record could not be created."
                )

            return {
                "success": True,
                "message": "Account created successfully.",
                "user": db_response.data[0],
            }

        except HTTPException:
            raise

        except Exception as exc:

            print(
                "USER REGISTRATION ERROR:",
                str(exc),
            )

            # ------------------------------------------------
            # Rollback Auth account if database insert failed
            # ------------------------------------------------

            if auth_user is not None:

                try:
                    (
                        supabase_admin
                        .auth
                        .admin
                        .delete_user(
                            str(auth_user.id)
                        )
                    )

                except Exception as rollback_error:

                    print(
                        "AUTH ROLLBACK ERROR:",
                        str(rollback_error),
                    )

            error_message = str(exc).lower()

            if (
                "already registered" in error_message
                or "already exists" in error_message
                or "duplicate" in error_message
                or "unique" in error_message
            ):

                raise HTTPException(
                    status_code=409,
                    detail=(
                        "An account with this "
                        "email already exists."
                    ),
                )

            raise HTTPException(
                status_code=500,
                detail="Account creation failed.",
            )

    # =====================================================
    # LOGIN
    # =====================================================

    @staticmethod
    def login(
        request: LoginRequest,
    ):

        try:

            auth_response = (
                supabase_client
                .auth
                .sign_in_with_password(
                    {
                        "email": request.email,
                        "password": request.password,
                    }
                )
            )

            session = auth_response.session
            auth_user = auth_response.user

            if session is None or auth_user is None:
                raise HTTPException(
                    status_code=401,
                    detail="Invalid email or password.",
                )

            # ------------------------------------------------
            # Load public.users profile
            # ------------------------------------------------

            db_response = (
                supabase_admin
                .table("users")
                .select("*")
                .eq(
                    "id",
                    str(auth_user.id),
                )
                .limit(1)
                .execute()
            )

            if not db_response.data:
                raise HTTPException(
                    status_code=404,
                    detail="User profile was not found.",
                )

            return {
                "success": True,
                "message": "Login successful.",
                "access_token": session.access_token,
                "refresh_token": session.refresh_token,
                "token_type": "bearer",
                "user": db_response.data[0],
            }

        except HTTPException:
            raise

        except Exception as exc:

            print(
                "USER LOGIN ERROR:",
                str(exc),
            )

            raise HTTPException(
                status_code=401,
                detail="Invalid email or password.",
            )

    # =====================================================
    # CURRENT USER
    # =====================================================

    @staticmethod
    def get_current_user(
        access_token: str,
    ):

        try:

            auth_response = (
                supabase_client
                .auth
                .get_user(
                    access_token
                )
            )

            auth_user = auth_response.user

            if auth_user is None:
                raise HTTPException(
                    status_code=401,
                    detail="Invalid access token.",
                )

            db_response = (
                supabase_admin
                .table("users")
                .select("*")
                .eq(
                    "id",
                    str(auth_user.id),
                )
                .limit(1)
                .execute()
            )

            if not db_response.data:
                raise HTTPException(
                    status_code=404,
                    detail="User profile was not found.",
                )

            return {
                "success": True,
                "user": db_response.data[0],
            }

        except HTTPException:
            raise

        except Exception as exc:

            print(
                "CURRENT USER ERROR:",
                str(exc),
            )

            raise HTTPException(
                status_code=401,
                detail="Invalid or expired access token.",
            )

    # =====================================================
    # UPDATE CURRENT USER
    # =====================================================

    @staticmethod
    def update_user(
        access_token: str,
        request: UpdateUserRequest,
    ):

        current = UserService.get_current_user(
            access_token
        )

        current_user = current["user"]

        update_data = {}

        if request.name is not None:
            update_data["name"] = request.name

        if request.phone is not None:
            update_data["phone"] = request.phone

        if request.address is not None:
            update_data["address"] = request.address

        if request.relationship is not None:
            update_data["relationship"] = (
                request.relationship
            )

        if request.priority is not None:
            update_data["priority"] = request.priority

        # ADDED (avatar picker feature): same "only touch what was
        # actually sent" pattern as every other field above — omitting
        # avatar_id from the request leaves the previously saved value
        # untouched rather than clearing it.
        if request.avatar_id is not None:
            update_data["avatar_id"] = request.avatar_id

        if not update_data:
            raise HTTPException(
                status_code=400,
                detail=(
                    "No profile fields were provided."
                ),
            )

        db_response = (
            supabase_admin
            .table("users")
            .update(update_data)
            .eq(
                "id",
                current_user["id"],
            )
            .execute()
        )

        if not db_response.data:
            raise HTTPException(
                status_code=500,
                detail="Profile update failed.",
            )

        return {
            "success": True,
            "message": "Profile updated successfully.",
            "user": db_response.data[0],
        }
