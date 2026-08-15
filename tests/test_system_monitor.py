#!/usr/bin/env python3

import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch


MONITOR = (
    Path.home()
    / "red-core/bin/.local/bin/redcore-system-monitor"
)

SOURCE = MONITOR.read_text()

MAIN_MARKER = """# ============================================================
# MAIN LOOP
# ============================================================
"""

if MAIN_MARKER not in SOURCE:
    raise RuntimeError("MAIN LOOP marker not found")

# Load the REAL Red Core implementation, but do not run
# its infinite main loop.
SOURCE = SOURCE.split(
    MAIN_MARKER,
    1
)[0]

# The production source performs its initial GPU discovery
# before entering MAIN LOOP. Disable that one startup call
# only for the test environment.
needle = """rebuild_gpu_monitors()


def gpu_sample():
"""

replacement = """# Initial production GPU discovery disabled in tests.


def gpu_sample():
"""

if needle not in SOURCE:
    raise RuntimeError(
        "Initial rebuild_gpu_monitors() call not found"
    )

SOURCE = SOURCE.replace(
    needle,
    replacement,
    1
)

ns = {
    "__name__": "redcore_system_monitor_tests"
}

exec(
    compile(
        SOURCE,
        str(MONITOR),
        "exec"
    ),
    ns
)


class FakeMonitor:
    def __init__(self, value=None):
        self._value = value
        self.process = None

    def value(self):
        return self._value


