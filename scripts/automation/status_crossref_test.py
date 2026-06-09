#!/usr/bin/env python3
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("sane-status-crossref.sh")
GITHUB_QUEUE_PATH = Path(__file__).with_name("github-queue.sh")


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
            github_queue_copy = automation_dir / "github-queue.sh"
            github_queue_copy.write_text(GITHUB_QUEUE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            github_queue_copy.chmod(GITHUB_QUEUE_PATH.stat().st_mode | stat.S_IXUSR)

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
                    when "hosted_file_actions"
                      if ARGV.include?("--json")
                        payload = {
                          current_actions: [
                            {
                              app: "SaneBar",
                              hosted_version: "2.1.41",
                              expected_version: "2.1.45",
                              variant_id: "1227172"
                            }
                          ]
                        }
                        puts JSON.generate(payload)
                      else
                        warn "expected --json"
                        exit 1
                      end
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
            outreach_dir = fake_home / "SaneApps" / "apps" / "SaneSales"
            outreach_dir.mkdir(parents=True)
            (outreach_dir / ".outreach.yml").write_text(
                textwrap.dedent(
                    """\
                    product: SaneSales
                    launch_calendar:
                      classification: active_launch_window
                      last_launch_readiness:
                        date: "2026-05-15"
                        status: go_for_support_surfaces_only
                        launch_readiness_exit: 0
                        blocker_summary:
                          - Product Hunt relaunch requires moderation approval.
                      scheduled:
                        - date: "2026-05-16"
                          time: "10:00"
                          channel: X opportunity scan
                          status: scheduled
                          action: Draft only high-fit replies.
                    launch_package:
                      status: ready_to_schedule_except_product_hunt_relaunch_approval
                      channel_plan:
                        product_hunt: blocked_until_relaunch_review_approval
                        directories: scheduled_support_surfaces
                    directory_submissions:
                      product_hunt:
                        status: live_unfeatured_relaunch_review_requested
                        product_url: https://www.producthunt.com/products/sanesales
                        observed_votes: 1
                        observed_daily_rank: 565
                      macupdate:
                        status: ready_to_submit_approval_required
                    video_distribution:
                      youtube_upload_candidate:
                        status: uploaded
                        youtube_url: https://youtu.be/example
                    x_tweet_history:
                      - date: "2026-05-14"
                        status: posted
                        url: https://x.com/i/web/status/1
                    """
                ),
                encoding="utf-8",
            )

            bin_dir = root / "bin"
            bin_dir.mkdir()
            gh_log = root / "gh-args.log"
            write_executable(
                bin_dir / "gh",
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    printf '%s\\n' "$*" >> "$GH_LOG"
                    has_jq=0
                    for arg in "$@"; do
                      [[ "$arg" == "--jq" ]] && has_jq=1
                    done
                    if [[ "$1" == "api" && "$2" == "notifications" ]]; then
                      cat <<'JSON'
                    [
                      {
                        "repository": {"full_name": "sane-apps/SaneBar"},
                        "subject": {
                          "title": "New SaneBar evidence",
                          "type": "Issue",
                          "url": "https://api.github.com/repos/sane-apps/SaneBar/issues/142"
                        },
                        "reason": "comment",
                        "updated_at": "2026-05-04T11:00:00Z"
                      },
                      {
                        "repository": {"full_name": "open-saas-directory/awesome-native-macosx-apps"},
                        "subject": {
                          "title": "Add SaneClip to Clipboard Managers",
                          "type": "PullRequest",
                          "url": "https://api.github.com/repos/open-saas-directory/awesome-native-macosx-apps/pulls/34"
                        },
                        "reason": "mention",
                        "updated_at": "2026-03-26T19:30:09Z"
                      }
                    ]
                    JSON
                      exit 0
                    fi
                    if [[ "$1" == "search" && "$2" == "issues" ]]; then
                      if [[ "$has_jq" -eq 1 ]]; then
                        printf '## sane-apps/SaneProcess\\n'
                        printf '  #8\\tOPEN\\tStub process issue\\tenhancement\\t2026-04-24T00:45:15Z\\n'
                      else
                        cat <<'JSON'
                    [
                      {
                        "repository": {"nameWithOwner": "sane-apps/SaneProcess"},
                        "number": 8,
                        "title": "Stub process issue",
                        "updatedAt": "2026-04-24T00:45:15Z",
                        "url": "https://github.com/sane-apps/SaneProcess/issues/8"
                      }
                    ]
                    JSON
                      fi
                      exit 0
                    fi
                    if [[ "$1" == "search" && "$2" == "prs" ]]; then
                      if [[ "$has_jq" -eq 1 ]]; then
                        printf '## sane-apps/Sane-AppleDocs\\n'
                        printf '  #13\\tOPEN\\tStub docs dependency pr\\tdependabot[bot]\\tdependencies\\t2026-04-16T01:40:27Z\\n'
                      else
                        cat <<'JSON'
                    [
                      {
                        "repository": {"nameWithOwner": "sane-apps/Sane-AppleDocs"},
                        "number": 13,
                        "title": "Stub docs dependency pr",
                        "updatedAt": "2026-04-16T01:40:27Z",
                        "url": "https://github.com/sane-apps/Sane-AppleDocs/pull/13",
                        "author": {"login": "dependabot[bot]"},
                        "isDraft": false
                      }
                    ]
                    JSON
                      fi
                      exit 0
                    fi
                    if [[ "$1" == "issue" && "$2" == "view" ]]; then
                      cat <<'JSON'
                    {
                      "title": "Stub process issue",
                      "url": "https://github.com/sane-apps/SaneProcess/issues/8",
                      "updatedAt": "2026-04-24T00:45:15Z",
                      "labels": [{"name": "enhancement"}],
                      "comments": [
                        {
                          "author": {"login": "MrSaneApps"},
                          "createdAt": "2026-05-04T10:00:00Z",
                          "body": "Latest comment explains the remaining blocker."
                        }
                      ]
                    }
                    JSON
                      exit 0
                    fi
                    if [[ "$1" == "pr" && "$2" == "view" ]]; then
                      cat <<'JSON'
                    {
                      "title": "Stub docs dependency pr",
                      "url": "https://github.com/sane-apps/Sane-AppleDocs/pull/13",
                      "updatedAt": "2026-04-16T01:40:27Z",
                      "labels": [{"name": "dependencies"}],
                      "author": {"login": "dependabot[bot]"},
                      "isDraft": false,
                      "comments": [
                        {
                          "author": {"login": "reviewer"},
                          "createdAt": "2026-05-04T10:30:00Z",
                          "body": "Please rerun CI before merge."
                        }
                      ],
                      "reviews": [
                        {
                          "author": {"login": "maintainer"},
                          "submittedAt": "2026-05-04T10:35:00Z",
                          "state": "COMMENTED",
                          "body": "Looks fine after CI."
                        }
                      ]
                    }
                    JSON
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
            env["GH_LOG"] = str(gh_log)

            result = subprocess.run(
                ["bash", str(script_copy)],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertIn("[3/10] Listing actions", result.stdout)
            self.assertIn("Current actions: 1", result.stdout)
            self.assertIn(
                "- SaaSworthy: Complete vendor portal profile (email #531)",
                result.stdout,
            )
            self.assertIn("[4/10] Hosted-file dashboard actions", result.stdout)
            self.assertIn("Needs dashboard sync: 1", result.stdout)
            self.assertIn(
                "- SaneBar: hosted 2.1.41 -> expected 2.1.45 (variant 1227172)",
                result.stdout,
            )
            self.assertIn("[5/10] Outreach / launch operations", result.stdout)
            self.assertIn("Tracked apps: 1", result.stdout)
            self.assertIn("- SaneSales: active_launch_window", result.stdout)
            self.assertIn("Product Hunt: status=live_unfeatured_relaunch_review_requested", result.stdout)
            self.assertIn("X: posted=1", result.stdout)
            self.assertIn("[6/10] App Store release gates", result.stdout)
            self.assertIn(
                "appstore_submit.rb not found",
                result.stdout,
            )
            self.assertIn("[7/10] GitHub notifications", result.stdout)
            self.assertIn("Notifications: 2", result.stdout)
            self.assertIn("New SaneBar evidence", result.stdout)
            self.assertIn("[8/10] Open GitHub issues", result.stdout)
            self.assertIn("Scope: org-wide", result.stdout)
            self.assertIn("## sane-apps/SaneProcess", result.stdout)
            self.assertIn("#8\tOPEN\tStub process issue", result.stdout)
            self.assertIn("[9/10] Open GitHub PRs", result.stdout)
            self.assertIn("## sane-apps/Sane-AppleDocs", result.stdout)
            self.assertIn("#13\tOPEN\tStub docs dependency pr", result.stdout)
            self.assertIn("[10/10] GitHub comment/review activity", result.stdout)
            self.assertIn("Comments read: 1", result.stdout)
            self.assertIn("Latest comment explains the remaining blocker.", result.stdout)
            self.assertIn("Reviews read: 1", result.stdout)
            self.assertIn("Please rerun CI before merge.", result.stdout)
            self.assertIn("External notification-backed GitHub threads:", result.stdout)
            self.assertIn(
                "open-saas-directory/awesome-native-macosx-apps PR #34",
                result.stdout,
            )
            self.assertIn("Notification: mention", result.stdout)
            self.assertIn("Done.", result.stdout)
            gh_calls = gh_log.read_text(encoding="utf-8")
            self.assertIn("api notifications --paginate", gh_calls)
            self.assertIn("search issues --owner sane-apps --state open", gh_calls)
            self.assertIn("search prs --owner sane-apps --state open", gh_calls)
            self.assertIn("issue view 8 --repo sane-apps/SaneProcess --comments", gh_calls)
            self.assertIn("pr view 13 --repo sane-apps/Sane-AppleDocs --comments", gh_calls)
            self.assertIn(
                "pr view 34 --repo open-saas-directory/awesome-native-macosx-apps --comments",
                gh_calls,
            )
            self.assertNotIn("issue list", gh_calls)
            self.assertNotIn("pr list", gh_calls)


if __name__ == "__main__":
    unittest.main()
