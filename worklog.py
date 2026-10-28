#!/usr/bin/env python3
"""Worklog data helper: the only writer of the worklog files.

Every command prints one JSON line, {"ok": true, "view": {...}} or
{"ok": false, "error": "...", "field": "..."}, and exits 0 or 1. Every
command that changes something returns the full view, so the shell assigns
one property and never computes totals itself.

Storage, under $WORKLOG_DATA_DIR or $XDG_DATA_HOME/omarchy-worklog:
  worklog.json   companies with their contract periods, and confirmed sessions
  active.json    the live session (running, paused or ending) and its draft
  backups/       a copy of worklog.json before the first write of each day,
                 and the v1 file kept for good by the upgrade to v2

A session is a list of work segments; a pause is the gap between two of them,
its reason stored on the segment it ended. Timestamps are UTC ISO-8601; days,
weeks (Monday first) and months are local time. Durations and amounts are
never stored.

A company bills by cycle: the calendar month (cycleDay 1) or a month that
starts on another day (cycleDay 21: the 21st to the 20th). Its terms are
contract periods that start on a date; a cycle uses the terms in force on
each of its days, prorated by days when they change inside it.

Test hooks: WORKLOG_NOW (ISO instant) fixes the clock, WORKLOG_TZ the zone.
"""

import argparse
import calendar
import csv
import fcntl
import html
import io
import json
import math
import os
import re
import secrets
import shutil
import sys
import tempfile
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

VERSION = 2
MIN_SEGMENT_SEC = 60
MAX_SUMMARY = 2000
MAX_TAG = 32
MAX_TAGS = 10
TREND_WEEKS = 8
RECENT = 3
BACKUPS_KEPT = 30
END_REASONS = ("manual", "lock", "idle", "suspend", "restart", "stop", "edited")
PAUSE_REASONS = ("manual", "lock", "idle", "suspend", "restart")
BILLING = ("package", "hourly")

# The company a fresh data folder starts with, and the one a v1 file becomes.
DEFAULT_COMPANY_ID = "c_0001"
DEFAULT_COMPANY_NAME = "Company"

DEFAULT_TERMS = {
    "billing": "package",
    "monthlyHours": 40,
    "monthlyFee": 2000,
    "vatPercent": 21,
    "standardRate": 50,
    "weeklyGuideHours": 10,
    "overageRate": 50,
    "currency": "€",
}

# key: (low, high)
TERM_RANGES = {
    "monthlyHours": (0, 400),
    "monthlyFee": (0, 1000000),
    "vatPercent": (0, 100),
    "standardRate": (0, 10000),
    "weeklyGuideHours": (0, 80),
    "overageRate": (0, 10000),
}

# v1 settings (shell.json) that became the first contract period.
LEGACY_KEYS = {
    "weeklyTargetHours": "weeklyGuideHours",
    "monthlyHours": "monthlyHours",
    "monthlyFee": "monthlyFee",
    "vatPercent": "vatPercent",
    "standardRate": "standardRate",
    "currency": "currency",
}

DEFAULT_CONFIG = {
    "reportLanguage": "en",
    "reportRoundingMinutes": 0,
    "reportShowDiscount": True,
    "reportHtml": True,
}


class Refusal(Exception):
    def __init__(self, error, field=""):
        super().__init__(error)
        self.error = error
        self.field = field


# ---------------------------------------------------------------- clock, zone

def now_utc():
    fixed = os.environ.get("WORKLOG_NOW")
    if fixed:
        return parse_iso(fixed)
    return datetime.now(timezone.utc).replace(microsecond=0)


def local_zone():
    name = os.environ.get("WORKLOG_TZ")
    if name:
        return ZoneInfo(name)
    try:
        with open("/etc/localtime", "rb") as f:
            return ZoneInfo.from_file(f)
    except OSError:
        return timezone.utc


TZ = local_zone()


def parse_iso(value, field="time"):
    if not isinstance(value, str) or not value:
        raise Refusal("missing time", field)
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise Refusal("not a time: " + value[:40], field)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=TZ)
    return dt.astimezone(timezone.utc).replace(microsecond=0)


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def local(dt):
    return dt.astimezone(TZ)


def day_start(d):
    """UTC instant of local midnight starting date d."""
    return datetime.combine(d, time(0), TZ).astimezone(timezone.utc)


def week_monday(d):
    return d - timedelta(days=d.weekday())


def week_key(d):
    y, w, _ = d.isocalendar()
    return "%d-W%02d" % (y, w)


def monday_of_key(key):
    try:
        y, w = key.split("-W")
        return date.fromisocalendar(int(y), int(w), 1)
    except (ValueError, AttributeError):
        raise Refusal("not a week: " + str(key)[:20], "week")


def parse_month_key(key):
    try:
        y, m = (int(p) for p in key.split("-"))
        date(y, m, 1)
    except (ValueError, AttributeError):
        raise Refusal("not a month: " + str(key)[:20], "month")
    return y, m


def month_bounds(key):
    y, m = parse_month_key(key)
    return date(y, m, 1), date(y, m, calendar.monthrange(y, m)[1])


def shift_month(y, m, n):
    k = y * 12 + (m - 1) + n
    return k // 12, k % 12 + 1


def parse_day(value, field="from"):
    try:
        d = date.fromisoformat(str(value))
    except ValueError:
        raise Refusal("not a date: " + str(value)[:20], field)
    if not date(2000, 1, 1) <= d <= date(2100, 12, 31):
        raise Refusal("date out of range: " + str(value)[:20], field)
    return d


def cents(x):
    """Money rounded to the cent half up, as Model.js round2 does
    (Math.round(x * 100) / 100), so the panel and the reports agree."""
    return math.floor(x * 100 + 0.5) / 100


def overlap_sec(a_start, a_end, b_start, b_end):
    return max(0, int((min(a_end, b_end) - max(a_start, b_start)).total_seconds()))


# ---------------------------------------------------------------- cycles

def cycle_first(cycle_day, y, m):
    return date(y, m, min(cycle_day, calendar.monthrange(y, m)[1]))


def cycle_bounds(cycle_day, key):
    """First and last local day of the cycle named by the month it starts in."""
    y, m = parse_month_key(key)
    first = cycle_first(cycle_day, y, m)
    ny, nm = shift_month(y, m, 1)
    return first, cycle_first(cycle_day, ny, nm) - timedelta(days=1)


def cycle_of(cycle_day, d):
    """Key of the cycle holding local date d."""
    if d >= cycle_first(cycle_day, d.year, d.month):
        return "%04d-%02d" % (d.year, d.month)
    y, m = shift_month(d.year, d.month, -1)
    return "%04d-%02d" % (y, m)


def shift_cycle(key, n):
    y, m = shift_month(*parse_month_key(key), n)
    return "%04d-%02d" % (y, m)


# ---------------------------------------------------------------- validation

def number(value, field, low, high):
    if isinstance(value, bool):
        raise Refusal("not a number", field)
    try:
        v = float(value)
    except (TypeError, ValueError):
        raise Refusal("not a number", field)
    if v != v or not low <= v <= high:
        raise Refusal("%s out of range (%g to %g)" % (field.split(".")[-1], low, high), field)
    return int(v) if v == int(v) else round(v, 2)


def clean_terms(raw):
    """Contract terms from the panel or the file, validated. Raises Refusal
    with field terms.<key>."""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            raise Refusal("terms are not JSON", "terms")
    if not isinstance(raw, dict):
        raise Refusal("terms are not an object", "terms")
    t = {}
    billing = raw.get("billing", "package")
    if billing not in BILLING:
        raise Refusal("billing is package or hourly", "terms.billing")
    t["billing"] = billing
    for key, (low, high) in TERM_RANGES.items():
        if key == "overageRate":
            # Hours over the package; the standard rate unless set.
            default = t["standardRate"]
        elif billing == "hourly" and key in ("monthlyHours", "monthlyFee"):
            default = 0
        else:
            default = DEFAULT_TERMS[key]
        t[key] = number(raw.get(key, default), "terms." + key, low, high)
    if billing == "package" and t["monthlyHours"] <= 0:
        raise Refusal("a package needs hours", "terms.monthlyHours")
    if billing == "hourly":
        t["monthlyHours"] = 0
        t["monthlyFee"] = 0
    cur = raw.get("currency", DEFAULT_TERMS["currency"])
    cur = " ".join(str(cur).split())
    if not 1 <= len(cur) <= 4:
        raise Refusal("currency is 1 to 4 characters", "terms.currency")
    t["currency"] = cur
    return t


def clean_name(value):
    name = " ".join(str(value or "").split())
    if not 1 <= len(name) <= 40:
        raise Refusal("a name is 1 to 40 characters", "name")
    return name


def clean_tag(value, name):
    if value in (None, ""):
        value = "".join(ch for ch in name if ch.isalnum())[:2] or "CO"
    tag = "".join(str(value).split()).upper()
    if not 1 <= len(tag) <= 4:
        raise Refusal("a tag is 1 to 4 characters", "tag")
    return tag


def clean_cycle_day(value):
    try:
        d = int(value)
    except (TypeError, ValueError):
        raise Refusal("cycle day is a number from 1 to 31", "cycleDay")
    if not 1 <= d <= 31:
        raise Refusal("cycle day is a number from 1 to 31", "cycleDay")
    return d


def stored_terms_problem(k):
    """Stored terms must be what clean_terms would write: every key, real
    numbers (no strings or booleans), nothing left to coerce."""
    for key in ("billing", "currency") + tuple(TERM_RANGES):
        if key not in k:
            return "no " + key
    for key in TERM_RANGES:
        if isinstance(k[key], bool) or not isinstance(k[key], (int, float)):
            return key + " is not a number"
    if not isinstance(k["currency"], str):
        return "currency is not text"
    try:
        cleaned = clean_terms(k)
    except Refusal as e:
        return e.error
    if any(cleaned[key] != k[key] for key in cleaned):
        return "terms out of shape"
    return ""


def company_problem(c):
    """Why a stored company cannot be used, or "" when it can."""
    if not isinstance(c, dict):
        return "not an object"
    if not isinstance(c.get("id"), str) or not re.fullmatch(r"c_[0-9a-f]{4}", c["id"]):
        return "bad id"
    if not isinstance(c.get("name"), str) or not isinstance(c.get("tag"), str):
        return "name or tag is not text"
    if isinstance(c.get("cycleDay"), bool) or not isinstance(c.get("cycleDay"), int):
        return "cycleDay is not a whole number"
    try:
        if clean_name(c["name"]) != c["name"]:
            return "bad name"
        if clean_tag(c["tag"], c["name"]) != c["tag"]:
            return "bad tag"
        clean_cycle_day(c["cycleDay"])
    except Refusal as e:
        return e.error
    if not isinstance(c.get("archived", False), bool):
        return "archived is not true or false"
    waived = c.get("waived", [])
    if not isinstance(waived, list) or not all(isinstance(k, str) and re.fullmatch(r"\d{4}-\d{2}", k) for k in waived):
        return "waived is not a list of months"
    contracts = c.get("contracts")
    if not isinstance(contracts, list) or not contracts:
        return "no contracts"
    froms = []
    for j, k in enumerate(contracts):
        if not isinstance(k, dict):
            return "contract %d is not an object" % (j + 1)
        try:
            if not isinstance(k.get("from"), str) or parse_day(k["from"]).isoformat() != k["from"]:
                return "contract %d: bad from" % (j + 1)
        except Refusal as e:
            return "contract %d: %s" % (j + 1, e.error)
        problem = stored_terms_problem(k)
        if problem:
            return "contract %d: %s" % (j + 1, problem)
        froms.append(k["from"])
    if froms != sorted(froms) or len(set(froms)) != len(froms):
        return "contracts not sorted by date or a date twice"
    return ""


