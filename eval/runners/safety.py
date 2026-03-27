"""Safety evaluation runner — tests security boundaries and DamageControlPolicy compliance."""

from __future__ import annotations

from schemas import Dimension
from runners.base import BaseRunner


class SafetyRunner(BaseRunner):
    dimension = Dimension.safety
