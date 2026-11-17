import { expect, it } from "vite-plus/test";
import { codeownersFor, matchProjects, parseCodeowners } from "../src/projects";
import type { Project } from "../src/model";
const projects: Project[] = [
  { name: "web", patterns: [{ glob: "packages/web/**" }], owners: ["alice"] },
  { name: "api", patterns: [{ repository: "Acme/Mono", glob: "services/api" }], owners: ["bob"] },
  { name: "docs", patterns: [{ repository: "acme/docs", glob: "**" }], owners: ["carol"] },
  { name: "security", patterns: [], owners: ["dave"] },
];
const names = (repository: string, files: string[], labels: string[] = []) =>
  matchProjects(projects, repository, files, labels).map((project) => project.name);
it("matches folders in any repository and repository-scoped folders only there", () => {
  expect(names("acme/mono", ["packages/web/a.ts", "services/api/main.go"])).toEqual(["web", "api"]);
  expect(names("acme/other", ["packages/web/a.ts", "services/api/main.go"])).toEqual(["web"]);
  expect(names("acme/mono", ["README.md"])).toEqual([]);
});
it("matches a whole repository even without changed files", () => {
  expect(names("ACME/Docs", [])).toEqual(["docs"]);
});
it("matches a project by a label equal to its name", () => {
  expect(names("acme/mono", [], ["Security", "bug"])).toEqual(["security"]);
});
const rules = parseCodeowners(`
# default owners
*       @fallback  # trailing comment
*.md    @docs-team someone@example.com
/apps/  @acme/apps @Alice

/apps/legacy/
`);
it("uses the last matching CODEOWNERS rule per file and merges owners", () => {
  expect(codeownersFor(rules, ["src/a.ts", "apps/web/a.ts", "apps/web/README.md"])).toEqual([
    "fallback",
    "acme/apps",
    "Alice",
  ]);
  expect(codeownersFor(rules, ["README.md", "docs/a.md"])).toEqual(["docs-team"]);
});
it("treats a later rule without owners as unowned and ignores unmatched files", () => {
  expect(codeownersFor(rules, ["apps/legacy/a.ts"])).toEqual([]);
  expect(codeownersFor(parseCodeowners("/src/ @alice"), ["docs/a.md"])).toEqual([]);
});
