"""Data layer tests: python3 -m unittest discover -s tests"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

FIXTURE_TERMS = {"weeklyTargetHours": 12, "monthlyHours": 48, "monthlyFee": 1800, "standardRate": 60}

HELPER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "worklog.py")


class Helper(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.out = os.path.join(self.dir, "out")
        self.now = "2026-10-27T15:00:00Z"  # Tuesday 16:00 in Madrid (CET after the DST change)

    def tearDown(self):
        self.tmp.cleanup()

    def run_cmd(self, *args, now=None, ok=True, config=None):
        env = dict(os.environ, WORKLOG_DATA_DIR=self.dir, WORKLOG_NOW=now or self.now, WORKLOG_TZ="Europe/Madrid")
        argv = [sys.executable, "-I", HELPER] + list(args)
        # Fixtures assume a 48 h / 1.800 / 60 €/h package: seeded as v1 settings.
        config = dict(config or {})
        if "legacy" not in config and not any(k in config for k in FIXTURE_TERMS):
            config["legacy"] = FIXTURE_TERMS
        argv += ["--config", json.dumps(config)]
        p = subprocess.run(argv, env=env, capture_output=True, text=True)
        result = json.loads(p.stdout)
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
        self.assertEqual(w["targetSec"], 12 * 3600)
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
        self.assertEqual(m["targetSec"], 48 * 3600)
        self.assertEqual(m["workedSec"], 10 * 3600)
        self.assertEqual(m["elapsedDays"], 27)
        self.assertEqual(m["daysLeft"], 5)
        money = m["money"]
        self.assertTrue(money["projected"])
        self.assertEqual(money["standardValue"], 2880)
        self.assertEqual(money["discount"], 1080)
        self.assertEqual(money["discountPercent"], 37.5)
        self.assertEqual(money["effectiveRate"], 37.5)

    def test_money_over_the_package(self):
        segs = [{"start": "2026-10-%02dT07:00:00Z" % d, "end": "2026-10-%02dT17:00:00Z" % d} for d in range(1, 7)]
        for s in segs:
            self.run_cmd("add", "--segments", json.dumps([s]), "--summary", "long day")
        money = self.run_cmd("view")["view"]["month"]["money"]
        self.assertFalse(money["projected"])
        self.assertEqual(money["standardValue"], 60 * 60)
        self.assertEqual(money["overHours"], 12)
        # The 12 h over the package are billed at the extra hour rate (the standard rate by default).
        self.assertEqual((money["fee"], money["overageNet"], money["net"]), (1800, 720, 2520))
        self.assertEqual(money["effectiveRate"], 42)

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
        self.assertIn("1.800,00 € + IVA 21 % (378,00 €) = 2.178,00 €", md)
        self.assertIn("2.880,00 €", md)
        self.assertIn("1.080,00 € (37,5 %)", md)
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
                     "--terms", json.dumps({"monthlyHours": 48}), now=now)
        for month in ("2026-10", "2026-11"):
            r = self.run_cmd("export", "--month", month, "--out", self.out, now=now)["export"]
            with open(r["csv"], encoding="utf-8") as f:
                rows = f.read().splitlines()
            self.assertEqual(rows[1].split(",")[4], "60", (month, rows))
            with open(r["markdown"], encoding="utf-8") as f:
                self.assertIn("Worked: 1h of 48h owed.", f.read())

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


if __name__ == "__main__":
    unittest.main()
