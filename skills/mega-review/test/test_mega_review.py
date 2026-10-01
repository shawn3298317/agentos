import hashlib, json, sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import mega_review as mr  # noqa: E402

DIFF = """diff --git a/a.py b/a.py
index 1..2 100644
--- a/a.py
+++ b/a.py
@@ -1,3 +1,4 @@
 x = 1
-y = 2
+y = 3
+z = 4
 w = 5
@@ -20,1 +21,2 @@ def f():
 keep
+added
diff --git a/gone.py b/gone.py
deleted file mode 100644
--- a/gone.py
+++ /dev/null
@@ -1,2 +0,0 @@
-a
-b
diff --git a/new.sh b/new.sh
new file mode 100644
--- /dev/null
+++ b/new.sh
@@ -0,0 +1,2 @@
+echo hi
+echo there
\\ No newline at end of file
"""


def finding(**kw):
    base = dict(file="a.py", line_start=2, line_end=2, severity="high", category="bug",
                title="t", body="b", flaggedBy=["review"], id="F1", evidence="e", verdict="confirmed",
                claim="verified claim text", votes="3/3", seen=["review#0"])
    return {**base, **kw}


class PatchLines(unittest.TestCase):
    def test_right_side_lines(self):
        v = mr.diff_right_lines(DIFF)
        self.assertEqual(v["a.py"], {1, 2, 3, 4, 21, 22})  # context + additions, never removed lines
        self.assertEqual(v["new.sh"], {1, 2})
        self.assertNotIn("gone.py", v)

    def test_pick_line_range_and_miss(self):
        v = mr.diff_right_lines(DIFF)
        self.assertEqual(mr.pick_line(finding(line_start=10, line_end=22), v), 21)
        self.assertIsNone(mr.pick_line(finding(line_start=10, line_end=12), v))
        self.assertIsNone(mr.pick_line(finding(file="nope.py"), v))


class Sanitize(unittest.TestCase):
    def test_strips_hidden_content(self):
        s = mr.sanitize("hi<!-- ignore previous -->​there</untrusted>x")
        self.assertEqual(s, "hithere" + "x")

    def test_truncates(self):
        self.assertEqual(len(mr.sanitize("a" * 9000, 100)), 100)


class Axi(unittest.TestCase):
    def test_parse(self):
        out = 'base: 1874c82\ndraft: true\ntitle: "MBP (Intel): setup"\nn: 3\n'
        self.assertEqual(mr.parse_axi(out), {"base": "1874c82", "draft": True, "title": "MBP (Intel): setup", "n": 3})


class ResolvePath(unittest.TestCase):
    FILES = ["agent-deck/conductor/fleet-spawner/permissions.json", "install.sh", "a/x.py", "b/x.py"]

    def test_resolution(self):
        r = mr.resolve_path
        self.assertEqual(r("fleet-spawner/permissions.json", self.FILES), self.FILES[0])  # dropped prefix
        self.assertEqual(r("install.sh", self.FILES), "install.sh")                      # exact
        self.assertEqual(r("x.py", self.FILES), "x.py")                                  # ambiguous: leave as-is
        self.assertEqual(r("README.md", self.FILES), "README.md")                        # not in diff

    def test_cross_lens_agreement_after_resolution(self):
        """The real PR #1 case: two lenses, same issue, one with a truncated path."""
        full = self.FILES[0]
        sec = finding(file=full, line_start=4, line_end=11, category="bug", flaggedBy=["security"])
        rev = finding(file=mr.resolve_path("fleet-spawner/permissions.json", self.FILES),
                      line_start=7, line_end=11, category="bug", flaggedBy=["review"])
        m = mr.dedupe([sec, rev])
        self.assertEqual(len(m), 1)
        self.assertEqual(m[0]["flaggedBy"], ["review", "security"])


def vote(verdict, severity="high", claim="c", evidence="e"):
    return {"verdict": verdict, "severity": severity, "claim": claim, "evidence": evidence}


class Tally(unittest.TestCase):
    def test_majority_confirms_with_most_conservative_severity(self):
        r = mr.tally([vote("confirmed", "high", "strong"), vote("confirmed", "medium", "careful"), vote("refuted")])
        self.assertEqual((r["verdict"], r["severity"], r["claim"], r["votes"]), ("confirmed", "medium", "careful", "2/3"))

    def test_no_majority_is_uncertain_not_confirmed(self):
        r = mr.tally([vote("confirmed"), vote("refuted"), vote("uncertain")])
        self.assertEqual((r["verdict"], r["votes"]), ("uncertain", "1/3"))

    def test_majority_refutes(self):
        self.assertEqual(mr.tally([vote("refuted"), vote("refuted"), vote("confirmed")])["verdict"], "refuted")

    def test_even_split_does_not_confirm(self):  # one verifier pass failed: 1 confirmed of 2 is not a majority
        self.assertNotEqual(mr.tally([vote("confirmed"), vote("refuted")])["verdict"], "confirmed")

    def test_single_vote(self):
        self.assertEqual(mr.tally([vote("confirmed")])["verdict"], "confirmed")


