import type { Options } from "./model";

export const repositoryPattern = /^[\w.-]+$/;
export const loginPattern = /^[a-z\d](?:[a-z\d]|-(?=[a-z\d])){0,38}$/i;

function parseList(value: string, reviewer: boolean): string[] {
  const unique = new Map<string, string>();
  for (const entry of value.split(/[,\n]/)) {
    const login = entry.trim().replace(reviewer ? /^@/ : /$^/, "");
    if (!login) continue;
    if (!loginPattern.test(login)) throw new Error("Invalid GitHub login in input list");
    unique.set(login.toLowerCase(), unique.get(login.toLowerCase()) ?? login);
  }
  return [...unique.values()];
}

function parseScopes(value: string): string[] {
  const unique = new Map<string, string>();
  for (const entry of value.split(/[,\n]/)) {
    const scope = entry.trim();
    if (!scope) continue;
    const [owner, repo, ...rest] = scope.split("/");
    if (
      rest.length ||
      !loginPattern.test(owner) ||
      (repo !== undefined && !repositoryPattern.test(repo))
    )
      throw new Error("issue-repositories entries must be an owner or owner/repo");
    unique.set(scope.toLowerCase(), unique.get(scope.toLowerCase()) ?? scope);
  }
  return [...unique.values()];
}

function parseWeights(value: string): Map<string, number> {
  const weights = new Map<string, number>();
  for (const line of value.split("\n")) {
    if (!line.trim()) continue;
    const match = /^(.+):\s*(\d+)\s*$/.exec(line);
    const name = match?.[1].trim().toLowerCase();
    const weight = Number(match?.[2]);
    if (!name || !Number.isSafeInteger(weight))
      throw new Error("status-weights lines must look like `In progress: 2`");
    weights.set(name, weight);
  }
  return weights;
}

export function parseOptions(raw: Record<string, string>): Options {
  const token = (raw.token ?? "").trim();
  if (!token) throw new Error("token is required");
  const reviewers = parseList(raw.reviewers ?? "", true);
  const assignment = raw["assign-reviewer"]?.trim() || "false";
  if (assignment !== "true" && assignment !== "false")
    throw new Error("assign-reviewer must be true or false");
  return {
    token,
    reviewers,
    organizations: parseList(raw.organizations ?? "", false),
    assignReviewer: assignment === "true",
    issueRepositories: parseScopes(raw["issue-repositories"] ?? ""),
    statusField: raw["status-field"]?.trim() || "Status",
    statusWeights: parseWeights(raw["status-weights"] ?? ""),
  };
}
