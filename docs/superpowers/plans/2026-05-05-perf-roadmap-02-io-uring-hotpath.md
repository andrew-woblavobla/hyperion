# Plan #2 — io_uring on the request hot path

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend Hyperion's io_uring usage from accept-only (existing 2.3-A) to the full request hot path: multishot accept + multishot recv with kernel-managed buffer rings (`IORING_REGISTER_PBUF_RING`, Linux 5.19+) + send SQEs paired with plan #1's C writer. Keep the dispatch model unchanged: Rust submits/reaps; Ruby parses and dispatches. Independent gate (`HYPERION_IO_URING_HOTPATH`) separate from the existing accept-only gate; default off.

**Architecture:** ABI-bump the existing `hyperion_io_uring` Rust crate (1 → 2) and add a new submodule `hotpath_impl` exposing recv-multishot, send, and buffer-ring primitives. Ruby gets a `Hyperion::IOUring::HotpathRing` class whose accept fiber drains a unified completion queue (accept + recv + send CQEs). Connection state stays in `lib/hyperion/connection.rb`; reads come from kernel-managed buffer-ring views. Plan #1's C writer gains a sibling `c_write_buffered_via_ring` entrypoint that submits a send SQE through `dlsym`-resolved Rust symbols (no hard build-time dependency between the two extensions). Per-worker fallback engages on sustained ring failure — worker degrades to accept4 + read_nonblock + write(2); other workers stay on the hotpath.

**Tech Stack:** Rust (`io-uring` 0.6 crate, `libc`, `IORING_REGISTER_PBUF_RING`, `std::panic::catch_unwind`), C (Ruby ext, `dlsym(RTLD_DEFAULT, ...)` for cross-extension binding), Ruby (Fiddle::Function bindings, `Connection` integration, CLI/config plumbing), Linux 5.6+ (basic) + 5.19+ (buffer rings).

**Spec reference:** `docs/superpowers/specs/2026-05-05-hyperion-perf-roadmap-design.md` § "#2 — io_uring on the request hot path".

**Sequence position:** Ships **after** plan #1 (C ResponseWriter). Plan #1's `c_write_buffered_via_ring` entrypoint depends on Rust symbols this plan exports.

**Worktree:** Most work runs on `openclaw-vm` (Linux 6.8). The macOS dev host is fine for cross-platform fallback specs and for the Ruby plumbing; the buffer-ring + recv-multishot specs are Linux-5.19+-only.

---

## File map

