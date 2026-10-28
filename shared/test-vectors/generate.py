#!/usr/bin/env python3
"""Reference implementation of docs/CONTRACT.md sections 2-4.

Writes qualification.json, ledger.json and status.json next to this file.
Run: python3 shared/test-vectors/generate.py
"""
import json
import math
import os
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
INF = float("inf")

DEFAULT_RULES = {
    "ratio": 10, "walkCadenceSpm": 100, "walkHrPct": 0.55, "otherHrPct": 0.65,
    "qualifyFraction": 0.8, "debitLimit": 60, "maxBank": None,
    "dailyPlayCap": None, "playWindows": None,
}


def rules(**kw):
    r = dict(DEFAULT_RULES)
    r.update(kw)
    return r


def round_half_away(x):
    return int(math.floor(abs(x) + 0.5)) * (1 if x >= 0 else -1)


def hr_threshold(pct, birth_year, at_year):
    return round_half_away(pct * (220 - (at_year - birth_year)))


def sample_passes(r, activity, birth_year, at_year, hr, cadence):
    if activity == "walk":
        t = hr_threshold(r["walkHrPct"], birth_year, at_year)
        return hr is not None and hr >= t and cadence is not None and cadence >= r["walkCadenceSpm"]
    t = hr_threshold(r["otherHrPct"], birth_year, at_year)
    return hr is not None and hr >= t


def minute_qualifies(r, p, t):
    return t > 0 and p >= r["qualifyFraction"] * t - 1e-9


# ---------------------------------------------------------------- qualification
def qualification():
    sample_cases = []
    for name, act, r, by, ay, hr, cad in [
        ("walk clearly passes", "walk", rules(), 2014, 2026, 160, 130.0),  # threshold 0.55*208=114.4 -> 114
        ("walk hr one below", "walk", rules(), 2014, 2026, 113, 120.0),
        ("walk hr exactly threshold", "walk", rules(), 2014, 2026, 114, 100.0),
        ("walk cadence just below", "walk", rules(), 2014, 2026, 150, 99.9),
        ("walk missing cadence", "walk", rules(), 2014, 2026, 150, None),
        ("walk missing hr", "walk", rules(), 2014, 2026, None, 130.0),
        ("cycle ignores cadence", "cycle", rules(), 2014, 2026, 135, None),      # 0.65*208=135.2 -> 135
        ("cycle hr below", "cycle", rules(), 2014, 2026, 134, 200.0),
        ("other hr ok", "other", rules(), 2014, 2026, 140, None),
        ("other missing hr", "other", rules(), 2014, 2026, None, None),
        ("midpoint rounds away from zero", "other", rules(otherHrPct=0.5), 2011, 2026, 103, None),  # 0.5*205=102.5 -> 103
        ("midpoint below", "other", rules(otherHrPct=0.5), 2011, 2026, 102, None),
        ("custom cadence", "walk", rules(walkCadenceSpm=120, walkHrPct=0.5), 2016, 2026, 105, 119.0),  # 0.5*210=105
    ]:
        sample_cases.append({
            "name": name, "activityType": act, "rules": r, "birthYear": by, "atYear": ay,
            "hr": hr, "cadence": cad,
            "expectedThresholdBpm": hr_threshold(r["walkHrPct"] if act == "walk" else r["otherHrPct"], by, ay),
            "expectedPass": sample_passes(r, act, by, ay, hr, cad),
        })

    session_cases = []
    for name, r, minutes in [
        ("all qualify", rules(), [[12, 12], [12, 12], [11, 12]]),
        ("80 percent boundary", rules(), [[10, 12], [9, 12], [8, 10], [7, 10]]),  # 10/12=.833 yes, 9/12=.75 no, 8/10 yes, 7/10 no
        ("empty minute never qualifies", rules(), [[0, 0], [12, 12]]),
        ("ratio 5", rules(ratio=5), [[12, 12], [12, 12]]),
        ("no minutes", rules(), []),
        ("fraction 1.0 needs all", rules(qualifyFraction=1.0), [[12, 12], [11, 12]]),
        ("fraction 0.5", rules(qualifyFraction=0.5), [[6, 12], [5, 12]]),
    ]:
        q = sum(1 for p, t in minutes if minute_qualifies(r, p, t))
        session_cases.append({
            "name": name, "rules": r,
            "minutes": [{"p": p, "t": t} for p, t in minutes],
            "expectedQualifyingMinutes": q,
            "expectedEarnedMinutes": q * r["ratio"],
        })
    return {"samples": sample_cases, "sessions": session_cases}


