#!/usr/bin/env bats
#
# Runs devbox-version-sync against small projects with fake devbox and docker
# commands (tests/fakes). Run with `bats tests`.

setup() {
  root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  PATH="$root/tests/fakes:$root/bin:$PATH"
  export FAKE_DEVBOX_VERSIONS=$BATS_TEST_TMPDIR/versions
  export FAKE_DEVBOX_LOG=$BATS_TEST_TMPDIR/devbox.log
  export FAKE_DOCKER_MISSING=$BATS_TEST_TMPDIR/missing-images
  export DEVBOX_VERSION_SYNC_SETUP_RUBY_URL=file://$BATS_TEST_TMPDIR/setup-ruby.json
  unset GITHUB_ACTIONS DEVBOX_VERSION_SYNC_CONFIG
  : >"$FAKE_DOCKER_MISSING"
  mkdir -p "$BATS_TEST_TMPDIR/project/.github"
  cd "$BATS_TEST_TMPDIR/project"
}

# available PACKAGE VERSION... : what the fake Devbox offers.
available() {
  local pkg=$1 version
  shift
  for version in "$@"; do echo "$pkg $version"; done >>"$FAKE_DEVBOX_VERSIONS"
}

# locked KEY=VERSION... : writes devbox.lock.
locked() {
  local entry json='{}'
  for entry in "$@"; do
    json=$(jq --arg k "${entry%%=*}" --arg v "${entry#*=}" '.[$k] = {version: $v}' <<<"$json")
  done
  jq --indent 2 '{lockfile_version: "1", packages: .}' <<<"$json" >devbox.lock
}

config() {
  cat >.github/devbox-version-sync.json
}

lock_keys() {
  jq -r '.packages | keys | join(" ")' devbox.lock
}

ruby_project() {
  cat >devbox.json <<'EOF'
{
  "packages": {
    "clang":  "latest",
    "ruby":   "4.0",
    "sqlite": "3"
  }
}
EOF
  locked clang@latest=21.1.8 ruby@4.0=4.0.2 sqlite@3=3.51.2
  echo "ruby-4.0.2" >.ruby-version
  printf 'ARG RUBY_VERSION=4.0.2\nFROM docker.io/library/ruby:$RUBY_VERSION-slim AS base\n' >Dockerfile
  config <<'EOF'
{
  "tools": [
    {
      "name": "Ruby",
      "package": "ruby",
      "auto": "patch",
      "checks": ["docker:docker.io/library/ruby:{version}-slim", "setup-ruby"],
      "after_update": "bundle install",
      "files": [
        { "path": ".ruby-version", "match": "^ruby-(\\S+)$", "replace": "ruby-{version}" },
        { "path": "Dockerfile", "match": "^ARG RUBY_VERSION=(\\S+)$", "replace": "ARG RUBY_VERSION={version}" }
      ]
    }
  ]
}
EOF
  available ruby 4.0.2 4.0.9 4.1.0
  echo '{"ruby": ["4.0.2", "4.0.9", "4.1.0"]}' >"$BATS_TEST_TMPDIR/setup-ruby.json"
}

go_project() {
  cat >devbox.json <<'EOF'
{
  "packages": {
    "go": "1.27.1",
    "postgresql": "18.6",
    "goose": "3.28.0",
    "sqlc": "1.31.1",
    "xcodegen": {
      "version": "2.44.1",
      "platforms": ["aarch64-darwin", "x86_64-darwin"]
    }
  }
}
EOF
  locked go@1.27.1=1.27.1 postgresql@18.6=18.6 goose@3.28.0=3.28.0 sqlc@1.31.1=1.31.1 xcodegen@2.44.1=2.44.1
  printf 'module example.com/app\n\ngo 1.27.1\n' >go.mod
  printf 'FROM golang:1.27.1-trixie AS build\n' >Dockerfile
  config <<'EOF'
{
  "tools": [
    {
      "name": "Go",
      "package": "go",
      "auto": "patch",
      "checks": ["docker:golang:{version}-trixie"],
      "files": [
        { "path": "go.mod", "match": "^go (\\S+)$", "replace": "go {version}" },
        { "path": "Dockerfile", "match": "^FROM golang:(\\S+?)-trixie", "replace": "FROM golang:{version}-trixie" }
      ]
    },
    { "name": "PostgreSQL", "package": "postgresql", "auto": "minor" },
    { "package": "goose", "auto": "minor", "group": "tools" },
    { "package": "sqlc", "auto": "minor", "group": "tools" },
    { "package": "xcodegen", "auto": "minor" }
  ]
}
EOF
  available go 1.27.1 1.27.3 1.28.0
  available postgresql 18.6 18.7 19.1
  available goose 3.28.0 3.29.1 4.0.0
  available sqlc 1.31.1 1.32.0
  available xcodegen 2.44.1 2.45.0
}

