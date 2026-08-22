from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Request

from fingerspeak_api.api.dependencies import ActorDep, DBSession, get_profile_for_actor
from fingerspeak_api.schemas import AshaChatRequest, AshaChatResponse
from fingerspeak_api.services.asha import AshaService

router = APIRouter(prefix="/asha", tags=["Asha"])


def get_asha_service(request: Request) -> AshaService:
    return request.app.state.asha_service


AshaServiceDep = Annotated[AshaService, Depends(get_asha_service)]


@router.post("/chat", response_model=AshaChatResponse)
async def chat_with_asha(
    payload: AshaChatRequest,
    db: DBSession,
    actor: ActorDep,
    service: AshaServiceDep,
) -> AshaChatResponse:
    context = payload.patient_context
    if context is not None and context.profile_id is not None:
        # Patient context may influence an answer, so caregiver grants are not sufficient.
        await get_profile_for_actor(db, context.profile_id, actor, owner_only=True)
    return await service.chat(payload)
