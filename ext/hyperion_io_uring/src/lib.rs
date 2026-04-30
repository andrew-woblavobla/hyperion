//! Hyperion 2.3-A — io_uring accept primitives.
//!
//! Surface (extern "C", consumed by Ruby via Fiddle):
//!
//!   * `hyperion_io_uring_abi_version()` — bumped on any breaking
//!     ABI change. Ruby refuses to load a mismatched binary.
//!   * `hyperion_io_uring_probe()` — runtime feature probe. Returns
//!     0 on success, negative errno-ish on failure. Ruby calls this
//!     once at boot to decide whether the kernel actually exposes
//!     io_uring (handles -ENOSYS sandboxes).
//!   * `hyperion_io_uring_ring_new(queue_depth)` — allocate a per-
//!     fiber ring. Returns an opaque pointer (NULL on failure).
//!   * `hyperion_io_uring_ring_free(ptr)` — close + free the ring.
//!     MUST be called from the same fiber that opened it. Workers
//!     never share rings across fork — each child opens its own.
//!   * `hyperion_io_uring_accept(ptr, listener_fd, out_errno_ptr)` —
//!     submit one accept SQE, wait for the matching CQE, return the
//!     accepted client fd. Returns:
//!       >= 0 : accepted client fd
//!       -1   : EAGAIN (caller treats as :wouldblock — should not
//!              normally happen with a blocking accept submission,
//!              but defensive against IORING_FEAT_NODROP races)
//!       -2   : ring submission failed; out_errno_ptr written with errno
//!       -3   : CQE wait failed
//!   * `hyperion_io_uring_read(ptr, fd, buf, max, out_errno_ptr)` —
//!     submit one read SQE, wait for the CQE, return bytes read.
//!     Returns the byte count, 0 on EOF, or -1/-2/-3 mirroring the
//!     accept error scheme.
//!
//! Memory model: rings are owned `Box`es; Ruby holds an opaque
//! `void*` and explicitly frees via `ring_free`. The ring's
//! submission queue + completion queue memory is mmap'd by the
//! kernel and reclaimed on free.
//!
//! Fork story: io_uring under fork has sharp edges — the parent's
//! outstanding SQEs leak into the child's CQ, and IORING_SETUP_SQPOLL
//! kernel threads don't survive fork. Hyperion's worker model (master
//! never opens a ring; each worker opens its own per-fiber rings
//! lazily on first use) sidesteps both. We do NOT use SQPOLL —
//! single-issuer per fiber is enough for the accept path.
//!
//! Darwin / non-Linux: the io-uring crate is Linux-only via Cargo
//! `target.'cfg(target_os = "linux")'` gating, so the symbols below
//! compile down to stubs on macOS that always return -ENOSYS-ish
//! sentinels. Ruby's `IOUring.supported?` checks the OS first and
//! never reaches these stubs in practice.

#![allow(clippy::missing_safety_doc)]

use std::os::raw::{c_int, c_uchar, c_uint};

const ABI_VERSION: u32 = 1;

// ---------- ABI version + probe ----------

#[no_mangle]
pub extern "C" fn hyperion_io_uring_abi_version() -> u32 {
    ABI_VERSION
}

// ===== Linux implementation =====

#[cfg(target_os = "linux")]
mod linux_impl {
    use super::*;
    use io_uring::{opcode, types, IoUring};
    use std::os::unix::io::RawFd;

    /// Owned per-fiber ring. Holds the IoUring + a tiny scratch
    /// `libc::sockaddr_storage` so accept SQEs can hand the kernel a
    /// pointer to write the accepted peer addr into. We don't expose
    /// the peer addr to Ruby (the connection layer already pulls it
    /// off `accept` if needed via getpeername), but the kernel
    /// requires the pointer to be non-NULL on the accept opcode.
    pub struct Ring {
        ring: IoUring,
        addr_storage: libc::sockaddr_storage,
        addr_len: libc::socklen_t,
    }

    impl Ring {
        pub fn new(queue_depth: u32) -> std::io::Result<Self> {
            let ring = IoUring::builder().build(queue_depth)?;
            let addr_storage: libc::sockaddr_storage = unsafe { std::mem::zeroed() };
            Ok(Ring {
                ring,
                addr_storage,
                addr_len: std::mem::size_of::<libc::sockaddr_storage>() as libc::socklen_t,
            })
        }

        /// Submit an accept SQE for `listener_fd` and wait for its
        /// CQE. Returns Ok(client_fd) or Err(errno).
        pub fn accept(&mut self, listener_fd: RawFd) -> Result<RawFd, i32> {
            // Reset addr_len each call — the kernel writes the actual
            // sockaddr length into it on success and we don't want a
            // narrowed value from a previous call to confuse it.
            self.addr_len = std::mem::size_of::<libc::sockaddr_storage>() as libc::socklen_t;

            let accept_e = opcode::Accept::new(
                types::Fd(listener_fd),
                &mut self.addr_storage as *mut _ as *mut libc::sockaddr,
                &mut self.addr_len,
            )
            .build()
            .user_data(0xacce_0000);

            unsafe {
                if self.ring.submission().push(&accept_e).is_err() {
                    return Err(libc::EAGAIN);
                }
            }

            // submit_and_wait drives io_uring_enter with min_complete=1.
            // On success the kernel wakes us when the accept completes
            // (or errors out). We do NOT block the OS thread under
            // Async — the fiber is parked here, but io_uring_enter
            // itself is a blocking syscall. For the accept fiber that's
            // fine: the worker's ONE accept fiber owning ONE ring is
            // exactly the design. For per-connection read rings (a
            // future 2.3-A.x deliverable) we'll need IORING_ENTER_GETEVENTS
            // with a non-blocking submission instead, paired with
            // scheduler integration.
            self.ring.submit_and_wait(1).map_err(|_| libc::EIO)?;

            let cqe = self.ring.completion().next().ok_or(libc::EIO)?;
            let res = cqe.result();
            if res < 0 {
                Err(-res)
            } else {
                Ok(res)
            }
        }

