//! `IORING_REGISTER_PBUF_RING` (Linux 5.19+) — kernel-managed receive
//! buffer pool.  The ring registers N buffers of M bytes each; the
//! kernel hands back a buffer-id in each recv CQE.  Caller borrows the
//! buffer (zero-copy view), consumes the bytes, then `release`s the
//! buffer-id back to the kernel so it can be refilled.
//!
//! Plan #2 (io_uring hot-path roadmap), Task 2.1.2.  Linux-only;
//! non-Linux builds see `stub_impl` which always returns ENOSYS from
//! `new()` so the caller can fall through to the accept4 path cleanly.
//!
//! ## Memory layout
//!
//! PBUF_RING uses a single contiguous, **page-aligned** memory region as
//! a producer/consumer ring of `io_uring_buf` entries (16 bytes each:
//! `addr:u64 | len:u32 | bid:u16 | resv:u16`).  The kernel treats
//! `ring[0].resv` as the tail counter it polls to discover newly-released
//! buffers; userspace increments it (with Release ordering) after writing
//! the entry's addr/len/bid.  The actual receive data lands in a
//! separate `backing` allocation whose slices are pointed to by the ring
//! entries.
//!
//! The ring and backing allocations are kept alive by this struct.
//! The kernel's registration holds a reference to the *ring* memory; if
//! the IoUring is dropped before this BufferRing, the registration
//! becomes stale — the caller (Task 2.1.3's `HotpathRing`) is
//! responsible for drop ordering.

#[cfg(target_os = "linux")]
mod linux_impl {
    use io_uring::{types::BufRingEntry, IoUring, squeue, cqueue};
    use std::alloc::{alloc_zeroed, dealloc, Layout};
    use std::sync::atomic::{AtomicU16, Ordering};

    /// Kernel-managed receive buffer pool for one io_uring instance.
    ///
    /// `group_id` (`bgid`) identifies the pool; recv SQEs reference it so
    /// the kernel knows which pool to pull a buffer from and return the
    /// buffer-id in `cqe.flags >> IORING_CQE_BUFFER_SHIFT`.
    pub struct BufferRing {
        /// Buffer group id passed to recv SQEs and to `register_buf_ring`.
        pub group_id: u16,
        /// Number of buffers in the ring.  Must be a power of two; the
        /// kernel enforces `ring_entries <= 32768`.
        pub n_bufs: u16,
        /// Size of each individual receive buffer in bytes.
        pub buf_size: u32,

        /// Page-aligned ring memory: N `BufRingEntry` (16 bytes each).
        /// The kernel reads from this to discover available buffers.
        /// Must stay pinned until the ring is unregistered.
        ring_ptr: *mut BufRingEntry,
        ring_layout: Layout,

        /// Backing storage for the actual receive data.  Slice `buf_id`
        /// starts at `buf_id as usize * buf_size as usize`.
        backing_ptr: *mut u8,
        backing_layout: Layout,

        /// Shadow of the tail counter.  The authoritative tail lives at
        /// `ring[0].resv` — this mirror lets `release` compute the slot
        /// index without re-reading the (volatile) kernel-shared field.
        /// AtomicU16 for forward-compatibility with a future SQPOLL path
        /// that might race; under the GVL today a Cell<u16> would suffice.
        tail: AtomicU16,
    }

    // SAFETY: BufferRing owns its raw allocations and the ring_ptr /
    // backing_ptr are not shared across threads (one ring per worker
    // process; the GVL is held during every call into this struct).
    unsafe impl Send for BufferRing {}

    impl BufferRing {
        /// Allocate the ring and backing memory, then register the buffer
        /// ring with the kernel via `IORING_REGISTER_PBUF_RING`.
        ///
        /// Returns `Err` with the OS errno on kernel rejection (e.g.
        /// `EINVAL` if `n_bufs` is not a power of two or exceeds 32768,
        /// `ENOSYS` on kernels < 5.19, `EPERM` under seccomp, etc.).
        ///
        /// # Panics
        ///
        /// Panics if `n_bufs == 0` or `buf_size == 0` (programming error).
        pub fn new(
            ring: &mut IoUring<squeue::Entry, cqueue::Entry>,
            group_id: u16,
            n_bufs: u16,
            buf_size: u32,
        ) -> std::io::Result<Self> {
            assert!(n_bufs > 0, "n_bufs must be > 0");
            assert!(buf_size > 0, "buf_size must be > 0");

            // --- Allocate the page-aligned ring entries ---
            //
            // The kernel requires the ring base address to be page-aligned.
            // Each BufRingEntry is 16 bytes (size_of::<io_uring_buf>()).
            let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) as usize };
            let ring_bytes = (n_bufs as usize) * std::mem::size_of::<BufRingEntry>();
            // Round up to a full page so the allocation is page-aligned.
            let ring_alloc_bytes = round_up(ring_bytes, page_size);
            let ring_layout = Layout::from_size_align(ring_alloc_bytes, page_size)
                .map_err(|_| std::io::Error::from_raw_os_error(libc::EINVAL))?;

