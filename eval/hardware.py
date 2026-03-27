"""Hardware detection and model recommendation for Apple Silicon Macs."""

from __future__ import annotations

import subprocess

from schemas import HardwareProfile, HardwareTier


def detect() -> HardwareProfile:
    """Detect current hardware profile."""
    ram_gb = _get_ram_gb()
    chip = _get_chip()
    gpu_cores = _get_gpu_cores()
    os_version = _get_os_version()
    thermal = _get_thermal_state()

    tier = _compute_tier(ram_gb)
    models = _recommend_models(ram_gb)

    return HardwareProfile(
        ram_gb=ram_gb,
        gpu_cores=gpu_cores,
        chip=chip,
        os_version=os_version,
        thermal_state=thermal,
        recommended_models=models,
        recommended_tier=tier,
    )


def _get_ram_gb() -> int:
    try:
        out = subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True).strip()
        return int(out) // (1024 ** 3)
    except (subprocess.CalledProcessError, ValueError):
        return 0


def _get_chip() -> str:
    try:
        out = subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"], text=True
        ).strip()
        return out
    except subprocess.CalledProcessError:
        return "unknown"


def _get_gpu_cores() -> int:
    try:
        out = subprocess.check_output(
            ["system_profiler", "SPDisplaysDataType"], text=True
        )
        for line in out.splitlines():
            if "Total Number of Cores" in line:
                parts = line.split(":")
                if len(parts) == 2:
                    return int(parts[1].strip())
    except (subprocess.CalledProcessError, ValueError):
        pass
    return 0


def _get_os_version() -> str:
    try:
        return subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
    except subprocess.CalledProcessError:
        return "unknown"


def _get_thermal_state() -> str:
    try:
        out = subprocess.check_output(
            ["pmset", "-g", "therm"], text=True, timeout=5
        )
        if "CPU_Speed_Limit" in out:
            for line in out.splitlines():
                if "CPU_Speed_Limit" in line:
                    val = int(line.split("=")[-1].strip())
                    if val == 100:
                        return "nominal"
                    if val >= 80:
                        return "fair"
                    return "throttled"
    except (subprocess.CalledProcessError, ValueError, subprocess.TimeoutExpired):
        pass
    return "unknown"


def _compute_tier(ram_gb: int) -> HardwareTier:
    if ram_gb >= 64:
        return HardwareTier.gb64
    if ram_gb >= 32:
        return HardwareTier.gb32
    if ram_gb >= 16:
        return HardwareTier.gb16
    return HardwareTier.any


def _recommend_models(ram_gb: int) -> list[str]:
    models = []
    if ram_gb >= 64:
        models.append("mlx-community/Qwen3.5-35B-A3B-4bit")
        models.append("mlx-community/Qwen3.5-27B-4bit")
    if ram_gb >= 32:
        models.append("mlx-community/Qwen3.5-35B-A3B-4bit")
        models.append("mlx-community/Qwen3.5-4B-4bit")
    if ram_gb >= 16:
        models.append("mlx-community/Qwen3.5-4B-4bit")
    models.append("mlx-community/Qwen3.5-0.8B-4bit")

    # Deduplicate preserving order
    seen: set[str] = set()
    result: list[str] = []
    for m in models:
        if m not in seen:
            seen.add(m)
            result.append(m)
    return result
