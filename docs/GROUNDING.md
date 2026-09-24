# ComfyBar - grounding (what every figure means, as read and measured, 2026-09-24)

ComfyUI 0.34.0 at `~/ComfyUI`, git 77739723 (2026-08-27), venv python 3.12.13, torch
2.15.0.dev20260826, running on 127.0.0.1:8188, started by hand as `python main.py`.
Everything below was read-only against the working server on 8188; every experiment ran on a
separate scratch instance on 8199.

## 1.1 What ComfyBar relies on (file:line)

| Fact | Where |
|---|---|
| `--listen` default 127.0.0.1; bare `--listen` = `0.0.0.0,::` | comfy/cli_args.py:63 |
| `--port` default 8188 | comfy/cli_args.py:64 |
| temp dir is `rmtree`d on start AND on exit | main.py:488-491, 531, 616 |
| SIGINT -> KeyboardInterrupt -> "Stopped server" + cleanup | main.py:612-616 |
| `GET /system_stats`: ram_total/ram_free, devices[] with vram_*, versions, argv | server.py:686-737 |
| on MPS, total/free = psutil host figures | comfy/model_management.py:321-323, 1758-1759; comfy/system_memory.py:117-128 |
| psutil macOS `available = inactive + free` (free incl. speculative) | venv psutil/_psosx.py:91-105 |
| `GET /prompt` -> exec_info.queue_remaining = pending + running | server.py:747, 1283-1288; execution.py:1342-1344 |
| `GET /queue`: tuples (number, prompt_id, prompt, extra_data, outputs), sensitive 6th removed | server.py:1064-1070, 69-72 |
| `extra_data.client_id` / `create_time` set at POST /prompt | server.py:1116-1117, 1130 |
| pending order = heapq on `number` | execution.py:1262-1274 |
| `GET /api/jobs`: status filter pending,in_progress,completed,failed,cancelled; sort; limit/offset | server.py:821-917; comfy_execution/jobs.py:23-31 |
| running/pending jobs carry no start time | comfy_execution/jobs.py:186-202 |
| start/end = timestamps of execution_start / success/error/interrupted messages | comfy_execution/jobs.py:205-247 |
| interrupted -> status "cancelled", not "failed" | comfy_execution/jobs.py:240-244 |
| `POST /api/jobs/{id}/cancel` -> {"cancelled": bool}, idempotent | server.py:971-987 |
| `POST /queue {"clear": true}` wipes pending only | server.py:1146-1158 |
| `POST /interrupt {"prompt_id"}` targeted interrupt | server.py:1160-1190 |
| `POST /free {"unload_models","free_memory"}` sets flags for the worker | server.py:1192-1201 |
| websocket: `?clientId=X` pops any existing socket for X | server.py:269-276 |
| send with sid None = broadcast; sid set = that socket only (dropped if absent) | server.py:1382-1390 |
| "status" broadcast on every queue change | server.py:1396-1397 |
| prompt without client_id -> server.client_id = None -> its messages broadcast | execution.py:736-739, 683-684 |
| "executing" only sent when client_id is not None | execution.py:494-496 |
| "progress" to server.client_id | main.py:458-471 |
| "progress_state" to server.client_id | comfy_execution/progress.py:160-185 |
| console buffer: LogInterceptor keeps last 300 writes, `\r` rewrites collapse | app/logger.py:51-70, 97-104 |
| `GET /internal/logs/raw` returns that buffer ("should NOT be depended upon") | api_server/routes/internal/internal_routes.py:8-31 |
| samplers print tqdm | comfy/k_diffusion/sampling.py:194 via comfy/utils.py:1264 |
| ComfyUI ProgressBar hook alone does not print | comfy/utils.py:1304-1329 |
| A typical API client queues with a fresh `uuid4` client_id per prompt and polls /history (no websocket) | observed in queue items |
| Some clients queue with no client_id at all | observed in queue items |
| AVAILABLE is defined as free + inactive + speculative + purgeable (vm_stat terms) | ComfyBar's definition, see 1.3 |


## 1.2 The progress question - measured on 8199

| Method | Works? | Disturbs anyone? | Stable? | Verdict |
|---|---|---|---|---|
| Open a socket under the running job's client_id (read from /queue extra_data) | YES for a socketless client (E2: full progress + node) | **YES for a client that has a socket**: E1 - the "page" socket stopped receiving at 94/300 the instant ours connected, and got nothing for its next prompt after ours closed (E1b). There is no API to tell the two kinds apart. | depends on sockets dict semantics | **Not shipped** |
| ComfyBar's own socket, own clientId | gets "status" broadcasts always; full progress + node for prompts with NO client_id (E3) - e.g. a pipeline that queues without a client_id | no | public ws protocol | **Shipped** |
| `GET /internal/logs/raw` tqdm line | YES for sampler loops of ANY client (live on 8188, another client's render: `1/3 [01:06<02:13, 66.73s/it]`) | no - plain GET | /internal is declared unstable; only tqdm-printing loops | **Shipped**, labelled |
| `progress_state` | per-client, same as progress | - | - | only for own/broadcast jobs |
| /api/jobs, /queue fields | no progress fields for running jobs | no | stable | used for queue, recent, start estimate |
| history timing | only after the job ends | no | stable | used for durations |

What is therefore shown honestly for another client's job: running, who queued it (inferred,
with evidence), elapsed (derived), sampler step x/y + tqdm's pass estimate when the console
has a bar; the running NODE is shown only for broadcast/own jobs ("not visible" otherwise,
with the reason).

Elapsed for a running job = max(queued time, previous job's end), because ComfyUI runs one
prompt at a time. Checked against ComfyUI's own execution_start_time: every recorded job in
the fixtures within 1 s (unit test), and a live job queued by another client exactly (0.000 s).

## 1.3 Every figure and its verified source

| Figure | Source | Verified against |
|---|---|---|
| Server up/down | GET /queue each poll; connection refused vs timeout/error | live 8188/8199, SIGSTOP test |
| Version / Python / torch | GET /system_stats | payload |
| Uptime | kinfo_proc p_starttime of the listening pid (sys/sysctl.h) | `ps -o etimes` (unit test, +/-2 s) |
| Process memory | proc_pid_rusage ri_phys_footprint (sys/resource.h) | Apple `footprint -p`: 34 GB vs ComfyBar's 33.6 GiB for the same process |
| Listening address | lsof -iTCP:<port> -sTCP:LISTEN | lsof |
| Queue / recent / durations | GET /queue, GET /api/jobs | log "Prompt executed in 333.68 seconds" = fixture duration 333.68 s |
| Memory AVAILABLE | host_statistics64 vm_statistics64: (free_count - speculative) + inactive + speculative + purgeable | `vm_stat` per list within 2% (unit test) |
| Memory in use | hw.memsize - AVAILABLE | arithmetic on the above |
| Swap in use | sysctl vm.swapusage (struct xsw_usage, public sys/sysctl.h) | `sysctl vm.swapusage` (unit test) |
| Memory pressure | DispatchSource memory-pressure events (dispatch/source.h 0x1/0x2/0x4) since launch | Apple API; no initial level exists |

**Unverified, therefore NOT shown**
- GPU busy % - only in IORegistry "PerformanceStatistics" (undocumented).
- Live memory-pressure level at launch - `kern.memorystatus_vm_pressure_level` is not in the
  public SDK headers.
- ComfyUI's own `ram_free` / `vram_free` on MPS - psutil "available" (no purgeable); differs
  from AVAILABLE, so not displayed as memory.
- Activity Monitor's "Memory Used" - Apple publishes no formula.
