import { expect, it } from "vite-plus/test";
import type { AssignmentStatus, ReviewerPick } from "../src/model";
import { renderComment, readSuggestions, findManagedComment } from "../src/comment";
const pick = (
  reviewer: string,
  reviewCount: number,
  status: AssignmentStatus = "suggested",
  category = "All",
): ReviewerPick => ({ reviewer, reviewCount, workload: reviewCount, status, category });
it.each(["suggested", "requested", "already-requested"] as const)(
  "renders one selection with truthful %s status",
  (status) => {
    const body = renderComment([pick("Alice", 2, status)]);
    expect(body).toContain("### Review roulette");
    expect(body).toContain("| Category | Suggested reviewer |");
    expect(body).toContain(
      "| All | [@Alice](https://github.com/Alice) — 2 pending review requests |",
    );
    expect(body).toContain(
      {
        suggested: "Suggestion only",
        requested: "Review requested",
        "already-requested": "Review already requested",
      }[status],
    );
    expect(readSuggestions(body)).toEqual(new Map([["all", "Alice"]]));
  },
);
it("renders singular workload", () => {
  expect(renderComment([pick("Bob", 1)])).toContain("1 pending review request |");
});
it("adds the assigned issue load when issues are counted", () => {
  expect(renderComment([{ ...pick("Bob", 1), issueLoad: 4, workload: 5 }])).toContain(
    "— 1 pending review request, assigned issue load 4 |",
  );
});
it.each([
  "hello",
  "<!-- review-roulette:v2:Alice -->",
  "<!-- review-roulette:v2:=Alice -->",
  "<!-- review-roulette:v2:All=bad login -->",
  "<!-- review-roulette:v2:%E0%A4%A=Alice -->",
  "<!-- review-roulette:v2:All=Alice&api -->",
  "<!-- review-roulette:v1:bad login -->",
  "<!-- review-roulette:v1:-bad -->",
  "<!-- review-roulette:v1:Alice -->\n<!-- review-roulette:v1:Bob -->",
])("ignores invalid markers", (body) => {
  expect(readSuggestions(body)).toBeUndefined();
});
it("renders one row per category and round-trips names through the marker", () => {
  const body = renderComment([
    pick("Alice", 2, "requested", "web & ui"),
    pick("Bob", 0, "already-requested", "API"),
  ]);
  expect(body).toContain(
    "| web & ui | [@Alice](https://github.com/Alice) — 2 pending review requests | Review requested |",
  );
  expect(body).toContain(
    "| API | [@Bob](https://github.com/Bob) — 0 pending review requests | Review already requested |",
  );
  expect(readSuggestions(body)).toEqual(
    new Map([
      ["web & ui", "Alice"],
      ["api", "Bob"],
    ]),
  );
});
it.each([
  ["suggested", "Suggestion only"],
  ["requested", "Assigned"],
  ["already-requested", "Already assigned"],
] as const)("words an issue comment as an assignment for %s", (status, text) => {
  const body = renderComment([pick("Alice", 1, status)], "issue");
  expect(body).toContain("| Category | Suggested assignee | Status |");
  expect(body).toContain(`| ${text} |`);
});
it("still reads the single-reviewer marker written by earlier versions", () => {
  expect(readSuggestions("text\n<!-- review-roulette:v1:Alice -->")).toEqual(
    new Map([["all", "Alice"]]),
  );
});
it("ignores copied markers and picks earliest owned valid comment", () => {
  const body = renderComment([pick("Alice", 0)]);
  const comments = [
    { id: 1, body, authorLogin: "mallory", authorType: "User" },
    { id: 5, body, authorLogin: "roulette[bot]", authorType: "Bot", appId: 10 },
    { id: 3, body, authorLogin: "roulette[bot]", authorType: "Bot", appId: 10 },
    { id: 2, body, authorLogin: "roulette[bot]", authorType: "Bot", appId: 11 },
  ];
  expect(findManagedComment(comments, { login: "roulette[bot]", appId: 10 })?.id).toBe(3);
});
it("supports authenticated user comments and rejects unmarked ones", () => {
  const comments = [
    { id: 1, body: "unmarked", authorLogin: "Alice", authorType: "User" },
    {
      id: 2,
      body: renderComment([pick("Bob", 0)]),
      authorLogin: "alice",
      authorType: "User",
    },
  ];
  expect(findManagedComment(comments, { login: "Alice" })?.id).toBe(2);
  expect(findManagedComment(comments, { login: "other" })).toBeUndefined();
});
