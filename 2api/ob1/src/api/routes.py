"""OpenAI-compatible API routes — proxies to OB-1 backend."""

from __future__ import annotations

import json
import time
import uuid
from typing import Any, AsyncGenerator, Optional

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, StreamingResponse

from ..core.auth import verify_api_key
from ..core.logger import get_logger
from ..core.models import AnthropicMessagesRequest, ChatCompletionRequest
from ..services.ob1_client import OB1Client
from ..services.token_manager import OB1TokenManager

log = get_logger("routes")

router = APIRouter()

_token_manager: Optional[OB1TokenManager] = None
_ob1_client: Optional[OB1Client] = None


def init(token_manager: OB1TokenManager, ob1_client: OB1Client):
    global _token_manager, _ob1_client
    _token_manager = token_manager
    _ob1_client = ob1_client


def _require_token_manager() -> OB1TokenManager:
    if _token_manager is None:
        raise RuntimeError("Token manager is not initialized")
    return _token_manager


def _require_ob1_client() -> OB1Client:
    if _ob1_client is None:
        raise RuntimeError("OB1 client is not initialized")
    return _ob1_client


@router.get("/v1/models")
async def list_models(_: str = Depends(verify_api_key)):
    token_manager = _require_token_manager()
    ob1_client = _require_ob1_client()
    api_key = await token_manager.get_api_key()
    if not api_key:
        return {"object": "list", "data": []}
    raw = await ob1_client.fetch_models(api_key)
    models = []
    for m in raw:
        models.append(
            {
                "id": m["id"],
                "object": "model",
                "created": m.get("created", 0),
                "owned_by": m["id"].split("/")[0] if "/" in m["id"] else "ob1",
                "name": m.get("name", m["id"]),
            }
        )
    return {"object": "list", "data": models}


@router.post("/v1/chat/completions")
async def chat_completions(
    request: ChatCompletionRequest,
    _: str = Depends(verify_api_key),
):
    messages = [{"role": m.role, "content": m.content} for m in request.messages]
    resp = await _send_chat_request(
        messages=messages,
        model=request.model,
        stream=request.stream,
        temperature=request.temperature,
        top_p=request.top_p,
        max_tokens=request.max_tokens,
    )
    if isinstance(resp, JSONResponse):
        return resp

    if request.stream:
        log.debug("Streaming response started")
        return StreamingResponse(
            _proxy_stream(resp, _token_manager),
            media_type="text/event-stream",
        )
    else:
        data = resp.json()
        usage = data.get("usage", {})
        _track_usage(usage)
        log.info(
            "Chat response: model=%s prompt_tokens=%d completion_tokens=%d",
            data.get("model", "?"),
            usage.get("prompt_tokens", 0),
            usage.get("completion_tokens", 0),
        )
        return JSONResponse(content=data)


@router.post("/v1/messages")
async def anthropic_messages(
    request: AnthropicMessagesRequest,
    _: str = Depends(verify_api_key),
):
    messages = _anthropic_to_openai_messages(request)
    resp = await _send_chat_request(
        messages=messages,
        model=request.model,
        stream=request.stream,
        temperature=request.temperature,
        top_p=request.top_p,
        max_tokens=request.max_tokens,
    )
    if isinstance(resp, JSONResponse):
        return resp

    if request.stream:
        return StreamingResponse(
            _proxy_stream_anthropic(resp, request.model),
            media_type="text/event-stream",
        )

    data = resp.json()
    usage = data.get("usage", {})
    _track_usage(usage)
    await resp.aclose()
    return JSONResponse(content=_openai_to_anthropic_response(data, request.model))


