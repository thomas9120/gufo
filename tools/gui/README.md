# Local Gufo launcher

A small browser control panel for one Gufo text server. Select existing model
files, configure a curated set of server and sampler options, save named presets,
and start or stop inference. The engine remains a separate executable.

## Start on Windows

Build the native executable first; see the
[Windows instructions](../../docs/WINDOWS.md) for the toolchain and commands.
Then double-click **[launch-gui.bat](../../launch-gui.bat)** in the repository
folder, or create a desktop shortcut to it. If startup fails, the terminal stays
open so you can read the error.

You can still launch from a terminal and pass options:

```powershell
.\launch-gui.bat -Port 8090
```

The first run creates `build/gui-env` and installs Flask and Waitress. Subsequent
runs reuse it; changed requirements or a failed package import trigger a dependency
reinstall. The launcher verifies imports before marking the environment ready. The
launcher opens at **http://127.0.0.1:8090**. Keep its terminal open.

1. Choose your **models folder**, then select a main GGUF. Browse into subfolders
   or paste a full path. Split models appear once; select their first shard.
2. Choose the **Model family**, then **Speculative decoding**: **Off**, **MTP**
   for Flash-Next, or **DFlash2** for Qwen3.8-27B. MTP uses Flash-Next's matching shared Q8_0 sidecar;
   DFlash2 uses a matching Qwen3.8-27B DFlash2 draft. Selecting a file does not
   change the mode. The picker shows local files; Gufo still decides which
   models and tensor formats it supports.
3. Optionally choose a **vision projector**. A blank field means **auto-detect**,
   not disabled vision. An explicitly selected incompatible projector fails
   during model loading.
4. Check the **Gufo executable**. It defaults to this checkout's
   `build/windows-gpu/gufo.exe`, then `build/windows-cpu/gufo.exe` or
   `build/release/gufo.exe`; another built copy can be selected. Leave that
   executable alongside its runtime DLLs and kernel libraries.
5. Adjust settings, click **Save preset** (or **Save as…** for a new name), then **Start Gufo**. Wait for
   **Ready**, and connect your chat client to the displayed API address and model
   name. The defaults are `http://127.0.0.1:8080/v1` and `gufo`.

The launcher starts with 32K context, one session, a 2,048-token output limit,
and Flash-Next thinking sampler values (temperature 1, top-p 0.95, top-k 20,
min-p 0). These are editable launcher defaults, not universal model settings.
**Default thinking level** offers Auto, Low, Medium, and Xhigh. Auto omits
`--reasoning-effort`, leaving Qwen's default of xhigh. The other levels set a
server default that clients can override per request. The selection is saved;
when Thinking is Off, the level is disabled and its flag is omitted.
Changing the thinking controls does not rewrite your sampler settings. API
clients can override the server's generation defaults per request.

Settings live in `%LOCALAPPDATA%\Gufo\launcher.json`. Saving is explicit and
works while the engine is running. **Start** uses the current form without saving
it. Reopening the launcher restores the last saved preset without loading a model.

Choose a **Launch preset**, then click **Load preset** to apply its complete model configuration: model and
sidecar paths, API model name, context, sessions, sampling, reasoning, and
speculative options. **Save preset** updates it; **Save as…** creates an independent
copy. Save, Rename, and Delete act on the loaded preset, identified below the buttons.
**Rename** keeps its identity and **Delete** removes only the preset, never
model files. At least one preset must remain. Switching or deleting with unsaved
edits offers Save, Discard, or Cancel. Selecting a preset leaves the form unchanged
until you click **Load preset**. Loading does not save or start the server; only
choosing Save in the unsaved-edits prompt writes changes to disk. Preset names
must be unique, and up to 100 presets can be saved.

