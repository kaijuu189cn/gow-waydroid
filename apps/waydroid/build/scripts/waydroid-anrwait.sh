#!/bin/bash
# Keep the game alive across Android's startup ANR.
#
# The problem
# -----------
# Honor of Kings needs ~9 seconds to process its first
# FocusEvent(hasFocus=true) -- measured directly:
#
#     $ logcat -d | grep InputDispatcher
#     InputDispatcher: a5eff3c ...sgame/SGameActivity spent 9183ms
#         processing FocusEvent(hasFocus=true)
#
# Android's per-window input dispatch timeout is 5000ms and is not
# configurable, so the app is declared ANR during a perfectly healthy start.
# The main thread is NOT blocked -- by the time the ANR trace is dumped it has
# already finished and gone back to sleep in __epoll_pwait, which is why the
# trace looks harmless:
#
#     "cent.tmgp.sgame" sysTid=5308
#       #00 __epoll_pwait
#       #05 android.os.MessageQueue.next
#       #08 android.app.ActivityThread.main
#
# Why `hide_error_dialogs=1` is the WRONG fix on its own
# -----------------------------------------------------
# Suppressing the dialog does stop it stealing focus, but AppErrors then
# auto-answers the ANR with its default choice, which is KILL:
#
#     ActivityManager: Killing 5308:com.tencent.tmgp.sgame/u0a126 (adj 102):
#         user request after error
#
# so the game dies anyway. With the dialog ENABLED the app is left running and
# simply waits for someone to choose. That choice is "Wait" -- so we make it
# automatically, as soon as the dialog appears.
#
# What this script does
# ---------------------
# Poll for an "Application Not Responding" window and tap its "Wait" button.
# Every ANR the game hits during startup is cleared within ~1s, so the game
# keeps running and eventually reaches its update/login screen.
#
# Disable with WAYDROID_ANR_AUTOWAIT=0.

_LOG=/tmp/waydroid-anrwait.log
_INTERVAL="${WAYDROID_ANR_POLL:-1}"
_log() { echo "[$(date '+%H:%M:%S')] $*" >>"$_LOG"; }

# `dumpsys` and `input` exist INSIDE Android, not on the container side -- the
# container image has neither. Running them bare silently produced nothing and
# the dialogs piled up (observed: 8 stacked ANR dialogs while this script sat
# there reporting no activity). Everything must go through lxc-attach.
_LXC="lxc-attach -P /var/lib/waydroid/lxc -n waydroid"
# NOTE: the variable is _LXC (leading underscore). This used to read `$LXC`,
# a DIFFERENT and unset name, so the function expanded to `-- sh -c "..."`,
# failed instantly, and 2>/dev/null hid the error. The helper therefore ran but
# did nothing at all -- which is exactly why ANR dialogs stacked up (observed 8
# at once) as if it were absent. Keep the underscore.
_lxc() { $_LXC -- sh -c "$1" 2>/dev/null; }

# Where to click, expressed as a fraction of the dialog's reported frame.
#
# The ANR dialog is NOT a fixed pixel size -- its frame tracks the display. The
# old hardcoded 42%/106% was measured on a 1916x1053 screen and silently became
# a no-op at other sizes: on a 1276x637 display the frame is [224,154][1052,419]
# and 42%/106% resolves to (571,434), which lands on empty dialog background
# instead of the "Wait" row. The dialog then never cleared and ANRs stacked up
# (observed: 3 at once).
#
# So derive the fractions from the DISPLAY size instead. Measured on two
# displays:
#
#   1276x637  frame [224,154][1052,419]  Wait row centre (380,357) = 19%, 77%
#   2376x1104 frame [653,440][1722,664]  Wait row centre (856,628) = 19%, 84%
#
# The dialog's internal layout does not scale proportionally, so a single
# fraction cannot match both row centres exactly. 85% is chosen because it
# lands inside the Wait row on BOTH: at 1276x637 it is y=379, and that row
# spans 332-382; at 2376x1104 it is y=630 against an observed 628. The X
# fraction is safe anywhere across the row, which is full dialog width.
_WAIT_FRAC_X=19
_WAIT_FRAC_Y=85

# Row position of the log-access dialog's "allow once" button, as a fraction of
# THAT dialog's own frame height. Measured with the dialog up on a 2376x1104
# screen: box y=253..625, allow row centred at y=533 -> (533-253)/(625-253) =
# 75%. The rows run title, message, "allow once", "deny" from top to bottom.
_LOGACCESS_ROW_FRAC=75

_log "anr-autowait started (poll ${_INTERVAL}s)"

