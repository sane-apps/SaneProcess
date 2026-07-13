#!/usr/bin/env python3
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("sane-status-crossref.sh")
GITHUB_HELPER_PATH = Path(__file__).with_name("sane-status-github.sh")


def write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def copy_status_runner(destination: Path) -> None:
    destination.write_text(SCRIPT_PATH.read_text(encoding="utf-8"), encoding="utf-8")
    destination.chmod(SCRIPT_PATH.stat().st_mode)
    helper_copy = destination.with_name("sane-status-github.sh")
    helper_copy.write_text(GITHUB_HELPER_PATH.read_text(encoding="utf-8"), encoding="utf-8")
    helper_copy.chmod(GITHUB_HELPER_PATH.stat().st_mode | stat.S_IXUSR)


def run_git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def init_git_repo(path: Path) -> None:
    path.mkdir(parents=True)
    run_git(path, "init")
    run_git(path, "config", "user.email", "status-test@saneapps.local")
    run_git(path, "config", "user.name", "Status Test")
    (path / "tracked.txt").write_text("clean\n", encoding="utf-8")
    run_git(path, "add", "tracked.txt")
    run_git(path, "commit", "-m", "Initial fixture")


class StatusCrossrefScriptTests(unittest.TestCase):
    def test_explicit_fast_status_surfaces_active_inbox_without_deep_lanes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_home = root / "home"
            fake_home.mkdir(parents=True)

            repo_root = root / "scripts"
            automation_dir = repo_root / "automation"
            automation_dir.mkdir(parents=True)

            script_copy = automation_dir / "sane-status-crossref.sh"
            copy_status_runner(script_copy)

            inbox_dir = fake_home / "SaneApps" / "infra" / "scripts"
            inbox_dir.mkdir(parents=True)
            write_executable(
                inbox_dir / "check-inbox.sh",
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    if [[ "${1:-}" == "active-summary" ]]; then
                      if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
                        echo "GitHub credential leaked into inbox child" >&2
                        exit 8
                      fi
                      if [[ "${STATUS_TEST_FAIL_INBOX:-0}" == "1" ]]; then
                        echo "stub inbox unavailable" >&2
                        exit 9
                      fi
                      echo "Business/API threads:"
                      echo "  - #1092 [REVIEW REQUIRED] Apollo API access"
                      exit 0
                    fi
                    echo "unexpected check-inbox args: $*" >&2
                    exit 1
                    """
                ),
            )

            sanecite = fake_home / "SaneApps" / "websites" / "sanecite-saas"
            saneprocess = fake_home / "SaneApps" / "infra" / "SaneProcess"
            init_git_repo(sanecite)
            init_git_repo(saneprocess)
            (saneprocess / "tracked.txt").write_text("dirty\n", encoding="utf-8")

            linked_source = root / "linked-source"
            init_git_repo(linked_source)
            saneclip = fake_home / "SaneApps" / "apps" / "SaneClip"
            saneclip.parent.mkdir(parents=True)
            run_git(linked_source, "worktree", "add", "-b", "status-linked", str(saneclip))
            (saneclip / "dirty-note.txt").write_text("untracked\n", encoding="utf-8")
            self.assertTrue((saneclip / ".git").is_file(), "fixture must exercise a linked worktree")

            fast_env = {
                **os.environ,
                "HOME": str(fake_home),
                "GH_TOKEN": "ambient-fast-token",
                "GITHUB_TOKEN": "ambient-fast-token",
            }
            result = subprocess.run(
                ["/bin/bash", str(script_copy), "--fast"],
                capture_output=True,
                text=True,
                env=fast_env,
                check=False,
            )

            self.assertEqual(
                result.returncode,
                0,
                msg=f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )
            self.assertIn("Sane status fast", result.stdout)
            self.assertIn("[1/3] Active inbox actions", result.stdout)
            self.assertIn("Business/API threads:", result.stdout)
            self.assertIn("#1092 [REVIEW REQUIRED] Apollo API access", result.stdout)
            self.assertIn("websites/sanecite-saas:", result.stdout)
            self.assertIn("apps/SaneClip:", result.stdout)
            self.assertIn("infra/SaneProcess:", result.stdout)
            self.assertIn("dirty files: 1", result.stdout)
            self.assertIn("?? dirty-note.txt", result.stdout)
            self.assertIn(" M tracked.txt", result.stdout)
            self.assertIn(f"Run: ruby {repo_root / 'SaneMaster.rb'} status", result.stdout)
            self.assertIn("not a full readiness verdict", result.stdout)
            self.assertIn("FAST STATUS: PARTIAL — selected lanes available (exit 0)", result.stdout)
            self.assertNotIn("[1/10] Sales", result.stdout)
            self.assertNotIn("[5/10] Setapp", result.stdout)

            failed_env = {**fast_env, "STATUS_TEST_FAIL_INBOX": "1"}
            failed = subprocess.run(
                ["/bin/bash", str(script_copy), "--fast"],
                capture_output=True,
                text=True,
                env=failed_env,
                check=False,
            )

            self.assertEqual(failed.returncode, 3, msg=failed.stderr)
            self.assertIn("stub inbox unavailable", failed.stderr)
            self.assertIn("[2/3] Key worktrees", failed.stdout)
            self.assertIn("not a full readiness verdict", failed.stdout)
            self.assertIn("FAST STATUS: PARTIAL AND INCOMPLETE", failed.stdout)
            self.assertIn("- Active inbox actions (exit 9)", failed.stdout)
            self.assertIn("Exit 3 means selected status coverage was incomplete", failed.stdout)

    def test_runner_uses_json_file_flow_and_reaches_issue_and_pr_sections(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_home = root / "home"
            fake_home.mkdir(parents=True)
            token_path = fake_home / ".codex" / "secrets" / "github_token"
            token_path.parent.mkdir(parents=True)
            token_path.write_text("fake-status-token\n", encoding="utf-8")
            token_path.chmod(0o600)

            for repo in (
                fake_home / "SaneApps" / "websites" / "sanecite-saas",
                fake_home / "SaneApps" / "apps" / "SaneClip",
                fake_home / "SaneApps" / "infra" / "SaneProcess",
            ):
                init_git_repo(repo)

            repo_root = root / "scripts"
            automation_dir = repo_root / "automation"
            automation_dir.mkdir(parents=True)

            script_copy = automation_dir / "sane-status-crossref.sh"
            copy_status_runner(script_copy)

            sane_master = repo_root / "SaneMaster.rb"
            sane_master.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env ruby
                    require "json"

                    if ENV["STATUS_CHILD_ENV_LOG"]
                      File.open(ENV.fetch("STATUS_CHILD_ENV_LOG"), "a") do |file|
                        gh = ENV.key?("GH_TOKEN") ? "present" : "missing"
                        github = ENV.key?("GITHUB_TOKEN") ? "present" : "missing"
                        file.puts "GH_TOKEN=#{gh} GITHUB_TOKEN=#{github}"
                      end
                    end

                    command = ARGV.shift
                    case command
                    when "sales"
                      if ENV["STATUS_TEST_FAIL_SALES"] == "1"
                        warn "stub sales unavailable"
                        exit 7
                      end
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
                    when "setapp_status"
                      puts "Setapp review status"
                      puts "- ⏳ SaneClip: In Review (status 5, version 2309 / 2.3.9, version_id 46886)"
                      puts "- ❌ SaneBar: Needs Revision (status 2, version 2168 / 2.1.68, version_id 46885)"
                      puts "ACTION REQUIRED: at least one Setapp version is waiting on us."
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
                    if [[ -n "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
                      printf 'token:scoped\\n' >> "$GH_LOG"
                    else
                      printf 'token:invalid-scope\\n' >> "$GH_LOG"
                    fi
                    printf 'path:%s\\n' "$PATH" >> "$GH_LOG"
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
            env["STATUS_CHILD_ENV_LOG"] = str(root / "child-env.log")
            env["STATUS_TEST_MODE"] = "1"
            env["STATUS_GH_BIN"] = str(bin_dir / "gh")
            env["GH_TOKEN"] = "ambient-token-must-not-leak"
            env["GITHUB_TOKEN"] = "ambient-token-must-not-leak"

            result = subprocess.run(
                ["/bin/bash", str(script_copy)],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertIn("[Core] Key worktrees", result.stdout)
            self.assertIn("[1/10] Sales", result.stdout)
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
            self.assertIn("[5/10] Setapp distribution channel", result.stdout)
            self.assertIn("Setapp review status", result.stdout)
            self.assertIn("SaneClip: In Review", result.stdout)
            self.assertIn("SaneBar: Needs Revision", result.stdout)
            self.assertIn("Setapp version is waiting on us", result.stdout)
            self.assertIn("[6/10] Outreach / launch operations", result.stdout)
            self.assertIn("Tracked apps: 1", result.stdout)
            self.assertIn("- SaneSales: active_launch_window", result.stdout)
            self.assertIn("Product Hunt: status=live_unfeatured_relaunch_review_requested", result.stdout)
            self.assertIn("X: posted=1", result.stdout)
            self.assertIn("[7/10] GitHub notifications", result.stdout)
            self.assertIn("Unread GitHub notifications: 2", result.stdout)
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
            self.assertIn("FULL STATUS: COMPLETE", result.stdout)
            self.assertNotIn("FULL STATUS: INCOMPLETE", result.stdout)
            gh_calls = gh_log.read_text(encoding="utf-8")
            self.assertIn("token:scoped", gh_calls)
            self.assertNotIn("token:invalid-scope", gh_calls)
            self.assertIn("path:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", gh_calls)
            self.assertNotIn(str(bin_dir), gh_calls)
            child_env = (root / "child-env.log").read_text(encoding="utf-8")
            self.assertNotIn("present", child_env)
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

            failed_env = {**env, "STATUS_TEST_FAIL_SALES": "1"}
            failed = subprocess.run(
                ["/bin/bash", str(script_copy), "--full"],
                capture_output=True,
                text=True,
                env=failed_env,
                check=False,
            )

            self.assertEqual(failed.returncode, 3, msg=failed.stderr)
            self.assertIn("stub sales unavailable", failed.stderr)
            self.assertIn("[10/10] GitHub comment/review activity", failed.stdout)
            self.assertIn("FULL STATUS: INCOMPLETE", failed.stdout)
            self.assertIn("- Sales (exit 7)", failed.stdout)
            self.assertIn("Exit 3 means full status coverage was incomplete", failed.stdout)
            self.assertNotIn("FULL STATUS: COMPLETE", failed.stdout)

    def test_checksuite_notifications_separate_active_from_superseded_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_home = root / "home"
            fake_home.mkdir()
            script_copy = root / "sane-status-crossref.sh"
            copy_status_runner(script_copy)

            token_path = fake_home / ".codex" / "secrets" / "github_token"
            token_path.parent.mkdir(parents=True)
            token_path.write_text("fake-status-token\n", encoding="utf-8")
            token_path.chmod(0o600)

            bin_dir = root / "bin"
            bin_dir.mkdir()
            write_executable(
                bin_dir / "gh",
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    endpoint="$2"
                    if [[ "$1" == "api" && "$endpoint" == "notifications" ]]; then
                      printf '%s\n' '[{"repository":{"full_name":"MrSaneApps/sanecite-saas"},"subject":{"title":"deploy workflow run failed for main branch","type":"CheckSuite","url":null},"reason":"ci_activity","updated_at":"2026-07-13T01:00:00Z"},{"repository":{"full_name":"MrSaneApps/sanecite-saas"},"subject":{"title":"deploy workflow run failed for main branch","type":"CheckSuite","url":null},"reason":"ci_activity","updated_at":"2026-07-13T03:00:00Z"},{"repository":{"full_name":"MrSaneApps/sanecite-saas"},"subject":{"title":"deploy workflow run failed for main branch","type":"CheckSuite","url":null},"reason":"ci_activity","updated_at":"2026-07-13T05:00:00Z"}]'
                      exit 0
                    fi
                    case "$endpoint" in
                      */check-suites/1) printf '{"id":1,"check_runs_url":"repos/MrSaneApps/sanecite-saas/check-suites/1/check-runs"}\n' ;;
                      */check-suites/2) printf '{"id":2,"check_runs_url":"repos/MrSaneApps/sanecite-saas/check-suites/2/check-runs"}\n' ;;
                      */check-suites/3) printf '{"id":3,"check_runs_url":"repos/MrSaneApps/sanecite-saas/check-suites/3/check-runs"}\n' ;;
                      */check-suites/1/check-runs) printf '{"check_runs":[{"details_url":"https://github.com/MrSaneApps/sanecite-saas/actions/runs/10"}]}\n' ;;
                      */check-suites/2/check-runs) printf '{"check_runs":[{"details_url":"https://github.com/MrSaneApps/sanecite-saas/actions/runs/20"}]}\n' ;;
                      */check-suites/3/check-runs) printf '{"check_runs":[{"details_url":"https://github.com/MrSaneApps/sanecite-saas/actions/runs/30"}]}\n' ;;
                      */actions/runs/10) printf '{"id":10,"workflow_id":5,"head_branch":"main","head_sha":"old-a","created_at":"2026-07-13T01:00:00Z","status":"completed","conclusion":"failure"}\n' ;;
                      */actions/runs/20) printf '{"id":20,"workflow_id":5,"head_branch":"main","head_sha":"old-b","created_at":"2026-07-13T03:00:00Z","status":"completed","conclusion":"failure"}\n' ;;
                      */actions/runs/30) printf '{"id":30,"workflow_id":5,"head_branch":"main","head_sha":"current","created_at":"2026-07-13T05:00:00Z","status":"completed","conclusion":"failure"}\n' ;;
                      *"actions/runs?branch=main&per_page=100") printf '%s\n' '{"workflow_runs":[{"id":10,"name":"deploy","workflow_id":5,"head_branch":"main","head_sha":"old-a","created_at":"2026-07-13T00:55:00Z","updated_at":"2026-07-13T01:00:00Z","status":"completed","conclusion":"failure"},{"id":20,"name":"deploy","workflow_id":5,"head_branch":"main","head_sha":"old-b","created_at":"2026-07-13T02:55:00Z","updated_at":"2026-07-13T03:00:00Z","status":"completed","conclusion":"failure"},{"id":30,"name":"deploy","workflow_id":5,"head_branch":"main","head_sha":"current","created_at":"2026-07-13T04:55:00Z","updated_at":"2026-07-13T05:00:00Z","status":"completed","conclusion":"failure"}]}' ;;
                      *"actions/workflows/5/runs?branch=main&per_page=20") printf '%s\n' '{"workflow_runs":[{"id":15,"head_sha":"green-a","created_at":"2026-07-13T02:00:00Z","status":"completed","conclusion":"success"},{"id":25,"head_sha":"green-b","created_at":"2026-07-13T04:00:00Z","status":"completed","conclusion":"success"},{"id":30,"head_sha":"current","created_at":"2026-07-13T05:00:00Z","status":"completed","conclusion":"failure"}]}' ;;
                      *) echo "unexpected gh endpoint: $endpoint" >&2; exit 1 ;;
                    esac
                    """
                ).lstrip(),
            )

            result = subprocess.run(
                ["/bin/bash", str(script_copy)],
                env={
                    **os.environ,
                    "HOME": str(fake_home),
                    "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "STATUS_TEST_MODE": "1",
                    "STATUS_GH_BIN": str(bin_dir / "gh"),
                    "STATUS_GITHUB_NOTIFICATIONS_ONLY": "1",
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
            self.assertIn("Unread GitHub notifications: 3", result.stdout)
            self.assertIn("CheckSuite summary: active=1 superseded=2 recovered=0 unknown=0", result.stdout)
            self.assertEqual(result.stdout.count("| superseded"), 2)
            self.assertEqual(result.stdout.count("| active"), 1)

    def test_setapp_status_reports_incomplete_without_launching_a_browser(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_home = root / "home"
            fake_home.mkdir(parents=True)
            token_path = fake_home / ".codex" / "secrets" / "github_token"
            token_path.parent.mkdir(parents=True)
            token_path.write_text("fake-status-token\n", encoding="utf-8")
            token_path.chmod(0o600)

            for repo in (
                fake_home / "SaneApps" / "websites" / "sanecite-saas",
                fake_home / "SaneApps" / "apps" / "SaneClip",
                fake_home / "SaneApps" / "infra" / "SaneProcess",
            ):
                init_git_repo(repo)

            repo_root = root / "scripts"
            automation_dir = repo_root / "automation"
            automation_dir.mkdir(parents=True)
            script_copy = automation_dir / "sane-status-crossref.sh"
            copy_status_runner(script_copy)

            safari_log = root / "mini-safari.log"
            mini_dir = repo_root / "mini"
            mini_dir.mkdir()
            write_executable(
                mini_dir / "mini-safari.sh",
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env bash
                    printf '%s\\n' "$*" >> {str(safari_log)!r}
                    touch "${{SETAPP_RETRY_READY}}"
                    printf 'https://developer.setapp.com\\n'
                    """
                ),
            )

            state_file = root / "setapp-ready"
            sane_master = repo_root / "SaneMaster.rb"
            sane_master.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env ruby
                    command = ARGV.shift
                    case command
                    when "sales"
                      puts "stub sales ok"
                    when "listing_actions"
                      json_out = ARGV[ARGV.index("--json-out") + 1]
                      File.write(json_out, '{"current_actions":[]}')
                    when "hosted_file_actions"
                      puts '{"current_actions":[]}'
                    when "setapp_status"
                      if File.exist?(ENV.fetch("SETAPP_RETRY_READY"))
                        puts "Setapp review status"
                        puts "- SaneBar: Released (status 10, version 2171 / 2.1.71, version_id 46885)"
                        puts "No Setapp action required."
                      else
                        puts "Setapp review status"
                        puts "Status unavailable: open and sign in to developer.setapp.com in Brave on the Mini or set SETAPP_PORTAL_TOKEN"
                        puts "   Treat Setapp status as incomplete until this is checked."
                      end
                    else
                      exit 0
                    end
                    """
                ),
                encoding="utf-8",
            )
            sane_master.chmod(sane_master.stat().st_mode | stat.S_IXUSR)

            inbox_dir = fake_home / "SaneApps" / "infra" / "scripts"
            inbox_dir.mkdir(parents=True)
            write_executable(inbox_dir / "check-inbox.sh", "#!/usr/bin/env bash\nprintf 'stub inbox ok\\n'\n")

            bin_dir = root / "bin"
            bin_dir.mkdir()
            write_executable(bin_dir / "gh", "#!/usr/bin/env bash\nprintf '[]\\n'\n")

            env = os.environ.copy()
            env["HOME"] = str(fake_home)
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["STATUS_TEST_MODE"] = "1"
            env["STATUS_GH_BIN"] = str(bin_dir / "gh")
            env["SETAPP_RETRY_READY"] = str(state_file)
            env.pop("GH_TOKEN", None)
            env.pop("GITHUB_TOKEN", None)

            result = subprocess.run(
                ["/bin/bash", str(script_copy), "--full"],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(
                result.returncode,
                3,
                msg=f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )
            self.assertNotIn("retrying with the current Mini Safari tab", result.stdout)
            self.assertIn("Status unavailable: open and sign in to developer.setapp.com in Brave on the Mini", result.stdout)
            self.assertIn("Treat Setapp status as incomplete", result.stdout)
            self.assertIn("Lane unavailable: Setapp distribution channel (exit 1)", result.stdout)
            self.assertIn("FULL STATUS: INCOMPLETE", result.stdout)
            self.assertFalse(safari_log.exists(), "status must not launch browser automation")


if __name__ == "__main__":
    unittest.main()
