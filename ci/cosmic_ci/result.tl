local record Result
  record Verdict
    ok: boolean
    detail: string
  end
end

function Result.fresh(output: string, ok: boolean, timed_out: boolean,
    signal: integer | nil, code: integer | nil): Result.Verdict
  if timed_out then return { ok = false, detail = "child timed out" } end
  if signal then
    return { ok = false, detail = "child stopped by signal " .. tostring(signal) }
  end
  if not ok then
    return { ok = false, detail = "child exited " .. tostring(code or 1) }
  end
  local ran, stood, suffix = output:match(
    "test: PASS %([^;]+; ([0-9]+) ran, ([0-9]+) stood([^\n]*)")
  if not ran or not stood then
    return { ok = false, detail = "test summary is missing or malformed" }
  end
  if suffix ~= ")" and not suffix:match("^, [0-9]+ ms%)$") then
    return { ok = false, detail = "test summary is missing or malformed" }
  end
  local ran_count = math.tointeger(assert(tonumber(ran)))
  local stood_count = math.tointeger(assert(tonumber(stood)))
  if ran_count == 0 then return { ok = false, detail = "no tests ran" } end
  if stood_count ~= 0 then
    return { ok = false, detail = tostring(stood_count) .. " tests stood" }
  end
  return { ok = true, detail = "" }
end

return Result
