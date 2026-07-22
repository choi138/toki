# Remote Usage Sync

Toki remote sync collects supported usage sources on another computer without
mounting its filesystem or giving the macOS app shell access. It is opt-in and
has no SSH dependency: the Agent makes outbound HTTPS requests to a Hub, and the
Hub keeps only the latest encrypted snapshot for each device.

The Linux/macOS collector uses the same local reader registry as the app:
Claude Code, Codex, Hermes, Cursor, Gemini CLI, GJC, OpenCode, and OpenClaw.
`RemoteUsageReader` is deliberately excluded inside the Agent to prevent sync
loops and double uploads. Ubuntu and other Swift-supported Linux distributions
can run it; Linux Cursor uses its XDG configuration database path.

```text
Linux/macOS Agent                    Hub                         macOS Toki
toki-agent run  -- outbound HTTPS --> stores ciphertext <-- HTTPS -- Remote reader
Local usage stores per-device key     no decryption keys         Keychain keys
```

## Privacy and trust boundaries

An encrypted snapshot contains timestamps, source/model identifiers, token
counts, activity kind, and keyed opaque stream identifiers. It deliberately
excludes prompts, responses, transcript/database rows, local paths,
project/session attribution, and security-audit findings.

The Hub can see the operator-provided device name, opaque device ID, upload
time, sequence, ciphertext size, and network metadata visible to its reverse
proxy. It cannot read token counts or models. Each device receives a separate
AES-256-GCM key, so compromising one Agent does not provide keys for other
devices. The Hub owner token can provision/revoke devices and download
ciphertext, but it is not a decryption key.

The security boundary does not protect a machine from its own administrator:
root or the Agent's Unix user can read that Agent's local credential file, and a
compromised Agent can submit false usage for its own device. A compromise of the
Mac user session or Keychain can expose every device key stored by that Toki
installation. Revoke a device immediately after an endpoint compromise.

The Hub is trusted for availability and liveness metadata, but not for snapshot
confidentiality or contents. AES-GCM and the Mac's replay anchor prevent the Hub
from forging usage or rolling a device back below the greatest sequence that Mac
has accepted. A compromised Hub can still withhold a newer snapshot, replay the
latest accepted ciphertext, and forge `lastSeenAt` or interval metadata so that
the replay appears fresh. The stale-device warning therefore detects ordinary
Agent/Hub outages only while the Hub is honest; it is not an end-to-end proof
that an Agent is currently online.

## Capacity and scheduling

- Default snapshot retention: 90 days; configurable from 1 to 366 days while
  creating the pairing bundle.
- Default Agent interval: 15 minutes; configurable from 1 minute to 24 hours.
- One replaceable snapshot per device, at most 8 MiB each.
- Up to 64 active devices and 48 MiB of encrypted snapshots per Hub.
- Agent keeps at most a small bounded encrypted spool when the Hub is offline.
- Agent uses a metadata-only source signature to skip rebuilding an unchanged
  retained window. It uploads a new encrypted snapshot only when retained usage
  content changes; otherwise it sends a small authenticated heartbeat that
  updates `lastSeenAt` without incrementing the snapshot sequence.
- Initial startup and successful intervals use stable device-ID-based jitter;
  failures use bounded exponential backoff with random jitter. This spreads
  requests from machines that start together.
- macOS reuses authenticated snapshots in memory for 30 seconds so period totals
  do not trigger duplicate disk reads or decryptions. Concurrent reads share one
  in-flight fetch. It first performs an ETag-conditional sequence-manifest request
  and downloads only the bounded per-device ciphertext whose sequence changed.
  The disk cache keeps small mutable manifest metadata separate from immutable,
  sequence-addressed envelope files, so a heartbeat does not rewrite ciphertext.
- A device is stale when its last successful upload or heartbeat is older than
  four times its configured interval. A reachable Hub that reports stale device
  metadata fails visibly. During ordinary transport failures, Toki may show its
  last validated encrypted cache for up to 48 hours even after that freshness
  window passes; treat offline fallback as last-known usage.

Use 5–15 minutes for ordinary servers and 15–30 minutes for large log histories.
One-minute sync is supported, but usually adds filesystem and network work
without useful freshness. `toki-agent run` is a long-running process with
backoff and jitter; do not invoke `sync-once` every minute from cron.

Do not run an Agent for source data that the same Toki installation already
reads locally unless the overlapping local readers are disabled. Local and
Remote Devices readers are independent, so collecting the same files through
both paths double-counts their tokens and activity.

## Build on Ubuntu

Install Swift 5.9.2 or later and SQLite headers, then build the root Agent package
and the dependency-isolated nested Hub package:

