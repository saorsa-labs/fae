"""Freeform evaluation runner — handles all text-based checks."""

from __future__ import annotations

from schemas import Dimension
from runners.base import BaseRunner


class FreeformRunner(BaseRunner):
    dimension = Dimension.freeform
