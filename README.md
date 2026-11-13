# devbox-version-sync

Keeps a project's version pins in step with [Devbox](https://www.jetify.com/devbox). Devbox leads: when it offers a newer release of a package, a weekly workflow updates `devbox.json`, `devbox.lock` and every other file that pins the version (`.ruby-version`, `.nvmrc`, `go.mod`, Dockerfiles, ...) together, in one pull request.

Each package has an update policy. Releases within it, such as Ruby 4.0.x, become pull requests automatically. A release beyond it, such as Ruby 4.1, gets an issue instead, and you move to it by running an upgrade workflow when you're ready.

## Setup

1. Add `.github/devbox-version-sync.json` to your repository (see [Config](#config) and [`examples/`](examples)).
2. Copy [`examples/devbox_version_sync.yml`](examples/devbox_version_sync.yml) and [`examples/devbox_version_upgrade.yml`](examples/devbox_version_upgrade.yml) into `.github/workflows/`.
3. Add a `DEVBOX_VERSION_SYNC_TOKEN` secret: a fine-grained personal access token with Contents and Pull requests write access to the repository. Without it, pull requests are opened with `GITHUB_TOKEN` and don't trigger CI.
4. Optionally, run `devbox-version-sync check` in CI so a hand edit that leaves files disagreeing with `devbox.lock` fails:

   ```yaml
   - uses: wamonroe/devbox-version-sync@v1
   - run: devbox-version-sync check
   ```

   This needs only `jq` and `perl`, not Devbox.

## Config

```json
{
  "$schema": "https://raw.githubusercontent.com/wamonroe/devbox-version-sync/v1/schema/config.schema.json",
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
```

| Key | |
| --- | --- |
| `package` | Package name in `devbox.json`. Required. |
| `name` | Name for pull requests and issues. Defaults to `package`. |
| `auto` | Update policy: `patch`, `minor`, `major` or `none`. See below. |
| `group` | Packages with the same group are updated in one pull request, e.g. CLI tools that only `devbox.json` pins. |
| `checks` | What must exist before moving to a version. Until it does, the sync workflow waits and the upgrade workflow fails. `{version}` is replaced with the version. <br>`docker:IMAGE`: the image is published.<br>`url:URL`: the URL responds.<br>`setup-ruby`: `ruby/setup-ruby@v1` can install that Ruby, so CI using it won't break. |
| `after_update` | Command to run after pulling the change, listed in pull requests. |
| `files[]` | Other files that pin the version. `path`, the file; `match`, a Perl regex matching exactly one line, whose first capture group is the version; `replace`, the replacement for the matched text, with `{version}`; `parts` (optional), to pin only the first N parts (`1` for `FROM node:24-slim`). |

### Update policies

A policy says how many leading version parts automatic updates keep fixed:

| `auto` | Keeps fixed | Ruby 4.0.9 follows | Postgres 18.6 follows |
| --- | --- | --- | --- |
| `patch` | first two parts | 4.0.x | (never updates; rejected) |
| `minor` | first part | 4.x | 18.x |
| `major` | nothing | every release | every release |
| `none` | everything | nothing automatic | nothing automatic |

The parts are counted by position, so pick by what the project's releases mean, not their names. Ruby and Go ship significant changes in x.y releases, so they want `patch`. PostgreSQL versions have two parts and 18.7 is its patch release, so it wants `minor`. `check` rejects a policy that would never update.

### How `devbox.json` pins a package

The policy has to fit how `devbox.json` pins the package. `devbox.json` can list packages in any of its forms (`"ruby": "4.0"`, `"ruby": { "version": "4.0" }`, `["ruby@4.0"]`), and the tool keeps the file's layout when it edits it.

- **A range** (`"ruby": "4.0"`, `"nodejs": "24"`): `devbox update` moves within it, so the range is the policy. `auto` is optional, and if given it must match: `"4.0"` is `patch`, `"24"` is `minor`. Upgrading changes the range (`"4.0"` to `"4.1"`).
- **An exact version** (`"go": "1.27.1"`): `auto` is required. Updates rewrite the version in `devbox.json`.
- **`latest`**: every release is an update, so `auto` can only be `major` (the default) or `none`. To hold back major releases, pin a range instead.

## Workflows

**Sync** (`.github/workflows/sync.yml`, run weekly) opens one pull request per package or group, on the branch `devbox-version-sync/<package or group>`. For each release beyond a package's policy, it opens or updates an issue (labelled `devbox-version-upgrade`), adds a callout to the pull request and notes it in the run summary. It closes the issue once nothing is beyond the policy.

| Input | Default | |
| --- | --- | --- |
| `config` | `.github/devbox-version-sync.json` | |
| `assignees` | | Comma-separated users to assign pull requests and issues to. |
| `upgrade-workflow` | `devbox_version_upgrade.yml` | The caller's upgrade workflow file name, linked from issues. |
| `issue-label` | `devbox-version-upgrade` | |

**Upgrade** (`.github/workflows/upgrade.yml`, run by hand) moves one package beyond its policy. Its `version` input takes a version or series ("4.1"); leave it blank for the newest. The pull request it opens includes a checklist and closes the package's issue. It takes the same `config`, `assignees` and `issue-label` inputs.

Both workflows take an optional `token` secret and need the permissions shown in the examples. Give both callers the same `concurrency` group so they never push at once.

## Command line

The workflows call `bin/devbox-version-sync`, which you can also run from a project root. It needs `jq`, `perl` and, for `update`, `upgrade` and `upgrade-available`, `devbox`.

```
devbox-version-sync check                    # validate the config and the pinned files
devbox-version-sync apply [PACKAGE...]       # write devbox.lock's versions into the files
devbox-version-sync info PACKAGE             # mode, policy, version and files
devbox-version-sync update PACKAGE...        # what the sync workflow does
devbox-version-sync upgrade-available PACKAGE
devbox-version-sync upgrade PACKAGE [VERSION]
```

Run it with no arguments for the full list.

## Development

```sh
bats tests
shellcheck bin/* tests/fakes/*
```

The tests run against small projects, with fake `devbox` and `docker` commands in `tests/fakes`.

Callers use the `v1` tag, and the reusable workflows use the action at `@v1`, so to release, move the tag: `git tag -f v1 && git push -f origin v1`. Breaking changes to the config or inputs get a `v2`.