            // SAFETY: layout has non-zero size and valid alignment.
            let ring_ptr = unsafe { alloc_zeroed(ring_layout) as *mut BufRingEntry };
            if ring_ptr.is_null() {
                return Err(std::io::Error::from_raw_os_error(libc::ENOMEM));
            }

            // --- Allocate the backing receive buffers ---
            let backing_bytes = (n_bufs as usize) * (buf_size as usize);
            // 64-byte alignment keeps each buffer on a cache line boundary.
            let backing_layout = Layout::from_size_align(backing_bytes, 64)
                .map_err(|_| {
                    unsafe { dealloc(ring_ptr as *mut u8, ring_layout) };
                    std::io::Error::from_raw_os_error(libc::EINVAL)
                })?;
            let backing_ptr = unsafe { alloc_zeroed(backing_layout) };
            if backing_ptr.is_null() {
                unsafe { dealloc(ring_ptr as *mut u8, ring_layout) };
                return Err(std::io::Error::from_raw_os_error(libc::ENOMEM));
            }

            // --- Populate the ring entries before registration ---
            //
            // We must fill addr/len/bid for all N slots and set the initial
            // tail (in ring[0].resv) to N so the kernel sees all buffers as
            // available immediately after registration.
            for i in 0..n_bufs {
                let buf_offset = (i as usize) * (buf_size as usize);
                // SAFETY: ring_ptr is valid for n_bufs entries.
                let entry = unsafe { &mut *ring_ptr.add(i as usize) };
                entry.set_addr(unsafe { backing_ptr.add(buf_offset) } as u64);
                entry.set_len(buf_size);
                entry.set_bid(i);
            }
            // Write the initial tail into ring[0].resv.  The kernel begins
            // reading from tail=0, so setting tail=n_bufs makes all N
            // buffers available (the ring wraps modulo n_bufs).
            // SAFETY: ring_ptr is valid; BufRingEntry::tail returns a pointer
            // into the first entry's resv field.
            unsafe {
                let tail_ptr = BufRingEntry::tail(ring_ptr) as *mut u16;
                tail_ptr.write_volatile(n_bufs);
            }

            // --- Register with the kernel ---
            //
            // io-uring 0.6.4: `Submitter::register_buf_ring(ring_addr, ring_entries, bgid)`.
            // The kernel holds the registration until `unregister_buf_ring` or ring close.
            unsafe {
                ring.submitter()
                    .register_buf_ring(ring_ptr as u64, n_bufs, group_id)
                    .map_err(|e| {
                        // Free allocations on registration failure.
                        dealloc(backing_ptr, backing_layout);
                        dealloc(ring_ptr as *mut u8, ring_layout);
                        e
                    })?;
            }

