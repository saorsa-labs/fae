"""Vision/perception evaluation runner."""

from __future__ import annotations

from schemas import Dimension
from runners.base import BaseRunner


class VisionRunner(BaseRunner):
    dimension = Dimension.vision
