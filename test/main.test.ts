import { beforeEach, expect, it, vi } from "vite-plus/test";
const doubles = vi.hoisted(() => ({
  inputs: {
    token: "secret",
    reviewers: "Alice",
    organizations: "",
    "assign-reviewer": "false",
  } as Record<string, string>,
  context: {
    eventName: "pull_request",
    payload: {
      number: 7,
      pull_request: {
        number: 7,
        base: { repo: { name: "project", owner: { login: "base-owner" } } },
        head: { repo: { name: "fork" } },
      },
    },
  } as { eventName: string; payload: Record<string, unknown> },
  setOutput: vi.fn(),
  setFailed: vi.fn(),
  setSecret: vi.fn(),
  info: vi.fn(),
  create: vi.fn(function () {}),
  run: vi.fn(),
}));
vi.mock("@actions/core", () => ({
  getInput: (key: string) => doubles.inputs[key],
  setOutput: doubles.setOutput,
  setFailed: doubles.setFailed,
  setSecret: doubles.setSecret,
  info: doubles.info,
}));
vi.mock("@actions/github", () => ({ context: doubles.context }));
vi.mock("../src/github", () => ({ GitHubClient: doubles.create }));
vi.mock("../src/run", () => ({ run: doubles.run }));
import { main as runMain } from "../src/main";
import { actionsHost } from "../src/hosts/actions";
import type { Host } from "../src/host";
const main = () => runMain(actionsHost());
beforeEach(() => {
  vi.clearAllMocks();
  doubles.run.mockResolvedValue({
    picks: [{ reviewer: "Alice", reviewCount: 3, workload: 3 }],
    assigned: false,
  });
});
it.each(["pull_request", "pull_request_target"])(
  "uses base repo and publishes outputs for %s",
  async (event) => {
    doubles.context.eventName = event;
    await main();
    expect(doubles.run.mock.calls.at(-1)?.[1]).toEqual({
      owner: "base-owner",
      repo: "project",
      pullNumber: 7,
      kind: "pull",
    });
    expect(doubles.setOutput.mock.calls).toEqual([
      ["skipped", false],
      ["reviewer", "Alice"],
      ["reviewers", "Alice"],
      ["review-count", 3],
      ["issue-load", ""],
      ["workload", 3],
      ["assigned", false],
    ]);
    expect(doubles.setSecret).toHaveBeenCalledWith("secret");
  },
);
it("passes issue workload inputs through and publishes the issue load", async () => {
  doubles.inputs["issue-repositories"] = "acme/tasks";
  doubles.inputs["status-weights"] = "Done: 0";
  doubles.run.mockResolvedValue({
    picks: [{ reviewer: "Alice", reviewCount: 3, issueLoad: 2, workload: 5 }],
    assigned: false,
  });
  await main();
  delete doubles.inputs["issue-repositories"];
  delete doubles.inputs["status-weights"];
  expect(doubles.run.mock.calls.at(-1)?.[0]).toMatchObject({
    issueRepositories: ["acme/tasks"],
    statusField: "Status",
    statusWeights: new Map([["done", 0]]),
  });
  expect(doubles.setOutput).toHaveBeenCalledWith("issue-load", 2);
  expect(doubles.setOutput).toHaveBeenCalledWith("workload", 5);
});
it("passes project inputs through and lists every unique pick", async () => {
  doubles.inputs.projects = "web | packages/web/** | alice";
  doubles.inputs.codeowners = "true";
  doubles.run.mockResolvedValue({
    picks: [
      { reviewer: "Alice", reviewCount: 1, workload: 1 },
      { reviewer: "Bob", reviewCount: 0, workload: 0 },
      { reviewer: "Alice", reviewCount: 1, workload: 1 },
    ],
    assigned: true,
  });
  await main();
  delete doubles.inputs.projects;
  delete doubles.inputs.codeowners;
  expect(doubles.run.mock.calls.at(-1)?.[0]).toMatchObject({
    projects: [{ name: "web", patterns: [{ glob: "packages/web/**" }], owners: ["alice"] }],
    codeowners: true,
  });
  expect(doubles.setOutput).toHaveBeenCalledWith("reviewer", "Alice");
  expect(doubles.setOutput).toHaveBeenCalledWith("reviewers", "Alice,Bob");
  expect(doubles.setOutput).toHaveBeenCalledWith("assigned", true);
});
it("fails before API work without PR context", async () => {
  const payload = doubles.context.payload;
  doubles.context.payload = {};
  await main();
  doubles.context.payload = payload;
  expect(doubles.create).not.toHaveBeenCalled();
  expect(doubles.setFailed.mock.calls[0][0]).toMatch(/pull.request/i);
});
it("sanitizes failure messages and never publishes partial outputs", async () => {
  doubles.run.mockRejectedValue(new Error("request failed with secret"));
  await main();
  expect(doubles.setOutput).not.toHaveBeenCalled();
  expect(doubles.setFailed).toHaveBeenCalledWith("request failed with ***");
});
it("reports a missing token before constructing the API", async () => {
  doubles.inputs.token = "";
  await main();
  doubles.inputs.token = "secret";
  expect(doubles.create).not.toHaveBeenCalled();
  expect(doubles.setFailed).toHaveBeenCalledWith("token is required");
});
it("handles non-Error failures without serializing arbitrary objects", async () => {
  doubles.run.mockRejectedValue({ token: "secret" });
  await main();
  expect(doubles.setFailed).toHaveBeenCalledWith("Review roulette failed");
});
function commentEvent(
  body: string,
  overrides: { association?: string; action?: string; pull?: boolean } = {},
) {
  return {
    action: overrides.action ?? "created",
    repository: { name: "project", owner: { login: "base-owner" } },
    issue: { number: 12, ...(overrides.pull ? { pull_request: {} } : {}) },
    comment: { body, author_association: overrides.association ?? "MEMBER" },
  };
}
async function withEvent(event: string, payload: Record<string, unknown>, command = "/roulette") {
  const previous = { ...doubles.context };
  doubles.context.eventName = event;
  doubles.context.payload = payload;
  doubles.inputs.command = command;
  await main();
  Object.assign(doubles.context, previous);
  delete doubles.inputs.command;
}
it.each([
  [true, "pull"],
  [false, "issue"],
])("runs a collaborator's command comment (pull request: %s)", async (pull, kind) => {
  await withEvent("issue_comment", commentEvent("please\r\n  /roulette  \nthanks", { pull }));
  expect(doubles.run.mock.calls.at(-1)?.[1]).toEqual({
    owner: "base-owner",
    repo: "project",
    pullNumber: 12,
    kind,
  });
  expect(doubles.setOutput).toHaveBeenCalledWith("skipped", false);
});
it.each([
  ["a different comment", commentEvent("nice work /roulette")],
  ["an outside commenter", commentEvent("/roulette", { association: "CONTRIBUTOR" })],
  ["an edited comment", commentEvent("/roulette", { action: "edited" })],
])("skips %s without touching the API", async (_name, payload) => {
  await withEvent("issue_comment", payload);
  expect(doubles.create).not.toHaveBeenCalled();
  expect(doubles.setOutput.mock.calls).toEqual([["skipped", true]]);
  expect(doubles.setFailed).not.toHaveBeenCalled();
});
it("refuses comment events without a command to avoid retriggering on its own comment", async () => {
  await withEvent("issue_comment", commentEvent("/roulette"), "");
  expect(doubles.create).not.toHaveBeenCalled();
  expect(doubles.setFailed).toHaveBeenCalledWith("command is required for issue_comment events");
});
it("ignores the command on other events and runs on a labeled issue event", async () => {
  await withEvent("issues", {
    action: "labeled",
    repository: { name: "project", owner: { login: "base-owner" } },
    issue: { number: 3 },
  });
  expect(doubles.run.mock.calls.at(-1)?.[1]).toMatchObject({ pullNumber: 3, kind: "issue" });
});
it("reports a skip when the run makes no pick", async () => {
  doubles.run.mockResolvedValue({ picks: [], assigned: false });
  await main();
  expect(doubles.setOutput.mock.calls).toEqual([["skipped", true]]);
  expect(doubles.info.mock.calls[0][0]).toMatch(/required label/);
});
function fakeHost(event: ReturnType<Host["event"]>, inputs: Record<string, string> = {}) {
  const calls: unknown[][] = [];
  const record =
    (kind: string) =>
    (...values: unknown[]) => {
      calls.push([kind, ...values]);
    };
  const host: Host = {
    input: (name) => ({ token: "secret", reviewers: "Alice", ...inputs })[name] ?? "",
    event: () => event,
    secret: record("secret"),
    info: record("info"),
    output: record("output"),
    fail: record("fail"),
  };
  return { host, calls };
}
it("runs for any host that supplies a target", async () => {
  const { host, calls } = fakeHost({
    target: { owner: "acme", repo: "mono", number: 5, kind: "pull" },
  });
  await runMain(host);
  expect(doubles.run.mock.calls.at(-1)?.[1]).toEqual({
    owner: "acme",
    repo: "mono",
    pullNumber: 5,
    kind: "pull",
  });
  expect(calls[0]).toEqual(["secret", "secret"]);
  expect(calls).toContainEqual(["output", "reviewer", "Alice"]);
});
it("skips when the host reports nothing to act on", async () => {
  const { host, calls } = fakeHost({ skip: "not a pull-request build" });
  await runMain(host);
  expect(doubles.create).not.toHaveBeenCalled();
  expect(calls.slice(1)).toEqual([
    ["info", "Review roulette skipped: not a pull-request build"],
    ["output", "skipped", true],
  ]);
});
it.each([
  { owner: "acme", repo: "mono", number: undefined, kind: "pull" as const },
  { owner: "acme", repo: undefined, number: 5, kind: "pull" as const },
  { owner: "bad owner", repo: "mono", number: 5, kind: "pull" as const },
  { owner: "acme", repo: "mono", number: 0, kind: "pull" as const },
])("fails through the host for an invalid target %j", async (target) => {
  const { host, calls } = fakeHost({ target });
  await runMain(host);
  expect(calls.at(-1)?.[0]).toBe("fail");
  expect(doubles.create).not.toHaveBeenCalled();
});
