# frozen_string_literal: true

module Hyperion
  # Measures a worker process's resident set size (RSS) in MiB.
  # Cross-platform: uses /proc/<pid>/statm on Linux (zero subprocess) and
  # `ps -o rss= -p <pid>` everywhere else (macOS, BSD).
  module WorkerHealth
    module_function

    # Returns the worker's RSS in MiB, or nil if it can't be read (process
    # gone, ps not available, /proc not mounted). Callers must handle nil
    # gracefully — health checks must never crash the supervisor.
    def rss_mb(pid)
      if File.readable?("/proc/#{pid}/statm")
        # statm fields are in pages; column index 1 is "resident".
        # PAGE_SIZE = 4096 on x86_64 / aarch64 Linux.
        contents = File.read("/proc/#{pid}/statm")
        pages = contents.split.fetch(1).to_i
        bytes = pages * 4096
        bytes / 1024 / 1024
      else
        # Fallback: ps emits RSS in KiB.
        out = `ps -o rss= -p #{pid} 2>/dev/null`
        kib = out.strip.to_i
        return nil if kib.zero?

        kib / 1024
      end
    rescue StandardError
      nil
    end
  end
end
