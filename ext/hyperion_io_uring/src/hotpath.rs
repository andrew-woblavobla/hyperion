//! Hotpath ring — multishot accept + multishot recv (with PBUF_RING
//! kernel buffers) + send SQEs. One ring per worker; the accept fiber
//! drains the unified completion queue.
//!
//! Per spec §#2: connection state stays in Ruby; this module owns
//! submission/completion + buffer-ring lifecycle.
//!
//! ## Drop-ordering contract
//!
//! `HotpathRing` declares fields in the order: `buffer_ring`, `ring`,
//! `healthy`.  Rust drops fields in declaration order, so auto-drop
//! will free `buffer_ring` (frees backing memory) BEFORE closing the
//! `ring` fd.  The explicit `Drop` impl runs `unregister_buf_ring`
//! BEFORE either auto-drop runs — while both allocations are still
//! alive — which is the required sequence:
//!
//!   1. `Drop::drop` calls `unregister_buf_ring`  ← user code, runs first
//!   2. auto-drop `buffer_ring`                   ← frees backing memory
//!   3. auto-drop `ring`                          ← closes io_uring fd
//!
//! If the kernel retains a buf-ring registration while userspace frees
//! the backing memory, the next multishot recv CQE can write into freed
//! memory.  This ordering prevents that UAF.

use std::os::raw::c_int;
use std::panic::catch_unwind;

/// POSIX EINVAL (22) used for null-pointer sentinel return values.
/// Hard-coded so we don't depend on `libc` in platform-uniform C ABI code.
const EINVAL: c_int = 22;

/// Op kind for completions delivered to Ruby.  The numeric values are
/// packed into the high byte of `user_data` so the Ruby side can
/// dispatch by integer comparison without `rb_intern` lookup.
/// Stable ABI — do not renumber.
#[repr(u8)]
#[derive(Clone, Copy, Debug)]
pub enum OpKind {
    Accept = 1,
    Recv   = 2,
    Send   = 3,
    Close  = 4,
}

/// FFI-safe completion record.  Returned in batches via `wait_completions`.
/// `#[repr(C)]` so Ruby (via Fiddle) can index it by byte offset.
///
/// Field layout (24 bytes total on 64-bit):
///   u8  op_kind  (offset  0, size 1)
///   pad (offset  1, size 3)
///   i32 fd       (offset  4, size 4)
///   i64 result   (offset  8, size 8)
///   i32 buf_id   (offset 16, size 4)
///   u32 flags    (offset 20, size 4)
///
/// `buf_id` is `-1` when the CQE is not a recv with a buffer id
/// (`IORING_CQE_F_BUFFER` not set, or `op_kind != Recv`).
#[repr(C)]
pub struct Completion {
    pub op_kind: u8,
    pub _pad:    [u8; 3],
    pub fd:      i32,
    pub result:  i64,
    pub buf_id:  i32,
    pub flags:   u32,
}

// Compile-time ABI guard: Ruby (via Fiddle) reads Completion by byte
// offset using the size assumed in lib/hyperion/io_uring.rb's
// HotpathRing::COMPLETION_BYTES constant. If a future field/padding
// change drifts this size, build fails here with a clear message
// rather than producing silent garbage at runtime.
const _: () = assert!(
    std::mem::size_of::<Completion>() == 24,
    "Completion ABI size changed — update Ruby Fiddle offsets in lib/hyperion/io_uring.rb"
);

// ===== Linux implementation =====

