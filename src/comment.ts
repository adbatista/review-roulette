import { loginPattern } from "./inputs";
import type { AssignmentStatus, CommentIdentity, ManagedComment, Suggestion } from "./model";

function describeWorkload(suggestion: Suggestion): string {
  const reviews = `${suggestion.reviewCount} pending review request${suggestion.reviewCount === 1 ? "" : "s"}`;
  return suggestion.issueLoad === undefined
    ? reviews
    : `${reviews}, assigned issue load ${suggestion.issueLoad}`;
}

export function renderComment(suggestion: Suggestion, status: AssignmentStatus): string {
  const copy = {
    suggested: "Suggestion only; no review request was created.",
    requested: "Review requested.",
    "already-requested": "Review already requested; no additional request was created.",
  };
  return `### Review roulette

| Category | Suggested reviewer |
| --- | --- |
| All | [@${suggestion.reviewer}](https://github.com/${suggestion.reviewer}) — ${describeWorkload(suggestion)} |

${copy[status]}

<!-- review-roulette:v1:${suggestion.reviewer} -->`;
}

export function readSuggestion(body: string): string | undefined {
  const matches = [...body.matchAll(/<!-- review-roulette:v1:([^\n]*?) -->/g)];
  if (matches.length !== 1) return undefined;
  const login = matches[0][1];
  return loginPattern.test(login) ? login : undefined;
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
        readSuggestion(comment.body) !== undefined,
    )
    .sort((a, b) => a.id - b.id)[0];
}
