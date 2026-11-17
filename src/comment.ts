import { loginPattern } from "./inputs";
import type { CommentIdentity, ManagedComment, ReviewerPick, Suggestion } from "./model";

const statusCopy = {
  suggested: "Suggestion only",
  requested: "Review requested",
  "already-requested": "Review already requested",
};

function describeWorkload(suggestion: Suggestion): string {
  const reviews = `${suggestion.reviewCount} pending review request${suggestion.reviewCount === 1 ? "" : "s"}`;
  return suggestion.issueLoad === undefined
    ? reviews
    : `${reviews}, assigned issue load ${suggestion.issueLoad}`;
}

export function renderComment(picks: ReviewerPick[]): string {
  const rows = picks.map(
    (pick) =>
      `| ${pick.category} | [@${pick.reviewer}](https://github.com/${pick.reviewer}) — ${describeWorkload(pick)} | ${statusCopy[pick.status]} |`,
  );
  const marker = picks
    .map((pick) => `${encodeURIComponent(pick.category)}=${pick.reviewer}`)
    .join("&");
  return `### Review roulette

| Category | Suggested reviewer | Status |
| --- | --- | --- |
${rows.join("\n")}

<!-- review-roulette:v2:${marker} -->`;
}

export function readSuggestions(body: string): Map<string, string> | undefined {
  const matches = [...body.matchAll(/<!-- review-roulette:v([12]):([^\n]*?) -->/g)];
  if (matches.length !== 1) return undefined;
  const [, version, payload] = matches[0];
  const pairs = version === "1" ? [`All=${payload}`] : payload.split("&");
  const suggestions = new Map<string, string>();
  for (const pair of pairs) {
    const split = pair.indexOf("=");
    const login = pair.slice(split + 1);
    if (split < 1 || !loginPattern.test(login)) return undefined;
    try {
      suggestions.set(decodeURIComponent(pair.slice(0, split)).toLowerCase(), login);
    } catch {
      return undefined;
    }
  }
  return suggestions;
}

export function findManagedComment(
  comments: ManagedComment[],
  identity: CommentIdentity,
): ManagedComment | undefined {
  return comments
    .filter(
      (comment) =>
        comment.authorLogin.toLowerCase() === identity.login.toLowerCase() &&
        (comment.authorType === "User" || comment.authorType === "Bot") &&
        (identity.appId === undefined ||
          (comment.authorType === "Bot" && comment.appId === identity.appId)) &&
        readSuggestions(comment.body) !== undefined,
    )
    .sort((a, b) => a.id - b.id)[0];
}