# ---------------------------------------------------------------- ledger
KIND_ORDER = {"earn": 0, "adjust": 1, "spend": 2}


def fold(entries, max_bank):
    seen = set()
    bal = 0
    for e in sorted(entries, key=lambda e: (e["at"], KIND_ORDER[e["kind"]], e["id"])):
        if e["id"] in seen:
            continue
        seen.add(e["id"])
        delta = -e["minutes"] if e["kind"] == "spend" else e["minutes"]
        if delta > 0 and max_bank is not None:
            bal = max(bal, min(bal + delta, max_bank))
        else:
            bal += delta
    return bal


def E(id, kind, minutes, at):
    return {"id": id, "kind": kind, "minutes": minutes, "at": at}


def ledger():
    cases = []
    for name, mb, entries in [
        ("empty", None, []),
        ("earn and spend", None, [E("s1", "earn", 100, 1000), E("p1", "spend", 1, 2000), E("p2", "spend", 1, 3000)]),
        ("debit goes negative", None, [E("p1", "spend", 1, 1000), E("p2", "spend", 1, 2000)]),
        ("adjust signed", None, [E("a1", "adjust", 30, 1000), E("a2", "adjust", -50, 2000)]),
        ("max bank caps credit", 120, [E("s1", "earn", 100, 1000), E("s2", "earn", 100, 2000)]),
        ("max bank after spend", 120, [E("s1", "earn", 100, 1000), E("p1", "spend", 50, 2000), E("s2", "earn", 100, 3000)]),
        ("earn exactly to cap", 60, [E("s1", "earn", 30, 1000), E("s2", "earn", 30, 2000), E("s3", "earn", 10, 3000)]),
        ("max bank repays debit", 20, [E("p1", "spend", 40, 1000), E("s1", "earn", 100, 2000)]),
        ("order independent input", 100, [E("s2", "earn", 90, 3000), E("p1", "spend", 60, 2000), E("s1", "earn", 90, 1000)]),
        ("same timestamp kind order", 100, [E("p", "spend", 50, 1000), E("e", "earn", 100, 1000), E("a", "adjust", 20, 1000)]),
        ("duplicate ids count once", None, [E("s1", "earn", 100, 1000), E("s1", "earn", 100, 1000), E("p1", "spend", 1, 2000)]),
        ("positive adjust capped", 60, [E("s1", "earn", 50, 1000), E("a1", "adjust", 30, 2000)]),
        ("negative adjust below zero", 60, [E("a1", "adjust", -10, 1000), E("s1", "earn", 100, 2000)]),
    ]:
        cases.append({"name": name, "maxBank": mb, "entries": entries, "expectedBalance": fold(entries, mb)})
    return {"cases": cases}


# ---------------------------------------------------------------- earn resolution
def resolve_earn(session, overrides, bonuses):
    o = [x for x in overrides if x["sessionId"] == session["id"]]
    if o:
        return o[0]["earnedMinutes"]
    ms_ = [b["multiplier"] for b in bonuses if b["startsAt"] <= session["startedAt"] < b["endsAt"]]
    m = max(ms_) if ms_ else 1.0
    return round_half_away(session["earnedMinutes"] * m)


