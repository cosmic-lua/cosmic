return {
  ["block_reason"] = {
    ["3ISWHWQTq31NBoVzqQ3tH8G6aqQ"] = "the compare step dies on the type skew before measuring, so the regression cannot even be re-measured in the lane until the skew fix lands",
    ["3ISltQMhob9AijyuE6tg70vN1k7"] = "the A/B is run and recorded, but the handover is refused: 'move 3ISWHyP7 check' demands --pr and this slice deliberately has no diff. Until 3ISltQMh settles what PR an evidence-only slice carries, this item cannot reach a reviewer, and re-running the measurement would only reproduce numbers already in its Result.",
    ["3IStqRsfgfFXaOyon5A0Of6xIFI"] = "the evidence handover this slice's Change step 4 performs is refused by the unconditional handover_refusal PR read; nothing else remains",
  },
  ["blocked_by"] = "3ISWHWQTq31NBoVzqQ3tH8G6aqQ 3ISltQMhob9AijyuE6tg70vN1k7 3IStqRsfgfFXaOyon5A0Of6xIFI",
  ["builders"] = "2193cf4f-c63b-584f-80fe-7f97567843c5 77b4f3ab-41c0-54aa-8f07-edca34169b73",
  ["claim"] = "77b4f3ab-41c0-54aa-8f07-edca34169b73",
  ["id"] = "3ISWHyP7awA0sy9WbVOyu0R5Qbq",
  ["parent"] = "3HyRcW05wBip6Wqcz145bUQBTyj",
  ["phase"] = "do",
  ["title"] = "release gate red: json_decode_large +12% and codec_base64_roundtrip_64k +21% vs 2026-08-23-d71d7f1 — root-cause or re-baseline",
}