web_project() {
  cat >devbox.json <<'EOF'
{
  "packages": ["bun@latest", "nodejs@24"],
  "shell": { "scripts": { "dev": ["bun run dev"] } }
}
EOF
  locked bun@latest=1.3.11 nodejs@24=24.21.0
  echo "24.12.0" >.nvmrc
  printf 'FROM node:24-slim\n' >Dockerfile
  config <<'EOF'
{
  "tools": [
    {
      "name": "Node.js",
      "package": "nodejs",
      "files": [
        { "path": ".nvmrc", "match": "^(\\S+)$", "replace": "{version}" },
        { "path": "Dockerfile", "match": "^FROM node:(\\S+)-slim$", "replace": "FROM node:{version}-slim", "parts": 1 }
      ]
    },
    { "name": "Bun", "package": "bun" }
  ]
}
EOF
  available nodejs 24.12.0 24.21.0 25.1.0
  available bun 1.3.11 1.4.2
}

# --- check ----------------------------------------------------------------------

@test "check passes when the files match devbox.lock" {
  ruby_project
  run devbox-version-sync check
  [ "$status" -eq 0 ]
  [[ $output == *'ruby 4.0.2 (range "4.0", auto: patch) .ruby-version Dockerfile'* ]]
}

@test "check fails when a file disagrees with devbox.lock and names the fix" {
  web_project
  run devbox-version-sync check
  [ "$status" -eq 1 ]
  [[ $output == *".nvmrc pins nodejs 24.12.0, but devbox.lock has 24.21.0"* ]]
  [[ $output == *"devbox-version-sync apply nodejs"* ]]
  [[ $output == *'bun 1.3.11 (latest "latest", auto: major)'* ]]
}

@test "check fails when a pinned line is missing" {
  ruby_project
  echo "FROM ruby" >Dockerfile
  run devbox-version-sync check
  [ "$status" -eq 1 ]
  [[ $output == *"Dockerfile: expected exactly one line matching"* ]]
  [[ $output != *"ruby 4.0.2"* ]]
}

@test "check names the expected value for partial pins" {
  web_project
  devbox-version-sync apply nodejs
  echo "FROM node:23-slim" >Dockerfile
  run devbox-version-sync check
  [ "$status" -eq 1 ]
  [[ $output == *"Dockerfile pins nodejs 23, but devbox.lock has 24.21.0 (so Dockerfile should pin 24)."* ]]
}

@test "apply writes the devbox.lock version into the files" {
  web_project
  run devbox-version-sync apply
  [ "$status" -eq 0 ]
  [ "$(cat .nvmrc)" = "24.21.0" ]
  [ "$(cat Dockerfile)" = "FROM node:24-slim" ]
  devbox-version-sync check
}

@test "check rejects unknown keys and missing file fields" {
  ruby_project
  config <<'EOF'
{ "tools": [ { "package": "ruby", "atuo": "patch", "files": [ { "path": ".ruby-version", "match": "^ruby-(\\S+)$" } ] } ] }
EOF
  run devbox-version-sync check
  [ "$status" -eq 1 ]
  [[ $output == *'ruby: unknown key "atuo"'* ]]
  [[ $output == *'ruby: file is missing "replace"'* ]]
}

