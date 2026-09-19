# Wolf debugging method (from games-on-whales docs)

Source: <https://games-on-whales.github.io/wolf/stable/user/troubleshooting.html>

> "When something doesn't work it'll be helpful to be able to see the logs from
> Wolf, please change the env variable **`WOLF_LOG_LEVEL` to `DEBUG`** and try to
> replicate ..."

## How Wolf is actually run on this host

Wolf is deployed via docker-compose, but this host has **no `docker compose`
binary available from the agent shell**. Deployment facts:

| Item | Value |
| --- | --- |
| compose file | `/data/stacks/wolf/docker-compose.yml` |
| Wolf image | `gameonwhales/wolf:stable` |
| container name | `wolf` |
| live config (in container) | `/etc/wolf/cfg/config.toml` |
| config bind source | `/mnt/HGST4/wolf` -> `/etc/wolf` |
| runtime dir bind | `/data/stacks/wolf/run-user-wolf` -> `/run/user/wolf` |
| network | host |

`/mnt/HGST4` is **not visible to the agent shell** (the agent runs in a
container); the path only resolves for the Docker daemon and inside Wolf. So
edit the config **through the container**, e.g.:

```bash
docker exec wolf sed -n '300,340p' /etc/wolf/cfg/config.toml
docker exec wolf cp /etc/wolf/cfg/config.toml /etc/wolf/cfg/config.toml.bak-$(date +%Y%m%d-%H%M%S)
```

## Turning on DEBUG

`WOLF_LOG_LEVEL` is an environment variable on the `wolf` container (not a
config.toml setting). Because there is no compose binary, recreate the container
preserving its exact original config:

```bash
docker rm -f wolf
docker run -d --name wolf --network=host --restart=unless-stopped \
  -e WOLF_STOP_CONTAINER_ON_EXIT=false \
  -e WOLF_LOG_LEVEL=DEBUG \
  -v /mnt/HGST4/wolf/:/etc/wolf \
  -v /var/run/docker.sock:/var/run/docker.sock:rw \
  -v /dev/:/dev/:rw \
  -v /run/udev:/run/udev:rw \
  -v /data/stacks/wolf/run-user-wolf:/run/user/wolf \
  --device-cgroup-rule "c 13:* rmw" \
  --device /dev/dri --device /dev/uinput --device /dev/uhid \
  gameonwhales/wolf:stable
```

Verify:

```bash
docker inspect wolf --format '{{range .Config.Env}}{{println .}}{{end}}' | grep WOLF_LOG_LEVEL
docker logs wolf 2>&1 | grep DEBUG | tail
```

Drop back to `INFO` for normal use -- DEBUG is very verbose.

## Other useful bits from the same page

* **Black screen + cursor on first run** is expected while Wolf pulls the image
  and the app does first-time updates. Only investigate if it persists or
  Moonlight drops the session.
* **Ports Wolf needs free**: 47984/tcp, 47989/tcp, 47999/udp, 48010/tcp,
  48100/udp, 48200/udp. "Address already in use" usually means Sunshine is
  still running.
* **`Unable to recognise GPU vendor: red hat, inc.`** -> multiple GPUs; see the
  Multiple GPU configuration page.
* **Controller also drives the host desktop** -> udev rules missing/outdated.
  Diagnose with the bundled script:
  ```bash
  sudo ./scripts/wolf-input-diag.sh host
  ```
  Any line marked `LEAK` is reachable by the host desktop. Fix by installing
  `85-wolf.rules` from the Wolf repo, then
  `sudo udevadm control --reload-rules && sudo udevadm trigger`.
* **AV1 problems** (e.g. 7900XTX, N150): comment out
  `[[gstreamer.video.av1_encoders]]` in the config.
* **Stutter every 5 min on a Linux laptop client**: NetworkManager/wpa_supplicant
  bgscan. Test with
  `iperf3 -c <server> -t 690 -u -R -b 80M`; fix bgscan via an NM dispatcher
  script.

## Why this mattered for the Waydroid app

The live `/etc/wolf/cfg/config.toml` hardcoded `RUN_SWAY=1` on **both** Waydroid
app entries (profile `moonlight-profile-id` and profile `public`). Waydroid
ships its own Wayland compositor, so the extra sway was pure overhead -- and
gow's `launcher()` appends `&& killall sway` to the exec line, so the session
died with the compositor. Both entries were changed to `RUN_SWAY=false`.
