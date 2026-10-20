#!/usr/bin/env python3
"""End-to-end API smoke test. Exits non-zero on any failure."""
from __future__ import annotations

import json
import sys
from decimal import Decimal

import httpx

BASE = "http://127.0.0.1:8000"
PW = "Apex@2026"
checks: list[tuple[str, bool, str]] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    checks.append((name, bool(cond), detail))
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))


def main() -> int:
    c = httpx.Client(base_url=BASE, timeout=30.0)

    print("\n--- health ---")
    h = c.get("/api/health").json()
    check("health endpoint reports ok", h.get("status") == "ok")
    check("ledger reports balanced", h.get("ledger_balanced") is True)

    print("\n--- auth ---")
    r = c.post("/api/auth/login", json={"email": "samrender@apex.io", "password": PW})
    check("login succeeds", r.status_code == 200, f"HTTP {r.status_code}")
    tok = r.json()
    hdr = {"Authorization": f"Bearer {tok['access_token']}"}
    check("login returns an account id", tok.get("account_id") is not None)

    bad = c.post("/api/auth/login", json={"email": "samrender@apex.io", "password": "wrong"})
    check("wrong password is rejected", bad.status_code == 401, f"HTTP {bad.status_code}")
    check("unauthenticated request is rejected",
          c.get("/api/portfolio/summary").status_code in (401, 403))

    me = c.get("/api/auth/me", headers=hdr).json()
    check("me returns the caller's identity", me["user"]["email"] == "samrender@apex.io")

    print("\n--- market data ---")
    inst = c.get("/api/market/instruments", headers=hdr).json()
    check("instrument list is populated", len(inst) >= 16, f"{len(inst)} instruments")

    book = c.get("/api/market/book/AAPL", headers=hdr).json()
    check("order book has both sides",
          len(book["bids"]) > 0 and len(book["asks"]) > 0,
          f"{len(book['bids'])} bids / {len(book['asks'])} asks")
    best_bid = Decimal(book["bids"][0]["price"])
    best_ask = Decimal(book["asks"][0]["price"])
    check("book is not crossed", best_bid < best_ask, f"{best_bid} < {best_ask}")
    check("cumulative depth increases monotonically",
          all(Decimal(book["asks"][i]["cumulative_qty"])
              <= Decimal(book["asks"][i + 1]["cumulative_qty"])
              for i in range(len(book["asks"]) - 1)))

    cd = c.get("/api/market/candles/AAPL", headers=hdr,
               params={"interval": "1h", "days": 20}).json()
    check("hourly candles returned", cd["count"] > 20, f"{cd['count']} bars")
    bad_ohlc = [k for k in cd["candles"]
                if not (Decimal(k["high"]) >= max(Decimal(k["open"]), Decimal(k["close"]))
                        and Decimal(k["low"]) <= min(Decimal(k["open"]), Decimal(k["close"])))]
    check("every candle is OHLC-coherent", not bad_ohlc, f"{len(bad_ohlc)} violations")

    ind = c.get("/api/market/candles/AAPL", headers=hdr,
                params={"interval": "1d", "days": 60, "indicators": True}).json()
    check("indicators are computed",
          any(k.get("rsi_14") is not None for k in ind["candles"]))

    mv = c.get("/api/market/movers", headers=hdr).json()
    check("movers endpoint returns buckets", "gainers" in mv and "most_active" in mv)

    print("\n--- order entry ---")
    # Buy into the resting ask. Price is sent as a JSON number and parsed
    # as Decimal server-side, so it lands on the tick grid exactly.
    r = c.post("/api/orders", headers=hdr, json={
        "symbol": "AAPL", "side": "buy", "kind": "limit",
        "quantity": 10, "limit_price": float(best_ask), "tif": "day"})
    check("limit order accepted", r.status_code == 201, f"HTTP {r.status_code} {r.text[:120]}")
    o = r.json()
    check("order crossed and filled", o["status"] in ("filled", "partially_filled"),
          f"status={o['status']} filled={o['filled_qty']}")
    check("fills are reported back", len(o["fills"]) > 0, f"{len(o['fills'])} fill(s)")
    check("fill price equals the resting ask",
          Decimal(o["fills"][0]["price"]) == best_ask if o["fills"] else False)

    # Idempotency: same client_order_id must not create a second order.
    coid = "11111111-2222-3333-4444-555555555555"
    a = c.post("/api/orders", headers=hdr, json={
        "symbol": "MSFT", "side": "buy", "kind": "limit", "quantity": 1,
        "limit_price": 1.00, "tif": "gtc", "client_order_id": coid}).json()
    b = c.post("/api/orders", headers=hdr, json={
        "symbol": "MSFT", "side": "buy", "kind": "limit", "quantity": 1,
        "limit_price": 1.00, "tif": "gtc", "client_order_id": coid}).json()
    check("replayed client_order_id returns the same order",
          a.get("order_id") == b.get("order_id"), f"{a.get('order_id')} vs {b.get('order_id')}")

    # A resting order we can then cancel.
    # Quantize to the tick grid: 174.73 * 0.95 = 165.9935, which the
    # engine correctly rejects as a sub-tick price.
    away = (best_bid * Decimal("0.95")).quantize(Decimal("0.01"))
    rest = c.post("/api/orders", headers=hdr, json={
        "symbol": "AAPL", "side": "buy", "kind": "limit",
        "quantity": 5, "limit_price": float(away), "tif": "gtc"}).json()
    check("far-from-market order rests", rest["status"] == "working",
          f"{rest.get('status')} {rest.get('reject_reason') or ''}")

    # A deliberately sub-tick price must be refused.
    subtick = c.post("/api/orders", headers=hdr, json={
        "symbol": "AAPL", "side": "buy", "kind": "limit",
        "quantity": 5, "limit_price": 165.9935, "tif": "gtc"}).json()
    check("sub-tick price is rejected", subtick["status"] == "rejected",
          (subtick.get("reject_reason") or "")[:50])
    dc = c.delete(f"/api/orders/{rest['order_id']}", headers=hdr)
    check("order cancels", dc.status_code == 200 and dc.json()["status"] == "cancelled")
    dc2 = c.delete(f"/api/orders/{rest['order_id']}", headers=hdr)
    check("double-cancel is refused", dc2.status_code == 409, f"HTTP {dc2.status_code}")

    # Risk rejection is a 200 business outcome carrying a reason.
    rej = c.post("/api/orders", headers=hdr, json={
        "symbol": "AAPL", "side": "buy", "kind": "limit",
        "quantity": 9999999, "limit_price": float(best_ask), "tif": "day"})
    check("oversized order is rejected with a reason",
          rej.status_code == 201 and rej.json()["status"] == "rejected"
          and rej.json()["reject_reason"],
          (rej.json().get("reject_reason") or "")[:70])

    # Malformed order shape is caught before it reaches the database.
    bad_shape = c.post("/api/orders", headers=hdr, json={
        "symbol": "AAPL", "side": "buy", "kind": "limit", "quantity": 10})
    check("limit order without a price is a 422", bad_shape.status_code == 422)

    print("\n--- portfolio ---")
    s = c.get("/api/portfolio/summary", headers=hdr).json()
    check("summary returns NAV", s.get("nav") is not None, f"nav={s.get('nav')}")
    check("summary distinguishes cash flow from P&L",
          "cash_flow_today" in s and "pnl_today" in s)
    pos = c.get("/api/portfolio/positions", headers=hdr).json()
    check("positions returned", isinstance(pos, list) and len(pos) > 0, f"{len(pos)} positions")
    bl = c.get("/api/portfolio/blotter", headers=hdr).json()
    check("blotter returned", len(bl) > 0, f"{len(bl)} fills")
    ec = c.get("/api/portfolio/equity-curve", headers=hdr, params={"days": 60}).json()
    check("equity curve has history", len(ec["curve"]) > 10, f"{len(ec['curve'])} days")
    check("performance stats computed", ec["stats"].get("trading_days") is not None,
          f"sharpe={ec['stats'].get('sharpe_ratio')} maxdd={ec['stats'].get('max_drawdown_pct')}")
    led = c.get("/api/portfolio/ledger", headers=hdr).json()
    check("ledger postings visible to the owner", len(led) > 0, f"{len(led)} postings")

    aso = c.get("/api/portfolio/as-of", headers=hdr,
                params={"at": "2026-09-15T20:00:00Z"}).json()
    check("point-in-time reconstruction works", "holdings" in aso,
          f"{len(aso.get('holdings', []))} holdings on 2026-09-15")

    print("\n--- tenant isolation (RLS) ---")
    r2 = c.post("/api/auth/login", json={"email": "sam@apex.io", "password": PW}).json()
    hdr2 = {"Authorization": f"Bearer {r2['access_token']}"}
    p1 = {x["order_id"] for x in c.get("/api/orders", headers=hdr, params={"limit": 500}).json()}
    p2 = {x["order_id"] for x in c.get("/api/orders", headers=hdr2, params={"limit": 500}).json()}
    check("two traders see disjoint order sets", not (p1 & p2),
          f"{len(p1)} vs {len(p2)} orders, {len(p1 & p2)} shared")
    if p1:
        probe = c.get(f"/api/orders/{next(iter(p1))}", headers=hdr2)
        check("fetching another trader's order by id returns 404",
              probe.status_code == 404, f"HTTP {probe.status_code}")
    # Cross-account order placement must be refused.
    xacct = c.post("/api/orders", headers=hdr2, json={
        "symbol": "AAPL", "side": "buy", "kind": "limit", "quantity": 1,
        "limit_price": 1.00, "tif": "gtc", "account_id": tok["account_id"]})
    check("cannot trade on someone else's account", xacct.status_code == 403,
          f"HTTP {xacct.status_code}")

    print("\n--- social ---")
    lb = c.get("/api/social/leaderboard", headers=hdr).json()
    check("leaderboard returns ranked strategies", len(lb) > 0, f"{len(lb)} strategies")
    check("leaderboard carries risk-adjusted metrics",
          all("sharpe_ratio" in x and "max_drawdown_pct" in x for x in lb))

    print("\n--- compliance (role-gated) ---")
    deny = c.get("/api/admin/alerts", headers=hdr)
    check("trader cannot read surveillance alerts", deny.status_code == 403,
          f"HTTP {deny.status_code}")
    comp = c.post("/api/auth/login",
                  json={"email": "compliance@apex.io", "password": PW}).json()
    chdr = {"Authorization": f"Bearer {comp['access_token']}"}
    al = c.get("/api/admin/alerts", headers=chdr, params={"state": "all"}).json()
    check("compliance can read alerts", isinstance(al, list) and len(al) > 0,
          f"{len(al)} alerts")
    check("alerts carry evidence", all(x.get("evidence") for x in al))
    hc = c.get("/api/admin/health", headers=chdr).json()
    check("no structural invariant is broken", hc["all_passing"] is True,
          ", ".join(f"{x['check_name']}={x['status']}" for x in hc["failures"]) or "no FAILs")
    check("advisories are reported separately from failures",
          isinstance(hc.get("advisories"), list),
          f"{len(hc.get('advisories', []))} advisory/advisories")

    print("\n--- privilege escalation regression ---")
    # The RLS predicate helper is SECURITY DEFINER. If it tested
    # current_user (the superuser owner) instead of session_user,
    # pg_has_role would report EVERY caller as compliance and RLS would
    # be silently disabled database-wide. This asserts it is not.
    tr = c.get("/api/orders", headers=hdr, params={"limit": 500}).json()
    co = c.get("/api/orders", headers=chdr, params={"limit": 500}).json()
    check("a trader does not see the whole order table",
          len(tr) < len(co), f"trader {len(tr)} vs compliance {len(co)}")

    print("\n--- currency ---")
    fx = c.get("/api/market/fx", headers=hdr).json()
    check("FX board returned", len(fx) >= 5, f"{len(fx)} currencies")
    usd_inr = next((float(r["per_usd"]) for r in fx if r["code"] == "INR"), 0)
    inr_usd = next((float(r["in_usd"]) for r in fx if r["code"] == "INR"), 0)
    check("inverse rate is consistent", abs(usd_inr * inr_usd - 1) < 1e-6,
          f"{usd_inr:.4f} x {inr_usd:.6f}")

    wal = c.get("/api/portfolio/currencies", headers=hdr).json()
    check("currency wallet returned", "holdings" in wal and wal.get("base_currency"),
          f"base {wal.get('base_currency')}, {len(wal.get('holdings', []))} held")

    before = c.get("/api/portfolio/currencies", headers=hdr).json()
    conv = c.post("/api/portfolio/convert", headers=hdr, json={
        "from_currency": before["base_currency"],
        "to_currency": "INR" if before["base_currency"] != "INR" else "USD",
        "amount": 500})
    check("currency conversion succeeds", conv.status_code == 201,
          f"HTTP {conv.status_code} {conv.text[:70]}")
    if conv.status_code == 201:
        after = c.get("/api/portfolio/currencies", headers=hdr).json()
        check("conversion added a currency holding",
              len(after["holdings"]) >= len(before["holdings"]))

    # A rupee-funded account must still be able to buy a USD-priced stock.
    r2c = c.post("/api/auth/login", json={"email": "sam@apex.io", "password": PW}).json()
    hdr_inr = {"Authorization": f"Bearer {r2c['access_token']}"}
    sumi = c.get("/api/portfolio/summary", headers=hdr_inr).json()
    check("INR account reports its own base currency",
          sumi.get("base_currency") == "INR", str(sumi.get("base_currency")))
    # Pick a name this account does NOT already hold, or the
    # concentration limit fires first and we learn nothing about currency.
    held_inr = {p["symbol"] for p in c.get("/api/portfolio/positions", headers=hdr_inr).json()}
    all_inst = c.get("/api/market/instruments", headers=hdr_inr).json()
    # An EQUITY, deliberately. "Buy 1 unit" is a sensible equity clip and
    # a nonsense crypto one: one BTC is about 7.7m rupees, which trips the
    # per-order notional limit long before anything about currency is
    # exercised. Fractional crypto sizing gets its own check below.
    fresh = next((i["symbol"] for i in all_inst
                  if i["kind"] == "equity" and i["symbol"] not in held_inr), "MSFT")
    bk = c.get(f"/api/market/book/{fresh}", headers=hdr_inr).json()
    if bk["asks"]:
        xr = c.post("/api/orders", headers=hdr_inr, json={
            "symbol": fresh, "side": "buy", "kind": "limit", "quantity": 1,
            "limit_price": float(bk["asks"][0]["price"]), "tif": "day"})
        check(f"rupee account can buy a dollar-priced stock ({fresh})",
              xr.status_code == 201 and xr.json()["status"] in ("filled", "partially_filled"),
              xr.json().get("reject_reason") or xr.json().get("status"))
        fxh2 = c.get("/api/portfolio/history", headers=hdr_inr,
                     params={"kind": "fx", "limit": 20}).json()
        check("the purchase produced an auto-conversion",
              any("Auto-conversion" in (r.get("description") or "") for r in fxh2),
              f"{len(fxh2)} conversions on this account")

    # Fractional size is the whole point of a crypto lot. The seeder got
    # this wrong first: a flat 5-150 "share" clip meant every crypto
    # order failed its pre-trade check and no account ever held a coin.
    cb = c.get("/api/market/book/BTC-USD", headers=hdr_inr).json()
    if cb["asks"]:
        ask = Decimal(cb["asks"][0]["price"])
        frac = c.post("/api/orders", headers=hdr_inr, json={
            "symbol": "BTC-USD", "side": "buy", "kind": "limit",
            "quantity": 0.002, "limit_price": float(ask), "tif": "day"})
        check("a rupee account can buy a fraction of a coin",
              frac.status_code == 201, f"HTTP {frac.status_code} {frac.text[:110]}")
        if frac.status_code == 201:
            check("the fractional quantity is preserved exactly",
                  Decimal(frac.json()["filled_qty"]) == Decimal("0.002"),
                  frac.json().get("filled_qty"))
        big = c.post("/api/orders", headers=hdr_inr, json={
            "symbol": "BTC-USD", "side": "buy", "kind": "limit",
            "quantity": 1, "limit_price": float(ask), "tif": "day"})
        # A rejected order is still a successfully RECORDED order -- the
        # API answers 201 and the rejection is in the body, because an
        # order the risk engine turned down is part of the audit trail,
        # not a failed HTTP call.
        bj = big.json() if big.status_code == 201 else {}
        check("a whole coin exceeds the rupee account's order limit",
              bj.get("status") == "rejected",
              f"HTTP {big.status_code} status={bj.get('status')} "
              f"{str(bj.get('reject_reason'))[:90]}")
        check("the rejection says what the limit was",
              "limit" in str(bj.get("reject_reason", "")).lower(),
              str(bj.get("reject_reason"))[:110])

    print("\n--- short selling is a per-account privilege ---")
    # No demo trader has shorting enabled -- it is the wrong default for an
    # account someone signs in to and starts selling from. The privilege is
    # still real and still enforced in two independent places; this suite
    # proves the refusal, and the block below proves the privilege works
    # once an account is actually granted it.
    # Testing both proves the flag is what gates it, not account type.
    vt = c.post("/api/auth/login", json={"email": "vartika@apex.io", "password": PW}).json()
    hdr_v = {"Authorization": f"Bearer {vt['access_token']}"}
    sv = c.get("/api/portfolio/summary", headers=hdr_v).json()
    check("test account has shorting disabled", sv.get("allow_short_selling") is False)

    pos_v = c.get("/api/portfolio/positions", headers=hdr_v).json()
    held_v = {p["symbol"]: float(p["quantity"]) for p in pos_v}
    sym = next(iter(held_v), "AAPL")
    qty = int(held_v.get(sym, 0)) + 5          # just over what is held
    px = float(c.get(f"/api/market/quote/{sym}", headers=hdr_v).json()["last_price"])
    over = c.post("/api/orders", headers=hdr_v, json={
        "symbol": sym, "side": "sell", "kind": "limit",
        "quantity": qty, "limit_price": px, "tif": "day"})
    reason = over.json().get("reject_reason") or ""
    check("selling 5 more than held is rejected",
          over.json().get("status") == "rejected", reason[:80])
    check("rejection says shorting is not enabled",
          "Short selling is not enabled" in reason, reason[:80])
    check("rejection states what is actually held",
          f"you hold" in reason, reason[:80])

    # Selling exactly what IS held must still work.
    if held_v.get(sym, 0) >= 1:
        ok_sell = c.post("/api/orders", headers=hdr_v, json={
            "symbol": sym, "side": "sell", "kind": "limit", "quantity": 1,
            "limit_price": float(c.get(f"/api/market/book/{sym}",
                                 headers=hdr_v).json()["bids"][0]["price"]), "tif": "day"})
        check("selling what you do hold still works",
              ok_sell.json().get("status") in ("filled", "partially_filled", "working"),
              ok_sell.json().get("reject_reason") or ok_sell.json().get("status"))

    allpos = c.get("/api/portfolio/positions", headers=hdr_v).json()
    check("no negative positions on a non-shorting account",
          all(float(p["quantity"]) > 0 for p in allpos),
          f"{sum(1 for p in allpos if float(p['quantity']) < 0)} short position(s)")

    # The other half of the rule: an account that IS granted the privilege
    # can go short, and the ledger follows it there. Granted and revoked
    # inside this check so the suite leaves no account able to short.
    import subprocess
    def grant(flag):
        subprocess.run(
            ["./scripts/db.sh", "psql", "-qtAc",
             f"UPDATE trading.account SET allow_short_selling={flag} "
             f"WHERE account_no='{sv['account_no']}'"],
            check=True, capture_output=True)

    grant("TRUE")
    try:
        held_v = {p["symbol"]: Decimal(p["quantity"])
                  for p in c.get("/api/portfolio/positions", headers=hdr_v).json()}
        sym_v = next(iter(held_v))
        over = c.post("/api/orders", headers=hdr_v, json={
            "symbol": sym_v, "side": "sell", "kind": "market",
            "quantity": float(held_v[sym_v] + Decimal("5")), "tif": "day"})
        oj = over.json() if over.status_code == 201 else {}
        check("a granted account may sell more than it holds",
              oj.get("status") in ("filled", "partially_filled", "working"),
              f"HTTP {over.status_code} {oj.get('status')} "
              f"{str(oj.get('reject_reason'))[:70]}")
        after = {p["symbol"]: Decimal(p["quantity"])
                 for p in c.get("/api/portfolio/positions", headers=hdr_v).json()}
        check("the resulting position is genuinely short",
              after.get(sym_v, Decimal(0)) < held_v[sym_v],
              f"{held_v[sym_v]} -> {after.get(sym_v)}")
        check("the ledger still balances after a short",
              c.get("/api/health").json().get("ledger_balanced") is True)

        # Close it. A short left open would fail the "no negative
        # positions on a non-shorting account" assertion on the NEXT run
        # of this suite -- which is correct of that assertion and a bug in
        # this one. Buying it back restores the account either way.
        short_qty = after.get(sym_v, Decimal(0))
        if short_qty < 0:
            c.post("/api/orders", headers=hdr_v, json={
                "symbol": sym_v, "side": "buy", "kind": "market",
                "quantity": float(-short_qty), "tif": "day"})
            closed = {p["symbol"]: Decimal(p["quantity"])
                      for p in c.get("/api/portfolio/positions",
                                     headers=hdr_v).json()}
            check("the short can be bought back to flat",
                  closed.get(sym_v, Decimal(0)) >= 0,
                  str(closed.get(sym_v, "flat")))
    finally:
        grant("FALSE")
    check("the privilege is revoked again",
          c.get("/api/portfolio/summary", headers=hdr_v).json()
           .get("allow_short_selling") is False)

    print("\n--- history ---")
    hist = c.get("/api/portfolio/history", headers=hdr, params={"limit": 100}).json()
    check("history returns activity", len(hist) > 0, f"{len(hist)} rows")
    check("history rows carry a settling journal entry",
          all(r.get("entry_id") for r in hist))
    buys = c.get("/api/portfolio/history", headers=hdr,
                 params={"kind": "buys", "limit": 50}).json()
    check("history filters to buys only",
          all(r["action"] == "buy" for r in buys), f"{len(buys)} buys")
    fxh = c.get("/api/portfolio/history", headers=hdr,
                params={"kind": "fx", "limit": 50}).json()
    check("history filters to conversions only",
          all(r["action"] == "fx_conversion" for r in fxh), f"{len(fxh)} conversions")

    sec = c.get("/api/market/sectors", headers=hdr).json()
    check("sector performance returned", len(sec) > 0, f"{len(sec)} sectors")

    print("\n--- crypto ---")
    crypto = [i for i in inst if i.get("kind") == "crypto"]
    check("crypto instruments are listed", len(crypto) >= 8, f"{len(crypto)} pairs")
    check("crypto is flagged as trading 24x7",
          all(i.get("trades_24x7") for i in crypto))
    sub = [i for i in crypto if Decimal(i["last_price"]) < 1]
    check("a sub-dollar coin keeps its precision",
          bool(sub) and all(Decimal(i["tick_size"]) < Decimal("0.01") for i in sub),
          ", ".join(f"{i['symbol']}={i['last_price']}" for i in sub))

    cbook = c.get("/api/market/book/DOGE-USD", headers=hdr).json()
    check("a sub-cent book has quotes on both sides",
          len(cbook["bids"]) > 0 and len(cbook["asks"]) > 0,
          f"{len(cbook['bids'])} x {len(cbook['asks'])}")
    check("a sub-cent book is not collapsed onto one price",
          Decimal(cbook["bids"][0]["price"]) < Decimal(cbook["asks"][0]["price"]),
          f"{cbook['bids'][0]['price']} / {cbook['asks'][0]['price']}")

    ccd = c.get("/api/market/candles/BTC-USD", headers=hdr,
                params={"interval": "1m", "days": 3}).json()["candles"]
    check("crypto has minute history", len(ccd) > 3000, f"{len(ccd)} bars")
    # The corruption this guards against showed up exactly here: the last
    # bars of a 24x7 instrument replaced by a handful of unit ticks, two
    # orders of magnitude off the rest of the series.
    closes = [float(b["close"]) for b in ccd]
    span = max(closes) / max(min(closes), 1e-9)
    check("crypto history has no order-of-magnitude discontinuity", span < 3,
          f"max/min = {span:.2f}")
    # Volume is traded quantity only. A live minute with marks but no
    # fills reports zero, which is the honest answer -- it used to report
    # "12" (one per ingestion poll) next to a backfilled 2,500, which made
    # the histogram meaningless and dragged VWAP toward a price nothing
    # traded at. See migration 026. So the assertion is about the bars
    # that DID trade: none of them may be a rounding artefact.
    traded = sorted(float(b["volume"]) for b in ccd if float(b["volume"]) > 0)
    check("most bars carry real traded volume", len(traded) > len(ccd) * 0.9,
          f"{len(traded)}/{len(ccd)} bars")
    # A thin minute is normal -- one small fill and nothing else -- so a
    # minimum-vs-median test would just be flaky. What must never happen
    # is the TAIL of the series parting company with the rest of it: that
    # was the corruption signature, the roller overwriting the last bars
    # of a 24x7 instrument with prices derived from an unprimed feed.
    tail = [float(b["close"]) for b in ccd[-10:]]
    body_mean = sum(float(b["close"]) for b in ccd[-110:-10]) / 100
    check("the newest bars continue the series rather than replacing it",
          all(abs(x - body_mean) / body_mean < 0.05 for x in tail),
          f"tail {min(tail):.4f}-{max(tail):.4f} vs mean {body_mean:.4f}")
    check("a bar that reports volume also reports a trade count",
          all(b["trade_count"] > 0 for b in ccd if float(b["volume"]) > 0))
    check("a bar with no volume has no VWAP",
          all(b["vwap"] is None for b in ccd if float(b["volume"]) == 0))

    print("\n--- search & on-demand listing ---")
    sr = c.get("/api/market/search", headers=hdr, params={"q": "bitcoin"}).json()
    check("search finds a listed instrument by name",
          any(r["symbol"] == "BTC-USD" for r in sr), f"{len(sr)} hits")
    sr2 = c.get("/api/market/search", headers=hdr, params={"q": "AAP"}).json()
    check("search matches a partial symbol",
          any(r["symbol"] == "AAPL" for r in sr2))
    check("search marks which hits are already listed",
          all("listed" in r for r in sr2))

    print("\n--- watchlist ---")
    wl = c.get("/api/watchlist", headers=hdr).json()
    # The RLS hole: social.v_watchlist ran as its owner, so this endpoint
    # -- which has no user predicate of its own by design -- returned
    # every demo user's lists. Migration 024 made the view run as the
    # caller. One user, one default list.
    check("watchlist is scoped to the caller", len(wl) == 1, f"{len(wl)} list(s)")

    # Start from a known state. This suite runs against a LIVE database
    # that may already hold anything -- scripts/ui_check.py stars BTC-USD
    # and leaves it there -- and "the count went up by one" is only true
    # if the symbol was not already on the list. Adding an existing item
    # is an ON CONFLICT ... DO UPDATE, so the count stays put and the
    # assertion fails on leftover state rather than on a defect.
    c.delete("/api/watchlist/items/BTC-USD", headers=hdr)
    wl = c.get("/api/watchlist", headers=hdr).json()
    before = len(wl[0]["items"])
    c.post("/api/watchlist/items", headers=hdr, json={"symbol": "BTC-USD",
                                                      "note": "smoke test"})
    wl = c.get("/api/watchlist", headers=hdr).json()
    check("adding to the watchlist persists",
          len(wl[0]["items"]) == before + 1 and
          any(i["symbol"] == "BTC-USD" for i in wl[0]["items"]))
    check("watchlist rows carry a live quote",
          all(i.get("last_price") is not None for i in wl[0]["items"]))
    unlisted = c.post("/api/watchlist/items", headers=hdr,
                      json={"symbol": "NOTREAL"})
    check("watchlist rejects an unlisted symbol", unlisted.status_code == 404,
          f"HTTP {unlisted.status_code}")

    # Cross-user isolation, end to end -- the proof the SQL suite cannot
    # give, because it runs as a role that is legitimately privileged.
    r2 = c.post("/api/auth/login", json={"email": "vartika@apex.io", "password": PW})
    hdr2 = {"Authorization": f"Bearer {r2.json()['access_token']}"}
    wl2 = c.get("/api/watchlist", headers=hdr2).json()
    check("a second user sees only their own watchlist",
          len(wl2) == 1 and not any(i["symbol"] == "BTC-USD"
                                    for i in wl2[0]["items"]),
          f"{len(wl2)} list(s), {len(wl2[0]['items'])} item(s)")
    check("the two users' watchlists are different rows",
          wl[0]["watchlist_id"] != wl2[0]["watchlist_id"])

    c.delete("/api/watchlist/items/BTC-USD", headers=hdr)
    wl = c.get("/api/watchlist", headers=hdr).json()
    check("removing from the watchlist persists",
          not any(i["symbol"] == "BTC-USD" for i in wl[0]["items"]))

    print("\n--- price alerts ---")
    btc = next(i for i in inst if i["symbol"] == "BTC-USD")
    px = Decimal(btc["last_price"])
    far = c.post("/api/alerts", headers=hdr, json={
        "symbol": "BTC-USD", "kind": "above",
        "threshold": str((px * Decimal("1.5")).quantize(Decimal("0.01")))})
    check("an alert can be created", far.status_code == 201,
          f"HTTP {far.status_code} {far.text[:120]}")
    far_id = far.json()["alert_id"]

    bad_kind = c.post("/api/alerts", headers=hdr, json={
        "symbol": "BTC-USD", "kind": "sideways", "threshold": "1"})
    check("an unknown alert kind is rejected", bad_kind.status_code == 422,
          f"HTTP {bad_kind.status_code}")
    bad_sym = c.post("/api/alerts", headers=hdr, json={
        "symbol": "NOTREAL", "kind": "above", "threshold": "1"})
    check("an alert on an unlisted symbol is rejected", bad_sym.status_code == 404,
          f"HTTP {bad_sym.status_code}")

    al = c.get("/api/alerts", headers=hdr).json()
    mine = {a["alert_id"]: a for a in al["alerts"]}
    check("the alert is listed", far_id in mine, f"{len(mine)} alert(s)")
    check("an alert reports its distance from the current price",
          mine[far_id]["distance"] is not None,
          str(mine[far_id]["distance"]))

    # 50% above the mark must not fire.
    c.post("/api/alerts/evaluate", headers=hdr)
    al = c.get("/api/alerts", headers=hdr).json()
    mine = {a["alert_id"]: a for a in al["alerts"]}
    check("an unmet alert does not fire", mine[far_id]["fire_count"] == 0,
          f"fire_count={mine[far_id]['fire_count']}")

    # One that is already true must fire on the next sweep.
    near = c.post("/api/alerts", headers=hdr, json={
        "symbol": "BTC-USD", "kind": "above",
        "threshold": str((px * Decimal("0.5")).quantize(Decimal("0.01")))})
    near_id = near.json()["alert_id"]
    ev = c.post("/api/alerts/evaluate", headers=hdr).json()
    check("an evaluation sweep reports what it fired", ev.get("fired", 0) >= 1,
          json.dumps(ev))
    al = c.get("/api/alerts", headers=hdr).json()
    mine = {a["alert_id"]: a for a in al["alerts"]}
    check("a met alert fires", mine[near_id]["fire_count"] >= 1,
          f"fire_count={mine[near_id]['fire_count']}")
    check("a one-shot alert disarms itself after firing",
          mine[near_id]["is_active"] is False,
          f"is_active={mine[near_id]['is_active']}")
    check("the unmet alert is still armed", mine[far_id]["is_active"] is True)

    fires = [f for f in al["recent_fires"] if f["alert_id"] == near_id]
    check("a fire is recorded with the price that triggered it",
          len(fires) == 1 and Decimal(fires[0]["price"]) > 0,
          str(fires[0]["price"]) if fires else "no fire row")

    # Idempotence: a disarmed alert must not fire again on the next sweep.
    c.post("/api/alerts/evaluate", headers=hdr)
    al = c.get("/api/alerts", headers=hdr).json()
    check("a disarmed alert does not fire twice",
          len([f for f in al["recent_fires"] if f["alert_id"] == near_id]) == 1)

    # Removal. An alert that fired cannot be deleted -- risk.alert_fire is
    # append-only and references it -- so it is archived instead. Before
    # migration 025 these two FKs contradicted each other and DELETE
    # returned a 500 for exactly the alerts a user would want to clear.
    rm_far = c.delete(f"/api/alerts/{far_id}", headers=hdr)
    rm_near = c.delete(f"/api/alerts/{near_id}", headers=hdr)
    check("an alert that never fired is deleted outright",
          rm_far.status_code == 200 and rm_far.json()["outcome"] == "deleted",
          f"HTTP {rm_far.status_code} {rm_far.text[:100]}")
    check("an alert that fired is archived, not deleted",
          rm_near.status_code == 200 and rm_near.json()["outcome"] == "archived",
          f"HTTP {rm_near.status_code} {rm_near.text[:100]}")
    left = {a["alert_id"] for a in c.get("/api/alerts", headers=hdr).json()["alerts"]}
    check("both disappear from the caller's list",
          far_id not in left and near_id not in left, f"{len(left)} left")
    check("removing an alert twice is a 404",
          c.delete(f"/api/alerts/{far_id}", headers=hdr).status_code == 404)
    check("an archived alert cannot be removed again",
          c.delete(f"/api/alerts/{near_id}", headers=hdr).status_code == 404)
    # And it must stop being evaluated.
    ev2 = c.post("/api/alerts/evaluate", headers=hdr).json()
    check("an archived alert stops firing", ev2.get("fired", 0) == 0,
          json.dumps(ev2))

    print("\n--- the band must contain the book ---")
    # Seed from one price source, run the feed from another, and the price
    # band -- anchored on the external mark -- stops containing the order
    # book. Every order is then rejected as "outside the band", with
    # nothing logged and nothing corrupt. This is the check that names it.
    h = c.get("/api/health").json()
    check("health reports which marks are being refused",
          "divergent_instruments" in h, str(h.get("divergent_instruments")))
    check("no mark is currently diverging from the venue",
          not h.get("divergent_instruments"),
          str(h.get("divergent_instruments"))[:90])

    hc = c.get("/api/admin/health", headers=chdr).json()
    rows = {r["check_name"]: r for r in (hc if isinstance(hc, list) else hc.get("checks", []))}
    check("the band invariant is reported", "bands_contain_their_books" in rows,
          ", ".join(sorted(rows))[:120])
    if "bands_contain_their_books" in rows:
        check("every band still contains its own book",
              rows["bands_contain_their_books"]["status"] == "PASS",
              rows["bands_contain_their_books"]["detail"][:100])

    # And prove an order at the venue's own price is actually accepted --
    # the symptom this whole invariant exists to prevent.
    bk = c.get("/api/market/book/AAPL", headers=hdr).json()
    probe = c.post("/api/orders", headers=hdr, json={
        "symbol": "AAPL", "side": "buy", "kind": "limit", "quantity": 1,
        "limit_price": float(bk["asks"][0]["price"]), "tif": "day"})
    pj = probe.json() if probe.status_code == 201 else {}
    check("an order at the book's own price is not band-rejected",
          pj.get("status") != "rejected"
          or "band" not in str(pj.get("reject_reason", "")),
          f"{pj.get('status')} {str(pj.get('reject_reason'))[:70]}")

    print("\n--- openapi ---")
    spec = c.get("/openapi.json").json()
    check("OpenAPI schema generated", len(spec.get("paths", {})) > 25,
          f"{len(spec.get('paths', {}))} documented paths")

    c.close()

    failed = [n for n, ok, _ in checks if not ok]
    print("\n" + "=" * 64)
    print(f"  {len(checks) - len(failed)}/{len(checks)} API checks passed")
    if failed:
        print("  FAILED:")
        for n in failed:
            print(f"    - {n}")
    print("=" * 64)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
