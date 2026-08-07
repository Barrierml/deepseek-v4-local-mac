# DeepSeek V4 Flash on a 48 GB Mac

Run the full 284B-parameter **DeepSeek-V4-Flash-0731** locally on Apple
Silicon with [DwarfStar / ds4](https://github.com/antirez/ds4), Metal, and
SSD-streamed MoE experts.

This repository is an installation and operations wrapper. It does **not**
contain model weights or a copy of ds4.

## Tested Hardware

- Apple M4 Pro, 20-core GPU
- 48 GB unified memory
- Internal NVMe SSD
- macOS

The tested model is the 80.76 GiB IQ2XXS imatrix GGUF published by
`antirez/deepseek-v4-gguf`. The installer verifies its exact byte count and
SHA256 before starting the service.

## What It Installs

- A pinned ds4 build with the Metal backend
- The DeepSeek V4 Flash IQ2XXS model, downloaded with resume support
- A local OpenAI-compatible endpoint at `http://127.0.0.1:8000/v1`
- A macOS LaunchAgent with `RunAtLoad` and `KeepAlive`
- Lifecycle, health, direct-generation, thinking, and SSE tests

The model file itself is excluded from Git.

## Requirements

- Apple Silicon Mac
- At least 48 GB unified memory
- At least 90 GiB free disk space before download
- Xcode Command Line Tools
- `git`, `curl`, `make`, and Python 3

The model is I/O intensive. Use an internal SSD or a fast Thunderbolt NVMe
drive. A slow USB enclosure will severely limit generation speed.

## Install

```sh
git clone https://github.com/Barrierml/deepseek-v4-local-mac.git
cd deepseek-v4-local-mac
./bin/setup.sh
```

The download is approximately 80.76 GiB and supports resuming. Setup then
builds ds4, verifies the model, installs the LaunchAgent, starts the service,
and runs real API smoke tests.

## Use

```sh
./bin/status.sh
./bin/smoke-test.sh
./bin/stop.sh
./bin/start.sh
```

Optional browser chat console:

```sh
./bin/dashboard-start.sh
open http://127.0.0.1:8791
```

The console keeps a browser-local `messages` conversation and sends the full
message list on every turn. This lets ds4 reuse matching live KV prefixes across
turns. It also shows the latest tokens/second, generated tokens, latency,
`cached_tokens`, `cache_write_tokens`, process RSS, CPU, swap, free memory, disk
space, expert budget, and context size.

The service:

- starts automatically after login;
- restarts after an unexpected exit;
- survives terminal or agent-session shutdown.

OpenAI-compatible request:

```sh
curl http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "Explain mmap in one paragraph."}],
    "max_tokens": 256,
    "reasoning_effort": "none"
  }'
```

## Defaults

Defaults live in `config.env` and can be overridden with environment variables:

- Context: 16,384 tokens
- Default output limit: 512 tokens
- Routed-expert budget: 12 GB, including two-layer prefill headroom
- Bind address: `127.0.0.1:8000`
- One live session to control KV and working-set pressure

For example:

```sh
SERVER_PORT=9000 SERVER_CTX=8192 ./bin/start.sh
```

To keep overrides across LaunchAgent reinstalls, create a private
`config.local.env` and source it before running the lifecycle scripts. That
file is ignored by Git.

## Measured Performance

On the tested M4 Pro 48 GB machine with other desktop applications open:

- Direct decode: roughly 2.2–3.1 tokens/s
- Thinking decode: roughly 1.6–1.9 tokens/s
- Short-prompt time to first generated token: roughly 7–12 seconds
- Cold service startup: roughly 10–12 seconds

The full model is much larger than RAM, so expert reads from SSD are the main
bottleneck. Closing memory-heavy applications may improve stability and reduce
swap pressure.

## Verification

```sh
sh -n bin/*.sh tests/*.sh config.env
./tests/test-local-tools.sh
./tests/test-public-repo.sh
./bin/acceptance-test.sh
```

`acceptance-test.sh` performs:

1. model size and SHA256 verification;
2. real GGUF inspection;
3. CLI generation;
4. direct, thinking, and SSE API generation;
5. stop/restart and a second generation pass;
6. LaunchAgent and PID 1 ownership checks.
7. Dashboard API and browser chat checks, including KV cache counters.

Runtime logs, PIDs, model verification stamps, generated reports, and responses
stay under ignored directories.

## Notes

- DSpark speculative decoding is not enabled; it requires an additional support
  model and is not necessary for the base deployment.
- Multi-session batching is intentionally disabled on 48 GB machines.
- The ds4 and model repositories have their own licenses. This wrapper is MIT
  licensed.