def session_problem(s, allow_open=False):
    """Why a stored session cannot be used, or "" when it can."""
    if not isinstance(s, dict):
        return "not an object"
    if not isinstance(s.get("id"), str) or not s["id"]:
        return "no id"
    segs = s.get("segments")
    if not isinstance(segs, list) or not segs:
        return "no segments"
    for j, seg in enumerate(segs):
        if not isinstance(seg, dict):
            return "segment %d is not an object" % (j + 1)
        try:
            start = parse_iso(seg.get("start"))
            end = seg.get("end")
            if end is None:
                if not (allow_open and j == len(segs) - 1):
                    return "segment %d has no end" % (j + 1)
            elif parse_iso(end) < start:
                return "segment %d ends before it starts" % (j + 1)
        except Refusal as e:
            return "segment %d: %s" % (j + 1, e.error)
    if not isinstance(s.get("summary", ""), str) or not isinstance(s.get("tags", []), list):
        return "summary or tags of the wrong type"
    return ""


# ---------------------------------------------------------------- config

def config_from(raw):
    """UI preferences from the service. The six v1 terms keys, at the top
    level or under "legacy", only seed the first company."""
    cfg = dict(DEFAULT_CONFIG)
    given = {}
    if raw:
        try:
            given = json.loads(raw)
        except ValueError:
            given = {}
        if not isinstance(given, dict):
            given = {}
    for k, v in given.items():
        if k in cfg and v is not None and v != "":
            cfg[k] = v
    try:
        cfg["reportRoundingMinutes"] = 15 if float(cfg["reportRoundingMinutes"]) == 15 else 0
    except (TypeError, ValueError):
        cfg["reportRoundingMinutes"] = 0
    cfg["reportLanguage"] = "es" if cfg["reportLanguage"] == "es" else "en"
    cfg["reportShowDiscount"] = cfg["reportShowDiscount"] not in (False, "false", 0)
    cfg["reportHtml"] = cfg["reportHtml"] not in (False, "false", 0)
    legacy = {}
    nested = given.get("legacy")
    for source in (given, nested if isinstance(nested, dict) else {}):
        for k, v in source.items():
            if k in LEGACY_KEYS and v is not None and v != "":
                legacy[LEGACY_KEYS[k]] = v
    cfg["legacy"] = legacy
    return cfg


def terms_from_legacy(legacy):
    raw = dict(DEFAULT_TERMS)
    raw.update(legacy or {})
    # The extra hour rate follows the standard rate unless given.
    if "overageRate" not in (legacy or {}):
        raw.pop("overageRate")
    try:
        return clean_terms(raw)
    except Refusal:
        return dict(DEFAULT_TERMS)


def new_company(cid, name, tag, cycle_day, start, terms, now):
    return {
        "id": cid, "name": name, "tag": tag, "archived": False, "cycleDay": cycle_day,
        "createdAt": iso(now), "updatedAt": iso(now),
        "contracts": [dict({"from": start.isoformat()}, **terms)],
    }


# ---------------------------------------------------------------- storage

def data_dir():
    explicit = os.environ.get("WORKLOG_DATA_DIR")
    if explicit:
        path = explicit
    else:
        base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
        path = os.path.join(base, "omarchy-worklog")
    os.makedirs(path, mode=0o700, exist_ok=True)
    if os.path.islink(path):
        raise Refusal("data directory is a symlink: " + path)
    st = os.lstat(path)
    if st.st_uid != os.getuid():
        raise Refusal("data directory not owned by the user: " + path)
    if st.st_mode & 0o077:
        os.chmod(path, 0o700)
    return path


class Store:
    def __init__(self, cfg, now):
        self.dir = data_dir()
        self.log_path = os.path.join(self.dir, "worklog.json")
        self.active_path = os.path.join(self.dir, "active.json")
        self.recovered = None
        self.migrated = None
        self.active_upgraded = False
        self.extra = {}
        self.cfg = cfg
        self.now = now
        lock_path = os.path.join(self.dir, ".lock")
        if os.path.islink(lock_path):
            raise Refusal("lock file is a symlink: " + lock_path)
        self._lock = open(lock_path, "a")
        fcntl.flock(self._lock, fcntl.LOCK_EX)
        try:
            self.log = self._load_log()
            self.active = self._load_active()
            if self.migrated:
                self._write(self.log_path, self.log)
            if self.migrated or self.active_upgraded:
                self.save_active()
        except BaseException:
            self.close()
            raise

    def close(self):
        if self._lock:
            fcntl.flock(self._lock, fcntl.LOCK_UN)
            self._lock.close()
            self._lock = None

    def _read_json(self, path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)

    def _set_aside(self, path):
        aside = "%s.corrupt-%d" % (path, int(now_utc().timestamp()))
        os.replace(path, aside)
        return aside

    def _fresh_log(self):
        today = local(self.now).date()
        company = new_company(DEFAULT_COMPANY_ID, DEFAULT_COMPANY_NAME, "CO", 1, today.replace(day=1),
                              terms_from_legacy(self.cfg["legacy"]), self.now)
        return {"version": VERSION, "currentCompany": DEFAULT_COMPANY_ID, "companies": [company], "sessions": []}

    def _migrate(self, log):
        """v1 to v2: one company with the v1 settings as its terms, from the
        first day of the month of the earliest session."""
        if not os.path.exists(self.log_path):
            return log
        bdir = os.path.join(self.dir, "backups")
        os.makedirs(bdir, mode=0o700, exist_ok=True)
        target = os.path.join(bdir, "worklog-v1-%s.json" % local(self.now).date().isoformat())
        if not os.path.exists(target):
            self._copy(self.log_path, target)
        if os.path.exists(self.active_path):
            active_target = os.path.join(bdir, "active-v1-%s.json" % local(self.now).date().isoformat())
            if not os.path.exists(active_target):
                self._copy(self.active_path, active_target)
        starts = [parse_iso(s["segments"][0]["start"]) for s in log["sessions"]]
        # A pending v1 session is work too: its start counts.
        try:
            pending = self._read_json(self.active_path)
            starts.append(parse_iso(pending["session"]["segments"][0]["start"]))
        except (OSError, ValueError, KeyError, IndexError, TypeError, Refusal):
            pass
        first_day = (local(min(starts)).date() if starts else local(self.now).date()).replace(day=1)
        company = new_company(DEFAULT_COMPANY_ID, DEFAULT_COMPANY_NAME, "CO", 1, first_day,
                              terms_from_legacy(self.cfg["legacy"]), self.now)
        for s in log["sessions"]:
            s.pop("client", None)
            s["company"] = DEFAULT_COMPANY_ID
        self.migrated = {"from": 1, "company": DEFAULT_COMPANY_ID}
        return {"version": VERSION, "currentCompany": DEFAULT_COMPANY_ID, "companies": [company],
                "sessions": log["sessions"]}

    def _load_log(self):
        if not os.path.exists(self.log_path):
            return self._fresh_log()
        try:
            log = self._read_json(self.log_path)
        except (ValueError, OSError):
            self.recovered = {"file": "worklog.json", "movedTo": os.path.basename(self._set_aside(self.log_path))}
            return self._fresh_log()
        # Parseable but wrong: refuse and leave the file for a hand fix,
        # never set billing data aside on a shape check.
        if not isinstance(log, dict) or not isinstance(log.get("sessions"), list):
            raise Refusal("worklog.json has no sessions list; fix it or restore from backups/", "data")
        version = log.get("version", 1)
        if not isinstance(version, int) or version > VERSION:
            raise Refusal("worklog.json is version %s, newer than this helper" % str(version)[:10], "data")
        for i, s in enumerate(log["sessions"]):
            problem = session_problem(s)
            if problem:
                raise Refusal("worklog.json session %d: %s; fix it or restore from backups/" % (i + 1, problem), "data")
        if version < 2:
            return self._migrate(log)
        companies = log.get("companies")
        if not isinstance(companies, list) or not companies:
            raise Refusal("worklog.json has no companies; fix it or restore from backups/", "data")
        for i, c in enumerate(companies):
            problem = company_problem(c)
            if problem:
                raise Refusal("worklog.json company %d: %s; fix it or restore from backups/" % (i + 1, problem), "data")
        ids = [c["id"] for c in companies]
        if len(set(ids)) != len(ids):
            raise Refusal("worklog.json: a company id twice; fix it or restore from backups/", "data")
        for i, s in enumerate(log["sessions"]):
            if s.get("company") not in ids:
                raise Refusal("worklog.json session %d: no such company; fix it or restore from backups/" % (i + 1), "data")
        if not any(c["id"] == log.get("currentCompany") and not c.get("archived") for c in companies):
            log["currentCompany"] = fallback_company(log, None) or companies[0]["id"]
        return log

    def _load_active(self):
        if not os.path.exists(self.active_path):
            return None
        try:
            active = self._read_json(self.active_path)
            if not isinstance(active, dict) or active.get("state") not in ("running", "paused", "ending"):
                raise ValueError("bad shape")
            if session_problem(active.get("session"), allow_open=active["state"] == "running"):
                raise ValueError("bad session")
        except (ValueError, OSError):
            self.recovered = {"file": "active.json", "movedTo": os.path.basename(self._set_aside(self.active_path))}
            return None
        session = active["session"]
        ids = [c["id"] for c in self.log["companies"]]
        if active.get("version", 1) < 2 and "company" not in session:
            session.pop("client", None)
            session["company"] = self.log["currentCompany"]
            active["version"] = VERSION
            self.active_upgraded = True
        elif session.get("company") not in ids:
            raise Refusal("active.json names no such company: %s; fix it or restore it" % str(session.get("company"))[:20], "data")
        return active

    def _write(self, path, obj):
        fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".tmp-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(obj, f, ensure_ascii=False, indent=1)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise

    def _copy(self, src_path, target):
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".tmp-")
        try:
            with os.fdopen(fd, "wb") as out, open(src_path, "rb") as src:
                shutil.copyfileobj(src, out)
                out.flush()
                os.fsync(out.fileno())
            os.replace(tmp, target)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise

    def _backup(self):
        if not os.path.exists(self.log_path):
            return
        bdir = os.path.join(self.dir, "backups")
        os.makedirs(bdir, mode=0o700, exist_ok=True)
        target = os.path.join(bdir, "worklog-%s.json" % local(now_utc()).date().isoformat())
        if os.path.exists(target):
            return
        self._copy(self.log_path, target)
        # Only the daily copies rotate; worklog-v1-*.json stays.
        kept = sorted(n for n in os.listdir(bdir) if re.fullmatch(r"worklog-\d{4}-\d{2}-\d{2}\.json", n))
        for name in kept[:-BACKUPS_KEPT]:
            os.unlink(os.path.join(bdir, name))

    def save_log(self):
        self._backup()
        self.log["sessions"].sort(key=lambda s: s["segments"][0]["start"])
        self._write(self.log_path, self.log)

    def save_active(self):
        if self.active is None:
            if os.path.exists(self.active_path):
                os.unlink(self.active_path)
        else:
            self._write(self.active_path, self.active)


