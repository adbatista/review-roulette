import { pathMatcher } from "./glob";
import type { Project } from "./model";

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

export function matchProjects(
  projects: Project[],
  repository: string,
  files: string[],
  labels: string[],
): Project[] {
  return projects.filter(
    (project) =>
      labels.some((label) => same(label, project.name)) ||
      project.patterns
        .filter((pattern) => !pattern.repository || same(pattern.repository, repository))
        .some((pattern) => pattern.glob === "**" || files.some(pathMatcher(pattern.glob))),
  );
}

interface CodeownersRule {
  matches: (path: string) => boolean;
  owners: string[];
}

export function parseCodeowners(content: string): CodeownersRule[] {
  return content
    .split("\n")
    .map((line) => line.replace(/(^|\s)#.*$/, "").trim())
    .filter(Boolean)
    .map((line) => {
      const [pattern, ...owners] = line.split(/\s+/);
      return {
        matches: pathMatcher(pattern, true),
        owners: owners.filter((owner) => owner.startsWith("@")).map((owner) => owner.slice(1)),
      };
    });
}

export function codeownersFor(rules: CodeownersRule[], files: string[]): string[] {
  const owners = new Map<string, string>();
  for (const file of files) {
    const rule = rules.findLast((candidate) => candidate.matches(file));
    for (const owner of rule?.owners ?? [])
      owners.set(owner.toLowerCase(), owners.get(owner.toLowerCase()) ?? owner);
  }
  return [...owners.values()];
}