async def _send_chat_request(
    *,
    messages: list[dict[str, Any]],
    model: str,
    stream: bool,
    temperature: float | None,
    top_p: float | None,
    max_tokens: int | None,
):
    token_manager = _require_token_manager()
    ob1_client = _require_ob1_client()
    api_key = await token_manager.get_api_key()
    if not api_key:
        log.warning("No valid OB-1 token available")
        return JSONResponse(
            status_code=503,
            content={"error": "No valid OB-1 token. Run ob1 auth to login."},
        )

    resolved_model = await _resolve_model_name(model, api_key)

    log.info(
        "Chat request: model=%s resolved_model=%s stream=%s messages=%d",
        model,
        resolved_model,
        stream,
        len(messages),
    )

    try:
        resp = await ob1_client.chat(
            api_key=api_key,
            messages=messages,
            model=resolved_model,
            stream=stream,
            temperature=temperature,
            top_p=top_p,
            max_tokens=max_tokens,
        )
    except Exception as e:
        log.error("Backend error: %s", e)
        return JSONResponse(status_code=502, content={"error": f"Backend error: {e}"})

    if resp.status_code == 401:
        await resp.aclose()
        log.warning("Token rejected (401), refreshing...")
        ok = await token_manager.refresh()
        if not ok:
            log.error("Token refresh failed")
            return JSONResponse(
                status_code=401, content={"error": "Token expired and refresh failed"}
            )
        api_key = await token_manager.get_api_key()
        if not api_key:
            return JSONResponse(
                status_code=401, content={"error": "Token refresh failed"}
            )
        try:
            resp = await ob1_client.chat(
                api_key=api_key,
                messages=messages,
                model=resolved_model,
                stream=stream,
                temperature=temperature,
                top_p=top_p,
                max_tokens=max_tokens,
            )
        except Exception as e:
            log.error("Backend error after refresh: %s", e)
            return JSONResponse(
                status_code=502, content={"error": f"Backend error: {e}"}
            )

    if resp.status_code != 200:
        try:
            body = (await resp.aread()).decode()
        except Exception:
            body = "unable to read response body"
        await resp.aclose()
        log.error("OB-1 returned %d: %s", resp.status_code, body[:200])
        return JSONResponse(
            status_code=resp.status_code,
            content={"error": f"OB-1 returned {resp.status_code}: {body[:500]}"},
        )

    return resp


async def _resolve_model_name(requested_model: str, api_key: str) -> str:
    ob1_client = _require_ob1_client()
    raw_models = await ob1_client.fetch_models(api_key)
    available = [item.get("id") for item in raw_models if item.get("id")]
    if requested_model in available:
        return requested_model

    anthropic_prefixed = f"anthropic/{requested_model}"
    if anthropic_prefixed in available:
        return anthropic_prefixed

    if requested_model.startswith("claude-"):
        lowered = requested_model.lower()
        family = None
        for candidate in ("haiku", "sonnet", "opus"):
            if candidate in lowered:
                family = candidate
                break

        if family:
            family_matches = [
                model_id
                for model_id in available
                if model_id.startswith(f"anthropic/claude-{family}")
            ]
            if family_matches:
                return sorted(family_matches)[-1]

        anthropic_models = [
            model_id for model_id in available if model_id.startswith("anthropic/")
        ]
        preferred_order = ["anthropic/claude-sonnet-4.6", "anthropic/claude-opus-4.6"]
        for model_id in preferred_order:
            if model_id in anthropic_models:
                return model_id
        if anthropic_models:
            return sorted(anthropic_models)[-1]

    return requested_model


def _anthropic_to_openai_messages(
    request: AnthropicMessagesRequest,
) -> list[dict[str, Any]]:
    messages: list[dict[str, Any]] = []
    if request.system:
        messages.append({"role": "system", "content": _flatten_content(request.system)})
    for message in request.messages:
        messages.append(
            {"role": message.role, "content": _flatten_content(message.content)}
        )
    return messages


def _flatten_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text" and isinstance(block.get("text"), str):
                parts.append(block["text"])
            elif block.get("type") == "tool_result":
                parts.append(_flatten_content(block.get("content", "")))
        return "\n".join(part for part in parts if part)
    return str(content)


def _openai_to_anthropic_response(data: dict[str, Any], model: str) -> dict[str, Any]:
    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    text = _flatten_content(message.get("content", ""))
    usage = data.get("usage") or {}
    return {
        "id": data.get("id", f"msg_{uuid.uuid4().hex}"),
        "type": "message",
        "role": "assistant",
        "content": [{"type": "text", "text": text}],
        "model": data.get("model", model),
        "stop_reason": _map_finish_reason(choice.get("finish_reason")),
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        },
    }


