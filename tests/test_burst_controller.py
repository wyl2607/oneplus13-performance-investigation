#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_tool(filename, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


CTRL = load_tool("simulate-burst-controller.py", "ctrl")


class ControllerReplayTests(unittest.TestCase):
    def samples(self, signal, temps=None, foreground=None, screen=None, step=10):
        temps = temps or [40] * len(signal)
        foreground = foreground or [1] * len(signal)
        screen = screen or [1] * len(signal)
        return [
            {
                "t_ms": i * step,
                "burst_signal": signal[i],
                "junction_c": temps[i],
                "foreground": foreground[i],
                "screen_on": screen[i],
            }
            for i in range(len(signal))
        ]

    def replay(self, samples):
        return CTRL.replay(
            samples,
            trigger_samples=2,
            min_hold_ms=20,
            max_boost_ms=50,
            cooldown_ms=30,
            thermal_gate_c=88,
        )

    def test_two_sample_trigger_and_release_after_hold(self):
        r = self.replay(self.samples([0, 1, 1, 1, 0, 0, 0, 0]))
        entries = [x for x in r["transitions"] if x["to"] == "BOOST"]
        exits = [x for x in r["transitions"] if x["from"] == "BOOST"]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["t_ms"], 20)
        self.assertEqual(exits[0]["reason"], "signal_cleared_after_hold")
        self.assertGreaterEqual(exits[0]["t_ms"] - entries[0]["t_ms"], 20)

    def test_thermal_gate_aborts_boost(self):
        temps = [40, 40, 40, 89, 89, 40, 40]
        r = self.replay(self.samples([0, 1, 1, 1, 1, 0, 0], temps=temps))
        self.assertEqual(r["summary"]["thermal_aborts"], 1)
        self.assertIn(
            "thermal_gate",
            [x["reason"] for x in r["transitions"]],
        )

    def test_background_signal_never_enters_boost(self):
        r = self.replay(
            self.samples(
                [1, 1, 1, 1],
                foreground=[0, 0, 0, 0],
            )
        )
        self.assertEqual(r["summary"]["boost_entries"], 0)

    def test_max_boost_forces_cooldown(self):
        r = self.replay(self.samples([1] * 12))
        reasons = [x["reason"] for x in r["transitions"]]
        self.assertIn("max_boost", reasons)
        self.assertGreaterEqual(r["summary"]["boost_entries"], 1)

    def test_invalid_timing_rejected(self):
        with self.assertRaisesRegex(ValueError, "max_boost_ms"):
            CTRL.replay(
                self.samples([0, 1]),
                trigger_samples=1,
                min_hold_ms=100,
                max_boost_ms=50,
                cooldown_ms=30,
                thermal_gate_c=88,
            )


if __name__ == "__main__":
    unittest.main()
