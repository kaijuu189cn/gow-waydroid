# Copyright 2021 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later
import os
import tools.helpers.run
from tools.helpers.version import versiontuple, kernel_version


def ismount(folder):
    """
    Ismount() implementation, that works for mount --bind.
    Workaround for: https://bugs.python.org/issue29707
    """
    folder = os.path.realpath(os.path.realpath(folder))
    with open("/proc/mounts", "r") as handle:
        for line in handle:
            words = line.split()
            if len(words) >= 2 and words[1] == folder:
                return True
            if words[0] == folder:
                return True
    return False


def bind(args, source, destination, create_folders=True, umount=False):
    """
    Mount --bind a folder and create necessary directory structure.
    :param umount: when destination is already a mount point, umount it first.
    """
    # Check/umount destination
    if ismount(destination):
        if umount:
            umount_all(args, destination)
        else:
            return

    # Check/create folders
    for path in [source, destination]:
        if os.path.exists(path):
            continue
        if create_folders:
            tools.helpers.run.user(args, ["mkdir", "-p", path])
        else:
            raise RuntimeError("Mount failed, folder does not exist: " +
                               path)

    # Actually mount the folder
    tools.helpers.run.user(args, ["mount", "-o", "bind", source, destination])

    # Verify, that it has worked
    if not ismount(destination):
        raise RuntimeError("Mount failed: " + source + " -> " + destination)


def bind_file(args, source, destination, create_folders=False):
    """
    Mount a file with the --bind option, and create the destination file,
    if necessary.
    """
    # Skip existing mountpoint
    if ismount(destination):
        return

    # Create empty file
    if not os.path.exists(destination):
        if create_folders:
            dir = os.path.dirname(destination)
            if not os.path.isdir(dir):
                tools.helpers.run.user(args, ["mkdir", "-p", dir])

        tools.helpers.run.user(args, ["touch", destination])

    # Mount
    tools.helpers.run.user(args, ["mount", "-o", "bind", source,
                                destination])


def umount_all_list(prefix, source="/proc/mounts"):
    """
    Parses `/proc/mounts` for all folders beginning with a prefix.
    :source: can be changed for testcases
    :returns: a list of folders, that need to be umounted
    """
    ret = []
    prefix = os.path.realpath(prefix)
    with open(source, "r") as handle:
        for line in handle:
            words = line.split()
            if len(words) < 2:
                raise RuntimeError("Failed to parse line in " + source + ": " +
                                   line)
            mountpoint = words[1]
            if mountpoint.startswith(prefix):
                # Remove "\040(deleted)" suffix (#545)
                deleted_str = r"\040(deleted)"
                if mountpoint.endswith(deleted_str):
                    mountpoint = mountpoint[:-len(deleted_str)]
                ret.append(mountpoint)
    ret.sort(reverse=True)
    return ret


def umount_all(args, folder):
    """
    Umount all folders, that are mounted inside a given folder.
    """
    all_list = umount_all_list(folder)
    for mountpoint in all_list:
        tools.helpers.run.user(args, ["umount", mountpoint])
    for mountpoint in all_list:
        if ismount(mountpoint):
            raise RuntimeError("Failed to umount: " + mountpoint)

def mount(args, source, destination, create_folders=True, umount=False,
          readonly=True, mount_type=None, options=None, force=True):
    """
    Mount and create necessary directory structure.
    :param umount: when destination is already a mount point, umount it first.
    :param force: attempt mounting even if the mount point already exists.
    """
    # Check/umount destination
    if ismount(destination):
        if umount:
            umount_all(args, destination)
        else:
            if not force:
                return

    # Check/create folders
    if not os.path.exists(destination):
        if create_folders:
            tools.helpers.run.user(args, ["mkdir", "-p", destination])
        else:
            raise RuntimeError("Mount failed, folder does not exist: " +
                            destination)

    extra_args = []
    opt_args = []
    if mount_type:
        extra_args.extend(["-t", mount_type])
    if readonly:
        opt_args.append("ro")
    if options:
        opt_args.extend(options)
    if opt_args:
        extra_args.extend(["-o", ",".join(opt_args)])

    # Actually mount the folder
    tools.helpers.run.user(args, ["mount", *extra_args, source, destination])

    # Verify, that it has worked
    if not ismount(destination):
        raise RuntimeError("Mount failed: " + source + " -> " + destination)

def mount_overlay(args, lower_dirs, destination, upper_dir=None, work_dir=None,
                  create_folders=True, readonly=True):
    """
    Mount an overlay.
    """
    dirs = [*lower_dirs]
    options = ["lowerdir=" + (":".join(lower_dirs))]

    if upper_dir:
        dirs.append(upper_dir)
        dirs.append(work_dir)
        options.append("upperdir=" + upper_dir)
        options.append("workdir=" + work_dir)

    if kernel_version() >= versiontuple("4.17"):
        options.append("xino=off")

    # Allow the overlay to survive a stale holder of the same upperdir.
    #
    # Overlayfs makes an upperdir exclusive to a single mount and refuses a
    # second one that shares it:
    #
    #     overlayfs: upperdir is in-use as upperdir/workdir of another mount,
    #               mount with '-o index=off' to override exclusive upperdir
    #               protection.
    #
    # That is fatal inside a container. A Waydroid session that gets killed --
    # or a streaming client that disconnects mid-boot -- can leave its overlay
    # mounted in a namespace we can no longer reach or unmount. The next
    # session's overlay mount then fails, and Waydroid does not retry: it
    # treats the failure as "this kernel cannot do overlays" and PERMANENTLY
    # disables the feature.
    #
    #     Mounting overlays failed. The feature has been disabled.
    #     Save config: /var/lib/waydroid/waydroid.cfg   <- mount_overlays = False
    #
    # Losing the overlay costs the ARM64 translator that lives in
    # /var/lib/waydroid/overlay, which surfaces as
    #
    #     dlopen failed: ".../libtprt.so" is for EM_AARCH64 (183)
    #     instead of EM_X86_64 (62)
    #
    # for every ARM-only library. In Honor of Kings libtprt.so is the
    # anti-cheat module, so the game starts fine and then dies on the way into
    # online mode. `index=off` is exactly what the kernel asks for here, and
    # is how this container's own root overlay is mounted.
    options.append("index=off")

    for dir_path in dirs:
        if not os.path.exists(dir_path):
            if create_folders:
                tools.helpers.run.user(args, ["mkdir", "-p", dir_path])
            else:
                raise RuntimeError("Mount failed, folder does not exist: " +
                                   dir_path)

    mount(args, "overlay", destination, mount_type="overlay", options=options,
          readonly=readonly, create_folders=create_folders, force=True)
