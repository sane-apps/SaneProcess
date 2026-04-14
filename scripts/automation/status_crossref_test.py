#!/usr/bin/env python3
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("sane-status-crossref.sh")


def write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class StatusCrossrefScriptTests(unittest.TestCase):
    def test_runner_uses_json_file_flow_and_reaches_issue_and_pr_sections(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_home = root / "home"
            fake_home.mkdir(parents=True)

            repo_root = root / "scripts"
            automation_dir = repo_root / "automation"
            automation_dir.mkdir(parents=True)

            script_copy = automation_dir / "sane-status-crossref.sh"
            script_copy.write_text(SCRIPT_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            script_copy.chmod(SCRIPT_PATH.stat().st_mode)

            sane_master = repo_root / "SaneMaster.rb"
            sane_master.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env ruby
                    require "json"

                    command = ARGV.shift
                    case command
                    when "sales"
                      puts "stub sales ok"
                    when "listing_actions"
                      json_out = nil
                      while (arg = ARGV.shift)
                        json_out = ARGV.shift if arg == "--json-out"
                      end
                      abort("missing --json-out") unless json_out
                      payload = {
                        current_actions: [
                          {
                            site: "SaaSworthy",
                            workflow: "Complete vendor portal profile",
                            action_status: "Needs action",
                            latest_email_id: 531
                          }
                        ]
                      }
                      File.write(json_out, JSON.pretty_generate(payload))
                      puts "stub listing actions written"
                    else
                      warn "unexpected command: #{command.inspect}"
                      exit 1
                    end
                    """
                ),
                encoding="utf-8",
            )
            sane_master.chmod(sane_master.stat().st_mode | stat.S_IXUSR)

            inbox_dir = fake_home / "SaneApps" / "infra" / "scripts"
            inbox_dir.mkdir(parents=True)
            write_executable(
                inbox_dir / "check-inbox.sh",
                "#!/usr/bin/env bash\nprintf 'stub inbox ok\\n'\n",
            )

            bin_dir = root / "bin"
            bin_dir.mkdir()
            write_executable(
                bin_dir / "gh",
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    if [[ "$1" == "issue" && "$2" == "list" ]]; then
                      printf '123\\tOPEN\\tStub issue\\n'
                      exit 0
                    fi
                    if [[ "$1" == "pr" && "$2" == "list" ]]; then
                      printf '17\\tOPEN\\tStub pr\\n'
                      exit 0
                    fi
                    echo "unexpected gh args: $*" >&2
                    exit 1
                    """
                ),
            )

            env = os.environ.copy()
            env["HOME"] = str(fake_home)
            env["PATH"] = f"{bin_dir}:{env['PATH']}"

            result = subprocess.run(
                ["bash", str(script_copy)],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertIn("[3/5] Listing actions", result.stdout)
            self.assertIn("Current actions: 1", result.stdout)
            self.assertIn(
                "- SaaSworthy: Complete vendor portal profile (email #531)",
                result.stdout,
            )
            self.assertIn("[4/5] Open GitHub issues", result.stdout)
            self.assertIn("123\tOPEN\tStub issue", result.stdout)
            self.assertIn("[5/5] Open GitHub PRs", result.stdout)
            self.assertIn("17\tOPEN\tStub pr", result.stdout)
            self.assertIn("Done.", result.stdout)


if __name__ == "__main__":
    unittest.main()