**Back up all…** downloads every saved preset as one `gufo-presets-<date>.json`
file (unsaved form edits are not included). **Import…** adds the presets from such
a file; existing presets are never changed or replaced, and a name that is already
taken gets a numeric suffix such as `Default (2)`. The file holds only per-preset
settings, not the shared executable, models folder, API bind address, or API port,
so a backup can be imported on another machine. Model paths inside presets are
absolute, so adjust them after importing on a machine with a different layout.
The file is validated before anything is written, and the import is rejected
whole if any preset is invalid or the 100-preset limit would be exceeded.

The executable, models folder, API bind address, and API port are shared across presets. **Save
preset** and **Save as…** also save these shared values. The form describes the
next launch; the Server panel separately identifies the running preset and
whether it launched with unsaved changes. Saving, renaming, or deleting a preset
does not change a running process. Concurrent edits from a stale browser tab are
rejected; reload that tab before saving again.

The Server panel also shows the engine's actual loaded model path, build revision,
per-session context and Vision on/off capability from `/props`. These values come
through the launcher's same-origin status endpoint, independently of the next-launch
form, and refresh with the metrics. Missing fields or an unavailable `/props` show
dashes; stopping, restarting or disconnecting clears the reported identity.

Choosing or entering a different main model clears sidecars and resets speculative
decoding to Off. Loading a preset restores all its fields together, including its
sidecars. Changing the model family limits available speculative modes without
rewriting sampler values. **Use family defaults** explicitly applies the family's
curated defaults: Flash-Next's thinking sampler, or Qwen3.8-27B's model-default
thinking controls (leaving sampling unchanged). The **Other / existing
configuration** family preserves the existing options for unclassified models.
Family selection guides the controls; Gufo still validates artifact compatibility.

Version 1 settings, including the older MTP checkbox, appear as a **Default**
preset in memory. They are not rewritten on load. The next explicit save writes
version 2 and preserves the original as `launcher.json.bak` (an existing backup
is never replaced). Corrupt files likewise remain untouched until an explicit
save, which preserves a backup before replacement.

The **Language** selector in the top bar switches between **English** and
**简体中文** (Simplified Chinese). English is the default on a first visit.
The choice is remembered in that browser's local storage (`gufo.language`),
separately from `launcher.json` and **Save preset**. Switching languages keeps
unsaved form edits, the selected preset and open dialogs; it does not reload
the page, save settings or start/stop the engine. If storage is blocked, the
choice still applies until the page is reloaded.

Interface labels, launcher errors and runtime status are translated. Model and
preset names, paths, command previews and raw engine logs remain unchanged.
Unknown messages fall back to their English source text.

The theme button in the top bar switches between the light paper palette
and a dark navy one; cards, fields, the status pill, metrics and the file picker
all follow it. Until you press it, the launcher follows your operating-system
theme. The choice is remembered in that browser's local storage, not in
`launcher.json`, so it is not part of **Save preset** and never reaches the
engine.

**Stop** releases the launched Gufo process. Closing a browser tab keeps it
running; **Exit launcher** or Ctrl+C in the launcher terminal stops both. On
Windows, Stop terminates the owned process tree and waits for it to exit.
When the latest metrics report generating or queued requests, Stop and Exit launcher
show their counts and ask for confirmation. Cancel or Escape leaves Gufo running.
Idle servers and older executables without request counts stop without this prompt.
A Windows Job Object also terminates that tree if the launcher crashes or its
terminal is closed abruptly. Failed shutdowns remain visible and can be retried
with Stop; Exit launcher does not report success while shutdown has failed.
Termination does not flush pending disk continuation cache writes. Snapshots
already written remain reusable.

## Reasoning preservation and disk caching

**Preserve reasoning in history** defaults to on, matching Qwen's template
default. The GUI explicitly passes `--preserve-thinking on` or `off`. This is
independent of generating new thoughts with **Thinking**. It preserves reasoning
supplied by the client; it cannot recover reasoning omitted from the request.
Chat Completions clients may override it with
`chat_template_kwargs.preserve_thinking`.