def earn():
    S = lambda id, earned, started: {"id": id, "earnedMinutes": earned, "startedAt": started, "endedAt": started + 1800000}
    B = lambda mult, a, b: {"multiplier": mult, "startsAt": a, "endsAt": b}
    O = lambda sid, earned: {"sessionId": sid, "earnedMinutes": earned}
    cases = []
    for name, session, overrides, bonuses in [
        ("no override no bonus", S("session-a", 100, 1000), [], []),
        ("override replaces", S("session-a", 100, 1000), [O("session-a", 40)], []),
        ("override zero voids", S("session-a", 100, 1000), [O("session-a", 0)], []),
        ("override for other session ignored", S("session-a", 100, 1000), [O("session-b", 0)], []),
        ("bonus doubles", S("session-a", 100, 1000), [], [B(2.0, 0, 2000)]),
        ("bonus start inclusive", S("session-a", 100, 1000), [], [B(2.0, 1000, 2000)]),
        ("bonus end exclusive", S("session-a", 100, 1000), [], [B(2.0, 0, 1000)]),
        ("overlapping bonuses take max", S("session-a", 100, 1000), [], [B(1.5, 0, 5000), B(3.0, 500, 1500), B(2.0, 0, 5000)]),
        ("bonus rounds half away", S("session-a", 5, 1000), [], [B(1.5, 0, 5000)]),   # 7.5 -> 8
        ("bonus fractional", S("session-a", 10, 1000), [], [B(1.25, 0, 5000)]),      # 12.5 -> 13
        ("override beats bonus", S("session-a", 100, 1000), [O("session-a", 30)], [B(2.0, 0, 5000)]),
        ("zero base with bonus", S("session-a", 0, 1000), [], [B(2.0, 0, 5000)]),
    ]:
        cases.append({"name": name, "session": session, "overrides": overrides, "bonuses": bonuses,
                      "expectedEarnMinutes": resolve_earn(session, overrides, bonuses)})
    return {"cases": cases}


# ---------------------------------------------------------------- status
def hm(s):
    h, m = s.split(":")
    return int(h) * 60 + int(m)


def status(r, tz, now_iso, entries):
    zone = ZoneInfo(tz)
    now = datetime.fromisoformat(now_iso.replace("Z", "+00:00"))
    local = now.astimezone(zone)
    bal = fold(entries, r["maxBank"])
    today = local.date()
    played = sum(e["minutes"] for e in entries if e["kind"] == "spend"
                 and datetime.fromtimestamp(e["at"] / 1000, timezone.utc).astimezone(zone).date() == today)
    from_balance = bal + r["debitLimit"]
    from_cap = INF if r["dailyPlayCap"] is None else r["dailyPlayCap"] - played
    wins = r["playWindows"]
    if not wins:
        from_window = INF
    else:
        t = local.hour * 60 + local.minute + local.second / 60 + local.microsecond / 60e6
        wd = local.isoweekday()
        matches = [w for w in wins if wd in w["days"] and hm(w["start"]) <= t < hm(w["end"])]
        from_window = 0 if not matches else max(math.ceil(hm(w["end"]) - t) for w in matches)
    avail = max(0, min(from_balance, from_cap, from_window))
    can = avail > 0
    reason = None
    if not can:
        if from_window <= 0:
            reason = "outsidePlayWindow"
        elif from_cap <= 0:
            reason = "dailyCapReached"
        else:
            reason = "debitLimitReached"
    return {"balance": bal, "todayPlayed": played, "minutesAvailable": int(avail), "canPlay": can, "reason": reason}


def ms(iso):
    return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)


