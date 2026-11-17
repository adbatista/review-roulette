import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vite-plus/test";
import { semaphoreHost } from "../src/hosts/semaphore";
const directory = mkdtempSync(join(tmpdir(), "roulette-"));
const pullBuild = {
  SEMAPHORE: "true",
  SEMAPHORE_GIT_PROVIDER: "github",
  SEMAPHORE_GIT_REPO_SLUG: "acme/mono",
  SEMAPHORE_GIT_PR_SLUG: "fork/mono",
  SEMAPHORE_GIT_PR_NUMBER: "42",
};
afterEach(() => {
  vi.restoreAllMocks();
  process.exitCode = undefined;
});
it("targets the project repository's pull request, not the fork", () => {
  expect(semaphoreHost(pullBuild).event()).toEqual({
    target: { owner: "acme", repo: "mono", number: 42, kind: "pull" },
  });
});
it("lets explicit variables override the build and point at an issue", () => {
  const env = {
    ...pullBuild,
    ROULETTE_REPOSITORY: "other/tasks",
    ROULETTE_NUMBER: " 7 ",
    ROULETTE_KIND: "issue",
  };
  expect(semaphoreHost(env).event()).toEqual({
    target: { owner: "other", repo: "tasks", number: 7, kind: "issue" },
  });
});
it("skips builds that are not for a pull request", () => {
  expect(semaphoreHost({ SEMAPHORE_GIT_REPO_SLUG: "acme/mono" }).event()).toEqual({
    skip: expect.stringMatching(/not a pull-request build/),
  });
});
it("leaves malformed targets for validation instead of guessing", () => {
  expect(semaphoreHost({ ROULETTE_REPOSITORY: "a/b/c", ROULETTE_NUMBER: "x1" }).event()).toEqual({
    target: { owner: "a", repo: undefined, number: undefined, kind: "pull" },
  });
  expect(semaphoreHost({ ROULETTE_NUMBER: "3" }).event().target).toMatchObject({
    owner: "",
    repo: undefined,
  });
});
it("rejects other git providers and unknown kinds", () => {
  expect(() =>
    semaphoreHost({ ...pullBuild, SEMAPHORE_GIT_PROVIDER: "bitbucket" }).event(),
  ).toThrow(/GitHub/);
  expect(() => semaphoreHost({ ...pullBuild, ROULETTE_KIND: "epic" }).event()).toThrow(
    /ROULETTE_KIND/,
  );
});
it("reads inputs from variables, then the config file, with a token fallback", () => {
  const config = join(directory, "config.json");
  writeFileSync(
    config,
    JSON.stringify({
      reviewers: ["alice", "bob"],
      "assign-reviewer": true,
      "status-weights": { "In progress": 3, Done: 0 },
      "status-field": "Stage",
      command: null,
    }),
  );
  const host = semaphoreHost({
    ROULETTE_CONFIG: config,
    ROULETTE_STATUS_FIELD: "Column",
    ROULETTE_ISSUE_REPOSITORIES: "acme/tasks",
    GITHUB_TOKEN: "fallback",
  });
  expect(host.input("reviewers")).toBe("alice\nbob");
  expect(host.input("assign-reviewer")).toBe("true");
  expect(host.input("status-weights")).toBe("In progress: 3\nDone: 0");
  expect(host.input("status-field")).toBe("Column");
  expect(host.input("issue-repositories")).toBe("acme/tasks");
  expect(host.input("command")).toBe("");
  expect(host.input("projects")).toBe("");
  expect(host.input("token")).toBe("fallback");
  expect(semaphoreHost({ ROULETTE_TOKEN: "own", GITHUB_TOKEN: "fallback" }).input("token")).toBe(
    "own",
  );
  expect(semaphoreHost({}).input("token")).toBe("");
});
it.each(["[]", "null", '"text"'])("rejects a config file holding %s", (content) => {
  const config = join(directory, "bad.json");
  writeFileSync(config, content);
  expect(() => semaphoreHost({ ROULETTE_CONFIG: config }).input("reviewers")).toThrow(
    /JSON object/,
  );
});
it("fails on an unreadable or invalid config file", () => {
  expect(() =>
    semaphoreHost({ ROULETTE_CONFIG: join(directory, "missing.json") }).input("reviewers"),
  ).toThrow();
});
it("logs outputs as shell variables and appends them to the output file", () => {
  const log = vi.spyOn(console, "log").mockImplementation(() => {});
  const file = join(directory, "outputs.env");
  const host = semaphoreHost({ ROULETTE_OUTPUT_FILE: file });
  host.output("reviewer", "alice");
  host.output("review-count", 2);
  host.info("hello");
  host.secret("ignored");
  expect(readFileSync(file, "utf8")).toBe("ROULETTE_REVIEWER=alice\nROULETTE_REVIEW_COUNT=2\n");
  expect(log.mock.calls.map(([line]) => line)).toEqual([
    "ROULETTE_REVIEWER=alice",
    "ROULETTE_REVIEW_COUNT=2",
    "hello",
  ]);
  semaphoreHost({}).output("assigned", false);
  expect(log).toHaveBeenLastCalledWith("ROULETTE_ASSIGNED=false");
});
it("reports failure on stderr with a failing exit code", () => {
  const error = vi.spyOn(console, "error").mockImplementation(() => {});
  semaphoreHost({}).fail("boom");
  expect(error).toHaveBeenCalledWith("Review roulette failed: boom");
  expect(process.exitCode).toBe(1);
});
