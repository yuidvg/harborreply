# HarborReply

- Read `CODEX_TASK.md` in full and `docs/PROGRESS.md` before changing behavior.
- No email sending, deleting, moving, marking read, or changing account settings.
- Use fictional `.invalid` fixtures only. Never read real Mail data or expose it in tools, Git, screenshots or services without separate explicit permission.
- Do not access `~/Library/Mail`. Mail diagnostics must be explicitly started by the user in the app on a prepared test message.
- Run `scripts/test.sh` and `scripts/build-app.sh`. Preserve fail-closed insertion and request/revision checks.
- Prefer the repository Nix workflows (`nix develop`, `nix run .#test`, `nix run .#build`, `nix run .#deploy`). Native builds still require host Xcode. Never change global nix-darwin settings or put mail, credentials or private runtime state in the Nix store.
- Keep synthetic scaling/complexity regression checks in ordinary tests; record measured sizes and operation counts, without claiming 300GB acceptance from small fixtures.
- Keep unit/regression tests, build, Mail GUI, speech, real-model quality and full-archive results distinct. Test-only mocks/fixtures are allowed. No fictional mail, fabricated style examples, Mock/demo generation or app self-test modes in the product/distribution; synthetic data belongs only in tests and performance tools.
- Record deviations in `docs/ARCHITECTURE.md` and unresolved work in `docs/PROGRESS.md`.
