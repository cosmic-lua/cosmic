return {
  ["block_reason"] = {["3If5rr2G9zZurErMCTTJzdqxLdM"] = "determinism is not expressible in the binding today, so the wrapper would ship an API that must break to gain it", ["3If5s4hNeSCYCYLbOoyuYH1dq7T"] = "the blob representation decides what a UDF argument's Teal type is, so the wrapper cannot be typed until it lands", ["3Int8VXj9GcPOKsNsQtTiP5t8cl"] = "spec's UDF value-type section (number | string | nil) predates the BLOB/TEXT decision on 3IlL8oOG; TiP5_t8cl wraps UDF arguments in Blob via value_type(n) in cosmic/sqlite/bind.tl, and Es2a_EOny's own Files section touches cosmic/sqlite/types.tl — landing both in parallel risks a stale UDF value type and a types.tl merge collision. Refine after TiP5_t8cl merges to reference the Blob wrapper."},
  ["blocked_by"] = "3If5rr2G9zZurErMCTTJzdqxLdM 3If5s4hNeSCYCYLbOoyuYH1dq7T 3Int8VXj9GcPOKsNsQtTiP5t8cl",
  ["id"] = "3If5tfhKFddBtGv2wqkEs2aEOny",
  ["parent"] = "3HyRdY4sPAYZ6xkwrXCh5BnsH7B",
  ["title"] = "cosmic.sqlite: expose create_function, create_aggregate and create_collation",
}