@test "check rejects a policy that doesn't match the devbox.json range" {
  ruby_project
  jq '.tools[0].auto = "minor"' .github/devbox-version-sync.json >c && mv c .github/devbox-version-sync.json
  run devbox-version-sync check
  [ "$status" -eq 1 ]
  [[ $output == *'auto is minor, but devbox.json pins the "4.0" range. Make them match: pin "4" in devbox.json, or set auto to patch.'* ]]
}

@test "check rejects a policy that would never update an exact pin" {
  go_project
  jq '.tools[1].auto = "patch"' .github/devbox-version-sync.json >c && mv c .github/devbox-version-sync.json
  run devbox-version-sync check
  [ "$status" -eq 1 ]
  [[ $output == *"postgresql: auto: patch keeps every part of 18.6 fixed, so it would never update. For versions like 18.6, use minor."* ]]
  [[ $output == *"go 1.27.1"* ]]
}

@test "check requires a policy for exact pins" {
  go_project
  jq 'del(.tools[0].auto)' .github/devbox-version-sync.json >c && mv c .github/devbox-version-sync.json
  run devbox-version-sync check
  [ "$status" -eq 1 ]
  [[ $output == *"go: devbox.json pins the exact version 1.27.1, so set auto"* ]]
}

@test "check rejects anything but major or none for latest" {
  web_project
  jq '.tools[1].auto = "minor"' .github/devbox-version-sync.json >c && mv c .github/devbox-version-sync.json
  run devbox-version-sync check
  [ "$status" -eq 1 ]
  [[ $output == *"bun: devbox.json takes bun@latest"* ]]
}

@test "check rejects unknown checks" {
  ruby_project
  jq '.tools[0].checks = ["dockr:ruby"]' .github/devbox-version-sync.json >c && mv c .github/devbox-version-sync.json
  run devbox-version-sync check
  [ "$status" -eq 1 ]
  [[ $output == *"unknown check 'dockr:ruby'"* ]]
}

# --- list and info ----------------------------------------------------------------

@test "list groups packages, keeping config order" {
  go_project
  run devbox-version-sync list
  [ "$status" -eq 0 ]
  [ "$output" = '[{"name":"go","packages":["go"]},{"name":"postgresql","packages":["postgresql"]},{"name":"tools","packages":["goose","sqlc"]},{"name":"xcodegen","packages":["xcodegen"]}]' ]
}

@test "info describes a package" {
  ruby_project
  run devbox-version-sync info ruby
  [ "$status" -eq 0 ]
  [ "$output" = '{"package":"ruby","name":"Ruby","mode":"range","spec":"4.0","auto":"patch","follows":"4.0.x","version":"4.0.2","after_update":"bundle install","files":["devbox.lock",".ruby-version","Dockerfile"]}' ]
}

# --- update -----------------------------------------------------------------------

@test "update moves a range to its newest patch and leaves devbox.json alone" {
  ruby_project
  cp devbox.json devbox.json.before
  run devbox-version-sync update ruby
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 <<<"$output" | jq -c '.[0] | [.from, .to, .paths]')" = '["4.0.2","4.0.9",["devbox.lock",".ruby-version","Dockerfile"]]' ]
  [ "$(cat .ruby-version)" = "ruby-4.0.9" ]
  grep -qx 'ARG RUBY_VERSION=4.0.9' Dockerfile
  [ "$(jq -r '.packages["ruby@4.0"].version' devbox.lock)" = "4.0.9" ]
  cmp devbox.json devbox.json.before
}

@test "update does nothing when everything is current" {
  ruby_project
  devbox-version-sync update ruby >/dev/null
  run devbox-version-sync update ruby
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 <<<"$output")" = "[]" ]
  [[ $output == *"already pinned. Nothing to do."* ]]
}

@test "update waits for the Docker image" {
  ruby_project
  echo "docker.io/library/ruby:4.0.9-slim" >"$FAKE_DOCKER_MISSING"
  run devbox-version-sync update ruby
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 <<<"$output")" = "[]" ]
  [[ $output == *"Devbox offers Ruby 4.0.9, but docker.io/library/ruby:4.0.9-slim is not published yet. Will retry next run."* ]]
  [ "$(cat .ruby-version)" = "ruby-4.0.2" ]
  [ "$(jq -r '.packages["ruby@4.0"].version' devbox.lock)" = "4.0.2" ]
}

