"""Data layer tests: python3 -m unittest discover -s tests"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

FIXTURE_TERMS = {"weeklyTargetHours": 10, "monthlyHours": 40, "monthlyFee": 1600, "standardRate": 50}

HELPER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "worklog.py")


class Helper(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.out = os.path.join(self.dir, "out")
        self.now = "2026-10-27T15:00:00Z"  # Tuesday 16:00 in Madrid (CET after the DST change)

    def tearDown(self):
        self.tmp.cleanup()

    def run_cmd(self, *args, now=None, ok=True, config=None, env_extra=None):
        env = dict(os.environ, WORKLOG_DATA_DIR=self.dir, WORKLOG_NOW=now or self.now, WORKLOG_TZ="Europe/Madrid", **(env_extra or {}))
        argv = list(args)
        # Fixtures assume a 40 h / 1.600 / 50 €/h package: seeded as v1 settings.
        config = dict(config or {})
        if "legacy" not in config and not any(k in config for k in FIXTURE_TERMS):
            config["legacy"] = FIXTURE_TERMS
        argv += ["--config", json.dumps(config)]
        # The way the shell calls it: the arguments as JSON on stdin.
        p = subprocess.run([sys.executable, "-I", HELPER, "--stdin"], input=json.dumps(argv), env=env, capture_output=True, text=True)
        result = json.loads(p.stdout)
        if ok is not None:
            self.assertEqual(result["ok"], ok, result)
            self.assertEqual(p.returncode, 0 if ok else 1)
        return result

    def log(self):
        with open(os.path.join(self.dir, "worklog.json")) as f:
            return json.load(f)

    def has_active(self):
        return os.path.exists(os.path.join(self.dir, "active.json"))

    def active(self):
        with open(os.path.join(self.dir, "active.json")) as f:
            return json.load(f)

    # -------------------------------------------------------------- lifecycle

    def test_full_cycle(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("pause", now="2026-10-27T10:00:00Z")
        v = self.run_cmd("resume", now="2026-10-27T10:30:00Z")["view"]
        self.assertEqual(v["state"], "running")
        self.run_cmd("stop", now="2026-10-27T12:00:00Z")
        self.assertEqual(self.active()["state"], "ending")
        v = self.run_cmd("confirm", "--summary", "Did things", "--tags", "Backend, review", now="2026-10-27T12:01:00Z")["view"]
        self.assertEqual(v["state"], "idle")
        self.assertFalse(self.has_active())
        s = self.log()["sessions"][0]
        self.assertEqual(len(s["segments"]), 2)
        self.assertEqual(s["segments"][0]["endReason"], "manual")
        self.assertEqual(s["segments"][1]["endReason"], "stop")
        self.assertEqual(s["tags"], ["backend", "review"])
        self.assertEqual(v["today"]["workedSec"], 3.5 * 3600)
        self.assertEqual(v["recent"][0]["pausedSec"], 1800)

    def test_commands_in_wrong_state_are_no_ops(self):
        r = self.run_cmd("pause", ok=False)
        self.assertEqual(r["error"], "no-op: idle")
        self.run_cmd("start")
        self.assertEqual(self.run_cmd("start", ok=False)["error"], "no-op: running")
        self.assertEqual(self.run_cmd("confirm", "--summary", "x", ok=False)["error"], "no-op: running")

    def test_start_while_paused_resumes(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("pause", now="2026-10-27T09:00:00Z")
        v = self.run_cmd("start", now="2026-10-27T09:10:00Z")["view"]
        self.assertEqual(v["state"], "running")
        self.assertEqual(len(v["active"]["segments"]), 2)

    def test_idle_pause_back_dated_and_clamped(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("pause", "--reason", "idle", "--at", "2026-10-27T07:00:00Z", now="2026-10-27T08:20:00Z")
        a = self.active()
        self.assertEqual(a["session"]["segments"][0]["end"], "2026-10-27T08:00:00Z")
        self.assertEqual(a["pauseReason"], "idle")
        self.assertFalse(a["announced"])

    def test_unpause_counts_the_gap_as_work(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("pause", "--reason", "idle", "--at", "2026-10-27T08:30:00Z", now="2026-10-27T08:45:00Z")
        v = self.run_cmd("unpause", now="2026-10-27T08:50:00Z")["view"]
        self.assertEqual(v["state"], "running")
        self.assertEqual(len(v["active"]["segments"]), 1)
        self.assertIsNone(v["active"]["segments"][0]["end"])

    def test_back_from_review(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("stop", now="2026-10-27T09:00:00Z")
        v = self.run_cmd("back")["view"]
        self.assertEqual(v["state"], "paused")
        self.assertEqual(v["active"]["segments"][0]["endReason"], "manual")

    def test_confirm_without_args_uses_the_draft(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("stop", now="2026-10-27T09:00:00Z")
        self.run_cmd("draft", "--summary", "from draft", "--tags", "a")
        self.run_cmd("confirm")
        s = self.log()["sessions"][0]
        self.assertEqual((s["summary"], s["tags"]), ("from draft", ["a"]))

    def test_discard(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("stop", now="2026-10-27T09:00:00Z")
        self.run_cmd("discard")
        self.assertFalse(self.has_active())
        self.assertFalse(os.path.exists(os.path.join(self.dir, "worklog.json")))

    def test_draft_survives(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("draft", "--summary", "half written", "--tags", "a,b")
        v = self.run_cmd("view")["view"]
        self.assertEqual(v["active"]["draft"], {"summary": "half written", "tags": ["a", "b"]})

    def test_start_with_earlier_segments(self):
        segs = [{"start": "2026-10-27T10:00:00Z", "end": "2026-10-27T15:00:00Z"}, {"start": "2026-10-27T16:00:00Z", "end": None}]
        v = self.run_cmd("start", "--segments", json.dumps(segs), now="2026-10-27T17:30:00Z")["view"]
        self.assertEqual(v["state"], "running")
        self.assertEqual(v["active"]["closedSec"], 5 * 3600)
        self.assertEqual(v["active"]["openStart"], "2026-10-27T16:00:00Z")
        self.assertEqual(v["active"]["source"], "manual")
        # The open segment is added by the shell; today counts closed time only.
        self.assertEqual(v["today"]["workedSec"], 5 * 3600)

    def test_start_with_closed_last_segment_refused(self):
        segs = [{"start": "2026-10-27T10:00:00Z", "end": "2026-10-27T11:00:00Z"}]
        r = self.run_cmd("start", "--segments", json.dumps(segs), ok=False)
        self.assertEqual(r["field"], "segments")

    # -------------------------------------------------------------- recovery

    def test_recover_same_boot_fresh_heartbeat(self):
        self.run_cmd("start", "--boot-id", "b1", now="2026-10-27T08:00:00Z")
        r = self.run_cmd("recover", "--boot-id", "b1", now="2026-10-27T08:01:00Z")
        self.assertIsNone(r["recovery"])
        self.assertEqual(r["view"]["state"], "running")

    def test_recover_stale_heartbeat(self):
        self.run_cmd("start", "--boot-id", "b1", now="2026-10-27T08:00:00Z")
        self.run_cmd("heartbeat", now="2026-10-27T09:00:00Z")
        r = self.run_cmd("recover", "--boot-id", "b1", now="2026-10-27T11:00:00Z")
        self.assertEqual(r["recovery"]["reason"], "restart")
        self.assertEqual(r["view"]["state"], "paused")
        self.assertEqual(r["view"]["active"]["segments"][0]["end"], "2026-10-27T09:00:00Z")

    def test_recover_other_boot(self):
        self.run_cmd("start", "--boot-id", "b1", now="2026-10-27T08:00:00Z")
        r = self.run_cmd("recover", "--boot-id", "b2", now="2026-10-27T08:00:30Z")
        self.assertEqual(r["view"]["state"], "paused")

    def test_recover_keeps_review(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("stop", now="2026-10-27T09:00:00Z")
        self.run_cmd("draft", "--summary", "kept")
        r = self.run_cmd("recover", "--boot-id", "b2", now="2026-10-28T09:00:00Z")
        self.assertEqual(r["view"]["state"], "ending")
        self.assertEqual(r["view"]["active"]["draft"]["summary"], "kept")

    # -------------------------------------------------------------- time math

    def test_midnight_split(self):
        segs = [{"start": "2026-10-26T22:00:00Z", "end": "2026-10-27T00:00:00Z"}]  # 23:00-01:00 Madrid
        self.run_cmd("add", "--segments", json.dumps(segs), "--summary", "late")
        v = self.run_cmd("view")["view"]
        days = {d["date"]: d["workedSec"] for d in v["week"]["days"]}
        self.assertEqual(days["2026-10-26"], 3600)
        self.assertEqual(days["2026-10-27"], 3600)
        self.assertEqual(len(self.log()["sessions"]), 1)

    def test_dst_weekend_counts_real_seconds(self):
        # Sunday 25 Oct 2026: 03:00 CEST becomes 02:00 CET. 00:00 to 04:00 local is 5 real hours.
        segs = [{"start": "2026-10-24T22:00:00Z", "end": "2026-10-25T03:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(segs), "--summary", "dst")
        v = self.run_cmd("view")["view"]
        self.assertEqual(v["trend"][-2]["workedSec"], 5 * 3600)

    def test_week_figures(self):
        segs = [{"start": "2026-10-26T08:00:00Z", "end": "2026-10-26T12:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(segs), "--summary", "monday")
        w = self.run_cmd("view")["view"]["week"]
        self.assertEqual(w["key"], "2026-W44")
        self.assertEqual(w["start"], "2026-10-26")
        self.assertEqual(w["workedSec"], 4 * 3600)
        self.assertEqual(w["targetSec"], 10 * 3600)
        self.assertEqual(w["daysLeft"], 6)  # Tuesday through Sunday
        sunday = self.run_cmd("view", now="2026-11-01T10:00:00Z")["view"]["week"]
        self.assertEqual(sunday["daysLeft"], 1)

    def test_trend_has_eight_weeks_oldest_first(self):
        t = self.run_cmd("view")["view"]["trend"]
        self.assertEqual(len(t), 8)
        self.assertEqual(t[-1]["key"], "2026-W44")
        self.assertEqual(t[0]["key"], "2026-W37")
        self.assertTrue(all(x["workedSec"] == 0 for x in t))

    def test_month_and_money(self):
        segs = [{"start": "2026-10-05T08:00:00Z", "end": "2026-10-05T18:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(segs), "--summary", "ten hours")
        m = self.run_cmd("view")["view"]["month"]
        self.assertEqual(m["key"], "2026-10")
        self.assertEqual(m["targetSec"], 40 * 3600)
        self.assertEqual(m["workedSec"], 10 * 3600)
        self.assertEqual(m["elapsedDays"], 27)
        self.assertEqual(m["daysLeft"], 5)
        money = m["money"]
        self.assertTrue(money["projected"])
        # Projected on the 40 h owed: 40 h at 50 is 2.000, the package 1.600.
        self.assertEqual(money["standardValue"], 2000)
        self.assertEqual(money["discount"], 400)
        self.assertEqual(money["discountPercent"], 20)
        self.assertEqual(money["effectiveRate"], 40)

    def test_money_over_the_package(self):
        segs = [{"start": "2026-10-%02dT07:00:00Z" % d, "end": "2026-10-%02dT17:00:00Z" % d} for d in range(1, 7)]
        for s in segs:
            self.run_cmd("add", "--segments", json.dumps([s]), "--summary", "long day")
        money = self.run_cmd("view")["view"]["month"]["money"]
        self.assertFalse(money["projected"])
        self.assertEqual(money["standardValue"], 60 * 50)
        self.assertEqual(money["overHours"], 20)
        # The 20 h over the package are billed at the extra hour rate (the standard rate by default).
        self.assertEqual((money["fee"], money["overageNet"], money["net"]), (1600, 1000, 2600))
        self.assertEqual(money["effectiveRate"], 43.33)

    def test_legacy_settings_seed_the_first_company(self):
        v = self.run_cmd("view", config={"weeklyTargetHours": 10, "monthlyHours": 40, "monthlyFee": 1000})["view"]
        self.assertEqual(v["week"]["targetSec"], 36000)
        self.assertEqual(v["month"]["money"]["standardValue"], 2000)  # 40 h at the default 50 €/h

    # -------------------------------------------------------------- validation

    def test_validation(self):
        good = [{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T09:00:00Z"}]
        cases = [
            ([{"start": "2026-10-27T09:00:00Z", "end": "2026-10-27T08:00:00Z"}], "x", "segments"),
            ([{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T09:00:00Z"},
              {"start": "2026-10-27T08:30:00Z", "end": "2026-10-27T10:00:00Z"}], "x", "segments"),
            ([{"start": "2026-10-27T14:00:00Z", "end": "2026-10-27T16:00:00Z"}], "x", "segments"),  # future
            (good, "   ", "summary"),
            (good, "x" * 2001, "summary"),
            ([{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T08:00:30Z"}], "x", "segments"),  # all dropped
        ]
        for segs, summary, field in cases:
            r = self.run_cmd("add", "--segments", json.dumps(segs), "--summary", summary, ok=False)
            self.assertEqual(r["field"], field, (segs, r))
        r = self.run_cmd("add", "--segments", json.dumps(good), "--summary", "x", "--tags", ",".join("t%d" % i for i in range(11)), ok=False)
        self.assertEqual(r["field"], "tags")
        r = self.run_cmd("add", "--segments", json.dumps(good), "--summary", "x", "--tags", "y" * 33, ok=False)
        self.assertEqual(r["field"], "tags")

    def test_overlap_with_other_session_and_running(self):
        a = [{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T09:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(a), "--summary", "first")
        b = [{"start": "2026-10-27T08:30:00Z", "end": "2026-10-27T09:30:00Z"}]
        r = self.run_cmd("add", "--segments", json.dumps(b), "--summary", "second", ok=False)
        self.assertIn("overlaps", r["error"])
        self.run_cmd("start", "--at", "2026-10-27T12:00:00Z")
        c = [{"start": "2026-10-27T13:00:00Z", "end": "2026-10-27T13:30:00Z"}]
        r = self.run_cmd("add", "--segments", json.dumps(c), "--summary", "third", ok=False)
        self.assertIn("running session", r["error"])

    def test_short_segments_dropped_at_confirm(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("pause", now="2026-10-27T08:00:30Z")
        self.run_cmd("resume", now="2026-10-27T08:10:00Z")
        self.run_cmd("stop", now="2026-10-27T09:00:00Z")
        self.run_cmd("confirm", "--summary", "x")
        self.assertEqual(len(self.log()["sessions"][0]["segments"]), 1)

    def test_empty_session_cannot_be_confirmed(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("stop", now="2026-10-27T08:00:20Z")
        r = self.run_cmd("confirm", "--summary", "x", ok=False)
        self.assertEqual(r["field"], "segments")

    def test_confirm_with_edited_segments(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("stop", now="2026-10-27T12:00:00Z")
        segs = [{"start": "2026-10-27T08:15:00Z", "end": "2026-10-27T11:00:00Z", "endReason": "stop"}]
        self.run_cmd("confirm", "--summary", "x", "--segments", json.dumps(segs))
        s = self.log()["sessions"][0]
        self.assertEqual(s["segments"][0]["start"], "2026-10-27T08:15:00Z")

    # -------------------------------------------------------------- history

    def test_update_delete_and_sorting(self):
        a = [{"start": "2026-10-27T10:00:00Z", "end": "2026-10-27T11:00:00Z"}]
        b = [{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T09:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(a), "--summary", "later")
        self.run_cmd("add", "--segments", json.dumps(b), "--summary", "earlier")
        sessions = self.log()["sessions"]
        self.assertEqual([s["summary"] for s in sessions], ["earlier", "later"])
        sid = sessions[0]["id"]
        self.run_cmd("update", "--id", sid, "--summary", "edited", "--tags", "z")
        self.assertEqual(self.log()["sessions"][0]["summary"], "edited")
        r = self.run_cmd("update", "--id", sid, "--segments", json.dumps(a), ok=False)
        self.assertIn("overlaps", r["error"])
        self.run_cmd("delete", "--id", sid)
        self.assertEqual(len(self.log()["sessions"]), 1)
        self.assertEqual(self.run_cmd("delete", "--id", "nope", ok=False)["field"], "id")

    def test_sessions_by_week_and_month(self):
        a = [{"start": "2026-10-20T08:00:00Z", "end": "2026-10-20T09:00:00Z"}]
        b = [{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T10:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(a), "--summary", "last week")
        self.run_cmd("add", "--segments", json.dumps(b), "--summary", "this week")
        w = self.run_cmd("sessions", "--week", "this")["sessions"]
        self.assertEqual([s["summary"] for s in w["sessions"]], ["this week"])
        self.assertEqual(w["figures"]["workedSec"], 7200)
        w43 = self.run_cmd("sessions", "--week", "2026-W43")["sessions"]
        self.assertEqual([s["summary"] for s in w43["sessions"]], ["last week"])
        m = self.run_cmd("month", "--month", "2026-10", "--company", "c_0001")["month"]
        self.assertEqual(sum(len(d["sessions"]) for d in m["days"]), 2)
        self.assertEqual(m["workedSec"], 3 * 3600)

    def test_backup_once_per_day(self):
        a = [{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T09:00:00Z"}]
        b = [{"start": "2026-10-27T10:00:00Z", "end": "2026-10-27T11:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(a), "--summary", "one")
        self.run_cmd("add", "--segments", json.dumps(b), "--summary", "two")
        backups = os.listdir(os.path.join(self.dir, "backups"))
        self.assertEqual(backups, ["worklog-2026-10-27.json"])
        with open(os.path.join(self.dir, "backups", backups[0])) as f:
            self.assertEqual(len(json.load(f)["sessions"]), 1)

    def test_corrupt_log_moved_aside(self):
        with open(os.path.join(self.dir, "worklog.json"), "w") as f:
            f.write("{not json")
        v = self.run_cmd("view")["view"]
        self.assertEqual(v["recovered"]["file"], "worklog.json")
        self.assertTrue(any(n.startswith("worklog.json.corrupt-") for n in os.listdir(self.dir)))
        self.assertIsNone(self.run_cmd("view")["view"]["recovered"])

    def test_concurrent_writers(self):
        env = dict(os.environ, WORKLOG_DATA_DIR=self.dir, WORKLOG_NOW=self.now, WORKLOG_TZ="Europe/Madrid")
        procs = []
        for h in range(6):
            segs = [{"start": "2026-10-27T%02d:00:00Z" % (6 + h), "end": "2026-10-27T%02d:30:00Z" % (6 + h)}]
            procs.append(subprocess.Popen([sys.executable, "-I", HELPER, "add", "--segments", json.dumps(segs), "--summary", "p%d" % h],
                                          env=env, stdout=subprocess.DEVNULL))
        for p in procs:
            p.wait()
        self.assertEqual(len(self.log()["sessions"]), 6)

    # -------------------------------------------------------------- export

    def test_export_week(self):
        segs = [{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T10:07:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(segs), "--summary", "Line one, with comma\nLine two", "--tags", "a")
        r = self.run_cmd("export", "--week", "this", "--out", self.out)["export"]
        with open(r["csv"], encoding="utf-8") as f:
            text = f.read()
        self.assertIn('"Line one, with comma\nLine two"', text)
        self.assertIn("2026-10-27 09:00", text)
        with open(r["markdown"], encoding="utf-8") as f:
            md = f.read()
        self.assertIn("week 44", md)
        self.assertIn("| Tue 27 Oct | 09:00 to 11:07 | 2h 07m | a | Line one, with comma. Line two. |", md)
        again = self.run_cmd("export", "--week", "this", "--out", self.out)["export"]
        self.assertTrue(again["csv"].endswith("worklog-2026-W44-2.csv"))

    def test_export_month_spanish_rounded_with_discount(self):
        segs = [{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T10:08:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(segs), "--summary", "Hecho")
        cfg = {"reportLanguage": "es", "reportRoundingMinutes": 15}
        r = self.run_cmd("export", "--month", "this", "--out", self.out, config=cfg)["export"]
        with open(r["markdown"], encoding="utf-8") as f:
            md = f.read()
        self.assertIn("octubre de 2026", md)
        self.assertIn("| mar 27 oct | 09:00 a 11:08 | 2h 15m |  | Hecho. |", md)
        self.assertIn("1.600,00 € + IVA 21 % (336,00 €) = 1.936,00 €", md)
        self.assertIn("2.000,00 €", md)
        self.assertIn("400,00 € (20,0 %)", md)
        self.assertIn("redondeada", md)

    # ------------------------------------------------------------ review 2026-10-27 (Codex)

    def test_confirm_retried_after_a_cut_does_not_duplicate(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("stop", now="2026-10-27T09:00:00Z")
        with open(os.path.join(self.dir, "active.json")) as f:
            saved_active = f.read()
        self.run_cmd("confirm", "--summary", "once")
        # The cut: the log was written, active.json was not removed.
        with open(os.path.join(self.dir, "active.json"), "w") as f:
            f.write(saved_active)
        self.run_cmd("confirm", "--summary", "once")
        self.assertEqual(len(self.log()["sessions"]), 1)
        self.assertFalse(self.has_active())

    def test_recover_drops_an_already_confirmed_active(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("stop", now="2026-10-27T09:00:00Z")
        with open(os.path.join(self.dir, "active.json")) as f:
            saved_active = f.read()
        self.run_cmd("confirm", "--summary", "once")
        with open(os.path.join(self.dir, "active.json"), "w") as f:
            f.write(saved_active)
        r = self.run_cmd("recover", "--boot-id", "b1")
        self.assertEqual(r["view"]["state"], "idle")
        self.assertEqual(len(self.log()["sessions"]), 1)

    def test_export_clips_sessions_to_the_period(self):
        # 31 Oct 23:00 to 1 Nov 01:00 Madrid: one hour in each month.
        segs = [{"start": "2026-10-31T22:00:00Z", "end": "2026-11-01T00:00:00Z"}]
        now = "2026-11-02T10:00:00Z"
        self.run_cmd("add", "--segments", json.dumps(segs), "--summary", "across months", now=now)
        self.run_cmd("contract", "--action", "set", "--id", "c_0001", "--from", "2026-10-01", "--replace", "2026-11-01",
                     "--terms", json.dumps({"monthlyHours": 40}), now=now)
        for month in ("2026-10", "2026-11"):
            r = self.run_cmd("export", "--month", month, "--out", self.out, now=now)["export"]
            with open(r["csv"], encoding="utf-8") as f:
                rows = f.read().splitlines()
            self.assertEqual(rows[1].split(",")[4], "60", (month, rows))
            with open(r["markdown"], encoding="utf-8") as f:
                self.assertIn("Worked: 1h of 40h owed.", f.read())

    def test_unpause_after_restart_keeps_the_counted_time(self):
        self.run_cmd("start", "--boot-id", "b1", now="2026-10-27T08:00:00Z")
        self.run_cmd("heartbeat", now="2026-10-27T08:59:50Z")
        self.run_cmd("pause", now="2026-10-27T09:00:00Z")
        self.run_cmd("unpause", now="2026-10-27T11:00:00Z")
        r = self.run_cmd("recover", "--boot-id", "b1", now="2026-10-27T11:00:01Z")
        self.assertIsNone(r["recovery"])
        self.assertEqual(r["view"]["state"], "running")

    def test_resume_refreshes_the_heartbeat(self):
        self.run_cmd("start", "--boot-id", "b1", now="2026-10-27T08:00:00Z")
        self.run_cmd("pause", now="2026-10-27T08:30:00Z")
        self.run_cmd("resume", now="2026-10-27T11:00:00Z")
        r = self.run_cmd("recover", "--boot-id", "b1", now="2026-10-27T11:00:30Z")
        self.assertIsNone(r["recovery"])

    def test_unpause_refuses_an_overlap(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("pause", now="2026-10-27T09:00:00Z")
        manual = [{"start": "2026-10-27T09:00:00Z", "end": "2026-10-27T10:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(manual), "--summary", "manual", now="2026-10-27T10:00:00Z")
        r = self.run_cmd("unpause", now="2026-10-27T10:00:00Z", ok=False)
        self.assertIn("overlaps", r["error"])
        self.assertEqual(self.active()["state"], "paused")

    def test_malformed_session_answers_in_json_and_keeps_the_file(self):
        path = os.path.join(self.dir, "worklog.json")
        with open(path, "w") as f:
            f.write('{"version": 1, "sessions": [{}]}')
        r = self.run_cmd("view", ok=False)
        self.assertEqual(r["field"], "data")
        self.assertIn("session 1", r["error"])
        with open(path) as f:
            self.assertEqual(f.read(), '{"version": 1, "sessions": [{}]}')

    def test_group_writable_data_dir_is_tightened(self):
        os.chmod(self.dir, 0o770)
        self.run_cmd("view")
        self.assertEqual(os.stat(self.dir).st_mode & 0o777, 0o700)

    def test_csv_cells_never_start_a_formula(self):
        segs = [{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T09:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(segs), "--summary", "=1+1", "--tags", "@x")
        r = self.run_cmd("export", "--week", "this", "--out", self.out)["export"]
        with open(r["csv"], encoding="utf-8") as f:
            row = f.read().splitlines()[1]
        self.assertTrue(row.endswith(",'@x,'=1+1"), row)

    def test_interrupted_backup_leaves_no_daily_backup(self):
        spec = importlib.util.spec_from_file_location("worklog_mod", HELPER)
        mod = importlib.util.module_from_spec(spec)
        assert spec.loader
        spec.loader.exec_module(mod)
        os.environ["WORKLOG_DATA_DIR"] = self.dir
        os.environ["WORKLOG_NOW"] = self.now
        try:
            self.run_cmd("add", "--segments", json.dumps([{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T09:00:00Z"}]), "--summary", "x")
            shutil.rmtree(os.path.join(self.dir, "backups"), ignore_errors=True)

            def cut(src, dst, *a):
                dst.write(b"{")
                raise OSError("cut")
            original = mod.shutil.copyfileobj
            mod.shutil.copyfileobj = cut
            store = mod.Store(mod.config_from(None), mod.now_utc())
            try:
                with self.assertRaises(OSError):
                    store.save_log()
            finally:
                store.close()
                mod.shutil.copyfileobj = original
            bdir = os.path.join(self.dir, "backups")
            self.assertEqual([n for n in os.listdir(bdir) if not n.startswith(".")], [])
            self.assertEqual([n for n in os.listdir(bdir) if n.startswith(".tmp-")], [])
        finally:
            del os.environ["WORKLOG_DATA_DIR"], os.environ["WORKLOG_NOW"]

    # ------------------------------------------------------------ arguments

    def helper(self, argv):
        env = dict(os.environ, WORKLOG_DATA_DIR=self.dir, WORKLOG_NOW=self.now, WORKLOG_TZ="Europe/Madrid")
        return subprocess.Popen([sys.executable, "-I", HELPER] + argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)

    def test_stdin_arguments_stay_off_the_command_line(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        p = self.helper(["--stdin"])
        try:
            # The helper waits on stdin; the command line shows once exec is done.
            cmdline = [b""]
            for _ in range(200):
                with open("/proc/%d/cmdline" % p.pid, "rb") as f:
                    cmdline = f.read().rstrip(b"\0").split(b"\0")
                if cmdline[-1] == b"--stdin":
                    break
                time.sleep(0.01)
            out, _ = p.communicate(json.dumps(["draft", "--summary", "private summary", "--tags", "secret-tag"]))
        finally:
            p.kill()
        self.assertEqual(cmdline[-2:], [HELPER.encode(), b"--stdin"])
        self.assertTrue(json.loads(out)["ok"])
        self.assertEqual(self.active()["draft"], {"summary": "private summary", "tags": ["secret-tag"]})

    def test_bad_stdin_arguments_are_refused(self):
        for stdin in ["", "not json", '{"cmd": "view"}', '["view", 1]', "[]", '["--stdin"]', "[" + '"x",' * (1 << 19) + '"x"]']:
            p = self.helper(["--stdin"])
            out, _ = p.communicate(stdin)
            r = json.loads(out)
            self.assertFalse(r["ok"], stdin[:40])
            self.assertEqual((r["field"], p.returncode), ("cmd", 1), stdin[:40])

    def test_command_line_arguments_still_work(self):
        p = self.helper(["view"])
        out, _ = p.communicate("")
        self.assertTrue(json.loads(out)["ok"])

    def test_refusals_never_echo_a_tag(self):
        segs = [{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T09:00:00Z"}]
        r = self.run_cmd("add", "--segments", json.dumps(segs), "--summary", "x", "--tags", "t" * 60 + "private", ok=False)
        self.assertEqual(r["field"], "tags")
        self.assertNotIn("private", r["error"])
        self.assertNotIn("tttt", r["error"])

    # -------------------------------------------------------------- live edit

    def base(self, now):
        return self.run_cmd("view", now=now)["view"]["active"]["editBase"]

    def files(self):
        out = []
        for name in ("worklog.json", "active.json"):
            path = os.path.join(self.dir, name)
            out.append(open(path).read() if os.path.exists(path) else None)
        return out

    def test_edit_active_moves_a_running_start_earlier(self):
        sid = self.run_cmd("start", now="2026-10-27T08:10:00Z")["view"]["active"]["id"]
        base = self.base("2026-10-27T08:15:00Z")
        v = self.run_cmd("edit-active", "--base", base, "--segments", json.dumps([{"start": "2026-10-27T08:00:00Z", "end": None}]),
                         now="2026-10-27T08:15:00Z")["view"]
        self.assertEqual(v["state"], "running")
        self.assertEqual(v["active"]["id"], sid)
        self.assertEqual(v["active"]["openStart"], "2026-10-27T08:00:00Z")
        self.assertEqual(self.active()["heartbeatAt"], "2026-10-27T08:15:00Z")
        v = self.run_cmd("pause", now="2026-10-27T08:20:00Z")["view"]
        self.assertEqual(v["today"]["workedSec"], 1200)

    def test_edit_active_keeps_a_paused_session_paused(self):
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("pause", "--reason", "idle", "--at", "2026-10-27T08:45:00Z", now="2026-10-27T09:00:00Z")
        before = self.active()
        v = self.run_cmd("edit-active", "--segments", json.dumps([{"start": "2026-10-27T08:00:00Z", "end": "2026-10-27T08:55:00Z"}]),
                         now="2026-10-27T09:01:00Z")["view"]
        self.assertEqual(v["state"], "paused")
        self.assertEqual(v["pauseReason"], "idle")
        self.assertEqual(v["announced"], before["announced"])
        self.assertEqual(v["active"]["closedSec"], 3300)
        v = self.run_cmd("resume", now="2026-10-27T09:02:00Z")["view"]
        self.assertEqual(len(v["active"]["segments"]), 2)

    def stale_save(self, form_base, form_segments, now):
        before = self.files()
        r = self.run_cmd("edit-active", "--base", form_base, "--segments", json.dumps(form_segments), now=now, ok=False)
        self.assertEqual(r["field"], "segments")
        self.assertEqual(self.files(), before)

    def test_stale_form_cannot_undo_a_pause(self):
        # Without the check the gap counts as work: 30 minutes billed from nothing.
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        base = self.base("2026-10-27T08:01:00Z")
        self.run_cmd("pause", now="2026-10-27T09:00:00Z")
        self.run_cmd("resume", now="2026-10-27T09:30:00Z")
        self.stale_save(base, [{"start": "2026-10-27T08:00:00Z", "end": None}], "2026-10-27T10:00:00Z")

    def test_stale_form_cannot_erase_later_work(self):
        # Same id and same state as the form, later work in the file.
        self.run_cmd("start", now="2026-10-27T10:00:00Z")
        v = self.run_cmd("pause", now="2026-10-27T10:00:30Z")["view"]
        base, segments = v["active"]["editBase"], v["active"]["segments"]
        self.run_cmd("resume", now="2026-10-27T10:10:00Z")
        self.run_cmd("pause", now="2026-10-27T10:20:00Z")
        self.stale_save(base, segments, "2026-10-27T10:30:00Z")

    def test_stale_form_cannot_land_on_a_new_session(self):
        v = self.run_cmd("start", now="2026-10-27T09:00:00Z")["view"]
        base, segments = v["active"]["editBase"], v["active"]["segments"]
        self.run_cmd("discard", now="2026-10-27T09:10:00Z")
        self.run_cmd("start", now="2026-10-27T09:20:00Z")
        self.stale_save(base, segments, "2026-10-27T09:30:00Z")

    def test_stale_form_refused_after_a_draft_or_company_change(self):
        v = self.run_cmd("start", now="2026-10-27T09:00:00Z")["view"]
        base, segments = v["active"]["editBase"], v["active"]["segments"]
        self.run_cmd("draft", "--summary", "written elsewhere", now="2026-10-27T09:01:00Z")
        self.stale_save(base, segments, "2026-10-27T09:02:00Z")
        base = self.base("2026-10-27T09:02:00Z")
        other = self.run_cmd("company", "--action", "add", "--name", "Other", "--tag", "OT", now="2026-10-27T09:03:00Z")
        other_id = [c["id"] for c in other["view"]["companies"] if c["name"] == "Other"][0]
        self.run_cmd("edit-active", "--company", other_id, now="2026-10-27T09:04:00Z")
        self.stale_save(base, segments, "2026-10-27T09:05:00Z")

    def test_a_heartbeat_does_not_make_a_form_stale(self):
        self.run_cmd("start", "--boot-id", "b1", now="2026-10-27T09:00:00Z")
        base = self.base("2026-10-27T09:00:00Z")
        self.run_cmd("heartbeat", now="2026-10-27T09:01:00Z")
        self.run_cmd("announce", now="2026-10-27T09:01:30Z")
        self.run_cmd("edit-active", "--base", base, "--segments", json.dumps([{"start": "2026-10-27T08:50:00Z", "end": None}]),
                     now="2026-10-27T09:02:00Z")

    def test_edit_active_writes_the_draft_with_the_times(self):
        self.run_cmd("start", now="2026-10-27T09:00:00Z")
        self.run_cmd("edit-active", "--segments", json.dumps([{"start": "2026-10-27T08:50:00Z", "end": None}]),
                     "--summary", "Fixing the invoice", "--tags", "backend, review", now="2026-10-27T09:05:00Z")
        self.assertEqual(self.active()["draft"], {"summary": "Fixing the invoice", "tags": ["backend", "review"]})
        self.run_cmd("edit-active", "--summary", "", now="2026-10-27T09:06:00Z")
        self.assertEqual(self.active()["draft"]["summary"], "")
        self.assertEqual(self.run_cmd("edit-active", now="2026-10-27T09:07:00Z", ok=False)["error"], "nothing to change")

    def test_edit_active_refused_saves_nothing(self):
        self.run_cmd("add", "--segments", json.dumps([{"start": "2026-10-27T07:00:00Z", "end": "2026-10-27T08:00:00Z"}]),
                     "--summary", "Earlier", now="2026-10-27T08:05:00Z")
        self.run_cmd("start", now="2026-10-27T09:00:00Z")
        before = self.files()
        r = self.run_cmd("edit-active", "--summary", "Should not land", "--segments", json.dumps([{"start": "2026-10-27T07:30:00Z", "end": None}]),
                         now="2026-10-27T09:05:00Z", ok=False)
        self.assertIn("overlaps", r["error"])
        self.assertEqual(self.files(), before)

    def test_edit_active_keeps_the_shape_of_the_state(self):
        self.run_cmd("start", now="2026-10-27T09:00:00Z")
        closed = [{"start": "2026-10-27T09:00:00Z", "end": "2026-10-27T09:04:00Z"}]
        r = self.run_cmd("edit-active", "--segments", json.dumps(closed), now="2026-10-27T09:05:00Z", ok=False)
        self.assertIn("keeps its last segment open", r["error"])
        self.run_cmd("pause", now="2026-10-27T09:06:00Z")
        r = self.run_cmd("edit-active", "--segments", json.dumps([{"start": "2026-10-27T09:00:00Z", "end": None}]), now="2026-10-27T09:07:00Z", ok=False)
        self.assertIn("has no end", r["error"])

    def test_edit_active_keeps_short_and_empty_segments(self):
        self.run_cmd("start", now="2026-10-27T09:00:00Z")
        v = self.run_cmd("pause", now="2026-10-27T09:00:00Z")["view"]
        self.assertEqual(v["active"]["segments"][0]["start"], v["active"]["segments"][0]["end"])
        v = self.run_cmd("edit-active", "--segments", json.dumps(v["active"]["segments"]), now="2026-10-27T09:05:00Z")["view"]
        self.assertEqual(len(v["active"]["segments"]), 1)
        self.run_cmd("resume", now="2026-10-27T09:06:00Z")
        v = self.run_cmd("pause", now="2026-10-27T09:06:30Z")["view"]
        self.assertEqual(len(v["active"]["segments"]), 2)
        v = self.run_cmd("edit-active", "--segments", json.dumps(v["active"]["segments"]), now="2026-10-27T09:07:00Z")["view"]
        self.assertEqual(len(v["active"]["segments"]), 2)
        backwards = [{"start": "2026-10-27T09:06:00Z", "end": "2026-10-27T09:05:00Z"}]
        self.run_cmd("edit-active", "--segments", json.dumps(backwards), now="2026-10-27T09:08:00Z", ok=False)

    def test_edit_active_time_ahead_of_now_is_stored_as_now(self):
        # A start inside the minute's tolerance, then a crash: the segment must
        # not sit ahead of the heartbeat, and confirm must still pass.
        self.run_cmd("start", "--boot-id", "b1", now="2026-10-27T08:00:00Z")
        v = self.run_cmd("edit-active", "--segments", json.dumps([{"start": "2026-10-27T08:01:00Z", "end": None}]), now="2026-10-27T08:00:30Z")["view"]
        self.assertEqual(v["active"]["openStart"], "2026-10-27T08:00:30Z")
        self.run_cmd("recover", "--boot-id", "b2", now="2026-10-27T08:05:00Z")
        self.run_cmd("resume", now="2026-10-27T08:06:00Z")
        self.run_cmd("stop", now="2026-10-27T08:30:00Z")
        self.run_cmd("confirm", "--summary", "Recovered", now="2026-10-27T08:31:00Z")
        self.assertEqual(len(self.log()["sessions"][0]["segments"]), 1)

    def test_confirm_drops_an_empty_segment(self):
        # What the panel's form does; the saved rows of the IPC confirm too.
        self.run_cmd("start", now="2026-10-27T09:00:00Z")
        self.run_cmd("pause", now="2026-10-27T09:00:00Z")
        self.run_cmd("resume", now="2026-10-27T09:10:00Z")
        self.run_cmd("stop", now="2026-10-27T09:30:00Z")
        self.run_cmd("confirm", "--summary", "Work", now="2026-10-27T09:31:00Z")
        self.assertEqual(len(self.log()["sessions"][0]["segments"]), 1)

    def test_a_session_of_empty_segments_stays_refused_at_confirm(self):
        self.run_cmd("start", now="2026-10-27T09:00:00Z")
        self.run_cmd("stop", now="2026-10-27T09:00:00Z")
        r = self.run_cmd("confirm", "--summary", "Nothing", now="2026-10-27T09:01:00Z", ok=False)
        self.assertIn("nothing worked", r["error"])

    # -------------------------------------------------------------- bounds

    def test_a_ledger_over_the_bound_is_refused_and_left_alone(self):
        self.run_cmd("add", "--segments", json.dumps([{"start": "2026-10-26T08:00:00Z", "end": "2026-10-26T10:00:00Z"}]), "--summary", "kept")
        log = self.log()
        # Pad the ledger past 1 MB with a field the helper keeps as it is.
        log["padding"] = "x" * (1 << 20)
        path = os.path.join(self.dir, "worklog.json")
        with open(path, "w") as f:
            json.dump(log, f)
        with open(path, "rb") as f:
            before = f.read()
        r = self.run_cmd("view", ok=False, env_extra={"WORKLOG_MAX_LEDGER_MB": "1"})
        self.assertIn("over 1 MB", r["error"])
        self.assertEqual(r["field"], "data")
        with open(path, "rb") as f:
            self.assertEqual(f.read(), before)
        self.assertEqual([n for n in os.listdir(self.dir) if "corrupt" in n], [])
        # A higher bound opens it, history intact.
        v = self.run_cmd("view", env_extra={"WORKLOG_MAX_LEDGER_MB": "4"})["view"]
        self.assertEqual(v["recent"][0]["summary"], "kept")

    def test_old_sessions_leave_the_view_figures_alone(self):
        recent = [{"start": "2026-10-26T08:00:00Z", "end": "2026-10-26T11:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(recent), "--summary", "recent")
        before = self.run_cmd("view")["view"]
        old = [{"start": "2025-03-03T08:00:00Z", "end": "2025-03-03T12:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(old), "--summary", "old")
        after = self.run_cmd("view")["view"]
        for k in ("week", "month", "trend", "today"):
            self.assertEqual(after[k], before[k], k)
        self.assertEqual(after["companies"][0]["sessionCount"], 2)
        # The old work is still there for its own week.
        r = self.run_cmd("sessions", "--week", "2025-W10")
        self.assertEqual(r["sessions"]["figures"]["workedSec"], 4 * 3600)


    def test_a_fifo_at_the_ledger_path_is_refused_without_hanging(self):
        path = os.path.join(self.dir, "worklog.json")
        os.mkfifo(path, 0o600)
        started = time.monotonic()
        r = self.run_cmd("view", ok=False)
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn("not a regular file", r["error"])
        self.assertTrue(os.path.exists(path))
        self.assertEqual([n for n in os.listdir(self.dir) if "corrupt" in n], [])

    def test_a_dangling_link_at_a_report_name_is_skipped(self):
        self.run_cmd("add", "--segments", json.dumps([{"start": "2026-10-26T08:00:00Z", "end": "2026-10-26T10:00:00Z"}]), "--summary", "x")
        out = os.path.join(self.dir, "reports")
        os.mkdir(out)
        first = self.run_cmd("export", "--week", "this", "--out", out)["export"]
        target = os.path.join(self.dir, "elsewhere.md")
        name = os.path.basename(first["markdown"]).replace(".md", "-2.md")
        os.symlink(target, os.path.join(out, name))
        second = self.run_cmd("export", "--week", "this", "--out", out)["export"]
        self.assertTrue(second["markdown"].endswith("-3.md"), second)
        self.assertFalse(os.path.exists(target))

    def test_the_answer_is_ascii_whatever_the_text(self):
        segs = [{"start": "2026-10-26T08:00:00Z", "end": "2026-10-26T10:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(segs), "--summary", "Revisión del menú, año 2026 ñ € 😀")
        env = dict(os.environ, WORKLOG_DATA_DIR=self.dir, WORKLOG_NOW=self.now, WORKLOG_TZ="Europe/Madrid")
        argv = ["month", "--month", "this", "--company", "all", "--config", json.dumps({"legacy": FIXTURE_TERMS})]
        p = subprocess.run([sys.executable, "-I", HELPER, "--stdin"], input=json.dumps(argv).encode(), env=env, capture_output=True)
        self.assertTrue(all(b < 128 for b in p.stdout), "non-ASCII byte in the answer")
        self.assertIn("Revisión del menú, año 2026 ñ € 😀", json.dumps(json.loads(p.stdout), ensure_ascii=False))

    def test_a_save_past_the_bound_is_refused_and_the_session_still_stops(self):
        env = {"WORKLOG_MAX_LEDGER_MB": "1"}
        self.run_cmd("start", now="2026-10-27T08:00:00Z", env_extra=env)
        path = os.path.join(self.dir, "worklog.json")
        before = b""
        for n in range(1000):
            day = "2025-%02d-%02d" % (1 + n // 28 % 12, 1 + n % 28)
            segs = [{"start": day + "T%02d:00:00Z" % (n // 336), "end": day + "T%02d:30:00Z" % (n // 336)}]
            r = self.run_cmd("add", "--segments", json.dumps(segs), "--summary", "x" * 2000, now="2026-10-27T08:10:00Z", ok=None, env_extra=env)
            if not r["ok"]:
                self.assertIn("saving would take worklog.json over 1 MB", r["error"])
                break
            with open(path, "rb") as f:
                before = f.read()
        else:
            self.fail("never refused")
        self.assertLessEqual(len(before), 1 << 20)
        with open(path, "rb") as f:
            self.assertEqual(f.read(), before)
        # The ledger stays readable, and the live session can still pause and stop.
        self.run_cmd("view", env_extra=env)
        self.run_cmd("pause", now="2026-10-27T09:00:00Z", env_extra=env)
        self.run_cmd("resume", now="2026-10-27T09:05:00Z", env_extra=env)
        self.run_cmd("stop", now="2026-10-27T09:30:00Z", env_extra=env)

    def test_a_fifo_at_the_lock_path_is_refused_without_hanging(self):
        os.mkfifo(os.path.join(self.dir, ".lock"), 0o600)
        started = time.monotonic()
        r = self.run_cmd("view", ok=False)
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn("lock file", r["error"])

    def test_old_sessions_leave_the_month_page_alone(self):
        recent = [{"start": "2026-10-26T08:00:00Z", "end": "2026-10-26T11:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(recent), "--summary", "recent")
        before = self.run_cmd("month", "--month", "this", "--company", "all")["month"]
        old = [{"start": "2025-03-03T08:00:00Z", "end": "2025-03-03T12:00:00Z"}]
        self.run_cmd("add", "--segments", json.dumps(old), "--summary", "old")
        after = self.run_cmd("month", "--month", "this", "--company", "all")["month"]
        self.assertEqual(after, before)
        older = self.run_cmd("month", "--month", "2025-03", "--company", "all")["month"]
        self.assertEqual(sum(d["workedSec"] for d in older["days"]), 4 * 3600)

if __name__ == "__main__":
    unittest.main()