**Run settings → RAM cache size (GiB)** defaults to 0 (automatic). A positive
whole number passes `--cache-ram-bytes` and replaces the engine's automatic
retained-snapshot budget, independently of disk caching. Raise it when long
chats miss the cache: on unified-memory machines (such as Strix Halo) the
automatic budget can be only a few hundred MiB once the model has loaded.
Flash-Next/MTP near 262K context needs about 16 GiB. Lower values can require
more prompt reprocessing; values larger than your free RAM push the system into
swap or the pagefile. This does not cap model weights, live context or disk
staging. The automatic default omits the flag so existing executables still
launch; raising the budget above the automatic one needs a rebuilt engine
(older engines only lower it).

**More options → Enable disk continuation cache** defaults to off. When enabled,
the GUI passes `--cache-disk`, `--cache-disk-bytes`, and
`--cache-disk-staging-bytes`. The suggested folder is `%LOCALAPPDATA%\Gufo\cache`
on Windows (`~/.cache/gufo` otherwise); Gufo creates it when needed. The disk
limit defaults to 8 GiB and the RAM staging limit to 0. Current Flash-Next and
Qwen27B component caches ignore the staging setting and stream through an internal
1 MiB buffer. On Windows, use a new folder on local NTFS; Gufo creates private
user-only ACLs and rejects existing folders with broader or unprotected ACLs,
reparse points and paths containing `..`. Completed checkpoints can be reused
after an engine restart, but may be lost after power failure. See the
[Windows cache contract](../../docs/WINDOWS.md#windows-component-disk-cache).
The older continuation store remains unavailable on Windows. Stop/Exit do not
drain pending writes.

These controls are saved per preset. Existing presets receive the defaults in
memory without rewriting the saved file. Use **Save preset** to persist changes;
they apply on the next engine launch. RAM continuation caching remains active
with disk caching off.

## Options and checks

The **Performance** section polls Gufo's `/metrics` endpoint about once per
second while the server is ready, including when requests come from another
chat client. It shows live prefill and generation tokens/second, cumulative
prompt and generated token counts for the current server run, and processing
and queued request counts. Live prefill divides changes in processed prompt
tokens by changes in the engine's cumulative measured prefill seconds
(`llamacpp:prompt_seconds_total`), excluding idle and generation intervals.
The engine publishes each token/time pair together, using the same per-step
timing as request results. Generation uses token-counter changes over the actual
interval between successful polls, including idle time. Both cover concurrent
requests. Prompt totals and live prefill exclude cached tokens. Measurements
arrive after work units return; an unfinished chunk has no speed estimate.
The generic Qwen runner can enqueue non-final chunks asynchronously, so its
existing per-step timers do not isolate GPU compute time; Flash-Next steps wait
for logits readback. These metrics do not introduce additional GPU waits.
Processing includes cache preparation and cleanup; queued requests await a
session. Live rates need two consecutive polls; failures, restarts and counter
resets clear their baseline. Both live rates show a dash when processing and queued
request counts are zero; completed speeds and cumulative totals remain visible. A prefill time-counter
reset or missing timing baseline shows a dash until a valid interval is available.
Executables with live token counters but no prefill time counter retain the
previous wall-time prefill calculation, identified by the panel's explanatory text.

The completed-request speed cards retain the latest nonzero prefill/generation
measurements; a fully cached prompt retains the previous prefill speed. Older
executables still show their completed speeds and totals, with a note to update
Gufo for live rates and request counts. Missing measurements appear as dashes,
and unavailable metrics are retried without adding process-log entries.
Restart the launcher after updating its code to load the new panel.

- The control panel binds to localhost. Gufo defaults to `127.0.0.1`; the form's
  **API bind address** accepts an IPv4 address. Use `0.0.0.0` to listen on all
  interfaces, or a local LAN IPv4 address to listen on that interface. Stop and
  restart Gufo to apply a change; saving is explicit and shared across presets.
  Network clients use this PC's LAN address, such as `http://192.168.1.10:8080/v1`,
  and Windows Firewall must allow the API port. The displayed URL uses loopback
  for `0.0.0.0`. The API has no authentication configured by this GUI, so expose
  it only to trusted networks; see [SERVER.md](../../docs/SERVER.md) for security.
  The API and control panel ports must differ. `gui.ps1 -Port 8091` changes the
  control panel's port; the form sets Gufo's port.
- `gui.ps1 -Config C:\path\launcher.json` uses another settings file.
- `gui.ps1 -NoBrowser` starts without opening a browser.
- More options exposes disk caching, sessions, penalties and Flash-Next MTP options. MTP
  options are passed only when MTP is enabled.
- DFlash2 uses the engine's adaptive defaults. MTP options, including its draft
  token cap, are not passed to DFlash2. If Qwen3.8-27B reports `MTP HTTP decoding
  requires a Qwen Flash-Next model`, select DFlash2 and choose its draft in the
  DFlash2 field.
- Start validates paths, GGUF magic, split-file presence and numeric options.
  It does not establish model/sidecar compatibility or estimate available VRAM.
- Command preview shows the next native argument list. It uses Windows native
  quoting, not PowerShell command syntax. Logs retain the last 300 lines.
- The GUI uses the current shell's environment, including any `GUFO_*`
  platform-tuning overrides.

To run directly, install `tools/gui/requirements.txt` in a Python environment
and run `python tools/gui/server.py`. The Python code also supports POSIX paths;
Windows is the locally tested launch platform.

Run the focused tests with the GUI environment:

```powershell
.\build\gui-env\Scripts\python.exe -m unittest discover -s tests/tools -p "gui_*_test.py"
```

The tests cover persistence, file selection, argument validation, real child
processes and local HTTP controls. They do not load a model or require a GPU.

The JavaScript DOM tests use the actual Flask-rendered templates and browser
modules. Install their isolated test dependency and run them with Node.js 22+:

```powershell
npm install --prefix build/gui-test-js --no-save --package-lock=false jsdom@26.1.0
node --experimental-vm-modules --test tests/tools/gui_dom_test.mjs tests/tools/gui_runtime_dom_test.mjs
```

Set `GUI_TEST_PYTHON` to a Python with the GUI requirements if the launcher
environment is elsewhere. CI runs the DOM suite on Windows and Linux. These tests
cover preset switching, sidecar restoration, file selection, runtime display,
language persistence, translation placeholders and switching with pending edits
or errors; they do not verify browser layout.

## Module boundaries

- `server.py` owns local HTTP controls, security, and the running configuration
  snapshot. `launcher_process.py` and `windows_job.py` own process lifetime.
  `engine_props.py` reads runtime identity from the owned engine.
- `settings.py` owns common defaults and validation; `models.py` owns curated
  family definitions exposed to both backend validation and the browser.
- `presets.py` owns preset operations, schema migration, and atomic JSON writes.
- `command.py` builds native Gufo arguments; `files.py` handles browsing and
  lightweight artifact checks. Neither launches a process.
- Browser modules separate form editing, presets, file picking, and runtime
  display. `app.js` wires them together through direct calls and callbacks.
  `runtime-metrics.js` and `runtime-identity.js` render engine observations;
  `busy-actions.js` confirms Stop/Exit using the shared `dialogs.js` helper.
  `i18n.js` translates English source strings using `static/locales/zh-CN.js`;
  missing entries retain the English text. Use `text()` with named placeholders
  for dynamic UI messages, and keep user data out of translation keys. Template
  text and accessible labels use `data-i18n` and `data-i18n-aria-label` attributes.
  `theme.js` remains independent and runs before first paint.

To add another text-model family, define its supported modes, reasoning levels,
and explicit defaults in `models.py`. Existing controls are reused. A genuinely
new option also needs validation, command construction, a small template section,
and focused tests. The family definitions describe UI choices, not detected
runtime capabilities. The GUI continues to manage one `serve llm` process.