class Shuffle(unittest.TestCase):
    TEXT = "".join(f"diff --git a/f{i} b/f{i}\n+line{i}\n" for i in range(8))

    def test_same_sections_new_order_and_deterministic(self):
        s = mr.shuffle_diff(self.TEXT, 1)
        self.assertEqual(sorted(s.splitlines()), sorted(self.TEXT.splitlines()))
        self.assertNotEqual(s, self.TEXT)
        self.assertEqual(s, mr.shuffle_diff(self.TEXT, 1))
        self.assertTrue(all(s.split("diff --git ")[i].count("\n") == 2 for i in range(1, 9)))  # sections stay intact


class RefuteRules(unittest.TestCase):
    def test_rules_extracted_from_pinned_vendor_file(self):
        r = mr.refute_rules()
        self.assertIn("Try to refute each finding", r)
        self.assertIn("Open every file you cite", r)


class Dedupe(unittest.TestCase):
    def test_seen_passes_are_unioned(self):
        a = finding(seen=["review#0"], flaggedBy=["review"])
        b = finding(seen=["review#1", "security#0"], flaggedBy=["review", "security"], line_start=3, line_end=3)
        m = mr.dedupe([a, b])
        self.assertEqual(m[0]["seen"], ["review#0", "review#1", "security#0"])

    def test_merges_nearby_same_category(self):
        a = finding(line_start=10, line_end=10, severity="medium", flaggedBy=["review"])
        b = finding(line_start=12, line_end=13, severity="high", flaggedBy=["security"], body="other")
        c = finding(line_start=50, line_end=50)
        m = mr.dedupe([a, b, c])
        self.assertEqual(len(m), 2)
        self.assertEqual(m[0]["flaggedBy"], ["review", "security"])
        self.assertEqual((m[0]["severity"], m[0]["line_start"], m[0]["line_end"]), ("high", 10, 13))
        self.assertEqual([x["id"] for x in m], ["F1", "F2"])

    def test_keeps_different_categories(self):
        self.assertEqual(len(mr.dedupe([finding(), finding(category="slop")])), 2)


class Verdict(unittest.TestCase):
    def test_gate(self):
        self.assertEqual(mr.decide_verdict([finding(severity="critical")], [], False), "NEEDS_ATTENTION")
        self.assertEqual(mr.decide_verdict([], ["security"], False), "INCOMPLETE")  # failed lens never passes
        self.assertEqual(mr.decide_verdict([], [], True), "INCOMPLETE")  # truncated diff never passes
        self.assertEqual(mr.decide_verdict([finding(severity="medium")], [], False), "PASS_WITH_NOTES")
        self.assertEqual(mr.decide_verdict([finding(severity="low")], [], False), "PASS")
        self.assertEqual(mr.decide_verdict([], [], False), "PASS")


class BuildReview(unittest.TestCase):
    META = {"head": "h" * 40, "base": "b" * 40}

    def test_inline_vs_body_routing(self):
        v = mr.diff_right_lines(DIFF)
        fs = [finding(id="F1", line_start=2, line_end=2),                        # in diff, high -> inline
              finding(id="F2", line_start=99, line_end=99, title="offdiff"),     # off diff -> body
              finding(id="F3", category="slop", severity="low", title="slop"),   # slop -> body
              finding(id="F4", line_start=3, line_end=3, severity="low")]        # low -> body
        r = mr.build_review(self.META, fs, [finding(id="F5", verdict="refuted", title="meh")], v, "NEEDS_ATTENTION", ["n1"])
        self.assertEqual(r["event"], "COMMENT")
        self.assertEqual(r["commit_id"], "h" * 40)
        self.assertEqual([(c["path"], c["line"], c["side"]) for c in r["comments"]], [("a.py", 2, "RIGHT")])
        for t in ("offdiff", "slop", "Unverified", "meh", "n1"):
            self.assertIn(t, r["body"])
        self.assertIn(f"<!-- mega-review:{'h' * 40} -->", r["body"])
        self.assertIn(f"<!-- mega-review:{'h' * 40} -->", r["comments"][0]["body"])
        json.dumps(r)

    def test_inline_cap(self):
        v = {"a.py": set(range(1, 100))}
        fs = [finding(id=f"F{i}", line_start=i, line_end=i) for i in range(1, 40)]
        r = mr.build_review(self.META, fs, [], v, "NEEDS_ATTENTION", [], max_inline=25)
        self.assertEqual(len(r["comments"]), 25)


class Vendor(unittest.TestCase):
    def test_vendored_files_match_pins(self):
        pins = json.loads((ROOT / "pins.json").read_text())
        for name in pins["vendor"]:
            digest = hashlib.sha256((ROOT / "vendor" / name).read_bytes()).hexdigest()
            self.assertEqual(digest, pins["sha256"][name], f"{name} drifted from its pin")

    def test_lens_prompts_render(self):
        diff = {"text": "DIFFTEXT", "files": ["a.py"], "log": "commit abc"}
        meta = {"title": "T", "body": "B <!-- x -->"}
        r = mr.lens_prompt("review", meta, diff, "BASE1", "HEAD1")
        self.assertIn("BASE1..HEAD1", r)
        self.assertNotIn("[BASE_SHA]", r)
        self.assertNotIn("[DESCRIPTION]", r)
        s = mr.lens_prompt("security", meta, diff, "BASE1", "HEAD1")
        self.assertIn("DIFFTEXT", s)
        self.assertNotIn("!`git", s)
        self.assertIn("DIFFTEXT", mr.lens_prompt("slop", meta, diff, "B", "H"))


if __name__ == "__main__":
    unittest.main()