def status_cases():
    weekdays = [{"days": [1, 2, 3, 4, 5], "start": "16:00", "end": "20:00"}]
    weekend = [{"days": [6, 7], "start": "09:00", "end": "21:00"}]
    earn100 = E("s1", "earn", 100, ms("2026-10-26T08:00:00Z"))
    cases = []
    for name, r, tz, now, entries in [
        ("credit no limits", rules(), "Europe/London", "2026-10-28T17:00:00Z", [earn100]),
        ("zero balance uses debit", rules(), "Europe/London", "2026-10-28T17:00:00Z", []),
        ("debit limit reached", rules(debitLimit=60), "Europe/London", "2026-10-28T17:00:00Z",
         [E("p%d" % i, "spend", 1, ms("2026-10-27T10:00:00Z") + i * 60000) for i in range(60)]),
        ("debit zero blocks at zero", rules(debitLimit=0), "Europe/London", "2026-10-28T17:00:00Z", []),
        ("inside weekday window", rules(playWindows=weekdays), "Europe/London", "2026-10-28T17:00:00Z", [earn100]),  # Wed 17:00 GMT
        ("window end caps minutes", rules(playWindows=weekdays), "Europe/London", "2026-10-28T19:45:30Z", [earn100]),
        ("before window", rules(playWindows=weekdays), "Europe/London", "2026-10-28T15:59:00Z", [earn100]),
        ("at window end", rules(playWindows=weekdays), "Europe/London", "2026-10-28T20:00:00Z", [earn100]),
        ("weekend window on weekday", rules(playWindows=weekend), "Europe/London", "2026-10-28T12:00:00Z", [earn100]),
        ("multiple windows max", rules(playWindows=weekdays + [{"days": [3], "start": "18:00", "end": "22:00"}]),
         "Europe/London", "2026-10-28T19:00:00Z", [E("s1", "earn", 500, ms("2026-10-26T08:00:00Z"))]),
        ("timezone shifts weekday", rules(playWindows=weekend), "Pacific/Auckland", "2026-10-30T22:00:00Z", [earn100]),  # Sat 11:00 NZDT
        ("daily cap partly used", rules(dailyPlayCap=30), "Europe/London", "2026-10-28T17:00:00Z",
         [earn100] + [E("p%d" % i, "spend", 1, ms("2026-10-28T09:00:00Z") + i * 60000) for i in range(20)]),
        ("daily cap reached", rules(dailyPlayCap=10), "Europe/London", "2026-10-28T17:00:00Z",
         [earn100] + [E("p%d" % i, "spend", 1, ms("2026-10-28T09:00:00Z") + i * 60000) for i in range(10)]),
        ("yesterday spend not counted in cap", rules(dailyPlayCap=10), "Europe/London", "2026-10-28T17:00:00Z",
         [earn100] + [E("p%d" % i, "spend", 1, ms("2026-10-27T09:00:00Z") + i * 60000) for i in range(10)]),
        ("local midnight boundary", rules(dailyPlayCap=10), "America/New_York", "2026-10-28T03:30:00Z",  # 23:30 Oct 27 EDT
         [earn100] + [E("p%d" % i, "spend", 1, ms("2026-10-27T20:00:00Z") + i * 60000) for i in range(10)]),  # 16:00 Oct 27 EDT; a different UTC date
        ("window wins reason over cap", rules(dailyPlayCap=10, playWindows=weekdays), "Europe/London", "2026-10-28T12:00:00Z",
         [earn100] + [E("p%d" % i, "spend", 1, ms("2026-10-28T09:00:00Z") + i * 60000) for i in range(10)]),
        ("cap wins reason over debit", rules(dailyPlayCap=10, debitLimit=0), "Europe/London", "2026-10-28T17:00:00Z",
         [E("p%d" % i, "spend", 1, ms("2026-10-28T09:00:00Z") + i * 60000) for i in range(10)]),
        ("window end 24:00", rules(playWindows=[{"days": [1, 2, 3, 4, 5, 6, 7], "start": "20:00", "end": "24:00"}]),
         "Europe/London", "2026-10-28T23:50:00Z", [earn100]),
        ("balance smaller than window", rules(debitLimit=0, playWindows=weekdays), "Europe/London", "2026-10-28T17:00:00Z",
         [E("s1", "earn", 20, ms("2026-10-26T08:00:00Z"))]),
    ]:
        cases.append({"name": name, "rules": r, "timeZone": tz, "now": now, "entries": entries,
                      "expected": status(r, tz, now, entries)})
    return {"cases": cases}


def write(name, data):
    with open(os.path.join(HERE, name), "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    write("qualification.json", qualification())
    write("ledger.json", ledger())
    write("earn.json", earn())
    write("status.json", status_cases())
    print("ok")
