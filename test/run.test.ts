import { expect, it } from "vite-plus/test";
import { run } from "../src/run";
import { renderComment } from "../src/comment";
import type { GitHubApi, Options, ManagedComment, ReviewerPick } from "../src/model";
const options: Options = {
  token: "fake",
  reviewers: ["Author", "Alice", "Bob"],
  organizations: [],
  assignReviewer: false,
  issueRepositories: [],
  statusField: "Status",
  statusWeights: new Map(),
  projects: [],
  codeowners: false,
};
const pick = (reviewer: string, reviewCount: number, category = "All"): ReviewerPick => ({
  reviewer,
  reviewCount,
  workload: reviewCount,
  category,
  status: "suggested",
});
const target = { owner: "acme", repo: "project", pullNumber: 7 };
function fixture(
  settings: {
    requested?: string[];
    comments?: ManagedComment[];
    fail?: string;
    author?: string;
    counts?: Map<string, number>;
    suggested?: string[];
    issueLoads?: Map<string, number>;
    files?: string[];
    labels?: string[];
    codeowners?: string;
    teams?: Record<string, string[]>;
  } = {},
) {
  const events: string[] = [];
  const published: string[] = [];
  const counted: string[][] = [];
  const step = (name: string) => {
    events.push(name);
    if (settings.fail === name) throw new Error(name + " failed");
  };
  const api: GitHubApi = {
    async checkAccess() {
      step("access");
      return { login: "bot" };
    },
    async getPull() {
      step("pull");
      return {
        author: settings.author ?? "author",
        requestedReviewers: settings.requested ?? [],
        labels: settings.labels ?? [],
        baseRef: "main",
      };
    },
    async listFiles() {
      step("files");
      return settings.files ?? [];
    },
    async getCodeowners(_target, ref) {
      step("codeowners:" + ref);
      return settings.codeowners;
    },
    async getTeamMembers(organization, team) {
      step(`team:${organization}/${team}`);
      return settings.teams?.[team] ?? [];
    },
    async getSuggestedReviewers() {
      step("suggestions");
      return settings.suggested ?? ["Author", "Alice", "Bob"];
    },
    async getCounts(_target, _orgs, reviewers) {
      step("counts");
      counted.push(reviewers);
      return (
        settings.counts ??
        new Map([
          ["alice", 1],
          ["bob", 2],
        ])
      );
    },
    async getIssueLoads(scopes, _reviewers, field, weights) {
      step(`issues:${scopes.join("+")}:${field}:${weights.size}`);
      return settings.issueLoads ?? new Map();
    },
    async listComments() {
      step("comments");
      return settings.comments ?? [];
    },
    async requestReview(_target, reviewer) {
      step("request:" + reviewer);
    },
    async createComment(_target, body) {
      step("create");
      published.push(body);
    },
    async updateComment(_target, id, body) {
      step("update:" + id);
      published.push(body);
    },
  };
  return { api, events, published, counted };
}
it("checks access first, excludes author before counting and creates suggestion without requesting", async () => {
  const f = fixture();
  const result = await run(options, target, f.api, () => 0);
  expect(result).toEqual({ picks: [pick("Alice", 1)], assigned: false });
  expect(f.events.slice(0, 3)).toEqual(["access", "pull", "counts"]);
  expect(f.counted).toEqual([["Alice", "Bob"]]);
  expect(f.events).not.toContain("request:Alice");
  expect(f.published[0]).toContain("Suggestion only");
});
it("skips issue lookups unless issue repositories are configured", async () => {
  const f = fixture();
  await run(options, target, f.api, () => 0);
  expect(f.events.some((event) => event.startsWith("issues"))).toBe(false);
});
it("adds assigned issue load to review requests before selecting", async () => {
  const f = fixture({
    issueLoads: new Map([
      ["alice", 5],
      ["bob", 1],
    ]),
  });
  const result = await run(
    {
      ...options,
      issueRepositories: ["acme/tasks", "other"],
      statusField: "Stage",
      statusWeights: new Map([["done", 0]]),
    },
    target,
    f.api,
    () => 0,
  );
  expect(result).toEqual({
    picks: [{ ...pick("Bob", 2), issueLoad: 1, workload: 3 }],
    assigned: false,
  });
  expect(f.events).toContain("issues:acme/tasks+other:Stage:1");
  expect(f.published[0]).toContain("2 pending review requests, assigned issue load 1");
});
it("balances native suggestions when no reviewer list is supplied", async () => {
  const f = fixture();
  const result = await run({ ...options, reviewers: [] }, target, f.api, () => 0);
  expect(result).toEqual({ picks: [pick("Alice", 1)], assigned: false });
  expect(f.counted).toEqual([["Alice", "Bob"]]);
  expect(f.events.slice(0, 4)).toEqual(["access", "pull", "suggestions", "counts"]);
});
it("fails before counting when GitHub has no suggestions", async () => {
  const f = fixture({ suggested: [] });
  await expect(run({ ...options, reviewers: [] }, target, f.api)).rejects.toThrow(/eligible/);
  expect(f.events).toEqual(["access", "pull", "suggestions"]);
});
it("propagates suggestion discovery failures without publishing", async () => {
  const f = fixture({ fail: "suggestions" });
  await expect(run({ ...options, reviewers: [] }, target, f.api)).rejects.toThrow(
    "suggestions failed",
  );
  expect(f.published).toEqual([]);
});
it("requests before publishing success", async () => {
  const f = fixture();
  const result = await run({ ...options, assignReviewer: true }, target, f.api, () => 0);
  expect(result.assigned).toBe(true);
  expect(f.events.slice(-2)).toEqual(["request:Alice", "create"]);
  expect(f.published[0]).toContain("Review requested");
});
it("skips already requested selection even without prior managed comment", async () => {
  const f = fixture({ requested: ["ALICE"] });
  const result = await run({ ...options, assignReviewer: true }, target, f.api, () => 0);
  expect(result.assigned).toBe(false);
  expect(f.events).not.toContain("request:Alice");
  expect(f.published[0]).toContain("Review already requested");
});
it("retains and updates an owned assigned suggestion even above minimum", async () => {
  const f = fixture({
    requested: ["Bob"],
    comments: [
      {
        id: 42,
        authorLogin: "bot",
        authorType: "Bot",
        body: renderComment([{ ...pick("Bob", 0), status: "requested" }]),
      },
    ],
  });
  const result = await run({ ...options, assignReviewer: true }, target, f.api, () => 0);
  expect(result.picks[0].reviewer).toBe("Bob");
  expect(f.events.at(-1)).toBe("update:42");
  expect(f.events).not.toContain("request:Bob");
});
it("fails early when no eligible reviewers exist", async () => {
  const f = fixture();
  await expect(run({ ...options, reviewers: ["Author"] }, target, f.api)).rejects.toThrow(
    /eligible/,
  );
  expect(f.events).toEqual(["access", "pull"]);
});
it.each(["access", "pull", "counts", "comments", "request:Alice"])(
  "propagates %s failure without publishing",
  async (fail) => {
    const f = fixture({ fail });
    await expect(run({ ...options, assignReviewer: true }, target, f.api, () => 0)).rejects.toThrow(
      fail + " failed",
    );
    expect(f.published).toEqual([]);
  },
);
it("reports comment failure after assignment; rerun skips already requested reviewer", async () => {
  const first = fixture({ fail: "create" });
  await expect(
    run({ ...options, assignReviewer: true }, target, first.api, () => 0),
  ).rejects.toThrow("create failed");
  const next = fixture({ requested: ["Alice"] });
  await run({ ...options, assignReviewer: true }, target, next.api, () => 0);
  expect(first.events).toContain("request:Alice");
  expect(next.events).not.toContain("request:Alice");
  expect(next.published[0]).toContain("Review already requested");
});
const web = { name: "web", patterns: [{ glob: "packages/web" }], owners: ["Alice", "Carol"] };
const api = { name: "api", patterns: [{ glob: "services/api" }], owners: ["Bob", "author"] };
const everyone = new Map([
  ["alice", 1],
  ["bob", 2],
  ["carol", 0],
  ["dave", 3],
]);
it("picks one owner per matched project and counts every candidate once", async () => {
  const f = fixture({
    files: ["packages/web/a.ts", "services/api/main.go"],
    counts: everyone,
  });
  const result = await run({ ...options, projects: [web, api] }, target, f.api, () => 0);
  expect(result.picks).toEqual([pick("Carol", 0, "web"), pick("Bob", 2, "api")]);
  expect(f.counted).toEqual([["Alice", "Carol", "Bob"]]);
  expect(f.events).not.toContain("suggestions");
  expect(f.published[0]).toContain("| web | [@Carol]");
  expect(f.published[0]).toContain("| api | [@Bob]");
});
it("matches a project by label and requests each distinct pick once", async () => {
  const shared = { name: "shared", patterns: [], owners: ["Carol"] };
  const f = fixture({ files: ["packages/web/a.ts"], labels: ["Shared"], counts: everyone });
  const result = await run(
    { ...options, projects: [web, shared, api], assignReviewer: true },
    target,
    f.api,
    () => 0,
  );
  expect(result.picks.map((entry) => [entry.category, entry.reviewer, entry.status])).toEqual([
    ["web", "Carol", "requested"],
    ["shared", "Carol", "requested"],
  ]);
  expect(result.assigned).toBe(true);
  expect(f.events.filter((event) => event.startsWith("request:"))).toEqual(["request:Carol"]);
});
it("keeps each category's previous pick from the managed comment", async () => {
  const f = fixture({
    files: ["packages/web/a.ts", "services/api/main.go"],
    requested: ["Alice"],
    counts: everyone,
    comments: [
      {
        id: 9,
        authorLogin: "bot",
        authorType: "Bot",
        body: renderComment([pick("Alice", 0, "web"), pick("Carol", 0, "api")]),
      },
    ],
  });
  const result = await run({ ...options, projects: [web, api] }, target, f.api, () => 0);
  expect(result.picks.map((entry) => [entry.reviewer, entry.status])).toEqual([
    ["Alice", "already-requested"],
    ["Bob", "suggested"],
  ]);
  expect(f.events.at(-1)).toBe("update:9");
});
it("falls back to the reviewer list when no project matches or only the author owns it", async () => {
  const solo = { name: "solo", patterns: [{ glob: "**" }], owners: ["author"] };
  const f = fixture({ files: ["README.md"] });
  const result = await run({ ...options, projects: [web, solo] }, target, f.api, () => 0);
  expect(result.picks).toEqual([pick("Alice", 1)]);
});
it("adds a code owners category from the base ref and expands teams", async () => {
  const f = fixture({
    files: ["packages/web/a.ts", "docs/a.md"],
    codeowners: "* @dave\n/packages/ @acme/web-team @Author\n",
    teams: { "web-team": ["Carol", "alice", "CAROL"] },
    counts: everyone,
  });
  const result = await run(
    { ...options, projects: [web], codeowners: true },
    target,
    f.api,
    () => 0.99,
  );
  expect(result.picks).toEqual([pick("Carol", 0, "web"), pick("Carol", 0, "Code owners")]);
  expect(f.events).toContain("codeowners:main");
  expect(f.events).toContain("team:acme/web-team");
  expect(f.counted).toEqual([["Alice", "Carol", "dave"]]);
});
it("falls back when the repository has no CODEOWNERS file", async () => {
  const f = fixture({ files: ["a.ts"] });
  const result = await run({ ...options, codeowners: true }, target, f.api, () => 0);
  expect(result.picks).toEqual([pick("Alice", 1)]);
});
it.each(["files", "codeowners:main", "team:acme/web"])(
  "propagates %s failure without publishing",
  async (fail) => {
    const f = fixture({ fail, files: ["a.ts"], codeowners: "* @acme/web" });
    await expect(run({ ...options, codeowners: true }, target, f.api, () => 0)).rejects.toThrow(
      fail + " failed",
    );
    expect(f.published).toEqual([]);
  },
);
