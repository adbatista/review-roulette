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
  create: vi.fn(function () {}),
  run: vi.fn(),
}));
vi.mock("@actions/core", () => ({
  getInput: (key: string) => doubles.inputs[key],
  setOutput: doubles.setOutput,
  setFailed: doubles.setFailed,
  setSecret: doubles.setSecret,
}));
vi.mock("@actions/github", () => ({ context: doubles.context }));
vi.mock("../src/github", () => ({ GitHubClient: doubles.create }));
vi.mock("../src/run", () => ({ run: doubles.run }));
import { main } from "../src/main";
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
    });
    expect(doubles.setOutput.mock.calls).toEqual([
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
