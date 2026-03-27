"""Intelligence (MCQ) evaluation runner."""

from __future__ import annotations

from schemas import Dimension
from runners.base import BaseRunner


class IntelligenceRunner(BaseRunner):
    dimension = Dimension.intelligence
