"""Generate a deterministic short PCM click, used only by the metronome sampler."""
import io
import math
from pathlib import Path
import struct
import wave

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "frontend/IPadApp/IPadApp/Resources/sori-click-v1.wav"


def build():
    rate = 44100
    count = 2205
    samples = []
    for i in range(count):
        t = i / rate
        attack = min(1.0, t / .001)
        tone = (math.sin(2 * math.pi * 1500 * t) + .3 * math.sin(2 * math.pi * 3000 * t)) / 1.3
        samples.append(round(24000 * attack * math.exp(-100 * t) * tone))
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(rate)
        f.writeframes(struct.pack("<" + "h" * count, *samples))
    data = bytearray(buffer.getvalue())
    # Standard WAV sample metadata: MIDI root C4, no loops.
    sample = struct.pack("<9I", 0, 0, round(1_000_000_000/rate), 60, 0, 0, 0, 0, 0)
    data += b"smpl" + struct.pack("<I", len(sample)) + sample
    data[4:8] = struct.pack("<I", len(data) - 8)
    TARGET.write_bytes(data)
    print("Generated " + str(TARGET))


if __name__ == "__main__":
    build()
