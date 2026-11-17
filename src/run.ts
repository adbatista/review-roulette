import { unique } from "./inputs";
import { findManagedComment, readSuggestions, renderComment } from "./comment";
import { codeownersFor, matchProjects, parseCodeowners } from "./projects";
import { selectReviewer } from "./selection";
import type {
  AssignmentStatus,
  Category,
  GitHubApi,
  Options,
  ReviewerPick,
  PullSnapshot,
  RunResult,
  Target,
} from "./model";

async function resolveCategories(
  options: Options,
  target: Target,
  pull: PullSnapshot,
  api: GitHubApi,
): Promise<Category[]> {
  const eligible = (logins: string[]) =>
    unique(logins).filter((login) => login.toLowerCase() !== pull.author.toLowerCase());
  const files = options.projects.length || options.codeowners ? await api.listFiles(target) : [];
  const categories: Category[] = matchProjects(
    options.projects,
    `${target.owner}/${target.repo}`,
    files,
    pull.labels,
  ).map((project) => ({ name: project.name, candidates: project.owners }));
  if (options.codeowners) {
    const content = await api.getCodeowners(target, pull.baseRef);
    const candidates: string[] = [];
    for (const owner of content ? codeownersFor(parseCodeowners(content), files) : []) {
      const [organization, team] = owner.split("/");
      candidates.push(...(team ? await api.getTeamMembers(organization, team) : [owner]));
    }
    categories.push({ name: "Code owners", candidates });
  }
  const matched = categories
    .map((category) => ({ ...category, candidates: eligible(category.candidates) }))
    .filter((category) => category.candidates.length);
  if (matched.length) return matched;
  const reviewers = options.reviewers.length
    ? options.reviewers
    : await api.getSuggestedReviewers(target);
  return [{ name: "All", candidates: eligible(reviewers) }];
}

export async function run(
  options: Options,
  target: Target,
  api: GitHubApi,
  random = Math.random,
): Promise<RunResult> {
  const identity = await api.checkAccess(target, options.organizations, options.issueRepositories);
  const pull = await api.getPull(target);
  const categories = await resolveCategories(options, target, pull, api);
  const everyone = unique(categories.flatMap((category) => category.candidates));
  if (!everyone.length)
    throw new Error("No eligible reviewers remain after excluding the PR author");
  const counts = await api.getCounts(target, options.organizations, everyone);
  const issueLoads = options.issueRepositories.length
    ? await api.getIssueLoads(
        options.issueRepositories,
        everyone,
        options.statusField,
        options.statusWeights,
      )
    : undefined;
  const workloads = new Map(
    [...counts].map(([login, count]) => [login, count + (issueLoads?.get(login) ?? 0)]),
  );
  const comment = findManagedComment(await api.listComments(target), identity);
  const previous = comment ? readSuggestions(comment.body) : undefined;
  const outstanding = new Set(pull.requestedReviewers.map((login) => login.toLowerCase()));
  const requested = new Set<string>();
  const picks: ReviewerPick[] = [];
  for (const category of categories) {
    const selection = selectReviewer(
      category.candidates,
      pull.author,
      workloads,
      pull.requestedReviewers,
      previous?.get(category.name.toLowerCase()),
      random,
    );
    const login = selection.reviewer.toLowerCase();
    let status: AssignmentStatus = outstanding.has(login)
      ? "already-requested"
      : requested.has(login)
        ? "requested"
        : "suggested";
    if (options.assignReviewer && status === "suggested") {
      await api.requestReview(target, selection.reviewer);
      requested.add(login);
      status = "requested";
    }
    picks.push({
      ...selection,
      category: category.name,
      status,
      reviewCount: counts.get(login)!,
      ...(issueLoads ? { issueLoad: issueLoads.get(login)! } : {}),
    });
  }
  const body = renderComment(picks);
  if (comment) await api.updateComment(target, comment.id, body);
  else await api.createComment(target, body);
  return { picks, assigned: requested.size > 0 };
}
