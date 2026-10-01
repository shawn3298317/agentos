# Vendored upstream prompts

These files are copied from the repositories below at the pinned commits in `../pins.json`
(sha256 checked by `test/test_mega_review.py`). They are verbatim except that `gh-axi` trims one
trailing newline, so a stored file may lack the final `\n` its upstream has. All are MIT licensed; the
copyright and license belong to the upstream authors. Refresh with `scripts/fetch_vendor.py`.

| File | Upstream | Pinned commit | Used for |
|---|---|---|---|
| `superpowers-code-reviewer.md` | [obra/superpowers](https://github.com/obra/superpowers) `skills/requesting-code-review/code-reviewer.md` | `8ca22dba9a94` | `review` lens |
| `security-review.md` | [anthropics/claude-code-security-review](https://github.com/anthropics/claude-code-security-review) `.claude/commands/security-review.md` | `0c6a49f1fa56` | `security` lens |
| `ponytail-review.md` | [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail) `skills/ponytail-review/SKILL.md` | `e3ba2aa6f1e6` | `slop` lens (advisory) |
| `rev-reviewer.md` | [WiktorStarczewski/review-council](https://github.com/WiktorStarczewski/review-council) `plugins/review-council/agents/rev-reviewer.md` | `25e0407a61f5` | two refute-first rules reused in the verifier prompt |
