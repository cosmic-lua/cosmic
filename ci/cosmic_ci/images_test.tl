local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Images = require("cosmic_ci.images")
local Proc = require("cosmic.proc")

local function words(list: {string}): string
  return table.concat(list, " ")
end

local function test_name_is_lowercase()
  assert(Images.name("Cosmic-Lua/Cosmic", "Ubuntu") ==
    "ghcr.io/cosmic-lua/cosmic-ci-ubuntu")
end

local function build_env(publish: string): {string:string}
  return {
    GITHUB_REPOSITORY = "Owner/Repo", GITHUB_SERVER_URL = "https://github.com",
    GITHUB_SHA = "abc123", IMAGE = "ubuntu", ARCH = "arm64",
    UBUNTU_SNAPSHOT = "20260924T120000Z", PUBLISH = publish,
  }
end

local build_words <const> = "buildx build --platform linux/arm64 " ..
  "--provenance=false " ..
  "--label org.opencontainers.image.source=https://github.com/Owner/Repo " ..
  "--label org.opencontainers.image.revision=abc123 " ..
  "--build-arg UBUNTU_SNAPSHOT=20260924T120000Z " ..
  "--secret id=ca,src=/etc/ssl/certs/ca-certificates.crt " ..
  "--tag ghcr.io/owner/repo-ci-ubuntu:abc123-arm64"

local function test_build_argv_pushes_only_when_publishing()
  local built = Images.build_argv(build_env("false"))
  assert(words(built) == build_words .. " ci/images/ubuntu", words(built))
  local pushed = Images.build_argv(build_env("true"))
  assert(words(pushed) == build_words .. " --push ci/images/ubuntu", words(pushed))
  -- One word each, as the shell quoted them.
  assert(#pushed == 17 and pushed[7] ==
    "org.opencontainers.image.source=https://github.com/Owner/Repo")
end

local function test_build_argv_refuses_missing_context()
  local env = build_env("false")
  env.UBUNTU_SNAPSHOT = nil
  local ok, why = pcall(Images.build_argv, env)
  assert(not ok and tostring(why):find("UBUNTU_SNAPSHOT", 1, true))
end

local function test_publish_argvs_join_each_arch()
  local login, create, inspect = Images.publish_argvs("ghcr.io/o/r-ci-ubuntu",
    "actor", "abc", " amd64  arm64 ")
  assert(words(login) == "login ghcr.io -u actor --password-stdin")
  assert(words(create) == "buildx imagetools create --tag ghcr.io/o/r-ci-ubuntu:abc " ..
    "ghcr.io/o/r-ci-ubuntu:abc-amd64 ghcr.io/o/r-ci-ubuntu:abc-arm64", words(create))
  assert(words(inspect) == "buildx imagetools inspect ghcr.io/o/r-ci-ubuntu:abc")
end

local inspect_output <const> = [[
Name:      ghcr.io/o/r-ci-ubuntu:abc
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:0123abcd

Manifests:
  Name:      ghcr.io/o/r-ci-ubuntu:abc@sha256:feed
  Digest:    sha256:ignored
]]

local function test_digest_is_the_first_digest_line()
  assert(Images.digest(inspect_output) == "sha256:0123abcd")
  assert(Images.digest("  Digest: sha256:indented extra\n") == "sha256:indented")
  assert(Images.digest("Digest: md5:nope\nDigest: sha256:late\n") == nil)
  assert(Images.digest("Digest:\n") == nil)
  assert(Images.digest("XDigest: sha256:x\n") == nil)
  assert(Images.digest("") == nil)
end

