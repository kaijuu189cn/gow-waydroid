#!/bin/bash
# OOM guard: stop lmkd from killing the game by mistake.
#
# Why this exists:
#   android.hardware.graphics.allocator@4.0-service.minigbm leaks a 4KB
#   scudo:secondary page per freed graphics buffer and never munmaps it.
#   During game battles it reaches 20GB+ in minutes. It runs at
#   oom_score_adj=-1000, so lmkd cannot reclaim it and kills the GAME instead.
#
# What it does -- and deliberately does NOT do:
#   It only retunes oom_score_adj: the allocator is demoted (so lmkd may
#   reclaim it first when memory genuinely runs out) and the games are pinned
#   at -1000 (so they are picked last).
#
#   It does NOT kill the allocator. Doing so takes the whole Android user space
#   down -- init treats the graphics HAL as a display dependency:
#
#       init: Service 'vendor.graphics.allocator-4-0' received SIGTERM
#       init: Service 'surfaceflinger' received SIGKILL
#       init: Untracked process (pid 449 name: (system_server) state: Z) ...
#       ... systemui, launcher, every app -> zombie
#
#   That reboots Android and the game dies anyway, so the ceiling below is
#   advisory only: it logs, it never signals.
#
# Why it scans /proc instead of using `waydroid shell`:
#   `waydroid shell -- pidof <pkg>` is extremely slow (spins at 99% CPU and
#   often never returns), and the PID it prints is not the one this namespace
#   must signal. Scanning /proc/*/cmdline matches the real host-visible PID.

_AL_LOG=/tmp/waydroid-oomguard.log
_AL_MAX_MB="${WAYDROID_ALLOC_MAX_MB:-6144}"
_PROTECT="${WAYDROID_OOM_PROTECT:-com.tencent.tmgp.sgame com.miHoYo.Yuanshen}"

# CPU mask applied to every thread of the protected games. "off" disables it.
# Default spans all CPUs the container can see; see the comment at the taskset
# call for why this matters (short version: Android's cpuset controller is dead
# in this container, so the game's main thread can miss the 5s input-dispatch
# deadline and get ANR-killed during its very heavy startup).
if [ "${WAYDROID_GAME_CPUS:-auto}" = "off" ]; then
    _GAME_CPUS=""
elif [ -n "${WAYDROID_GAME_CPUS:-}" ] && [ "${WAYDROID_GAME_CPUS}" != "auto" ]; then
    _GAME_CPUS="${WAYDROID_GAME_CPUS}"
else
    _GAME_CPUS="$(taskset -pc $$ 2>/dev/null | sed 's/.*: //')"
    [ -n "$_GAME_CPUS" ] || _GAME_CPUS="0-$(( $(nproc 2>/dev/null || echo 1) - 1 ))"
fi
_last_warn=0
_alog() { echo "[$(date '+%H:%M:%S')] $*" >>"$_AL_LOG"; }
_alog "guard started (ceiling ${_AL_MAX_MB}MB, protect: ${_PROTECT}, game cpus: ${_GAME_CPUS:-none})"

# Print "pid cmdline" for every process whose cmdline contains any pattern.
_scan() {
    local p cmd
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd="$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)"
        [ -n "$cmd" ] || continue
        local pat
        for pat in $1; do
            case "$cmd" in
                *"$pat"*) echo "${p#/proc/} $cmd" ;;
            esac
        done
    done
}