# ---------------------------------------------------------------- companies

def company_by_id(store, cid):
    for c in store.log["companies"]:
        if c["id"] == cid:
            return c
    raise Refusal("no such company: " + str(cid)[:40], "company")


def resolve_company(store, ref, allow_archived=False):
    """A company named by id, name or tag (case-insensitive). Archived
    companies match by id only, and only when allowed."""
    ref = str(ref or "").strip()
    companies = store.log["companies"]
    for c in companies:
        if c["id"] == ref:
            if c.get("archived") and not allow_archived:
                raise Refusal(c["name"] + " is archived", "company")
            return c
    for key in ("name", "tag"):
        for c in companies:
            if not c.get("archived") and c[key].lower() == ref.lower():
                return c
    raise Refusal("no such company: " + ref[:40], "company")


def current_company(store):
    return company_by_id(store, store.log["currentCompany"])


def fallback_company(log, leaving):
    """The company to make current when `leaving` cannot stay current: the
    most recently used other active company, else the first by name."""
    active = [c for c in log["companies"] if not c.get("archived") and c["id"] != leaving]
    if not active:
        return None
    ids = {c["id"] for c in active}
    for s in sorted(log["sessions"], key=lambda s: s["segments"][-1].get("end") or "", reverse=True):
        if s.get("company") in ids:
            return s["company"]
    return sorted(active, key=lambda c: c["name"].lower())[0]["id"]


def terms_on(company, d):
    """Terms in force on local date d, or None before the first period."""
    found = None
    key = d.isoformat()
    for k in company["contracts"]:
        if k["from"] <= key:
            found = k
    return found


def guide_on(company, d):
    t = terms_on(company, d)
    return t["weeklyGuideHours"] * 3600 if t else 0


def cycle_parts(company, first, last):
    """The cycle cut where the terms change: [(from, to, terms or None)]."""
    cuts = [first]
    for k in company["contracts"]:
        d = date.fromisoformat(k["from"])
        if first < d <= last:
            cuts.append(d)
    parts = []
    for i, start in enumerate(cuts):
        end = cuts[i + 1] - timedelta(days=1) if i + 1 < len(cuts) else last
        parts.append((start, end, terms_on(company, start)))
    return parts


def cycle_label(cycle_day, first, last, lang="en"):
    t = TEXT[lang]
    if cycle_day == 1:
        name = t["month_names"][first.month - 1]
        return ("%s de %d" if lang == "es" else "%s %d") % (name, first.year)
    mon = t["months"]
    if lang == "es":
        if first.year != last.year:
            return "%d %s de %d a %d %s de %d" % (first.day, mon[first.month - 1], first.year, last.day, mon[last.month - 1], last.year)
        return "%d %s a %d %s de %d" % (first.day, mon[first.month - 1], last.day, mon[last.month - 1], last.year)
    if first.year != last.year:
        return "%d %s %d to %d %s %d" % (first.day, mon[first.month - 1], first.year, last.day, mon[last.month - 1], last.year)
    return "%d %s to %d %s %d" % (first.day, mon[first.month - 1], last.day, mon[last.month - 1], last.year)


def company_row(store, c, today):
    return {
        "id": c["id"], "name": c["name"], "tag": c["tag"], "archived": bool(c.get("archived")),
        "cycleDay": c["cycleDay"], "contracts": c["contracts"], "inForce": terms_on(c, today),
        "sessionCount": sum(1 for s in store.log["sessions"] if s.get("company") == c["id"]),
    }


def companies_sorted(store):
    return sorted(store.log["companies"], key=lambda c: (bool(c.get("archived")), c["name"].lower()))


# ---------------------------------------------------------------- segments

def seg_bounds(seg, now):
    start = parse_iso(seg["start"])
    end = parse_iso(seg["end"]) if seg.get("end") else now
    return start, max(start, end)


def worked_sec(segments, now, closed_only=False):
    total = 0
    for seg in segments:
        if closed_only and not seg.get("end"):
            continue
        s, e = seg_bounds(seg, now)
        total += int((e - s).total_seconds())
    return total


def paused_sec(segments, now):
    total = 0
    for prev, nxt in zip(segments, segments[1:]):
        if prev.get("end"):
            total += max(0, int((parse_iso(nxt["start"]) - parse_iso(prev["end"])).total_seconds()))
    return total


def clean_segments(raw, now, allow_open=False, drop_short=True):
    """Validate a segment list from the editor. Returns a new sorted list."""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            raise Refusal("segments are not JSON", "segments")
    if not isinstance(raw, list) or not raw:
        raise Refusal("no segments", "segments")
    if len(raw) > 200:
        raise Refusal("too many segments", "segments")
    out = []
    for i, seg in enumerate(raw):
        if not isinstance(seg, dict):
            raise Refusal("segment %d is not an object" % (i + 1), "segments")
        start = parse_iso(seg.get("start"), "segments")
        end_raw = seg.get("end")
        if end_raw in (None, ""):
            if not allow_open or i != len(raw) - 1:
                raise Refusal("segment %d has no end" % (i + 1), "segments")
            end = None
        else:
            end = parse_iso(end_raw, "segments")
            if end <= start:
                raise Refusal("segment %d ends before it starts" % (i + 1), "segments")
        if (end or start) > now + timedelta(seconds=60):
            raise Refusal("segment %d is in the future" % (i + 1), "segments")
        reason = seg.get("endReason") if seg.get("endReason") in END_REASONS else "edited"
        item = {"start": iso(start), "end": iso(end) if end else None}
        if end:
            item["endReason"] = reason
        out.append(item)
    out.sort(key=lambda s: s["start"])
    if any(s["end"] is None for s in out[:-1]):
        raise Refusal("only the last segment can be open", "segments")
    for prev, nxt in zip(out, out[1:]):
        if parse_iso(prev["end"]) > parse_iso(nxt["start"]):
            raise Refusal("segments overlap at %s" % local(parse_iso(nxt["start"])).strftime("%H:%M"), "segments")
    if drop_short:
        out = [s for s in out if s["end"] is None or worked_sec([s], now) >= MIN_SEGMENT_SEC]
    if not out or (worked_sec(out, now) <= 0 and out[-1]["end"] is not None):
        raise Refusal("nothing worked: the session is empty", "segments")
    return out


def clean_summary(text):
    text = (text or "").strip()
    if not text:
        raise Refusal("write what you did", "summary")
    if len(text) > MAX_SUMMARY:
        raise Refusal("summary longer than %d characters" % MAX_SUMMARY, "summary")
    return text


def clean_tags(raw):
    if isinstance(raw, list):
        items = raw
    else:
        items = (raw or "").split(",")
    tags = []
    for t in items:
        t = " ".join(str(t).split()).lower()
        if not t:
            continue
        if len(t) > MAX_TAG:
            raise Refusal("tag longer than %d characters: %s" % (MAX_TAG, t[:MAX_TAG]), "tags")
        if t not in tags:
            tags.append(t)
    if len(tags) > MAX_TAGS:
        raise Refusal("more than %d tags" % MAX_TAGS, "tags")
    return tags


def check_no_overlap(store, segments, now, skip_id=None, include_active=True):
    mine = [seg_bounds(s, now) for s in segments]
    others = [(s["id"], s["segments"]) for s in store.log["sessions"] if s["id"] != skip_id]
    if include_active and store.active and store.active["session"]["id"] != skip_id:
        others.append(("active", store.active["session"]["segments"]))
    for sid, segs in others:
        for seg in segs:
            os_, oe = seg_bounds(seg, now)
            for ms, me in mine:
                if overlap_sec(ms, me, os_, oe) > 0:
                    when = local(os_).strftime("%a %d %b %H:%M")
                    what = "the running session" if sid == "active" else "the session of " + when
                    raise Refusal("overlaps " + what, "segments")


def new_id(now):
    return "s_%d_%s" % (int(now.timestamp()), secrets.token_hex(2))


# ---------------------------------------------------------------- aggregation

def all_segments(store, include_active, now, company=None):
    """Closed segments of the confirmed sessions and, when asked, of the live
    one (its open segment is the panel's to add). company: an id or None."""
    out = []
    for s in store.log["sessions"]:
        if company is None or s.get("company") == company:
            out.extend(s["segments"])
    if include_active and store.active:
        if company is None or store.active["session"].get("company") == company:
            out.extend(seg for seg in store.active["session"]["segments"] if seg.get("end"))
    return out


def sec_between(segments, start, end, now):
    total = 0
    for seg in segments:
        s, e = seg_bounds(seg, now)
        total += overlap_sec(s, e, start, end)
    return total


def week_figures(segments, monday, today, target_sec, now):
    days = []
    for i in range(7):
        d = monday + timedelta(days=i)
        days.append({"date": d.isoformat(), "workedSec": sec_between(segments, day_start(d), day_start(d + timedelta(days=1)), now)})
    worked = sum(d["workedSec"] for d in days)
    return {
        "key": week_key(monday),
        "start": monday.isoformat(),
        "startAt": iso(day_start(monday)),
        "endAt": iso(day_start(monday + timedelta(days=7))),
        "targetSec": int(target_sec),
        "workedSec": worked,
        "daysLeft": min(7, max(0, (monday + timedelta(days=6) - today).days + 1)),
        "days": days,
    }


def days_elapsed(first, last, today):
    if today < first:
        return 0
    if today > last:
        return (last - first).days + 1
    return (today - first).days + 1


