#!/usr/bin/env python3
"""Stage one producer-neutral evidence bundle in no-mistakes local state.

Usage:
  fm-evidence-import-stage.py stage --contract OFFER.json --bundle DIR \
      --manifest RELATIVE_PATH --worktree DIR
  fm-evidence-import-stage.py recover --worktree DIR

The contract schema and normalization are owned by
``fm-evidence-import-contract.py``.  This command copies only its manifest,
report, and artifact files.  Final imports live below
``$NM_HOME/evidence-imports`` (or ``~/.no-mistakes/evidence-imports``), never
below the named project worktree.

Every source component is opened relative to the already-open bundle directory
with symlink following disabled.  The command copies into one unique
``.incomplete-*`` directory, proves each source path remained bound to the same
regular file, verifies every hash from the staged bytes, and publishes the
complete directory with one rename.  A repeated byte-identical import is
idempotent.  Any other import resolving to the same run-and-manifest identity
is refused without replacing or merging the existing directory.

``recover`` removes abandoned incomplete directories while holding the same
per-state-root lock used by ``stage``.  Incomplete names are never import
destinations and therefore cannot become publishable during recovery.
One source file may contain at most 67108864 bytes and one incomplete import
may contain at most 536870912 source bytes, bounding interrupted recovery state.
"""

import argparse
import ctypes
import errno
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import sys
import tempfile


SCRIPT_DIR = Path(__file__).resolve().parent
CONTRACT_SCRIPT = SCRIPT_DIR / "fm-evidence-import-contract.py"
INCOMPLETE_PREFIX = ".incomplete-"
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_IMPORT_BYTES = 512 * 1024 * 1024
ACL_TYPE_EXTENDED = 0x00000100
ACL_FIRST_ENTRY = 0
ACL_NEXT_ENTRY = -1
ACL_EXTENDED_ALLOW = 1
LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.openat.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_int)
LIBC.openat.restype = ctypes.c_int
LIBC.mkdirat.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
LIBC.mkdirat.restype = ctypes.c_int
LIBC.readlinkat.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t)
LIBC.readlinkat.restype = ctypes.c_ssize_t
if sys.platform == "darwin":
    LIBC.acl_get_fd_np.argtypes = (ctypes.c_int, ctypes.c_int)
    LIBC.acl_get_fd_np.restype = ctypes.c_void_p
    LIBC.acl_get_entry.argtypes = (
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_void_p),
    )
    LIBC.acl_get_entry.restype = ctypes.c_int
    LIBC.acl_get_tag_type.argtypes = (ctypes.c_void_p, ctypes.POINTER(ctypes.c_int))
    LIBC.acl_get_tag_type.restype = ctypes.c_int
    LIBC.acl_free.argtypes = (ctypes.c_void_p,)
    LIBC.acl_free.restype = ctypes.c_int


