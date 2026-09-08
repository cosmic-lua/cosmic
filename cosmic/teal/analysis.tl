--- Optional Teal semantic analysis over immutable source snapshots.
---
--- This additive facade is the canonical typed API for rule authors. The
--- `cosmic.teal.session` convenience stays lazy for bootstrap compatibility;
--- this module exposes the exact Snapshot-bearing records.

local implementation = require("cosmic._teal_analysis")

local type AnalysisOptions = implementation.AnalysisOptions
local type Analysis = implementation.Analysis
local type Session = implementation.Session

local function session(opts?: AnalysisOptions): Session
  return implementation.session(opts)
end

local record AnalysisModule
  type AnalysisOptions = AnalysisOptions
  type Analysis = Analysis
  type Session = Session
  session: function(opts?: AnalysisOptions): Session
end

local M: AnalysisModule = {session = session}
return M
