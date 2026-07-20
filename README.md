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
| Expose HTTP Ports | `7860` |

ACE-Step scales from <4 GB VRAM to 24 GB+. Below ~6 GB it silently drops into
DiT-only mode and loses thinking mode, sample mode, and CoT captioning. 24 GB
keeps everything on and leaves room for the 4B models.

**3. Run it** — open the pod's web terminal:

```bash
git clone https://github.com/chiragmewada/runpods-aimusic.git /root/bootstrap
cd /root/bootstrap && chmod +x *.sh
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
