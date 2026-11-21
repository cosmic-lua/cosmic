# qr vectors

`vectors.txt` holds QR codes drawn by two encoders that agree module for
module: Project Nayuki's qrcodegen 1.8.0 and python-qrcode 8.2, both from
PyPI. [`cosmic/qr_test.tl`] holds [`cosmic.qr`] to them, drawing and
reading. This wrote it, run
with both installed as `python3 generate.py > vectors.txt`:

```python
# Writes testdata/qr/vectors.txt: QR codes from Project Nayuki's qrcodegen
# (byte mode, no ECC boost), each checked module for module against python-qrcode.
import random, sys
import qrcode, qrcode.util
from qrcodegen import QrCode, QrSegment

LEVELS = {"L": QrCode.Ecc.LOW, "M": QrCode.Ecc.MEDIUM, "Q": QrCode.Ecc.QUARTILE, "H": QrCode.Ecc.HIGH}
rng = random.Random(18004)
printable = bytes(range(0x20, 0x7f))
cases = [
    (b"HELLO", "M", None, None),
    (b"https://example.com/", "M", None, None),
    ("héllo wörld ✓ 日本".encode(), "Q", None, None),
    (b"01234567890123456789", "L", None, None),
    (b"", "H", None, None),
    (bytes(range(256)), "L", None, None),
    (b"x" * 150, "M", None, None),
    (bytes(rng.choice(printable) for _ in range(140)), "L", None, None),
    (bytes(rng.choice(printable) for _ in range(100)), "H", None, None),
    (bytes(rng.choice(printable) for _ in range(300)), "Q", None, None),
    (bytes(rng.choice(printable) for _ in range(500)), "H", None, None),
    (bytes(rng.choice(printable) for _ in range(2953)), "L", None, None),
]
for m in range(8):
    cases.append((b"cosmic qr mask", "M", m, None))
out = sys.stdout
out.write("# QR codes from Project Nayuki's qrcodegen %s (Python) in byte mode, each the same\n" % "1.8.0")
out.write("# module for module as python-qrcode 8.2 draws it. A case: the text in hex, the level, the mask\n")
out.write("# asked for (auto: the lowest penalty), the version and mask drawn, and a row of hex per\n")
out.write("# line of modules, the leftmost the high bit, padded with light to a whole digit.\n")
for text, level, mask, _ in cases:
    code = QrCode.encode_segments([QrSegment.make_bytes(text)], LEVELS[level], 1, 40, -1 if mask is None else mask, False)
    other = qrcode.QRCode(version=code.get_version(), border=0, mask_pattern=code.get_mask(),
                          error_correction=getattr(qrcode.constants, "ERROR_CORRECT_" + level))
    other.add_data(qrcode.util.QRData(text, mode=qrcode.util.MODE_8BIT_BYTE))
    other.make(fit=False)
    matrix = other.get_matrix()
    n = code.get_size()
    rows = []
    for y in range(n):
        bits = "".join("1" if code.get_module(x, y) else "0" for x in range(n))
        assert [int(c) for c in bits] == [1 if v else 0 for v in matrix[y]], (text[:20], y)
        bits += "0" * (-len(bits) % 4)
        rows.append("%0*x" % (len(bits) // 4, int(bits, 2)))
    out.write("\ntext %s\nlevel %s\nmask %s\nversion %d\ndrawn %d\n" % (text.hex(), level,
              "auto" if mask is None else mask, code.get_version(), code.get_mask()))
    out.write("\n".join(rows) + "\n")
```

`segments.txt` holds codes qrcodegen 1.8.0 drew in numeric,
alphanumeric, mixed and ECI segments, which [`cosmic.qr`] reads but does
not make; [`cosmic/qr_test.tl`] reads each back. This wrote it, run as
`python3 segments.py > segments.txt`:

```python
# Writes testdata/qr/segments.txt: QR codes from Project Nayuki's qrcodegen in
# numeric, alphanumeric, mixed and ECI segments, which cosmic.qr does not make.
import sys
from qrcodegen import QrCode, QrSegment

LEVELS = {"L": QrCode.Ecc.LOW, "M": QrCode.Ecc.MEDIUM, "Q": QrCode.Ecc.QUARTILE, "H": QrCode.Ecc.HIGH}
B, N, A = QrSegment.make_bytes, QrSegment.make_numeric, QrSegment.make_alphanumeric
# Each case: its name, its segments as (kind, text), and the level.
cases = [
    ("numeric", [("N", "0123456789012345678901234567890")], "M"),
    ("numeric, a pair left", [("N", "12345678")], "L"),
    ("numeric, one left", [("N", "1234567")], "H"),
    ("alphanumeric", [("A", "HELLO WORLD $%*+-./: 0123")], "Q"),
    ("alphanumeric, one left", [("A", "ABC")], "M"),
    ("mixed", [("A", "HTTPS://EXAMPLE.COM/"), ("B", "path?q="), ("N", "31415926535")], "M"),
    ("eci utf-8", [("E", "26"), ("B", "snö ☃")], "L"),
    ("numeric, version 10", [("N", "9" * 600)], "L"),
    ("alphanumeric, version 32", [("A", "COSMIC QR " * 150)], "Q"),
    ("numeric, version 30", [("N", "2718281828" * 400)], "L"),
    ("alphanumeric, version 12", [("A", "QR CODE " * 50)], "M"),
    ("eci in two bytes", [("E", "899"), ("B", "two-byte eci")], "M"),
    ("eci in three bytes", [("E", "20000"), ("B", "three-byte eci")], "M"),
]
MAKE = {"N": N, "A": A, "B": lambda t: B(t.encode()), "E": lambda t: QrSegment.make_eci(int(t))}
out = sys.stdout
out.write("# QR codes from Project Nayuki's qrcodegen 1.8.0 (Python) in the segments named. A case: its\n")
out.write("# name, the text it reads as in hex, the level, the version and mask drawn, and a row of hex per\n")
out.write("# line of modules, the leftmost the high bit, padded with light to a whole digit.\n")
for name, segs, level in cases:
    code = QrCode.encode_segments([MAKE[k](t) for k, t in segs], LEVELS[level], 1, 40, -1, False)
    text = "".join(t for k, t in segs if k != "E").encode()
    n = code.get_size()
    rows = []
    for y in range(n):
        bits = "".join("1" if code.get_module(x, y) else "0" for x in range(n))
        bits += "0" * (-len(bits) % 4)
        rows.append("%0*x" % (len(bits) // 4, int(bits, 2)))
    out.write("\nname %s\ntext %s\nlevel %s\nversion %d\ndrawn %d\n" % (name, text.hex(), level,
              code.get_version(), code.get_mask()))
    out.write("\n".join(rows) + "\n")
```

[`cosmic.qr`]: ../../cosmic/qr.tl
[`cosmic/qr_test.tl`]: ../../cosmic/qr_test.tl
