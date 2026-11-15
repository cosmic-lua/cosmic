# qr vectors

`vectors.txt` holds QR codes drawn by two encoders that agree module for
module: Project Nayuki's qrcodegen 1.8.0 and python-qrcode 8.2, both from
PyPI. [`cosmic/qr_test.tl`] holds [`cosmic.qr`] to them. This wrote it, run
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

[`cosmic.qr`]: ../../cosmic/qr.tl
[`cosmic/qr_test.tl`]: ../../cosmic/qr_test.tl