```bash
sudo apt-get update
sudo apt-get install -y libsqlite3-dev
swift build -c release --product toki-agent
swift build --package-path TokiHub -c release --product toki-hub
sudo install -m 0755 .build/release/toki-agent /usr/local/bin/toki-agent
sudo install -m 0755 TokiHub/.build/release/toki-hub /usr/local/bin/toki-hub
```

Build on the target Linux distribution, or package the matching Swift runtime
with the executable. The macOS app remains an Xcode/XcodeGen build.

## Deploy the Hub

Run one Hub process for a storage directory. The supplied service binds it to a
Unix-domain socket under `/run/toki-hub`; nginx owns the public TLS endpoint.
The socket prevents other local users from impersonating the Hub during a
restart or bypassing nginx's public rate limits.

1. Create the dedicated service user and grant only the nginx worker account
   membership in its group. Ubuntu/Debian normally uses `www-data`; substitute
   the worker user configured by your distribution when different.

   ```bash
   sudo useradd --system --home /nonexistent --shell /usr/sbin/nologin toki-hub
   sudo usermod --append --groups toki-hub www-data
   ```

   Skip `useradd` if the account already exists. Do not add ordinary login users
   to the `toki-hub` group.
2. Generate a high-entropy owner token with `openssl rand -base64 48`, then
   install and edit the protected environment file:

   ```bash
   sudo install -m 0600 packaging/toki-hub.env.example /etc/toki-hub.env
   sudoedit /etc/toki-hub.env
   ```

3. Install and start the hardened service. systemd creates the private state
   directory and a group-traversable runtime directory; the service's umask
   keeps the socket accessible only to its owner and group.

   ```bash
   sudo install -m 0644 packaging/systemd/toki-hub.service /etc/systemd/system/toki-hub.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now toki-hub
   sudo systemctl status toki-hub
   ```

4. Install the Unix-socket proxy include and copy
   `packaging/nginx/toki-hub.conf.example` into nginx's `http` context. Replace
   the hostname and certificate paths, then validate and restart nginx. A full
   restart is required after changing supplementary group membership.

   ```bash
   sudo install -m 0644 packaging/nginx/toki-hub-proxy.inc.example /etc/nginx/toki-hub-proxy.inc
   sudo install -m 0644 packaging/nginx/toki-hub.conf.example /etc/nginx/conf.d/toki-hub.conf
   sudoedit /etc/nginx/conf.d/toki-hub.conf
   sudo nginx -t
   sudo systemctl restart nginx
   ```

   Keep request/header/body logging disabled; authorization headers and pairing
   bundles must never enter logs.
5. Confirm the nginx worker can reach the socket, then verify the public health
   endpoint:

   ```bash
   sudo -u www-data curl --fail --unix-socket /run/toki-hub/toki-hub.sock http://localhost/health
   curl --fail https://your-hub.example/health
   ```

   Do not bind the Hub directly to a public interface, and do not use plain HTTP
   except for loopback development.

The reverse-proxy example enforces TLS, an 8 MiB limit only for snapshot uploads,
a 64 KiB limit for every other request, connection and request rate limits,
short timeouts, HSTS, and no access log. Its snapshot-read
burst admits one manifest plus all 64 per-device snapshots during a cold sync;
the legacy bulk snapshot endpoint has a separate one-request burst and one
connection limit, and other owner operations keep a smaller burst. If another
proxy or load balancer is used, preserve those controls and the `Authorization`
header.

The Hub also enforces these memory bounds in-process: ordinary routes collect at
most 64 KiB, while only the snapshot-upload route is allowed to collect an 8 MiB
envelope. The proxy limits remain required for connection, rate, and timeout
controls.

## Connect macOS Toki

1. Open Toki settings and enter the HTTPS Hub URL and owner token under
   **Remote Sync**.
2. Enter a device name, retention days, and interval minutes.
3. Click **Copy Agent Pairing Bundle**. The bundle contains only that device's
   write token and encryption key. Toki marks the pasteboard value as concealed
   and transient, then clears it after 60 seconds or when the settings model is
   released.

Treat the bundle as a secret until pairing finishes. Other apps and macOS
Universal Clipboard may observe clipboard contents; disable cross-device
clipboard sharing or use an isolated administrative session when that is outside
your trust boundary.

