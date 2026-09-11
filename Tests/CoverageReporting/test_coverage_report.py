import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/coverage-report.py"
SPEC = importlib.util.spec_from_file_location("coverage_report", SCRIPT)
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


def entry(name, covered, count, functions=(0, 0)):
    return {"filename": name, "summary": {
        "lines": {"covered": covered, "count": count, "percent": 999},
        "functions": {"covered": functions[0], "count": functions[1]}}}


def export(*files):
    return {"type": "llvm.coverage.json.export", "data": [{"files": list(files)}]}


class CoverageReportTests(unittest.TestCase):
    def test_filters_tests_dependencies_and_prefix_matches_and_weights_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = REPORT.summarize(export(
                entry(str(root / "Sources/Core/Small.swift"), 1, 1, (1, 1)),
                entry("Sources/Core/Large.swift", 1, 9, (1, 3)),
                entry(str(root / "Tests/CoreTests/Test.swift"), 100, 100),
                entry(str(root / ".build/checkouts/dependency/Sources/Core.swift"), 100, 100),
                entry(str(root / "SourcesElsewhere/Fake.swift"), 100, 100),
            ), root)
            self.assertEqual(len(report["files"]), 2)
            self.assertEqual(report["modules"]["Core"]["lines"], {"covered": 2, "count": 10})
            self.assertEqual(REPORT.percentage(report["totals"]["lines"]), 20)
            self.assertEqual(REPORT.percentage(report["totals"]["functions"]), 50)

    def test_duplicate_files_are_counted_once_and_conflicts_are_rejected(self):
        root = Path("/fixture")
        source = entry("Sources/Core/One.swift", 2, 4)
        report = REPORT.summarize(export(source, source), root)
        self.assertEqual(report["totals"]["lines"], {"covered": 2, "count": 4})
        with self.assertRaises(ValueError):
            REPORT.summarize(export(source, entry(source["filename"], 3, 4)), root)

    def test_zero_coverage_is_kept_and_empty_metric_is_not_called_complete(self):
        report = REPORT.summarize(export(entry("Sources/Core/Uncovered.swift", 0, 20)), Path("/fixture"))
        text = REPORT.markdown(report)
        self.assertIn("0.00%", text)
        self.assertIn("| Sources/Core/Uncovered.swift | 20 | 0.00% |", text)
        self.assertIsNone(REPORT.percentage(report["totals"]["functions"]))
        self.assertIn("not whole-app coverage", text)

    def test_missing_sources_and_invalid_counts_fail_instead_of_reporting_success(self):
        with self.assertRaises(ValueError):
            REPORT.summarize(export(entry("Tests/Test.swift", 1, 1)), Path("/fixture"))
        for invalid in [[], {"type": "wrong", "data": []}]:
            with self.assertRaises(ValueError):
                REPORT.summarize(invalid, Path("/fixture"))
        for covered, count in [(-1, 2), (3, 2), (True, 2), (1, 1.5)]:
            with self.assertRaises(ValueError):
                REPORT.summarize(export(entry("Sources/Core/One.swift", covered, count)), Path("/fixture"))

    def test_baseline_comparison_marks_gains_losses_and_unmeasured_modules(self):
        root = Path("/fixture")
        before = REPORT.summarize(export(entry("Sources/Core/A.swift", 3, 10), entry("Sources/MCP/A.swift", 9, 10)), root)
        after = REPORT.summarize(export(entry("Sources/Core/A.swift", 5, 10), entry("Sources/MCP/A.swift", 8, 10),
                                        entry("Sources/New/A.swift", 1, 1)), root)
        text = REPORT.markdown(after, before)
        self.assertIn("+20.00 pp", text)
        self.assertIn("-10.00 pp", text)
        self.assertIn("| New | 100.00% | 1/1 | — | — |", text)
        for invalid in [[], {"schema_version": 99}]:
            with self.assertRaises(ValueError):
                REPORT.markdown(after, invalid)

    def test_cli_writes_reviewable_artifacts_and_rejects_bad_input(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "input.json"
            source.write_text(json.dumps(export(entry("Sources/Core/One.swift", 2, 3))))
            output = root / "output"
            command = ["python3", str(SCRIPT), "--root", str(root), "--input", str(source), "--output", str(output)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((output / "summary.md").read_text(), result.stdout)
            self.assertEqual((output / "swiftpm-coverage.json").read_bytes(), source.read_bytes())
            self.assertEqual(json.loads((output / "summary.json").read_text())["totals"]["lines"], {"covered": 2, "count": 3})
            source.write_text("not JSON")
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Coverage report failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