class RedCoreSystemMonitorTests(
    unittest.TestCase
):

    def setUp(self):
        ns["GPU_MONITORS"] = []
        ns["GPU_DEVICES"] = []

    # --------------------------------------------------------
    # AMD
    # --------------------------------------------------------

    def test_amd_sysfs_usage(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = Path(tmp)

            (
                device /
                "gpu_busy_percent"
            ).write_text("37\n")

            monitor = ns["AmdGpuMonitor"]({
                "device": str(device)
            })

            self.assertEqual(
                monitor.value(),
                37.0
            )

    def test_amd_missing_usage_is_null(self):
        with tempfile.TemporaryDirectory() as tmp:
            monitor = ns["AmdGpuMonitor"]({
                "device": tmp
            })

            self.assertIsNone(
                monitor.value()
            )

    # --------------------------------------------------------
    # INTEL
    # --------------------------------------------------------

    def test_intel_missing_backend_is_null(self):
        with patch.object(
            ns["shutil"],
            "which",
            return_value=None
        ):
            monitor = ns["IntelGpuMonitor"]()

        self.assertIsNone(
            monitor.value()
        )

        self.assertIsNone(
            monitor.process
        )

    # --------------------------------------------------------
    # NVIDIA
    # --------------------------------------------------------

    def test_nvidia_missing_backend_is_null(self):
        with patch.object(
            ns["shutil"],
            "which",
            return_value=None
        ):
            monitor = ns["NvidiaGpuMonitor"](0)

        self.assertIsNone(
            monitor.value()
        )

        self.assertIsNone(
            monitor.process
        )

    def test_nvidia_multiple_gpu_indices(self):
        fake_result = MagicMock()

        fake_result.stdout = (
            "0\n"
            "1\n"
            "2\n"
        )

        with patch.object(
            ns["shutil"],
            "which",
            return_value="/usr/bin/nvidia-smi"
        ), patch.object(
            ns["subprocess"],
            "run",
            return_value=fake_result
        ):
            result = ns["nvidia_indices"]()

        self.assertEqual(
            result,
            [0, 1, 2]
        )

    def test_nvidia_invalid_index_output_ignored(self):
        fake_result = MagicMock()

        fake_result.stdout = (
            "0\n"
            "N/A\n"
            "1\n"
            "garbage\n"
        )

        with patch.object(
            ns["shutil"],
            "which",
            return_value="/usr/bin/nvidia-smi"
        ), patch.object(
            ns["subprocess"],
            "run",
            return_value=fake_result
        ):
            result = ns["nvidia_indices"]()

        self.assertEqual(
            result,
            [0, 1]
        )

    # --------------------------------------------------------
    # HYBRID / MULTI GPU
    # --------------------------------------------------------

    def test_hybrid_uses_busiest_gpu(self):
        ns["GPU_DEVICES"] = [
            {
                "vendor": "intel"
            },
            {
                "vendor": "nvidia"
            }
        ]

        ns["GPU_MONITORS"] = [
            (
                "intel",
                FakeMonitor(12)
            ),
            (
                "nvidia",
                FakeMonitor(68)
            )
        ]

        vendor, usage = (
            ns["gpu_sample"]()
        )

        self.assertEqual(
            vendor,
            "nvidia"
        )

        self.assertEqual(
            usage,
            68
        )

    def test_hybrid_can_switch_active_gpu(self):
        ns["GPU_DEVICES"] = [
            {
                "vendor": "intel"
            },
            {
                "vendor": "nvidia"
            }
        ]

        intel = FakeMonitor(74)
        nvidia = FakeMonitor(4)

        ns["GPU_MONITORS"] = [
            ("intel", intel),
            ("nvidia", nvidia)
        ]

        vendor, usage = (
            ns["gpu_sample"]()
        )

        self.assertEqual(
            (vendor, usage),
            ("intel", 74)
        )

        intel._value = 2
        nvidia._value = 81

        vendor, usage = (
            ns["gpu_sample"]()
        )

        self.assertEqual(
            (vendor, usage),
            ("nvidia", 81)
        )

    # --------------------------------------------------------
    # NO FAKE VALUES
    # --------------------------------------------------------

    def test_unavailable_gpu_usage_remains_null(self):
        ns["GPU_DEVICES"] = [
            {
                "vendor": "amd"
            }
        ]

        ns["GPU_MONITORS"] = [
            (
                "amd",
                FakeMonitor(None)
            )
        ]

        vendor, usage = (
            ns["gpu_sample"]()
        )

        self.assertEqual(
            vendor,
            "amd"
        )

        self.assertIsNone(
            usage
        )

    def test_unknown_gpu_is_not_fake_zero(self):
        ns["GPU_DEVICES"] = []
        ns["GPU_MONITORS"] = []

        vendor, usage = (
            ns["gpu_sample"]()
        )

        self.assertEqual(
            vendor,
            "unknown"
        )

        self.assertIsNone(
            usage
        )

    # --------------------------------------------------------
    # DYNAMIC GPU DISCOVERY
    # --------------------------------------------------------

    def test_rebuild_detects_amd_intel_nvidia(self):
        globals_ = (
            ns["rebuild_gpu_monitors"]
            .__globals__
        )

        fake_devices = [
            {
                "vendor": "amd",
                "device": "/fake/amd"
            },
            {
                "vendor": "intel",
                "device": "/fake/intel"
            }
        ]

        class FakeVendorMonitor:
            def __init__(self, *args):
                self.process = None

            def value(self):
                return None

        old_discover = globals_[
            "discover_drm_gpus"
        ]

        old_name = globals_[
            "gpu_friendly_name"
        ]

        old_indices = globals_[
            "nvidia_indices"
        ]

        old_amd = globals_[
            "AmdGpuMonitor"
        ]

        old_intel = globals_[
            "IntelGpuMonitor"
        ]

        old_nvidia = globals_[
            "NvidiaGpuMonitor"
        ]

        try:
            globals_[
                "discover_drm_gpus"
            ] = lambda: fake_devices

            globals_[
                "gpu_friendly_name"
            ] = lambda: "Test GPUs"

            globals_[
                "nvidia_indices"
            ] = lambda: [0]

            globals_[
                "AmdGpuMonitor"
            ] = FakeVendorMonitor

            globals_[
                "IntelGpuMonitor"
            ] = FakeVendorMonitor

            globals_[
                "NvidiaGpuMonitor"
            ] = FakeVendorMonitor

            ns["rebuild_gpu_monitors"]()

            vendors = [
                vendor
                for vendor, _
                in ns["GPU_MONITORS"]
            ]

            self.assertEqual(
                vendors,
                [
                    "amd",
                    "intel",
                    "nvidia"
                ]
            )

            self.assertEqual(
                ns["GPU_NAME"],
                "Test GPUs"
            )

        finally:
            globals_[
                "discover_drm_gpus"
            ] = old_discover

            globals_[
                "gpu_friendly_name"
            ] = old_name

            globals_[
                "nvidia_indices"
            ] = old_indices

            globals_[
                "AmdGpuMonitor"
            ] = old_amd

            globals_[
                "IntelGpuMonitor"
            ] = old_intel

            globals_[
                "NvidiaGpuMonitor"
            ] = old_nvidia

    def test_gpu_can_disappear(self):
        globals_ = (
            ns["rebuild_gpu_monitors"]
            .__globals__
        )

        class FakeVendorMonitor:
            def __init__(self, *args):
                self.process = None

            def value(self):
                return None

        old_discover = globals_[
            "discover_drm_gpus"
        ]

        old_name = globals_[
            "gpu_friendly_name"
        ]

        old_indices = globals_[
            "nvidia_indices"
        ]

        old_intel = globals_[
            "IntelGpuMonitor"
        ]

        try:
            globals_[
                "IntelGpuMonitor"
            ] = FakeVendorMonitor

            globals_[
                "discover_drm_gpus"
            ] = lambda: [
                {
                    "vendor": "intel",
                    "device": "/fake/intel"
                }
            ]

            globals_[
                "gpu_friendly_name"
            ] = lambda: "Intel Test"

            globals_[
                "nvidia_indices"
            ] = lambda: []

            ns["rebuild_gpu_monitors"]()

            self.assertEqual(
                len(
                    ns["GPU_MONITORS"]
                ),
                1
            )

            # Simulate GPU removal.
            globals_[
                "discover_drm_gpus"
            ] = lambda: []

            globals_[
                "gpu_friendly_name"
            ] = lambda: "Unknown"

            ns["rebuild_gpu_monitors"]()

            self.assertEqual(
                ns["GPU_MONITORS"],
                []
            )

            self.assertEqual(
                ns["GPU_DEVICES"],
                []
            )

        finally:
            globals_[
                "discover_drm_gpus"
            ] = old_discover

            globals_[
                "gpu_friendly_name"
            ] = old_name

            globals_[
                "nvidia_indices"
            ] = old_indices

            globals_[
                "IntelGpuMonitor"
            ] = old_intel

    # --------------------------------------------------------
    # HOT-PLUG / SENSOR REFRESH
    # --------------------------------------------------------

    def test_hardware_event_refreshes_sensors_and_gpu(self):
        globals_ = (
            ns[
                "refresh_hardware_if_needed"
            ].__globals__
        )

        old_sensor = globals_[
            "discover_cpu_temp_sensors"
        ]

        old_gpu = globals_[
            "rebuild_gpu_monitors"
        ]

        gpu_refresh = MagicMock()

        try:
            globals_[
                "discover_cpu_temp_sensors"
            ] = lambda: [
                "/fake/new-cpu-temp"
            ]

            globals_[
                "rebuild_gpu_monitors"
            ] = gpu_refresh

            globals_[
                "hardware_refresh_pending"
            ] = True

            globals_[
                "hardware_refresh_deadline"
            ] = (
                time.monotonic() - 1
            )

            ns[
                "refresh_hardware_if_needed"
            ]()

            self.assertEqual(
                globals_[
                    "CPU_TEMP_SENSORS"
                ],
                [
                    "/fake/new-cpu-temp"
                ]
            )

            gpu_refresh.assert_called_once()

            self.assertFalse(
                globals_[
                    "hardware_refresh_pending"
                ]
            )

        finally:
            globals_[
                "discover_cpu_temp_sensors"
            ] = old_sensor

            globals_[
                "rebuild_gpu_monitors"
            ] = old_gpu

    def test_hardware_events_are_debounced(self):
        globals_ = (
            ns[
                "schedule_hardware_refresh"
            ].__globals__
        )

        ns[
            "schedule_hardware_refresh"
        ]()

        first_deadline = globals_[
            "hardware_refresh_deadline"
        ]

        time.sleep(0.01)

        ns[
            "schedule_hardware_refresh"
        ]()

        second_deadline = globals_[
            "hardware_refresh_deadline"
        ]

        self.assertTrue(
            globals_[
                "hardware_refresh_pending"
            ]
        )

        self.assertGreater(
            second_deadline,
            first_deadline
        )


if __name__ == "__main__":
    unittest.main(
        verbosity=2
    )