#[cfg(target_os = "linux")]
mod linux_impl {
    use super::*;
    use crate::buffer_ring::BufferRing;
    use io_uring::{cqueue, opcode, squeue, types, IoUring};
    use std::os::unix::io::RawFd;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// Per-worker hotpath ring.  Owns one `IoUring` instance and one
    /// `BufferRing` (PBUF_RING kernel buffer pool for multishot recv).
    ///
    /// # Field declaration order
    ///
    /// Fields are declared `buffer_ring` → `ring` → `healthy` so that
    /// Rust's auto-drop (declaration order) frees `buffer_ring` first
    /// (backing memory) and then `ring` (io_uring fd).  The explicit
    /// `Drop` impl calls `unregister_buf_ring` BEFORE either auto-drop
    /// runs — see module-level doc for the full ordering proof.
    pub struct HotpathRing {
        /// Kernel-managed receive buffer pool.  Dropped FIRST by
        /// auto-drop (frees backing memory).  The explicit `Drop` impl
        /// has already unregistered the buf-ring with the kernel, so
        /// this free is safe.
        pub buffer_ring: BufferRing,
        /// The io_uring instance.  Dropped SECOND by auto-drop (closes
        /// the ring fd).
        pub ring: IoUring<squeue::Entry, cqueue::Entry>,
        /// Set to `false` on `submit_and_wait` failure.  Ruby checks
        /// this after each batch to detect ring corruption.
        pub healthy: AtomicBool,
    }

    impl HotpathRing {
        /// Allocate a ring of `queue_depth` SQE slots + CQE slots, and
        /// register a PBUF_RING of `n_bufs` buffers of `buf_size` bytes.
        ///
        /// `n_bufs` must be a power of two and ≤ 32768 (kernel limit).
        /// Returns `Err` on kernel rejection (ENOSYS < 5.19, EINVAL for
        /// bad params, EPERM in seccomp sandboxes, etc.).
        pub fn new(queue_depth: u32, n_bufs: u16, buf_size: u32)
            -> std::io::Result<Self>
        {
            let mut ring: IoUring<squeue::Entry, cqueue::Entry> =
                IoUring::builder().build(queue_depth)?;
            // group_id 0 — one buffer ring per HotpathRing.
            let buffer_ring = BufferRing::new(&mut ring, 0, n_bufs, buf_size)?;
            Ok(Self {
                buffer_ring,
                ring,
                healthy: AtomicBool::new(true),
            })
        }

        /// Post an `AcceptMulti` SQE for `listener_fd`.
        ///
        /// The multishot accept keeps reposting itself after each
        /// accepted connection until the listener is closed or the SQE
        /// is cancelled.  Each accepted fd arrives as a separate CQE
        /// drained by `wait_completions`.
        ///
        /// CONTRACT: when `wait_completions` returns -1 (sets
        /// `healthy = false`), the Ruby caller MUST stop issuing any
        /// further `submit_*` calls and engage the per-worker accept4
        /// fallback. This method does NOT guard on `is_healthy()`
        /// itself — it would unconditionally push the SQE onto a
        /// broken ring and fail at submit() with a confusing OS error.
        /// The Ruby side checks `is_healthy()` after each
        /// wait_completions return.
        ///
        /// Available since kernel 5.19.
        pub fn submit_accept_multishot(&mut self, listener_fd: RawFd)
            -> Result<(), i32>
        {
            // user_data encodes: high byte = OpKind, low 32 bits = fd.
            let ud = ((OpKind::Accept as u64) << 56)
                   | (listener_fd as u32 as u64);
            let sqe = opcode::AcceptMulti::new(types::Fd(listener_fd))
                .build()
                .user_data(ud);
            unsafe {
                self.ring.submission().push(&sqe)
                    .map_err(|_| libc::EAGAIN)?;
            }
            self.ring.submit().map_err(|_| libc::EIO)?;
            Ok(())
        }