Toki accepts only a root HTTPS origin (or loopback HTTP for development), with a
2048-byte URL and 253-byte host safety bound. It stores the Hub URL and owner
token together in one size-bounded macOS Keychain record, binding the bearer
credential to its origin, and stores each device encryption key in a separate
Keychain record. Cleanup enumerates those Keychain records as well as its local
device index so a crash between the two stores cannot leave an undiscoverable
device key behind. Legacy split URL/token records fail closed and
must be reconnected. Connecting from a disconnected state clears any unbound
encrypted cache, replay anchors, and leftover device keys before saving the new
Hub configuration. Local cleanup clears encrypted cache and replay anchors
before deleting Keychain credentials. If any cleanup step fails, Toki reports
the failure; retry local cleanup before reconnecting or resuming remote reads.
Existing devices whose keys were lost must be revoked and paired again.
The encrypted disk cache is also bound to the configured Hub origin so library
consumers cannot reuse one Hub's cache after changing origins.
The cache stores ciphertext envelopes plus private, plaintext routing and
freshness metadata such as device names, sequences, and check-in times; it never
stores decrypted token events. Toki refuses to disconnect while devices remain active
because deleting those keys would make their snapshots unreadable. Disconnect
performs a fresh Hub device-list check and fails safely when the Hub cannot be
reached. Revoke devices first. A device shown as **Encryption key unavailable**
must be revoked and paired again.

## Pair and run an Agent

Run the Agent as the same Unix account that owns the usage stores being
collected. Transfer the pairing bundle through a trusted administrative
channel. SSH, a cloud session manager, or a physical console can carry the
paste, but none is part of the sync protocol.

```bash
toki-agent doctor
toki-agent pair
```

Paste the bundle into `toki-agent pair`, then send EOF with Control-D. When input
is a terminal, the Agent disables echo and restores it on success or failure.
Reading from standard input keeps the credential out of shell arguments and
history. Verify one upload before enabling the service, then create only the
Agent-owned private directories required by the hardened user unit:

```bash
toki-agent sync-once
toki-agent status
install -d -m 0700 ~/.config/toki-agent ~/.local/state/toki-agent ~/.local/share/toki-agent
mkdir -p ~/.config/systemd/user
install -m 0644 packaging/systemd/toki-agent.service ~/.config/systemd/user/toki-agent.service
systemctl --user daemon-reload
systemctl --user enable --now toki-agent
systemctl --user status toki-agent
```

The supplied user service grants write access only to the default Toki Agent XDG
directories. It exposes only the supported log roots and individual SQLite
database/WAL/SHM files as optional read-only mounts; it does not expose an entire
home directory. At least one source must exist and be readable. A source that is
not installed may remain absent, while a present but unreadable or wrong-type
source makes `doctor` fail visibly. `ExecStartPre` runs that redacted check
inside the service namespace. `toki-agent status` likewise reports spool
corruption instead of showing it as zero pending uploads.

Optional mounts that do not exist at service startup do not become visible
automatically if a tool creates them later. After installing a new source, or
after a SQLite tool first creates/replaces a WAL or SHM sidecar, run
`systemctl --user daemon-reload` and restart the Agent. The next source change
builds one snapshot; an unchanged retained window returns to heartbeat-only
operation. `toki-agent full-rescan` safely clears both Codex and Claude parse
caches before forcing a verification snapshot.

If the Agent was paired with custom `XDG_CONFIG_HOME`,
`XDG_STATE_HOME`, or `XDG_DATA_HOME` values, add the same environment values to a
systemd override and update both its writable `BindPaths` and relevant read-only
source paths to those existing absolute directories before starting it. If a
tool records data outside the standard roots, add only the narrowest required
path with `BindReadOnlyPaths`, run `systemctl --user daemon-reload`, and restart
the unit. Relative XDG paths are ignored in favor of the default directories.

For a headless account that must run after logout, an administrator can enable
user lingering with `sudo loginctl enable-linger USERNAME`. The Agent opens no
inbound listener. Configuration, state, and encrypted spool files use XDG paths
with user-only permissions. After obtaining its exclusive process lock, the
Agent removes only recognized durable-write temporary files left by an abrupt
exit; this includes temporary configuration, state, parse-cache, and encrypted
spool files. Agent-owned directories must be real private directories rather
than symbolic links, and configuration, state, spool, and lock entries must be
regular files. Unexpected special files fail closed.

To replace a pairing, revoke the old device in Toki, stop the service, run
`toki-agent unpair`, and then paste the newly generated bundle. `unpair` removes
credentials and pending ciphertext but never changes source logs or databases.

## Rotation, backup, and failure behavior

- Owner token: replace `TOKI_HUB_OWNER_TOKEN`, restart the Hub, then use **Update
  Owner Token** in Toki settings. Existing Agent upload tokens are unaffected.
- Agent compromise: revoke the device, unpair or erase the Agent configuration,
  and provision a new device ID/key.
- Lost Mac Keychain: revoke and re-pair affected devices. The next full snapshot
  can restore the retained window as long as the source usage data still exists.
- Hub outage: Agent retries with exponential backoff and retains encrypted
  pending data. Toki may use a validated encrypted cache no older than 48 hours
  for ordinary network outages or server 5xx responses. That fallback can
  outlive a cached device's four-interval freshness window and represents
  last-known usage, not proof that the Agent remains online.