@test "update waits for ruby/setup-ruby" {
  ruby_project
  echo '{"ruby": ["4.0.2"]}' >"$BATS_TEST_TMPDIR/setup-ruby.json"
  GITHUB_ACTIONS=true run devbox-version-sync update ruby
  [ "$status" -eq 0 ]
  [[ $output == *"::notice::Devbox offers Ruby 4.0.9, but ruby/setup-ruby doesn't offer Ruby 4.0.9 yet. Will retry next run."* ]]
}

@test "update moves an exact pin within its series and rewrites devbox.json in place" {
  go_project
  run devbox-version-sync update go
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 <<<"$output" | jq -c '.[0] | [.from, .to, .from_spec, .to_spec, .paths]')" = '["1.27.1","1.27.3","1.27.1","1.27.3",["devbox.json","devbox.lock","go.mod","Dockerfile"]]' ]
  grep -qx '    "go": "1.27.3",' devbox.json
  grep -qx 'go 1.27.3' go.mod
  grep -qx 'FROM golang:1.27.3-trixie AS build' Dockerfile
  [[ $(lock_keys) != *go@1.27.1* && $(lock_keys) == *go@1.27.3* ]]
}

@test "update follows minor releases when the policy allows" {
  go_project
  run devbox-version-sync update goose sqlc postgresql
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 <<<"$output" | jq -c 'map([.package, .to])')" = '[["goose","3.29.1"],["sqlc","1.32.0"],["postgresql","18.7"]]' ]
  grep -qx '    "postgresql": "18.7",' devbox.json
}

@test "update rewrites the version inside a package object" {
  go_project
  run devbox-version-sync update xcodegen
  [ "$status" -eq 0 ]
  [ "$(jq -c '.packages.xcodegen' devbox.json)" = '{"version":"2.45.0","platforms":["aarch64-darwin","x86_64-darwin"]}' ]
  [ "$(lock_keys)" = "go@1.27.1 goose@3.28.0 postgresql@18.6 sqlc@1.31.1 xcodegen@2.45.0" ]
}

@test "update fixes files that drifted from devbox.lock" {
  web_project
  run devbox-version-sync update nodejs
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 <<<"$output" | jq -c '.[0] | [.from, .to]')" = '["24.12.0","24.21.0"]' ]
  [ "$(cat .nvmrc)" = "24.21.0" ]
}

@test "update takes the newest release for latest" {
  web_project
  run devbox-version-sync update bun
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 <<<"$output" | jq -c '.[0] | [.from, .to]')" = '["1.3.11","1.4.2"]' ]
  [ "$(jq -c .packages devbox.json)" = '["bun@latest","nodejs@24"]' ]
}

@test "update leaves auto: none alone" {
  ruby_project
  jq '.tools[0].auto = "none"' .github/devbox-version-sync.json >c && mv c .github/devbox-version-sync.json
  run devbox-version-sync update ruby
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 <<<"$output")" = "[]" ]
  [ "$(cat .ruby-version)" = "ruby-4.0.2" ]
}

@test "update won't move a pin backwards" {
  ruby_project
  echo "ruby-4.0.10" >.ruby-version
  run devbox-version-sync update ruby
  [ "$status" -eq 0 ]
  [[ $output == *"ruby is pinned at 4.0.10, but Devbox resolves ruby@4.0 to 4.0.9. Leaving it alone."* ]]
  [ "$(tail -n 1 <<<"$output")" = "[]" ]
}

# --- upgrade-available --------------------------------------------------------------

@test "upgrade-available reports a release beyond the policy" {
  ruby_project
  run devbox-version-sync upgrade-available ruby
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 <<<"$output")" = "4.1.0" ]
}

@test "upgrade-available is quiet when the policy covers the newest release" {
  go_project
  run devbox-version-sync upgrade-available sqlc
  [ "$status" -eq 0 ]
  [ -z "$(grep -v '^devbox' <<<"$output" || true)" ]
  run devbox-version-sync upgrade-available goose
  [ "$(tail -n 1 <<<"$output")" = "4.0.0" ]
}

