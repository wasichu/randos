"""Offline regression fixtures for the trusted, no-checkout label workflow."""
from pathlib import Path
import json
import tempfile
import textwrap
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
workflow = (ROOT / ".github/workflows/dependabot-labels.yml").read_text()
module = types.ModuleType("dependency_labels")
code = textwrap.dedent(workflow.split("        run: |\n", 1)[1])
exec(compile(code, "dependabot-labels.yml", "exec"), module.__dict__)


def bot_commit(update="patch", group="tui-mix", verified=True):
    return {
        "author": {"login": "dependabot[bot]"},
        "commit": {
            "verification": {"verified": verified},
            "message": (
                "Bump dependencies\n\n---\nupdated-dependencies:\n"
                "- dependency-name: telemetry\n"
                f"  update-type: version-update:semver-{update}\n"
                f"  dependency-group: {group}\n...\n\nSigned-off-by: dependabot[bot]"
            ),
        },
    }


class DependencyLabelsTest(unittest.TestCase):
    def test_maintainer_commits_before_and_after_signed_metadata(self):
        maintainer = {"author": {"login": "wasichu"}, "commit": {"message": "Merge base"}}
        self.assertFalse(module.needs_major([maintainer, bot_commit(), maintainer]))

    def test_major_versions_and_breaking_zero_major_groups(self):
        self.assertTrue(module.needs_major([bot_commit(update="major")]))
        self.assertTrue(module.needs_major([bot_commit(update="minor", group="cargo-major")]))
        self.assertFalse(module.needs_major([bot_commit(update="minor", group="cargo")]))

    def test_unsigned_or_human_authored_metadata_is_rejected(self):
        forged = bot_commit(update="major")
        forged["author"]["login"] = "someone-else"
        for commit in (forged, bot_commit(verified=False), {"author": None}):
            with self.assertRaisesRegex(ValueError, "No verified"):
                module.needs_major([commit])
        self.assertFalse(module.needs_major([forged, bot_commit()]))

    def test_missing_or_incomplete_signed_metadata_is_rejected(self):
        for message in ("Bump something", "---\nupdated-dependencies:\n...", "---\nupdated-dependencies:\n- dependency-name: x\n..."):
            commit = bot_commit()
            commit["commit"]["message"] = message
            with self.assertRaisesRegex(ValueError, "No verified"):
                module.needs_major([commit])

    def test_major_is_retained_across_multiple_verified_updates(self):
        self.assertTrue(module.needs_major([bot_commit(update="major"), bot_commit()]))

    def test_signed_metadata_with_crlf_line_endings(self):
        commit = bot_commit(update="minor", group="cargo-major")
        commit["commit"]["message"] = commit["commit"]["message"].replace("\n", "\r\n")
        self.assertTrue(module.needs_major([commit]))

    def test_paginated_api_metadata_is_classified_and_labelled_without_shell_execution(self):
        event = {"pull_request": {"number": 33, "user": {"login": "dependabot[bot]"}}}
        pages = [[{"author": None}], [bot_commit(update="minor", group="cargo-major")]]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "event.json"
            path.write_text(json.dumps(event))
            with (
                patch.dict(module.os.environ, {"GITHUB_EVENT_PATH": str(path), "GITHUB_REPOSITORY": "owner/repo"}),
                patch.object(module.subprocess, "check_output", return_value=json.dumps(pages)) as fetch,
                patch.object(module.subprocess, "run") as label,
            ):
                module.main()
                fetch.assert_called_once_with([
                    "gh", "api", "--paginate", "--slurp",
                    "repos/owner/repo/pulls/33/commits?per_page=100",
                ], text=True)
                label.assert_called_once_with([
                    "gh", "pr", "edit", "33", "--repo", "owner/repo", "--add-label", "major",
                ], check=True)


if __name__ == "__main__":
    unittest.main()
