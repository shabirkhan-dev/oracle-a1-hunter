# oracle-a1-hunter

Gets an Oracle Cloud **Always Free** Ampere A1 machine (up to 4 OCPUs and 24 GB RAM, free)
when your region says **"Out of host capacity"**. A GitHub Actions workflow asks Oracle every
10 minutes and tries each size in turn: 4 OCPU / 24 GB, then 2 / 12, then 1 / 6. When a slot
opens it creates the machine, opens an issue here (GitHub notifies you), and switches itself off.

The new machine gets:
- Ubuntu 24.04, a 100 GB disk and 4 GB of swap;
- **Tailscale**, so it joins your tailnet as `grid` with no port opened.

It is meant to host [Grid](https://github.com/shabirkhan-dev/grid) 24/7.

Nothing secret is in this repository. Your Oracle and Tailscale keys live in this repo's
encrypted **Actions secrets**, which are not visible even though the repo is public. Public
repositories get unlimited free Actions minutes, which is why this lives here and not in a
private repo.

## Set up (once, about 10 minutes)

### 1. An Oracle API key

In the Oracle Cloud console, open your profile (top right) → **My profile** → **API keys** →
**Add API key** → **Generate API key pair**:

1. **Download the private key** (`.pem`).
2. Click **Add**.
3. Oracle shows a *Configuration file preview*. Keep it open: it has your `user`,
   `fingerprint`, `tenancy` and `region`.

### 2. A Tailscale key for the machine

In the Tailscale admin console, go to **Settings → Keys → Generate auth key**:
- **Reusable: off.** It's used once, by this one machine.
- **Ephemeral: off.** A server should stay on your tailnet when it restarts.
- **Tags: on,** `tag:grid-server`. Add it under Access controls → Tags first, as you did for
  `grid-env`.

To reach it with Tailscale SSH, add this to your Tailscale policy's `"ssh"` rules:

```json
{ "action": "accept", "src": ["autogroup:member"], "dst": ["tag:grid-server"], "users": ["ubuntu", "root"] }
```

### 3. The secrets here

In this repo: **Settings → Secrets and variables → Actions → New repository secret**.

| Secret | Value |
|---|---|
| `OCI_USER_OCID` | `user=` from the preview |
| `OCI_TENANCY_OCID` | `tenancy=` from the preview |
| `OCI_FINGERPRINT` | `fingerprint=` from the preview |
| `OCI_REGION` | `region=` from the preview (for Singapore, `ap-singapore-1`) |
| `OCI_PRIVATE_KEY` | the whole downloaded `.pem` file, including the `BEGIN`/`END` lines |
| `SSH_PUBLIC_KEY` | your SSH public key, e.g. the contents of `~/.ssh/id_ed25519.pub` |
| `TS_AUTHKEY` | the Tailscale key from step 2 (optional, but recommended) |

Optional: `OCI_COMPARTMENT_OCID` (defaults to the tenancy) and `OCI_SUBNET_OCID` (otherwise a
small `grid-vcn` network is made the first time).

### 4. Start it

Go to **Actions → Hunt for a free Oracle A1 machine → Run workflow** to run it once and check
the log. After that it runs every 10 minutes by itself. A run that finds no capacity passes
quietly; only a real problem fails.

## Good to know

- **Idle machines can be reclaimed.** Oracle may stop an Always Free machine that stays mostly
  idle (very low CPU, memory and network use) for a week. Upgrading the account to Pay As You
  Go removes that, and you are not charged while you stay within the free limits, but it needs
  a card. Keep backups either way. Check Oracle's current terms.
- **Your home region only.** Always Free machines can only be created there.
- **Running it by hand:** with the OCI CLI signed in on your machine, run
  `SSH_KEY_FILE=~/.ssh/id_ed25519.pub OCI_TENANCY_OCID=... ./hunt.sh`.
  It exits `0` when the machine exists, `2` for "no capacity, try later", and anything else on a
  real error.