- TLS/auth/integrity failure: Toki fails closed. Certificate failures, redirects,
  401/403, oversized responses, conflicting snapshots, missing device keys, and
  AES-GCM authentication failures are not hidden by cached data.
- Replay/rollback protection: Toki persists the greatest accepted sequence and
  ciphertext digest separately from its 48-hour encrypted response cache. An
  older sequence or different ciphertext for an accepted sequence fails closed,
  including after an app restart, cache corruption, cache eviction, or temporary
  Keychain failure. Updating only the Hub owner token copies existing anchors to
  the new credential scope. Replay anchors are removed only after explicit
  device revocation or a confirmed disconnect.
- Backup: Hub storage contains ciphertext plus plaintext device metadata and
  credential digests. Back it up only while `toki-hub` is stopped, or use a
  filesystem snapshot that is atomic across the entire storage directory. A
  live file-by-file copy is unsupported because it can combine registry and
  snapshot generations. A Hub backup alone cannot decrypt usage; protect both
  the backup and the Mac Keychain backup according to their separate roles.

A simple stopped-service backup sequence is:

```bash
sudo systemctl stop toki-hub
sudo tar --acls --xattrs -C /var/lib -cpf /secure-backups/toki-hub.tar toki-hub
sudo systemctl start toki-hub
```

Stop the service during restore as well, restore the whole directory, preserve
ownership and mode, and start the Hub before nginx health checks resume. If an
Agent reports a sequence conflict after restoring an older Hub generation,
revoke and pair that Agent again; its retained source usage data can rebuild the
window under the new device identity.

The Hub is a single-writer service. It takes an exclusive process lock for its
storage directory and refuses to start a second process against the same path.
Storage and XDG paths must be absolute. Revocation is persisted before the
snapshot is removed; a failed deletion is reported and can be retried. On
startup, the Hub completes an interrupted snapshot commit and removes ciphertext
files that have no active record in a valid registry. If snapshot files exist
but the registry itself is missing, startup preserves them and fails closed for
operator recovery instead of inferring that they are disposable. Sequence
conflicts or unrecoverable corrupted state likewise fail closed rather than
resetting.

Configuration, state, spool, registry, snapshot, cache, and replay-anchor
replacements use a temporary file, file `fsync`, atomic rename, and
parent-directory `fsync`; durable removals also synchronize the parent
directory. File removal uses non-recursive `unlink`, and directory cleanup uses
`rmdir` only after recognized files are gone. An expected file path that contains
a directory, symbolic link, or other special file is never recursively removed;
Agent, Hub, cache, and replay-anchor code reports corruption instead. These
stores remove only recognized crash-left temporary files, and the Agent and Hub
do so while holding their exclusive process/storage lock.

If a directory `fsync` reports failure after a rename or removal has already
committed, the storage API reports that committed state explicitly. The Hub
keeps the committed generation instead of rolling one side of a
registry/snapshot update back. Before advancing the registry, it confirms the
snapshot-directory rename. It returns HTTP 503 until the relevant directory
synchronization is confirmed. Snapshot, heartbeat, and revocation retries are
idempotent, and startup recovery completes interrupted snapshot commits. Device
provisioning is intentionally not retried blindly because its upload token is
returned only once: after a provisioning 503, refresh the device list and revoke
any newly visible keyless device before creating another pairing bundle.

## Library integration

The root Swift package exposes five products:

- `TokiUsageCore`: reusable token usage values, activity-time estimation, date
  parsing, and the base local-reader protocol.
- `TokiUsageReaders`: reusable local reader implementations, pricing, parse
  caches, and the Hermes usage ledger.

- `TokiSyncProtocol`: versioned snapshots, validation, pairing types, and
  authenticated encryption.
- `TokiDurableStorage`: optional durable file replacement/removal primitives,
  with no Vapor or network dependency.
- `toki-agent`: optional outbound-only collector.

`TokiHub/Package.swift` is a dependency-isolated nested package that exposes
`toki-hub`, the optional encrypted relay/storage API. This separation keeps
Vapor and its transitive server dependencies out of the root package's
dependency graph. The Hub package uses a local `path: ".."` dependency and is
therefore intended for a repository clone, container/source build, or separately
distributed Hub binary. SwiftPM consumers cannot select this nested executable
by adding the repository root URL as a dependency.

Depending on a root library product does not start a server, collect local usage,
or make network requests. Local files are read only when a caller invokes a
reader, and existing Toki library/app users remain local-only until a Hub is
explicitly configured.

Snapshot encryption and opaque stream identifiers use distinct HKDF-derived
keys, so a value from one purpose cannot be reused as key material for the
other. The Hub receives neither derived key and stores only ciphertext plus the
minimum routing, quota, and credential-digest metadata described above.
