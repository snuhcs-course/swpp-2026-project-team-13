"""Echo's generated UI sprites; no score-bank or external image dependency."""
import json
from pathlib import Path
import struct
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "frontend/IPadApp/IPadApp/Assets.xcassets"


class EchoIntervalAssetsTests(unittest.TestCase):
    def test_all_four_character_states_are_real_transparent_pngs_with_bounded_size(self):
        total = 0
        dimensions = set()
        for state in ["waiting", "singing", "puzzled", "happy"]:
            folder = ASSETS / f"echo-dragon-{state}.imageset"
            manifest = json.loads((folder / "Contents.json").read_text())
            self.assertEqual(len(manifest["images"]), 1)
            source = folder / manifest["images"][0]["filename"]
            data = source.read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", data[16:29])
            self.assertEqual(depth, 8)
            self.assertEqual(color, 6, "Sprites must retain their alpha channel")
            self.assertEqual(interlace, 0)
            self.assertGreaterEqual(width, 512)
            self.assertEqual(width, height)
            self.assertLessEqual(width, 2048)
            dimensions.add((width, height))
            compressed = bytearray()
            position = 8
            while position < len(data):
                length = struct.unpack(">I", data[position:position + 4])[0]
                if data[position + 4:position + 8] == b"IDAT":
                    compressed.extend(data[position + 8:position + 8 + length])
                position += length + 12
            pixels = zlib.decompress(compressed)
            self.assertEqual(len(pixels), height * (1 + width * 4))
            # First pixel's predictors are zero for all PNG row filters.
            self.assertEqual(pixels[4], 0, "The image corner must actually be transparent")
            total += len(data)
        self.assertEqual(len(dimensions), 1, "Expression swaps use the same canvas")
        self.assertLess(total, 8 * 1024 * 1024)
        print(f"Four transparent Echo sprites: {total / 1048576:.2f} MiB")


if __name__ == "__main__":
    unittest.main()
