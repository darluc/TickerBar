#!/usr/bin/env python3
"""Convert an authorized, locally downloaded reference snapshot; no network or credentials.
Usage: python3 scripts/import-etf-seed.py data.js cumdays.json output.json
"""
import argparse
import json
import re
from pathlib import Path


def convert(source, cumulative):
    # The data file is a JS object containing JSON values and bare top-level keys.
    # Parse only that format, never eval arbitrary website JavaScript.
    text = source.read_text()
    match = re.search(r"window\.__ISLANDS\s*=\s*(\{.*\})\s*;?\s*$", text, re.S)
    if not match:
        raise ValueError("No supported data object")
    text = re.sub(r'(?m)^(\s*)(\w+):', r'\1"\2":', match[1])
    data = json.loads(text)
    daily, broad, cum = (data[k] for k in ("dailyData", "broadData", "cumData"))
    codes = [row["code"] for row in data["histData"]["funds"]]
    if len(codes) != 20 or len(set(codes)) != 20:
        raise ValueError("Expected a fixed 20-ETF basket")
    records = {}
    for i, date in enumerate(daily["dates"]):
        records[date] = {"date": date, "basketTurnover": daily["amount"][i] * 1e8,
                         "basketNetFlow": daily["netflow"][i] * 1e8}
    for i, date in enumerate(broad["dates"]):
        records.setdefault(date, {"date": date})["broadMarketFlows"] = {
            cat: broad["series"][cat][i] * 1e8 for cat in broad["cats"]}
    curves = []
    def curve(label, values, **dates):
        if len(values) != len(cum["slots"]):
            raise ValueError("Cumulative time axis length mismatch")
        curves.append(dict(label=label, interpolated=True, points=[
            dict(time=t, cumulative=value * 1e8) for t, value in zip(cum["slots"], values)
        ], **dates))
    for date, values in sorted(json.loads(cumulative.read_text()).items()):
        curve(date, values, date=date)
    # Prefer the more precise dedicated yesterday curve over cumdays' rounded values.
    curves = [c for c in curves if c["label"] != cum["prevDate"]]
    curve(cum["prevDate"], cum["prev"], date=cum["prevDate"])
    curve("种子20日均值", cum["avg20"], startDate=cum["avgFrom"], endDate=cum["avgTo"])
    cmp, typ = data["cmpData"], data["typData"]
    return dict(version=1, source="原站授权种子 / Choice 标注；申赎底层公式未核实；采集 2026-11-06",
                basketCodes=codes, days=sorted(records.values(), key=lambda d: d["date"]), curves=curves,
                samples=dict(dailyCount=cmp["sample"]["n"], turnoverMedian=cmp["sample"]["amtMed"] * 1e8,
                             excluded=cmp["excluded"], signalCount=typ["supN"], normalCount=typ["norN"],
                             startDate=typ["range"][0], endDate=typ["range"][1]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "cumulative", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    result = convert(args.source, args.cumulative)
    args.output.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    print(f"Archived {len(result['days'])} daily records and {len(result['curves'])} cumulative curves")