        /// Post a `RecvMulti` SQE for `fd` backed by `buffer_ring`.
        ///
        /// The multishot recv rearms itself after each CQE unless
        /// `IORING_CQE_F_MORE` is absent, in which case the caller
        /// must reissue.  Each CQE carries a buf_id (extracted by
        /// `wait_completions`) that the caller must `release_buffer`
        /// after consuming.
        ///
        /// Available since kernel 6.0.
        pub fn submit_recv_multishot(&mut self, fd: RawFd)
            -> Result<(), i32>
        {
            let group_id = self.buffer_ring.group_id();
            let ud = ((OpKind::Recv as u64) << 56) | (fd as u32 as u64);
            let sqe = opcode::RecvMulti::new(types::Fd(fd), group_id)
                .build()
                .user_data(ud);
            unsafe {
                self.ring.submission().push(&sqe)
                    .map_err(|_| libc::EAGAIN)?;
            }
            self.ring.submit().map_err(|_| libc::EIO)?;
            Ok(())
        }

        /// Post a `Writev` SQE for `fd`.
        ///
        /// The caller is responsible for keeping `iov_ptr` (and the
        /// underlying buffers) alive until the matching send CQE is
        /// returned by `wait_completions`.
        pub fn submit_send(
            &mut self,
            fd: RawFd,
            iov_ptr: *const libc::iovec,
            iov_count: u32,
        ) -> Result<(), i32> {
            let ud = ((OpKind::Send as u64) << 56) | (fd as u32 as u64);
            let sqe = opcode::Writev::new(types::Fd(fd), iov_ptr, iov_count)
                .build()
                .user_data(ud);
            unsafe {
                self.ring.submission().push(&sqe)
                    .map_err(|_| libc::EAGAIN)?;
            }
            self.ring.submit().map_err(|_| libc::EIO)?;
            Ok(())
        }

        /// Submit any pending SQEs and wait for at least `min_complete`
        /// CQEs.  Drains up to `out_cap` completions into `out`.
        ///
        /// `_timeout_ms` is reserved for a future
        /// `io_uring_wait_cqe_timeout` path; for now we use
        /// `submit_and_wait` which blocks until `min_complete` CQEs
        /// arrive.
        ///
        /// Returns the number of completions written to `out`, or `-1`
        /// if `submit_and_wait` fails (ring marked unhealthy).
        ///
        /// # Buffer-id extraction
        ///
        /// For `Recv` CQEs with `IORING_CQE_F_BUFFER` set, the
        /// kernel encodes the buffer-id in `cqe.flags >> IORING_CQE_BUFFER_SHIFT`
        /// (upper 16 bits of the flags word).  We extract it and store it
        /// in `Completion::buf_id`; all other completions get `buf_id = -1`.
        pub fn wait_completions(
            &mut self,
            min_complete: u32,
            _timeout_ms: u32,
            out: *mut Completion,
            out_cap: u32,
        ) -> i32 {
            if self.ring.submit_and_wait(min_complete as usize).is_err() {
                self.healthy.store(false, Ordering::Release);
                return -1;
            }
            let mut written = 0u32;
            let mut completion = self.ring.completion();
            while written < out_cap {
                let cqe = match completion.next() {
                    Some(c) => c,
                    None    => break,
                };
                let user     = cqe.user_data();
                let op_byte  = (user >> 56) as u8;
                let fd       = (user & 0xffff_ffff) as i32;
                let result   = cqe.result() as i64;
                let flags    = cqe.flags();

                // Extract buf_id for recv completions that carry a buffer.
                // IORING_CQE_F_BUFFER (= 1) signals a valid buf_id in the
                // upper 16 bits of flags (IORING_CQE_BUFFER_SHIFT = 16).
                let buf_id = if op_byte == (OpKind::Recv as u8)
                    && result >= 0
                    && (flags & io_uring::sys::IORING_CQE_F_BUFFER) != 0
                {
                    ((flags >> io_uring::sys::IORING_CQE_BUFFER_SHIFT) & 0xffff) as i32
                } else {
                    -1
                };

                // SAFETY: `out` is valid for `out_cap` elements (caller
                // contract); `written < out_cap` is checked above.
                unsafe {
                    *out.add(written as usize) = Completion {
                        op_kind: op_byte,
                        _pad:    [0; 3],
                        fd,
                        result,
                        buf_id,
                        flags,
                    };
                }
                written += 1;
            }
            written as i32
        }

