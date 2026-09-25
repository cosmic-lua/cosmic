-- The images ci/images/ holds, built and published for ci-images.yml:
-- `image-build` builds one image for one architecture and pushes it when
-- PUBLISH is true, and `image-publish` joins one image's architectures
-- under one tag and reports the index's digest on the run's summary.
-- Each reads its context from the environment the job sets, and runs
-- `docker`, found on PATH, from the checkout's root (GITHUB_WORKSPACE).
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

local record Images
end

local function required(env: {string:string}, name: string): string
  local value = env[name]
  assert(value and value ~= "", "missing required environment variable: " .. name)
  return value
end

--- The image's name on GHCR: `ghcr.io/<repository>-ci-<image>`, lowercase,
--- since GHCR's names are and the repository's may not be.
function Images.name(repository: string, image: string): string
  return (("ghcr.io/" .. repository .. "-ci-" .. image):lower())
end

--- The words after `docker` that build `image` for `arch`, from the
--- checkout's root. --provenance=false keeps it a plain image, so the
--- index publish joins holds the platforms and nothing else.
function Images.build_argv(env: {string:string}): {string}
  local repository = required(env, "GITHUB_REPOSITORY")
  local image = required(env, "IMAGE")
  local arch = required(env, "ARCH")
  local sha = required(env, "GITHUB_SHA")
  local argv: {string} = {
    "buildx", "build",
    "--platform", "linux/" .. arch, "--provenance=false",
    "--label", "org.opencontainers.image.source=" ..
      required(env, "GITHUB_SERVER_URL") .. "/" .. repository,
    "--label", "org.opencontainers.image.revision=" .. sha,
    "--build-arg", "UBUNTU_SNAPSHOT=" .. required(env, "UBUNTU_SNAPSHOT"),
    "--secret", "id=ca,src=/etc/ssl/certs/ca-certificates.crt",
    "--tag", Images.name(repository, image) .. ":" .. sha .. "-" .. arch,
  }
  if required(env, "PUBLISH") == "true" then argv[#argv + 1] = "--push" end
  argv[#argv + 1] = "ci/images/" .. image
  return argv
end

--- The words after `docker` for each of publish's three commands: the
--- login (the token goes on its stdin, never here), the join of each
--- architecture in the blank-separated `arches` under `name:sha`, and
--- the inspection of the index that join made.
function Images.publish_argvs(name: string, actor: string, sha: string,
    arches: string): {string}, {string}, {string}
  local login: {string} = { "login", "ghcr.io", "-u", actor, "--password-stdin" }
  local create: {string} = { "buildx", "imagetools", "create", "--tag",
    name .. ":" .. sha }
  for arch in arches:gmatch("[^ \t\n]+") do
    create[#create + 1] = name .. ":" .. sha .. "-" .. arch
  end
  local inspect: {string} = { "buildx", "imagetools", "inspect", name .. ":" .. sha }
  return login, create, inspect
end

--- The digest `imagetools inspect` reports: the second field of the first
--- line whose first is `Digest:`, as `awk '$1 == "Digest:"'` reads it,
--- and nil unless it is a sha256 one.
function Images.digest(output: string): string | nil
  for line in output:gmatch("[^\n]*") do
    local first, second = line:match("^[ \t]*([^ \t]+)[ \t]*([^ \t]*)")
    if first == "Digest:" then
      if second:sub(1, 7) == "sha256:" then return second end
      return nil
    end
  end
  return nil
end

--- The environment docker runs in: the job's, less the token, which only
--- the login's stdin carries.
local function docker_environment(env: {string:string}): {string:string}
  local out: {string:string} = {}
  for name, value in pairs(env) do
    if name ~= "TOKEN" then out[name] = value end
  end
  return out
end

--- Runs `docker words...` from the checkout's root, and answers 0, or a
--- failing status and why; `input` goes to its stdin, and `capture`
--- answers its stdout as well.
local function docker(env: {string:string}, words: {string},
    input?: string, capture?: boolean): integer, string, string
  local found, missing = Proc.find("docker", env.PATH)
  if found == nil then return 127, "docker: " .. missing, "" end
  local argv: {string} = { found }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local options: Child.Options = { cwd = required(env, "GITHUB_WORKSPACE"),
    env = docker_environment(env) }
  if input then options.input = input end
  if capture then options.stdout = "capture" end
  -- Named by the words before its first option, which hold no secret.
  local label = "docker"
  for i = 1, 3 do
    local word = words[i]
    if word == nil or word:sub(1, 1) == "-" then break end
    label = label .. " " .. word
  end
  local result, trouble = Child.run(argv, options)
  if result == nil then return 1, label .. ": " .. trouble, "" end
  if result.ok then return 0, "", result.stdout or "" end
  if result.signal then
    return 128 + result.signal, label .. ": signal " .. tostring(result.signal), ""
  end
  local code = result.code or 1
  return code, label .. ": exit " .. tostring(code), ""
end

--- Builds one image for one architecture, pushing it when PUBLISH is
--- true: 0, or docker's failing status and why.
function Images.build(env: {string:string}): integer, string
  local code, trouble = docker(env, Images.build_argv(env))
  return code, trouble
end

local function append(path: string, text: string): boolean, string
  local fd, trouble = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND,
    0x1a4)
  if fd == nil then return false, path .. ": " .. trouble end
  local put, put_trouble = Fs.put(fd, text)
  local closed, close_trouble = Fs.close(fd)
  if not put then return false, path .. ": " .. put_trouble end
  if not closed then return false, path .. ": " .. close_trouble end
  return true, ""
end

--- Joins one image's architectures under `name:GITHUB_SHA`, writes its
--- `name@digest` to `out`, and appends it to the step summary: 0, or a
--- failing status and why.
function Images.publish(env: {string:string}, out: integer): integer, string
  local image = required(env, "IMAGE")
  local name = Images.name(required(env, "GITHUB_REPOSITORY"), image)
  local sha = required(env, "GITHUB_SHA")
  local summary = required(env, "GITHUB_STEP_SUMMARY")
  local token = required(env, "TOKEN")
  local login, create, inspect = Images.publish_argvs(name,
    required(env, "GITHUB_ACTOR"), sha, required(env, "ARCHES"))
  local code, trouble = docker(env, login, token .. "\n")
  if code ~= 0 then return code, trouble end
  code, trouble = docker(env, create)
  if code ~= 0 then return code, trouble end
  local report: string
  code, trouble, report = docker(env, inspect, nil, true)
  if code ~= 0 then return code, trouble end
  local digest = Images.digest(report)
  if digest == nil then return 1, "no digest for " .. name .. ":" .. sha end
  local reference = name .. "@" .. digest
  local put, put_trouble = Fs.put(out, reference .. "\n")
  if not put then return 1, put_trouble end
  local appended, append_trouble = append(summary,
    image .. ": `" .. reference .. "`\n")
  if not appended then return 1, append_trouble end
  return 0, ""
end

local function command(name: string, argv: {string},
    run: function({string:string}): integer, string): integer
  if #argv > 0 then
    local _, _ = Fs.put(Fs.stderr, "driver.tl " .. name .. ": takes no arguments\n")
    return 2
  end
  local code, trouble = run(Env.all())
  if code ~= 0 then
    local _, _ = Fs.put(Fs.stderr, name .. ": " .. trouble .. "\n")
  end
  return code
end

function Images.build_command(argv: {string}): integer
  return command("image-build", argv, Images.build)
end

function Images.publish_command(argv: {string}): integer
  return command("image-publish", argv, function(env: {string:string}): integer, string
    return Images.publish(env, Fs.stdout)
  end)
end

return Images