--- A `docker` that records each call's cwd, argv (one bracketed word
--- each) and, for a login, stdin, answers inspect with FAKE_INSPECT, and
--- exits FAKE_STATUS from the subcommand named FAKE_FAIL.
local fake_docker <const> = [[#!/bin/sh
{
  printf 'cwd %s\n' "$(pwd)"
  printf 'argv'
  for word in "$@"; do printf ' [%s]' "$word"; done
  printf '\n'
  printf 'token %s\n' "${TOKEN-unset}"
} >> "$FAKE_LOG"
case "$1" in login) printf 'stdin %s\n' "$(cat)" >> "$FAKE_LOG" ;; esac
case "$1 $2 $3" in "$FAKE_FAIL"*) exit "$FAKE_STATUS" ;; esac
case "$2 $3" in "imagetools inspect") printf '%s' "$FAKE_INSPECT" ;; esac
exit 0
]]

local function fake(tmp: string): {string:string}
  local bin, workspace = tmp .. "/bin", tmp .. "/workspace"
  assert(Fs.mkdirs(bin) and Fs.mkdirs(workspace))
  assert(Fs.write(bin .. "/docker", fake_docker, 0x1ed))
  return {
    PATH = bin .. ":/usr/bin:/bin", FAKE_LOG = tmp .. "/log",
    FAKE_INSPECT = inspect_output, FAKE_FAIL = "none", FAKE_STATUS = "0",
    GITHUB_WORKSPACE = workspace, GITHUB_REPOSITORY = "Owner/Repo",
    GITHUB_SERVER_URL = "https://github.com", GITHUB_SHA = "abc123",
    GITHUB_ACTOR = "actor", GITHUB_STEP_SUMMARY = tmp .. "/summary",
  }
end

local function read(path: string): string
  return (assert(Fs.read(path)))
end

local function test_build_runs_docker_from_the_checkout(tmp: string)
  local env = fake(tmp)
  for name, value in pairs(build_env("true")) do env[name] = value end
  local code, trouble = Images.build(env)
  assert(code == 0, trouble)
  local bracketed = build_words:gsub("[^ ]+", "[%0]")
  local cwd = "cwd " .. assert(Fs.absolute(env.GITHUB_WORKSPACE)) .. "\n"
  assert(read(env.FAKE_LOG) == cwd ..
    "argv " .. bracketed .. " [--push] [ci/images/ubuntu]\ntoken unset\n",
    read(env.FAKE_LOG))
end

local function test_build_fails_with_docker(tmp: string)
  local env = fake(tmp)
  for name, value in pairs(build_env("false")) do env[name] = value end
  env.FAKE_FAIL, env.FAKE_STATUS = "buildx build", "3"
  local code, trouble = Images.build(env)
  assert(code == 3 and trouble == "docker buildx build: exit 3", trouble)
end

local function publish_env(tmp: string): {string:string}
  local env = fake(tmp)
  env.IMAGE, env.ARCHES, env.TOKEN = "Ubuntu", "amd64 arm64", "s3cret-token"
  return env
end

local function test_publish_joins_and_reports_the_digest(tmp: string)
  local env = publish_env(tmp)
  assert(Fs.write(env.GITHUB_STEP_SUMMARY, "earlier\n"))
  local out = assert(Fs.open_write(tmp .. "/out"))
  local code, trouble = Images.publish(env, out)
  assert(Fs.close(out))
  assert(code == 0, trouble)
  local name = "ghcr.io/owner/repo-ci-ubuntu"
  local cwd = "cwd " .. assert(Fs.absolute(env.GITHUB_WORKSPACE)) .. "\n"
  assert(read(env.FAKE_LOG) ==
    cwd .. "argv [login] [ghcr.io] [-u] [actor] [--password-stdin]\n" ..
    "token unset\nstdin s3cret-token\n" ..
    cwd .. "argv [buildx] [imagetools] [create] [--tag] [" .. name .. ":abc123] [" ..
      name .. ":abc123-amd64] [" .. name .. ":abc123-arm64]\ntoken unset\n" ..
    cwd .. "argv [buildx] [imagetools] [inspect] [" .. name .. ":abc123]\n" ..
    "token unset\n", read(env.FAKE_LOG))
  assert(read(tmp .. "/out") == name .. "@sha256:0123abcd\n")
  assert(read(env.GITHUB_STEP_SUMMARY) ==
    "earlier\nUbuntu: `" .. name .. "@sha256:0123abcd`\n")