        /// Submit a read SQE for `fd` into `buf` and wait for the
        /// CQE. Returns Ok(bytes) (0 on EOF) or Err(errno).
        pub fn read(&mut self, fd: RawFd, buf: *mut u8, len: u32) -> Result<i32, i32> {
            let read_e = opcode::Read::new(types::Fd(fd), buf, len)
                .build()
                .user_data(0xeead_0001);

            unsafe {
                if self.ring.submission().push(&read_e).is_err() {
                    return Err(libc::EAGAIN);
                }
            }

            self.ring.submit_and_wait(1).map_err(|_| libc::EIO)?;
            let cqe = self.ring.completion().next().ok_or(libc::EIO)?;
            let res = cqe.result();
            if res < 0 {
                Err(-res)
            } else {
                Ok(res)
            }
        }
    }

    /// Probe: try to set up a tiny ring. Returns 0 on success or the
    /// negative errno (e.g. -ENOSYS in a sandbox where io_uring_setup
    /// is blocked, or -EPERM in a seccomp-filtered container).
    pub fn probe() -> c_int {
        match IoUring::builder().build(8) {
            Ok(_) => 0,
            Err(e) => -(e.raw_os_error().unwrap_or(libc::ENOSYS)),
        }
    }
}

// ===== Non-Linux stubs =====
//
// On Darwin / BSD we still compile the crate so the `cargo build`
// step in the gem's extconf succeeds and the cdylib drops into the
// expected place — but every entry point returns the canonical
// "kernel feature missing" sentinel so the Ruby probe falls back
// cleanly.

#[cfg(not(target_os = "linux"))]
mod stub_impl {
    use super::*;

    pub struct Ring;

    impl Ring {
        pub fn new(_queue_depth: u32) -> std::io::Result<Self> {
            Err(std::io::Error::from_raw_os_error(38)) // ENOSYS on Linux; reuse code on Darwin
        }
    }

    pub fn probe() -> c_int {
        -38 // -ENOSYS
    }
}

#[cfg(target_os = "linux")]
use linux_impl::Ring;
#[cfg(not(target_os = "linux"))]
use stub_impl::Ring;

// ---------- C ABI ----------

#[no_mangle]
pub extern "C" fn hyperion_io_uring_probe() -> c_int {
    #[cfg(target_os = "linux")]
    {
        linux_impl::probe()
    }
    #[cfg(not(target_os = "linux"))]
    {
        stub_impl::probe()
    }
}

#[no_mangle]
pub extern "C" fn hyperion_io_uring_ring_new(queue_depth: c_uint) -> *mut Ring {
    let depth = if queue_depth == 0 { 256 } else { queue_depth };
    match Ring::new(depth) {
        Ok(r) => Box::into_raw(Box::new(r)),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_ring_free(ptr: *mut Ring) {
    if !ptr.is_null() {
        drop(Box::from_raw(ptr));
    }
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_accept(
    ptr: *mut Ring,
    listener_fd: c_int,
    out_errno: *mut c_int,
) -> c_int {
    if ptr.is_null() {
        if !out_errno.is_null() {
            *out_errno = 22; // EINVAL
        }
        return -2;
    }
    #[cfg(target_os = "linux")]
    {
        let ring = &mut *ptr;
        match ring.accept(listener_fd) {
            Ok(fd) => fd,
            Err(errno) => {
                if !out_errno.is_null() {
                    *out_errno = errno;
                }
                if errno == libc::EAGAIN {
                    -1
                } else {
                    -2
                }
            }
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (ptr, listener_fd);
        if !out_errno.is_null() {
            *out_errno = 38; // ENOSYS
        }
        -2
    }
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_read(
    ptr: *mut Ring,
    fd: c_int,
    buf: *mut c_uchar,
    max: c_uint,
    out_errno: *mut c_int,
) -> c_int {
    if ptr.is_null() || buf.is_null() {
        if !out_errno.is_null() {
            *out_errno = 22; // EINVAL
        }
        return -2;
    }
    #[cfg(target_os = "linux")]
    {
        let ring = &mut *ptr;
        match ring.read(fd, buf, max) {
            Ok(n) => n,
            Err(errno) => {
                if !out_errno.is_null() {
                    *out_errno = errno;
                }
                if errno == libc::EAGAIN {
                    -1
                } else {
                    -2
                }
            }
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (ptr, fd, buf, max);
        if !out_errno.is_null() {
            *out_errno = 38;
        }
        -2
    }
}
