# Contributing to Hyperion

Thanks for considering a contribution. Hyperion aims to stay small, focused, and
faster than Puma on every realistic Ruby/Rails workload — please read the
README's benchmark section first to understand the design constraints.

## Development setup

```sh
git clone https://github.com/andrew-woblavobla/hyperion.git
cd hyperion
bundle install
bundle exec rake compile     # build the C extension
bundle exec rake             # runs compile + rspec
```

## Reporting bugs

Open an issue at https://github.com/andrew-woblavobla/hyperion/issues. Include:

- Hyperion version (`bundle exec hyperion --version` or `Hyperion::VERSION`)
- Ruby version + platform (`ruby -v`, `uname -a`)
- Minimum reproducible example (a Rack app + the curl/wrk command that
  surfaces the issue)
- Relevant log lines (Hyperion logs structured JSON to stdout by default)

## Pull requests

- Run `bundle exec rake` locally and confirm green before opening.
- Add specs for any behaviour change.
- For performance-sensitive code, include before/after numbers from
  `bench/compare.rb` (or a custom microbench).
- Keep commits focused; squash WIP commits before review.
- Match existing style: `# frozen_string_literal: true` at the top of
  every Ruby file, two-space indent, no trailing whitespace.

## Architecture cheat-sheet

- `lib/hyperion/server.rb` — accept loop, per-OS worker model.
- `lib/hyperion/connection.rb` — single connection lifecycle (read, parse,
  dispatch, write, keep-alive loop).
- `lib/hyperion/parser.rb` — pure-Ruby HTTP/1.1 parser fallback.
- `ext/hyperion_http/parser.c` — llhttp-based C extension; the default parser
  when the gem is built with the extension.
- `lib/hyperion/adapter/rack.rb` — Rack 3 env builder.
- `lib/hyperion/response_writer.rb` — HTTP/1.1 wire format.
- `lib/hyperion/http2_handler.rb` — per-stream fiber dispatch over
  `protocol-http2`.
- `lib/hyperion/master.rb` / `worker.rb` — pre-fork cluster + lifecycle hooks.
- `lib/hyperion/logger.rb` — structured logger (text/JSON, stdout/stderr split).
- `lib/hyperion/metrics.rb` — lock-free per-thread counters.
- `lib/hyperion/config.rb` — Ruby DSL config file.

## License

By contributing you agree your changes ship under the project's MIT license.
