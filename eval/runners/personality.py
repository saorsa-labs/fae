"""Personality evaluation runner — tests SOUL.md compliance and voice-appropriateness."""

from __future__ import annotations

from schemas import Dimension
from runners.base import BaseRunner


class PersonalityRunner(BaseRunner):
    dimension = Dimension.personality
