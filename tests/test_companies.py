"""Companies, contract periods and billing cycles (v2):
python3 -m unittest discover -s tests"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

FIXTURE_TERMS = {"weeklyTargetHours": 12, "monthlyHours": 48, "monthlyFee": 1800, "standardRate": 60}
from datetime import date

HELPER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "worklog.py")
NOW = "2026-10-27T15:00:00Z"  # Tuesday 16:00 in Madrid


def load_module():
    spec = importlib.util.spec_from_file_location("worklog_mod_v2", HELPER)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


W = load_module()


def seg(start, end):
    return {"start": start, "end": end}


class Companies(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.out = os.path.join(self.dir, "out")

    def tearDown(self):
        self.tmp.cleanup()

    def run_cmd(self, *args, now=NOW, ok=True, config=None):
        env = dict(os.environ, WORKLOG_DATA_DIR=self.dir, WORKLOG_NOW=now, WORKLOG_TZ="Europe/Madrid")
        argv = list(args)
        # Fixtures assume a 48 h / 1.800 / 60 €/h package: seeded as v1 settings.
        config = dict(config or {})
        if "legacy" not in config and not any(k in config for k in FIXTURE_TERMS):
            config["legacy"] = FIXTURE_TERMS
        argv += ["--config", json.dumps(config)]
        # The way the shell calls it: the arguments as JSON on stdin.
        p = subprocess.run([sys.executable, "-I", HELPER, "--stdin"], input=json.dumps(argv), env=env, capture_output=True, text=True)
        result = json.loads(p.stdout)
        self.assertEqual(result["ok"], ok, result)
        return result

    def log(self):
        with open(os.path.join(self.dir, "worklog.json")) as f:
            return json.load(f)

    def add(self, segments, summary="work", company=None, now=NOW):
        args = ["add", "--segments", json.dumps(segments), "--summary", summary]
        if company:
            args += ["--company", company]
        return self.run_cmd(*args, now=now)

    def terms(self, cid, frm, now=NOW, replace=None, **kw):
        kw.setdefault("standardRate", 60)
        args = ["contract", "--action", "set", "--id", cid, "--from", frm, "--terms", json.dumps(kw)]
        if replace:
            args += ["--replace", replace]
        return self.run_cmd(*args, now=now)

    def company(self, name, cycle_day=1, now=NOW):
        r = self.run_cmd("company", "--action", "add", "--name", name, "--cycle-day", str(cycle_day), now=now)
        return r["company"]

    def month(self, key, company, now=NOW):
        return self.run_cmd("month", "--month", key, "--company", company, now=now)["month"]

    def figures(self, key, company, now=NOW):
        return self.month(key, company, now)["companies"][0]["figures"]

    # -------------------------------------------------------------- 1

    def test_migration_from_v1(self):
        v1 = {"version": 1, "sessions": [
            {"id": "s_1", "client": "", "segments": [seg("2026-10-22T08:00:00Z", "2026-10-22T10:00:00Z")],
             "summary": "old", "tags": [], "source": "timer"}]}
        raw = json.dumps(v1)
        with open(os.path.join(self.dir, "worklog.json"), "w") as f:
            f.write(raw)
        active = {"version": 1, "state": "paused", "session": {"id": "s_2", "client": "",
                  "segments": [seg("2026-10-27T08:00:00Z", "2026-10-27T09:00:00Z")]}}
        with open(os.path.join(self.dir, "active.json"), "w") as f:
            json.dump(active, f)
        r = self.run_cmd("view", config={"legacy": {"monthlyFee": 1500, "monthlyHours": 40}})
        self.assertEqual(r["view"]["migrated"], {"from": 1, "company": "c_0001"})
        log = self.log()
        self.assertEqual(log["version"], 2)
        c = log["companies"][0]
        self.assertEqual((c["name"], c["tag"], c["cycleDay"]), ("Company", "CO", 1))
        self.assertEqual(c["contracts"][0]["from"], "2026-10-01")
        self.assertEqual(c["contracts"][0]["monthlyFee"], 1500)
        self.assertEqual(c["contracts"][0]["monthlyHours"], 40)
        self.assertEqual(log["sessions"][0]["company"], "c_0001")
        self.assertNotIn("client", log["sessions"][0])
        with open(os.path.join(self.dir, "backups", "worklog-v1-2026-10-27.json")) as f:
            self.assertEqual(f.read(), raw)
        with open(os.path.join(self.dir, "active.json")) as f:
            self.assertEqual(json.load(f)["session"]["company"], "c_0001")
        self.assertIsNone(self.run_cmd("view")["view"]["migrated"])
        # The daily rotation never removes the v1 copy.
        for d in range(1, 32):
            name = os.path.join(self.dir, "backups", "worklog-2026-09-%02d.json" % d) if d <= 30 else None
            if name:
                open(name, "w").close()
        self.add([seg("2026-10-27T10:00:00Z", "2026-10-27T11:00:00Z")])
        self.assertTrue(os.path.exists(os.path.join(self.dir, "backups", "worklog-v1-2026-10-27.json")))

    def test_newer_version_refused_and_left_alone(self):
        with open(os.path.join(self.dir, "worklog.json"), "w") as f:
            f.write('{"version": 3, "sessions": []}')
        r = self.run_cmd("view", ok=False)
        self.assertIn("version 3", r["error"])
        with open(os.path.join(self.dir, "worklog.json")) as f:
            self.assertEqual(f.read(), '{"version": 3, "sessions": []}')

    # -------------------------------------------------------------- 2

    def test_cycle_bounds(self):
        d = date
        self.assertEqual(W.cycle_bounds(21, "2026-10"), (d(2026, 10, 21), d(2026, 11, 20)))
        self.assertEqual(W.cycle_of(21, d(2026, 10, 20)), "2026-09")
        self.assertEqual(W.cycle_of(21, d(2026, 10, 21)), "2026-10")
        seq = [W.cycle_bounds(31, "2026-%02d" % m) for m in range(1, 6)]
        self.assertEqual(seq, [(d(2026, 1, 31), d(2026, 2, 27)), (d(2026, 2, 28), d(2026, 3, 30)),
                               (d(2026, 3, 31), d(2026, 4, 29)), (d(2026, 4, 30), d(2026, 5, 30)),
                               (d(2026, 5, 31), d(2026, 6, 29))])
        self.assertEqual(W.cycle_bounds(29, "2027-02")[0], d(2027, 2, 28))
        self.assertEqual(W.cycle_bounds(29, "2028-02")[0], d(2028, 2, 29))
        self.assertEqual(W.cycle_bounds(1, "2026-02"), (d(2026, 2, 1), d(2026, 2, 28)))
        self.assertEqual(W.cycle_of(31, d(2026, 3, 30)), "2026-02")
        self.assertEqual(W.cycle_label(21, d(2026, 10, 21), d(2026, 11, 20)), "21 Oct to 20 Nov 2026")
        self.assertEqual(W.cycle_label(21, d(2026, 12, 21), d(2027, 1, 20)), "21 Dec 2026 to 20 Jan 2027")
        self.assertEqual(W.cycle_label(21, d(2026, 10, 21), d(2026, 11, 20), "es"), "21 oct a 20 nov de 2026")
        self.assertEqual(W.cycle_label(1, d(2026, 10, 1), d(2026, 10, 31), "es"), "octubre de 2026")

    # -------------------------------------------------------------- 3

    def test_terms_in_force_and_uncontracted(self):
        self.run_cmd("company", "--action", "rename", "--id", "c_0001", "--cycle-day", "21")
        self.terms("c_0001", "2026-10-21", replace="2026-10-01", monthlyHours=48, monthlyFee=1800)
        self.terms("c_0001", "2027-01-21", monthlyHours=60, monthlyFee=2250)
        now = "2027-03-01T10:00:00Z"
        self.assertEqual(self.figures("2026-12", "c_0001", now)["parts"][0]["monthlyFee"], 1800)
        self.assertEqual(self.figures("2027-01", "c_0001", now)["parts"][0]["monthlyFee"], 2250)
        sep = self.figures("2026-09", "c_0001", now)
        self.assertEqual(sep["billing"], "none")
        self.assertEqual(sep["targetSec"], 0)
        self.assertEqual(sep["money"]["net"], 0)

    def test_partial_first_month_under_calendar_cycles(self):
        self.terms("c_0001", "2026-10-21", replace="2026-10-01", monthlyHours=48, monthlyFee=1800)
        f = self.figures("2026-10", "c_0001")
        self.assertEqual(f["billing"], "mixed")
        self.assertEqual(f["targetSec"], round(48 * 3600 * 11 / 31 / 60) * 60)
        self.assertEqual(f["money"]["net"], round(1800 * 11 / 31, 2))

    # -------------------------------------------------------------- 4

    def test_mid_cycle_change_prorated(self):
        self.terms("c_0001", "2026-11-01", replace="2026-10-01", monthlyHours=48, monthlyFee=1800)
        self.terms("c_0001", "2026-11-16", monthlyHours=60, monthlyFee=2250)
        now = "2026-11-20T20:00:00Z"
        for day in range(2, 8):
            self.add([seg("2026-11-%02dT07:00:00Z" % day, "2026-11-%02dT16:00:00Z" % day)], now=now)
        f = self.figures("2026-11", "c_0001", now)
        self.assertEqual([p["days"] for p in f["parts"]], [15, 15])
        self.assertEqual(f["targetSec"], 54 * 3600)
        self.assertEqual(f["expectedSec"], 34 * 3600)
        m = f["money"]
        self.assertEqual((m["net"], m["vat"], m["gross"]), (2025, 425.25, 2450.25))
        self.assertEqual((m["standardValue"], m["discount"], m["effectiveRate"]), (3240, 1215, 37.5))
        on10 = self.run_cmd("view", now="2026-11-10T12:00:00Z")["view"]["month"]
        self.assertEqual(on10["expectedSec"], 16 * 3600)
        self.terms("c_0001", "2026-11-16", billing="hourly", standardRate=70, now=now)
        f = self.figures("2026-11", "c_0001", now)
        self.assertEqual(f["billing"], "mixed")
        self.assertEqual(len(f["money"]["lines"]), 2)
        self.assertIsNone(f["money"]["discount"])

    # -------------------------------------------------------------- 5

    def test_fee_change_does_not_alter_past_cycles(self):
        self.run_cmd("company", "--action", "rename", "--id", "c_0001", "--cycle-day", "21")
        self.terms("c_0001", "2026-10-21", replace="2026-10-01", monthlyHours=48, monthlyFee=1800)
        now = "2026-11-25T10:00:00Z"
        self.add([seg("2026-10-27T08:00:00Z", "2026-10-27T12:00:00Z")], now=now)
        before = self.month("2026-10", "c_0001", now)
        r1 = self.run_cmd("export", "--month", "2026-10", "--out", self.out, now=now)["export"]
        self.terms("c_0001", "2026-11-21", monthlyHours=48, monthlyFee=2000, now=now)
        self.assertEqual(self.month("2026-10", "c_0001", now), before)
        r2 = self.run_cmd("export", "--month", "2026-10", "--out", self.out, now=now)["export"]
        for kind in ("markdown", "csv", "html"):
            with open(r1[kind]) as a, open(r2[kind]) as b:
                self.assertEqual(a.read(), b.read(), kind)
        self.assertEqual(self.figures("2026-11", "c_0001", now)["money"]["net"], 2000)

    # -------------------------------------------------------------- 6

    def test_hourly_company(self):
        self.terms("c_0001", "2026-10-01", billing="hourly", standardRate=60, vatPercent=21)
        self.add([seg("2026-10-05T08:00:00Z", "2026-10-05T18:00:00Z")])
        f = self.figures("2026-10", "c_0001")
        self.assertEqual(f["targetSec"], 0)
        self.assertEqual((f["money"]["net"], f["money"]["gross"]), (600, 726))
        self.assertIsNone(f["money"]["discount"])
        r = self.run_cmd("export", "--month", "this", "--out", self.out)["export"]
        with open(r["markdown"]) as fh:
            md = fh.read()
        self.assertIn("Billed at 60,00 €/h: 600,00 € + VAT 21 % (126,00 €) = 726,00 €.", md)
        self.assertNotIn("owed", md)
        bad = self.run_cmd("contract", "--action", "set", "--id", "c_0001", "--from", "2026-10-01",
                           "--terms", json.dumps({"billing": "package", "monthlyHours": 0}), ok=False)
        self.assertEqual(bad["field"], "terms.monthlyHours")

    # -------------------------------------------------------------- 7

    def test_company_scoping(self):
        b = self.company("Beta Labs", cycle_day=21)
        self.add([seg("2026-10-26T08:00:00Z", "2026-10-26T10:00:00Z")], company="c_0001")
        self.add([seg("2026-10-27T08:00:00Z", "2026-10-27T11:00:00Z")], company=b)
        v = self.run_cmd("view")["view"]
        self.assertEqual(v["currentCompany"], "c_0001")
        self.assertEqual(v["week"]["workedSec"], 2 * 3600)
        self.assertEqual(v["today"]["workedSec"], 3 * 3600)
        self.assertEqual(v["month"]["workedSec"], 2 * 3600)
        m = self.month("2026-10", "all")
        self.assertEqual([c["name"] for c in m["companies"]], ["Beta Labs", "Company"])
        self.assertEqual(m["companies"][0]["figures"]["key"], "2026-10")  # starts 21 Oct
        self.assertEqual(m["companies"][0]["figures"]["workedSec"], 3 * 3600)
        self.assertEqual(len(m["invoice"]), 1)
        self.assertEqual(m["workedSec"], 5 * 3600)

    # -------------------------------------------------------------- 8

    def test_cycle_boundaries(self):
        self.run_cmd("company", "--action", "rename", "--id", "c_0001", "--cycle-day", "21")
        now = "2026-11-25T10:00:00Z"
        self.add([seg("2026-11-20T22:00:00Z", "2026-11-21T00:00:00Z")], now=now)
        oct_ = self.month("2026-10", "c_0001", now)
        nov = self.month("2026-11", "c_0001", now)
        self.assertEqual((oct_["workedSec"], nov["workedSec"]), (3600, 3600))
        # Listed under each day it has work on, in both cycles.
        self.assertEqual([d["date"] for d in oct_["days"] if d["sessions"]], ["2026-11-20"])
        self.assertEqual([d["date"] for d in nov["days"] if d["sessions"]], ["2026-11-21"])
        self.assertEqual(len(oct_["days"]), 31)
        boundary = [w for w in nov["weeks"] if w["start"] == "2026-11-16"][0]
        self.assertEqual((boundary["daysInCycle"], boundary["workedSec"]), (2, 3600))
        self.run_cmd("company", "--action", "rename", "--id", "c_0001", "--cycle-day", "1", now=now)
        self.assertEqual(len(self.month("2027-02", "c_0001", now)["days"]), 28)

    # -------------------------------------------------------------- 9

    def test_start_uses_current_company(self):
        b = self.company("Beta Labs")
        v = self.run_cmd("start", "--company", "beta labs", now="2026-10-27T08:00:00Z")["view"]
        self.assertEqual(v["currentCompany"], b)
        self.assertEqual(v["active"]["company"], b)
        self.run_cmd("discard")
        self.assertEqual(self.run_cmd("start")["view"]["active"]["company"], b)
        self.run_cmd("discard")
        self.run_cmd("company", "--action", "archive", "--id", b)
        r = self.run_cmd("start", "--company", b, ok=False)
        self.assertIn("archived", r["error"])

    # -------------------------------------------------------------- 10

    def test_archive_rules(self):
        b = self.company("Beta Labs")
        self.run_cmd("company", "--action", "use", "--id", b)
        self.add([seg("2026-10-26T08:00:00Z", "2026-10-26T09:00:00Z")], company=b)
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        r = self.run_cmd("company", "--action", "archive", "--id", b, ok=False)
        self.assertIn("live session", r["error"])
        self.run_cmd("discard")
        v = self.run_cmd("company", "--action", "archive", "--id", b)["view"]
        self.assertEqual(v["currentCompany"], "c_0001")
        self.assertTrue([c for c in v["companies"] if c["id"] == b][0]["archived"])
        self.assertEqual(len(self.month("2026-10", "all")["companies"]), 1)
        self.assertEqual(len(self.run_cmd("sessions", "--week", "this")["sessions"]["sessions"]), 1)
        self.assertIn("archived", self.run_cmd("company", "--action", "use", "--id", b, ok=False)["error"])
        r = self.run_cmd("company", "--action", "delete", "--id", b, ok=False)
        self.assertIn("1 sessions", r["error"])
        self.run_cmd("company", "--action", "unarchive", "--id", b)
        r = self.run_cmd("company", "--action", "archive", "--id", "c_0001")
        self.assertEqual(r["view"]["currentCompany"], b)
        self.assertIn("only active", self.run_cmd("company", "--action", "archive", "--id", b, ok=False)["error"])
        c = self.company("Gamma")
        self.run_cmd("company", "--action", "delete", "--id", c)
        self.assertNotIn(c, [x["id"] for x in self.log()["companies"]])

    def test_last_company_cannot_be_deleted(self):
        self.add([seg("2026-10-26T08:00:00Z", "2026-10-26T09:00:00Z")])
        self.run_cmd("delete", "--id", self.log()["sessions"][0]["id"])
        self.assertIn("last company", self.run_cmd("company", "--action", "delete", "--id", "c_0001", ok=False)["error"])

    # -------------------------------------------------------------- 11

    def test_company_validation(self):
        self.company("Beta Labs")
        cases = [
            (["company", "--action", "add", "--name", "beta LABS"], "name"),
            (["company", "--action", "add", "--name", "  "], "name"),
            (["company", "--action", "add", "--name", "x" * 41], "name"),
            (["company", "--action", "add", "--name", "Ok", "--tag", "ABCDE"], "tag"),
            (["company", "--action", "add", "--name", "Ok", "--cycle-day", "0"], "cycleDay"),
            (["company", "--action", "add", "--name", "Ok", "--cycle-day", "32"], "cycleDay"),
            (["contract", "--action", "delete", "--id", "c_0001", "--from", "2026-10-01"], "from"),
            (["contract", "--action", "set", "--id", "c_0001", "--from", "2026-13-01", "--terms", "{}"], "from"),
            (["contract", "--action", "set", "--id", "c_0001", "--from", "2026-11-01", "--terms", '{"vatPercent": 101}'], "terms.vatPercent"),
            (["contract", "--action", "set", "--id", "c_0001", "--from", "2026-11-01", "--terms", '{"currency": "EUROS"}'], "terms.currency"),
            (["contract", "--action", "set", "--id", "c_0001", "--from", "2026-11-01", "--replace", "2026-01-01", "--terms", "{}"], "from"),
            (["add", "--segments", json.dumps([seg("2026-10-26T08:00:00Z", "2026-10-26T09:00:00Z")]), "--summary", "x", "--company", "nope"], "company"),
        ]
        for args, field in cases:
            self.assertEqual(self.run_cmd(*args, ok=False)["field"], field, args)

    # -------------------------------------------------------------- 12

    def test_session_company_edit(self):
        b = self.company("Beta Labs")
        self.add([seg("2026-10-26T08:00:00Z", "2026-10-26T10:00:00Z")])
        sid = self.log()["sessions"][0]["id"]
        self.run_cmd("update", "--id", sid, "--company", b)
        self.assertEqual(self.log()["sessions"][0]["company"], b)
        self.assertEqual(self.figures("2026-10", b)["workedSec"], 7200)
        self.assertEqual(self.figures("2026-10", "c_0001")["workedSec"], 0)
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        self.run_cmd("edit-active", "--company", b, now="2026-10-27T09:00:00Z")
        self.run_cmd("stop", now="2026-10-27T10:00:00Z")
        self.run_cmd("confirm", "--summary", "x", "--company", "c_0001", now="2026-10-27T10:00:00Z")
        self.assertEqual(self.log()["sessions"][-1]["company"], "c_0001")

    # -------------------------------------------------------------- 13

    def test_reports(self):
        self.add([seg("2026-10-27T08:00:00Z", "2026-10-27T10:00:00Z")], summary="a < b <script>")
        r = self.run_cmd("export", "--month", "this", "--out", self.out)["export"]
        self.assertTrue(r["markdown"].endswith("worklog-2026-10.md"))
        with open(r["html"]) as f:
            page = f.read()
        self.assertIn("a &lt; b &lt;script&gt;", page)
        self.assertNotIn("<script", page)
        with open(r["markdown"]) as f:
            md = f.read()
        self.assertIn("# Work report for Company, October 2026", md)
        self.assertIn("Terms: package of 48h a cycle, 1.800,00 € + VAT 21 %, standard rate 60,00 €/h, extra hours at 60,00 €/h, calendar month.", md)
        self.assertIn("Worked: 2h of 48h owed. 46h under the package.", md)
        no_html = self.run_cmd("export", "--month", "this", "--out", self.out, config={"reportHtml": False})["export"]
        self.assertNotIn("html", no_html)
        b = self.company("Beta Labs", cycle_day=21)
        self.add([seg("2026-10-26T08:00:00Z", "2026-10-26T09:00:00Z")], company=b)
        r = self.run_cmd("export", "--month", "this", "--out", self.out)["export"]
        self.assertTrue(r["markdown"].endswith("worklog-company-2026-10.md"))
        with open(r["csv"]) as f:
            self.assertTrue(f.readline().startswith("date,company,"))
        es = self.run_cmd("export", "--month", "this", "--company", b, "--out", self.out, config={"reportLanguage": "es"})["export"]
        self.assertTrue(es["markdown"].endswith("worklog-beta-labs-2026-10-es.md"))
        with open(es["markdown"]) as f:
            md = f.read()
        self.assertIn("# Informe de trabajo para Beta Labs, 21 oct a 20 nov de 2026", md)
        self.assertIn("ciclo desde el día 21", md)
        week = self.run_cmd("export", "--week", "this", "--out", self.out)["export"]
        with open(week["markdown"]) as f:
            md = f.read()
        self.assertIn("| Day | Company | Time |", md)
        self.assertIn("Total: 3h.", md)
        every = self.run_cmd("export", "--month", "2026-10", "--company", "all", "--out", self.out)["export"]
        self.assertEqual(len(every["reports"]), 2)

    def test_report_split_and_uncontracted(self):
        self.terms("c_0001", "2026-11-06", replace="2026-10-01", monthlyHours=48, monthlyFee=1800)
        self.terms("c_0001", "2026-11-16", monthlyHours=60, monthlyFee=2250)
        now = "2026-12-02T10:00:00Z"
        self.add([seg("2026-11-02T08:00:00Z", "2026-11-02T10:00:00Z")], now=now)
        r = self.run_cmd("export", "--month", "2026-11", "--out", self.out, now=now)["export"]
        with open(r["markdown"]) as f:
            md = f.read()
        self.assertIn("Terms from 16 Nov 2026: package of 60h a cycle", md)
        self.assertIn("No terms before 6 Nov 2026: 2h not billed.", md)
        self.assertIn("Total:", md)
        self.terms("c_0001", "2026-11-01", monthlyHours=48, monthlyFee=1800, now=now)
        r = self.run_cmd("export", "--month", "2026-11", "--out", self.out, now=now)["export"]
        with open(r["markdown"]) as f:
            md = f.read()
        self.assertIn("prorated by days (5 + 10 + 15 days)", md)

    # -------------------------------------------------------------- extra hours

    def test_extra_hours_billed_or_waived(self):
        self.terms("c_0001", "2026-10-01", replace="2026-10-01", monthlyHours=10, monthlyFee=500, overageRate=45)
        self.add([seg("2026-10-05T07:00:00Z", "2026-10-05T19:00:00Z")])  # 12 h, 2 over
        m = self.figures("2026-10", "c_0001")["money"]
        self.assertEqual((m["overSec"], m["overageRate"], m["overageNet"]), (7200, 45, 90))
        self.assertEqual((m["fee"], m["net"], m["vat"], m["gross"]), (500, 590, 123.9, 713.9))
        r = self.run_cmd("export", "--month", "2026-10", "--out", self.out)["export"]
        with open(r["markdown"]) as f:
            md = f.read()
        self.assertIn("Package fee: 500,00 €.", md)
        self.assertIn("Extra hours: 2h at 45,00 €/h = 90,00 €.", md)
        self.assertIn("Total: 590,00 € + VAT 21 % (123,90 €) = 713,90 €.", md)
        self.run_cmd("overage", "--action", "waive", "--id", "c_0001", "--month", "2026-10")
        m = self.figures("2026-10", "c_0001")["money"]
        self.assertTrue(m["overageWaived"])
        self.assertEqual((m["net"], m["gross"]), (500, 605))
        r = self.run_cmd("export", "--month", "2026-10", "--out", self.out, config={"reportLanguage": "es"})["export"]
        with open(r["markdown"]) as f:
            self.assertIn("Horas extra: 2h a 45,00 €/h = 90,00 €, no facturadas.", f.read())
        self.run_cmd("overage", "--action", "bill", "--id", "c_0001", "--month", "2026-10")
        self.assertEqual(self.figures("2026-10", "c_0001")["money"]["net"], 590)
        self.assertEqual(self.run_cmd("overage", "--action", "waive", "--id", "c_0001", "--month", "x", ok=False)["field"], "month")

    def test_extra_hour_rate_defaults_to_the_standard_rate(self):
        self.terms("c_0001", "2026-11-01", standardRate=70)
        c = self.log()["companies"][0]
        self.assertEqual(c["contracts"][-1]["overageRate"], 70)
        bad = self.run_cmd("contract", "--action", "set", "--id", "c_0001", "--from", "2026-11-01",
                           "--terms", json.dumps({"overageRate": -1}), ok=False)
        self.assertEqual(bad["field"], "terms.overageRate")

    # -------------------------------------------------------------- Codex review 2026-10-28

    def test_report_splits_a_session_over_a_terms_change(self):
        # F1: hourly 60 €/h, then 120 €/h from 16 Nov; one session across local midnight.
        self.terms("c_0001", "2026-11-01", replace="2026-10-01", billing="hourly", standardRate=60, vatPercent=0)
        self.terms("c_0001", "2026-11-16", billing="hourly", standardRate=120, vatPercent=0)
        now = "2026-12-02T10:00:00Z"
        self.add([seg("2026-11-15T22:00:00Z", "2026-11-16T00:00:00Z")], now=now)
        self.assertEqual(self.figures("2026-11", "c_0001", now)["money"]["net"], 180)
        r = self.run_cmd("export", "--month", "2026-11", "--out", self.out, now=now)["export"]
        with open(r["markdown"]) as f:
            md = f.read()
        self.assertIn("1 to 15 Nov, 1h at 60,00 €/h: 60,00 €.", md)
        self.assertIn("16 to 30 Nov, 1h at 120,00 €/h: 120,00 €.", md)
        self.assertIn("Total: 180,00 €", md)

    def test_currency_changes_only_on_a_cycle_start(self):
        # F3: two currencies never add up in one cycle.
        r = self.run_cmd("contract", "--action", "set", "--id", "c_0001", "--from", "2026-11-16",
                         "--terms", json.dumps({"currency": "USD"}), ok=False)
        self.assertEqual(r["field"], "from")
        self.terms("c_0001", "2026-11-01", currency="USD")
        r = self.run_cmd("company", "--action", "rename", "--id", "c_0001", "--cycle-day", "21", ok=False)
        self.assertIn("mid-cycle", r["error"])
        self.assertEqual(self.log()["companies"][0]["cycleDay"], 1)

    def test_migration_counts_a_pending_v1_session(self):
        # F4: an ending v1 session in October keeps October contracted.
        with open(os.path.join(self.dir, "worklog.json"), "w") as f:
            json.dump({"version": 1, "sessions": []}, f)
        with open(os.path.join(self.dir, "active.json"), "w") as f:
            json.dump({"version": 1, "state": "ending", "session": {"id": "s_9", "client": "",
                       "segments": [seg("2026-10-27T08:00:00Z", "2026-10-27T09:00:00Z")]}}, f)
        now = "2026-11-20T10:00:00Z"
        self.run_cmd("view", now=now)
        self.assertEqual(self.log()["companies"][0]["contracts"][0]["from"], "2026-10-01")
        self.assertTrue(os.path.exists(os.path.join(self.dir, "backups", "active-v1-2026-11-20.json")))
        self.run_cmd("confirm", "--summary", "pending", now=now)
        self.assertEqual(self.figures("2026-10", "c_0001", now)["billing"], "package")

    def test_unknown_company_in_a_v2_active_file_is_refused(self):
        # F7: never re-bill a damaged reference to another company.
        self.run_cmd("start", now="2026-10-27T08:00:00Z")
        path = os.path.join(self.dir, "active.json")
        with open(path) as f:
            active = json.load(f)
        active["session"]["company"] = "c_dead"
        text = json.dumps(active)
        with open(path, "w") as f:
            f.write(text)
        r = self.run_cmd("heartbeat", ok=False)
        self.assertEqual(r["field"], "data")
        with open(path) as f:
            self.assertEqual(f.read(), text)

    def test_stored_numbers_must_be_numbers(self):
        # F9: a string where a number belongs is refused on load, before any write.
        self.add([seg("2026-10-26T08:00:00Z", "2026-10-26T09:00:00Z")])
        path = os.path.join(self.dir, "worklog.json")
        for patch in ({"cycleDay": "1"}, {"contracts": [dict(self.log()["companies"][0]["contracts"][0], monthlyFee="1800")]}):
            data = self.log()
            data["companies"][0].update(patch)
            text = json.dumps(data)
            with open(path, "w") as f:
                f.write(text)
            r = self.run_cmd("company", "--action", "rename", "--id", "c_0001", "--name", "Changed", ok=False)
            self.assertEqual(r["field"], "data")
            with open(path) as f:
                self.assertEqual(f.read(), text)
            data["companies"][0]["cycleDay"] = 1
            data["companies"][0]["contracts"][0]["monthlyFee"] = 1800
            with open(path, "w") as f:
                json.dump(data, f)

    def test_markdown_report_escapes_the_data(self):
        # F5: no remote images, links or HTML from a summary.
        self.add([seg("2026-10-27T08:00:00Z", "2026-10-27T09:00:00Z")], summary='<img src="https://x.invalid/p"> [fake](https://x.invalid) *args')
        r = self.run_cmd("export", "--month", "this", "--out", self.out)["export"]
        with open(r["markdown"]) as f:
            md = f.read()
        self.assertNotRegex(md, r"(?<!\\)<img")
        self.assertIn(r'\<img src="https://x.invalid/p"\> \[fake\](https://x.invalid) \*args', md)

    def test_money_rounds_half_up_like_the_panel(self):
        # F2: 50.01 €/h for 30 minutes is 25.005: 25,01 € here and in Model.js.
        self.terms("c_0001", "2026-10-01", billing="hourly", standardRate=50.01, vatPercent=0)
        self.add([seg("2026-10-05T08:00:00Z", "2026-10-05T08:30:00Z")])
        self.assertEqual(self.figures("2026-10", "c_0001")["money"]["net"], 25.01)

    def test_moving_terms_onto_other_terms_is_refused(self):
        self.terms("c_0001", "2026-11-01", monthlyFee=1900)
        r = self.run_cmd("contract", "--action", "set", "--id", "c_0001", "--from", "2026-11-01", "--replace", "2026-10-01",
                         "--terms", json.dumps({"monthlyFee": 1800}), ok=False)
        self.assertIn("already start", r["error"])
        self.assertEqual(len(self.log()["companies"][0]["contracts"]), 2)

    def test_a_report_set_shares_one_name(self):
        os.makedirs(self.out)
        open(os.path.join(self.out, "worklog-2026-10.csv"), "w").close()
        r = self.run_cmd("export", "--month", "this", "--out", self.out)["export"]
        self.assertEqual({os.path.basename(r[k]) for k in ("csv", "markdown", "html")},
                         {"worklog-2026-10-2.csv", "worklog-2026-10-2.md", "worklog-2026-10-2.html"})

    def test_fresh_install_defaults_are_neutral(self):
        env = dict(os.environ, WORKLOG_DATA_DIR=self.dir, WORKLOG_NOW=NOW, WORKLOG_TZ="Europe/Madrid")
        p = subprocess.run([sys.executable, "-I", HELPER, "view"], env=env, capture_output=True, text=True)
        c = json.loads(p.stdout)["view"]["companies"][0]
        self.assertEqual((c["name"], c["cycleDay"]), ("Company", 1))
        t = c["inForce"]
        self.assertEqual((t["monthlyHours"], t["monthlyFee"], t["standardRate"], t["weeklyGuideHours"], t["overageRate"]), (40, 2000, 50, 10, 50))

    # -------------------------------------------------------------- 14

    def test_load_validation_companies(self):
        self.add([seg("2026-10-26T08:00:00Z", "2026-10-26T09:00:00Z")])
        path = os.path.join(self.dir, "worklog.json")
        good = self.log()
        cases = []
        bad = json.loads(json.dumps(good)); bad["sessions"][0]["company"] = "c_ffff"; cases.append(bad)
        bad = json.loads(json.dumps(good)); bad["companies"][0]["contracts"] = []; cases.append(bad)
        bad = json.loads(json.dumps(good)); bad["companies"][0]["contracts"] *= 2; cases.append(bad)
        for data in cases:
            text = json.dumps(data)
            with open(path, "w") as f:
                f.write(text)
            r = self.run_cmd("view", ok=False)
            self.assertEqual(r["field"], "data")
            with open(path) as f:
                self.assertEqual(f.read(), text)
        repaired = json.loads(json.dumps(good))
        repaired["companies"].append(dict(repaired["companies"][0], id="c_0002", name="Other", archived=True))
        repaired["currentCompany"] = "c_0002"
        with open(path, "w") as f:
            json.dump(repaired, f)
        self.assertEqual(self.run_cmd("view")["view"]["currentCompany"], "c_0001")

    # ------------------------------------------- found by the 0.3.0 review

    def test_half_cent_vat_rounds_up(self):
        self.terms("c_0001", "2026-10-01", monthlyFee=10.05, vatPercent=10)
        m = self.run_cmd("view")["view"]["month"]["money"]
        self.assertEqual((m["vat"], m["gross"]), (1.01, 11.06), m)

    def test_report_keeps_a_fractional_vat_rate(self):
        self.terms("c_0001", "2026-10-01", monthlyFee=100, vatPercent=7.5)
        out = self.run_cmd("export", "--month", "2026-10", "--company", "c_0001", "--out", self.out)["export"]
        with open(out["markdown"], encoding="utf-8") as f:
            md = f.read()
        self.assertIn("VAT 7,5 %", md)
        self.assertNotIn("VAT 8 %", md)

    def test_resume_cannot_overlap_a_confirmed_session_or_start_later(self):
        self.run_cmd("start", now="2026-10-28T08:00:00Z")
        self.run_cmd("pause", now="2026-10-28T09:00:00Z")
        self.add([seg("2026-10-28T09:00:00Z", "2026-10-28T10:00:00Z")], now="2026-10-28T12:00:00Z")
        r = self.run_cmd("resume", "--at", "2026-10-28T09:30:00Z", now="2026-10-28T12:00:00Z", ok=False)
        self.assertIn("overlaps", r["error"])
        r = self.run_cmd("resume", "--at", "2026-10-28T13:00:00Z", now="2026-10-28T12:00:00Z", ok=False)
        self.assertEqual(r["field"], "at")
        v = self.run_cmd("resume", now="2026-10-28T12:00:00Z")["view"]
        self.assertEqual(v["state"], "running")

    def test_month_lists_a_session_on_every_day_it_has_work(self):
        # 23:00 on 30 Sep to 02:00 on 1 Oct, Madrid: two hours count in October.
        self.add([seg("2026-09-30T21:00:00Z", "2026-10-01T00:00:00Z")], summary="Boundary work")
        month = self.run_cmd("month", "--month", "2026-10", "--company", "c_0001")["month"]
        day = month["days"][0]
        self.assertEqual(day["workedSec"], 7200)
        self.assertEqual([r["summary"] for r in day["sessions"]], ["Boundary work"])
        sept = self.run_cmd("month", "--month", "2026-09", "--company", "c_0001")["month"]
        self.assertEqual(len(sept["days"][-1]["sessions"]), 1)


if __name__ == "__main__":
    unittest.main()
