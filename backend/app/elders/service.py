from fastapi import HTTPException

from app.core.supabase import supabase_admin
from app.elders.schemas import CreateElderRequest, UpdateElderRequest


class ElderService:

    # =====================================================
    # ELDER LOGIN PROVISIONING
    # =====================================================
    #
    # Shared by both create() and update() below. Creates a real
    # Supabase Auth account (role=ELDER) AND the matching public.users
    # row (login()/get_current_user() both read from "users", not
    # "elders" — an Auth-only account with no "users" row would fail
    # to log in with "User profile was not found."), then links that
    # new user's id onto the given elder row's user_id column.
    #
    # A random temporary password is generated here, never a
    # caregiver-typed or hardcoded one. It is returned ONCE in this
    # response for the caregiver to pass on; it is never stored
    # anywhere (Supabase Auth stores only its hash) and never logged.
    @staticmethod
    def _provision_login(elder_id: str, elder_name: str, login_email: str) -> str:
        import secrets

        temporary_password = secrets.token_urlsafe(12)

        auth_user = None
        try:
            auth_response = (
                supabase_admin
                .auth
                .admin
                .create_user(
                    {
                        "email": login_email,
                        "password": temporary_password,
                        "email_confirm": True,
                        "user_metadata": {"name": elder_name},
                        "app_metadata": {"role": "ELDER"},
                    }
                )
            )
            auth_user = auth_response.user
            if auth_user is None:
                raise HTTPException(
                    status_code=400,
                    detail="Elder login account could not be created.",
                )
            user_id = str(auth_user.id)

            # public.users row — required for login()/get_current_user()
            # to resolve this account at all (see app/users/service.py).
            user_insert = (
                supabase_admin
                .table("users")
                .insert(
                    {
                        "id": user_id,
                        "name": elder_name,
                        "email": login_email,
                        "phone": "",
                        "role": "ELDER",
                        "address": None,
                        "relationship": None,
                        "priority": 1,
                    }
                )
                .execute()
            )
            if not user_insert.data:
                raise RuntimeError("public.users record could not be created for elder login.")

            link_response = (
                supabase_admin
                .table("elders")
                .update({"user_id": user_id})
                .eq("id", elder_id)
                .execute()
            )
            if not link_response.data:
                raise RuntimeError("Could not link the new login account to this elder profile.")

            return temporary_password

        except HTTPException:
            raise
        except Exception as exc:
            print("ELDER LOGIN PROVISIONING ERROR:", str(exc))
            if auth_user is not None:
                try:
                    supabase_admin.auth.admin.delete_user(str(auth_user.id))
                except Exception as rollback_error:
                    print("ELDER LOGIN ROLLBACK ERROR:", str(rollback_error))
            error_message = str(exc).lower()
            if "already registered" in error_message or "already exists" in error_message or "duplicate" in error_message:
                raise HTTPException(status_code=409, detail="An account with this email already exists.")
            raise HTTPException(status_code=500, detail="Elder login account could not be created.")

    @staticmethod
    def create(caregiver_id: str, request: CreateElderRequest) -> dict:
        data = {
            "caregiver_id": caregiver_id,
            "name": request.name,
            "age": request.age,
            "previous_falls": request.previous_falls,
            "assistive_device": request.assistive_device,
            "address": request.address,
            "phone": request.phone,
            "gender": request.gender,
            # ADDED (avatar picker feature): saved on creation too, so
            # a caregiver can pick an avatar right away in the Add
            # Elder flow rather than only afterwards in Edit Elder.
            "avatar_id": request.avatar_id,
        }
        response = supabase_admin.table("elders").insert(data).execute()
        if not response.data:
            raise HTTPException(status_code=500, detail="Elder profile could not be created.")
        elder = response.data[0]

        # Optional login provisioning in the same request that creates
        # the profile. Only runs when the caregiver explicitly asked
        # for it; every existing caller that omits grant_login behaves
        # exactly as before.
        temporary_password = None
        if request.grant_login and request.login_email:
            temporary_password = ElderService._provision_login(
                elder["id"], elder["name"], request.login_email
            )
            # Re-read so the returned elder row reflects the new user_id.
            refreshed = (
                supabase_admin.table("elders").select("*").eq("id", elder["id"]).limit(1).execute()
            )
            if refreshed.data:
                elder = refreshed.data[0]

        result = {"success": True, "elder": elder}
        if temporary_password:
            result["login_email"] = request.login_email
            result["temporary_password"] = temporary_password
            result["login_notice"] = (
                "Share this temporary password with the elder directly — "
                "it will not be shown again."
            )
        return result

    @staticmethod
    def list_for_caregiver(caregiver_id: str) -> dict:
        response = (
            supabase_admin.table("elders")
            .select("*")
            .eq("caregiver_id", caregiver_id)
            .execute()
        )
        return {"success": True, "elders": response.data or []}

    @staticmethod
    def get_risk_profile(elder_id: str) -> dict:
        """
        Returns exactly the three fields Component 4 needs
        (age, previous_falls, assistive_device) — this is what
        app.integration.pipeline should call instead of using
        hardcoded defaults, once elder profiles are populated.
        """
        response = (
            supabase_admin.table("elders")
            .select("age, previous_falls, assistive_device")
            .eq("id", elder_id)
            .limit(1)
            .execute()
        )
        if not response.data:
            raise HTTPException(status_code=404, detail="Elder profile not found.")
        return response.data[0]

    @staticmethod
    def get_by_id(elder_id: str, caregiver_id: str) -> dict:
        """Scoped to the requesting caregiver so one caregiver can't
        read another caregiver's elder by guessing an id."""
        response = (
            supabase_admin.table("elders")
            .select("*")
            .eq("id", elder_id)
            .eq("caregiver_id", caregiver_id)
            .limit(1)
            .execute()
        )
        if not response.data:
            raise HTTPException(status_code=404, detail="Elder profile not found.")
        return {"success": True, "elder": response.data[0]}

    # Resolves the CALLING Elder's own profile from their authenticated
    # user id — never accepts an elder_id from the client for this
    # endpoint, so an Elder can never view another elder's profile
    # this way.
    @staticmethod
    def get_my_profile(user_id: str) -> dict:
        response = (
            supabase_admin.table("elders")
            .select("*")
            .eq("user_id", user_id)
            .limit(1)
            .execute()
        )
        if not response.data:
            raise HTTPException(
                status_code=404,
                detail="Your elder profile could not be found.",
            )
        return {"success": True, "elder": response.data[0]}

    # UNAUTHENTICATED by design (the standalone legacy Elder App has no
    # login — see the router's own comment), and returns ONLY
    # id/name/age, never previous_falls/address/phone/caregiver_id/
    # avatar_id, since those either feed Component 4's model input or
    # are contact/sensitive info with no reason to be exposed to a
    # device that identifies itself with nothing more than knowing the
    # elder_id.
    @staticmethod
    def get_public(elder_id: str) -> dict:
        response = (
            supabase_admin.table("elders")
            .select("id, name, age")
            .eq("id", elder_id)
            .limit(1)
            .execute()
        )
        if not response.data:
            raise HTTPException(status_code=404, detail="Elder profile not found.")
        return {"success": True, "elder": response.data[0]}

    @staticmethod
    def delete(elder_id: str, caregiver_id: str) -> dict:
        """Scoped to the requesting caregiver — same reasoning as
        get_by_id. Deleting an elder does NOT cascade-delete their
        alert history (see app/alerts) by design, so past records
        remain auditable; add ON DELETE CASCADE in SQL if you'd
        rather have history disappear with the elder."""
        response = (
            supabase_admin.table("elders")
            .delete()
            .eq("id", elder_id)
            .eq("caregiver_id", caregiver_id)
            .execute()
        )
        if not response.data:
            raise HTTPException(status_code=404, detail="Elder profile not found.")
        return {"success": True, "message": "Elder profile deleted."}

    @staticmethod
    def update(elder_id: str, caregiver_id: str, request: UpdateElderRequest) -> dict:
        # Ownership-filtered update: any authenticated caregiver who
        # knew/guessed another caregiver's elder_id must NOT be able to
        # update that elder's profile — both .eq("id", ...) and
        # .eq("caregiver_id", ...) are required below.
        #
        # ADDED (avatar picker feature): avatar_id needs no special
        # handling here — it's just another optional field on
        # UpdateElderRequest, so it flows through this existing
        # model_dump()-based update_data construction automatically
        # whenever the Flutter app sends it.
        update_data = {
            k: v
            for k, v in request.model_dump(exclude={"grant_login", "login_email"}).items()
            if v is not None
        }
        if not update_data and not (request.grant_login and request.login_email):
            raise HTTPException(status_code=400, detail="No fields were provided.")

        elder = None
        if update_data:
            response = (
                supabase_admin
                .table("elders")
                .update(update_data)
                .eq("id", elder_id)
                .eq("caregiver_id", caregiver_id)
                .execute()
            )
            if not response.data:
                raise HTTPException(status_code=404, detail="Elder profile not found.")
            elder = response.data[0]
        else:
            existing = ElderService.get_by_id(elder_id, caregiver_id)
            elder = existing["elder"]

        # Grant login access to an EXISTING elder profile. If this
        # elder already has user_id set, do NOT create a second
        # account.
        temporary_password = None
        if request.grant_login and request.login_email:
            if elder.get("user_id"):
                raise HTTPException(
                    status_code=400,
                    detail="This elder already has app access linked.",
                )
            temporary_password = ElderService._provision_login(
                elder["id"], elder["name"], request.login_email
            )
            refreshed = (
                supabase_admin.table("elders").select("*").eq("id", elder_id).limit(1).execute()
            )
            if refreshed.data:
                elder = refreshed.data[0]

        result = {"success": True, "elder": elder}
        if temporary_password:
            result["login_email"] = request.login_email
            result["temporary_password"] = temporary_password
            result["login_notice"] = (
                "Share this temporary password with the elder directly — "
                "it will not be shown again."
            )
        return result
