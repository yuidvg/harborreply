# Distribution — Apple Silicon

正式なSparkle配布は [READMEの開発とリリース手順](../README.md#開発とリリースの流れsparkle) に従い `nix run .#deploy` を使います。以下は未公証の開発用ZIPを作る手順です。

## Build and transfer

Run from the repository root with Nix and locally installed Xcode:

```sh
nix run .#test
nix run .#package
```

v0.1.27 produces `dist/HarborReply-0.1.27-apple-silicon.zip` and a SHA-256 sidecar. The ZIP contains HarborReply.app, the Japanese installation guide and the user-started Mail acceptance checklist. No fictional mail, scenarios or test data are distributed. The application contains no runtime sample mails or fixed reply generator. Python is bundled; the recipient needs no development tools. Only arm64 is shipped, with a macOS 14 deployment target. Liquid Glass controls/cards are gated to macOS 26+; earlier systems use standard materials/buttons. The target device and macOS 14–26 remain unverified.

Packaging requires the host Apple toolchain and Python 3.12+ for safe archive extraction. The runtime is pinned and checksum-verified by `scripts/runtime.lock.json`; licenses remain in app resources. Packaging rejects stale app versions, retired trial CLI modes and mail fixtures inside app resources before downloading a runtime. Before ZIP creation it also checks the complete distribution, permits only the app and installation/acceptance instructions, and rejects `.eml`/`.mbox` files or packages anywhere. Test fixtures remain in the development repository only. Rebuilding recreates the generated app so removed resources cannot survive an earlier build.

AirDrop the ZIP to its intended owner. They extract it, move HarborReply.app to Applications and follow [FRIEND_INSTALL.md](FRIEND_INSTALL.md). This build is ad-hoc signed and not notarized. No Gatekeeper bypass or permission pregrant is performed. AirDrop transmission, target-device installation and remote deployment have not been completed by these packaging commands.

## Connection and ordinary operation

The owner opens Settings, chooses **Sign in with ChatGPT**, selects a model and explicitly enables sending selected mail excerpts to ChatGPT. Signing in alone does not enable generation. Signed-out, connecting, connected, expired, permission-needed and failed states are distinguished. Credentials are stored in the local Keychain. There is no automatic change to separately billed API generation. Real authorization, plan eligibility, refresh/revocation and generated quality require owner testing.

Select one message in Apple Mail and press the empty target island or `Control + Option + R`. The related island searches the persisted SQLite/FTS5 whole-Mail catalog. Start indexing explicitly there: native batches contain at most128 metadata rows and20 body reads, with byte-bounded commits and persisted pause/resume checkpoints. Initial indexing visits the archive; later target selection searches already-indexed data. Completed scans are snapshots rather than live synchronization. Synthetic operation/scaling measurements do not establish300GB acceptance.

Press the style island and choose an address used for your own writing. Matching genuine Sent is acquired directly, without waiting for the whole-Mail index. Shared addresses must not be chosen. Default estimated token budget is32,768; extraction accepts at most512 complete samples, checks at most4,096 headers, makes at most1,024 body attempts and returns at most64MiB of bodies/headers. Collection order is Mail's order and coverage can be capped. Quotes, duplicates and other aliases are excluded. Re-extraction offers address selection again. Extraction is local; generation receives at most3 short examples totaling4,096 bytes.

Enter the intended reply in adjustment and press Generate. Validated output can be copied immediately. Normal 「Mailに配置」 remains disabled until [MAIL_ACCEPTANCE.md](MAIL_ACCEPTANCE.md) passes. There is no sending feature. Request/revision, cancellation, account/native-ID and retained draft guards remain fail closed.

Panel-open capture is OFF by default. Enabling it can request normal OS Automation consent. Subsequent capture only uses already-running Mail with a no-prompt permission preflight, empty intent/reply, no tracked draft and an idle/non-importing/non-recording state. No idle polling or automatic Mail launch is added. Native AppleScript runs on a dedicated serial queue.

Retrieval, indexing and style extraction do not contact an external model. Private app storage has0700/0600 permissions and is not automatically encrypted. Whole-Mail bodies are stored as immutable SQLite snapshots; raw MIME and attachments are not copied. Older app-owned `.eml` snapshots remain separate. No access to Mail's private directory, mail/account mutation or sending is added.

## Error identification and acceptance

The islands expose selectable fixed operation/getter/original-number codes. Native IDs use direct retained-reference property reads, including ordered-ID checkpoints; the other6 metadata columns retain ranged reads with a per-property unsupported-event fallback. Direct reads include `SCALAR` in their location. Returned-row validation and range capability read/update have separate codes. These changes have synthetic native-event tests; the owner's reported `-1708` disappearance and its actual cause remain unverified.

Quit the older app and open v0.1.20/build21. 「HarborReplyについて」 shows version/build and the bundled public Mail Bridge fingerprint. The fingerprint describes bundled code, not cached live script or mail data. Resume indexing rather than restarting solely because of an unsupported read; a separately detected cursor/folder/count change requires updating from the start.

Build, package/signature, automated regression, actual Mail, interactive UI, speech, authenticated model quality and full-archive results remain separate in [VERIFICATION.md](VERIFICATION.md). The Mail diagnostic code is retained but its ordinary UI was removed; a user-started diagnostic path must be restored before the prepared-message matrix can be completed.

## Content-free debugging

The owner explicitly launches `open -a HarborReply --args --diagnostics`, reproduces the operation and returns only `~/Library/Logs/HarborReply/diagnostics.jsonl` and `diagnostics.previous.jsonl` by AirDrop. No automatic upload occurs. Do not send Application Support, mail exports, screenshots containing mail, Keychain exports or arbitrary system logs.

Only with an existing owner-authorized SSH account and verified host key:

```sh
scripts/watch-logs.sh owner@friend-mac.local
```

Replace the example with the authorized destination. This follows HarborReply's logs across rotation, refuses unknown host keys and does not enable Remote Login or change sharing/firewall settings. AirDrop alone does not create a live connection. No remote access has been configured or tested.
