#!/bin/bash
# Reinstall Android apps that Android's PackageManager dropped.
#
# WHY THIS EXISTS
# ---------------
# Android's PackageManager reconciles /data/app against
# /data/system/packages.xml at boot. Any directory under /data/app that has no
# matching record in packages.xml is treated as an orphan and DELETED.
#
# That is normally harmless -- packages.xml and /data/app are written together.
# But it bites whenever packages.xml is lost or reset while /data/app is still
# populated, which is exactly what happens when switching Android versions:
#
#   * an older Android cannot read a newer packages.xml (and vice versa), so
#     the file has to be reset for the downgrade to boot at all
#   * the moment it is reset, the next boot sees a fresh database and wipes
#     every installed app, including multi-gigabyte games
#
# Measured on this host: switching Android 17 -> Android 13 with a reset
# packages.xml removed all 10 installed apps (13 GB under /data/app) and their
# 24 GB of per-app data in one boot.
#
# WHAT IT DOES
# ------------
# APKs are kept outside userdata, in /var/lib/waydroid/apk-stash, which the
# PackageManager never inspects. After Android finishes booting this script
# reinstalls any stashed APK whose package is not currently installed. With
# `-r` and the app's data left in /data/data, an update-in-place restores the
# app without touching its saved state.
#
# The stash is populated by the same script on first run: it copies base.apk
# out of every /data/app/<mangling>/<pkg>-<hash>/ directory it finds.
#
# Runs in the background from startup.sh so it never delays the UI.

set -u

STASH=/var/lib/waydroid/apk-stash
LOG=/tmp/waydroid-apprestore.log
LXC="lxc-attach -P /var/lib/waydroid/lxc -n waydroid"
WAYDROID_WORK=/var/lib/waydroid

log() { printf '[apprestore] %s\n' "$*" | tee -a "$LOG"; }

mkdir -p "$STASH"

# ---------------------------------------------------------------- populate
# Pull base.apk out of every installed app dir into the stash.
#
# The directory name is "<package>-<base64-ish hash>", and the hash alphabet
# includes '-' and '_', so stripping from the LAST '-' is not reliable:
#
#     com.tencent.tmgp.sgame-BwWbIEwBPYiePCjlrGw   -> ok
#     com.valvesoftware.underlords-mYPRw7sdyGyHI5  -> ok
#     com.valvesoftware.underlords-                -> becomes "underlords"
#
# Getting this wrong made the restore loop look for packages that do not exist
# and produced a second, badly-named stash entry. Derive the real package name
# by scanning backwards for the first segment that is a valid Java package
# (every dot-separated part starts with a letter), which stops at the correct
# place regardless of what the hash looks like.
in_populate() {
    local appdir="$WAYDROID_WORK/userdata/app"
    [ -d "$appdir" ] || return 0

    local apk dir pkg dest n=0
    while IFS= read -r apk; do
        dir=$(basename "$(dirname "$apk")")

        # Walk the '-'-separated prefixes from longest to shortest and take the
        # first one whose parts all look like Java identifiers.
        pkg=""
        local cand="$dir"
        while [ -n "$cand" ]; do
            local ok=1 part
            local IFS='.'
            for part in $cand; do
                case "$part" in
                    [a-zA-Z]*) ;;
                    *) ok=0; break ;;
                esac
            done
            unset IFS
            if [ "$ok" = "1" ] && printf '%s' "$cand" | grep -qE '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$'; then
                pkg="$cand"
                break
            fi
            case "$cand" in
                *-*) cand="${cand%-*}" ;;
                *) break ;;
            esac
        done

        [ -n "$pkg" ] || { log "could not derive package name from '$dir'"; continue; }

        dest="$STASH/$pkg.apk"
        if [ ! -f "$dest" ]; then
            cp -a "$apk" "$dest" 2>/dev/null && { n=$((n+1)); log "stashed $pkg"; }
        fi
    done < <(find "$appdir" -maxdepth 3 -name base.apk 2>/dev/null)

    [ "$n" -gt 0 ] && log "stashed $n apk(s) into $STASH"
    return 0
}

