import { findManagedComment, readSuggestion, renderComment } from "./comment";
import { selectReviewer } from "./selection";
import type { AssignmentStatus, GitHubApi, Options, RunResult, Suggestion, Target } from "./model";

export async function run(
  options: Options,
  target: Target,
  api: GitHubApi,
  random = Math.random,
): Promise<RunResult> {
  const identity = await api.checkAccess(target, options.organizations, options.issueRepositories);
  const pull = await api.getPull(target);
  const reviewers = options.reviewers.length
    ? options.reviewers
    : await api.getSuggestedReviewers(target);
  const eligible = reviewers.filter((login) => login.toLowerCase() !== pull.author.toLowerCase());
  if (!eligible.length)
    throw new Error("No eligible reviewers remain after excluding the PR author");
  const counts = await api.getCounts(target, options.organizations, eligible);
  const issueLoads = options.issueRepositories.length
    ? await api.getIssueLoads(
        options.issueRepositories,
        eligible,
        options.statusField,
        options.statusWeights,
      )
    : undefined;
  const workloads = new Map(
    [...counts].map(([login, count]) => [login, count + (issueLoads?.get(login) ?? 0)]),
  );
  const comment = findManagedComment(await api.listComments(target), identity);
  const selection = selectReviewer(
    eligible,
    pull.author,
    workloads,
    pull.requestedReviewers,
    comment ? readSuggestion(comment.body) : undefined,
    random,
  );
  const login = selection.reviewer.toLowerCase();
  const suggestion: Suggestion = {
    ...selection,
    reviewCount: counts.get(login)!,
    ...(issueLoads ? { issueLoad: issueLoads.get(login)! } : {}),
  };
  const alreadyRequested = pull.requestedReviewers.some(
    (requested) => requested.toLowerCase() === login,
  );
  let assigned = false;
  let status: AssignmentStatus = alreadyRequested ? "already-requested" : "suggested";
  if (options.assignReviewer && !alreadyRequested) {
    await api.requestReview(target, suggestion.reviewer);
    assigned = true;
    status = "requested";
  }
  const body = renderComment(suggestion, status);
  if (comment) await api.updateComment(target, comment.id, body);
  else await api.createComment(target, body);
  return { ...suggestion, assigned };
}