while true; do
    # ORDER MATTERS: the ANR dialog is drawn ON TOP of the log-access dialog,
    # so it must be dismissed first. Tapping the log-access button while an ANR
    # covers it just hits the ANR instead, and the loop never converges.

    # Ask WindowManager whether an ANR dialog is up, and where it is.
    #
    # The geometry is on the window's "Frames:" line, which sits ~25 lines
    # below the "Application Not Responding" header -- past mAttrs, mToken and
    # the animator block. A short -A window misses it, so scan far enough:
    #
    #     Window #5 Window{d38eda4 u0 Application Not Responding: ...}:
    #         ...
    #         Frames: parent=[0,37][1916,989] display=[0,37][1916,989]
    #             frame=[527,380][1389,645] last=[527,380][1389,645] ...
    #
    # We parse it rather than hardcoding, because the dialog is centred and its
    # width/height depend on the message text.
    _info="$(_lxc 'dumpsys window windows 2>/dev/null' \
             | grep -A30 'Application Not Responding' \
             | grep -m1 'Frames:' \
             | sed 's/.*[^a-z]frame=\[\([0-9-]*\),\([0-9-]*\)\]\[\([0-9-]*\),\([0-9-]*\)\].*/\1 \2 \3 \4/')"

    if [ -n "$_info" ]; then
        set -- $_info
        _x1="$1"; _y1="$2"; _x2="$3"; _y2="$4"
        # Guard against a malformed parse producing nonsense coordinates.
        case "$_x1$_y1$_x2$_y2" in
            *[!0-9-]*) sleep "$_INTERVAL"; continue ;;
        esac
        if [ "$_x2" -gt "$_x1" ] && [ "$_y2" -gt "$_y1" ]; then
            _w=$(( _x2 - _x1 )); _h=$(( _y2 - _y1 ))
            _tx=$(( _x1 + _w * _WAIT_FRAC_X / 100 ))
            _ty=$(( _y1 + _h * _WAIT_FRAC_Y / 100 ))
            # Clamp to the REAL display size, not a hardcoded 1916x1053 -- on a
            # smaller panel that constant let a tap through well off-screen.
            _dw="$(_lxc 'wm size 2>/dev/null' | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1/p' | head -1)"
            _dh="$(_lxc 'wm size 2>/dev/null' | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\2/p' | head -1)"
            [ -n "$_dw" ] || _dw=1916
            [ -n "$_dh" ] || _dh=1053
            [ "$_tx" -lt 0 ] && _tx=0
            [ "$_ty" -lt 0 ] && _ty=0
            [ "$_tx" -ge "$_dw" ] && _tx=$(( _dw - 1 ))
            [ "$_ty" -ge "$_dh" ] && _ty=$(( _dh - 1 ))
            _log "ANR dialog [${_x1},${_y1}][${_x2},${_y2}] -> tap Wait (${_tx},${_ty})"
            _lxc "input tap $_tx $_ty"
            sleep 2
            continue
        fi
    fi

    # ------------------------------------------------------------------
    # The system "allow app to read all device logs?" dialog
    # ------------------------------------------------------------------
    # THIS IS A SYMPTOM, NOT A CAUSE, and the tap below is therefore OFF by
    # default. Set WAYDROID_LOGACCESS_AUTOTAP=1 to re-enable it.
    #
    # It was originally added because Honor of Kings appeared to hang behind
    # this dialog during play. The logs say otherwise. Two independent pieces
    # of evidence:
    #
    #  1. Ordering. In the logcat timeline the game dies FIRST and the dialog
    #     is created ~1.4s LATER:
    #         12:43:42.937  E CRASH: signal 11 (SIGSEGV)  >>> com.tencent.tmgp.sgame
    #         12:43:44.134  Forwarding signal 11
    #         12:43:44.356  START android/com.android.internal.app.LogAccessDialogActivity
    #         12:43:46.757  Process 3685 exited due to signal 11
    #
    #  2. The reason it appears. The ANR trace of the crashing process has its
    #     main thread inside the tombstone writer, reading the log buffer:
    #         #00 __dl_recvfrom
    #         #01 __dl_LogdRead
    #         #02 __dl_android_logger_list_read
    #         #03 __dl_dump_log_file          <- reading logs
    #         #04 __dl_engrave_tombstone_proto
    #         #07 __dl_debuggerd_fallback_handler
    #     Reading logs is what triggers Android 13's log-access consent, so the
    #     CRASH causes the DIALOG -- the game's crash reporter (CrashSight)
    #     collects logs to attach to the crash report.
    #
    # Dismissing it cannot save the game: by the time it is on screen the
    # process is already dead. Worse, every tap is an input injection into the
    # input subsystem, and the crash we are chasing is IN that subsystem
    # (see the note at the top of this file), so tapping adds noise to the very
    # thing under investigation.
    # OFF BY DEFAULT -- see the note above. Tapping this dialog treats a
    # symptom and injects input into the subsystem that is already crashing.
    _linfo=""
    if [ "${WAYDROID_LOGACCESS_AUTOTAP:-0}" = "1" ]; then
    _linfo="$(_lxc 'dumpsys window windows 2>/dev/null' \
              | grep -A30 'LogAccessDialogActivity' \
              | grep -m1 'Frames:' \
              | sed 's/.*[^a-z]frame=\[\([0-9-]*\),\([0-9-]*\)\]\[\([0-9-]*\),\([0-9-]*\)\].*/\1 \2 \3 \4/')"
    fi
    if [ -n "$_linfo" ]; then
        set -- $_linfo
        _lx1="$1"; _ly1="$2"; _lx2="$3"; _ly2="$4"
        case "$_lx1$_ly1$_lx2$_ly2" in
            *[!0-9-]*) sleep "$_INTERVAL"; continue ;;
        esac
        if [ "$_lx2" -gt "$_lx1" ] && [ "$_ly2" -gt "$_ly1" ]; then
            _lw=$(( _lx2 - _lx1 )); _lh=$(( _ly2 - _ly1 ))
            _ltx=$(( _lx1 + _lw / 2 ))
            _lty=$(( _ly1 + _lh * _LOGACCESS_ROW_FRAC / 100 ))
            _log "log-access dialog [${_lx1},${_ly1}][${_lx2},${_ly2}] -> tap Allow (${_ltx},${_lty})"
            _lxc "input tap $_ltx $_lty"
            sleep 2
            continue
        fi
    fi

    sleep "$_INTERVAL"
done