# ----------------------------------------------------------------- wait boot
# sys.boot_completed is set once PackageManager has finished its reconcile,
# which is the point after which an install will succeed.
in_wait_boot() {
    local i
    for i in $(seq 1 180); do
        local v
        v=$($LXC -- getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
        [ "$v" = "1" ] && return 0
        sleep 5
    done
    return 1
}

# --------------------------------------------------------------- reinstall
in_reinstall() {
    local apk pkg installed n=0

    # `pm install` runs INSIDE Android, so it can only open paths that exist in
    # Android's own filesystem. Handing it a host path fails with:
    #
    #     Error: Unable to open file: /var/lib/waydroid/apk-stash/<pkg>.apk
    #     Consider using a file under /data/local/tmp/
    #
    # Android itself names the fix: stage each APK onto the Android side and
    # install from there.
    #
    # NOTE -- the host path is NOT the answer. Writing to
    # /var/lib/waydroid/userdata/local/tmp does nothing, because Android's
    # /data is a *different filesystem* from that directory. Measured:
    #
    #     android  /data            dev 57
    #     android  /data/local/tmp  dev 57, inode 23215229
    #     container userdata        dev 29
    #     container userdata/local/tmp  dev 29, inode 23175302
    #
    # and a file written to the container path is simply invisible:
    #
    #     $ echo x > /var/lib/waydroid/userdata/local/tmp/probe.txt
    #     android$ cat /data/local/tmp/probe.txt
    #     cat: /data/local/tmp/probe.txt: No such file or directory
    #
    # So stage by PIPING the bytes through lxc-attach into Android's own
    # namespace, which is the only view where /data/local/tmp is real:
    #
    #     cat "$apk" | lxc-attach ... -- sh -c 'cat > /data/local/tmp/x.apk'
    #
    # Verified on a 1.8 GB APK (byte-exact) and by a successful `pm install`.
    local stage_path="/data/local/tmp"
    $LXC -- mkdir -p "$stage_path" 2>/dev/null
    $LXC -- chmod 0771 "$stage_path" 2>/dev/null

    for apk in "$STASH"/*.apk; do
        [ -f "$apk" ] || continue
        pkg=$(basename "$apk" .apk)

        # Already present? Then nothing to do -- this is the normal case once
        # the apps have been reinstalled successfully.
        if $LXC -- pm list packages 2>/dev/null | grep -qx "package:$pkg"; then
            continue
        fi

        log "reinstalling $pkg"
        local base staged
        base=$(basename "$apk")
        staged="${stage_path}/${base}"
        if ! cat "$apk" | $LXC -- sh -c "cat > '$staged'" 2>>"$LOG"; then
            log "FAILED to stage $pkg (out of space?)"
            continue
        fi

        # Sanity-check the staged copy; a truncated APK installs with a
        # confusing parse error rather than a clear one.
        src_sz=$(stat -c %s "$apk" 2>/dev/null || echo 0)
        dst_sz=$($LXC -- stat -c %s "$staged" 2>/dev/null || echo -1)
        if [ "$src_sz" != "$dst_sz" ]; then
            log "FAILED to stage $pkg (size $dst_sz != $src_sz)"
            $LXC -- rm -f "$staged" 2>/dev/null
            continue
        fi

        # -r : replace/keep data, -d : allow version downgrade, -g : grant
        # runtime permissions the apps declared (Android 13 would otherwise
        # gate them behind a UI we cannot reach before login).
        if $LXC -- pm install -r -d -g "$staged" 2>&1 | tee -a "$LOG" | grep -q Success; then
            n=$((n+1))
            log "installed $pkg"
        else
            log "FAILED to install $pkg"
        fi

        $LXC -- rm -f "$staged" 2>/dev/null
    done
    [ "$n" -gt 0 ] && log "reinstalled $n app(s)" || log "all stashed apps already present"
}

# If Android never came up there is nothing useful to do.
if ! in_wait_boot; then
    log "Android did not reach sys.boot_completed; skipping app restore"
    exit 0
fi

in_populate
in_reinstall
log "done"