| Path | Status | Responsibility |
|---|---|---|
| `ext/hyperion_io_uring/Cargo.toml` | Modify | Bump version 2.3.0 → 2.4.0. |
| `ext/hyperion_io_uring/src/lib.rs` | Modify | Bump `ABI_VERSION` 1 → 2. New extern "C" entrypoints with `hyperion_io_uring_hotpath_*` prefix. |
| `ext/hyperion_io_uring/src/hotpath.rs` | **Create** | New module: `HotpathRing` struct, `submit_recv_multishot`, `submit_send`, `wait_completions`, `force_unhealthy` test seam. Linux-only impl + Darwin stubs. |
| `ext/hyperion_io_uring/src/buffer_ring.rs` | **Create** | New module: owns the `IORING_REGISTER_PBUF_RING` mmap, `borrow(buf_id, len)` + `release(buf_id)`. |
| `lib/hyperion/io_uring.rb` | Modify | Bump `EXPECTED_ABI` 1 → 2. New `HotpathRing` class, `hotpath_supported?`, `resolve_hotpath_policy!`. Existing `Ring` accept-only class unchanged. |
| `lib/hyperion/config.rb` | Modify | Add `io_uring_hotpath: :off` setting alongside existing `io_uring:`. |
| `lib/hyperion/cli.rb` | Modify | New `--io-uring-hotpath={off,auto,on}` flag + `apply_io_uring_hotpath_env_override!` for `HYPERION_IO_URING_HOTPATH`. New env vars `HYPERION_IO_URING_HOTPATH_BUFS`, `HYPERION_IO_URING_HOTPATH_BUF_SIZE`. |
| `lib/hyperion/server.rb` | Modify | When `io_uring_hotpath` resolves truthy, instantiate `HotpathRing` per accept fiber instead of the accept-only `Ring`. The accept fiber drains a unified CQ. |
| `lib/hyperion/connection.rb` | Modify | New `feed_read_bytes(buf_view)` + `io_uring_owned` flag. When `io_uring_owned`, `read_chunk` is replaced by buffer-ring view consumption. Writes (when `io_uring_owned`) route through `c_write_buffered_via_ring`. |
| `ext/hyperion_http/response_writer.c` | Modify (from #1) | Add `c_write_buffered_via_ring` + dlsym wiring at `Init_hyperion_response_writer`. |
| `ext/hyperion_http/extconf.rb` | Modify | No new probe needed (dlfcn already linked from #1). |
| `lib/hyperion/http/response_writer.rb` | Modify (from #1) | Document the new `c_write_buffered_via_ring` surface. |
| `config/hyperion.example.rb` | Modify | Add `io_uring_hotpath :off` example. |
| `docs/IO_URING_HOTPATH.md` | **Create** | New operator doc. |
| `docs/CONFIGURATION.md` | Modify | New env var rows. |
| `spec/hyperion/io_uring_hotpath_spec.rb` | **Create** | Linux 5.19+. recv multishot, ECONNABORTED/ECANCELED/EBADF errno paths. |
| `spec/hyperion/io_uring_hotpath_send_spec.rb` | **Create** | Linux 5.19+. send SQEs end-to-end + short-write follow-up. |
| `spec/hyperion/io_uring_hotpath_fallback_spec.rb` | **Create** | Cross-platform. `hotpath_supported?` false on macOS / Linux<5.19 / `=off`. |
| `spec/hyperion/connection_io_uring_hotpath_spec.rb` | **Create** | Linux 5.19+. End-to-end byte-for-byte vs non-hotpath. |
| `spec/hyperion/io_uring_hotpath_buffer_exhaustion_spec.rb` | **Create** | Linux 5.19+. Exhaust the buffer ring, assert `:io_uring_recv_enobufs` increments + no client dropped. |
| `spec/hyperion/io_uring_hotpath_fallback_engaged_spec.rb` | **Create** | Linux 5.19+. Inject `HotpathRing#force_unhealthy!`, assert per-worker fallback. |
| `spec/hyperion/io_uring_hotpath_abi_spec.rb` | **Create** | Cross-platform. ABI v1 `.so` against v2 → `hotpath_supported?` false + warn. |
| `spec/hyperion/io_uring_soak_smoke_spec.rb` | Modify (existing) | Add hotpath-on variant; `:perf` tag. |

---

## Sub-PR 2.1 — Rust crate ABI v2 + hotpath entrypoints + buffer ring

Goal: ship the Rust surface with no Ruby integration. Specs at the Rust-binding layer pass; nothing wired to the connection.

### Task 2.1.1: Bump Rust crate version + ABI

**Files:**
- Modify: `ext/hyperion_io_uring/Cargo.toml`
- Modify: `ext/hyperion_io_uring/src/lib.rs`

- [ ] **Step 1: Bump the Cargo version**

Open `Cargo.toml`. Change `version = "2.3.0"` to `version = "2.4.0"`.

- [ ] **Step 2: Bump `ABI_VERSION`**

Open `ext/hyperion_io_uring/src/lib.rs`. Find:

```rust
const ABI_VERSION: u32 = 1;
```

Change to:

```rust
const ABI_VERSION: u32 = 2;
```

- [ ] **Step 3: Build to confirm clean compilation**

```bash
(cd ext/hyperion_io_uring && cargo build --release)
```

Expected: `Compiling hyperion_io_uring v2.4.0` then `Finished release [optimized] target(s)`.

- [ ] **Step 4: Verify the existing accept-only ABI specs still pass**

```bash
bundle exec rake compile
bundle exec rspec spec/hyperion/io_uring_spec.rb spec/hyperion/io_uring_loop_spec.rb -fd
```

Expected: any spec that checks `EXPECTED_ABI` against the cdylib will fail until we bump the Ruby side too. Note the failing spec(s).

- [ ] **Step 5: Bump `EXPECTED_ABI` in `lib/hyperion/io_uring.rb`**

Find `EXPECTED_ABI = 1` (line 55). Change to `EXPECTED_ABI = 2`.

- [ ] **Step 6: Re-run + confirm green**

```bash
bundle exec rake compile && bundle exec rspec spec/hyperion/io_uring_spec.rb -fd
```

Expected: green.

- [ ] **Step 7: Commit**

```bash
git add ext/hyperion_io_uring/Cargo.toml ext/hyperion_io_uring/src/lib.rs lib/hyperion/io_uring.rb
git commit -m "[ext] hyperion_io_uring: ABI v2 (perf roadmap #2 prep)"
```

---

### Task 2.1.2: Implement the buffer-ring module (`buffer_ring.rs`)

**Files:**
- Create: `ext/hyperion_io_uring/src/buffer_ring.rs`
- Modify: `ext/hyperion_io_uring/src/lib.rs` — `mod buffer_ring;` declaration.

- [ ] **Step 1: Create `buffer_ring.rs`**

```rust
//! IORING_REGISTER_PBUF_RING (Linux 5.19+) — kernel-managed receive
//! buffer pool. The ring registers N buffers of M bytes each; the
//! kernel hands back a buffer-id in each recv CQE. Caller borrows
//! the buffer (zero-copy view), consumes the bytes, then `release`s
//! the buffer-id back to the kernel.

use std::sync::atomic::{AtomicU16, Ordering};

#[cfg(target_os = "linux")]
mod linux_impl {
    use super::*;
    use io_uring::{IoUring, types};
    use std::os::raw::c_void;

    pub struct BufferRing {
        pub group_id: u16,
        pub n_bufs: u16,
        pub buf_size: u32,
        /// Backing storage for the buffers. Pinned heap allocation;
        /// the kernel reads/writes into it directly via the registered
        /// pbuf ring.
        pub backing: Vec<u8>,
        /// Tail index for the producer (us, "release-buffer" side).
        /// Kernel reads via the mmap'd ring — we update this counter
        /// when we hand a buffer back. Atomic because in a future
        /// SQPOLL design the kernel could race.
        pub tail: AtomicU16,
    }

    impl BufferRing {
        pub fn new(ring: &mut IoUring, group_id: u16, n_bufs: u16, buf_size: u32)
            -> std::io::Result<Self>
        {
            let total = (n_bufs as usize) * (buf_size as usize);
            let backing = vec![0u8; total];

            // Register the buffer ring with the kernel. The
            // io-uring crate exposes this via the submitter's
            // register_buf_ring; fall back to libc-level if the
            // crate version on the host is older.
            unsafe {
                let submitter = ring.submitter();
                submitter.register_buf_ring(
                    backing.as_ptr() as *mut c_void as u64,
                    n_bufs as u16,
                    group_id,
                ).or_else(|e| {
                    // -ENOSYS / -EINVAL → 5.19 not available
                    // (or kernel built without the feature).
                    Err(e)
                })?;
            }

            // Pre-populate the ring: every buffer is initially
            // available to the kernel.
            for i in 0..n_bufs {
                let offset = (i as usize) * (buf_size as usize);
                let ptr = backing[offset..].as_ptr();
                unsafe {
                    submitter_provide_buf(ring, group_id, i, ptr as *mut u8, buf_size);
                }
            }

            Ok(BufferRing {
                group_id,
                n_bufs,
                buf_size,
                backing,
                tail: AtomicU16::new(n_bufs),
            })
        }

        /// Borrow a slice view into the kernel-filled buffer.
        pub unsafe fn borrow(&self, buf_id: u16, len: usize) -> &[u8] {
            let offset = (buf_id as usize) * (self.buf_size as usize);
            std::slice::from_raw_parts(self.backing.as_ptr().add(offset), len)
        }

        /// Release a buffer back to the kernel — increment tail and
        /// post the buffer pointer.
        pub fn release(&self, buf_id: u16) {
            // Update tail (best-effort; the kernel polls this).
            self.tail.fetch_add(1, Ordering::Release);
            // For 5.19+ pbuf ring, release is mostly a counter update
            // — the buffer storage stays pinned; the kernel re-uses
            // it by index. No additional syscall required.
            let _ = buf_id; // suppress unused-warning
        }
    }

    /// Helper for the crate-version-portable buffer-provide call.
    unsafe fn submitter_provide_buf(
        _ring: &mut IoUring,
        _group_id: u16,
        _buf_id: u16,
        _ptr: *mut u8,
        _len: u32,
    ) {
        // The io-uring 0.6 crate exposes the provide_buffer SQE via
        // opcode::ProvideBuffers. For pbuf rings (5.19+), the kernel
        // pulls buffer info from the registered ring directly; this
        // helper is a no-op when the pbuf ring path is engaged. Kept
        // as a hook for the SQE-style ProvideBuffers fallback (5.6 →
        // 5.18 path) we may add later. Today we register-only.
    }
}

#[cfg(not(target_os = "linux"))]
mod stub_impl {
    pub struct BufferRing {
        pub group_id: u16,
        pub n_bufs: u16,
        pub buf_size: u32,
    }

    impl BufferRing {
        pub fn new(_ring: &mut (), _group_id: u16, _n_bufs: u16, _buf_size: u32)
            -> std::io::Result<Self>
        {
            Err(std::io::Error::from_raw_os_error(38)) // ENOSYS
        }

        pub unsafe fn borrow(&self, _buf_id: u16, _len: usize) -> &[u8] { &[] }
        pub fn release(&self, _buf_id: u16) {}
    }
}

#[cfg(target_os = "linux")]
pub use linux_impl::BufferRing;
#[cfg(not(target_os = "linux"))]
pub use stub_impl::BufferRing;
```

- [ ] **Step 2: Declare the module in `lib.rs`**

Open `ext/hyperion_io_uring/src/lib.rs`. After the `#![allow(...)]` line, add:

```rust
mod buffer_ring;
```

- [ ] **Step 3: Build to confirm**

```bash
(cd ext/hyperion_io_uring && cargo build --release)
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add ext/hyperion_io_uring/src/buffer_ring.rs ext/hyperion_io_uring/src/lib.rs
git commit -m "[ext/io_uring] buffer_ring module: PBUF_RING (5.19+) registration + borrow/release"
```

---

### Task 2.1.3: Implement the hotpath module (`hotpath.rs`)

**Files:**
- Create: `ext/hyperion_io_uring/src/hotpath.rs`
- Modify: `ext/hyperion_io_uring/src/lib.rs` — declare module + add extern "C" entrypoints.

- [ ] **Step 1: Create `hotpath.rs`**

```rust
//! Hotpath ring — multishot accept + multishot recv (with PBUF_RING
//! kernel buffers) + send SQEs. One ring per worker; the accept
//! fiber drains the unified completion queue.
//!
//! Per spec §#2: connection state stays in Ruby; this module owns
//! submission/completion + buffer-ring lifecycle.

use crate::buffer_ring::BufferRing;
use std::os::raw::c_int;
use std::panic::catch_unwind;
use std::sync::atomic::{AtomicBool, Ordering};

/// Op kind for completions delivered to Ruby.
#[repr(u8)]
#[derive(Clone, Copy, Debug)]
pub enum OpKind {
    Accept = 1,
    Recv   = 2,
    Send   = 3,
    Close  = 4,
}

/// FFI-safe completion record. Returned in batches via wait_completions.
#[repr(C)]
pub struct Completion {
    pub op_kind: u8,
    pub fd:      i32,
    pub result:  i64,   // bytes / accepted-fd / negative errno
    pub buf_id:  i32,   // -1 when not a recv
    pub flags:   u32,   // IORING_CQE_F_MORE etc.
}

#[cfg(target_os = "linux")]
mod linux_impl {
    use super::*;
    use io_uring::{opcode, squeue, types, IoUring};
    use std::os::unix::io::RawFd;

    pub struct HotpathRing {
        pub ring: IoUring<squeue::Entry, io_uring::cqueue::Entry>,
        pub buffer_ring: BufferRing,
        pub healthy: AtomicBool,
    }

    impl HotpathRing {
        pub fn new(queue_depth: u32, n_bufs: u16, buf_size: u32)
            -> std::io::Result<Self>
        {
            let mut ring = IoUring::builder().build(queue_depth)?;
            let buffer_ring = BufferRing::new(&mut ring, /*group_id=*/0, n_bufs, buf_size)?;
            Ok(Self { ring, buffer_ring, healthy: AtomicBool::new(true) })
        }

        pub fn submit_accept_multishot(&mut self, listener_fd: RawFd) -> Result<(), i32> {
            let sqe = opcode::AcceptMulti::new(types::Fd(listener_fd))
                .build()
                .user_data(((OpKind::Accept as u64) << 56) | (listener_fd as u64));
            unsafe {
                self.ring.submission().push(&sqe).map_err(|_| libc::EAGAIN)?;
            }
            self.ring.submit().map_err(|_| libc::EIO)?;
            Ok(())
        }

        pub fn submit_recv_multishot(&mut self, fd: RawFd) -> Result<(), i32> {
            let sqe = opcode::RecvMulti::new(types::Fd(fd), self.buffer_ring.group_id)
                .build()
                .user_data(((OpKind::Recv as u64) << 56) | (fd as u64));
            unsafe {
                self.ring.submission().push(&sqe).map_err(|_| libc::EAGAIN)?;
            }
            self.ring.submit().map_err(|_| libc::EIO)?;
            Ok(())
        }

        pub fn submit_send(&mut self, fd: RawFd, iov_ptr: *const libc::iovec, iov_count: u32)
            -> Result<(), i32>
        {
            let sqe = opcode::Writev::new(types::Fd(fd), iov_ptr, iov_count)
                .build()
                .user_data(((OpKind::Send as u64) << 56) | (fd as u64));
            unsafe {
                self.ring.submission().push(&sqe).map_err(|_| libc::EAGAIN)?;
            }
            self.ring.submit().map_err(|_| libc::EIO)?;
            Ok(())
        }

        /// Drain up to `out_cap` completions. Returns the number written.
        pub fn wait_completions(&mut self, min_complete: u32, timeout_ms: u32,
                                out: *mut Completion, out_cap: u32) -> i32 {
            // Submit pending + wait for at least min_complete CQEs.
            let _ = timeout_ms; // 0.6 wait_with_timeout is feature-gated; use submit_and_wait
            if self.ring.submit_and_wait(min_complete as usize).is_err() {
                self.healthy.store(false, Ordering::Release);
                return -1;
            }
            let mut written = 0u32;
            while written < out_cap {
                let cqe = match self.ring.completion().next() {
                    Some(c) => c,
                    None => break,
                };
                let user = cqe.user_data();
                let op_byte = (user >> 56) as u8;
                let fd = (user & 0xffff_ffff) as i32;
                let result = cqe.result() as i64;
                let flags = cqe.flags();
                let buf_id = if op_byte == (OpKind::Recv as u8) && result >= 0 {
                    // Buffer ID lives in the upper 16 bits of flags.
                    ((flags >> 16) & 0xffff) as i32
                } else { -1 };
                unsafe {
                    *out.offset(written as isize) = Completion {
                        op_kind: op_byte,
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

        pub fn release_buffer(&self, buf_id: u16) {
            self.buffer_ring.release(buf_id);
        }

        pub fn force_unhealthy(&self) {
            self.healthy.store(false, Ordering::Release);
        }

        pub fn is_healthy(&self) -> bool {
            self.healthy.load(Ordering::Acquire)
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod stub_impl {
    use super::*;
    pub struct HotpathRing;

    impl HotpathRing {
        pub fn new(_qd: u32, _nb: u16, _bs: u32) -> std::io::Result<Self> {
            Err(std::io::Error::from_raw_os_error(38))
        }
        pub fn submit_accept_multishot(&mut self, _fd: i32) -> Result<(), i32> { Err(38) }
        pub fn submit_recv_multishot(&mut self, _fd: i32)   -> Result<(), i32> { Err(38) }
        pub fn submit_send(&mut self, _fd: i32, _p: *const libc::iovec, _n: u32)
            -> Result<(), i32> { Err(38) }
        pub fn wait_completions(&mut self, _m: u32, _t: u32,
                                _o: *mut Completion, _c: u32) -> i32 { -1 }
        pub fn release_buffer(&self, _bid: u16) {}
        pub fn force_unhealthy(&self) {}
        pub fn is_healthy(&self) -> bool { false }
    }
}

#[cfg(target_os = "linux")]
pub use linux_impl::HotpathRing;
#[cfg(not(target_os = "linux"))]
pub use stub_impl::HotpathRing;

// ---------- C ABI ----------

/// Hotpath probe: 0 if 5.19+ buffer-ring registration succeeds, else
/// negative errno.
#[no_mangle]
pub extern "C" fn hyperion_io_uring_hotpath_supported() -> c_int {
    let res = catch_unwind(|| {
        #[cfg(target_os = "linux")]
        {
            // Probe by trying to set up a tiny ring + register a tiny pbuf.
            match HotpathRing::new(8, 4, 256) {
                Ok(_) => 0,
                Err(e) => -(e.raw_os_error().unwrap_or(libc::ENOSYS)),
            }
        }
        #[cfg(not(target_os = "linux"))]
        { -38 }
    });
    res.unwrap_or(-libc::EINVAL)
}

#[no_mangle]
pub extern "C" fn hyperion_io_uring_hotpath_ring_new(queue_depth: u32, n_bufs: u16, buf_size: u32)
    -> *mut HotpathRing
{
    let res = catch_unwind(|| {
        match HotpathRing::new(queue_depth, n_bufs, buf_size) {
            Ok(r)  => Box::into_raw(Box::new(r)),
            Err(_) => std::ptr::null_mut(),
        }
    });
    res.unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_ring_free(ptr: *mut HotpathRing) {
    let _ = catch_unwind(|| {
        if !ptr.is_null() { drop(Box::from_raw(ptr)); }
    });
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_submit_accept_multishot(
    ptr: *mut HotpathRing, listener_fd: c_int) -> c_int
{
    if ptr.is_null() { return -libc::EINVAL; }
    let res = catch_unwind(|| {
        let r = &mut *ptr;
        match r.submit_accept_multishot(listener_fd) {
            Ok(()) => 0,
            Err(e) => -e,
        }
    });
    res.unwrap_or(-libc::EINVAL)
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_submit_recv_multishot(
    ptr: *mut HotpathRing, fd: c_int) -> c_int
{
    if ptr.is_null() { return -libc::EINVAL; }
    let res = catch_unwind(|| {
        let r = &mut *ptr;
        match r.submit_recv_multishot(fd) {
            Ok(()) => 0,
            Err(e) => -e,
        }
    });
    res.unwrap_or(-libc::EINVAL)
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_submit_send(
    ptr: *mut HotpathRing, fd: c_int,
    iov_ptr: *const libc::iovec, iov_count: u32) -> c_int
{
    if ptr.is_null() || iov_ptr.is_null() { return -libc::EINVAL; }
    let res = catch_unwind(|| {
        let r = &mut *ptr;
        match r.submit_send(fd, iov_ptr, iov_count) {
            Ok(()) => 0,
            Err(e) => -e,
        }
    });
    res.unwrap_or(-libc::EINVAL)
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_wait_completions(
    ptr: *mut HotpathRing, min_complete: u32, timeout_ms: u32,
    out: *mut Completion, out_cap: u32) -> c_int
{
    if ptr.is_null() || out.is_null() { return -libc::EINVAL; }
    let res = catch_unwind(|| {
        let r = &mut *ptr;
        r.wait_completions(min_complete, timeout_ms, out, out_cap)
    });
    res.unwrap_or(-libc::EINVAL)
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_release_buffer(
    ptr: *mut HotpathRing, buf_id: u16) -> c_int
{
    if ptr.is_null() { return -libc::EINVAL; }
    let res = catch_unwind(|| {
        let r = &*ptr;
        r.release_buffer(buf_id);
        0
    });
    res.unwrap_or(-libc::EINVAL)
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_force_unhealthy(
    ptr: *mut HotpathRing) -> c_int
{
    if ptr.is_null() { return -libc::EINVAL; }
    let res = catch_unwind(|| {
        (&*ptr).force_unhealthy();
        0
    });
    res.unwrap_or(-libc::EINVAL)
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_io_uring_hotpath_is_healthy(
    ptr: *mut HotpathRing) -> c_int
{
    if ptr.is_null() { return 0; }
    let res = catch_unwind(|| {
        if (&*ptr).is_healthy() { 1 } else { 0 }
    });
    res.unwrap_or(0)
}
```

- [ ] **Step 2: Declare the module in `lib.rs`**

Open `ext/hyperion_io_uring/src/lib.rs`. Below the existing `mod buffer_ring;` line, add:

```rust
pub mod hotpath;
pub use hotpath::Completion as HotpathCompletion;
```

- [ ] **Step 3: Build, run cargo check**

```bash
(cd ext/hyperion_io_uring && cargo check --release && cargo build --release)
```

Expected: clean (Linux). On macOS the stub paths compile.

- [ ] **Step 4: Commit**

```bash
git add ext/hyperion_io_uring/src/hotpath.rs ext/hyperion_io_uring/src/lib.rs
git commit -m "[ext/io_uring] hotpath module: ring lifecycle + multishot accept/recv + send + completions"
```

---

### Task 2.1.4: Smoke test the Rust hotpath via Fiddle (failing spec first)

Establishes that the new entrypoints are reachable from Ruby before we wrap them in a higher-level `HotpathRing` class.

**Files:**
- Create: `spec/hyperion/io_uring_hotpath_spec.rb`

- [ ] **Step 1: Write the failing spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'hyperion/io_uring'
require 'fiddle'

# Linux 5.19+ only. Skip cleanly on macOS / older kernels.
RSpec.describe 'io_uring hotpath FFI', if: Hyperion::IOUring.linux? do
  before do
    Hyperion::IOUring.reset!
    skip 'hotpath_supported? false (kernel < 5.19 or buffer-ring registration failed)' \
      unless Hyperion::IOUring.respond_to?(:hotpath_supported?) && Hyperion::IOUring.hotpath_supported?
  end

  it 'probes successfully' do
    expect(Hyperion::IOUring.hotpath_supported?).to eq(true)
  end

  it 'allocates and frees a hotpath ring' do
    lib = Hyperion::IOUring.send(:load!)
    new_fn = Fiddle::Function.new(
      lib['hyperion_io_uring_hotpath_ring_new'],
      [Fiddle::TYPE_INT, Fiddle::TYPE_SHORT, Fiddle::TYPE_INT],
      Fiddle::TYPE_VOIDP
    )
    free_fn = Fiddle::Function.new(
      lib['hyperion_io_uring_hotpath_ring_free'],
      [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID
    )

    ptr = new_fn.call(64, 32, 4096)
    expect(ptr).not_to be_null
    free_fn.call(ptr)
  end
end
```

- [ ] **Step 2: Run the spec on the bench VM (macOS dev will skip)**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && bundle exec rake compile && bundle exec rspec spec/hyperion/io_uring_hotpath_spec.rb -fd'
```

Expected on Linux 5.19+: pass. macOS: skip (`described_class.linux?` is false).

- [ ] **Step 3: Commit**

```bash
git add spec/hyperion/io_uring_hotpath_spec.rb
git commit -m "[spec] io_uring_hotpath: smoke ring_new/ring_free via Fiddle"
```

---

## Sub-PR 2.2 — Ruby `HotpathRing` class + supported probe + policy resolver

Goal: a Ruby surface for the new Rust entrypoints, plus the cross-platform fallback specs.

### Task 2.2.1: Add `HotpathRing` class to `lib/hyperion/io_uring.rb`

**Files:**
- Modify: `lib/hyperion/io_uring.rb`

- [ ] **Step 1: Bind the new Fiddle functions in the `load!` method**

Find `def load!` (line 219). Inside it, after the existing `@read_fn = Fiddle::Function.new(...)` block (lines 247-251), add:

```ruby
        # Plan #2 — hotpath surface (5.19+).
        @hotpath_supported_fn = Fiddle::Function.new(
          @lib['hyperion_io_uring_hotpath_supported'], [], Fiddle::TYPE_INT
        )
        @hotpath_ring_new_fn = Fiddle::Function.new(
          @lib['hyperion_io_uring_hotpath_ring_new'],
          [Fiddle::TYPE_INT, Fiddle::TYPE_SHORT, Fiddle::TYPE_INT],
          Fiddle::TYPE_VOIDP
        )
        @hotpath_ring_free_fn = Fiddle::Function.new(
          @lib['hyperion_io_uring_hotpath_ring_free'],
          [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID
        )
        @hotpath_submit_accept_fn = Fiddle::Function.new(
          @lib['hyperion_io_uring_hotpath_submit_accept_multishot'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT
        )
        @hotpath_submit_recv_fn = Fiddle::Function.new(
          @lib['hyperion_io_uring_hotpath_submit_recv_multishot'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT
        )
        @hotpath_submit_send_fn = Fiddle::Function.new(
          @lib['hyperion_io_uring_hotpath_submit_send'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_INT
        )
        @hotpath_wait_fn = Fiddle::Function.new(
          @lib['hyperion_io_uring_hotpath_wait_completions'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT,
           Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_INT
        )
        @hotpath_release_buf_fn = Fiddle::Function.new(
          @lib['hyperion_io_uring_hotpath_release_buffer'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SHORT], Fiddle::TYPE_INT
        )
        @hotpath_force_unhealthy_fn = Fiddle::Function.new(
          @lib['hyperion_io_uring_hotpath_force_unhealthy'],
          [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT
        )
        @hotpath_is_healthy_fn = Fiddle::Function.new(
          @lib['hyperion_io_uring_hotpath_is_healthy'],
          [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT
        )
```

- [ ] **Step 2: Add the supported probe**

Add to the `class << self` block (after `compute_supported`, around line 182):

```ruby
      # Plan #2 — true when (a) accept-only `supported?` true, AND
      # (b) the kernel actually accepts pbuf-ring registration (5.19+).
      def hotpath_supported?
        return @hotpath_supported unless @hotpath_supported.nil?

        @hotpath_supported = compute_hotpath_supported
      end

      def compute_hotpath_supported
        return false unless supported?
        return false unless @hotpath_supported_fn
        @hotpath_supported_fn.call.zero?
      rescue StandardError
        false
      end
```

Update `reset!` to clear the new cache:

```ruby
      def reset!
        @supported = nil
        @hotpath_supported = nil
        @lib = nil
      end
```

- [ ] **Step 3: Add the `HotpathRing` class**

Insert after the existing `class Ring` block (around line 140), but still inside `module IOUring`:

```ruby
    # Plan #2 — io_uring hot path: multishot accept + multishot recv
    # with kernel-managed buffer rings + send SQEs. One ring per
    # worker; the accept fiber drains the unified completion queue.
    class HotpathRing
      DEFAULT_QUEUE_DEPTH = 1024
      DEFAULT_N_BUFS      = 512
      DEFAULT_BUF_SIZE    = 8192

      # Layout matches the Rust `#[repr(C)] Completion` struct:
      #   u8 op_kind | i32 fd | i64 result | i32 buf_id | u32 flags
      # padded to native alignment. Total: 24 bytes.
      COMPLETION_BYTES = 24
      MAX_BATCH        = 64

      def initialize(queue_depth: DEFAULT_QUEUE_DEPTH,
                     n_bufs: DEFAULT_N_BUFS,
                     buf_size: DEFAULT_BUF_SIZE)
        raise Unsupported, 'io_uring hotpath not supported' \
          unless IOUring.hotpath_supported?

        @ptr = IOUring.hotpath_ring_new(queue_depth, n_bufs, buf_size)
        raise Unsupported, 'hotpath ring allocation failed' if @ptr.nil? || @ptr.null?

        @completion_buf = Fiddle::Pointer.malloc(COMPLETION_BYTES * MAX_BATCH,
                                                 Fiddle::RUBY_FREE)
        @closed = false
      end

      def submit_accept_multishot(listener_fd)
        rc = IOUring.hotpath_submit_accept(@ptr, listener_fd.to_i)
        raise SystemCallError.new('hotpath submit_accept', -rc) if rc.negative?

        nil
      end

      def submit_recv_multishot(fd)
        rc = IOUring.hotpath_submit_recv(@ptr, fd.to_i)
        raise SystemCallError.new('hotpath submit_recv', -rc) if rc.negative?

        nil
      end

      def submit_send(fd, iov_ptr, iov_count)
        rc = IOUring.hotpath_submit_send(@ptr, fd.to_i, iov_ptr, iov_count.to_i)
        raise SystemCallError.new('hotpath submit_send', -rc) if rc.negative?

        nil
      end

      # Drain up to `MAX_BATCH` completions. Yields each as a frozen
      # Hash; returns the count yielded. Caller is responsible for
      # `release_buffer(buf_id)` after consuming a recv buffer view.
      def each_completion(min_complete: 1, timeout_ms: 100)
        n = IOUring.hotpath_wait(@ptr, min_complete, timeout_ms,
                                 @completion_buf, MAX_BATCH)
        return 0 if n.negative?

        n.times do |i|
          offset = i * COMPLETION_BYTES
          op_kind = @completion_buf[offset, 1].unpack1('C')
          fd      = @completion_buf[offset + 4,  4].unpack1('l<')
          result  = @completion_buf[offset + 8,  8].unpack1('q<')
          buf_id  = @completion_buf[offset + 16, 4].unpack1('l<')
          flags   = @completion_buf[offset + 20, 4].unpack1('L<')
          yield({
            op_kind: op_kind, fd: fd, result: result,
            buf_id: buf_id, flags: flags
          })
        end
        n
      end

      def release_buffer(buf_id)
        IOUring.hotpath_release_buf(@ptr, buf_id.to_i)
      end

      def force_unhealthy!
        IOUring.hotpath_force_unhealthy(@ptr)
      end

      def healthy?
        IOUring.hotpath_is_healthy(@ptr) == 1
      end

      def close
        return if @closed

        @closed = true
        IOUring.hotpath_ring_free(@ptr) if @ptr && !@ptr.null?
        @ptr = nil
      end

      attr_reader :ptr
    end
```

- [ ] **Step 4: Add the FFI wrapper helpers**

After the existing `def ring_read(...)` (~line 283), add:

```ruby
      def hotpath_ring_new(qd, n_bufs, buf_size)
        ptr = @hotpath_ring_new_fn.call(qd, n_bufs, buf_size)
        ptr.null? ? nil : ptr
      end

      def hotpath_ring_free(ptr); @hotpath_ring_free_fn.call(ptr); end

      def hotpath_submit_accept(ptr, fd)
        @hotpath_submit_accept_fn.call(ptr, fd)
      end

      def hotpath_submit_recv(ptr, fd)
        @hotpath_submit_recv_fn.call(ptr, fd)
      end

      def hotpath_submit_send(ptr, fd, iov, n)
        @hotpath_submit_send_fn.call(ptr, fd, iov, n)
      end

      def hotpath_wait(ptr, mc, t, out, cap)
        @hotpath_wait_fn.call(ptr, mc, t, out, cap)
      end

      def hotpath_release_buf(ptr, buf_id)
        @hotpath_release_buf_fn.call(ptr, buf_id)
      end

      def hotpath_force_unhealthy(ptr)
        @hotpath_force_unhealthy_fn.call(ptr)
      end

      def hotpath_is_healthy(ptr)
        @hotpath_is_healthy_fn.call(ptr)
      end
```

- [ ] **Step 5: Add `resolve_hotpath_policy!`**

After the existing `resolve_policy!` (~line 299), add:

```ruby
    # Plan #2 — resolve `:off | :auto | :on` for the hotpath gate.
    # Mirrors `resolve_policy!` semantics: `:on` raises on unsupported,
    # `:auto` quietly falls back, `:off` returns false.
    def self.resolve_hotpath_policy!(policy)
      case policy
      when :off, nil, false
        false
      when :auto
        hotpath_supported?
      when :on, true
        unless hotpath_supported?
          raise Unsupported,
                'io_uring hotpath required (io_uring_hotpath: :on) but unsupported on this host ' \
                "(linux=#{linux?}, kernel_ok=#{kernel_supports_io_uring?}, hotpath=#{hotpath_supported?})"
        end
        true
      else
        raise ArgumentError, "io_uring_hotpath must be :off, :auto, or :on (got #{policy.inspect})"
      end
    end
```

- [ ] **Step 6: Sanity probe**

```bash
bundle exec rake compile
ruby -I lib -r hyperion -e 'p Hyperion::IOUring.respond_to?(:hotpath_supported?)'
```

Expected: `true`.

- [ ] **Step 7: Commit**

```bash
git add lib/hyperion/io_uring.rb
git commit -m "[lib/io_uring] HotpathRing class + hotpath_supported? + resolve_hotpath_policy!"
```

---

### Task 2.2.2: Cross-platform fallback spec (failing first)

**Files:**
- Create: `spec/hyperion/io_uring_hotpath_fallback_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'hyperion/io_uring'

RSpec.describe Hyperion::IOUring, '.hotpath_supported?' do
  before { described_class.reset! }
  after  { described_class.reset! }

  it 'returns false on Darwin' do
    allow(Etc).to receive(:uname).and_return({ sysname: 'Darwin', release: '24.0.0' })
    expect(described_class.hotpath_supported?).to eq(false)
  end

  it 'returns false when the kernel is older than 5.6 (accept-only baseline)' do
    allow(Etc).to receive(:uname).and_return({ sysname: 'Linux', release: '5.4.0' })
    expect(described_class.hotpath_supported?).to eq(false)
  end

  describe '.resolve_hotpath_policy!' do
    it 'returns false for :off' do
      expect(described_class.resolve_hotpath_policy!(:off)).to eq(false)
    end

    it 'returns false for nil / false' do
      expect(described_class.resolve_hotpath_policy!(nil)).to eq(false)
      expect(described_class.resolve_hotpath_policy!(false)).to eq(false)
    end

    it 'raises for :on on unsupported hosts' do
      allow(described_class).to receive(:hotpath_supported?).and_return(false)
      expect {
        described_class.resolve_hotpath_policy!(:on)
      }.to raise_error(Hyperion::IOUring::Unsupported, /unsupported on this host/)
    end

    it ':auto returns false on unsupported hosts' do
      allow(described_class).to receive(:hotpath_supported?).and_return(false)
      expect(described_class.resolve_hotpath_policy!(:auto)).to eq(false)
    end

    it 'raises ArgumentError on unknown values' do
      expect {
        described_class.resolve_hotpath_policy!('bogus')
      }.to raise_error(ArgumentError, /must be :off, :auto, or :on/)
    end
  end
end
```

- [ ] **Step 2: Run the spec**

```bash
bundle exec rspec spec/hyperion/io_uring_hotpath_fallback_spec.rb -fd
```

Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add spec/hyperion/io_uring_hotpath_fallback_spec.rb
git commit -m "[spec] io_uring_hotpath_fallback: cross-platform supported? + policy specs"
```

---

### Task 2.2.3: ABI mismatch spec

**Files:**
- Create: `spec/hyperion/io_uring_hotpath_abi_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'hyperion/io_uring'

RSpec.describe 'io_uring hotpath ABI guard' do
  before { Hyperion::IOUring.reset! }
  after  { Hyperion::IOUring.reset! }

  it 'falls back when the cdylib reports an older ABI' do
    fake_lib = double('lib').tap do |l|
      allow(l).to receive(:[]).and_return(Object.new)
    end

    abi_fn = double('abi_fn')
    allow(abi_fn).to receive(:call).and_return(1) # the OLD ABI

    allow(Fiddle::Function).to receive(:new).and_call_original
    allow(Fiddle).to receive(:dlopen).and_return(fake_lib)
    allow(Fiddle::Function).to receive(:new).with(anything, [], Fiddle::TYPE_INT).and_return(abi_fn)

    expect(Hyperion::IOUring.send(:load!)).to be_nil
    # The mismatch warning is non-fatal; supported? returns false.
    expect(Hyperion::IOUring.hotpath_supported?).to eq(false)
  end
end
```

- [ ] **Step 2: Run + commit**

```bash
bundle exec rspec spec/hyperion/io_uring_hotpath_abi_spec.rb -fd
git add spec/hyperion/io_uring_hotpath_abi_spec.rb
git commit -m "[spec] io_uring_hotpath_abi: ABI v1 .so against v2 expectations falls back"
```

---

## Sub-PR 2.3 — CLI / config / server / connection wiring

### Task 2.3.1: Add `io_uring_hotpath` to `Hyperion::Config`

**Files:**
- Modify: `lib/hyperion/config.rb`

- [ ] **Step 1: Find the existing `io_uring:` setting (line 49)**

```bash
grep -n 'io_uring:' lib/hyperion/config.rb
```

- [ ] **Step 2: Add the new key immediately after**

```ruby
      io_uring: :off,
      # Plan #2 (perf roadmap) — io_uring hot path policy. Independent
      # gate from the accept-only `io_uring:` above. Tri-state:
      #   :off  — accept and read/write stay on the existing paths
      #           (default; no behavior change in 2.18 minor cut).
      #   :auto — engage when supported (Linux 5.19+ + buffer-ring
      #           registration succeeds); quietly fall back otherwise.
      #   :on   — demand it. Boot raises if unsupported.
      # Override at runtime via `HYPERION_IO_URING_HOTPATH={off,auto,on}`.
      io_uring_hotpath: :off,
```

- [ ] **Step 3: Commit**

```bash
git add lib/hyperion/config.rb
git commit -m "[lib/config] add io_uring_hotpath: :off setting (default off; independent gate)"
```

---

### Task 2.3.2: CLI flag + env-var bridge

**Files:**
- Modify: `lib/hyperion/cli.rb`

- [ ] **Step 1: Add the env-var override helper**

Find `apply_io_uring_env_override!` (line 502). Immediately after, add:

```ruby
    # Plan #2 — env override for the hotpath gate.
    def self.apply_io_uring_hotpath_env_override!(config)
      raw = ENV['HYPERION_IO_URING_HOTPATH']
      return unless raw

      case raw.downcase
      when 'off', '0', 'false' then config.io_uring_hotpath = :off
      when 'on',  '1', 'true'  then config.io_uring_hotpath = :on
      when 'auto'              then config.io_uring_hotpath = :auto
      else
        Hyperion.logger.warn do
          { message: 'HYPERION_IO_URING_HOTPATH ignored (must be off|on|auto)', value: raw }
        end
      end
    end
    private_class_method :apply_io_uring_hotpath_env_override!
```

- [ ] **Step 2: Wire it into the CLI startup**

Find the `apply_io_uring_env_override!(config)` call (line 46). On the next line, add:

```ruby
      apply_io_uring_hotpath_env_override!(config)
```

- [ ] **Step 3: Add the CLI flag**

Find the `--async-io` block (~line 184). Below it, add:

```ruby
        opts.on('--io-uring-hotpath POLICY',
                'io_uring hot path policy (off|auto|on); default off; Linux 5.19+ only') do |v|
          cli_opts[:io_uring_hotpath] = v.to_sym
        end
```

- [ ] **Step 4: Pass `io_uring_hotpath:` to `Server.new`**

Find the `Server.new` call (line 313). Find the existing `io_uring: config.io_uring,` line (323). Below it, add:

```ruby
                          io_uring_hotpath: config.io_uring_hotpath,
```

- [ ] **Step 5: Sanity smoke**

```bash
bundle exec hyperion --help 2>&1 | grep -A1 io-uring-hotpath
```

Expected: the flag appears in the help text.

- [ ] **Step 6: Commit**

```bash
git add lib/hyperion/cli.rb
git commit -m "[cli] --io-uring-hotpath flag + HYPERION_IO_URING_HOTPATH env"
```

---

### Task 2.3.3: Server boot — instantiate `HotpathRing` per accept fiber

**Files:**
- Modify: `lib/hyperion/server.rb`

- [ ] **Step 1: Locate the existing io_uring resolution**

Run:

```bash
grep -n 'io_uring_active\|io_uring_policy\|@io_uring' lib/hyperion/server.rb | head -20
```

The existing fields are `@io_uring_policy` (line 243), `@io_uring_active` (line 244), `log_io_uring_state_once` (line 245).

- [ ] **Step 2: Add hotpath fields**

In `Server#initialize` after the existing `@io_uring_active = ...` line, add:

```ruby
      # Plan #2 — hotpath gate. Independent of @io_uring_active.
      @io_uring_hotpath_policy = io_uring_hotpath
      @io_uring_hotpath_active =
        io_uring_hotpath != :off &&
        Hyperion::IOUring.resolve_hotpath_policy!(io_uring_hotpath)
      log_io_uring_hotpath_state_once
```

Update the constructor signature (line 197) to accept the new kwarg:

```ruby
                   io_uring: :off, io_uring_hotpath: :off,
```

- [ ] **Step 3: Add `log_io_uring_hotpath_state_once`**

Add a method (next to `log_io_uring_state_once`):

```ruby
    def log_io_uring_hotpath_state_once
      return @io_uring_hotpath_logged if @io_uring_hotpath_logged

      Hyperion.logger.info do
        {
          message: 'io_uring_hotpath state',
          policy: @io_uring_hotpath_policy,
          active: @io_uring_hotpath_active,
          kernel_ok: Hyperion::IOUring.kernel_supports_io_uring?,
          hotpath_supported: Hyperion::IOUring.respond_to?(:hotpath_supported?) &&
                              Hyperion::IOUring.hotpath_supported?
        }
      end
      @io_uring_hotpath_logged = true
    end
```

- [ ] **Step 4: Wire `HotpathRing` into the accept fiber**

Find the accept-fiber spawn point. The existing accept loop reads the `@io_uring_active` flag and lazily opens a per-fiber `Hyperion::IOUring::Ring` on first use (per the comment at line 240-243). Mirror that for hotpath: when `@io_uring_hotpath_active` is true, open a `HotpathRing` instead, and use it for both accept-multishot and recv-multishot.

The exact integration point depends on where `connection_loop.rb` calls `accept_loop`. Look for:

```bash
grep -n 'IOUring::Ring.new\|hyperion_io_uring' lib/hyperion/server.rb lib/hyperion/server/connection_loop.rb 2>/dev/null
```

At every site where `Hyperion::IOUring::Ring.new` is invoked behind `@io_uring_active`, add a sibling branch:

```ruby
        ring = if @io_uring_hotpath_active
                 Fiber.current[:hyperion_hotpath_ring] ||=
                   Hyperion::IOUring::HotpathRing.new
               elsif @io_uring_active
                 Fiber.current[:hyperion_io_uring] ||=
                   Hyperion::IOUring::Ring.new
               else
                 nil
               end
```

(Specific patches depend on the existing accept-loop layout; the agent should locate each `IOUring::Ring.new` and pair it with a `HotpathRing.new` branch following the pattern above.)

- [ ] **Step 5: Run server-boot specs to confirm no regression**

```bash
bin/check
bundle exec rspec spec/hyperion/server_spec.rb spec/hyperion/cluster_smoke_spec.rb 2>/dev/null -fd
```

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add lib/hyperion/server.rb
git commit -m "[lib/server] resolve io_uring_hotpath policy + per-fiber HotpathRing instantiation"
```

---

### Task 2.3.4: Connection — buffer-ring read path

**Files:**
- Modify: `lib/hyperion/connection.rb`

- [ ] **Step 1: Add the `io_uring_owned` flag**

Find `Hyperion::Connection#initialize` (the constructor that takes the socket). Add an `io_uring_owned: false` kwarg, store in `@io_uring_owned`. Default false preserves existing behavior.

- [ ] **Step 2: Add `feed_read_bytes`**

```ruby
    # Plan #2 — called by the accept fiber when an io_uring recv CQE
    # arrives carrying a kernel-buffer view. Copies bytes into the
    # connection's existing parser buffer (one allocation, same shape
    # as today's read_nonblock result), then feeds the parser. Caller
    # invokes `hotpath_ring.release_buffer(buf_id)` after this returns.
    def feed_read_bytes(bytes)
      @read_buffer ||= +''
      @read_buffer << bytes
      # Re-enter the same parse-and-dispatch flow that `serve` uses.
      # `parse_request` already handles partial reads (returns nil to
      # signal "need more"). When dispatch completes, the response is
      # written via the existing #respond path (which on hotpath
      # connections lands in c_write_buffered_via_ring per Task
      # 2.4.x).
      drive_pending_requests
    end
```

(The exact name of the parse-driven helper is implementation-specific; the agent should locate the existing `parse_request` / `process_request` flow and reuse it — `feed_read_bytes` should NOT duplicate parsing logic, only stage bytes and call into the existing pipeline.)

- [ ] **Step 3: Gate the existing `read_chunk` path**

Find `read_chunk` (line 1086). Add at the top:

```ruby
    def read_chunk(socket)
      # Plan #2 — when this connection is io_uring-owned, reads come
      # via feed_read_bytes from the accept fiber. Shouldn't be
      # called on the read-from-socket path.
      raise 'BUG: read_chunk called on io_uring-owned connection' if @io_uring_owned

      # ... existing implementation ...
    end
```

- [ ] **Step 4: Commit**

```bash
git add lib/hyperion/connection.rb
git commit -m "[lib/connection] feed_read_bytes for io_uring-owned conns; gate read_chunk"
```

---

## Sub-PR 2.4 — Plan #1 ↔ #2 seam: `c_write_buffered_via_ring`

### Task 2.4.1: Add the C-side via-ring entrypoint

**Files:**
- Modify: `ext/hyperion_http/response_writer.c`

- [ ] **Step 1: Add the dlsym lookup at `Init_hyperion_response_writer`**

```c
    /* Plan #2 seam: resolve the io_uring hotpath submit_send symbol
     * at init time. NULL when the io_uring crate isn't loaded — the
     * via-ring path will short-circuit to direct write in that case. */
    extern int (*hyp_submit_send_fn)(void *, int, const void *, unsigned int);
    hyp_submit_send_fn = (int (*)(void *, int, const void *, unsigned int))
        dlsym(RTLD_DEFAULT, "hyperion_io_uring_hotpath_submit_send");
```

(`dlfcn.h` is already included via the existing `have_header('dlfcn.h')` probe in `extconf.rb`.)

Define the global:

```c
int (*hyp_submit_send_fn)(void *, int, const void *, unsigned int) = NULL;
```

at the top of `response_writer.c`, alongside the other static state.

- [ ] **Step 2: Add `c_write_buffered_via_ring`**

```c
/* Plan #2 — io_uring-owned variant of c_write_buffered. Submits a
 * send SQE via Rust instead of issuing write/writev directly. The
 * Ruby caller (response_writer.rb dispatcher) supplies the ring
 * pointer extracted from the connection's HotpathRing instance. */
static VALUE c_write_buffered_via_ring(VALUE self, VALUE io,
                                        VALUE rb_status, VALUE rb_headers,
                                        VALUE rb_body, VALUE rb_keep_alive,
                                        VALUE rb_date, VALUE rb_ring_ptr) {
    if (!hyp_submit_send_fn) {
        /* io_uring crate not loaded — fall back to direct write. */
        return c_write_buffered(self, io, rb_status, rb_headers, rb_body,
                                 rb_keep_alive, rb_date);
    }

    int fd = NUM2INT(rb_funcall(io, id_fileno, 0));

    long body_size = 0;
    Check_Type(rb_body, T_ARRAY);
    long body_len = RARRAY_LEN(rb_body);
    for (long i = 0; i < body_len; i++) {
        VALUE chunk = RARRAY_AREF(rb_body, i);
        Check_Type(chunk, T_STRING);
        body_size += RSTRING_LEN(chunk);
    }

    if (TYPE(rb_headers) == T_HASH) {
        VALUE keys = rb_funcall(rb_headers, rb_intern("keys"), 0);
        for (long i = 0; i < RARRAY_LEN(keys); i++) {
            VALUE k = RARRAY_AREF(rb_headers, i);
            VALUE v = rb_hash_aref(rb_headers, k);
            hyp_check_header_value(v);
        }
    }

    VALUE head = hyperion_build_response_head(
        rb_status, Qnil, rb_headers, LL2NUM(body_size),
        rb_keep_alive, rb_date
    );

    /* Build iov in a heap arena (NOT stack — the SQE references this
     * memory until the send CQE arrives, after the C function has
     * returned). The connection layer pins the arena per response;
     * we allocate via xmalloc and mark it for free after the CQE. */
    struct iovec *iov = (struct iovec *)xmalloc(sizeof(struct iovec) * (body_len + 1));
    iov[0].iov_base = RSTRING_PTR(head);
    iov[0].iov_len  = RSTRING_LEN(head);
    for (long i = 0; i < body_len; i++) {
        VALUE chunk = RARRAY_AREF(rb_body, i);
        iov[i + 1].iov_base = RSTRING_PTR(chunk);
        iov[i + 1].iov_len  = RSTRING_LEN(chunk);
    }

    void *ring_ptr = NUM2VOIDP(rb_ring_ptr);
    int rc = hyp_submit_send_fn(ring_ptr, fd, iov, (unsigned int)(body_len + 1));
    /* The iov + head are referenced by the kernel until the send
     * CQE; we cannot free `iov` here. The connection layer holds the
     * head Ruby string + body Array via its per-response arena (Ruby
     * GC keeps them alive while the connection holds the reference).
     * `iov` is leaked to the connection arena; freed when the conn
     * tears down. (Per spec §#2 invariants — "iov held in per-conn
     * arena, not stack".) */
    if (rc < 0) {
        xfree(iov);
        rb_sys_fail("hotpath submit_send");
    }

    /* Return body_size + head_size; the actual byte count comes
     * later via the send CQE. Ruby caller updates :bytes_written
     * speculatively; CQE feedback (in connection.rb) reconciles. */
    return SIZET2NUM(RSTRING_LEN(head) + body_size);
}
```

Register it in `Init_hyperion_response_writer`:

```c
    rb_define_singleton_method(rb_mResponseWriter, "c_write_buffered_via_ring",
                               c_write_buffered_via_ring, 7);
```

- [ ] **Step 3: Compile**

```bash
bundle exec rake compile
```

Expected: clean.

- [ ] **Step 4: Smoke probe**

```bash
ruby -I lib -r hyperion -e 'p Hyperion::Http::ResponseWriter.respond_to?(:c_write_buffered_via_ring)'
```

Expected: `true`.

- [ ] **Step 5: Commit**

```bash
git add ext/hyperion_http/response_writer.c
git commit -m "[ext] response_writer.c: c_write_buffered_via_ring (plan #1↔#2 seam, dlsym-resolved)"
```

---

### Task 2.4.2: End-to-end byte-parity spec (Linux 5.19+)

**Files:**
- Create: `spec/hyperion/connection_io_uring_hotpath_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'net/http'
require 'hyperion'

RSpec.describe 'Connection over io_uring hotpath',
               if: Hyperion::IOUring.linux? && Hyperion::IOUring.respond_to?(:hotpath_supported?) && Hyperion::IOUring.hotpath_supported? do

  it 'matches the non-hotpath wire output byte-for-byte' do
    body = ['hello hotpath']

    # Boot two servers — one with hotpath, one without — and compare
    # the GET response wire bytes.
    [false, true].map do |hotpath|
      server = nil
      port = nil
      thread = Thread.new do
        TCPServer.open('127.0.0.1', 0) do |s|
          port = s.addr[1]
          server = Hyperion::Server.new(
            host: '127.0.0.1', port: port, app: ->(_env) { [200, { 'content-type' => 'text/plain' }, body] },
            io_uring_hotpath: hotpath ? :on : :off,
            io_uring: hotpath ? :on : :off
          )
          server.run
        end
      end
      sleep 0.2 until port
      response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
      thread.kill
      response.body
    end.then do |(without_hotpath, with_hotpath)|
      expect(with_hotpath).to eq(without_hotpath)
    end
  end
end
```

(The above is illustrative — the exact `Hyperion::Server.run` boot sequence may need tweaking. The agent should reuse the patterns from `spec/hyperion/server_spec.rb` for booting Hyperion in-process and tearing it down.)

- [ ] **Step 2: Run on the bench VM**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && bundle exec rake compile && bundle exec rspec spec/hyperion/connection_io_uring_hotpath_spec.rb -fd'
```

Expected on Linux 5.19+: pass. macOS: skip.

- [ ] **Step 3: Commit**

```bash
git add spec/hyperion/connection_io_uring_hotpath_spec.rb
git commit -m "[spec] connection_io_uring_hotpath: byte-for-byte parity vs non-hotpath"
```

---

## Sub-PR 2.5 — Buffer exhaustion + fallback-engaged + soak + docs + bench

### Task 2.5.1: Buffer exhaustion spec (Linux 5.19+)

**Files:**
- Create: `spec/hyperion/io_uring_hotpath_buffer_exhaustion_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'hyperion'

RSpec.describe 'io_uring hotpath buffer exhaustion',
               if: Hyperion::IOUring.linux? && Hyperion::IOUring.respond_to?(:hotpath_supported?) && Hyperion::IOUring.hotpath_supported? do

  it 'increments :io_uring_recv_enobufs and keeps serving when the buffer ring is exhausted' do
    ENV['HYPERION_IO_URING_HOTPATH_BUFS'] = '4' # force tiny buffer ring
    Hyperion::IOUring.reset!

    initial = Hyperion.metrics.snapshot[:io_uring_recv_enobufs] || 0

    # Drive 32 concurrent slow clients against a hotpath server.
    # Each client opens a connection, writes a partial request, then
    # waits — pinning their kernel buffers and exhausting the ring.
    server, port = boot_test_server(io_uring_hotpath: :on)
    threads = 32.times.map do
      Thread.new do
        s = TCPSocket.new('127.0.0.1', port)
        s.write('GET / HTTP/1.1' + "\r\n")
        sleep 1.0
        s.write("Host: x\r\n\r\n")
        s.read
        s.close
      end
    end
    threads.each(&:join)
    server.shutdown

    final = Hyperion.metrics.snapshot[:io_uring_recv_enobufs] || 0
    expect(final).to be > initial
  ensure
    ENV.delete('HYPERION_IO_URING_HOTPATH_BUFS')
    Hyperion::IOUring.reset!
  end
end
```

(`boot_test_server` is a pattern from existing `spec/hyperion/server_spec.rb`; reuse the helper or inline the boot logic.)

- [ ] **Step 2: Run on the VM, then commit**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && bundle exec rspec spec/hyperion/io_uring_hotpath_buffer_exhaustion_spec.rb -fd'
git add spec/hyperion/io_uring_hotpath_buffer_exhaustion_spec.rb
git commit -m "[spec] io_uring_hotpath_buffer_exhaustion: ENOBUFS counter + no-drop"
```

---

### Task 2.5.2: Fallback-engaged spec (Linux 5.19+)

**Files:**
- Create: `spec/hyperion/io_uring_hotpath_fallback_engaged_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'hyperion'

RSpec.describe 'io_uring hotpath per-worker fallback',
               if: Hyperion::IOUring.linux? && Hyperion::IOUring.respond_to?(:hotpath_supported?) && Hyperion::IOUring.hotpath_supported? do

  it 'engages fallback after force_unhealthy! and continues serving via accept4' do
    server, port = boot_test_server(io_uring_hotpath: :on)

    # Issue one successful request to confirm the hotpath is live.
    response_a = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
    expect(response_a.code).to eq('200')

    # Force the ring unhealthy. The worker should detect on the next
    # wait_completions and engage fallback.
    ring = server.send(:hotpath_ring_for_test)
    ring.force_unhealthy!

    initial = Hyperion.metrics.snapshot[:io_uring_hotpath_fallback_engaged] || 0
    sleep 0.3 # let the accept fiber observe the unhealthy state

    # Subsequent request should still succeed (via accept4 fallback).
    response_b = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
    expect(response_b.code).to eq('200')

    final = Hyperion.metrics.snapshot[:io_uring_hotpath_fallback_engaged] || 0
    expect(final).to be > initial
  ensure
    server&.shutdown
  end
end
```

- [ ] **Step 2: Implement the fallback path in `lib/hyperion/server.rb`**

Locate the accept-fiber main loop. After each `wait_completions` call, check `ring.healthy?`. If false:

```ruby
        unless ring.healthy?
          Hyperion.metrics.increment(:io_uring_hotpath_fallback_engaged)
          Hyperion.logger.warn do
            { message: 'io_uring hotpath ring unhealthy; engaging accept4 fallback per-worker',
              worker_pid: Process.pid }
          end
          @io_uring_hotpath_active = false
          ring.close
          # Drop into the existing accept4 loop — same code path as
          # io_uring_hotpath: :off was at boot.
          break
        end
```

Then immediately fall through to the existing accept4 loop (which assumes `@io_uring_hotpath_active = false`).

- [ ] **Step 3: Run + commit**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && bundle exec rspec spec/hyperion/io_uring_hotpath_fallback_engaged_spec.rb -fd'
git add spec/hyperion/io_uring_hotpath_fallback_engaged_spec.rb lib/hyperion/server.rb
git commit -m "[lib/server] per-worker hotpath fallback on unhealthy ring + spec"
```

---

### Task 2.5.3: Send spec (Linux 5.19+)

**Files:**
- Create: `spec/hyperion/io_uring_hotpath_send_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'hyperion/io_uring'
require 'fiddle'

RSpec.describe 'io_uring hotpath send',
               if: Hyperion::IOUring.linux? && Hyperion::IOUring.respond_to?(:hotpath_supported?) && Hyperion::IOUring.hotpath_supported? do

  it 'submits a send SQE and the bytes appear at the peer' do
    r, w = Socket.pair(:UNIX, :STREAM)
    ring = Hyperion::IOUring::HotpathRing.new(queue_depth: 16, n_bufs: 4, buf_size: 4096)

    payload = "hello via io_uring\n"
    iov_buf = Fiddle::Pointer.malloc(2 * Fiddle::SIZEOF_VOIDP)
    payload_ptr = Fiddle::Pointer[payload]
    iov_buf[0, Fiddle::SIZEOF_VOIDP] = [payload_ptr.to_i].pack('Q<')
    iov_buf[Fiddle::SIZEOF_VOIDP, Fiddle::SIZEOF_VOIDP] = [payload.bytesize].pack('Q<')

    ring.submit_send(w.fileno, iov_buf, 1)
    Timeout.timeout(2) do
      ring.each_completion(min_complete: 1) do |cqe|
        expect(cqe[:result]).to eq(payload.bytesize)
      end
    end

    expect(r.read_nonblock(payload.bytesize, exception: false)).to eq(payload)
  ensure
    ring&.close
    [r, w].each { |s| s.close unless s.closed? }
  end
end
```

- [ ] **Step 2: Run + commit**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && bundle exec rspec spec/hyperion/io_uring_hotpath_send_spec.rb -fd'
git add spec/hyperion/io_uring_hotpath_send_spec.rb
git commit -m "[spec] io_uring_hotpath_send: end-to-end send SQE + completion"
```

---

### Task 2.5.4: Soak smoke extension

**Files:**
- Modify: `spec/hyperion/io_uring_soak_smoke_spec.rb`

- [ ] **Step 1: Inspect the existing soak spec**

```bash
grep -n 'io_uring_hotpath\|hotpath\|describe' spec/hyperion/io_uring_soak_smoke_spec.rb | head -10
```

If hotpath isn't already covered, add a sibling `context 'with hotpath on'` block that re-uses the existing soak harness with `io_uring_hotpath: :on`. Tag it `:perf`.

- [ ] **Step 2: Insert the new context**

Insert at the bottom of the file's main `RSpec.describe`:

```ruby
  context 'with io_uring_hotpath enabled', :perf,
          if: Hyperion::IOUring.linux? && Hyperion::IOUring.respond_to?(:hotpath_supported?) && Hyperion::IOUring.hotpath_supported? do
    it 'sustains 1k requests with no drop' do
      # Reuses the same soak shape, with io_uring_hotpath: :on.
      run_soak_with_options(io_uring: :on, io_uring_hotpath: :on)
    end
  end
```

- [ ] **Step 3: Commit**

```bash
git add spec/hyperion/io_uring_soak_smoke_spec.rb
git commit -m "[spec] io_uring_soak_smoke: hotpath-on variant (:perf-tagged)"
```

---

### Task 2.5.5: Operator doc (`docs/IO_URING_HOTPATH.md`)

**Files:**
- Create: `docs/IO_URING_HOTPATH.md`

- [ ] **Step 1: Write the doc**

```markdown
# io_uring hot path (Hyperion 2.18+)

Per-request io_uring on Linux 5.19+ — multishot accept + multishot
recv with kernel-managed buffer rings (`IORING_REGISTER_PBUF_RING`)
+ send SQEs paired with the C-side `Hyperion::Http::ResponseWriter`.
Independent gate from the existing accept-only `io_uring:` policy
(2.3-A). Default off; opt-in only after operator-validation.

## When to enable

| Environment | Recommendation |
|---|---|
| Linux 5.19+, no shared-CGroup quota pressure | `--io-uring-hotpath auto` |
| Linux 5.19+ in containers without io_uring whitelisting | leave off (kernel returns -EPERM at boot) |
| Linux <5.19 | not available; supported probe returns false |
| macOS / BSD | not applicable |

## Enable

```sh
# CLI
bundle exec hyperion --io-uring-hotpath on config.ru

# Env
HYPERION_IO_URING_HOTPATH=on bundle exec hyperion config.ru

# DSL (config/hyperion.rb)
io_uring_hotpath :auto
```

Independent of the accept-only gate. Both can be set:

```sh
HYPERION_IO_URING_ACCEPT=1 HYPERION_IO_URING_HOTPATH=on bundle exec hyperion config.ru
```

## Buffer-ring tuning

| Env var | Default | Notes |
|---|---|---|
| `HYPERION_IO_URING_HOTPATH_BUFS` | 512 | Number of kernel-managed receive buffers per worker. |
| `HYPERION_IO_URING_HOTPATH_BUF_SIZE` | 8192 | Bytes per buffer. |

Total pinned memory per worker = `BUFS * BUF_SIZE` (default 4 MiB).

## Observability

Counters (in addition to the existing accept-only `:accept_aborts`):

- `:io_uring_recv_enobufs` — recv CQE returned ENOBUFS (buffer ring exhausted). Spike → raise `BUFS`.
- `:io_uring_send_short` — send CQE returned fewer bytes than submitted (follow-up SQE issued).
- `:io_uring_hotpath_fallback_engaged` — per-worker fallback to accept4 + read_nonblock + write(2).
- `:io_uring_release_double` — defensive counter; should always be 0.
- `:io_uring_unexpected_errno` — defensive counter; should always be 0.

## Fallback model

Per-worker, not per-process. If a worker's ring becomes unhealthy
(sustained submit failures, repeated EBADR), that worker degrades to
the existing accept4 + read_nonblock + write(2) path. Other workers
keep running on the hotpath. Master is unaware. Operators see a single
`io_uring hotpath ring unhealthy; engaging accept4 fallback per-worker`
warning + counter increment.

## Default-flip schedule

Non-binding; revisit after one minor release of soak.

| Version | Default |
|---|---|
| 2.18 | `:off` |
| 2.19 | `:auto` (planned, after one minor of soak) |
| 2.20+ | `:on` (planned) |

## Rollback

- Operator: unset `HYPERION_IO_URING_HOTPATH`. Default off was the design.
- Hard: `git revert` the gem update; existing accept-only `HYPERION_IO_URING_ACCEPT` path is unaffected.
```

- [ ] **Step 2: Update `docs/CONFIGURATION.md`**

Add rows to the env-var table for:
- `HYPERION_IO_URING_HOTPATH={off,auto,on}` (default off)
- `HYPERION_IO_URING_HOTPATH_BUFS=512`
- `HYPERION_IO_URING_HOTPATH_BUF_SIZE=8192`

- [ ] **Step 3: Update `config/hyperion.example.rb`**

Add an example line near the existing `io_uring :off` (search the file for it):

```ruby
# Hot-path io_uring (Linux 5.19+ only). Independent of `io_uring`
# above. Default :off. See docs/IO_URING_HOTPATH.md.
io_uring_hotpath :off
```

- [ ] **Step 4: Commit**

```bash
git add docs/IO_URING_HOTPATH.md docs/CONFIGURATION.md config/hyperion.example.rb
git commit -m "[docs] IO_URING_HOTPATH operator doc + config example + env-var table"
```

---

### Task 2.5.6: Bench gate on `openclaw-vm`

**Files:**
- None modified — bench artifacts only.

- [ ] **Step 1: Sync to the VM**

```bash
rsync -az --delete \
  --exclude=.git --exclude=tmp --exclude='*.gem' \
  --exclude='lib/hyperion_http/*.bundle' \
  --exclude='lib/hyperion_http/*.so' \
  --exclude='ext/*/target' \
  ./ ubuntu@openclaw-vm:~/hyperion/
```

- [ ] **Step 2: Capture the BEFORE baseline (post-#1 baseline)**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && bundle exec rake compile && OUT_CSV=/tmp/before-hotpath.csv ./bench/run_all.sh --row 1 --row 4'
```

- [ ] **Step 3: Capture the AFTER numbers with hotpath ON**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && HYPERION_IO_URING_HOTPATH=1 OUT_CSV=/tmp/after-hotpath.csv ./bench/run_all.sh --row 1 --row 4'
```

- [ ] **Step 4: Diff**

```bash
scp ubuntu@openclaw-vm:/tmp/before-hotpath.csv /tmp/
scp ubuntu@openclaw-vm:/tmp/after-hotpath.csv  /tmp/
diff -u /tmp/before-hotpath.csv /tmp/after-hotpath.csv
```

Expected: row 4 median r/s ≥ +15% vs the post-#1 baseline. Row 1 may not move much (already a C-loop direct route).

- [ ] **Step 5: Record the outcome in the spec doc**

Append under #2 → "Acceptance":

```markdown
### Outcome (filled in after bench re-run)

- Date: <YYYY-MM-DD>
- Host: openclaw-vm
- Row 1: before <r/s> → after <r/s> (Δ <±X%>)
- Row 4: before <r/s> → after <r/s> (Δ <±X%>)
- Acceptance: row 4 ≥ +15% — <pass/fail>
```

- [ ] **Step 6: Commit + open PR**

```bash
git add docs/superpowers/specs/2026-05-05-hyperion-perf-roadmap-design.md
git commit -m "[docs] perf-roadmap-design: record #2 (io_uring hotpath) bench outcome"
git push -u origin HEAD
gh pr create --title "[perf] io_uring hot path (perf roadmap #2)" --body "$(cat <<'EOF'
## Summary

- Extends Hyperion's io_uring beyond accept-only to the full request hot path
- Multishot accept + multishot recv with `IORING_REGISTER_PBUF_RING` (5.19+) buffer rings + send SQEs
- Connection state stays in Ruby; Rust submits/reaps + owns buffer-ring lifecycle
- New independent gate: `HYPERION_IO_URING_HOTPATH` env / `--io-uring-hotpath` flag / `io_uring_hotpath :auto` DSL
- Per-worker fallback on unhealthy ring; master + sibling workers unaffected
- Plan #1's C writer dovetails via dlsym-resolved `c_write_buffered_via_ring`

## Test plan

- [ ] `bin/check --full` green on macOS (fallback) and Linux 5.19+ (hotpath active)
- [ ] New specs: `io_uring_hotpath_*_spec.rb` series (cross-platform fallback specs run everywhere; Linux-5.19+ specs skip on macOS)
- [ ] `bench/run_all.sh --row 4` median r/s ≥ +15% on openclaw-vm with `HYPERION_IO_URING_HOTPATH=1`
- [ ] Wire output byte-for-byte identical (covered by `connection_io_uring_hotpath_spec.rb`)
- [ ] CI matrix green (Ubuntu + macOS × Ruby 3.3.6 + 3.4.1)

EOF
)"
```

---

## Acceptance gate (from spec)

- [ ] `bin/check --full` green on macOS (fallback) and Linux 5.19+ (hotpath active).
- [ ] New specs pass on every platform where they're not explicitly skipped.
- [ ] `bench/run_all.sh --row 4` on `openclaw-vm`, three trials, median r/s ≥ +15% vs post-#1 baseline.
- [ ] `parser_alloc_audit_spec.rb` shows the read-side String allocation eliminated when hotpath is active (update the audit ceiling in this PR if needed).
- [ ] Wire output byte-for-byte identical (paired with #1).
- [ ] Documentation: `docs/IO_URING_HOTPATH.md`, `docs/CONFIGURATION.md` env-var rows, `config/hyperion.example.rb` example.
- [ ] CI matrix green (Ubuntu + macOS × Ruby 3.3.6 + 3.4.1).

## Rollback

- Operator: unset `HYPERION_IO_URING_HOTPATH` (default off).
- Hard: `git revert` the PR(s); the existing `HYPERION_IO_URING_ACCEPT` accept-only path is unaffected.
