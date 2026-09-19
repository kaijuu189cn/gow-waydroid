# Contributing

This repository is a standalone home for the Waydroid app. It follows
[games-on-whales/gow](https://github.com/games-on-whales/gow) app conventions so
it can be dropped into that repository as-is, either as a fork or as a pull
request.

Everything in the checklist below was verified against `gow@master`
(2026-06-21) — against the other apps in `apps/`, not against documentation.

---

## Upstream app conventions

An app is a directory under `apps/` with this shape:

```
apps/<name>/
├── _index.md          the docs page (rendered by the website)
├── assets/
│   ├── icon.png       required — shown in the client's app list
│   ├── screenshot.png required — shown at the top of the docs page
│   └── wolf.config.toml  required — the app definition
├── build/             Dockerfile (and anything it COPYs)
└── build-fedora/      Dockerfile for the Fedora variant
```

`assets/gamepadui.png` appears on some apps (lutris) and is optional.

### `_index.md`

No YAML front-matter. The H1 is the app name, immediately followed by the
screenshot, then prose:

```markdown
# Lutris

![Lutris screenshot](assets/screenshot.png)

An open-source gaming platform for Linux ...
```

This is what every other app does; the docs site relies on the relative
`assets/screenshot.png` path.

### Registering the app in CI

Two lines in `.github/workflows/auto-build.yml` — one in the main apps matrix,
one in the Fedora matrix:

```yaml
  apps:
    strategy:
      matrix:
        image:
          - { name: youtube,   docker_path: apps, platforms: "linux/amd64" }
          - { name: waydroid,  docker_path: apps, platforms: "linux/amd64" }   # <- main matrix

  apps-fedora:
    strategy:
      matrix:
        image:
          - { name: waydroid,  docker_path: apps, platforms: "linux/amd64" }   # <- fedora matrix
```

`docker_path` is `apps` for app images and `images` for base images. Both
matrices use `fail-fast: false`, so one broken app does not stop the others.

`build-wildlife.yml` fires on any push touching `apps/**` or `website/**` and
dispatches the docs rebuild — nothing app-specific is needed for that.

---

## Checklist for this repository

| Convention | Status |
| --- | --- |
| `apps/waydroid/_index.md` with H1 + screenshot line + prose | yes |
| `apps/waydroid/assets/icon.png` | yes |
| `apps/waydroid/assets/screenshot.png` | yes |
| `apps/waydroid/assets/wolf.config.toml` | yes |
| `apps/waydroid/build/Dockerfile` | yes |
| `apps/waydroid/build-fedora/Dockerfile` | yes |

**Not in this repository, needed for an upstream PR:** the two
`auto-build.yml` matrix lines above. They are part of the gow tree, not of the
app directory, so this repo cannot carry them.

---

## Build

The Dockerfile uses `RUN <<EOF` heredocs, which **require BuildKit**. The
legacy builder skips them silently and produces an image with no
`/usr/bin/waydroid`, which then exits 127. Install `docker-buildx-plugin` if
`docker build` does not already use BuildKit.

```bash
cd apps/waydroid/build
./houdini/fetch-houdini.sh          # optional, proprietary, not committed
docker build --build-arg BASE_APP_IMAGE=ghcr.io/games-on-whales/base-app:edge \
             -t gow-waydroid:latest .
```

## Verify

```bash
./tools/verify-image.sh gow-waydroid:latest
```

Exit codes: `0` all checks passed, `1` at least one failed, `2` the image could
not be inspected. Each check corresponds to a failure that actually happened
during development, so a red line means a specific known symptom is about to
return. The script was validated in both directions — it reports 18 OK on a
correct image and 17 FAIL on an unrelated image.

The checks are static (presence of files, executables and the init sections that
carry each fix). They cannot prove the app *runs*, which needs a host with a GPU
and a Moonlight client.

---

## Submitting upstream

1. Fork `games-on-whales/gow`.
2. Copy `apps/waydroid/` in, and add the two matrix lines from above.
3. Open a pull request. The description should lead with what the app does, then
   why it needs `SYS_ADMIN` / `NET_ADMIN` / `MKNOD` — Waydroid boots a nested
   container, so it is genuinely more privileged than the other apps, and that is
   the first thing a reviewer will ask about. `apps/waydroid/_index.md` has a
   section on this that can be quoted.

`docs/` in this repository is engineering history and should **not** go
upstream; `apps/waydroid/` is self-contained without it.

---

## Keeping this repository in sync

Because the app directory is meant to be copyable, avoid adding files to
`apps/waydroid/` that only make sense here. Tooling that is specific to this
repository lives in `tools/`.
