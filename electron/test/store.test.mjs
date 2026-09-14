import assert from "node:assert/strict";
import test from "node:test";

import { AppStore } from "../src/store.mjs";

const URL_ONE = "https://github.com/users/alex/projects/1";
const URL_TWO = "https://github.com/orgs/acme/projects/2";

function snapshot(url, title, suffix = "1") {
  return {
    project: { url, owner: url.includes("/orgs/") ? "acme" : "alex", number: Number(url.split("/").at(-1)), isOrganization: url.includes("/orgs/") },
    title,
    viewerLogin: "alex",
    issues: [
      { id: `issue-${suffix}`, number: Number(suffix), title: `${title} mine`, body: "Full body", url: `https://github.com/acme/repo/issues/${suffix}`, repository: "acme/repo", status: "Ready", labels: ["bug"], assignees: ["alex"], updatedAt: "2026-09-14T10:00:00.000Z", projectItemID: `item-${suffix}` },
      { id: `other-${suffix}`, number: 90 + Number(suffix), title: `${title} other`, body: "Hidden from Mine", url: `https://github.com/acme/repo/issues/${90 + Number(suffix)}`, repository: "acme/repo", status: "Done", labels: [], assignees: ["sam"], updatedAt: "2026-09-14T10:00:00.000Z", projectItemID: `other-item-${suffix}` },
    ],
    fetchedAt: "2026-09-14T10:00:00.000Z",
    metadata: { id: `project-${suffix}`, statusField: { id: `field-${suffix}`, name: "Workflow", options: [{ id: "ready", name: "Ready" }, { id: "done", name: "Done" }] }, repositories: ["acme/repo"], viewerID: "user-alex" },
  };
}

