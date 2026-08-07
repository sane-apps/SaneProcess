#!/usr/bin/env node
const assert = require("assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  assertIsolatedProfile,
  braveLaunchOptions,
  prepareIsolatedProfile,
} = require("./sane_brave_playwright.cjs");

const options = braveLaunchOptions({
  args: ["--no-sandbox", "--load-extension=/tmp/example"],
  ignoreDefaultArgs: ["--disable-extensions"],
});
assert(!options.args.includes("--no-sandbox"));
assert(options.ignoreDefaultArgs.includes("--no-sandbox"));
assert(options.args.includes("--disable-crash-reporter"));
assert(options.args.includes("--disable-session-crashed-bubble"));
assert(options.args.includes("--noerrdialogs"));

assert.throws(
  () => assertIsolatedProfile(path.join(os.homedir(), "Library/Application Support/BraveSoftware/Brave-Browser")),
  /isolated \/tmp\/brave-/
);

const profile = `/tmp/brave-sane-policy-test-${process.pid}`;
prepareIsolatedProfile(profile);
const preferences = JSON.parse(
  fs.readFileSync(path.join(profile, "Default", "Preferences"), "utf8")
);
assert.equal(preferences.profile.exit_type, "Normal");
assert.equal(preferences.profile.exited_cleanly, true);
assert.equal(preferences.brave.dont_ask_for_crash_reporting, true);
fs.rmSync(profile, { recursive: true, force: true });

console.log("Sane Brave Playwright policy tests passed");