class Refusal(ValueError):
    """A deterministic, caller-correctable refusal."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def emit_line(stream, value):
    stream.buffer.write((value + "\n").encode("utf-8", errors="backslashreplace"))


def emit_json(stream, value):
    emit_line(stream, json.dumps(value, ensure_ascii=True, separators=(",", ":")))


def refuse(code, message):
    raise Refusal(code, message)


def load_contract_owner():
    spec = importlib.util.spec_from_file_location("fm_evidence_import_contract", CONTRACT_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError("contract validator is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def normalized_contract(path):
    owner = load_contract_owner()
    try:
        if not os.path.isfile(path):
            raise RuntimeError("contract input is not a regular file")
        raw = owner.read_input(path)
        contract = owner.decode_contract(raw)
    except owner.Refusal as error:
        raise Refusal(error.code, error.message) from error
    except owner.DuplicateKeyError as error:
        raise Refusal("duplicate-key", "input contains a duplicate object key") from error
    except (UnicodeDecodeError, ValueError, RecursionError, MemoryError, OverflowError) as error:
        raise Refusal("invalid-json", "input is not valid JSON") from error
    return contract, (owner.json_value(contract) + "\n").encode("utf-8")


def contained_by(path, directory):
    try:
        return os.path.commonpath((path, directory)) == directory
    except ValueError:
        return False


def group_or_world_writable(file_stat):
    return bool(file_stat.st_mode & (stat.S_IWGRP | stat.S_IWOTH))


def directory_flags():
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return flags


def file_identity(file_stat):
    return file_stat.st_dev, file_stat.st_ino


def shared_write_and_execute(file_stat):
    mode = file_stat.st_mode
    return bool(
        (mode & stat.S_IWGRP and mode & stat.S_IXGRP)
        or (mode & stat.S_IWOTH and mode & stat.S_IXOTH)
    )


def ancestor_is_replaceable(parent_stat, child_stat=None):
    trusted_owners = (0, os.geteuid())
    if parent_stat.st_uid not in trusted_owners:
        return True
    if not shared_write_and_execute(parent_stat):
        return False
    if not parent_stat.st_mode & stat.S_ISVTX:
        return True
    return child_stat is not None and child_stat.st_uid not in trusted_owners


def descriptor_has_grant_acl(descriptor):
    if sys.platform != "darwin":
        return False
    ctypes.set_errno(0)
    acl = LIBC.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
    if not acl:
        error_number = ctypes.get_errno()
        if error_number in (errno.ENOENT, errno.EOPNOTSUPP):
            return False
        raise OSError(error_number, os.strerror(error_number))
    try:
        entry_id = ACL_FIRST_ENTRY
        while True:
            entry = ctypes.c_void_p()
            ctypes.set_errno(0)
            result = LIBC.acl_get_entry(acl, entry_id, ctypes.byref(entry))
            if result < 0:
                error_number = ctypes.get_errno()
                if error_number == errno.EINVAL:
                    return False
                raise OSError(error_number, os.strerror(error_number))
            tag_type = ctypes.c_int()
            if LIBC.acl_get_tag_type(entry, ctypes.byref(tag_type)) < 0:
                error_number = ctypes.get_errno()
                raise OSError(error_number, os.strerror(error_number))
            if tag_type.value == ACL_EXTENDED_ALLOW:
                return True
            entry_id = ACL_NEXT_ENTRY
    finally:
        LIBC.acl_free(acl)


def refuse_grant_acl(descriptor):
    try:
        has_grant = descriptor_has_grant_acl(descriptor)
    except OSError as error:
        raise Refusal(
            "unsafe-state-root",
            "NM_HOME extended ACLs could not be inspected safely",
        ) from error
    if has_grant:
        refuse(
            "unsafe-state-root",
            "NM_HOME state directories must not grant access through extended ACLs",
        )


def directory_contains(ancestor_fd, descendant_fd):
    ancestor = file_identity(os.fstat(ancestor_fd))
    current = os.dup(descendant_fd)
    seen = set()
    try:
        while True:
            current_identity = file_identity(os.fstat(current))
            if current_identity == ancestor:
                return True
            if current_identity in seen:
                return False
            seen.add(current_identity)
            parent = open_at(current, "..", directory_flags())
            parent_identity = file_identity(os.fstat(parent))
            if parent_identity == current_identity:
                os.close(parent)
                return False
            os.close(current)
            current = parent
    finally:
        os.close(current)


def open_worktree(worktree):
    worktree_path = os.path.realpath(os.path.abspath(worktree))
    try:
        descriptor = os.open(worktree_path, directory_flags())
    except OSError as error:
        raise Refusal("invalid-worktree", "worktree must name an existing directory") from error
    if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        refuse("invalid-worktree", "worktree must name an existing directory")
    return worktree_path, descriptor


def open_state_root(path, worktree_fd):
    current = os.open(os.sep, directory_flags())
    components = path.split(os.sep)[1:]
    followed = 0
    try:
        while components:
            component = components.pop(0)
            if component in ("", "."):
                continue
            refuse_grant_acl(current)
            if component == "..":
                next_fd = open_at(current, "..", directory_flags())
                os.close(current)
                current = next_fd
                continue
            parent_stat = os.fstat(current)
            if ancestor_is_replaceable(parent_stat):
                refuse(
                    "unsafe-state-root",
                    "NM_HOME ancestors must not permit replacement by another local principal",
                )
            try:
                next_fd = open_at(current, component, directory_flags())
            except FileNotFoundError:
                if file_identity(os.fstat(current)) == file_identity(os.fstat(worktree_fd)):
                    refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")
                try:
                    mkdir_at(current, component, 0o700)
                except FileExistsError:
                    components.insert(0, component)
                    continue
                next_fd = open_at(current, component, directory_flags())
            except OSError as error:
                if error.errno not in (errno.ELOOP, errno.ENOTDIR):
                    raise
                if shared_write_and_execute(parent_stat):
                    refuse(
                        "unsafe-state-root",
                        "NM_HOME ancestors must not permit replacement by another local principal",
                    )
                try:
                    target = readlink_at(current, component)
                except OSError:
                    raise error
                followed += 1
                if followed > 40:
                    refuse("unsafe-state-root", "NM_HOME contains too many symbolic links")
                target_components = target.split(os.sep)
                if os.path.isabs(target):
                    os.close(current)
                    current = os.open(os.sep, directory_flags())
                    target_components = target_components[1:]
                components = target_components + components
                continue
            next_stat = os.fstat(next_fd)
            if ancestor_is_replaceable(parent_stat, next_stat):
                os.close(next_fd)
                refuse(
                    "unsafe-state-root",
                    "NM_HOME ancestors must not permit replacement by another local principal",
                )
            if file_identity(next_stat) == file_identity(os.fstat(worktree_fd)):
                os.close(next_fd)
                refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")
            os.close(current)
            current = next_fd
        refuse_grant_acl(current)
        if file_identity(os.fstat(current)) == file_identity(os.fstat(worktree_fd)):
            refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")
        return current
    except Refusal:
        os.close(current)
        raise
    except OSError as error:
        os.close(current)
        raise RuntimeError("could not prepare no-mistakes state") from error


def resolve_state_root(worktree):
    worktree_path, worktree_fd = open_worktree(worktree)

    configured = os.environ.get("NM_HOME", os.path.expanduser("~/.no-mistakes"))
    if not os.path.isabs(configured):
        os.close(worktree_fd)
        refuse("unsafe-state-root", "NM_HOME must resolve from an absolute path")
    state_root = os.path.realpath(configured)
    imports = os.path.join(state_root, "evidence-imports")
    imports_namespace = os.path.realpath(imports)
    if contained_by(state_root, worktree_path):
        os.close(worktree_fd)
        refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")
    if contained_by(imports_namespace, worktree_path) or contained_by(
        worktree_path, imports_namespace
    ):
        os.close(worktree_fd)
        refuse(
            "unsafe-state-root",
            "evidence import state must not overlap the project worktree",
        )

    state_root_fd = None
    imports_fd = None
    try:
        state_root_fd = open_state_root(configured, worktree_fd)
        state_root = os.path.realpath(configured)
        imports = os.path.join(state_root, "evidence-imports")
        imports_namespace = os.path.realpath(imports)
        if contained_by(state_root, worktree_path):
            refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")
        if contained_by(imports_namespace, worktree_path) or contained_by(
            worktree_path, imports_namespace
        ):
            refuse(
                "unsafe-state-root",
                "evidence import state must not overlap the project worktree",
            )
        root_stat = os.fstat(state_root_fd)
        if (
            not stat.S_ISDIR(root_stat.st_mode)
            or root_stat.st_uid != os.geteuid()
            or group_or_world_writable(root_stat)
        ):
            refuse(
                "unsafe-state-root",
                "no-mistakes state must be an owned directory without group or world write access",
            )
        if directory_contains(worktree_fd, state_root_fd):
            refuse("unsafe-state-root", "no-mistakes state must be outside the project worktree")

        try:
            imports_fd = open_at(state_root_fd, "evidence-imports", directory_flags())
        except FileNotFoundError:
            mkdir_at(state_root_fd, "evidence-imports", 0o700)
            imports_fd = open_at(state_root_fd, "evidence-imports", directory_flags())
        refuse_grant_acl(imports_fd)
        imports_stat = os.fstat(imports_fd)
        if (
            not stat.S_ISDIR(imports_stat.st_mode)
            or imports_stat.st_uid != os.geteuid()
            or group_or_world_writable(imports_stat)
        ):
            refuse(
                "unsafe-state-root",
                "evidence import state must be an owned directory without group or world write access",
            )
        if directory_contains(imports_fd, worktree_fd) or directory_contains(
            worktree_fd, imports_fd
        ):
            refuse(
                "unsafe-state-root",
                "evidence import state must not overlap the project worktree",
            )
        return state_root, imports, imports_fd
    except Refusal:
        if imports_fd is not None:
            os.close(imports_fd)
        raise
    except OSError as error:
        if imports_fd is not None:
            os.close(imports_fd)
        raise RuntimeError("could not prepare evidence import state") from error
    finally:
        if state_root_fd is not None:
            os.close(state_root_fd)
        os.close(worktree_fd)


def acquire_lock(imports_fd):
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = open_at(imports_fd, ".lock", flags, 0o600)
        lock_stat = os.fstat(descriptor)
        if (
            not stat.S_ISREG(lock_stat.st_mode)
            or lock_stat.st_uid != os.geteuid()
            or group_or_world_writable(lock_stat)
        ):
            os.close(descriptor)
            refuse(
                "unsafe-state-root",
                "evidence import lock must be an owned regular file without group or world write access",
            )
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return descriptor
    except Refusal:
        raise
    except OSError as error:
        raise RuntimeError("could not lock evidence import state") from error


def remove_incomplete(imports):
    removed = 0
    try:
        names = os.listdir(imports)
    except OSError as error:
        raise RuntimeError("could not inspect incomplete imports") from error
    for name in names:
        if not name.startswith(INCOMPLETE_PREFIX):
            continue
        path = os.path.join(imports, name)
        try:
            entry_stat = os.lstat(path)
            if stat.S_ISDIR(entry_stat.st_mode):
                remove_tree(path)
            else:
                os.unlink(path)
            removed += 1
        except FileNotFoundError:
            continue
        except OSError as error:
            raise RuntimeError("could not remove an incomplete import") from error
    return removed


def remove_tree(path):
    for directory, directories, _files in os.walk(path, topdown=True, followlinks=False):
        os.chmod(directory, 0o700, follow_symlinks=False)
        for name in directories:
            member = os.path.join(directory, name)
            if stat.S_ISDIR(os.lstat(member).st_mode):
                os.chmod(member, 0o700, follow_symlinks=False)
    for directory, directories, files in os.walk(path, topdown=False, followlinks=False):
        for name in files:
            member = os.path.join(directory, name)
            try:
                os.chmod(member, 0o600, follow_symlinks=False)
            except OSError:
                pass
            os.unlink(member)
        for name in directories:
            member = os.path.join(directory, name)
            member_stat = os.lstat(member)
            if stat.S_ISDIR(member_stat.st_mode):
                os.rmdir(member)
            else:
                os.unlink(member)
    os.rmdir(path)


def open_bundle(bundle):
    path = os.path.abspath(bundle)
    try:
        bundle_stat = os.lstat(path)
    except OSError as error:
        raise Refusal("unsafe-bundle", "offered bundle is unavailable") from error
    if not stat.S_ISDIR(bundle_stat.st_mode):
        refuse("unsafe-bundle", "offered bundle must be a directory, not a symlink")
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        return os.open(path, flags)
    except OSError as error:
        raise Refusal("unsafe-bundle", "could not safely open offered bundle") from error


def source_fingerprint(file_stat):
    return (
        file_stat.st_dev,
        file_stat.st_ino,
        file_stat.st_size,
        file_stat.st_mtime_ns,
        file_stat.st_ctime_ns,
    )


def open_at(directory_fd, name, flags, mode=0):
    descriptor = LIBC.openat(directory_fd, os.fsencode(name), flags, mode)
    if descriptor < 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), name)
    return descriptor


def mkdir_at(directory_fd, name, mode):
    result = LIBC.mkdirat(directory_fd, os.fsencode(name), mode)
    if result < 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), name)


def readlink_at(directory_fd, name):
    size = 256
    while size <= 65536:
        buffer = ctypes.create_string_buffer(size)
        result = LIBC.readlinkat(directory_fd, os.fsencode(name), buffer, size)
        if result < 0:
            error_number = ctypes.get_errno()
            raise OSError(error_number, os.strerror(error_number), name)
        if result < size:
            return os.fsdecode(buffer.raw[:result])
        size *= 2
    raise OSError(errno.ENAMETOOLONG, os.strerror(errno.ENAMETOOLONG), name)


def open_regular_at(bundle_fd, relative_path):
    current = os.dup(bundle_fd)
    flags = os.O_RDONLY | os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        components = relative_path.split("/")
        for component in components[:-1]:
            directory_flags = flags
            if hasattr(os, "O_DIRECTORY"):
                directory_flags |= os.O_DIRECTORY
            next_fd = open_at(current, component, directory_flags)
            next_stat = os.fstat(next_fd)
            if not stat.S_ISDIR(next_stat.st_mode):
                os.close(next_fd)
                refuse("unsafe-source", "bundle path component is not a directory")
            os.close(current)
            current = next_fd
        file_fd = open_at(current, components[-1], flags)
        file_stat = os.fstat(file_fd)
        if not stat.S_ISREG(file_stat.st_mode):
            os.close(file_fd)
            refuse("unsafe-source", "bundle member is not a regular file")
        return file_fd, source_fingerprint(file_stat)
    except Refusal:
        raise
    except OSError as error:
        if error.errno in (errno.ELOOP, errno.ENOTDIR, errno.ENOENT):
            raise Refusal(
                "unsafe-source", "bundle member could not be opened without path substitution"
            ) from error
        raise RuntimeError("could not read offered bundle") from error
    finally:
        os.close(current)


def test_stop(point):
    """Deterministic process-stop seam used only by filesystem race tests."""
    if os.environ.get("FM_EVIDENCE_IMPORT_TEST_STOP") == point:
        os.kill(os.getpid(), signal.SIGSTOP)


def write_from_source(bundle_fd, relative_path, destination, max_bytes):
    source_fd, before = open_regular_at(bundle_fd, relative_path)
    os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)
    output_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        output_flags |= os.O_NOFOLLOW
    output_fd = os.open(destination, output_flags, 0o600)
    digest = hashlib.sha256()
    copied = 0
    try:
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            copied += len(chunk)
            if copied > max_bytes:
                refuse("source-too-large", "bundle member exceeds the bounded import size")
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(output_fd, view)
                view = view[written:]
        os.fsync(output_fd)
        test_stop("after-copy:" + relative_path)
        after = source_fingerprint(os.fstat(source_fd))
    finally:
        os.close(output_fd)
        os.close(source_fd)

    replacement_fd, rebound = open_regular_at(bundle_fd, relative_path)
    os.close(replacement_fd)
    if before != after or before != rebound:
        refuse("source-changed", "bundle member changed during import: {}".format(relative_path))
    return digest.hexdigest(), copied


def sha256_file(path):
    digest = hashlib.sha256()
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        file_stat = os.fstat(descriptor)
        if not stat.S_ISREG(file_stat.st_mode):
            refuse("staged-copy-invalid", "staged evidence contains a non-regular file")
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def write_bytes(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        view = memoryview(content)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def staged_files(contract, manifest_path):
    entries = [(manifest_path, "manifest.json", contract["manifest_sha256"])]
    entries.append(
        (
            contract["report"]["path"],
            "bundle/" + contract["report"]["path"],
            contract["report"]["sha256"],
        )
    )
    entries.extend(
        (artifact["path"], "bundle/" + artifact["path"], artifact["sha256"])
        for artifact in contract["artifacts"]
    )
    return entries


def verify_staged(temp_path, entries):
    for _source, destination, expected in entries:
        actual = sha256_file(os.path.join(temp_path, destination))
        if actual != expected:
            refuse("hash-mismatch", "staged file hash does not match contract: {}".format(destination))


def tree_identity(path):
    identity = []
    for directory, directories, files in os.walk(path, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        relative_directory = os.path.relpath(directory, path)
        for name in list(directories):
            member = os.path.join(directory, name)
            member_stat = os.lstat(member)
            if not stat.S_ISDIR(member_stat.st_mode):
                refuse("destination-collision", "final import contains an unsafe path")
            relative = os.path.normpath(os.path.join(relative_directory, name))
            identity.append(("directory", relative))
        for name in files:
            member = os.path.join(directory, name)
            member_stat = os.lstat(member)
            if not stat.S_ISREG(member_stat.st_mode):
                refuse("destination-collision", "final import contains an unsafe path")
            relative = os.path.normpath(os.path.join(relative_directory, name))
            identity.append(("file", relative, member_stat.st_size, sha256_file(member)))
    return identity


def protect_tree(path):
    directories = []
    for directory, child_directories, files in os.walk(path, topdown=True):
        directories.append(directory)
        for name in files:
            os.chmod(os.path.join(directory, name), 0o400, follow_symlinks=False)
        child_directories.sort()
    for directory in reversed(directories):
        os.chmod(directory, 0o700, follow_symlinks=False)


def import_identity(contract):
    material = (contract["run_binding"] + "\0" + contract["manifest_sha256"]).encode("utf-8")
    return hashlib.sha256(material).hexdigest()


def rename_without_replace(directory_fd, source, destination):
    if sys.platform == "darwin" and hasattr(LIBC, "renameatx_np"):
        function = LIBC.renameatx_np
        function.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        function.restype = ctypes.c_int
        result = function(
            directory_fd,
            os.fsencode(source),
            directory_fd,
            os.fsencode(destination),
            0x00000004,
        )
    elif sys.platform.startswith("linux") and hasattr(LIBC, "renameat2"):
        function = LIBC.renameat2
        function.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        function.restype = ctypes.c_int
        result = function(
            directory_fd,
            os.fsencode(source),
            directory_fd,
            os.fsencode(destination),
            1,
        )
    else:
        refuse("unsupported-platform", "atomic no-replace finalization is unavailable")
    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number in (errno.EEXIST, errno.ENOTEMPTY):
        raise FileExistsError(error_number, os.strerror(error_number), destination)
    raise OSError(error_number, os.strerror(error_number), destination)


def stage(arguments):
    contract, normalized = normalized_contract(arguments.contract)
    owner = load_contract_owner()
    try:
        manifest_path = owner.relative_path(arguments.manifest, "manifest path")
    except owner.Refusal as error:
        raise Refusal(error.code, error.message) from error
    declared_paths = [contract["report"]["path"]] + [
        artifact["path"] for artifact in contract["artifacts"]
    ]
    if owner.paths_overlap([manifest_path] + declared_paths):
        refuse("duplicate-path", "manifest, report, and artifact paths must not overlap")

    bundle_fd = open_bundle(arguments.bundle)
    state_root, imports, imports_fd = resolve_state_root(arguments.worktree)
    test_stop("after-state-open")
    lock_fd = acquire_lock(imports_fd)
    cwd_fd = os.open(".", directory_flags())
    temp_path = None
    try:
        os.fchdir(imports_fd)
        remove_incomplete(".")
        temp_path = tempfile.mkdtemp(prefix=INCOMPLETE_PREFIX, dir=".")
        write_bytes(os.path.join(temp_path, "contract.json"), normalized)
        entries = staged_files(contract, manifest_path)
        total_bytes = 0
        for source, destination, expected in entries:
            remaining = MAX_IMPORT_BYTES - total_bytes
            actual, copied = write_from_source(
                bundle_fd,
                source,
                os.path.join(temp_path, destination),
                min(MAX_FILE_BYTES, remaining),
            )
            total_bytes += copied
            if actual != expected:
                refuse("hash-mismatch", "bundle member hash does not match contract: {}".format(source))
        verify_staged(temp_path, entries)
        protect_tree(temp_path)
        test_stop("before-finalize")

        identity = import_identity(contract)
        final_path = os.path.join(imports, identity)
        if os.path.lexists(identity):
            try:
                final_stat = os.lstat(identity)
                identical = stat.S_ISDIR(final_stat.st_mode) and tree_identity(
                    identity
                ) == tree_identity(temp_path)
            except (OSError, Refusal):
                identical = False
            if not identical:
                refuse(
                    "destination-collision",
                    "a non-identical finalized import already exists for this run and manifest",
                )
            remove_tree(temp_path)
            temp_path = None
            status = "already-finalized"
        else:
            try:
                rename_without_replace(imports_fd, temp_path, identity)
                temp_path = None
                status = "finalized"
            except FileExistsError:
                refuse(
                    "destination-collision",
                    "a finalized import appeared before atomic finalization",
                )
        try:
            emit_json(
                sys.stdout,
                {
                    "status": status,
                    "import_id": identity,
                    "path": final_path,
                    "state_root": state_root,
                },
            )
        except OSError:
            pass
        return 0
    finally:
        if temp_path is not None:
            try:
                remove_tree(temp_path)
            except OSError:
                pass
        os.fchdir(cwd_fd)
        os.close(cwd_fd)
        os.close(lock_fd)
        os.close(imports_fd)
        os.close(bundle_fd)


def recover(arguments):
    state_root, _imports, imports_fd = resolve_state_root(arguments.worktree)
    test_stop("after-state-open")
    lock_fd = acquire_lock(imports_fd)
    cwd_fd = os.open(".", directory_flags())
    try:
        os.fchdir(imports_fd)
        removed = remove_incomplete(".")
        emit_json(sys.stdout, {"status": "recovered", "removed": removed, "state_root": state_root})
        return 0
    finally:
        os.fchdir(cwd_fd)
        os.close(cwd_fd)
        os.close(lock_fd)
        os.close(imports_fd)


def parse_arguments(arguments):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    stage_parser = commands.add_parser("stage", help="stage and atomically finalize one bundle")
    stage_parser.add_argument("--contract", required=True)
    stage_parser.add_argument("--bundle", required=True)
    stage_parser.add_argument("--manifest", required=True)
    stage_parser.add_argument("--worktree", required=True)
    recover_parser = commands.add_parser("recover", help="remove abandoned incomplete imports")
    recover_parser.add_argument("--worktree", required=True)
    return parser.parse_args(arguments)


def main(arguments):
    try:
        parsed = parse_arguments(arguments)
        if parsed.command == "stage":
            return stage(parsed)
        return recover(parsed)
    except Refusal as error:
        emit_json(sys.stderr, {"code": error.code, "message": error.message})
        return 2
    except RuntimeError as error:
        emit_line(sys.stderr, "fm-evidence-import-stage: {}".format(error))
        return 1
    except OSError:
        emit_line(sys.stderr, "fm-evidence-import-stage: import failed unexpectedly")
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception:
        emit_line(sys.stderr, "fm-evidence-import-stage: import failed unexpectedly")
        sys.exit(1)
