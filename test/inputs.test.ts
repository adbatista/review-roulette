import { describe, expect, it } from "vite-plus/test";
import { parseOptions } from "../src/inputs";
describe("parseOptions", () => {
  it("normalizes lists and defaults", () => {
    const result = parseOptions({
      token: "secret",
      reviewers: "@Alice, alice\nBob",
      organizations: "Acme,acme\nOther",
    });
    expect(result).toEqual({
      token: "secret",
      reviewers: ["Alice", "Bob"],
      organizations: ["Acme", "Other"],
      assignReviewer: false,
      issueRepositories: [],
      statusField: "Status",
      statusWeights: new Map(),
      projects: [],
      codeowners: false,
    });
  });
  it("accepts empty organization scope and explicit assignment", () => {
    const result = parseOptions({
      token: "secret",
      reviewers: "a",
      organizations: " , \n",
      "assign-reviewer": "true",
    });
    expect(result.organizations).toEqual([]);
    expect(result.assignReviewer).toBe(true);
  });
  it("parses issue workload scopes and status weights", () => {
    const result = parseOptions({
      token: "secret",
      "issue-repositories": "acme/tasks, Acme/Tasks\nother",
      "status-field": " Stage ",
      "status-weights": "In progress: 3\n\nReview: now: 2\n*: 0",
    });
    expect(result.issueRepositories).toEqual(["acme/tasks", "other"]);
    expect(result.statusField).toBe("Stage");
    expect([...result.statusWeights]).toEqual([
      ["in progress", 3],
      ["review: now", 2],
      ["*", 0],
    ]);
  });
  it("parses projects with folder, repository and label-only patterns", () => {
    const result = parseOptions({
      token: "secret",
      projects:
        "web | packages/web/**, packages/ui | @Alice, bob\n\ndocs | acme/docs:, Acme/site:guides/** | carol\nsecurity | | dave",
      codeowners: "true",
    });
    expect(result.codeowners).toBe(true);
    expect(result.projects).toEqual([
      {
        name: "web",
        patterns: [{ glob: "packages/web/**" }, { glob: "packages/ui" }],
        owners: ["Alice", "bob"],
      },
      {
        name: "docs",
        patterns: [
          { repository: "acme/docs", glob: "**" },
          { repository: "Acme/site", glob: "guides/**" },
        ],
        owners: ["carol"],
      },
      { name: "security", patterns: [], owners: ["dave"] },
    ]);
  });
  it.each([undefined, "", " , \n"])(
    "uses discovery for missing or empty reviewers %j",
    (reviewers) => {
      const result = parseOptions({
        token: "secret",
        ...(reviewers === undefined ? {} : { reviewers }),
      });
      expect(result.reviewers).toEqual([]);
    },
  );
  it.each<Record<string, string>>([
    {},
    { token: "", reviewers: "a" },
    { token: "s", reviewers: "a--b" },
    { token: "s", reviewers: "-alice" },
    { token: "s", reviewers: "a", organizations: "bad org" },
    { token: "s", reviewers: "a", "assign-reviewer": "yes" },
    { token: "s", "issue-repositories": "acme/tasks/extra" },
    { token: "s", "issue-repositories": "acme/bad repo" },
    { token: "s", "status-weights": "Todo" },
    { token: "s", "status-weights": "Todo: -1" },
    { token: "s", "status-weights": "Todo: 1.5" },
    { token: "s", "status-weights": ": 1" },
    { token: "s", projects: "web | src/**" },
    { token: "s", projects: "web | src/** | alice | extra" },
    { token: "s", projects: " | src/** | alice" },
    { token: "s", projects: "web | src/** | " },
    { token: "s", projects: "web | src/** | bad login" },
    { token: "s", projects: "web | a | alice\nWEB | b | bob" },
    { token: "s", projects: "all | a | alice" },
    { token: "s", projects: "Code Owners | a | alice" },
    { token: "s", projects: "web | bad owner/repo:src | alice" },
    { token: "s", codeowners: "yes" },
  ])("rejects invalid inputs %j", (raw) => {
    expect(() => parseOptions(raw)).toThrow();
  });
});
