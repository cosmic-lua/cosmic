#!/usr/bin/env cosmic
--- reads: .github/workflows/release.yml
-- The release verifier is deliberately structural: dispatching a release
-- would publish an asset, while these checks make its required evidence
-- and failure paths reviewable before that irreversible boundary.
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local PATH < const > = ".github/workflows/release.yml"
--- Drop YAML and shell comments before looking for active configuration or commands.
local function active_lines(text: string): string
  local lines: {string} = {}
  for raw in text:gmatch("([^\n]*)\n?") do
    local line = raw
    if line:match("^%s*#") then
      line = ""
    else
      line = line:gsub("%s+#.*$", "")
    end
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end
local function line_at(text: string, needle: string, after: integer): integer | nil
  local number = 0
  for line in text:gmatch("([^\n]*)\n?") do
    number = number + 1
    if number > after and line == needle then
      return number
    end
  end
  return nil
end

local function has_line(text: string, needle: string): boolean
  return line_at(text, needle, 0) ~= nil
end

local function count_line(text: string, needle: string): integer
  local found = 0
  for line in text:gmatch("([^\n]*)\n?") do
    if line == needle then
      found = found + 1
    end
  end
  return found
end

local function has_mapping_key(text: string, key: string): boolean
  for line in text:gmatch("([^\n]*)\n?") do
    local trimmed = line:gsub("^%s*", "")
    if trimmed:sub(1, #key + 1) == key .. ":" then
      return true
    end
  end
  return false
end

local function precedes_both(position: integer | nil, log: integer | nil,
    summary: integer | nil): boolean
  return position ~= nil and log ~= nil and summary ~= nil and
  position < log and position < summary
end

--- Extract an active job by its YAML key, not a similarly named comment.
local function job_body(source: string, name: string): string
  local body: {string} = {}
  local in_jobs = false
  local found = false
  for line in source:gmatch("([^\n]*)\n?") do
    if found then
      if line:match("^%S") or line:match("^  %S") then
        break
      end
      body[#body + 1] = line
    elseif line:match("^jobs:%s*$") then
      in_jobs = true
    elseif in_jobs and line:match("^  ([%w_%-]+):%s*$") == name then
      found = true
      body[#body + 1] = line
    end
  end
  return table.concat(body, "\n")
end

--- Keep job-level mappings out of step bodies and their shell scripts.
local function job_config(job: string): string
  local body: {string} = {}
  for line in job:gmatch("([^\n]*)\n?") do
    if line == "    steps:" then
      break
    end
    body[#body + 1] = line
  end
  return table.concat(body, "\n")
end

--- Extract an active job-level mapping, stopping at its next peer mapping.
local function mapping_body(config: string, name: string): string
  local body: {string} = {}
  local found = false
  for line in config:gmatch("([^\n]*)\n?") do
    if found then
      if line:match("^    %S") then
        break
      end
      body[#body + 1] = line
    elseif line == "    " .. name .. ":" then
      found = true
      body[#body + 1] = line
    end
  end
  return table.concat(body, "\n")
end

--- Extract one active named step, stopping at the next peer step.
local function step_body(job: string, name: string): string
  local target = "- name: " .. name
  local indent = ""
  local body: {string} = {}
  for line in job:gmatch("([^\n]*)\n?") do
    local lead = line:match("^(%s*)%- ")
    if indent ~= "" then
      if lead == indent then
        break
      end
      body[#body + 1] = line
    elseif line:match("^%s*(.-)%s*$") == target then
      indent = lead or ""
      body[#body + 1] = line
    end
  end
  return table.concat(body, "\n")
end

--- Keep active step metadata separate from the block scalar that is the shell program.
local function step_config(step: string): string
  local body: {string} = {}
  for line in step:gmatch("([^\n]*)\n?") do
    if line == "        run: |" then
      break
    end
    body[#body + 1] = line
  end
  return table.concat(body, "\n")
end

local function run_body(step: string): string
  local body: {string} = {}
  local found = false
  for line in step:gmatch("([^\n]*)\n?") do
    if found then
      body[#body + 1] = line
    elseif line == "        run: |" then
      found = true
    end
  end
  return table.concat(body, "\n")
end

local function need_line(text: string, needle: string, label: string): boolean, string
  if has_line(text, needle) then
    return true, ""
  end
  return false, label .. " missing `" .. needle .. "`"
end

local function need_lines(text: string, needles: {string}, label: string): boolean, string
  for _, needle in ipairs(needles) do
    local ok, err = need_line(text, needle, label)
    if not ok then
      return false, err
    end
  end
  return true, ""
end

local function validate(source: string): boolean, string
  local active = active_lines(source)
  local build = job_body(active, "build")
  local release = job_body(active, "release")
  local verify = job_body(active, "verify")
  if build == "" or release == "" or verify == "" then
    return false, "release jobs missing"
  end

  local build_config = job_config(build)
  local tag = step_body(build, "name the release")
  local tag_config = step_config(tag)
  local tag_run = run_body(tag)
  local build_outputs = mapping_body(build_config, "outputs")
  local ok, err = need_lines(build_outputs, {
      "      commit: ${{ steps.tag.outputs.commit }}",
      "      tag: ${{ steps.tag.outputs.tag }}",
    }, "build output")
  if not ok then return false, err end
  ok, err = need_lines(tag_config, {
      "        id: tag",
      "        shell: bash",
    }, "release naming configuration")
  if not ok then return false, err end
  ok, err = need_lines(tag_run, {
      "          commit=\"$(git rev-parse HEAD)\"",
      "          test \"$commit\" = \"$GITHUB_SHA\"",
      "          echo \"commit=$commit\" >> \"$GITHUB_OUTPUT\"",
      "          echo \"COSMIC_VERSION=$tag\" >> \"$GITHUB_ENV\"",
    }, "release naming")
  if not ok then return false, err end

  local release_config = job_config(release)
  local publish = step_body(release, "create release")
  local publish_config = step_config(publish)
  local publish_run = run_body(publish)
  local release_outputs = mapping_body(release_config, "outputs")
  local release_env = mapping_body(release_config, "env")
  ok, err = need_lines(release_outputs, {
      "      digest: ${{ steps.publish.outputs.digest }}",
    }, "publisher output")
  if not ok then return false, err end
  ok, err = need_lines(release_env, {
      "      BUILD_COMMIT: ${{ needs.build.outputs.commit }}",
    }, "publisher wiring")
  if not ok then return false, err end
  ok, err = need_lines(publish_config, {
      "        id: publish",
      "        shell: bash",
    }, "publisher")
  if not ok then return false, err end
  ok, err = need_lines(publish_run, {
      "          set -euo pipefail",
      "          remote_tag=\"$(git ls-remote --refs origin \"refs/tags/$TAG\")\"",
      "          if [ -n \"$remote_tag\" ]; then",
      "            git fetch --depth=1 origin \"refs/tags/$TAG:refs/tags/$TAG\"",
      "            tag_commit=\"$(git rev-parse --verify \"refs/tags/$TAG^{commit}\")\"",
      "            if [ \"$tag_commit\" != \"$BUILD_COMMIT\" ]; then",
      "              exit 1",
      "          digest=\"$(sha256sum release/cosmic-lua | awk '{print $1}')\"",
      "          echo \"digest=$digest\" >> \"$GITHUB_OUTPUT\"",
      "            --target \"$BUILD_COMMIT\" \\",
      "          gh release create \"$tag\" \\",
    }, "publisher run")
  if not ok then return false, err end
  local tag_query = line_at(publish_run,
    "          remote_tag=\"$(git ls-remote --refs origin \"refs/tags/$TAG\")\"", 0)
  local existing_tag = line_at(publish_run, "          if [ -n \"$remote_tag\" ]; then", 0)
  local dereference = line_at(publish_run,
    "            tag_commit=\"$(git rev-parse --verify \"refs/tags/$TAG^{commit}\")\"", 0)
  local tag_check = line_at(publish_run,
    "            if [ \"$tag_commit\" != \"$BUILD_COMMIT\" ]; then", 0)
  local mismatch_exit = line_at(publish_run, "              exit 1", tag_check or 0)
  local create = line_at(publish_run, "          gh release create \"$tag\" \\", 0)
  if not (tag_query and existing_tag and dereference and tag_check and mismatch_exit and create and
    tag_query < existing_tag and existing_tag < dereference and dereference < tag_check and
    tag_check < mismatch_exit and mismatch_exit < create) then
    return false, "publisher tag equality must precede publication"
  end

  local verify_config = job_config(verify)
  local verify_permissions = mapping_body(verify_config, "permissions")
  local verify_env = mapping_body(verify_config, "env")
  local verifier = step_body(verify, "verify the published release")
  local verifier_config = step_config(verifier)
  local run = run_body(verifier)
  ok, err = need_lines(verify_config, {
      "    needs: [build, release]",
      "    runs-on: ubuntu-latest",
      "    timeout-minutes: 10",
    }, "verifier configuration")
  if not ok then return false, err end
  ok, err = need_lines(verify_permissions, {
      "      contents: read",
    }, "verifier permissions")
  if not ok then return false, err end
  ok, err = need_lines(verify_env, {
      "      TAG: ${{ needs.build.outputs.tag }}",
      "      BUILD_COMMIT: ${{ needs.build.outputs.commit }}",
      "      EXPECTED_DIGEST: ${{ needs.release.outputs.digest }}",
    }, "verifier configuration")
  if not ok then return false, err end
  if has_line(verify_permissions, "      contents: write") then
    return false, "verifier permissions are not read-only"
  end
  if has_mapping_key(verify_config, "continue-on-error") or
  has_mapping_key(verifier_config, "continue-on-error") or
  has_mapping_key(verify_config, "if") or has_mapping_key(verifier_config, "if") then
    return false, "verifier failure semantics are optional"
  end
  ok, err = need_lines(verifier_config, {
      "        shell: bash",
    }, "verifier step configuration")
  if not ok then return false, err end
  ok, err = need_lines(run, {
      "          set -euo pipefail",
      "          git init -q tag",
      "          git -C tag fetch --depth=1 origin \"refs/tags/$TAG\"",
      "          tag_commit=\"$(git -C tag rev-parse --verify \"FETCH_HEAD^{commit}\")\"",
      "          test \"$tag_commit\" = \"$BUILD_COMMIT\"",
      "            --output cosmic-lua \\",
      "            --output SHA256SUMS \\",
      "            \"$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/releases/download/$TAG/cosmic-lua\"",
      "            \"$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/releases/download/$TAG/SHA256SUMS\"",
      "          primary_rows=\"$(awk 'NF == 2 && $2 == \"cosmic-lua\" { print $1 \"  \" $2 }' SHA256SUMS)\"",
      "          primary_count=\"$(printf '%s\\n' \"$primary_rows\" | awk 'NF { count = count + 1 } END { print count + 0 }')\"",
      "          test \"$primary_count\" = 1",
      "          manifest_digest=\"$(printf '%s\\n' \"$primary_rows\" | awk '{ print $1 }')\"",
      "          [[ \"$manifest_digest\" =~ ^[0-9a-f]{64}$ ]]",
      "          test \"$manifest_digest\" = \"$EXPECTED_DIGEST\"",
      "          version=\"$(sh ./cosmic-lua --version)\"",
      "          test -n \"$version\"",
      "          version_lines=\"$(printf '%s\\n' \"$version\" | awk 'END { print NR }')\"",
      "          test \"$version_lines\" = 1",
      "          read -r program reported_tag _ <<< \"$version\"",
      "          test \"$program\" = cosmic-lua",
      "          test \"$reported_tag\" = \"$TAG\"",
      "          evidence=\"release-verify: PASS tag=$TAG commit=$BUILD_COMMIT sha256=$manifest_digest\"",
      "          echo \"$evidence\"",
      "          echo \"$evidence\" >> \"$GITHUB_STEP_SUMMARY\"",
    }, "verifier")
  if not ok then return false, err end
  local curl = "          curl --fail --location --retry 5 --retry-delay 2 --retry-max-time 180 --max-time 60 \\"
  if count_line(run, curl) ~= 2 then
    return false, "verifier curl retries are incomplete"
  end
  local checksum = "          printf '%s  cosmic-lua\\n' \"$manifest_digest\" | sha256sum --check --status -"
  if count_line(run, checksum) ~= 2 then
    return false, "verifier must checksum before and after execution"
  end
  if has_line(run, "          cat SHA256SUMS | sha256sum --check --status -") then
    return false, "verifier checks an unfiltered manifest"
  end
  local commit_check = line_at(run, "          test \"$tag_commit\" = \"$BUILD_COMMIT\"", 0)
  local primary_rows = line_at(run,
    "          primary_rows=\"$(awk 'NF == 2 && $2 == \"cosmic-lua\" { print $1 \"  \" $2 }' SHA256SUMS)\"", 0)
  local primary_count = line_at(run,
    "          primary_count=\"$(printf '%s\\n' \"$primary_rows\" | awk 'NF { count = count + 1 } END { print count + 0 }')\"", 0)
  local primary_guard = line_at(run, "          test \"$primary_count\" = 1", 0)
  local manifest_digest = line_at(run,
    "          manifest_digest=\"$(printf '%s\\n' \"$primary_rows\" | awk '{ print $1 }')\"", 0)
  local digest_format = line_at(run,
    "          [[ \"$manifest_digest\" =~ ^[0-9a-f]{64}$ ]]", 0)
  local digest_check = line_at(run,
    "          test \"$manifest_digest\" = \"$EXPECTED_DIGEST\"", 0)
  local first_check = line_at(run, checksum, 0)
  local execute = line_at(run, "          version=\"$(sh ./cosmic-lua --version)\"", 0)
  local nonempty_version = line_at(run, "          test -n \"$version\"", execute or 0)
  local version_count = line_at(run,
    "          version_lines=\"$(printf '%s\\n' \"$version\" | awk 'END { print NR }')\"", execute or 0)
  local line_guard = line_at(run, "          test \"$version_lines\" = 1", execute or 0)
  local version_fields = line_at(run, "          read -r program reported_tag _ <<< \"$version\"",
    line_guard or 0)
  local program_guard = line_at(run, "          test \"$program\" = cosmic-lua", version_fields or 0)
  local reported_tag_check = line_at(run, "          test \"$reported_tag\" = \"$TAG\"",
    program_guard or 0)
  local second_check = line_at(run, checksum, (first_check or 0) + 1)
  local evidence = line_at(run,
    "          evidence=\"release-verify: PASS tag=$TAG commit=$BUILD_COMMIT sha256=$manifest_digest\"", 0)
  local log_evidence = line_at(run, "          echo \"$evidence\"", 0)
  local summary_evidence = line_at(run, "          echo \"$evidence\" >> \"$GITHUB_STEP_SUMMARY\"", 0)
  if not (precedes_both(commit_check, log_evidence, summary_evidence) and
    precedes_both(primary_rows, log_evidence, summary_evidence) and
    precedes_both(primary_count, log_evidence, summary_evidence) and
    precedes_both(primary_guard, log_evidence, summary_evidence) and
    precedes_both(manifest_digest, log_evidence, summary_evidence) and
    precedes_both(digest_format, log_evidence, summary_evidence) and
    precedes_both(digest_check, log_evidence, summary_evidence) and
    precedes_both(first_check, log_evidence, summary_evidence) and
    precedes_both(execute, log_evidence, summary_evidence) and
    precedes_both(nonempty_version, log_evidence, summary_evidence) and
    precedes_both(version_count, log_evidence, summary_evidence) and
    precedes_both(line_guard, log_evidence, summary_evidence) and
    precedes_both(version_fields, log_evidence, summary_evidence) and
    precedes_both(program_guard, log_evidence, summary_evidence) and
    precedes_both(reported_tag_check, log_evidence, summary_evidence) and
    precedes_both(second_check, log_evidence, summary_evidence) and
    manifest_digest and digest_format and digest_check and manifest_digest < digest_format and
    manifest_digest < digest_check and
    digest_check and first_check and execute and second_check and digest_check < first_check and
    first_check < execute and execute < second_check and
    precedes_both(evidence, log_evidence, summary_evidence)) then
    return false, "verifier evidence/checksum order is unsafe"
  end
  for _, forbidden in ipairs({"--assimilate", "/releases/latest/",
      "actions/checkout", "actions/download-artifact", "gh release download",
      "--make build", "o/bin/", "artifacts/"}) do
    if active:find(forbidden, 1, true) and verify:find(forbidden, 1, true) then
      return false, "verifier forbidden fallback `" .. forbidden .. "`"
    end
  end
  return true, ""
end

local function replace_after(source: string, marker: string, old: string, new: string): string
  local start = assert(source:find(marker, 1, true), "mutation marker missing: " .. marker)
  local head = source:sub(1, start + #marker - 1)
  local tail = source:sub(start + #marker)
  local at = assert(tail:find(old, 1, true), "mutation anchor missing: " .. old)
  return head .. tail:sub(1, at - 1) .. new .. tail:sub(at + #old)
end

local function move_after(source: string, line: string, marker: string): string
  local at = assert(source:find(line, 1, true), "move line missing: " .. line)
  local without = source:sub(1, at - 1) .. source:sub(at + #line)
  local marker_at = assert(without:find(marker, 1, true), "move marker missing: " .. marker)
  local after = marker_at + #marker
  return without:sub(1, after) .. "\n" .. line .. without:sub(after + 1)
end

local function reject(source: string, label: string)
  local ok, err = validate(source)
  assert(not ok, label .. " mutation unexpectedly passed")
  assert(#err > 0, label .. " mutation produced no failure")
end

local function test_release_workflow_proves_published_asset_provenance()
  local source = check.must(fs.read(PATH))
  local ok, err = validate(source)
  assert(ok, err)
end

local function test_release_workflow_validator_rejects_security_mutations()
  local source = check.must(fs.read(PATH))
  reject(replace_after(source, "  verify:\n", "needs: [build, release]", "needs: [build]"),
    "release dependency")
  reject(replace_after(source, "  verify:\n", "needs: [build, release]",
      "# needs: [build, release]"), "commented release dependency")
  reject(replace_after(source, "  verify:\n", "contents: read", "contents: write"),
    "read-only permission")
  reject(replace_after(source, "        id: publish\n", "--target \"$BUILD_COMMIT\"", "--branch \"$BUILD_COMMIT\""),
    "publication target")
  reject(replace_after(source, "        id: publish\n",
      "if [ \"$tag_commit\" != \"$BUILD_COMMIT\" ]; then", "if false; then"),
    "existing tag equality")
  reject(replace_after(source, "  verify:\n", "releases/download/$TAG/cosmic-lua",
      "releases/latest/download/cosmic-lua"), "browser tag")
  reject(replace_after(source, "  verify:\n", "sha256sum --check --status -", "true"),
    "first checksum")
  reject(move_after(source, "          printf '%s  cosmic-lua\\n' \"$manifest_digest\" | sha256sum --check --status -",
      "          version=\"$(sh ./cosmic-lua --version)\""), "first checksum after execution")
  reject(replace_after(
      replace_after(source, "version=\"$(sh ./cosmic-lua --version)\"",
        "sha256sum --check --status -", "true"),
      "  verify:\n", "sha256sum --check --status -",
      "sha256sum --check --status -\n          sha256sum --check --status -"),
    "second checksum before execution")
  reject(replace_after(source, "  verify:\n",
      "printf '%s  cosmic-lua\\n' \"$manifest_digest\" | sha256sum --check --status -",
      "# printf '%s  cosmic-lua\\n' \"$manifest_digest\" | sha256sum --check --status -"),
    "commented first checksum")
  reject(replace_after(source, "  verify:\n",
      "printf '%s  cosmic-lua\\n' \"$manifest_digest\" | sha256sum --check --status -",
      "cat SHA256SUMS | sha256sum --check --status -"), "unfiltered first checksum")
  reject(replace_after(source, "version=\"$(sh ./cosmic-lua --version)\"",
      "sha256sum --check --status -", "true"), "second checksum")
  reject(replace_after(source, "  verify:\n", "test \"$reported_tag\" = \"$TAG\"",
      "test \"$reported_tag\" != \"\""), "reported tag")
  reject(replace_after(source, "  verify:\n", "test \"$reported_tag\" = \"$TAG\"",
      "# test \"$reported_tag\" = \"$TAG\""), "commented reported tag")
  reject(replace_after(source, "  verify:\n",
      "test \"$manifest_digest\" = \"$EXPECTED_DIGEST\"",
      "# test \"$manifest_digest\" = \"$EXPECTED_DIGEST\""), "commented publisher digest")
  reject(move_after(source, "          test \"$manifest_digest\" = \"$EXPECTED_DIGEST\"",
      "          version=\"$(sh ./cosmic-lua --version)\""), "publisher digest after execution")
  reject(replace_after(source, "  verify:\n",
      "manifest_digest=\"$(printf '%s\\n' \"$primary_rows\" | awk '{ print $1 }')\"",
      "manifest_digest=\"$EXPECTED_DIGEST\""), "substituted manifest digest")
  reject(replace_after(source, "  verify:\n",
      "manifest_digest=\"$(printf '%s\\n' \"$primary_rows\" | awk '{ print $1 }')\"",
      "# manifest_digest=\"$(printf '%s\\n' \"$primary_rows\" | awk '{ print $1 }')\""),
    "commented manifest digest")
  reject(move_after(source,
      "          manifest_digest=\"$(printf '%s\\n' \"$primary_rows\" | awk '{ print $1 }')\"",
      "          echo \"$evidence\" >> \"$GITHUB_STEP_SUMMARY\""), "manifest digest after evidence")
  reject(move_after(source, "          test \"$reported_tag\" = \"$TAG\"",
      "          evidence=\"release-verify: PASS tag=$TAG commit=$BUILD_COMMIT sha256=$manifest_digest\""),
    "reported tag after evidence")
  reject(move_after(source, "          test \"$tag_commit\" = \"$BUILD_COMMIT\"",
      "          echo \"$evidence\" >> \"$GITHUB_STEP_SUMMARY\""), "commit equality after evidence")
  reject(move_after(source, "          [[ \"$manifest_digest\" =~ ^[0-9a-f]{64}$ ]]",
      "          echo \"$evidence\" >> \"$GITHUB_STEP_SUMMARY\""), "digest format after evidence")
  reject(move_after(source, "          test \"$program\" = cosmic-lua",
      "          echo \"$evidence\" >> \"$GITHUB_STEP_SUMMARY\""), "program name after evidence")
  reject(replace_after(source, "  verify:\n",
      "primary_count=\"$(printf '%s\\n' \"$primary_rows\" | awk 'NF { count = count + 1 } END { print count + 0 }')\"",
      "primary_count=1"), "forced primary count")
  reject(replace_after(source, "  verify:\n",
      "version_lines=\"$(printf '%s\\n' \"$version\" | awk 'END { print NR }')\"",
      "version_lines=1"), "forced version line count")
  reject(replace_after(source, "  verify:\n", "echo \"$evidence\" >> \"$GITHUB_STEP_SUMMARY\"", "true"),
    "missing evidence summary")
  reject(replace_after(source, "  verify:\n", "test \"$version_lines\" = 1", "true"),
    "single-line version guard")
  reject(replace_after(source, "if [ \"$tag_commit\" != \"$BUILD_COMMIT\" ]; then", "exit 1", "exit 0"),
    "existing tag mismatch success")
  reject(replace_after(source, "        id: publish\n", "if [ -n \"$remote_tag\" ]; then", "if false; then"),
    "existing tag branch")
  reject(replace_after(source, "  verify:\n", "runs-on: ubuntu-latest",
      "runs-on: ubuntu-latest\n    continue-on-error: true"), "failure semantics")
  reject(replace_after(source, "  verify:\n", "sh ./cosmic-lua --version",
      "sh ./cosmic-lua --assimilate --version"), "assimilation")
end
