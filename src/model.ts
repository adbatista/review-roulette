import type { GitHubClient } from "./github";

export interface Options {
  token: string;
  reviewers: string[];
  organizations: string[];
  assignReviewer: boolean;
  issueRepositories: string[];
  statusField: string;
  statusWeights: Map<string, number>;
  projects: Project[];
  codeowners: boolean;
}
export interface Project {
  name: string;
  patterns: { repository?: string; glob: string }[];
  owners: string[];
}
export interface Category {
  name: string;
  candidates: string[];
}
export interface Target {
  owner: string;
  repo: string;
  pullNumber: number;
}
export interface PullSnapshot {
  author: string;
  requestedReviewers: string[];
  labels: string[];
  baseRef: string;
}
export interface Selection {
  reviewer: string;
  workload: number;
}
export interface Suggestion extends Selection {
  reviewCount: number;
  issueLoad?: number;
}
export type AssignmentStatus = "suggested" | "requested" | "already-requested";
export interface ReviewerPick extends Suggestion {
  category: string;
  status: AssignmentStatus;
}
export interface RunResult {
  picks: ReviewerPick[];
  assigned: boolean;
}
export interface ManagedComment {
  id: number;
  body: string;
  authorLogin: string;
  authorType: string;
  appId?: number;
}
export interface CommentIdentity {
  login: string;
  appId?: number;
}
export type GitHubApi = Pick<GitHubClient, keyof GitHubClient>;