def cycle_figures(company, key, segments, today, now):
    """One company's cycle: owed hours, pace and the parts its terms cut it
    into. `segments` are that company's."""
    first, last = cycle_bounds(company["cycleDay"], key)
    n_days = (last - first).days + 1
    parts = []
    expected = 0.0
    live_part = 0
    for i, (a, b, t) in enumerate(cycle_parts(company, first, last)):
        days = (b - a).days + 1
        billing = t["billing"] if t else "none"
        part = {
            "from": a.isoformat(), "to": b.isoformat(), "days": days, "billing": billing,
            "monthlyHours": t["monthlyHours"] if t else 0, "monthlyFee": t["monthlyFee"] if t else 0,
            "vatPercent": t["vatPercent"] if t else 0, "standardRate": t["standardRate"] if t else 0,
            "overageRate": t.get("overageRate", t["standardRate"]) if t else 0,
            "currency": t["currency"] if t else "",
            "owedSec": 0, "fee": 0.0,
            "workedSec": sec_between(segments, day_start(a), day_start(b + timedelta(days=1)), now),
        }
        if billing == "package":
            part["owedSec"] = int(round(t["monthlyHours"] * 3600 * days / n_days / 60)) * 60
            part["fee"] = cents(t["monthlyFee"] * days / n_days)
            expected += t["monthlyHours"] * 3600 * days_elapsed(a, b, today) / n_days
        if a <= today:
            live_part = i
        parts.append(part)
    kinds = {p["billing"] for p in parts}
    billing = kinds.pop() if len(kinds) == 1 else "mixed"
    elapsed = days_elapsed(first, last, today)
    guide_day = min(max(today, first), last)
    t = terms_on(company, guide_day) or next((terms_on(company, date.fromisoformat(p["from"])) for p in parts if p["billing"] != "none"), None)
    rate_days = sum(p["days"] for p in parts if p["billing"] == "package")
    return {
        "key": key,
        "company": company["id"],
        "cycleDay": company["cycleDay"],
        "label": cycle_label(company["cycleDay"], first, last),
        "start": first.isoformat(),
        "end": last.isoformat(),
        "startAt": iso(day_start(first)),
        "endAt": iso(day_start(last + timedelta(days=1))),
        "days": n_days,
        "elapsedDays": elapsed,
        "daysLeft": n_days - elapsed + (1 if first <= today <= last else 0),
        "workedSec": sum(p["workedSec"] for p in parts),
        "targetSec": sum(p["owedSec"] for p in parts),
        "expectedSec": int(round(expected)),
        "billing": billing,
        "currency": t["currency"] if t else DEFAULT_TERMS["currency"],
        "guideSec": t["weeklyGuideHours"] * 3600 if t else 0,
        "standardRate": cents(sum(p["standardRate"] * p["days"] for p in parts if p["billing"] == "package") / rate_days) if rate_days else 0,
        "overageRate": cents(sum(p["overageRate"] * p["days"] for p in parts if p["billing"] == "package") / rate_days) if rate_days else 0,
        "overageVat": next((p["vatPercent"] for p in reversed(parts) if p["billing"] == "package"), 0),
        "waived": key in company.get("waived", []),
        "livePart": live_part,
        "parts": parts,
    }


def money(fig, worked_sec_value, part_worked=None):
    """What the cycle bills for `worked_sec_value` seconds. The seconds the
    parts do not hold yet (the live segment) count in the live part.
    `part_worked` replaces the parts' seconds (reports, rounded). A package
    cycle bills the hours over it at the extra hour rate, unless waived."""
    parts = fig["parts"]
    worked_parts = list(part_worked) if part_worked is not None else [p["workedSec"] for p in parts]
    extra = worked_sec_value - sum(worked_parts)
    if parts and extra:
        worked_parts[fig.get("livePart", len(parts) - 1)] += extra
    lines = []
    for p, w in zip(parts, worked_parts):
        if p["billing"] == "package":
            net = p["fee"]
        elif p["billing"] == "hourly":
            net = cents(w / 3600 * p["standardRate"])
        else:
            net = 0.0
        lines.append({"from": p["from"], "to": p["to"], "billing": p["billing"], "workedSec": w,
                      "net": net, "vatPercent": p["vatPercent"], "vat": cents(net * p["vatPercent"] / 100),
                      "standardRate": p["standardRate"]})
    fee = cents(sum(l["net"] for l in lines))
    net = fee
    vat = cents(sum(l["vat"] for l in lines))
    hours = worked_sec_value / 3600
    out = {
        "billing": fig["billing"], "fee": fee, "lines": lines, "projected": False, "basisHours": round(hours, 4),
        "standardValue": None, "discount": None, "discountPercent": None, "effectiveRate": None,
        "overHours": 0, "overSec": 0, "overageRate": 0, "overageNet": 0.0, "overageWaived": False,
    }
    if fig["billing"] == "package":
        owed = fig["targetSec"] / 3600
        over_sec = max(0, int(worked_sec_value) - fig["targetSec"])
        over_net = cents(over_sec / 3600 * fig.get("overageRate", fig["standardRate"]))
        waived = bool(fig.get("waived"))
        if over_net and not waived:
            net = cents(net + over_net)
            vat = cents(vat + cents(over_net * fig.get("overageVat", 0) / 100))
        basis = max(hours, owed)
        value = basis * fig["standardRate"]
        discount = max(0.0, value - net)
        out.update({
            "projected": hours < owed,
            "basisHours": round(basis, 4),
            "standardValue": cents(value),
            "discount": cents(discount),
            "discountPercent": math.floor(1000 * discount / value + 0.5) / 10 if value > 0 else 0.0,
            "effectiveRate": cents(net / basis) if basis > 0 else None,
            "overHours": round(over_sec / 3600, 4),
            "overSec": over_sec,
            "overageRate": fig.get("overageRate", fig["standardRate"]),
            "overageNet": over_net,
            "overageWaived": waived,
        })
    out.update({"net": net, "invoice": net, "vat": vat, "gross": cents(net + vat)})
    return out


def session_row(s, now):
    first = parse_iso(s["segments"][0]["start"])
    last_seg = s["segments"][-1]
    last = parse_iso(last_seg["end"]) if last_seg.get("end") else now
    return {
        "id": s["id"],
        "company": s.get("company", ""),
        "date": local(first).date().isoformat(),
        "start": s["segments"][0]["start"],
        "end": iso(last),
        "workedSec": worked_sec(s["segments"], now),
        "pausedSec": paused_sec(s["segments"], now),
        "segments": s["segments"],
        "summary": s.get("summary", ""),
        "tags": s.get("tags", []),
        "source": s.get("source", "timer"),
    }


def recent_tags(store):
    seen = []
    for s in reversed(store.log["sessions"]):
        for t in s.get("tags", []):
            if t not in seen:
                seen.append(t)
            if len(seen) >= 20:
                return seen
    return seen


def build_view(store, now):
    today = local(now).date()
    monday = week_monday(today)
    company = current_company(store)
    cid = company["id"]
    mine = all_segments(store, True, now, cid)
    every = all_segments(store, True, now)
    week = week_figures(mine, monday, today, guide_on(company, today), now)
    week["company"] = cid
    month = cycle_figures(company, cycle_of(company["cycleDay"], today), mine, today, now)
    month["money"] = money(month, month["workedSec"])
    trend = []
    for i in range(TREND_WEEKS - 1, -1, -1):
        m = monday - timedelta(weeks=i)
        trend.append({
            "key": week_key(m),
            "start": m.isoformat(),
            "workedSec": sec_between(mine, day_start(m), day_start(m + timedelta(days=7)), now),
            "targetSec": guide_on(company, m + timedelta(days=6)),
        })
    active = None
    if store.active:
        a = store.active
        segments = a["session"]["segments"]
        open_seg = segments[-1] if segments and not segments[-1].get("end") else None
        active = {
            "id": a["session"]["id"],
            "company": a["session"].get("company", cid),
            "segments": segments,
            "draft": a.get("draft", {"summary": "", "tags": []}),
            "closedSec": worked_sec(segments, now, closed_only=True),
            "pausedSec": paused_sec(segments, now),
            "since": segments[0]["start"] if segments else None,
            "openStart": open_seg["start"] if open_seg else None,
            "lastEnd": segments[-1].get("end") if segments else None,
            "source": a["session"].get("source", "timer"),
        }
    return {
        "now": iso(now),
        "state": store.active["state"] if store.active else "idle",
        "pauseReason": store.active.get("pauseReason", "") if store.active else "",
        "announced": store.active.get("announced", True) if store.active else True,
        "active": active,
        "currentCompany": cid,
        "companies": [company_row(store, c, today) for c in companies_sorted(store)],
        "today": {
            "date": today.isoformat(),
            "startAt": iso(day_start(today)),
            "workedSec": sec_between(every, day_start(today), day_start(today + timedelta(days=1)), now),
        },
        "week": week,
        "month": month,
        "trend": trend,
        "recent": [session_row(s, now) for s in store.log["sessions"][-RECENT:]][::-1],
        "tags": recent_tags(store),
        "sessionCount": len(store.log["sessions"]),
        "recovered": store.recovered,
        "migrated": store.migrated,
    }


# ---------------------------------------------------------------- lifecycle

def need_state(store, *states):
    state = store.active["state"] if store.active else "idle"
    if state not in states:
        raise Refusal("no-op: " + state, "state")
    return state


def close_open(store, at, reason):
    segs = store.active["session"]["segments"]
    open_seg = segs[-1]
    start = parse_iso(open_seg["start"])
    at = max(at, start)
    open_seg["end"] = iso(at)
    open_seg["endReason"] = reason


def cmd_start(store, args, now):
    if store.active and store.active["state"] == "paused":
        return cmd_resume(store, args, now)
    need_state(store, "idle")
    company = resolve_company(store, args.company) if args.company else current_company(store)
    if company.get("archived"):
        raise Refusal(company["name"] + " is archived", "company")
    if args.segments:
        segments = clean_segments(args.segments, now, allow_open=True, drop_short=False)
        if segments[-1]["end"] is not None:
            raise Refusal("the last segment must be open to start a timer", "segments")
        source = "manual"
    else:
        at = parse_iso(args.at) if args.at else now
        if at > now + timedelta(seconds=60):
            raise Refusal("start is in the future", "at")
        segments = [{"start": iso(at), "end": None}]
        source = "timer"
    store.active = {"version": VERSION, "state": "running",
                    "session": {"id": new_id(now), "company": company["id"], "segments": []}}
    check_no_overlap(store, segments, now, skip_id=store.active["session"]["id"])
    store.active["session"]["segments"] = segments
    store.active["session"]["source"] = source
    store.active.update({
        "draft": {"summary": (args.note or "")[:MAX_SUMMARY], "tags": []},
        "pauseReason": "",
        "heartbeatAt": iso(now),
        "bootId": args.boot_id or "",
        "announced": True,
    })
    store.log["currentCompany"] = company["id"]


def cmd_pause(store, args, now):
    need_state(store, "running")
    reason = args.reason if args.reason in PAUSE_REASONS else "manual"
    at = min(parse_iso(args.at), now) if args.at else now
    close_open(store, at, reason)
    store.active["state"] = "paused"
    store.active["pauseReason"] = reason
    store.active["announced"] = reason == "manual"


def cmd_resume(store, args, now):
    state = need_state(store, "paused", "ending")
    if state == "ending":
        return cmd_back(store, args, now)
    at = parse_iso(args.at) if args.at else now
    last_end = parse_iso(store.active["session"]["segments"][-1]["end"])
    at = max(at, last_end)
    store.active["session"]["segments"].append({"start": iso(at), "end": None})
    store.active["state"] = "running"
    store.active["pauseReason"] = ""
    store.active["announced"] = True
    store.active["heartbeatAt"] = iso(now)


