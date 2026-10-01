---
name: mega-review
description: First-layer gate for a GitHub PR, including drafts. Runs vendored upstream reviewers (superpowers code-reviewer, Anthropic security-review, ponytail over-engineering) as read-only lenses over multiple passes, cross-verifies every finding by majority vote against the code, and posts one review with a summary plus inline comments. Use when asked to mega-review, gate, or pre-screen a PR before human review.
---

# mega-review

A deterministic driver, not an LLM-orchestrated skill: `scripts/mega_review.py` does the orchestration, so the gate never depends on a model following instructions. Any agent harness that loads Agent Skills (`SKILL.md`) can invoke it by running the script.

## Requirements

- `python3` (stdlib only), `git`, Node 20+ for [gh-axi](https://github.com/kunchenguid/gh-axi) (`npx -y gh-axi`), and `gh` installed and authenticated for the target repo (gh-axi wraps it). All GitHub access goes through gh-axi; the skill never calls `gh` directly.
- The `claude` CLI, installed and logged in. The lenses, normalizer and verifier run as `claude -p` **whatever harness is hosting this skill**.
- Optional: set `GH_AXI` to override how gh-axi is launched (default `npx -y gh-axi`).

## Run

Paths are relative to this skill's directory.

```bash
# dry run (default): prints the review, writes artifacts, posts nothing
python3 scripts/mega_review.py https://github.com/OWNER/REPO/pull/N
# post it as one COMMENT review
python3 scripts/mega_review.py https://github.com/OWNER/REPO/pull/N --post
```

Options: `--lenses review,security,slop`, `--lens-passes 2`, `--verify-passes 3`, `--force` (re-review a head SHA already reviewed), `--max-diff-bytes`, `--keep`.
A default run makes about 9 model calls (3 lenses x 2 passes, plus 3 verifiers, plus normalizers). Expect a few dollars on a mid-size PR; lower the pass counts to cut it.
Artifacts land in `~/.cache/mega-review/runs/<owner>__<repo>-<n>-<sha8>/` (`lens-*.md`, `findings.json`, `payload.json`).

Exit codes: `0` PASS or PASS_WITH_NOTES, `10` NEEDS_ATTENTION, `11` INCOMPLETE (a lens had no successful pass, or the diff was truncated), `2` error.
A failed lens or truncated diff never reads as a pass. **Never post without the user's go-ahead**: a submitted review cannot be fully deleted.

## Pipeline

1. `gh-axi api` fetches PR metadata. A worktree is checked out detached at the PR head (cached clone under `~/.cache/mega-review/repos`). Draft state does not block a run.
2. Lenses run in parallel as `claude -p` with a read-only tool allowlist and no user or project settings loaded (so no hooks and no PR-supplied `.claude/settings.json`). Each lens runs `--lens-passes` times; later passes read the inline diff in a different file order, and candidates are unioned (recall):
   - `review`: `vendor/superpowers-code-reviewer.md` (bugs, quality, plan alignment)
   - `security`: `vendor/security-review.md` (its own 8/10 confidence filter)
   - `slop`: `vendor/ponytail-review.md` (over-engineering; advisory, never blocks)
3. A small model converts each lens's prose into a shared finding schema (extract only). Paths are resolved onto real diff paths.
4. Findings are merged (same file, within 3 lines, same category). Then `--verify-passes` independent verifiers, each with the refute-first rules from `vendor/rev-reviewer.md`, open the cited code and vote confirmed / refuted / uncertain. Confirmed needs a strict majority; severity is the most conservative confirming vote (precision).
5. The verifier also writes a corrected `claim`, and that text, not the lens's original, is what gets posted, so a comment cannot carry a claim its own evidence contradicts.
6. Only confirmed findings count. Confirmed medium+ findings on lines inside the diff become inline comments (max 25); everything else goes in the summary body (`info` stays in `findings.json`). Lines outside the diff never go in `comments[]`, since one bad line makes GitHub reject the whole review.
7. One `POST /pulls/{n}/reviews` via `gh-axi api --input`, pinned to the reviewed head SHA, with a hidden `<!-- mega-review:<sha> -->` marker so re-runs skip the same SHA.

## Upstream prompts

Vendored verbatim in `vendor/` at the commits in `pins.json` (see `vendor/NOTICE.md`; sha256 checked by the tests). To update: edit the sha, run `scripts/fetch_vendor.py`, read the diff, run the tests.

## Known limits

- Verification is same-family (Claude) until a Codex lens exists. Add it as another entry in `LENSES` once `codex` is authenticated.
- Results vary between runs; the multi-pass vote reduces that but does not remove it. Treat the verdict as a first-layer filter, not a merge approval.
- PR title/body/commits are untrusted: HTML comments and invisible Unicode are stripped and the text is delimited, which reduces prompt-injection risk rather than removing it.
- `CLAUDE.md` files in the PR head are still read by the lenses.
- CI check status is not considered.

## Tests

`python3 -m unittest discover -s test` covers the pure logic: diff-line parsing, path resolution, dedupe, vote tally, shuffle, routing, verdict, and vendor integrity. The model calls are not unit-tested.