def _map_finish_reason(reason: Optional[str]) -> str:
    if reason in {None, "stop"}:
        return "end_turn"
    if reason == "length":
        return "max_tokens"
    if reason == "tool_calls":
        return "tool_use"
    return reason or "end_turn"


async def _proxy_stream_anthropic(resp, model: str) -> AsyncGenerator[str, None]:
    message_id = f"msg_{uuid.uuid4().hex}"
    sent_start = False
    content_started = False
    usage: dict[str, Any] = {"input_tokens": 0, "output_tokens": 0}
    stop_reason = "end_turn"
    try:
        async for line in resp.aiter_lines():
            if not line or not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue

            if not sent_start:
                prompt_tokens = ((chunk.get("usage") or {}).get("prompt_tokens")) or 0
                usage["input_tokens"] = prompt_tokens
                yield _anthropic_sse(
                    "message_start",
                    {
                        "type": "message_start",
                        "message": {
                            "id": message_id,
                            "type": "message",
                            "role": "assistant",
                            "content": [],
                            "model": chunk.get("model", model),
                            "stop_reason": None,
                            "stop_sequence": None,
                            "usage": usage,
                        },
                    },
                )
                sent_start = True

            delta = (chunk.get("choices") or [{}])[0].get("delta") or {}
            finish_reason = (chunk.get("choices") or [{}])[0].get("finish_reason")
            text = delta.get("content")
            if text:
                if not content_started:
                    yield _anthropic_sse(
                        "content_block_start",
                        {
                            "type": "content_block_start",
                            "index": 0,
                            "content_block": {"type": "text", "text": ""},
                        },
                    )
                    content_started = True
                yield _anthropic_sse(
                    "content_block_delta",
                    {
                        "type": "content_block_delta",
                        "index": 0,
                        "delta": {"type": "text_delta", "text": text},
                    },
                )
            chunk_usage = chunk.get("usage") or {}
            if chunk_usage.get("completion_tokens") is not None:
                usage["output_tokens"] = chunk_usage.get(
                    "completion_tokens", usage["output_tokens"]
                )
                _track_usage(chunk_usage)
            if finish_reason:
                stop_reason = _map_finish_reason(finish_reason)

        if not sent_start:
            yield _anthropic_sse(
                "message_start",
                {
                    "type": "message_start",
                    "message": {
                        "id": message_id,
                        "type": "message",
                        "role": "assistant",
                        "content": [],
                        "model": model,
                        "stop_reason": None,
                        "stop_sequence": None,
                        "usage": usage,
                    },
                },
            )
        if not content_started:
            yield _anthropic_sse(
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
            )
        yield _anthropic_sse(
            "content_block_stop", {"type": "content_block_stop", "index": 0}
        )
        yield _anthropic_sse(
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                "usage": {"output_tokens": usage["output_tokens"]},
            },
        )
        yield _anthropic_sse("message_stop", {"type": "message_stop"})
    finally:
        await resp.aclose()


def _anthropic_sse(event: str, data: dict[str, Any]) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


def _track_usage(usage: dict):
    """Extract token counts from usage and record cost."""
    pt = usage.get("prompt_tokens", 0)
    ct = usage.get("completion_tokens", 0)
    if pt or ct:
        # Rough OpenRouter-style cost estimate (per 1M tokens)
        cost = pt * 0.000015 + ct * 0.000075
        _require_token_manager().add_cost(cost)
    elif usage:
        _require_token_manager().add_cost(0)


async def _proxy_stream(resp, tm) -> AsyncGenerator[str, None]:
    """Proxy SSE stream from OB-1 backend directly to client."""
    try:
        async for line in resp.aiter_lines():
            if line:
                yield f"{line}\n\n"
                # Extract usage from the final chunk
                if line.startswith("data: ") and '"usage"' in line:
                    try:
                        chunk = json.loads(line[6:])
                        usage = chunk.get("usage") or {}
                        if usage:
                            _track_usage(usage)
                    except Exception:
                        pass
    finally:
        await resp.aclose()