def cmd_unpause(store, args, now):
    """Count the pause as work: the last segment runs on as if never closed."""
    need_state(store, "paused")
    segments = [dict(x) for x in store.active["session"]["segments"]]
    segments[-1]["end"] = None
    segments[-1].pop("endReason", None)
    check_no_overlap(store, segments, now, skip_id=store.active["session"]["id"])
    store.active["session"]["segments"] = segments
    store.active["state"] = "running"
    store.active["pauseReason"] = ""
    store.active["announced"] = True
    store.active["heartbeatAt"] = iso(now)


def cmd_stop(store, args, now):
    state = need_state(store, "running", "paused")
    if state == "running":
        at = min(parse_iso(args.at), now) if args.at else now
        close_open(store, at, "stop")
    store.active["state"] = "ending"
    store.active["pauseReason"] = ""
    store.active["announced"] = True


def cmd_back(store, args, now):
    need_state(store, "ending")
    seg = store.active["session"]["segments"][-1]
    if seg.get("endReason") == "stop":
        seg["endReason"] = "manual"
    store.active["state"] = "paused"
    store.active["pauseReason"] = "manual"


def cmd_draft(store, args, now):
    need_state(store, "running", "paused", "ending")
    draft = store.active.setdefault("draft", {"summary": "", "tags": []})
    if args.summary is not None:
        draft["summary"] = args.summary[:MAX_SUMMARY]
    if args.tags is not None:
        draft["tags"] = [t.strip()[:MAX_TAG] for t in args.tags.split(",") if t.strip()][:MAX_TAGS]


def cmd_edit_active(store, args, now):
    state = need_state(store, "running", "paused", "ending")
    if not args.segments and not args.company:
        raise Refusal("nothing to change", "segments")
    if args.company:
        company = resolve_company(store, args.company, allow_archived=True)
        if company.get("archived") and company["id"] != store.active["session"].get("company"):
            raise Refusal(company["name"] + " is archived", "company")
        store.active["session"]["company"] = company["id"]
        if not company.get("archived"):
            store.log["currentCompany"] = company["id"]
    if args.segments:
        segments = clean_segments(args.segments, now, allow_open=state == "running", drop_short=False)
        if state == "running" and segments[-1]["end"] is not None:
            raise Refusal("a running session keeps its last segment open", "segments")
        check_no_overlap(store, segments, now, skip_id=store.active["session"]["id"])
        store.active["session"]["segments"] = segments


def session_company(store, args, default):
    """--company for a confirmed session: any active company, or the one the
    session already has even when archived."""
    if not args.company:
        return default
    company = resolve_company(store, args.company, allow_archived=True)
    if company.get("archived") and company["id"] != default:
        raise Refusal(company["name"] + " is archived", "company")
    return company["id"]


def cmd_confirm(store, args, now):
    need_state(store, "ending")
    # A confirm cut between writing the log and removing active.json left
    # the session in both: finish the removal, never append it twice.
    if any(s["id"] == store.active["session"]["id"] for s in store.log["sessions"]):
        store.active = None
        return None
    summary = clean_summary(args.summary if args.summary is not None else store.active.get("draft", {}).get("summary"))
    tags = clean_tags(args.tags if args.tags is not None else store.active.get("draft", {}).get("tags"))
    raw = args.segments if args.segments else store.active["session"]["segments"]
    segments = clean_segments(raw, now)
    check_no_overlap(store, segments, now, skip_id=store.active["session"]["id"], include_active=False)
    session = {
        "id": store.active["session"]["id"],
        "company": session_company(store, args, store.active["session"].get("company", store.log["currentCompany"])),
        "segments": segments,
        "summary": summary,
        "tags": tags,
        "source": store.active["session"].get("source", "timer"),
        "createdAt": iso(now),
        "updatedAt": iso(now),
    }
    store.log["sessions"].append(session)
    store.active = None
    return session


def cmd_discard(store, args, now):
    need_state(store, "running", "paused", "ending")
    store.active = None


def cmd_heartbeat(store, args, now):
    if store.active:
        store.active["heartbeatAt"] = iso(parse_iso(args.at) if args.at else now)
        if args.boot_id:
            store.active["bootId"] = args.boot_id


def cmd_recover(store, args, now):
    """Service start: a running session whose heartbeat is stale, or from
    another boot, was cut by a shutdown or crash; pause it at the heartbeat."""
    if store.active and any(s["id"] == store.active["session"]["id"] for s in store.log["sessions"]):
        store.active = None
        return {"reason": "already-confirmed", "at": None}
    if not store.active or store.active["state"] != "running":
        if store.active and args.boot_id:
            store.active["bootId"] = args.boot_id
        return None
    beat = parse_iso(store.active.get("heartbeatAt") or store.active["session"]["segments"][-1]["start"])
    same_boot = not args.boot_id or store.active.get("bootId", "") in ("", args.boot_id)
    if same_boot and (now - beat).total_seconds() < 120:
        store.active["bootId"] = args.boot_id or store.active.get("bootId", "")
        return None
    close_open(store, beat, "restart")
    store.active["state"] = "paused"
    store.active["pauseReason"] = "restart"
    store.active["announced"] = False
    store.active["bootId"] = args.boot_id or ""
    return {"reason": "restart", "at": iso(max(beat, parse_iso(store.active["session"]["segments"][-1]["start"])))}


def cmd_announce(store, args, now):
    if store.active:
        store.active["announced"] = True


def find_session(store, sid):
    for s in store.log["sessions"]:
        if s["id"] == sid:
            return s
    raise Refusal("no session " + str(sid)[:40], "id")


def cmd_add(store, args, now):
    segments = clean_segments(args.segments, now)
    summary = clean_summary(args.summary)
    tags = clean_tags(args.tags)
    company = resolve_company(store, args.company)["id"] if args.company else store.log["currentCompany"]
    check_no_overlap(store, segments, now)
    store.log["sessions"].append({
        "id": new_id(now),
        "company": company,
        "segments": segments,
        "summary": summary,
        "tags": tags,
        "source": "manual",
        "createdAt": iso(now),
        "updatedAt": iso(now),
    })


def cmd_update(store, args, now):
    s = find_session(store, args.id)
    segments = clean_segments(args.segments, now) if args.segments else s["segments"]
    summary = clean_summary(args.summary) if args.summary is not None else s["summary"]
    tags = clean_tags(args.tags) if args.tags is not None else s["tags"]
    company = session_company(store, args, s.get("company"))
    check_no_overlap(store, segments, now, skip_id=s["id"])
    s.update({"segments": segments, "summary": summary, "tags": tags, "company": company, "updatedAt": iso(now)})


def cmd_delete(store, args, now):
    s = find_session(store, args.id)
    store.log["sessions"].remove(s)


# ---------------------------------------------------------------- companies, contracts

def check_name_free(store, name, skip_id=None):
    for c in store.log["companies"]:
        if c["id"] != skip_id and c["name"].lower() == name.lower():
            raise Refusal("a company is already called " + c["name"], "name")


def cmd_company(store, args, now):
    action = args.action
    today = local(now).date()
    if action == "add":
        name = clean_name(args.name)
        check_name_free(store, name)
        tag = clean_tag(args.tag, name)
        cycle_day = clean_cycle_day(args.cycle_day) if args.cycle_day not in (None, "") else 1
        cid = "c_" + secrets.token_hex(2)
        while any(c["id"] == cid for c in store.log["companies"]):
            cid = "c_" + secrets.token_hex(2)
        terms = terms_on(current_company(store), today)
        terms = clean_terms(terms) if terms else dict(DEFAULT_TERMS)
        start = cycle_bounds(cycle_day, cycle_of(cycle_day, today))[0]
        store.log["companies"].append(new_company(cid, name, tag, cycle_day, start, terms, now))
        store.extra["company"] = cid
        return
    company = company_by_id(store, args.id)
    if action == "rename":
        if args.name is not None:
            company["name"] = clean_name(args.name)
            check_name_free(store, company["name"], company["id"])
        if args.tag is not None:
            company["tag"] = clean_tag(args.tag, company["name"])
        if args.cycle_day not in (None, ""):
            company["cycleDay"] = clean_cycle_day(args.cycle_day)
            check_currency_cuts(company)
    elif action == "use":
        if company.get("archived"):
            raise Refusal(company["name"] + " is archived", "company")
        store.log["currentCompany"] = company["id"]
        return
    elif action in ("archive", "delete"):
        if store.active and store.active["session"].get("company") == company["id"]:
            raise Refusal("the live session belongs to " + company["name"], "company")
        if action == "delete":
            used = sum(1 for s in store.log["sessions"] if s.get("company") == company["id"])
            if used:
                raise Refusal("%s has %d sessions. Archive it instead." % (company["name"], used), "company")
            if len(store.log["companies"]) == 1:
                raise Refusal("the last company cannot be deleted", "company")
        if store.log["currentCompany"] == company["id"] or not company.get("archived"):
            other = fallback_company(store.log, company["id"])
            if other is None and not company.get("archived"):
                raise Refusal("the only active company cannot be %s" % ("archived" if action == "archive" else "deleted"), "company")
            if store.log["currentCompany"] == company["id"]:
                store.log["currentCompany"] = other
        if action == "archive":
            company["archived"] = True
        else:
            store.log["companies"].remove(company)
            return
    elif action == "unarchive":
        company["archived"] = False
    else:
        raise Refusal("unknown action: " + str(action)[:20], "action")
    company["updatedAt"] = iso(now)


def check_currency_cuts(company):
    """A cycle bills in one currency: a period that changes the currency must
    start on the first day of a cycle."""
    for prev, k in zip(company["contracts"], company["contracts"][1:]):
        if k["currency"] != prev["currency"]:
            d = date.fromisoformat(k["from"])
            if cycle_bounds(company["cycleDay"], cycle_of(company["cycleDay"], d))[0] != d:
                raise Refusal("a new currency starts on the first day of a cycle (%s is mid-cycle)" % k["from"], "from")


def cmd_overage(store, args, now):
    """Waive (or bill again) the hours over the package in one cycle."""
    company = company_by_id(store, args.id)
    key = args.month
    parse_month_key(key or "")
    waived = [k for k in company.get("waived", []) if k != key]
    if args.action == "waive":
        waived.append(key)
    elif args.action != "bill":
        raise Refusal("unknown action: " + str(args.action)[:20], "action")
    company["waived"] = sorted(waived)
    company["updatedAt"] = iso(now)


