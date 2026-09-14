const WEBSITE_URL = "https://github.com/users/demo/projects/1";
const MOBILE_URL = "https://github.com/users/demo/projects/2";

const now = "2026-09-14T10:00:00.000Z";

const data = {
  projects: [
    { url: WEBSITE_URL, title: "Website · Current sprint" },
    { url: MOBILE_URL, title: "Mobile app · Launch" },
  ],
  snapshots: {
    [WEBSITE_URL]: {
      project: { url: WEBSITE_URL, owner: "demo", number: 1, isOrganization: false },
      title: "Website · Current sprint",
      viewerLogin: "demo",
      issues: [
        { id: "demo-42", number: 42, title: "Fix GitHub sign-in", body: "After returning from GitHub, restore the page where sign-in started.", url: "https://github.com/example/web-app/issues/42", repository: "example/web-app", status: "In progress", labels: ["bug"], assignees: ["demo"], updatedAt: now, projectItemID: "demo-item-42" },
        { id: "demo-38", number: 38, title: "Refine mobile navigation", body: "Keep menu spacing and behavior consistent on smaller screens.", url: "https://github.com/example/web-app/issues/38", repository: "example/web-app", status: "In progress", labels: ["interface"], assignees: ["demo"], updatedAt: now, projectItemID: "demo-item-38" },
        { id: "demo-47", number: 47, title: "Add the project empty state", body: "Show a helpful message when a project has no items yet.", url: "https://github.com/example/web-app/issues/47", repository: "example/web-app", status: "Todo", labels: ["interface"], assignees: ["demo"], updatedAt: now, projectItemID: "demo-item-47" },
        { id: "demo-31", number: 31, title: "Update the installation guide", body: "Review the first steps and requirements for running the project.", url: "https://github.com/example/docs/issues/31", repository: "example/docs", status: "Todo", labels: ["documentation"], assignees: ["teammate"], updatedAt: now, projectItemID: "demo-item-31" },
      ],
      fetchedAt: now,
      metadata: { id: "demo-project", statusField: { id: "demo-status", name: "Status", options: [{ id: "demo-todo", name: "Todo" }, { id: "demo-progress", name: "In progress" }, { id: "demo-done", name: "Done" }] }, repositories: ["example/web-app", "example/docs"], viewerID: "demo-viewer" },
    },
    [MOBILE_URL]: {
      project: { url: MOBILE_URL, owner: "demo", number: 2, isOrganization: false },
      title: "Mobile app · Launch",
      viewerLogin: "demo",
      issues: [
        { id: "demo-mobile-18", number: 18, title: "Prepare App Store screenshots", body: "Demo project item.", url: "https://github.com/example/mobile/issues/18", repository: "example/mobile", status: "Ready", labels: ["launch"], assignees: ["demo"], updatedAt: now, projectItemID: "demo-mobile-item-18" },
        { id: "demo-mobile-16", number: 16, title: "Review onboarding analytics", body: "Demo project item.", url: "https://github.com/example/mobile/issues/16", repository: "example/mobile", status: "In review", labels: ["launch"], assignees: ["demo"], updatedAt: now, projectItemID: "demo-mobile-item-16" },
        { id: "demo-mobile-12", number: 12, title: "Finish accessibility labels", body: "Demo project item.", url: "https://github.com/example/mobile/issues/12", repository: "example/mobile", status: "Done", labels: ["launch"], assignees: ["demo"], updatedAt: now, projectItemID: "demo-mobile-item-12" },
      ],
      fetchedAt: now,
      metadata: { id: "demo-mobile-project", statusField: { id: "demo-mobile-status", name: "Status", options: [{ id: "demo-ready", name: "Ready" }, { id: "demo-review", name: "In review" }, { id: "demo-mobile-done", name: "Done" }] }, repositories: ["example/mobile"], viewerID: "demo-viewer" },
    },
  },
};

const composerCatalog = {
  "example/web-app": composer("example/web-app", "repo-web", [{ id: "demo-bug", name: "bug" }, { id: "demo-enhancement", name: "enhancement" }]),
  "example/docs": composer("example/docs", "repo-docs", [{ id: "demo-docs", name: "documentation" }]),
  "example/mobile": composer("example/mobile", "repo-mobile", [{ id: "demo-launch", name: "launch" }]),
};

function composer(repository, repositoryID, labels) {
  return {
    repository,
    repositoryID,
    assignees: [{ id: "demo-viewer", name: "demo" }, { id: "demo-teammate", name: "teammate" }],
    labels,
    milestones: [{ id: "demo-milestone", name: "Next release" }],
    issueTypes: [{ id: "demo-task", name: "Task" }, { id: "demo-feature", name: "Feature" }],
    projects: data.projects.map((project, index) => ({ id: `demo-project-${index + 1}`, title: project.title, url: project.url })),
    templates: [{ filename: "bug_report.md", name: "Bug report", about: "Describe a reproducible problem", body: "## What happened?\n\n## Steps to reproduce\n\n## Expected behavior\n", title: "", assigneeIDs: [], labelIDs: labels.slice(0, 1).map((label) => label.id), issueTypeID: "demo-task" }],
    canWrite: true,
    warnings: [],
  };
}

export function createDemoData() {
  return structuredClone({ ...data, composers: composerCatalog });
}

