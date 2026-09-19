#!/usr/bin/env python3
"""Set an Android global/secure/system setting through Waydroid's IPlatform.

WHY
---
`waydroid shell -- settings put ...` aborts with a NullPointerException, because
the shell command runs with no calling package and AppOpsService.checkPackage()
therefore NPEs before the write happens:

    java.lang.NullPointerException
      at com.android.server.appop.AppOpsService.checkPackage
      at android.content.ContentProvider.getCallingAttributionSource
      at com.android.providers.settings.SettingsProvider.mutateGlobalSetting

Editing /data/system/users/0/settings_global.xml directly does not stick
either: SettingsProvider caches values in memory and rewrites the whole store
on shutdown, so a hand-made edit is silently reverted the next time Android
stops. That is exactly what happened with policy_control -- the edit survived
`waydroid shell -- stop` but was gone after the following boot.

Waydroid's own platform service exposes settingsPutString/settingsPutInt over
gbinder (lineageos.waydroid.IPlatform). Those calls originate from the Android
app process, so they carry a real calling package and AppOps is satisfied --
and because SettingsProvider itself performs the write, it persists normally.

USAGE
-----
    waydroid-setting.py global policy_control "immersive.full=*"
    waydroid-setting.py --get global policy_control
"""
import argparse
import sys

sys.path.insert(0, "/usr/lib/waydroid")

from tools.interfaces import IPlatform  # noqa: E402

# Namespace ids as used by IPlatform's int32 argument.
NAMESPACES = {
    "system": 0,
    "secure": 1,
    "global": 2,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("namespace", choices=sorted(NAMESPACES))
    ap.add_argument("key")
    ap.add_argument("value", nargs="?")
    ap.add_argument("--get", action="store_true")
    ap.add_argument("--int", dest="as_int", action="store_true",
                    help="write as int instead of string")
    args = ap.parse_args()

    ns = NAMESPACES[args.namespace]

    # IPlatform.get_service() needs a few attributes that normally come from
    # argparse in the real `waydroid` CLI. loadBinderNodes() also reads the
    # config file to find the binder driver names.
    class Args:
        work = "/var/lib/waydroid"
        config = "/var/lib/waydroid/waydroid.cfg"
        images_path = "/var/lib/waydroid/images"
        BINDER_DRIVER = "anbox-binder"
        SERVICE_MANAGER_PROTOCOL = "aidl3"
        BINDER_PROTOCOL = "aidl3"

    svc = IPlatform.get_service(Args())
    if not svc:
        print("ERROR: could not reach the IPlatform service", file=sys.stderr)
        return 1

    if args.get or args.value is None:
        val = svc.settingsGetString(ns, args.key)
        print(f"{args.namespace}/{args.key} = {val!r}")
        return 0

    if args.as_int:
        svc.settingsPutInt(ns, args.key, int(args.value))
    else:
        svc.settingsPutString(ns, args.key, args.value)

    # Read back so success is verified rather than assumed.
    val = svc.settingsGetString(ns, args.key)
    ok = "OK " if val == args.value else "MISMATCH "
    print(f"{ok}{args.namespace}/{args.key} = {val!r}")
    return 0 if val == args.value else 1


if __name__ == "__main__":
    raise SystemExit(main())
