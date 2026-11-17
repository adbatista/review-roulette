function translate(glob: string): string {
  let out = "";
  for (let i = 0; i < glob.length; i++) {
    const char = glob[i];
    if (char === "*" && glob[i + 1] === "*") {
      i++;
      if (glob[i + 1] === "/") {
        i++;
        out += "(?:.*/)?";
      } else out += ".*";
    } else if (char === "*") out += "[^/]*";
    else if (char === "?") out += "[^/]";
    else out += char.replace(/[\\^$.|+()[\]{}]/g, "\\$&");
  }
  return out;
}

// CODEOWNERS rules differ from plain globs: a pattern without a slash matches at any
// depth, and a trailing wildcard segment such as `docs/*` does not reach nested files.
export function pathMatcher(pattern: string, codeowners = false): (path: string) => boolean {
  const directory = pattern.endsWith("/");
  const trimmed = pattern.replace(/^\.\//, "").replace(/\/+$/, "");
  const floating = codeowners && !trimmed.includes("/");
  const glob = trimmed.replace(/^\/+/, "");
  const shallow = codeowners && glob.slice(glob.lastIndexOf("/") + 1).includes("*");
  const suffix = directory ? "/.*" : shallow ? "" : "(?:/.*)?";
  const regex = new RegExp(`^${floating ? "(?:.*/)?" : ""}${translate(glob)}${suffix}$`);
  return (path) => regex.test(path);
}
