# Win32 compatibility provenance

The POSIX shadow headers, `posix.cpp`, `spawn.cpp`, and HIP `cmath` workaround
were imported from `thomas9120/gufo-adapted` branch `windows-port` at
`ab4d98189a6d8103fce29d2537e4113da3da2420`. Their original compatibility commit
is `edb2f8b0629005f2852d4543a3c24786b56979a5`.

Stage-one additions are `directory.cpp`/`dirent.h`, `mkdirat`, a narrow
no-replace rename operation, and 64-bit device/inode types used by the new
upstream cache. The imported path resolver handles `openat(fd, ".", ...)`, and
failed flushes no longer return success. The later persistence foundations add
`filesystem.cpp`: protected user-only ACL creation/inspection and native
directory-handle operations for open, enumeration, stat, rename, and unlink.
Other inherited path adapters still use names. Private `0600`/`0700` chmod is
implemented; other modes are unsupported. UID zero maps to the real token user
SID, not every Windows owner. The component checkpoint store uses private local
NTFS roots and a rebuildable-cache contract; the older continuation store remains
disabled. Private identity caching is enabled.

The companion socket helper and root vcpkg manifest come from the same pinned
fork revision. The new CMake module and build/check scripts adapt those ideas
to the current official engine; no fork model changes, GUI, release workflow,
or tuning options were imported. See [Windows status](../../docs/WINDOWS.md)
for reproducible commands and validated scope.

The stage-two transport increment adapts the socket helper for native handle
width and real listener nonblocking mode, uses it throughout HTTP/WebSocket
I/O, and cancels pending I/O during local shutdown. The original POSIX file
shim remains separate; its no-op `fcntl(F_SETFL)` does not configure sockets.
Content tracing now uses private ACLs and refuses unsafe existing files.

Directory handles request write access for an actual `FlushFileBuffers` call.
This works for owned NTFS directories, but access to volume/root ancestors is
not available to this process. Do not infer whole-cache power-loss durability
from those isolated successes. See the unresolved contract in the Windows
status document. The component cache therefore flushes its managed directories
without flushing profile/volume ancestors, and does not promise checkpoint
survival across power loss. The CPU shim's reviewed security dependency is Advapi32;
HIP/DXGI remain outside it. Native I/O fault controls compile only for tests.
