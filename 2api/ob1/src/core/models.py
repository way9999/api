"""Pydantic models for OB1 2API."""

from __future__ import annotations
from typing import Any, List, Optional, Union
from pydantic import BaseModel


class ChatMessage(BaseModel):
    role: str
    content: Union[str, list]


class ChatCompletionRequest(BaseModel):
    model: str = "anthropic/claude-opus-4.6"
    messages: List[ChatMessage]
    stream: bool = False
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    max_tokens: Optional[int] = None


class AnthropicMessage(BaseModel):
    role: str
    content: Union[str, List[dict[str, Any]]]


class AnthropicMessagesRequest(BaseModel):
    model: str = "anthropic/claude-opus-4.6"
    messages: List[AnthropicMessage]
    max_tokens: int = 4096
    system: Optional[Union[str, List[dict[str, Any]]]] = None
    stream: bool = False
    temperature: Optional[float] = None
    top_p: Optional[float] = None
