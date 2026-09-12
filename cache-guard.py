#!/usr/bin/env python3
"""Guarded filesystem operations for VibeShot's cache directory.

`captured()`/`gifReady()`/`scrollCaptured()` in VibeShot.qml are reachable
from a *public* local IPC surface (`omarchy-shell shell call aayork.vibeshot
...`) -- any process running as this user, not just our own scripts, can
invoke them with an arbitrary path argument. A lexical "does this string
start with the cache dir?" check is not enough: a symlink planted anywhere
between the cache root and the named file (or the cache root itself) makes a
lexically-valid path resolve somewhere else entirely, and the plugin would
then rm/cp/load whatever that turns out to be.

Every subcommand here re-derives the cache directory from scratch and walks
down to it one path component at a time with os.O_NOFOLLOW, refusing to
follow any symlink and requiring every component to be a directory owned by
the user actually running this process. The target file itself is opened
the same way (O_NOFOLLOW, must be a regular file we own) before anything is
done with it. Verification and use happen in the same short-lived process
on descriptors we hold open, not on a pathname string re-resolved later --
that's what "verified file descriptor" means in practice for a CLI tool
that can't keep a long-lived handle around between separate invocations.

Subcommands:
  mkdirs                    ensure the cache dir (and its pins/ subdir) exist, 0700, owned by us
  check PATH                exit 0 iff PATH verifies as a real file inside the cache dir
  rm PATH...                verify then unlink each PATH inside the cache dir
  save SRC DEST              verify SRC inside the cache dir, then create DEST exclusively (no overwrite, no symlink-follow) and copy the verified bytes into it
  cat PATH                   verify PATH inside the cache dir, stream its bytes to stdout
"""
import os
import pwd
import re
import stat
import sys

NAME_RE = re.compile(r"^(?!\.\.?$)[A-Za-z0-9._-]+$")
MAX_COPY_BYTES = 256 * 1024 * 1024  # generous ceiling for a screenshot/gif/pin


def fail(msg):
    print(f"cache-guard: {msg}", file=sys.stderr)
    sys.exit(1)


def real_home():
    return pwd.getpwuid(os.getuid()).pw_dir


def open_nofollow_dir(name, dir_fd):
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)


def verify_dir_fd(fd):
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        raise PermissionError("not a directory we own")


def tighten_mode(fd, mode=0o700):
    """fchmod acts on the fd itself, not a re-resolved pathname, so this
    can't be tricked into chmod'ing something other than what we already
    have open. Only ever loosens->tightens; never widens beyond `mode`."""
    st = os.fstat(fd)
    if stat.S_IMODE(st.st_mode) != mode:
        os.fchmod(fd, mode)


def open_or_create_dir(name, dir_fd, mode=0o700):
    """Open `name` under dir_fd with O_NOFOLLOW, creating it if absent.
    Never follows a symlink at `name`, and refuses anything not owned by us."""
    try:
        fd = open_nofollow_dir(name, dir_fd)
    except FileNotFoundError:
        os.mkdir(name, mode, dir_fd=dir_fd)
        fd = open_nofollow_dir(name, dir_fd)
    verify_dir_fd(fd)
    tighten_mode(fd, mode)
    return fd


def open_existing_dir(name, dir_fd):
    fd = open_nofollow_dir(name, dir_fd)
    verify_dir_fd(fd)
    return fd


def cache_dir_string():
    home = real_home()
    xdg = os.environ.get("XDG_CACHE_HOME")
    base = xdg if (xdg and os.path.isabs(xdg)) else os.path.join(home, ".cache")
    return os.path.join(base, "aayork.vibeshot")


def cache_root_fd(create=False):
    """Walk from filesystem root down to the cache dir, opening every
    component with O_NOFOLLOW. Ownership is only enforced from the first
    component we actually own onward -- system ancestors like / or /home
    are root-owned and out of the same-user attacker's reach, so requiring
    *them* to be owned by us would just break normal setups. Once we reach
    a component owned by us, everything below it must be too."""
    parts = [p for p in cache_dir_string().split("/") if p]
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    enforcing = False
    try:
        for i, part in enumerate(parts):
            is_last = i == len(parts) - 1
            try:
                nfd = open_nofollow_dir(part, fd)
            except FileNotFoundError:
                if not (create and (is_last or enforcing)):
                    raise
                os.mkdir(part, 0o700, dir_fd=fd)
                nfd = open_nofollow_dir(part, fd)
            st = os.fstat(nfd)
            if not stat.S_ISDIR(st.st_mode):
                os.close(nfd)
                raise PermissionError(f"{part} is not a directory")
            if st.st_uid == os.getuid():
                enforcing = True
            elif enforcing:
                os.close(nfd)
                raise PermissionError(f"{part} is not owned by the current user")
            # Only the cache dir itself needs to be private -- ~/.cache and
            # any custom XDG_CACHE_HOME above it are shared with every other
            # app and shouldn't have their mode changed.
            if is_last:
                tighten_mode(nfd)
            os.close(fd)
            fd = nfd
        return fd
    except Exception:
        os.close(fd)
        raise


