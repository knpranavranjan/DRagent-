# Running OPHIRA on your PC and reaching it from anywhere

The models run in MATLAB. MATLAB runs on this PC. So the PC is the server,
and remote access is a tunnel back to it — not a copy of the app somewhere
else.

```
  your phone / laptop, anywhere
            |
            |  HTTPS
            v
   Cloudflare edge          <- public URL lives here
            |
            |  outbound connection, opened BY your PC
            v
   cloudflared on your PC
            |
            v
   ophira_server.py  :8000  <- access key checked here
            |
            |  job files on disk
            v
   MATLAB worker ->  the five models
```

## Why not Vercel, Netlify, or any other static/serverless host

Two reasons, and the first one is final.

**MATLAB.** Every stage — triage, grading, maculopathy, lesions,
calibration — is MATLAB code loading `.mat` files. No serverless platform
offers MATLAB, you cannot install it into a function image, and the licence
is bound to a machine. There is no configuration that fixes this.

**The job queue is stateful.** `ophira_server.py` writes a job file to
`data/sessions/jobs/pending/` and the browser polls until it appears in
`jobs/done/`. Serverless functions are stateless with an ephemeral disk: the
POST that creates the job and the GET that polls for it can land on
different instances with different filesystems, and the poll would never
resolve.

A static host can serve the UI. It cannot screen anything.

---

## Double-click

| file | what it does |
|---|---|
| **START OPHIRA.bat** | runs on this PC only. No key, nothing published. |
| **SHARE OPHIRA.bat** | runs it and prints a public HTTPS link. |

Keep the window open — closing it stops the worker and closes the link.

## Or one command

```
python run.py --tunnel
```

That prints, after about a minute:

```
Public link:  https://<random-words>.trycloudflare.com/?k=<key>
  agent UI    https://<random-words>.trycloudflare.com/agent.html?k=<key>
```

Open that link on any device. It is the whole setup.

`Ctrl-C` stops the server, the MATLAB worker and the tunnel together.
Closing the window does the same — the processes are in a Windows job
object with `KILL_ON_JOB_CLOSE`, so they cannot outlive the launcher.

### What the flags do

| | |
|---|---|
| `--tunnel` | publish a public HTTPS URL. Always key-gated. |
| `--key <k>` | use your key instead of a fresh random one, so the link survives a restart |
| `--port 8010` | if 8000 is taken |
| `--no-worker` | UI only; nothing gets graded |
| `--check` | test the requirements, start nothing |
| `--verify` | run the test suite against the real models |

Without `--tunnel` nothing changes: `python run.py` is still the local
kiosk on `127.0.0.1`, with no key and no network exposure.

---

## The access key

**The link is the credential.** Anyone holding it has full access — they can
upload fundus images, read every session stored on the PC, and download
reports. There are no user accounts; this is one shared secret.

So:

- Send the link over something private. Not a public repo, not a slide, not
  a screenshot in a demo video.
- The key is generated once and kept in `.ophira_key`, which is gitignored.
  It is reused on every run, so the `?k=` part of the link stays the same.
- **Delete `.ophira_key` to rotate it.** The next run mints a new one and
  every previously shared link stops working immediately.
- `--key <k>` overrides the saved one for a single run.
- `Ctrl-C` ends all access immediately.

**The key staying the same does not make the URL stay the same.** A quick
tunnel gets a random hostname every run regardless. See below.

How it is enforced, in [app/server/ophira_server.py](app/server/ophira_server.py):

- checked on **every** request — the UI, the API, the sample images, not
  just `/api/*`
- presented as `?k=` on the first visit, then a `HttpOnly` cookie, so the
  key is not in the URL of every later page
- compared with `secrets.compare_digest`, so a wrong key cannot be
  recovered one character at a time by timing the response
- a rejected request gets a bare 401 that names nothing about the system
- responses are `Cache-Control: no-store, private`

`tests/test_remote_access.py` asserts all of it, including that the default
keyless local run is unchanged.

---

## What this is not

This is a screening aid running on a PC under your control, reachable by a
link. It is **not** a hosted service and nothing here makes it one.

Before anyone other than you puts images into it, note what you are
accepting: patient images travelling over the internet to a machine in your
room, stored unencrypted in `data/sessions/images/`, on an OS whose backups
you may not control (this path is inside OneDrive — check whether it is
syncing). None of that is addressed by the access key.

The clinical limits are unchanged and are stated in the report itself and
in [DEPLOYMENT_MANIFEST.md](DEPLOYMENT_MANIFEST.md): this screens, it does
not diagnose, and every route comes from the deterministic decision engine.

---

## A stable address

`trycloudflare.com` quick tunnels get a random hostname on every run and
Cloudflare does not guarantee them. Two ways to get an address that does
not move.

### ngrok — free, no domain needed

The free tier includes one permanent domain, which is the cheapest way to
stop re-sending links. Sign up, then:

```
winget install ngrok.ngrok
ngrok config add-authtoken <token from your dashboard>
ngrok http --url=<your-static-domain>.ngrok-free.app 8000
```

Start `python run.py` (no `--tunnel`) alongside it. The address is then the
same every time and only the key matters.

### Cloudflare named tunnel — needs a domain you own

If you already have a domain on Cloudflare:

```
tools/cloudflared.exe tunnel login
tools/cloudflared.exe tunnel create ophira
tools/cloudflared.exe tunnel route dns ophira ophira.yourdomain.com
tools/cloudflared.exe tunnel run --url http://127.0.0.1:8000 ophira
```

Start `python run.py --key <your-key>` (no `--tunnel`) alongside it.

With an account you can also put **Cloudflare Access** in front, which
replaces the shared key with real email-based login and an audit trail.
That is the honest upgrade if anyone but you will use this.

## A private alternative

If you only need it on *your* devices, [Tailscale](https://tailscale.com)
is a better fit than a public URL: install it on the PC and on your phone,
run `python run.py --host 0.0.0.0`, and reach it at the PC's Tailscale IP.
No public hostname exists at all, so there is nothing to leak.

---

## Troubleshooting

**"cloudflared not installed"**
Download it to `tools/cloudflared.exe`:
`https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe`
or `winget install --id Cloudflare.cloudflared`.

**"tunnel did not open"**
See `artifacts/logs/tunnel.log`. The system keeps running locally; only
remote access failed.

**Every capture sits at "analysing"**
The MATLAB worker is not running. `artifacts/logs/worker.log` says why.
`python run.py --check` confirms whether MATLAB was found.

**"Access key required" on a link that worked**
The server restarted and issued a new key. Use the new link, or pin one
with `--key`.

**The link works but the page is slow on first load**
The tunnel adds a round trip to Cloudflare's nearest edge. Grading time is
unchanged — that happens on the PC.
