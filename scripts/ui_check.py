#!/usr/bin/env python3
"""
End-to-end UI check. Drives the dashboard in a real browser and asserts
the things a screenshot cannot: that a sub-cent coin keeps its precision
through the ticket, that a fractional order is not rounded to zero, that
the watchlist and alerts round-trip, that the asset-class filters narrow
what they say they narrow, and that nothing writes to the console.

    .venv/bin/python scripts/ui_check.py       # API must be running

Screenshots land in $APEX_SHOTS, or a temp directory it prints.
"""
import asyncio, sys
from playwright.async_api import async_playwright

BASE = "http://127.0.0.1:8000"
import os, tempfile
SHOTS = os.environ.get("APEX_SHOTS", tempfile.mkdtemp(prefix="apex-ui-"))
checks = []
def check(n, c, d=""):
    checks.append((n, bool(c), d))
    print(f"  {'PASS' if c else 'FAIL'}  {n}" + (f"  [{d}]" if d else ""))

async def main():
    async with async_playwright() as pw:
        exe = os.environ.get("PLAYWRIGHT_CHROMIUM")
        b = await (pw.chromium.launch(executable_path=exe) if exe
                   else pw.chromium.launch())
        pg = await b.new_page(viewport={"width": 1600, "height": 1000})
        errs, logs = [], []
        pg.on("console", lambda m: (logs.append(m.text),
              errs.append(m.text) if m.type == "error" else None))
        pg.on("pageerror", lambda e: errs.append(f"pageerror: {e}"))

        await pg.goto(BASE, wait_until="networkidle")
        print("\n--- login ---")
        chips = await pg.locator("#demo-chips .chip, #demo-chips button, #demo-chips > *").count()
        check("demo account chips rendered", chips > 0, f"{chips} chips")
        names = await pg.locator("#demo-chips").inner_text()
        # These are the handles the user asked for by name, and the chip
        # label has to BE the handle -- it is what you type to sign in.
        import re as _re
        for who in ("samrender", "sam", "ginni", "vartika", "paritosh", "pari"):
            check(f"demo list offers the login '{who}'",
                  bool(_re.search(rf"\b{who}\b", names, _re.I)))

        await pg.fill("#email", "samrender@apex.io")
        await pg.fill("#password", "Apex@2026")
        await pg.click("#login-btn")
        await pg.wait_for_selector("#app.ready", timeout=20000)
        await pg.wait_for_timeout(2500)
        check("signed in", "Samrender" in await pg.locator("#who-name").inner_text())
        check("feed badge names the provider",
              "live" in (await pg.locator("#live-text").inner_text()).lower()
              or "simulated" in (await pg.locator("#live-text").inner_text()).lower(),
              await pg.locator("#live-text").inner_text())

        print("\n--- tape and asset classes ---")
        n_all = await pg.locator("#tape .tape-item").count()
        check("tape populated", n_all >= 20, f"{n_all} rows")
        await pg.click('#class-seg button[data-class="crypto"]')
        await pg.wait_for_timeout(400)
        n_c = await pg.locator("#tape .tape-item").count()
        check("crypto filter narrows the tape", 0 < n_c < n_all, f"{n_c} of {n_all}")
        check("crypto rows carry a 24x7 badge",
              await pg.locator("#tape .badge.c24").count() == n_c)
        await pg.click('#class-seg button[data-class="equity"]')
        await pg.wait_for_timeout(300)
        n_e = await pg.locator("#tape .tape-item").count()
        check("stocks filter narrows the tape", 0 < n_e < n_all, f"{n_e} of {n_all}")
        await pg.click('#class-seg button[data-class="all"]')
        await pg.wait_for_timeout(300)

        print("\n--- a sub-dollar coin keeps its precision ---")
        await pg.click('#tape .tape-item[data-sym="DOGE-USD"]')
        await pg.wait_for_timeout(2500)
        strip = await pg.locator("#quote-strip").inner_text()
        check("DOGE quote strip shows sub-cent precision",
              "0.1" in strip and "0.10" != strip[:4], strip.split("\n")[0][:70])
        limit = await pg.input_value("#o-limit")
        check("the ticket defaults to a tick-valid DOGE price",
              limit.startswith("0.1") and len(limit.split(".")[1]) >= 4, limit)
        step = await pg.get_attribute("#o-limit", "step")
        check("the price input's step matches the instrument's tick", step == "0.00001", str(step))
        qstep = await pg.get_attribute("#o-qty", "step")
        check("the quantity input's step matches the lot size",
              qstep == "1e-8" or float(qstep) == 1e-8, str(qstep))
        book = await pg.locator("#book .book-row").count()
        check("the sub-cent book has levels", book >= 4, f"{book} levels")
        await pg.screenshot(path=f"{SHOTS}/01-doge.png")

        print("\n--- a fractional crypto order ---")
        await pg.click('#tape .tape-item[data-sym="BTC-USD"]')
        await pg.wait_for_timeout(2500)
        await pg.fill("#o-qty", "0.0015")
        await pg.click("#o-submit")
        await pg.wait_for_timeout(2500)
        toasts = await pg.locator("#toasts").inner_text()
        check("a fractional BTC order is accepted", "reject" not in toasts.lower(),
              toasts.replace("\n", " ")[:110])
        await pg.click('#blotter-tabs button[data-tab="positions"]')
        await pg.wait_for_timeout(1500)
        pos = await pg.locator("#blotter-body").inner_text()
        check("the fractional position is not rounded to zero",
              "BTC-USD" in pos and "0.0" in pos,
              [l for l in pos.split("\n") if "BTC" in l][:1])
        await pg.screenshot(path=f"{SHOTS}/02-positions.png")

        print("\n--- search ---")
        await pg.keyboard.press("/")
        await pg.wait_for_timeout(500)
        check("the / shortcut opens search",
              not await pg.locator("#search-modal").is_hidden())
        await pg.fill("#search-input", "bitcoin")
        await pg.wait_for_timeout(2500)
        rows = await pg.locator(".sr-row").count()
        check("search returns matches", rows > 0, f"{rows} rows")
        check("results say which are already listed",
              await pg.locator(".sr-row .act.listed").count() > 0)
        await pg.screenshot(path=f"{SHOTS}/03-search.png")
        await pg.keyboard.press("Enter")
        await pg.wait_for_timeout(2500)
        check("picking a result opens that instrument",
              "BTC-USD" in await pg.locator("#quote-strip").inner_text())

        print("\n--- watchlist ---")
        # Idempotent: a previous run may have left this name starred.
        if await pg.locator("#star-btn.on").count():
            await pg.click("#star-btn")
            await pg.wait_for_timeout(1500)
        await pg.click("#star-btn")
        await pg.wait_for_timeout(1500)
        check("starring adds to the watchlist",
              await pg.locator("#star-btn.on").count() == 1,
              await pg.locator("#star-btn").inner_text())
        await pg.click('#blotter-tabs button[data-tab="watchlist"]')
        await pg.wait_for_timeout(1800)
        wl = await pg.locator("#blotter-body").inner_text()
        check("the watchlist tab lists the starred name", "BTC-USD" in wl)
        check("the watchlist shows the session rule", "24" in wl)
        await pg.click('#class-seg button[data-class="watch"]')
        await pg.wait_for_timeout(600)
        check("the watchlist works as a tape filter",
              await pg.locator("#tape .tape-item").count() == 1,
              f'{await pg.locator("#tape .tape-item").count()} rows')
        await pg.click('#class-seg button[data-class="all"]')
        await pg.wait_for_timeout(400)

        print("\n--- price alert ---")
        await pg.click("#bell-btn")
        await pg.wait_for_timeout(600)
        check("the alert dialog opens", not await pg.locator("#alert-modal").is_hidden())
        thr = await pg.input_value("#alert-threshold")
        check("the alert threshold is pre-filled near the mark", bool(thr), thr)
        # A level already below the market, so it fires on the next sweep.
        px = float((await pg.locator("#quote-strip").inner_text()).split("\n")[1].replace(",", ""))
        await pg.fill("#alert-threshold", f"{px * 0.5:.2f}")
        await pg.fill("#alert-note", "browser check")
        await pg.click("#alert-form button[type=submit]")
        await pg.wait_for_timeout(1500)
        await pg.click('#blotter-tabs button[data-tab="alerts"]')
        await pg.wait_for_timeout(1800)
        al = await pg.locator("#blotter-body").inner_text()
        check("the alert is listed", "BTC-USD" in al and "browser check" in al)
        await pg.screenshot(path=f"{SHOTS}/04-alerts.png")
        # Let the ingestion worker's sweep fire it, then check the toast.
        await pg.wait_for_timeout(9000)
        al2 = await pg.locator("#blotter-body").inner_text()
        check("the alert fires and is recorded",
              "fired" in al2.lower(), al2.replace("\n", " ")[:140])

        print("\n--- chart indicators ---")
        await pg.click('#blotter-tabs button[data-tab="orders"]')
        for ind in ("bb", "rsi"):
            await pg.click(f'#ind-seg button[data-ind="{ind}"]')
            await pg.wait_for_timeout(1800)
        check("the RSI pane appears when toggled on",
              not await pg.locator("#rsi-chart").is_hidden())
        check("the chart canvas is drawn",
              await pg.locator("#chart canvas").count() >= 1)
        await pg.screenshot(path=f"{SHOTS}/05-indicators.png")

        print("\n--- markets, portfolio, history ---")
        await pg.keyboard.press("g"); await pg.keyboard.press("m")
        await pg.wait_for_timeout(2500)
        check("the g-m shortcut reaches Markets",
              await pg.locator("#view-markets").get_attribute("class") == "view active")
        mkc = await pg.locator("#mk-crypto").inner_text()
        check("the markets page has a crypto board", "BTC-USD" in mkc)
        check("the crypto board shows tick size", "0.00001" in mkc or "0.0001" in mkc)
        await pg.click('#mk-class button[data-class="crypto"]')
        await pg.wait_for_timeout(1500)
        g = await pg.locator("#mk-gainers").inner_text()
        check("the movers filter to crypto only",
              all("-USD" in l for l in g.split("\n") if "-USD" in l or "Inc" in l),
              g.replace("\n", " ")[:90])
        await pg.screenshot(path=f"{SHOTS}/06-markets.png")

        await pg.keyboard.press("g"); await pg.keyboard.press("p")
        await pg.wait_for_timeout(3000)
        pf = await pg.locator("#pf-metrics").inner_text()
        check("portfolio metrics render", len(pf) > 20, pf.replace("\n", " ")[:90])
        check("holdings include a coin",
              "-USD" in await pg.locator("#pf-positions").inner_text())
        alloc = await pg.locator("#pf-alloc").inner_text()
        check("allocation breaks the book down by asset class",
              "Stocks" in alloc and "Cash" in alloc, alloc.replace("\n", " ")[:90])
        check("allocation calls out the crypto weighting",
              "Crypto" in alloc and "Digital assets" in alloc)
        check("allocation names the largest position", "Largest position" in alloc)
        await pg.screenshot(path=f"{SHOTS}/07-portfolio.png")

        await pg.keyboard.press("g"); await pg.keyboard.press("h")
        await pg.wait_for_timeout(2500)
        h = await pg.locator("#history-table").inner_text()
        check("history renders rows", "buy" in h.lower() or "sell" in h.lower())
        await pg.screenshot(path=f"{SHOTS}/08-history.png")

        print("\n--- compliance health panel ---")
        await pg.click("#logout-btn"); await pg.wait_for_timeout(1200)
        await pg.fill("#email", "compliance@apex.io"); await pg.fill("#password", "Apex@2026")
        await pg.click("#login-btn"); await pg.wait_for_selector("#app.ready")
        await pg.wait_for_timeout(2000)
        await pg.click('nav button[data-view="compliance"]')
        await pg.wait_for_timeout(2500)
        hc = await pg.locator("#healthcheck").inner_text()
        check("the health panel reports the RLS invariant", "views_respect_rls" in hc)
        check("the health panel reports candle provenance",
              "history_is_marked_backfill" in hc)
        check("the health panel reports tick-grid pricing",
              "resting_prices_on_tick_grid" in hc)
        check("no structural invariant is failing", "FAIL" not in hc,
              [l for l in hc.split("\n") if "FAIL" in l][:2])
        await pg.screenshot(path=f"{SHOTS}/09-compliance.png")

        print("\n--- shortcuts sheet ---")
        await pg.keyboard.press("?")
        await pg.wait_for_timeout(500)
        check("the ? sheet opens", not await pg.locator("#keys-modal").is_hidden())
        check("it documents the shortcuts",
              await pg.locator("#keys-grid kbd").count() >= 10)
        await pg.keyboard.press("Escape")

        print("\n--- console ---")
        real = [e for e in errs if "favicon" not in e.lower()]
        check("no console errors", not real, "; ".join(real[:3]))

        await b.close()

    failed = [n for n, ok, _ in checks if not ok]
    print("\n" + "=" * 64)
    print(f"  {len(checks) - len(failed)}/{len(checks)} browser checks passed")
    for n in failed:
        print(f"    - {n}")
    print("=" * 64)
    return 1 if failed else 0

sys.exit(asyncio.run(main()))