        /// Return `buf_id` to the kernel buffer pool so it can be
        /// reused for the next multishot recv CQE.
        ///
        /// Must be called once per recv CQE with `buf_id >= 0`.  The
        /// caller must NOT read from the buffer after calling this.
        pub fn release_buffer(&self, buf_id: u16) {
            self.buffer_ring.release(buf_id);
        }

        /// Force `is_healthy()` to return `false`.  Used by Ruby when
        /// it detects an unrecoverable error outside the ring (e.g. a
        /// connection closure that shouldn't propagate further).
        pub fn force_unhealthy(&self) {
            self.healthy.store(false, Ordering::Release);
        }

        /// Returns `true` while the ring is in a usable state.  Set to
        /// `false` by `wait_completions` on `submit_and_wait` failure or
        /// by `force_unhealthy`.
        pub fn is_healthy(&self) -> bool {
            self.healthy.load(Ordering::Acquire)
        }
    }

    impl Drop for HotpathRing {
        fn drop(&mut self) {
            // CRITICAL: unregister the kernel buf-ring BEFORE
            // `buffer_ring`'s auto-drop frees the backing memory.
            //
            // Rust's field-drop runs AFTER this user Drop body, in
            // declaration order: buffer_ring first (backing memory freed),
            // then ring (fd closed).  So calling unregister here — while
            // both buffer_ring.ring_ptr and ring.fd are still valid — is
            // the correct sequence:
            //
            //   1. THIS: unregister_buf_ring       ← kernel stops writing
            //   2. auto-drop buffer_ring            ← frees backing memory
            //   3. auto-drop ring                   ← closes io_uring fd
            //
            // Best-effort: if the ring fd was already closed by a prior
            // failure the unregister will error — we ignore that.
            let _ = unsafe {
                self.ring.submitter()
                    .unregister_buf_ring(self.buffer_ring.group_id())
            };
        }
    }

    /// Probe: try to set up a tiny ring + register a tiny PBUF_RING.
    /// Returns 0 on success or -errno on failure (-ENOSYS in sandboxes,
    /// -EINVAL on kernels that don't support PBUF_RING < 5.19).
    pub fn probe() -> c_int {
        match HotpathRing::new(8, 4, 256) {
            Ok(_)  => 0,
            Err(e) => -(e.raw_os_error().unwrap_or(libc::ENOSYS)),
        }
    }
}

// ===== Non-Linux stubs =====
//
// On Darwin / BSD the io-uring dep is gated out. We compile zero-cost
// stubs so the macOS dev build succeeds cleanly. The Ruby layer checks
// the OS before loading the hotpath path and never reaches these stubs.

#[cfg(not(target_os = "linux"))]
mod stub_impl {
    use super::*;

    pub struct HotpathRing;

    impl HotpathRing {
        pub fn new(_qd: u32, _nb: u16, _bs: u32) -> std::io::Result<Self> {
            Err(std::io::Error::from_raw_os_error(38)) // ENOSYS
        }

        pub fn submit_accept_multishot(&mut self, _fd: i32) -> Result<(), i32> {
            Err(38)
        }

        pub fn submit_recv_multishot(&mut self, _fd: i32) -> Result<(), i32> {
            Err(38)
        }

        // iov_ptr typed as *const u8 here — `libc` is not available on
        // non-Linux targets (it's a Linux-only Cargo dep in this crate).
        // The caller passes the raw pointer opaquely; this stub never
        // dereferences it.  The Linux extern "C" wrapper casts *const u8
        // → *const libc::iovec before calling the real impl.
        pub fn submit_send(
            &mut self, _fd: i32, _p: *const u8, _n: u32,
        ) -> Result<(), i32> {
            Err(38)
        }