def resolve_leaf(cache_fd, rel_path):
    """Resolve `rel_path` (at most one subdirectory deep, e.g. "pins/x.png")
    relative to the already-verified cache_fd. Every component is opened
    O_NOFOLLOW; the final component must be a regular file owned by us.
    Returns (leaf_fd, leaf_name, parent_fd)."""
    parts = rel_path.split("/")
    if len(parts) > 2 or any(not NAME_RE.match(p) for p in parts):
        raise PermissionError(f"invalid cache-relative path {rel_path!r}")

    parent_fd = cache_fd
    close_parent = False
    if len(parts) == 2:
        parent_fd = open_existing_dir(parts[0], cache_fd)
        close_parent = True

    try:
        leaf_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
    except Exception:
        if close_parent:
            os.close(parent_fd)
        raise

    st = os.fstat(leaf_fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
        os.close(leaf_fd)
        if close_parent:
            os.close(parent_fd)
        raise PermissionError(f"{rel_path} is not a regular file we own")

    return leaf_fd, parts[-1], parent_fd


def to_relative(path):
    prefix = cache_dir_string() + "/"
    if not (isinstance(path, str) and path.startswith(prefix) and len(path) > len(prefix)):
        raise PermissionError(f"{path!r} is not inside the cache directory")
    return path[len(prefix):]


def cmd_mkdirs():
    cache_fd = cache_root_fd(create=True)
    pins_fd = open_or_create_dir("pins", cache_fd)
    os.close(pins_fd)
    os.close(cache_fd)


def cmd_check(path):
    cache_fd = cache_root_fd(create=False)
    leaf_fd, _, parent_fd = resolve_leaf(cache_fd, to_relative(path))
    os.close(leaf_fd)
    if parent_fd != cache_fd:
        os.close(parent_fd)
    os.close(cache_fd)


def cmd_rm(paths):
    cache_fd = cache_root_fd(create=False)
    failures = 0
    for path in paths:
        try:
            rel = to_relative(path)
            leaf_fd, name, parent_fd = resolve_leaf(cache_fd, rel)
            os.close(leaf_fd)
            os.unlink(name, dir_fd=parent_fd)
            if parent_fd != cache_fd:
                os.close(parent_fd)
        except Exception as e:
            print(f"cache-guard: skip {path}: {e}", file=sys.stderr)
            failures += 1
    os.close(cache_fd)
    if failures:
        sys.exit(1)


def _open_verified_src(src):
    cache_fd = cache_root_fd(create=False)
    leaf_fd, _, parent_fd = resolve_leaf(cache_fd, to_relative(src))
    if parent_fd != cache_fd:
        os.close(parent_fd)
    os.close(cache_fd)
    st = os.fstat(leaf_fd)
    if st.st_size > MAX_COPY_BYTES:
        os.close(leaf_fd)
        raise ValueError(f"{src} exceeds the {MAX_COPY_BYTES}-byte copy limit")
    return leaf_fd


def cmd_save(src, dest):
    leaf_fd = _open_verified_src(src)
    try:
        # O_EXCL|O_NOFOLLOW: never overwrite an existing file (attacker- or
        # otherwise-planted) and never write through a pre-positioned symlink.
        dest_fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(leaf_fd, "rb", closefd=True) as src_f, \
                 os.fdopen(dest_fd, "wb", closefd=True) as dest_f:
                leaf_fd = None
                dest_fd = None
                while True:
                    chunk = src_f.read(1024 * 1024)
                    if not chunk:
                        break
                    dest_f.write(chunk)
        finally:
            if dest_fd is not None:
                os.close(dest_fd)
    finally:
        if leaf_fd is not None:
            os.close(leaf_fd)


def cmd_cat(src):
    leaf_fd = _open_verified_src(src)
    with os.fdopen(leaf_fd, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)


def main():
    if len(sys.argv) < 2:
        fail("missing subcommand")
    cmd, args = sys.argv[1], [a for a in sys.argv[2:] if a != "--"]
    try:
        if cmd == "mkdirs":
            cmd_mkdirs()
        elif cmd == "check":
            cmd_check(args[0])
        elif cmd == "rm":
            cmd_rm(args)
        elif cmd == "save":
            cmd_save(args[0], args[1])
        elif cmd == "cat":
            cmd_cat(args[0])
        else:
            fail(f"unknown subcommand {cmd!r}")
    except SystemExit:
        raise
    except Exception as e:
        fail(str(e))


if __name__ == "__main__":
    main()