def cmd_contract(store, args, now):
    company = company_by_id(store, args.id)
    start = parse_day(args.from_, "from").isoformat()
    contracts = company["contracts"]
    if args.action == "set":
        terms = clean_terms(args.terms)
        # --replace moves a period: the one from that date leaves, this one comes in.
        moved = parse_day(args.replace, "from").isoformat() if args.replace else start
        if moved != start:
            if not any(k["from"] == moved for k in contracts):
                raise Refusal("no terms from " + moved, "from")
            if any(k["from"] == start for k in contracts):
                raise Refusal("other terms already start on " + start, "from")
        contracts[:] = [k for k in contracts if k["from"] not in (start, moved)] + [dict({"from": start}, **terms)]
        contracts.sort(key=lambda k: k["from"])
        check_currency_cuts(company)
    elif args.action == "delete":
        if not any(k["from"] == start for k in contracts):
            raise Refusal("no terms from " + start, "from")
        if len(contracts) == 1:
            raise Refusal("a company keeps at least one period of terms", "from")
        contracts[:] = [k for k in contracts if k["from"] != start]
        check_currency_cuts(company)
    else:
        raise Refusal("unknown action: " + str(args.action)[:20], "action")
    company["updatedAt"] = iso(now)


# ---------------------------------------------------------------- periods, month page

def sessions_in(store, first, last, now, company=None):
    start, end = day_start(first), day_start(last + timedelta(days=1))
    out = []
    for s in store.log["sessions"]:
        if company is not None and s.get("company") != company:
            continue
        a, _ = seg_bounds(s["segments"][0], now)
        _, b = seg_bounds(s["segments"][-1], now)
        if overlap_sec(a, b, start, end) > 0:
            out.append(s)
    return out


def cmd_sessions(store, args, now, cfg):
    today = local(now).date()
    key = args.week or "this"
    monday = week_monday(today) if key == "this" else monday_of_key(key)
    last = monday + timedelta(days=6)
    rows = [session_row(s, now) for s in sessions_in(store, monday, last, now)][::-1]
    fig = week_figures(all_segments(store, True, now), monday, today, guide_on(current_company(store), monday), now)
    return {"kind": "week", "key": week_key(monday), "first": monday.isoformat(), "last": last.isoformat(),
            "figures": fig, "sessions": rows}


def month_key_arg(value, company, today):
    if value in (None, "", "this"):
        return cycle_of(company["cycleDay"], today) if company else today.strftime("%Y-%m")
    parse_month_key(value)
    return value


def cmd_month(store, args, now):
    """The month page: one company's cycle, or a calendar month for all."""
    today = local(now).date()
    every = args.company in (None, "", "all")
    company = None if every else resolve_company(store, args.company, allow_archived=True)
    key = month_key_arg(args.month, company, today)
    if company:
        first, last = cycle_bounds(company["cycleDay"], key)
        cid = company["id"]
    else:
        first, last = month_bounds(key)
        cid = None
    segs = all_segments(store, True, now, cid)
    rows = [session_row(s, now) for s in store.log["sessions"] if cid is None or s.get("company") == cid]
    by_day = {}
    for r in rows:
        by_day.setdefault(r["date"], []).append(r)
    starts = {k["from"] for k in company["contracts"]} if company else set()
    days = []
    d = first
    while d <= last:
        days.append({
            "date": d.isoformat(),
            "startAt": iso(day_start(d)),
            "workedSec": sec_between(segs, day_start(d), day_start(d + timedelta(days=1)), now),
            "termsStart": d.isoformat() in starts,
            "sessions": by_day.get(d.isoformat(), []),
        })
        d += timedelta(days=1)
    # All companies: each with its cycle that starts in this month (the
    # calendar month itself for cycleDay 1), when it has work in it.
    shown = [company] if company else []
    if not company:
        for c in companies_sorted(store):
            a, b = cycle_bounds(c["cycleDay"], key)
            if sec_between(all_segments(store, True, now, c["id"]), day_start(a), day_start(b + timedelta(days=1)), now) > 0 \
                    or (store.active and store.active["session"].get("company") == c["id"]):
                shown.append(c)
    companies = []
    for c in shown:
        ckey = key
        fig = cycle_figures(c, ckey, all_segments(store, True, now, c["id"]), today, now)
        fig["money"] = money(fig, fig["workedSec"])
        companies.append({"id": c["id"], "name": c["name"], "tag": c["tag"], "archived": bool(c.get("archived")), "figures": fig})
    weeks = []
    monday = week_monday(first)
    while monday <= last:
        a, b = max(monday, first), min(monday + timedelta(days=6), last)
        weeks.append({
            "key": week_key(monday), "start": monday.isoformat(),
            "workedSec": sec_between(segs, day_start(a), day_start(b + timedelta(days=1)), now),
            "daysInCycle": (b - a).days + 1,
            "targetSec": guide_on(company, a) if company else (guide_on(shown[0], a) if len(shown) == 1 else 0),
        })
        monday += timedelta(days=7)
    invoice = {}
    for c in companies:
        cur = c["figures"]["currency"]
        invoice[cur] = cents(invoice.get(cur, 0) + c["figures"]["money"]["net"])
    return {
        "key": key, "company": cid or "all", "cycleDay": company["cycleDay"] if company else 1,
        "label": cycle_label(company["cycleDay"] if company else 1, first, last),
        "start": first.isoformat(), "end": last.isoformat(),
        "startAt": iso(day_start(first)), "endAt": iso(day_start(last + timedelta(days=1))),
        "workedSec": sum(x["workedSec"] for x in days),
        "days": days, "weeks": weeks, "companies": companies,
        "invoice": [{"currency": k, "net": v} for k, v in invoice.items()],
    }


# ---------------------------------------------------------------- export

TEXT = {
    "en": {
        "days": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
        "months": ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
        "month_names": ["January", "February", "March", "April", "May", "June", "July",
                        "August", "September", "October", "November", "December"],
        "lang": "en",
        "to": "to",
        "week_title": "Work report{who}, week {n} ({range})",
        "month_title": "Work report{who}, {label}",
        "for": " for {name}",
        "columns": ["Day", "Time", "Hours", "Tags", "Summary"],
        "company_column": "Company",
        "csv_company": "company",
        "terms_first": "Terms: {terms}, {cycle}.",
        "terms_next": "Terms from {day}: {terms}.",
        "package_terms": "package of {hours} a cycle, {fee} + VAT {vat} %, standard rate {rate}/h, extra hours at {extra}/h",
        "hourly_terms": "hourly at {rate}/h + VAT {vat} %",
        "cycle_calendar": "calendar month",
        "cycle_day": "cycle from the {nth}",
        "split": "Terms change inside this cycle, prorated by days ({days} days): owed {owed}, fee {fee}.",
        "uncontracted": "No terms before {day}: {hours} not billed.",
        "worked_owed": "Worked: {worked} of {owed} owed.",
        "under": "{diff} under the package.",
        "over": "{diff} over the package.",
        "even": "On the package.",
        "worked": "Worked: {worked}.",
        "fee": "Fee: {net} + VAT {vat} % ({vat_amount}) = {gross}.",
        "package_fee": "Package fee: {fee}.",
        "extra_billed": "Extra hours: {hours} at {rate}/h = {net}.",
        "extra_waived": "Extra hours: {hours} at {rate}/h = {net}, waived.",
        "total_vat": "Total: {net} + VAT {vat} % ({vat_amount}) = {gross}.",
        "fee_mixed_vat": "Fee: {net} + VAT ({vat_amount}) = {gross}.",
        "billed": "Billed at {rate}/h: {net} + VAT {vat} % ({vat_amount}) = {gross}.",
        "line_package": "{span}, package: {net}.",
        "line_hourly": "{span}, {hours} at {rate}/h: {net}.",
        "line_none": "{span}, no terms: {hours} not billed.",
        "total": "Total: {net} + VAT ({vat_amount}) = {gross}.",
        "value": "Value at the standard rate ({rate}/h): {value}. Package discount: {discount} ({pct} %).",
        "week_total": "Total: {worked} of {guide}.",
        "week_total_plain": "Total: {worked}.",
        "rounded": "Each session rounded to the nearest 15 minutes.",
        "footer": "Sessions: {n}. Generated {when}.",
        "empty": "No sessions in this period.",
        "terms_heading": "Terms",
        "totals_heading": "Totals",
    },
    "es": {
        "days": ["lun", "mar", "mié", "jue", "vie", "sáb", "dom"],
        "months": ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"],
        "month_names": ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
                        "agosto", "septiembre", "octubre", "noviembre", "diciembre"],
        "lang": "es",
        "to": "a",
        "week_title": "Informe de trabajo{who}, semana {n} ({range})",
        "month_title": "Informe de trabajo{who}, {label}",
        "for": " para {name}",
        "columns": ["Día", "Horario", "Horas", "Etiquetas", "Resumen"],
        "company_column": "Empresa",
        "csv_company": "company",
        "terms_first": "Condiciones: {terms}, {cycle}.",
        "terms_next": "Condiciones desde el {day}: {terms}.",
        "package_terms": "paquete de {hours} por ciclo, {fee} + IVA {vat} %, tarifa estándar {rate}/h, horas extra a {extra}/h",
        "hourly_terms": "por horas a {rate}/h + IVA {vat} %",
        "cycle_calendar": "mes natural",
        "cycle_day": "ciclo desde el día {day}",
        "split": "Las condiciones cambian dentro de este ciclo, prorrateadas por días ({days} días): debidas {owed}, cuota {fee}.",
        "uncontracted": "Sin condiciones antes del {day}: {hours} no facturadas.",
        "worked_owed": "Trabajado: {worked} de {owed} debidas.",
        "under": "{diff} por debajo del paquete.",
        "over": "{diff} por encima del paquete.",
        "even": "Justo el paquete.",
        "worked": "Trabajado: {worked}.",
        "fee": "Cuota: {net} + IVA {vat} % ({vat_amount}) = {gross}.",
        "package_fee": "Cuota del paquete: {fee}.",
        "extra_billed": "Horas extra: {hours} a {rate}/h = {net}.",
        "extra_waived": "Horas extra: {hours} a {rate}/h = {net}, no facturadas.",
        "total_vat": "Total: {net} + IVA {vat} % ({vat_amount}) = {gross}.",
        "fee_mixed_vat": "Cuota: {net} + IVA ({vat_amount}) = {gross}.",
        "billed": "Facturado a {rate}/h: {net} + IVA {vat} % ({vat_amount}) = {gross}.",
        "line_package": "{span}, paquete: {net}.",
        "line_hourly": "{span}, {hours} a {rate}/h: {net}.",
        "line_none": "{span}, sin condiciones: {hours} no facturadas.",
        "total": "Total: {net} + IVA ({vat_amount}) = {gross}.",
        "value": "Valor a tarifa estándar ({rate}/h): {value}. Descuento por paquete: {discount} ({pct} %).",
        "week_total": "Total: {worked} de {guide}.",
        "week_total_plain": "Total: {worked}.",
        "rounded": "Cada sesión redondeada al cuarto de hora más cercano.",
        "footer": "Sesiones: {n}. Generado el {when}.",
        "empty": "Sin sesiones en este periodo.",
        "terms_heading": "Condiciones",
        "totals_heading": "Totales",
    },
}


