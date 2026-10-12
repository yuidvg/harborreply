# Next version

The user explicitly requested the whole-Mail index and larger budgeted Sent corpus; these were implemented independently in v0.1.8 while production insertion remains closed. v0.1.16 removes shipped Mock/demo and app self-test modes. Next validate actual Mail/direct-ID/fullpath/local-root/ordering behavior on owner-prepared fixtures, speech hardware and owner-authenticated model quality. Test-only regressions, native build, real Mail, model quality and whole-archive performance remain separate gates.

Before claiming 300GB acceptance, measure initial/refresh throughput, query latency/recall, RAM, FTS/disk growth and failures on an owner-authorized representative archive; retain only aggregate non-content diagnostics. Add local index retention/pruning and explicit app-data removal without mutating Mail.

After measuring retrieval gaps and real-model edits:

- Confirm the user's real mail service, then implement one differential connector. Include sent/draft distinction, deletions/moves, expired history tokens, identity collisions and local-only archives. Do not implement Gmail, Graph and generic IMAP all at once.
- Extract only explicitly needed attachments, with original references and unreadable/scanned states. Keep document receipt separate from substantive verification.
- Add policy version/applicability management and user-confirmed extraction. Never treat historical mail statements as current regulations.
- Add semantic retrieval only where observed FTS/manual association failures justify it.
- Compare generated and actual sent text only after a reliable sent-mail acquisition path exists; do not learn unattended from shared mailboxes.
- If real testing shows Mail partial insertion cannot be safe, evaluate an explicit extension API in another mail client as an optional migration decision. Keep the archive/context/generator core reusable. Do not migrate automatically.
- The Apple Silicon AirDrop package now includes its Python runtime. Next verify on the recipient's macOS, obtain a Developer ID/notarization for wider distribution, and add schema migrations before incompatible persistence changes.
