import { expect, it } from "vite-plus/test";
import { pathMatcher } from "../src/glob";
it.each([
  ["packages/web", "packages/web/src/a.ts", true],
  ["packages/web", "packages/web", true],
  ["packages/web", "packages/website/a.ts", false],
  ["packages/web/", "packages/web/a.ts", true],
  ["packages/web/**", "packages/web/src/a.ts", true],
  ["./packages/web", "packages/web/a.ts", true],
  ["packages/*/src", "packages/web/src/a.ts", true],
  ["packages/*/src", "packages/web/lib/src/a.ts", false],
  ["**/*.md", "README.md", true],
  ["**/*.md", "docs/guide/intro.md", true],
  ["src/**/test", "src/test/a.ts", true],
  ["src/**/test", "src/a/b/test/c.ts", true],
  ["src/file?.ts", "src/file1.ts", true],
  ["src/file?.ts", "src/file/.ts", false],
  ["src/a+b(1).ts", "src/a+b(1).ts", true],
  ["src/a.ts", "src/axts", false],
  ["web", "packages/web/a.ts", false],
  ["**", "anything/at/all.ts", true],
])("matches project glob %s against %s: %s", (pattern, path, expected) => {
  expect(pathMatcher(pattern)(path)).toBe(expected);
});
it.each([
  ["*", "any/depth/file.ts", true],
  ["*.js", "src/deep/app.js", true],
  ["*.js", "src/app.ts", false],
  ["/build/logs/", "build/logs/a/b.log", true],
  ["/build/logs/", "src/build/logs/a.log", false],
  ["docs/*", "docs/intro.md", true],
  ["docs/*", "docs/guide/intro.md", false],
  ["apps/", "packages/apps/a.ts", true],
  ["/apps", "apps/a.ts", true],
  ["/apps", "packages/apps/a.ts", false],
  ["/apps/github", "apps/github/a/b.ts", true],
  ["**/logs", "build/logs/a.log", true],
  ["Makefile", "tools/Makefile", true],
])("matches CODEOWNERS pattern %s against %s: %s", (pattern, path, expected) => {
  expect(pathMatcher(pattern, true)(path)).toBe(expected);
});
