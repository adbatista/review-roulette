import type { Selection } from "./model";
export function selectReviewer(
  reviewers: string[],
  author: string,
  counts: ReadonlyMap<string, number>,
  requestedReviewers: string[],
  previousReviewer: string | undefined,
  random: () => number,
): Selection {
  const normalized = new Map([...counts].map(([login, count]) => [login.toLowerCase(), count]));
  const candidates = reviewers
    .filter((login) => login.toLowerCase() !== author.toLowerCase())
    .map((reviewer) => {
      const workload = normalized.get(reviewer.toLowerCase());
      if (workload === undefined || !Number.isSafeInteger(workload) || workload < 0)
        throw new Error("Invalid or missing reviewer workload count");
      return { reviewer, workload };
    });
  if (!candidates.length)
    throw new Error("No eligible reviewers remain after excluding the PR author");
  const minimum = Math.min(...candidates.map((candidate) => candidate.workload));
  const previous = candidates.find(
    (candidate) => candidate.reviewer.toLowerCase() === previousReviewer?.toLowerCase(),
  );
  if (
    previous &&
    (previous.workload === minimum ||
      requestedReviewers.some((login) => login.toLowerCase() === previous.reviewer.toLowerCase()))
  )
    return previous;
  const tied = candidates.filter((candidate) => candidate.workload === minimum);
  return tied[Math.floor(random() * tied.length)];
}
