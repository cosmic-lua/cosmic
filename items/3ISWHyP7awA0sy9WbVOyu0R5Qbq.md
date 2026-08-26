## Capture

Release.yml's perf gate has refused to publish since 2026-08-24. The
2026-08-25 run (32818853162) measured cleanly and flagged, after the
gate's own retry: json_decode_large 798.63µs -> 891.35µs (+11.6%,
noise ±10.0%) and codec_base64_roundtrip_64k 132.05µs -> 159.82µs
(+21.0%, noise ±10.0%), against baseline 2026-08-23-d71d7f1; 9
scenarios got faster (literal parse -97% among them). Work it under
skills/optimize: reproduce locally against the 2026-08-23 release
binary per the compare loop; suspects are whatever touched json
decode and base64 codec paths in the 8/23–8/25 window; a real
regression gets a fix or a revert, and only an environmental
explanation earns a perf_gate:false re-baseline dispatch. Blocked
today by 3ISWHWQT: the compare step cannot even run until the
version_info skew fix lands, so land that first.
