# runpods-aimusic

Running [ACE-Step 1.5](https://github.com/ace-step/ACE-Step-1.5) on a RunPod pod,
with the Gradio UI reachable from a browser.

The repo itself is cloned onto a network volume rather than baked into an image,
so the model weights (the expensive part) download once and survive pod deletion.

## Console setup

**1. Create a network volume** — Storage → Network Volume.

| Setting | Value |
|---|---|
| Datacenter | any Secure Cloud DC with the GPU you want |
| Size | 100 GB |

Network volumes are Secure Cloud only, and a pod must be in the *same*
datacenter as its volume. Roughly $0.07/GB/month, so ~$7/month for 100 GB.

**2. Deploy a pod** — pick the GPU, then attach the volume.

| Setting | Value |
|---|---|
| GPU | RTX 4090 (24 GB) |
| Template | RunPod PyTorch (any recent 2.x) |
| Network volume | the one from step 1, mounted at `/workspace` |
| Container disk | 20 GB |
| Expose HTTP Ports | `7860, 3000` |

ACE-Step scales from <4 GB VRAM to 24 GB+. Below ~6 GB it silently drops into
DiT-only mode and loses thinking mode, sample mode, and CoT captioning. 24 GB
keeps everything on and leaves room for the 4B models.

List every port you might want up front. Editing a pod restarts the container,
which wipes everything outside the network volume, so it is worth avoiding a
second edit later. The max is 10 and unused ones cost nothing.

**3. Run it** — open the pod's web terminal:

```bash
git clone https://github.com/chiragmewada/runpods-aimusic.git /workspace/bootstrap
cd /workspace/bootstrap && chmod +x *.sh
./setup.sh                                  # ~5-10 min first time, seconds after
export UI_USER=admin UI_PASS='<something-long>'
./start.sh
```

First start also downloads several GB of weights to `/workspace/models`. Later
pods reuse them.

**4. Open the UI** at `https://<POD_ID>-7860.proxy.runpod.net` and log in with
`UI_USER` / `UI_PASS`.

## Why the scripts do what they do

`start.sh` calls `acestep` directly instead of the bundled `start_gradio_ui.sh`,
which would break in two ways on a pod:

- it defaults to `SERVER_NAME=127.0.0.1`, which the RunPod proxy cannot reach —
  the service must bind `0.0.0.0`
- it blocks on an interactive `read -rp "Update now before starting? (Y/N)"`
  prompt at startup

**Auth is mandatory.** The proxy URL is public to anyone who knows the pod ID,
so `start.sh` refuses to launch without `UI_USER`/`UI_PASS`. A GPU that renders
music on demand is worth stealing.

**Paths on the volume**, all set as env vars in `start.sh`:

| Path | Holds |
|---|---|
| `/workspace/ACE-Step-1.5` | checkout + `.venv` |
| `/workspace/ACE-Step-1.5/checkpoints` | model weights |
| `/workspace/hf-cache` | HuggingFace cache (`HF_HOME`) |
| `/workspace/uv-cache` | uv package cache (`UV_CACHE_DIR`) |

**Do not set `ACESTEP_CHECKPOINTS_DIR`.** `get_checkpoints_dir()` honours it,
but the LM loader at `acestep_v15_pipeline.py:546` hardcodes
`<project_root>/checkpoints` instead. Setting it sends the DiT and the LM to
different directories: the DiT loads, the LM does not, and the failure is a
warning rather than an error. The checkout is already on the volume, so the
default path persists regardless.

## What survives a pod restart

Restarting or editing a pod replaces the container. Anything on the **container
disk** (`/root`, `/tmp`, apt packages) is gone; anything on the **network
volume** (`/workspace`) is not.

| Survives | Does not |
|---|---|
| model weights, venv, checkouts, Node, SQLite DB, generated audio | `apt` packages such as ffmpeg, anything under `/root` |

This is why the scripts clone into `/workspace` and install Node to
`/workspace/node`. Clone this repo to `/workspace/bootstrap`, not `/root`, or
you will re-clone it after every edit. `setup.sh` and `setup-ui.sh` are both
idempotent — re-running them after a restart reinstalls only the ephemeral
pieces and takes seconds.

## Alternative frontend: ace-step-ui

[fspecii/ace-step-ui](https://github.com/fspecii/ace-step-ui) is a Suno-style
React frontend for ACE-Step 1.5, with a library, stem separation, and an audio
editor.

```bash
./setup-ui.sh                               # Node + ffmpeg + npm deps
export UI_USER=admin UI_PASS='<something-long>'
./start-ui.sh
```

Then open `https://<POD_ID>-7860.proxy.runpod.net`.

**No pod edit is needed.** The UI serves on 7860 — already exposed for the
Gradio setup — and ACE-Step moves to 7861 on loopback, where it does not need
to be publicly reachable. Editing a pod restarts it, so reusing the port avoids
that entirely. Override with `UI_PORT` / `ACE_PORT` if you want them elsewhere.

`./stop-ui.sh` stops everything. Re-running `start-ui.sh` reuses a live
ACE-Step instead of reloading the models, so UI restarts cost seconds rather
than minutes of GPU time.

**Only port 3000 is needed.** Vite proxies `/api`, `/audio`, `/editor`,
`/blog`, and `/demucs-web` to the Express backend on 3001 server-side, so the
browser never addresses 3001 directly. Those cover every path the Express app
mounts. ACE-Step is bound to loopback, and nothing here uses websockets.

The one exception is stem extraction, which picks its base URL like this:

```js
const baseUrl = window.location.port === '3000'
    ? `${window.location.protocol}//${window.location.hostname}:3001`
    : window.location.origin;
```

RunPod encodes the port in the hostname, so `window.location.port` is empty,
the check fails, and it correctly falls back to same-origin. Reaching the UI at
a literal `localhost:3000` — through an SSH tunnel, say — flips that branch on
and stem extraction will try to reach 3001 directly. Use the proxy URL.

Two things `setup-ui.sh` handles that would otherwise break it:

- **`allowedHosts`.** Vite 6 rejects unrecognised `Host` headers, so every
  request through `*.proxy.runpod.net` would fail with "Blocked request. This
  host is not allowed."
- **Auth.** The upstream app assumes localhost and has no real auth — its own
  config calls the JWT *"for local session, not critical security"*. A basic-auth
  plugin gates the dev server, covering the proxied backend routes too.

Both live in a generated `vite.config.runpod.ts` that imports the upstream
config, so `git pull` in the UI checkout never conflicts.

**This UI reloads the models on every generation.** It does not generate
through the ACE-Step API — each request spawns `server/scripts/simple_generate.py`,
which imports `AceStepHandler` and loads the models itself in a fresh process.
So expect several minutes per song, every song.

`start.sh` (Gradio) keeps the models resident and generates in seconds after
the initial load. **For actually producing music, Gradio is the faster tool**;
this UI is worth it for the library, stem separation, and editor.

Because of that, `start-ui.sh` stops the ACE-Step server rather than keeping it
warm: a resident server holds ~20GB of VRAM that the spawned process then
cannot allocate, and generation fails with `CUDA error: out of memory` on a
24GB card. Only the model-list endpoint is lost, and the frontend falls back
from it. `WITH_ACESTEP=1` keeps it running, which will OOM on 24GB.

**When it does run ACE-Step, it does so without Gradio auth, bound to `127.0.0.1`.**
`@gradio/client` cannot authenticate against a password-protected Gradio app,
so the protection moves to the frontend instead. Loopback keeps 7860 off the
public proxy no matter which ports the pod exposes. The consequence: while
`start-ui.sh` is running the Gradio UI is not reachable from a browser. Use
`start.sh` for that — run one or the other, not both.

`--enable-api` mounts the REST routes onto the Gradio port rather than 8001, so
one process serves both and the model loads once. Two processes would not fit
in 24 GB.

## Known limits

**The 100-second proxy timeout.** RunPod's HTTP proxy sits behind Cloudflare,
which kills any connection idle for 100s (error 524). Gradio's queue streams
progress so generation usually survives, but long jobs on a busy GPU can trip
it. If that happens: expose a TCP port instead of HTTP, or drive the REST API
(`--enable-api`, port 8001) and poll for results.

**"Unknown LM model: acestep-5Hz-lm-1.7B".** The 1.7B LM is listed in
`MAIN_MODEL_COMPONENTS` — it ships inside the `ACE-Step/Ace-Step1.5` repo — but
not in `SUBMODEL_REGISTRY`, so `ensure_lm_model()` cannot fetch it on its own
and reports it as unknown. It only arrives with the main model download. Only
`acestep-5Hz-lm-0.6B` and `acestep-5Hz-lm-4B` are separately downloadable.

Without the LM the service still starts and plain generation works, but
thinking mode, sample mode (generate from description), and CoT
caption/language detection all fail at request time.

## Tuning

Both are read by `start.sh` as env vars:

- `LM_MODEL` — `acestep-5Hz-lm-0.6B` / `-1.7B` (default) / `-4B`. Bigger is
  better at prompt understanding and costs VRAM.
- `DIT_MODEL` — `acestep-v15-turbo` (2B, default) or `acestep-v15-xl-turbo` (4B).

Add `--offload_to_cpu true` to `start.sh` if you hit OOM on a smaller GPU.

## Cost

Stop the pod when idle — you keep paying for the volume (~$7/month at 100 GB)
but not the GPU. Because the weights live on the volume, a restart is a couple
of minutes, not a re-download.