while true; do
    # --- 1. protect game processes (match real host-visible PIDs) ----------
    for _line in $(_scan "$_PROTECT"); do
        _pid="${_line%% *}"
        case "$_pid" in ''|*[!0-9]*) continue ;; esac
        [ -w "/proc/$_pid/oom_score_adj" ] || continue
        _cur="$(cat "/proc/$_pid/oom_score_adj" 2>/dev/null)"
        if [ "$_cur" != "-1000" ]; then
            echo -1000 >"/proc/$_pid/oom_score_adj" 2>/dev/null \
                && _alog "protected pid $_pid (adj $_cur -> -1000): ${_line#* }"
        fi

        # --------------------------------------------------------------
        # Pin the game's threads to the FULL cpu set.
        # --------------------------------------------------------------
        # Android's cpuset controller is not functional in this container:
        # /dev/cpuset/{top-app,foreground,...} exist but contain no `cpus`
        # or `tasks` files, so every thread of the game lands in the root
        # cgroup with no priority separation from Android's own background
        # threads. During startup Honor of Kings runs ~9.7 cores' worth of
        # ARM-translated work, and its MAIN thread -- the one that must
        # acknowledge FocusEvent(hasFocus=true) -- does not get scheduled
        # within the 5s input-dispatch timeout. Android then declares an ANR
        # even though the thread is not blocked on anything:
        #
        #     ActivityManager: ANR in com.tencent.tmgp.sgame
        #     Reason: Input dispatching timed out ... Waited 5004ms
        #     ANR trace main thread: #00 __epoll_pwait   <- idle, not stuck
        #
        # Spreading the threads over every available CPU (rather than letting
        # them pile onto a busy subset) gives the main thread room to run.
        # This is best-effort: if the kernel rejects the mask we keep going,
        # because losing the game to an ANR is much worse than a pin failure.
        if [ -n "${_GAME_CPUS:-}" ] && [ -w "/proc/$_pid/task" ]; then
            for _t in "/proc/$_pid"/task/*; do
                [ -d "$_t" ] || continue
                taskset -p "$_GAME_CPUS" "${_t##*/}" >/dev/null 2>&1
            done
        fi
    done

    # --- 2. demote + watchdog the leaking allocator ------------------------
    _apid="$(pidof android.hardware.graphics.allocator@4.0-service.minigbm 2>/dev/null | awk '{print $1}')"
    if [ -n "$_apid" ] && [ -r "/proc/$_apid/status" ]; then
        _rss_kb="$(awk '/^VmRSS:/{print $2}' "/proc/$_apid/status" 2>/dev/null)"
        _rss_mb=$(( ${_rss_kb:-0} / 1024 ))

        if [ -w "/proc/$_apid/oom_score_adj" ]; then
            _aadj="$(cat "/proc/$_apid/oom_score_adj" 2>/dev/null)"
            if [ "$_aadj" != "0" ]; then
                echo 0 >"/proc/$_apid/oom_score_adj" 2>/dev/null \
                    && _alog "allocator pid $_apid adj $_aadj -> 0 (killable by lmkd)"
            fi
        fi

        # ------------------------------------------------------------------
        # Ceiling: DO NOT kill the allocator here.
        # ------------------------------------------------------------------
        # An earlier revision SIGTERM'd the allocator once it passed a ceiling.
        # That is catastrophic while a game is running: Android's init treats
        # the graphics HAL as a hard dependency of the display stack and tears
        # the whole user space down with it. Observed on this host:
        #
        #     init: Service 'vendor.graphics.allocator-4-0' (pid 235) received SIGTERM
        #     init: Service 'surfaceflinger' (pid 293) received SIGKILL
        #     init: Untracked process (pid 449 name: (system_server) state: Z) ...
        #     ... every app, systemui, launcher -> zombie
        #
        # i.e. killing the allocator reboots Android and the game dies anyway.
        # The earlier "verified safe" test only held because no game was running.
        #
        # So the guard's job is limited to adjusting oom_score_adj, which lets
        # lmkd reclaim the allocator *if and when* memory actually runs short.
        # lmkd shuts services down in the correct order; we do not.
        if [ "$_rss_mb" -gt "$_AL_MAX_MB" ]; then
            _now="$(date +%s)"
            if [ $(( _now - _last_warn )) -gt 300 ]; then
                _last_warn="$_now"
                _alog "NOTE allocator RSS ${_rss_mb}MB exceeds ${_AL_MAX_MB}MB; \
leaving it to lmkd (killing it would restart Android)"
            fi
        fi
    fi

    sleep 3
done