function persistence(initial = {}) {
  let settings = structuredClone(initial.settings || {});
  let token = initial.token || null;
  const caches = new Map(Object.entries(initial.caches || {}).map(([key, value]) => [key, structuredClone(value)]));
  const calls = { saveSettings: 0, saveCache: [], removeCache: [], setToken: [], deleteToken: 0 };
  return {
    calls,
    loadSettings: () => structuredClone(settings),
    saveSettings(value) { calls.saveSettings += 1; settings = structuredClone(value); },
    loadCache(url) { return structuredClone(caches.get(url) || null); },
    saveCache(url, value) { calls.saveCache.push(url); caches.set(url, structuredClone(value)); },
    removeCache(url) { calls.removeCache.push(url); caches.delete(url); },
    getToken: () => token,
    setToken(value) { calls.setToken.push(value); token = value; },
    deleteToken() { calls.deleteToken += 1; token = null; },
    hasToken: () => Boolean(token),
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

function client(overrides = {}) {
  return {
    fetchProject: async (url) => snapshot(url, "Fetched"),
    fetchIssueComposer: async (repository) => ({ repository, repositoryID: "repo", assignees: [{ id: "user-alex", name: "alex" }, { id: "user-sam", name: "sam" }], labels: [{ id: "label-bug", name: "bug" }], milestones: [{ id: "milestone", name: "Release" }], issueTypes: [{ id: "type-task", name: "Task" }], projects: [{ id: "extra", title: "Roadmap", url: "https://github.com/users/alex/projects/3" }], templates: [{ filename: "bug.md", name: "Bug", about: "", body: "", title: "", assigneeIDs: [], labelIDs: [], issueTypeID: null }], canWrite: true, warnings: [] }),
    updateStatus: async () => {},
    updateAssignees: async (_id, ids) => ids.map((id) => ({ id, name: id === "user-alex" ? "alex" : "sam" })),
    createIssue: async () => ({ issueID: "new", url: "https://github.com/acme/repo/issues/100", projectItemID: "new-item", warning: null }),
    uploadAttachment: async (_repository, filePath) => `https://github.com/assets/${filePath.split("/").at(-1)}`,
    ...overrides,
  };
}

test("restores one project cache and exposes the exact renderer state without secrets", async (t) => {
  const cached = snapshot(URL_ONE, "Cached project");
  const storage = persistence({ settings: { projectURL: URL_ONE, projects: [{ url: URL_ONE, title: "Cached project" }], useCLI: false, onlyMine: true, hiddenStatusNamesByProject: { [URL_ONE.toLowerCase()]: ["Done"] } }, token: "super-secret", caches: { [URL_ONE]: cached } });
  const store = new AppStore({ client: client({ fetchProject: async () => cached }), persistence: storage });
  t.after(() => store.close());
  await store.initialize();

  await store.dispatch({ action: "select", id: "other-1" });
  const value = store.state("preview", { horizontal: "right", vertical: "below" });
  assert.deepEqual(Object.keys(value).sort(), ["alwaysOnTop", "attachmentError", "canEditStatus", "composerAttachments", "composerError", "composerLoading", "composerMetadata", "composerRepository", "createdIssueURL", "creationRevision", "detailIssue", "errorMessage", "hasSavedToken", "inProgressStatuses", "isConfigured", "isDemo", "isLoading", "isMutating", "issues", "lastSyncLabel", "mode", "mutationError", "mutationNotice", "onlyMine", "pendingProjectURL", "pinnedIssueID", "previewHorizontal", "previewVertical", "projectTitle", "projectURL", "projects", "repositories", "search", "selectedIssueID", "showSettings", "statusFieldName", "statusOptions", "statusVisibility", "todoStatuses", "useCLI", "viewerLogin"].sort());
  assert.equal(JSON.stringify(value).includes("super-secret"), false);
  assert.deepEqual(value.issues.map((issue) => issue.id), ["issue-1"]);
  assert.equal(value.detailIssue.id, "other-1", "selected detail must survive the Mine filter");
  assert.deepEqual(value.statusVisibility, [{ name: "Ready", visible: true }, { name: "Done", visible: false }, { name: "", visible: true }]);
  assert.equal(value.previewHorizontal, "right");
  assert.equal(value.previewVertical, "below");
});

test("project switching commits atomically, ignores stale results, and isolates caches", async (t) => {
  const first = snapshot(URL_ONE, "One", "1");
  const storage = persistence({ settings: { projectURL: URL_ONE, projects: [{ url: URL_ONE, title: "One" }, { url: URL_TWO, title: "Two" }], useCLI: true }, caches: { [URL_ONE]: first } });
  const slow = deferred();
  const api = client({ fetchProject: async (url) => url === URL_TWO ? slow.promise : first });
  const store = new AppStore({ client: api, persistence: storage });
  t.after(() => store.close());
  await store.initialize();

  const switching = store.dispatch({ action: "selectProject", url: URL_TWO });
  assert.equal(store.state().projectURL, URL_ONE);
  assert.equal(store.state().pendingProjectURL, URL_TWO);
  const reconnect = store.dispatch({ action: "connect", projectURL: URL_ONE, useCLI: true, token: "" });
  await reconnect;
  slow.resolve(snapshot(URL_TWO, "Late two", "2"));
  await switching;
  assert.equal(store.state().projectURL, URL_ONE);
  assert.equal(store.state().pendingProjectURL, "");
  assert.equal(storage.calls.saveCache.includes(URL_TWO), false);

  api.fetchProject = async (url) => snapshot(url, "Two", "2");
  await store.dispatch({ action: "selectProject", url: URL_TWO });
  assert.equal(store.state().projectURL, URL_TWO);
  assert.equal(storage.calls.saveCache.at(-1), URL_TWO);
});

test("serializes writes, keeps filtered detail, and preserves confirmed partial creation", async (t) => {
  const live = snapshot(URL_ONE, "Live");
  const storage = persistence({ settings: { projectURL: URL_ONE, projects: [{ url: URL_ONE, title: "Live" }], useCLI: true }, caches: { [URL_ONE]: live } });
  const assignment = deferred();
  const creation = deferred();
  let assignmentCalls = 0;
  let creationCalls = 0;
  let request;
  const api = client({
    fetchProject: async () => live,
    updateAssignees: async (_id, ids) => { assignmentCalls += 1; await assignment.promise; return ids.map((id) => ({ id, name: "sam" })); },
    createIssue: async (value) => { creationCalls += 1; request = value; return creation.promise; },
  });
  const store = new AppStore({ client: api, persistence: storage });
  t.after(() => store.close());
  await store.initialize();
  await store.dispatch({ action: "select", id: "issue-1" });
  await store.dispatch({ action: "loadComposer", repository: "acme/repo" });

  const saving = store.dispatch({ action: "updateAssignees", id: "issue-1", assigneeIDs: ["user-sam"] });
  await store.dispatch({ action: "updateAssignees", id: "issue-1", assigneeIDs: [] });
  assignment.resolve();
  await saving;
  assert.equal(assignmentCalls, 1);
  assert.equal(store.state().issues.some((issue) => issue.id === "issue-1"), false);
  assert.equal(store.state().detailIssue.id, "issue-1");

  const message = { action: "createIssue", repository: "acme/repo", title: "Created", body: "Body", assigneeIDs: ["user-sam"], labelIDs: ["label-bug"], milestoneID: "milestone", issueTypeID: "type-task", templateFilename: "bug.md", additionalProjectIDs: ["extra"], parentIssue: "1", blockedBy: ["2"], blocking: ["3"], optionID: "ready" };
  const creating = store.dispatch(message);
  await store.dispatch(message);
  creation.resolve({ issueID: "new", url: "https://github.com/acme/repo/issues/100", projectItemID: null, warning: "Issue created, but adding it to the project failed." });
  await creating;
  assert.equal(creationCalls, 1);
  assert.equal(store.state().createdIssueURL, "https://github.com/acme/repo/issues/100");
  assert.equal(store.state().creationRevision, 1);
  assert.match(store.state().mutationNotice, /adding it to the project failed/);
  assert.deepEqual(request, { projectID: "project-1", repository: "acme/repo", title: "Created", body: "Body", assigneeIDs: ["user-sam"], labelIDs: ["label-bug"], milestoneID: "milestone", issueTypeID: "type-task", templateFilename: "bug.md", additionalProjectIDs: ["extra"], parentIssue: "1", blockedBy: ["2"], blocking: ["3"], statusFieldID: "field-1", statusOptionID: "ready" });
});

test("composer generation guards and demo mutations never touch live persistence or GitHub", async (t) => {
  const storage = persistence({ settings: { projectURL: URL_ONE, projects: [{ url: URL_ONE, title: "Live" }] }, caches: { [URL_ONE]: snapshot(URL_ONE, "Live") } });
  const slow = deferred();
  let githubCalls = 0;
  const api = client({ fetchProject: async () => { githubCalls += 1; return snapshot(URL_ONE, "Live"); }, fetchIssueComposer: async (repository) => repository === "acme/slow" ? slow.promise : client().fetchIssueComposer(repository) });
  const store = new AppStore({ client: api, persistence: storage });
  t.after(() => store.close());
  await store.initialize({ demo: true });
  const persistenceCalls = structuredClone(storage.calls);

  await store.dispatch({ action: "statusVisibility", name: "Done", visible: false });
  const demoFirstURL = store.state().projectURL;
  const demoSecondURL = store.state().projects[1].url;
  await store.dispatch({ action: "selectProject", url: demoSecondURL });
  assert.equal(store.state().statusVisibility.find((row) => row.name === "Done").visible, true);
  await store.dispatch({ action: "selectProject", url: demoFirstURL });
  assert.equal(store.state().statusVisibility.find((row) => row.name === "Done").visible, false);

  const old = store.dispatch({ action: "loadComposer", repository: "acme/slow" });
  await store.dispatch({ action: "loadComposer", repository: "example/web-app" });
  slow.resolve(await client().fetchIssueComposer("acme/slow"));
  await old;
  assert.equal(store.state().composerRepository, "example/web-app");
  assert.equal(store.state().composerMetadata.repository, "example/web-app");
  assert.equal(githubCalls, 0);

  await store.dispatch({ action: "createIssue", repository: "example/web-app", title: "Demo only", body: "A complete body", assigneeIDs: ["demo-viewer"], labelIDs: [], milestoneID: "", issueTypeID: "", templateFilename: "", additionalProjectIDs: [], parentIssue: "", blockedBy: [], blocking: [], optionID: "demo-todo" });
  await store.dispatch({ action: "connect", projectURL: URL_TWO, useCLI: true, token: "" });
  assert.equal(store.state().creationRevision, 1);
  assert.equal(githubCalls, 0);
  assert.deepEqual(storage.calls, persistenceCalls);
});

test("attachment uploads are reused after an uncertain create and file paths never enter state", async (t) => {
  const live = snapshot(URL_ONE, "Live");
  const storage = persistence({ settings: { projectURL: URL_ONE, projects: [{ url: URL_ONE, title: "Live" }] }, caches: { [URL_ONE]: live } });
  let uploads = 0;
  let creates = 0;
  let finalBody = "";
  const api = client({
    fetchProject: async () => live,
    validateAttachment: async (filePath) => ({ name: filePath.split("/").at(-1), size: 1234 }),
    uploadAttachment: async () => { uploads += 1; return "https://github.com/user-attachments/assets/image"; },
    createIssue: async (request) => {
      creates += 1;
      finalBody = request.body;
      if (creates === 1) throw new Error("GitHub may have created the issue. Check the repository before retrying.");
      return { issueID: "created", url: "https://github.com/acme/repo/issues/101", projectItemID: "item", warning: null };
    },
  });
  const store = new AppStore({ client: api, persistence: storage });
  t.after(() => store.close());
  await store.initialize();
  await store.dispatch({ action: "loadComposer", repository: "acme/repo" });
  await store.addAttachments(["/private/tmp/layout.png", "/private/tmp/layout.png"]);
  assert.equal(store.state().composerAttachments.length, 1);
  assert.equal(JSON.stringify(store.state()).includes("/private/tmp/layout.png"), false);

  const message = { action: "createIssue", repository: "acme/repo", title: "With image", body: "Body", assigneeIDs: [], labelIDs: [], additionalProjectIDs: [], blockedBy: [], blocking: [], optionID: "ready" };
  await store.dispatch(message);
  assert.match(store.state().mutationError, /Check the repository before retrying/);
  assert.equal(store.state().composerAttachments.length, 1);
  await store.dispatch(message);
  assert.equal(uploads, 1);
  assert.equal(creates, 2);
  assert.match(finalBody, /!\[layout\.png\]\(https:\/\/github\.com\/user-attachments\/assets\/image\)/);
  assert.equal(store.state().composerAttachments.length, 0);
  assert.equal(store.state().creationRevision, 1);
});

test("No status creation omits both status identifiers, including attachment creates", async (t) => {
  const live = snapshot(URL_ONE, "Live");
  const storage = persistence({ settings: { projectURL: URL_ONE, projects: [{ url: URL_ONE, title: "Live" }] }, caches: { [URL_ONE]: live } });
  let captured;
  const api = client({
    fetchProject: async () => live,
    validateAttachment: async () => ({ name: "proof.png", size: 42 }),
    uploadAttachment: async () => "https://github.com/user-attachments/assets/proof",
    createIssue: async (request) => {
      if (Boolean(request.statusFieldID) !== Boolean(request.statusOptionID)) throw new Error("Status field and option must be supplied together.");
      captured = request;
      return { issueID: "created", url: "https://github.com/acme/repo/issues/102", projectItemID: "item", warning: null };
    },
  });
  const store = new AppStore({ client: api, persistence: storage });
  t.after(() => store.close());
  await store.initialize();
  await store.dispatch({ action: "loadComposer", repository: "acme/repo" });
  await store.addAttachments(["/private/tmp/proof.png"]);
  await store.dispatch({ action: "createIssue", repository: "acme/repo", title: "No status", body: "Body", assigneeIDs: [], labelIDs: [], additionalProjectIDs: [], blockedBy: [], blocking: [], optionID: "" });

  assert.equal(store.state().mutationError, "");
  assert.equal(store.state().creationRevision, 1);
  assert.equal(captured.statusFieldID, null);
  assert.equal(captured.statusOptionID, null);
  assert.match(captured.body, /proof\.png/);
});

test("GitHub handoff uses trusted metadata, copies oversized body, and preserves composer state", async (t) => {
  const live = snapshot(URL_ONE, "Live");
  const storage = persistence({ settings: { projectURL: URL_ONE, projects: [{ url: URL_ONE, title: "Live" }] }, caches: { [URL_ONE]: live } });
  const opened = [];
  const copied = [];
  const store = new AppStore({ client: client({ fetchProject: async () => live }), persistence: storage, openExternal: async (url) => opened.push(url), copyText: (text) => copied.push(text) });
  t.after(() => store.close());
  await store.initialize();
  await store.dispatch({ action: "loadComposer", repository: "acme/repo" });
  const body = "x".repeat(7_100);
  await store.dispatch({ action: "openIssueComposerOnGitHub", repository: "acme/repo", title: "Draft", body, assigneeIDs: ["user-sam"], labelIDs: ["label-bug"], milestoneID: "milestone", additionalProjectIDs: ["extra"] });

  assert.deepEqual(copied, [body]);
  assert.equal(opened.length, 1);
  const target = new URL(opened[0]);
  assert.equal(target.origin, "https://github.com");
  assert.equal(target.pathname, "/acme/repo/issues/new");
  assert.equal(target.searchParams.has("body"), false);
  assert.equal(target.searchParams.get("assignees"), "sam");
  assert.equal(target.searchParams.get("labels"), "bug");
  assert.equal(store.state().composerMetadata.repository, "acme/repo");
  assert.match(store.state().mutationNotice, /draft is still here/);
});