end

local function test_publish_refuses_an_index_without_a_digest(tmp: string)
  local env = publish_env(tmp)
  env.FAKE_INSPECT = "Name: x\nDigest: md5:0\n"
  local out = assert(Fs.open_write(tmp .. "/out"))
  local code, trouble = Images.publish(env, out)
  assert(Fs.close(out))
  assert(code == 1 and trouble == "no digest for ghcr.io/owner/repo-ci-ubuntu:abc123",
    trouble)
  assert(read(tmp .. "/out") == "")
  assert(Fs.exists(env.GITHUB_STEP_SUMMARY) == false)
end

local function test_publish_stops_at_a_docker_failure(tmp: string)
  local commands <const> = { "login", "buildx imagetools create",
    "buildx imagetools inspect" }
  for calls, command in ipairs(commands) do
    local dir = tmp .. "/" .. tostring(calls)
    local env = publish_env(dir)
    env.FAKE_FAIL, env.FAKE_STATUS = command, "5"
    local out = assert(Fs.open_write(dir .. "/out"))
    local code, trouble = Images.publish(env, out)
    assert(Fs.close(out))
    local label = command == "login" and "login ghcr.io" or command
    assert(code == 5 and trouble == "docker " .. label .. ": exit 5", trouble)
    local _, ran = read(env.FAKE_LOG):gsub("argv ", "")
    assert(ran == calls, "ran on past the failure")
    assert(not trouble:find("s3cret", 1, true))
    assert(read(dir .. "/out") == "")
  end
end

local function test_missing_docker_fails(tmp: string)
  local env = fake(tmp)
  for name, value in pairs(build_env("false")) do env[name] = value end
  env.PATH = tmp .. "/nowhere"
  local code, trouble = Images.build(env)
  assert(code == 127 and trouble:find("^docker: "), trouble)
end

--- driver.tl as a workflow step runs it, from a copy of this project:
--- the self-check holds `ci/o/build.db` while tests run (see
--- orchestration_test.tl), so the driver never runs with `ci/` as root.
local function driver(tmp: string, command: string,
    env: {string:string}): Child.Result
  local project = tmp .. "/driver-project"
  assert(Fs.mkdirs(project))
  assert(assert(Child.run({ "/bin/cp", "-R", assert(Fs.absolute("cosmic_ci")),
    project })).ok)
  return (assert(Child.run({ assert(Proc.executable()),
    project .. "/cosmic_ci/driver.tl", command }, { cwd = project, env = env,
    stdout = "capture", stderr = "capture", timeout_ms = 60000 })))
end

local function test_driver_runs_both_commands(tmp: string)
  local env = publish_env(tmp)
  for name, value in pairs(build_env("false")) do
    if name ~= "IMAGE" then env[name] = value end
  end
  env.HOME = tmp
  local built = driver(tmp .. "/build", "image-build", env)
  assert(built.ok, built.stderr)
  local published = driver(tmp .. "/publish", "image-publish", env)
  assert(published.ok, published.stderr)
  assert(published.stdout == "ghcr.io/owner/repo-ci-ubuntu@sha256:0123abcd\n",
    published.stdout)
  local _, calls = read(env.FAKE_LOG):gsub("argv ", "")
  assert(calls == 4)
  env.FAKE_FAIL, env.FAKE_STATUS = "login", "4"
  local refused = driver(tmp .. "/refused", "image-publish", env)
  assert(refused.code == 4 and refused.stderr ==
    "image-publish: docker login ghcr.io: exit 4\n", refused.stderr)
  assert(not (refused.stdout .. refused.stderr):find("s3cret", 1, true))
end