        pub fn wait_completions(
            &mut self, _m: u32, _t: u32, _o: *mut Completion, _c: u32,
        ) -> i32 {
            -1
        }

        pub fn release_buffer(&self, _bid: u16) {}
        pub fn force_unhealthy(&self) {}

        pub fn is_healthy(&self) -> bool {
            false
        }
    }

    pub fn probe() -> c_int {
        -38 // -ENOSYS
    }
}

#[cfg(target_os = "linux")]
pub use linux_impl::{HotpathRing, probe};
#[cfg(not(target_os = "linux"))]
pub use stub_impl::{HotpathRing, probe};

// ===== C ABI =====
//
// All entry points:
//   - are prefixed `hyperion_io_uring_hotpath_`
//   - null-check their pointer argument before dereferencing
//   - wrap the body in `catch_unwind(AssertUnwindSafe(...))` to prevent
//     panic propagation across the FFI boundary (UB on stable Rust)
//   - return a negative errno sentinel on panic or bad pointer

/// Probe whether the hotpath (PBUF_RING + multishot accept/recv) is
/// supported on this kernel.  Returns 0 on success, negative errno
/// otherwise (e.g. -ENOSYS on kernels < 5.19 or in sandboxes).
///
/// CAVEAT — partial probe coverage:
/// `probe()` exercises `IORING_REGISTER_PBUF_RING` only (kernel ≥ 5.19).
/// `IORING_OP_RECV` with `IORING_RECV_MULTISHOT` requires kernel ≥ 6.0
/// and is NOT exercised here. A 5.19-5.x kernel returns 0 from this
/// probe but will reject the first `submit_recv_multishot` SQE with
/// `result < 0` and no `IORING_CQE_F_MORE` bit. The Ruby caller MUST
/// treat the first recv CQE failure as a feature-unavailable signal
/// and fall back to the accept4 + read_nonblock path.
#[no_mangle]
pub extern "C" fn hyperion_io_uring_hotpath_supported() -> c_int {
    catch_unwind(probe).unwrap_or(-EINVAL)
}

/// Allocate a new `HotpathRing`.  Returns an opaque pointer, or NULL
/// on failure (memory exhaustion, kernel rejection, etc.).
///
/// Caller must free with `hyperion_io_uring_hotpath_ring_free`.
#[no_mangle]
pub extern "C" fn hyperion_io_uring_hotpath_ring_new(
    queue_depth: u32,
    n_bufs: u16,
    buf_size: u32,
) -> *mut HotpathRing {
    catch_unwind(|| match HotpathRing::new(queue_depth, n_bufs, buf_size) {
        Ok(r)  => Box::into_raw(Box::new(r)),
        Err(_) => std::ptr::null_mut(),
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Free a `HotpathRing` previously allocated by
/// `hyperion_io_uring_hotpath_ring_new`.  No-op on NULL.
///
/// SAFETY: `ptr` must be a live pointer returned by `ring_new` and not
/// yet freed.  Must be called from the same worker that created it.
#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_ring_free(
    ptr: *mut HotpathRing,
) {
    let _ = catch_unwind(std::panic::AssertUnwindSafe(|| {
        if !ptr.is_null() {
            drop(Box::from_raw(ptr));
        }
    }));
}

/// Post an `AcceptMulti` SQE for `listener_fd`.
/// Returns 0 on success or a negative errno on failure.
#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_submit_accept_multishot(
    ptr: *mut HotpathRing,
    listener_fd: c_int,
) -> c_int {
    if ptr.is_null() {
        return -EINVAL;
    }
    catch_unwind(std::panic::AssertUnwindSafe(|| {
        match (*ptr).submit_accept_multishot(listener_fd) {
            Ok(()) => 0,
            Err(e) => -e,
        }
    }))
    .unwrap_or(-EINVAL)
}

/// Post a `RecvMulti` SQE for `fd` backed by the ring's buffer pool.
/// Returns 0 on success or a negative errno on failure.
#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_submit_recv_multishot(
    ptr: *mut HotpathRing,
    fd: c_int,
) -> c_int {
    if ptr.is_null() {
        return -EINVAL;
    }
    catch_unwind(std::panic::AssertUnwindSafe(|| {
        match (*ptr).submit_recv_multishot(fd) {
            Ok(()) => 0,
            Err(e) => -e,
        }
    }))
    .unwrap_or(-EINVAL)
}