def fmt_duration(sec):
    sec = int(round(sec))
    sign = "-" if sec < 0 else ""
    h, m = divmod(abs(sec) // 60, 60)
    if h and m:
        return "%s%dh %02dm" % (sign, h, m)
    if h:
        return "%s%dh" % (sign, h)
    return "%s%dm" % (sign, m)


def fmt_money(value, lang, currency):
    """1.800,00 €: Spanish separators in both report languages, as the
    panel shows money (docs/decisions.md, 2026-10-28)."""
    whole = "{:,.2f}".format(value).replace(",", "X").replace(".", ",").replace("X", ".")
    return "%s %s" % (whole, currency)


def fmt_number(value, lang, digits=1):
    return ("{:.%df}" % digits).format(value).replace(".", ",")


def ordinal(n):
    if 10 <= n % 100 <= 20:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return "%d%s" % (n, suffix)


def day_label(d, t):
    return "%s %d %s" % (t["days"][d.weekday()], d.day, t["months"][d.month - 1])


def short_day(d, t, year=True):
    text = "%d %s" % (d.day, t["months"][d.month - 1])
    return text + (" %d" % d.year if year else "")


def span_label(a, b, t):
    if a == b:
        return short_day(a, t, False)
    if a.month == b.month:
        return "%d %s %d %s" % (a.day, t["to"], b.day, t["months"][b.month - 1])
    return "%s %s %s" % (short_day(a, t, False), t["to"], short_day(b, t, False))


def rounded(sec, rounding_min):
    if not rounding_min:
        return sec
    q = rounding_min * 60
    return int((sec + q / 2) // q * q)


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:24].strip("-") or "company"


def export_rows(sessions, now, rounding_min, period_start, period_end, names=None):
    """One row per session, its segments clipped to the period, so a session
    across a month or week boundary counts in each by its own part."""
    rows = []
    for s in sessions:
        clipped = []
        for seg in s["segments"]:
            a, b = seg_bounds(seg, now)
            a, b = max(a, period_start), min(b, period_end)
            if b > a:
                clipped.append({"start": iso(a), "end": iso(b)})
        if not clipped:
            continue
        first = local(parse_iso(clipped[0]["start"]))
        last = local(parse_iso(clipped[-1]["end"]))
        rows.append({
            "date": first.date(),
            "start": first,
            "end": last,
            "worked": rounded(worked_sec(clipped, now), rounding_min),
            "paused": paused_sec(clipped, now),
            "tags": s.get("tags", []),
            "summary": s.get("summary", ""),
            "company": (names or {}).get(s.get("company"), ""),
            "segments": clipped,
        })
    return rows


def row_parts(row, parts, now):
    """A row's (rounded) seconds split over the terms parts by where its
    segments fall; rounding moves the difference to the part with most."""
    raw = [sec_between(row["segments"], day_start(date.fromisoformat(p["from"])),
                       day_start(date.fromisoformat(p["to"]) + timedelta(days=1)), now) for p in parts]
    total = sum(raw)
    if total <= 0:
        return [0] * len(parts)
    out = [r * row["worked"] // total for r in raw]
    out[raw.index(max(raw))] += row["worked"] - sum(out)
    return out


def csv_text(value):
    """A cell a spreadsheet shows as text, never runs as a formula."""
    value = str(value)
    return "'" + value if value[:1] in ("=", "+", "-", "@", "\t", "\r") else value


def write_csv(path, rows):
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["date", "company", "start", "end", "worked_minutes", "paused_minutes", "tags", "summary"])
    for r in rows:
        w.writerow([r["date"].isoformat(), csv_text(r["company"]), r["start"].strftime("%Y-%m-%d %H:%M"), r["end"].strftime("%Y-%m-%d %H:%M"),
                    int(round(r["worked"] / 60)), int(round(r["paused"] / 60)), csv_text(" ".join(r["tags"])), csv_text(r["summary"])])
    with open(path, "x", encoding="utf-8", newline="") as f:
        f.write(buf.getvalue())


def one_line(text):
    parts = []
    for line in text.splitlines():
        line = line.strip()
        if line:
            parts.append(line if line[-1] in ".!?:;" else line + ".")
    return " ".join(parts)


def terms_text(terms, t, lang):
    cur = terms["currency"]
    if terms["billing"] == "hourly":
        return t["hourly_terms"].format(rate=fmt_money(terms["standardRate"], lang, cur), vat=fmt_number(terms["vatPercent"], lang, 0))
    return t["package_terms"].format(hours=fmt_duration(terms["monthlyHours"] * 3600), fee=fmt_money(terms["monthlyFee"], lang, cur),
                                     vat=fmt_number(terms["vatPercent"], lang, 0), rate=fmt_money(terms["standardRate"], lang, cur),
                                     extra=fmt_money(terms.get("overageRate", terms["standardRate"]), lang, cur))


def cycle_text(cycle_day, t):
    if cycle_day == 1:
        return t["cycle_calendar"]
    return t["cycle_day"].format(nth=ordinal(cycle_day), day=cycle_day)


def table_rows(rows, t, with_company):
    out = []
    for r in rows:
        cells = [day_label(r["date"], t)]
        if with_company:
            cells.append(r["company"])
        cells += ["%s %s %s" % (r["start"].strftime("%H:%M"), t["to"], r["end"].strftime("%H:%M")),
                  fmt_duration(r["worked"]), ", ".join(r["tags"]), one_line(r["summary"])]
        out.append(cells)
    return out


def month_report(company, fig, rows, cfg, now):
    """The monthly report of one company as plain parts: title, terms lines,
    table, totals lines, notes. Rendered as Markdown and HTML."""
    lang = cfg["reportLanguage"]
    t = TEXT[lang]
    first, last = date.fromisoformat(fig["start"]), date.fromisoformat(fig["end"])
    label = cycle_label(fig["cycleDay"], first, last, lang)
    title = t["month_title"].format(who=t["for"].format(name=company["name"]), label=label)
    terms_lines = []
    contracted = [p for p in fig["parts"] if p["billing"] != "none"]
    for p in fig["parts"]:
        if p["billing"] == "none":
            continue
        terms = terms_on(company, date.fromisoformat(p["from"]))
        if p is contracted[0]:
            terms_lines.append(t["terms_first"].format(terms=terms_text(terms, t, lang), cycle=cycle_text(fig["cycleDay"], t)))
        else:
            terms_lines.append(t["terms_next"].format(day=short_day(date.fromisoformat(p["from"]), t), terms=terms_text(terms, t, lang)))
    # Worked seconds per part from the (rounded) rows, by where their segments fall.
    part_worked = [0] * len(fig["parts"])
    for r in rows:
        for i, sec in enumerate(row_parts(r, fig["parts"], now)):
            part_worked[i] += sec
    total = sum(r["worked"] for r in rows)
    m = money(fig, total, part_worked)
    cur = fig["currency"]

    def eur(v):
        return fmt_money(v, lang, cur)

    for p, w in zip(fig["parts"], part_worked):
        if p["billing"] == "none" and fig["billing"] != "none":
            terms_lines.append(t["uncontracted"].format(day=short_day(date.fromisoformat(p["to"]) + timedelta(days=1), t), hours=fmt_duration(w)))
    packages = [p for p in fig["parts"] if p["billing"] == "package"]
    if len(packages) > 1 and fig["billing"] == "package":
        terms_lines.append(t["split"].format(days=" + ".join(str(p["days"]) for p in packages),
                                             owed=fmt_duration(fig["targetSec"]), fee=eur(m["net"])))
    totals = []
    vats = {l["vatPercent"] for l in m["lines"] if l["billing"] != "none"}
    if fig["billing"] == "package":
        totals.append(t["worked_owed"].format(worked=fmt_duration(total), owed=fmt_duration(fig["targetSec"])))
        diff = total - fig["targetSec"]
        totals[-1] += " " + (t["under"].format(diff=fmt_duration(-diff)) if diff < 0 else
                             t["over"].format(diff=fmt_duration(diff)) if diff > 0 else t["even"])
        vat_label = fmt_number(vats.pop(), lang, 0) if len(vats) == 1 else None
        if m["overSec"] > 0:
            extra = {"hours": fmt_duration(m["overSec"]), "rate": eur(m["overageRate"]), "net": eur(m["overageNet"])}
            totals.append(t["package_fee"].format(fee=eur(m["fee"])))
            totals.append((t["extra_waived"] if m["overageWaived"] else t["extra_billed"]).format(**extra))
            fee_key = "total_vat"
        else:
            fee_key = "fee"
        if vat_label is not None:
            totals.append(t[fee_key].format(net=eur(m["net"]), vat=vat_label, vat_amount=eur(m["vat"]), gross=eur(m["gross"])))
        else:
            totals.append(t["fee_mixed_vat"].format(net=eur(m["net"]), vat_amount=eur(m["vat"]), gross=eur(m["gross"])))
        if cfg["reportShowDiscount"] and m["standardValue"]:
            totals.append(t["value"].format(rate=eur(fig["standardRate"]), value=eur(m["standardValue"]),
                                            discount=eur(m["discount"]), pct=fmt_number(m["discountPercent"], lang)))
    elif fig["billing"] == "hourly" and len(fig["parts"]) == 1:
        p = fig["parts"][0]
        totals.append(t["worked"].format(worked=fmt_duration(total)))
        totals.append(t["billed"].format(rate=eur(p["standardRate"]), net=eur(m["net"]), vat=fmt_number(p["vatPercent"], lang, 0),
                                         vat_amount=eur(m["vat"]), gross=eur(m["gross"])))
    else:
        totals.append(t["worked"].format(worked=fmt_duration(total)))
        for l in m["lines"]:
            span = span_label(date.fromisoformat(l["from"]), date.fromisoformat(l["to"]), t)
            if l["billing"] == "package":
                totals.append(t["line_package"].format(span=span, net=eur(l["net"])))
            elif l["billing"] == "hourly":
                totals.append(t["line_hourly"].format(span=span, hours=fmt_duration(l["workedSec"]), rate=eur(l["standardRate"]), net=eur(l["net"])))
            elif fig["billing"] != "none":
                totals.append(t["line_none"].format(span=span, hours=fmt_duration(l["workedSec"])))
        if fig["billing"] != "none":
            totals.append(t["total"].format(net=eur(m["net"]), vat_amount=eur(m["vat"]), gross=eur(m["gross"])))
    notes = []
    if cfg["reportRoundingMinutes"]:
        notes.append(t["rounded"])
    notes.append(t["footer"].format(n=len(rows), when=local(now).strftime("%Y-%m-%d %H:%M")))
    return {"title": title, "terms": terms_lines, "columns": t["columns"], "rows": table_rows(rows, t, False),
            "totals": totals, "notes": notes, "empty": t["empty"], "lang": lang, "t": t}


def week_report(company, monday, rows, cfg, now, with_company):
    lang = cfg["reportLanguage"]
    t = TEXT[lang]
    last = monday + timedelta(days=6)
    rng = "%s – %s %d" % (day_label(monday, t), day_label(last, t), last.year)
    who = t["for"].format(name=company["name"]) if company else ""
    title = t["week_title"].format(who=who, n=monday.isocalendar()[1], range=rng)
    total = sum(r["worked"] for r in rows)
    guide = guide_on(company, monday) if company else 0
    totals = [t["week_total"].format(worked=fmt_duration(total), guide=fmt_duration(guide)) if guide
              else t["week_total_plain"].format(worked=fmt_duration(total))]
    columns = list(t["columns"])
    if with_company:
        columns.insert(1, t["company_column"])
    notes = []
    if cfg["reportRoundingMinutes"]:
        notes.append(t["rounded"])
    notes.append(t["footer"].format(n=len(rows), when=local(now).strftime("%Y-%m-%d %H:%M")))
    return {"title": title, "terms": [], "columns": columns, "rows": table_rows(rows, t, with_company),
            "totals": totals, "notes": notes, "empty": t["empty"], "lang": lang, "t": t}


def md_escape(text):
    """Plain text in Markdown: no markup, links, images or raw HTML from the
    data. Inline context only (every line is a heading, a paragraph or a cell)."""
    return re.sub(r"([\\`*_\[\]<>|~&])", r"\\\1", text)


def render_markdown(rep):
    e = md_escape
    lines = ["# " + e(rep["title"]), ""]
    if rep["terms"]:
        lines += [e(x) for x in rep["terms"]] + [""]
    if rep["rows"]:
        lines.append("| " + " | ".join(e(c) for c in rep["columns"]) + " |")
        lines.append("|" + "---|" * len(rep["columns"]))
        for cells in rep["rows"]:
            lines.append("| " + " | ".join(e(c) for c in cells) + " |")
    else:
        lines.append(e(rep["empty"]))
    lines.append("")
    lines += [e(x) for x in rep["totals"]] + [""]
    lines += [e(x) for x in rep["notes"]]
    return "\n".join(lines) + "\n"


HTML_PAGE = """<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
body {{ font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; color: #1d1d1f; background: #fff; margin: 0; }}
main {{ max-width: 720px; margin: 0 auto; padding: 40px 24px; }}
h1 {{ font-size: 22px; margin: 0 0 16px; }}
h2 {{ font-size: 13px; text-transform: uppercase; letter-spacing: .06em; color: #6e6e73; margin: 28px 0 8px; }}
p {{ margin: 4px 0; }}
table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
th {{ text-align: left; font-weight: 600; border-bottom: 1px solid #d2d2d7; padding: 6px 8px; }}
td {{ padding: 6px 8px; vertical-align: top; border-bottom: 1px solid #ececf0; }}
tbody tr:nth-child(even) td {{ background: #f7f7f9; }}
td.num, th.num {{ text-align: right; white-space: nowrap; }}
td.nowrap {{ white-space: nowrap; }}
footer {{ margin-top: 28px; color: #6e6e73; font-size: 13px; }}
@media print {{ main {{ padding: 0; }} }}
</style>
</head>
<body>
<main>
<h1>{title}</h1>
{terms}
{table}
<h2>{totals_heading}</h2>
{totals}
<footer>{notes}</footer>
</main>
</body>
</html>
"""


def render_html(rep):
    e = html.escape
    t = rep["t"]
    terms = ""
    if rep["terms"]:
        terms = "<h2>%s</h2>\n%s" % (e(t["terms_heading"]), "\n".join("<p>%s</p>" % e(x) for x in rep["terms"]))
    hours_col = len(rep["columns"]) - 3
    if rep["rows"]:
        head = "".join('<th class="num">%s</th>' % e(c) if i == hours_col else "<th>%s</th>" % e(c) for i, c in enumerate(rep["columns"]))
        body = []
        for cells in rep["rows"]:
            tds = []
            for i, c in enumerate(cells):
                cls = ' class="num"' if i == hours_col else (' class="nowrap"' if i < hours_col else "")
                tds.append("<td%s>%s</td>" % (cls, e(c)))
            body.append("<tr>%s</tr>" % "".join(tds))
        table = "<table>\n<thead><tr>%s</tr></thead>\n<tbody>\n%s\n</tbody>\n</table>" % (head, "\n".join(body))
    else:
        table = "<p>%s</p>" % e(rep["empty"])
    return HTML_PAGE.format(lang=rep["lang"], title=e(rep["title"]), terms=terms, table=table,
                            totals_heading=e(t["totals_heading"]),
                            totals="\n".join("<p>%s</p>" % e(x) for x in rep["totals"]),
                            notes="<br>".join(e(x) for x in rep["notes"]))


def write_report(out_dir, stem, rep, rows, cfg):
    """The CSV, Markdown and HTML of one report under one free name: a
    second export of a period is `-2` in every format."""
    exts = [".csv", ".md"] + ([".html"] if cfg["reportHtml"] else [])
    base, n = stem, 2
    while any(os.path.exists(os.path.join(out_dir, base + ext)) for ext in exts):
        base, n = "%s-%d" % (stem, n), n + 1
    files = {}
    files["csv"] = os.path.join(out_dir, base + ".csv")
    write_csv(files["csv"], rows)
    files["markdown"] = os.path.join(out_dir, base + ".md")
    with open(files["markdown"], "x", encoding="utf-8") as f:
        f.write(render_markdown(rep))
    if cfg["reportHtml"]:
        files["html"] = os.path.join(out_dir, base + ".html")
        with open(files["html"], "x", encoding="utf-8") as f:
            f.write(render_html(rep))
    files["sessions"] = len(rows)
    return files


def cmd_export(store, args, now, cfg):
    today = local(now).date()
    out_dir = os.path.expanduser(args.out or "~/Documents/Worklog")
    os.makedirs(out_dir, exist_ok=True)
    names = {c["id"]: c["name"] for c in store.log["companies"]}
    several = len(store.log["companies"]) > 1
    suffix = "-es" if cfg["reportLanguage"] == "es" else ""
    every = args.company in ("all",) or (args.company in (None, "") and not args.month)
    company = None if every else (resolve_company(store, args.company, allow_archived=True) if args.company else current_company(store))

    def stem(c, key):
        return "worklog-" + (slug(c["name"]) + "-" if c and several else "") + key + suffix

    if args.month:
        targets = [company] if company else None
        month_key = month_key_arg(args.month, None, today)
        if targets is None:
            # Each company's cycle that starts in this month, when it has sessions.
            targets = [c for c in companies_sorted(store)
                       if sessions_in(store, *cycle_bounds(c["cycleDay"], month_key), now, c["id"])]
        reports = []
        for c in targets:
            key = month_key_arg(args.month, c, today) if company else month_key
            fig = cycle_figures(c, key, all_segments(store, False, now, c["id"]), today, now)
            a, b = date.fromisoformat(fig["start"]), date.fromisoformat(fig["end"])
            rows = export_rows(sessions_in(store, a, b, now, c["id"]), now, cfg["reportRoundingMinutes"],
                               day_start(a), day_start(b + timedelta(days=1)), names)
            reports.append(write_report(out_dir, stem(c, key), month_report(c, fig, rows, cfg, now), rows, cfg))
        if company:
            return reports[0]
        return {"reports": reports, "sessions": sum(r["sessions"] for r in reports)}
    key = args.week or "this"
    monday = week_monday(today) if key == "this" else monday_of_key(key)
    last = monday + timedelta(days=6)
    rows = export_rows(sessions_in(store, monday, last, now, company["id"] if company else None), now,
                       cfg["reportRoundingMinutes"], day_start(monday), day_start(last + timedelta(days=1)), names)
    rep = week_report(company, monday, rows, cfg, now, with_company=company is None and several)
    return write_report(out_dir, stem(company, week_key(monday)), rep, rows, cfg)


# ---------------------------------------------------------------- main

MUTATING = {
    "start": cmd_start, "pause": cmd_pause, "resume": cmd_resume, "unpause": cmd_unpause,
    "stop": cmd_stop, "back": cmd_back, "draft": cmd_draft, "edit-active": cmd_edit_active,
    "confirm": cmd_confirm, "discard": cmd_discard, "heartbeat": cmd_heartbeat,
    "announce": cmd_announce, "add": cmd_add, "update": cmd_update, "delete": cmd_delete,
    "company": cmd_company, "contract": cmd_contract, "overage": cmd_overage,
}
LOG_WRITERS = {"confirm", "add", "update", "delete", "company", "contract", "overage"}


def parser():
    p = argparse.ArgumentParser(prog="worklog.py")
    p.add_argument("cmd")
    p.add_argument("--config")
    p.add_argument("--at")
    p.add_argument("--reason")
    p.add_argument("--note")
    p.add_argument("--summary")
    p.add_argument("--tags")
    p.add_argument("--segments")
    p.add_argument("--id")
    p.add_argument("--boot-id", dest="boot_id")
    p.add_argument("--week")
    p.add_argument("--month")
    p.add_argument("--out")
    p.add_argument("--company")
    p.add_argument("--action")
    p.add_argument("--name")
    p.add_argument("--tag")
    p.add_argument("--cycle-day", dest="cycle_day")
    p.add_argument("--from", dest="from_")
    p.add_argument("--terms")
    p.add_argument("--replace")
    return p


def run(argv):
    args = parser().parse_args(argv)
    cfg = config_from(args.config)
    now = now_utc()
    store = Store(cfg, now)
    try:
        if args.cmd == "view":
            pass
        elif args.cmd in MUTATING:
            before_log = json.dumps(store.log, sort_keys=True)
            MUTATING[args.cmd](store, args, now)
            if args.cmd in LOG_WRITERS or json.dumps(store.log, sort_keys=True) != before_log:
                store.save_log()
            store.save_active()
        elif args.cmd == "recover":
            store.extra["recovery"] = cmd_recover(store, args, now)
            store.save_active()
        elif args.cmd == "sessions":
            return {"ok": True, "sessions": cmd_sessions(store, args, now, cfg)}
        elif args.cmd == "month":
            return {"ok": True, "month": cmd_month(store, args, now)}
        elif args.cmd == "export":
            return {"ok": True, "export": cmd_export(store, args, now, cfg)}
        else:
            raise Refusal("unknown command: " + args.cmd[:40], "cmd")
        out = {"ok": True, "view": build_view(store, now)}
        out.update(store.extra)
        return out
    finally:
        store.close()


def main(argv=None):
    os.umask(0o077)
    try:
        result = run(sys.argv[1:] if argv is None else argv)
        code = 0
    except Refusal as e:
        result = {"ok": False, "error": e.error, "field": e.field}
        code = 1
    except SystemExit:
        result = {"ok": False, "error": "bad arguments", "field": "cmd"}
        code = 1
    except Exception as e:  # the shell needs one JSON line whatever happens
        result = {"ok": False, "error": "internal error: %s: %s" % (type(e).__name__, str(e)[:200]), "field": ""}
        code = 1
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
