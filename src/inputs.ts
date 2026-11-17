import type { Options, Project } from "./model";

export const repositoryPattern = /^[\w.-]+$/;
export const loginPattern = /^[a-z\d](?:[a-z\d]|-(?=[a-z\d])){0,38}$/i;

export const unique = (values: string[]) =>
  values.filter(
    (value, index) =>
      values.findIndex((other) => other.toLowerCase() === value.toLowerCase()) === index,
  );

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

function parseBoolean(raw: Record<string, string>, name: string): boolean {
  const value = raw[name]?.trim() || "false";
  if (value !== "true" && value !== "false") throw new Error(`${name} must be true or false`);
  return value === "true";
}

function parseProjects(value: string): Project[] {
  const projects = new Map<string, Project>();
  for (const line of value.split("\n")) {
    if (!line.trim()) continue;
    const [name, patterns, owners, ...rest] = line.split("|").map((part) => part.trim());
    const key = name.toLowerCase();
    if (!name || owners === undefined || rest.length)
      throw new Error("projects lines must look like `name | patterns | owners`");
    if (projects.has(key) || key === "all" || key === "code owners")
      throw new Error("projects names must be unique and not `All` or `Code owners`");
    const project: Project = {
      name,
      patterns: patterns
        .split(",")
        .map((pattern) => pattern.trim())
        .filter(Boolean)
        .map((pattern) => {
          const scoped = /^([^/:]+\/[^/:]+):(.*)$/.exec(pattern);
          if (!scoped) return { glob: pattern };
          const [owner, repo] = scoped[1].split("/");
          if (!loginPattern.test(owner) || !repositoryPattern.test(repo))
            throw new Error("projects repository patterns must look like `owner/repo:glob`");
          return { repository: scoped[1], glob: scoped[2].trim() || "**" };
        }),
      owners: parseList(owners, true),
    };
    if (!project.owners.length) throw new Error("projects lines need at least one owner");
    projects.set(key, project);
  }
  return [...projects.values()];
}

export function parseOptions(raw: Record<string, string>): Options {
  const token = (raw.token ?? "").trim();
  if (!token) throw new Error("token is required");
  const reviewers = parseList(raw.reviewers ?? "", true);
  return {
    token,
    reviewers,
    organizations: parseList(raw.organizations ?? "", false),
    assignReviewer: parseBoolean(raw, "assign-reviewer"),
    issueRepositories: parseScopes(raw["issue-repositories"] ?? ""),
    statusField: raw["status-field"]?.trim() || "Status",
    statusWeights: parseWeights(raw["status-weights"] ?? ""),
    projects: parseProjects(raw.projects ?? ""),
    codeowners: parseBoolean(raw, "codeowners"),
    command: raw.command?.trim() ?? "",
    requiredLabel: raw["required-label"]?.trim() ?? "",
  };
}
