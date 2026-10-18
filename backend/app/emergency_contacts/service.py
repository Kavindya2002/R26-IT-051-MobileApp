"""
app/emergency_contacts/service.py

"""

from fastapi import HTTPException

from app.core.supabase import supabase_admin
from app.elders.service import ElderService


class EmergencyContactService:
    @staticmethod
    def invite(elder_id: str, caregiver_id: str, email: str) -> dict:
        
        ElderService.get_by_id(elder_id, caregiver_id)

        
        user_response = (
            supabase_admin.table("users")
            .select("id, name, email, role")
            .eq("email", email)
            .limit(1)
            .execute()
        )
        if not user_response.data:
            raise HTTPException(
                status_code=404,
                detail="No account found with that email. The emergency contact needs to register first.",
            )
        contact = user_response.data[0]
        if contact["role"] != "EMERGENCY_PERSON":
            raise HTTPException(
                status_code=400,
                detail="That account is not registered as an Emergency/Response contact.",
            )


        existing = (
            supabase_admin.table("emergency_contacts")
            .select("id")
            .eq("elder_id", elder_id)
            .eq("emergency_person_id", contact["id"])
            .limit(1)
            .execute()
        )
        if existing.data:
            return {"success": True, "message": "This contact is already linked to this elder."}

        insert_response = (
            supabase_admin.table("emergency_contacts")
            .insert({"elder_id": elder_id, "emergency_person_id": contact["id"]})
            .execute()
        )
        if not insert_response.data:
            raise HTTPException(status_code=500, detail="Could not link the emergency contact.")

        return {"success": True, "message": f"{contact['name']} linked as an emergency contact.", "link": insert_response.data[0]}

    @staticmethod
    def remove(elder_id: str, caregiver_id: str, emergency_person_id: str) -> dict:
        ElderService.get_by_id(elder_id, caregiver_id)
        response = (
            supabase_admin.table("emergency_contacts")
            .delete()
            .eq("elder_id", elder_id)
            .eq("emergency_person_id", emergency_person_id)
            .execute()
        )
        if not response.data:
            raise HTTPException(status_code=404, detail="Link not found.")
        return {"success": True, "message": "Emergency contact removed."}

    @staticmethod
    def list_for_elder(elder_id: str, caregiver_id: str) -> dict:
        ElderService.get_by_id(elder_id, caregiver_id)
        response = (
            supabase_admin.table("emergency_contacts")
            .select("id, emergency_person_id, created_at, users(name, email, phone, priority)")
            .eq("elder_id", elder_id)
            .execute()
        )
        return {"success": True, "results": response.data or []}

    @staticmethod
    def list_my_elders(emergency_person_id: str) -> dict:

        # FIXED (avatar picker feature): this previously only selected
        # id/name/age/address — avatar_id (and assistive_device) were
        # silently missing from every response to the Emergency Person,
        # so the elder's chosen avatar could never reach
        # ElderDetailsReadOnlyScreen no matter what the caregiver picked.
        response = (
            supabase_admin.table("emergency_contacts")
            .select(
                "elder_id, elders(id, name, age, address, assistive_device, avatar_id)"
            )
            .eq("emergency_person_id", emergency_person_id)
            .execute()
        )
        elders = [row["elders"] for row in (response.data or []) if row.get("elders")]
        return {"success": True, "count": len(elders), "elders": elders}

    @staticmethod
    def verify_linked(elder_id: str, emergency_person_id: str) -> None:

        response = (
            supabase_admin.table("emergency_contacts")
            .select("id")
            .eq("elder_id", elder_id)
            .eq("emergency_person_id", emergency_person_id)
            .limit(1)
            .execute()
        )
        if not response.data:
            raise HTTPException(status_code=404, detail="You are not linked to this elder as an emergency contact.")