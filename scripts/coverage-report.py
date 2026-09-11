#!/usr/bin/env python3
"""Summarize SwiftPM's LLVM coverage export without counting tests or dependencies."""
import argparse
import json
from pathlib import Path
import shutil


METRICS = ("lines", "functions")


def counts(value):
    covered, count = value["covered"], value["count"]
    if type(covered) is not int or type(count) is not int or not 0 <= covered <= count:
        raise ValueError("Coverage counts must be integers with 0 <= covered <= count")
    return {"covered": covered, "count": count}


def percentage(value):
    return 100 * value["covered"] / value["count"] if value["count"] else None


def summarize(export, root):
    if not isinstance(export, dict) or export.get("type") != "llvm.coverage.json.export":
        raise ValueError("Expected an LLVM coverage JSON export from swift test")
    source_root = (root / "Sources").resolve()
    files = {}
    for group in export["data"]:
        for entry in group["files"]:
            source = Path(entry["filename"])
            if not source.is_absolute():
                source = root / source
            try:
                relative = source.resolve().relative_to(source_root)
            except ValueError:
                continue
            if len(relative.parts) < 2:
                continue
            name = "Sources/" + relative.as_posix()
            summary = {metric: counts(entry["summary"][metric]) for metric in METRICS}
            if name in files and files[name] != summary:
                raise ValueError(f"Conflicting coverage entries for {name}")
            files[name] = summary
    if not files:
        raise ValueError("No root Sources/ files found; check the report and repository root")
    modules = {}
    totals = {metric: {"covered": 0, "count": 0} for metric in METRICS}
    for name, summary in sorted(files.items()):
        module = name.split("/")[1]
        target = modules.setdefault(module, {metric: {"covered": 0, "count": 0} for metric in METRICS})
        for metric in METRICS:
            for key in ("covered", "count"):
                target[metric][key] += summary[metric][key]
                totals[metric][key] += summary[metric][key]
    return {"schema_version": 1, "modules": modules, "totals": totals, "files": dict(sorted(files.items()))}


def format_percentage(value):
    result = percentage(value)
    return f"{result:.2f}%" if result is not None else "—"


def markdown(report, baseline=None):
    if baseline is not None:
        if not isinstance(baseline, dict) or baseline.get("schema_version") != 1 or not isinstance(baseline.get("modules"), dict):
            raise ValueError("Baseline must be a summary.json produced by this script")
        for module in baseline["modules"].values():
            for metric in METRICS:
                counts(module[metric])
    lines = ["## Noodle test coverage", "",
             "Root source modules present in the SwiftPM test report. Test code and dependencies are excluded. "
             "App/UI targets absent from the test bundle are not measured; this is not whole-app coverage.", "",
             "| Module | Line coverage | Covered / executable lines | Function coverage |" + (" Change vs baseline |" if baseline else ""),
             "| --- | ---: | ---: | ---: |" + (" ---: |" if baseline else "")]
    for name, summary in report["modules"].items():
        label = name.replace("|", "\\|").replace("\n", " ")
        line = summary["lines"]
        row = f"| {label} | {format_percentage(line)} | {line['covered']:,}/{line['count']:,} | {format_percentage(summary['functions'])} |"
        if baseline:
            previous = baseline["modules"].get(name)
            before = percentage(previous["lines"]) if previous else None
            after = percentage(line)
            delta = f"{after - before:+.2f} pp" if before is not None and after is not None else "—"
            row += f" {delta} |"
        lines.append(row)
    total = report["totals"]["lines"]
    lines += ["", f"Combined measured-source line coverage: **{format_percentage(total)}** "
              f"({total['covered']:,}/{total['count']:,} executable lines).", "",
              "### Largest remaining gaps", "", "| Source file | Uncovered lines | Line coverage |", "| --- | ---: | ---: |"]
    gaps = sorted(report["files"].items(), key=lambda item: (-(item[1]["lines"]["count"] - item[1]["lines"]["covered"]), item[0]))
    for name, summary in gaps[:20]:
        line = summary["lines"]
        missing = line["count"] - line["covered"]
        if not missing:
            continue
        label = name.replace("|", "\\|").replace("\n", " ")
        lines.append(f"| {label} | {missing:,} | {format_percentage(line)} |")
    lines += ["", "The coverage artifact contains every source-file summary and the original SwiftPM JSON export.", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="JSON path printed by swift test --show-codecov-path")
    parser.add_argument("--output", type=Path, required=True, help="Directory for summary.md, summary.json and swiftpm-coverage.json")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--baseline", type=Path, help="Optional earlier summary.json for module percentage-point changes")
    args = parser.parse_args()
    try:
        report = summarize(json.loads(args.input.read_text()), args.root.resolve())
        baseline = json.loads(args.baseline.read_text()) if args.baseline else None
        rendered = markdown(report, baseline)
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        (args.output / "summary.md").write_text(rendered)
        raw = args.output / "swiftpm-coverage.json"
        if args.input.resolve() != raw.resolve():
            shutil.copyfile(args.input, raw)
        print(rendered, end="")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Coverage report failed: {error}\n")


if __name__ == "__main__":
    main()