@test "upgrade-available reports any newer release for auto: none" {
  ruby_project
  jq '.tools[0].auto = "none"' .github/devbox-version-sync.json >c && mv c .github/devbox-version-sync.json
  run devbox-version-sync upgrade-available ruby
  [ "$(tail -n 1 <<<"$output")" = "4.1.0" ]
}

# --- upgrade ------------------------------------------------------------------------

@test "upgrade moves a range to the newest series" {
  ruby_project
  run devbox-version-sync upgrade ruby
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 <<<"$output" | jq -c '.[0] | [.from, .to, .from_spec, .to_spec, .paths]')" = '["4.0.2","4.1.0","4.0","4.1",["devbox.json","devbox.lock",".ruby-version","Dockerfile"]]' ]
  grep -qx '    "ruby":   "4.1",' devbox.json
  [ "$(lock_keys)" = "clang@latest ruby@4.1 sqlite@3" ]
  [ "$(cat .ruby-version)" = "ruby-4.1.0" ]
}

@test "upgrade moves an exact pin to a chosen series" {
  go_project
  available go 1.29.0
  run devbox-version-sync upgrade go 1.28
  [ "$status" -eq 0 ]
  grep -qx '    "go": "1.28.0",' devbox.json
  grep -qx 'go 1.28.0' go.mod
}

@test "upgrade refuses a version that isn't newer" {
  ruby_project
  devbox-version-sync update ruby >/dev/null 2>&1
  run devbox-version-sync upgrade ruby 4.0
  [ "$status" -eq 1 ]
  [[ $output == *"Devbox resolves ruby@4.0 to 4.0.9, which is not newer than 4.0.9."* ]]
}

@test "upgrade fails when Devbox has no such version" {
  ruby_project
  run devbox-version-sync upgrade ruby 5
  [ "$status" -eq 1 ]
  [[ $output == *"devbox could not resolve ruby@5"* ]]
}

@test "upgrade fails while the Docker image is missing" {
  ruby_project
  echo "docker.io/library/ruby:4.1.0-slim" >"$FAKE_DOCKER_MISSING"
  run devbox-version-sync upgrade ruby
  [ "$status" -eq 1 ]
  [[ $output == *"docker.io/library/ruby:4.1.0-slim is not published yet. Try again later."* ]]
  grep -qx '    "ruby":   "4.0",' devbox.json
}

# --- describe -------------------------------------------------------------------------

@test "describe titles a single bump and lists follow-up commands" {
  ruby_project
  devbox-version-sync update ruby 2>/dev/null >result.json
  run devbox-version-sync describe bump result.json
  [ "$status" -eq 0 ]
  [ "$(jq -r .title <<<"$output")" = "Bump Ruby from 4.0.2 to 4.0.9" ]
  [ "$(jq -r .paths <<<"$output")" = $'devbox.lock\n.ruby-version\nDockerfile' ]
  [[ $(jq -r .body <<<"$output") == *'| Ruby (`ruby`) | 4.0.2 | 4.0.9 |'* ]]
  [[ $(jq -r .body <<<"$output") == *'- `bundle install`'* ]]
}

@test "describe titles a group bump" {
  go_project
  devbox-version-sync update goose sqlc 2>/dev/null >result.json
  run devbox-version-sync describe bump result.json
  [ "$(jq -r .title <<<"$output")" = "Bump goose to 3.29.1 and sqlc to 1.32.0" ]
  [ "$(jq -r .paths <<<"$output")" = $'devbox.json\ndevbox.lock' ]
}

@test "describe explains an upgrade" {
  ruby_project
  devbox-version-sync upgrade ruby 2>/dev/null >result.json
  run devbox-version-sync describe upgrade result.json
  [ "$(jq -r .title <<<"$output")" = "Upgrade Ruby from 4.0.2 to 4.1.0" ]
  [[ $(jq -r .body <<<"$output") == *'Moves `ruby` from the `4.0` range in `devbox.json` to `4.1`, which Devbox resolves to 4.1.0.'* ]]
  [[ $(jq -r .body <<<"$output") == *'run `devbox install`, then `bundle install`, and try the app locally'* ]]
}