/// Post a `Writev` SQE for `fd`.
///
/// `iov_ptr` must point to `iov_count` valid `iovec` entries (each
/// entry is `{ base: *mut u8, len: usize }` — the layout of POSIX
/// `iovec`) and must remain valid until the matching send CQE arrives.
/// Returns 0 on success or a negative errno on failure.
///
/// The argument is typed as `*const u8` (rather than `*const libc::iovec`)
/// so this extern "C" declaration compiles on all platforms; the Linux
/// impl casts it to the correct `*const libc::iovec` type internally.
#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_submit_send(
    ptr: *mut HotpathRing,
    fd: c_int,
    iov_ptr: *const u8,
    iov_count: u32,
) -> c_int {
    if ptr.is_null() || iov_ptr.is_null() {
        return -EINVAL;
    }
    #[cfg(target_os = "linux")]
    {
        catch_unwind(std::panic::AssertUnwindSafe(|| {
            // SAFETY: caller guarantees `iov_ptr` points to `iov_count`
            // valid `libc::iovec` entries with the same layout.
            match (*ptr).submit_send(fd, iov_ptr as *const libc::iovec, iov_count) {
                Ok(()) => 0,
                Err(e) => -e,
            }
        }))
        .unwrap_or(-EINVAL)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (ptr, fd, iov_ptr, iov_count);
        -38 // -ENOSYS
    }
}

/// Submit pending SQEs and wait for at least `min_complete` CQEs.
/// Writes up to `out_cap` `Completion` structs into `out`.
///
/// Returns the number of completions written, or `-1` on ring failure
/// (ring is marked unhealthy after this).
///
/// `out` must point to a buffer of at least `out_cap * 24` bytes
/// (24 = `size_of::<Completion>()` on 64-bit).
#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_wait_completions(
    ptr: *mut HotpathRing,
    min_complete: u32,
    timeout_ms: u32,
    out: *mut Completion,
    out_cap: u32,
) -> c_int {
    if ptr.is_null() || (out_cap > 0 && out.is_null()) {
        return -EINVAL;
    }
    catch_unwind(std::panic::AssertUnwindSafe(|| {
        (*ptr).wait_completions(min_complete, timeout_ms, out, out_cap)
    }))
    .unwrap_or(-EINVAL)
}

/// Release `buf_id` back to the kernel's buffer pool.
/// Must be called once per recv CQE whose `buf_id >= 0`.
#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_release_buffer(
    ptr: *mut HotpathRing,
    buf_id: u16,
) {
    let _ = catch_unwind(std::panic::AssertUnwindSafe(|| {
        if !ptr.is_null() {
            (*ptr).release_buffer(buf_id);
        }
    }));
}

/// Force `is_healthy` to return false.
#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_force_unhealthy(
    ptr: *mut HotpathRing,
) {
    let _ = catch_unwind(std::panic::AssertUnwindSafe(|| {
        if !ptr.is_null() {
            (*ptr).force_unhealthy();
        }
    }));
}

/// Returns 1 if the ring is healthy, 0 otherwise.
#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_is_healthy(
    ptr: *mut HotpathRing,
) -> c_int {
    if ptr.is_null() {
        return 0;
    }
    catch_unwind(std::panic::AssertUnwindSafe(|| {
        if (*ptr).is_healthy() { 1 } else { 0 }
    }))
    .unwrap_or(0)
}