            Ok(BufferRing {
                group_id,
                n_bufs,
                buf_size,
                ring_ptr,
                ring_layout,
                backing_ptr,
                backing_layout,
                // Mirror of the tail we just wrote.
                tail: AtomicU16::new(n_bufs),
            })
        }

        /// Borrow a read-only view into the kernel-filled buffer `buf_id`.
        ///
        /// The slice is valid until the next `release(buf_id)` call — the
        /// kernel may overwrite the memory the moment the buffer is released.
        /// Callers **must not** hold the slice across fiber yield points or
        /// after calling `release`.
        ///
        /// # Safety
        ///
        /// - `buf_id` must be a valid id returned by a recv CQE on this ring.
        /// - `len` must be `<= buf_size` (the kernel writes at most `buf_size`
        ///   bytes).
        pub unsafe fn borrow(&self, buf_id: u16, len: usize) -> &[u8] {
            debug_assert!((buf_id as usize) < (self.n_bufs as usize));
            debug_assert!(len <= self.buf_size as usize);
            let offset = (buf_id as usize) * (self.buf_size as usize);
            // SAFETY: backing_ptr is valid for the full backing allocation;
            // offset is within range by the invariants above.
            std::slice::from_raw_parts(self.backing_ptr.add(offset), len)
        }

        /// Release `buf_id` back to the kernel.
        ///
        /// Re-writes the ring entry (addr/len/bid) and increments the tail
        /// counter.  No syscall is required — the kernel polls the tail in
        /// shared memory.
        pub fn release(&self, buf_id: u16) {
            // Shadow tail is purely local state under the GVL; Relaxed is
            // sufficient. The cross-domain ordering with the kernel is
            // enforced by the explicit Release fence below before the
            // tail-pointer store.
            let shadow_tail = self.tail.fetch_add(1, Ordering::Relaxed);
            let slot = (shadow_tail as usize) & (self.n_bufs as usize - 1);

            // Re-publish the buffer at the slot.
            let buf_offset = (buf_id as usize) * (self.buf_size as usize);
            // SAFETY: ring_ptr is valid; slot < n_bufs by the mask above.
            unsafe {
                let entry = &mut *self.ring_ptr.add(slot);
                entry.set_addr(self.backing_ptr.add(buf_offset) as u64);
                entry.set_len(self.buf_size);
                entry.set_bid(buf_id);
            }

            // Store-Release barrier: the slot writes above MUST be visible
            // to the kernel before the tail increment is. write_volatile
            // alone is not a barrier on ARM (DMB ST is needed); on x86 TSO
            // makes this redundant but the fence is free there. Without
            // this fence, ARM kernels could observe the tail increment
            // before the slot writes and pick up stale buffer pointers.
            // Mirrors liburing's io_uring_buf_ring_advance which uses
            // smp_store_release on the tail.
            std::sync::atomic::fence(Ordering::Release);
            // SAFETY: ring_ptr is valid; tail() points to ring[0].resv.
            unsafe {
                let tail_ptr = BufRingEntry::tail(self.ring_ptr) as *mut u16;
                // wrapping_add handles u16 overflow correctly (the kernel
                // also uses wrapping arithmetic on this counter).
                tail_ptr.write_volatile(shadow_tail.wrapping_add(1));
            }
        }

        /// Accessors for callers that need read-only metadata.
        pub fn group_id(&self) -> u16 { self.group_id }
        pub fn n_bufs(&self) -> u16 { self.n_bufs }
        pub fn buf_size(&self) -> u32 { self.buf_size }
    }

    impl Drop for BufferRing {
        fn drop(&mut self) {
            // CRITICAL CONTRACT for HotpathRing (Task 2.1.3):
            //
            // Before this Drop runs, the owner MUST have called
            // `ring.submitter().unregister_buf_ring(self.group_id)` on the
            // associated IoUring, OR have dropped the IoUring (which closes
            // the ring fd and tears down the registration kernel-side).
            //
            // Otherwise the kernel retains a registration pointing to the
            // memory we are about to free, and the next multishot recv CQE
            // can write into freed userspace memory — a kernel-side
            // use-after-free, NOT a benign leak.
            //
            // HotpathRing's own Drop impl must enforce the order:
            //   1. unregister_buf_ring(group_id)
            //   2. drop(BufferRing)        ← this Drop runs here
            //   3. drop(IoUring)
            //
            // SAFETY: backing_ptr / ring_ptr / *_layout are valid; the
            // owner has guaranteed (per contract above) that the kernel
            // is no longer accessing this memory.
            unsafe { dealloc(self.backing_ptr, self.backing_layout) };
            unsafe { dealloc(self.ring_ptr as *mut u8, self.ring_layout) };
        }
    }

    /// Round `n` up to the nearest multiple of `align` (which must be a
    /// power of two).
    #[inline]
    fn round_up(n: usize, align: usize) -> usize {
        (n + align - 1) & !(align - 1)
    }
}

// ===== Non-Linux stub =====
//
// On Darwin / BSD the entire io-uring dep is gated out; we compile a
// zero-cost stub that always returns ENOSYS from `new()`.  The Ruby
// caller probes with `IOUring.supported?` before reaching this code
// in practice, but the stub ensures the macOS cdylib links cleanly.

#[cfg(not(target_os = "linux"))]
mod stub_impl {
    /// Non-Linux stub — never instantiated in practice.
    pub struct BufferRing {
        pub group_id: u16,
        pub n_bufs: u16,
        pub buf_size: u32,
    }

    impl BufferRing {
        pub fn new(
            _ring: &mut (),
            _group_id: u16,
            _n_bufs: u16,
            _buf_size: u32,
        ) -> std::io::Result<Self> {
            Err(std::io::Error::from_raw_os_error(38)) // ENOSYS
        }

        /// SAFETY: never called on non-Linux (new() always errors first).
        pub unsafe fn borrow(&self, _buf_id: u16, _len: usize) -> &[u8] {
            &[]
        }

        pub fn release(&self, _buf_id: u16) {}

        pub fn group_id(&self) -> u16 { self.group_id }
        pub fn n_bufs(&self) -> u16 { self.n_bufs }
        pub fn buf_size(&self) -> u32 { self.buf_size }
    }
}

#[cfg(target_os = "linux")]
pub use linux_impl::BufferRing;
#[cfg(not(target_os = "linux"))]
pub use stub_impl::BufferRing;
