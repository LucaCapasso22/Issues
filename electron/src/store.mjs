import { randomUUID } from "node:crypto";
import { extname, resolve } from "node:path";

import { createDemoData } from "./demo.mjs";

const DEFAULT_IN_PROGRESS = "In progress, Doing";
const DEFAULT_TODO = "Todo, To do, Backlog, Ready";
const PROJECT_URL = /^https:\/\/github\.com\/(users|orgs)\/([A-Za-z0-9_.-]+)\/projects\/([1-9][0-9]*)\/?$/i;
const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const VIDEO_EXTENSIONS = new Set([".mp4", ".mov", ".webm"]);

function clone(value) {
  return value == null ? value : structuredClone(value);
}

function errorText(error) {
  return error instanceof Error && error.message ? error.message : String(error || "An unexpected error occurred.");
}

function projectKey(url) {
  return String(url || "").trim().replace(/\/+$/, "").toLowerCase();
}

function canonicalInputURL(url) {
  const match = String(url || "").trim().match(PROJECT_URL);
  if (!match) return null;
  return `https://github.com/${match[1].toLowerCase()}/${match[2]}/projects/${Number(match[3])}`;
}

function repositoryName(value) {
  const repository = String(value || "").trim();
  return REPOSITORY.test(repository) ? repository : null;
}

function uniqueStrings(value, maximum = Infinity) {
  if (!Array.isArray(value)) return [];
  const result = [];
  const seen = new Set();
  for (const item of value) {
    if (typeof item !== "string" || seen.has(item)) continue;
    seen.add(item);
    result.push(item);
    if (result.length >= maximum) break;
  }
  return result;
}

function optionalString(value) {
  const text = typeof value === "string" ? value.trim() : "";
  return text || null;
}

function safeGitHubURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname.toLowerCase() === "github.com" ? url : null;
  } catch {
    return null;
  }
}

function normalizedProjects(value) {
  const result = [];
  const seen = new Set();
  for (const project of Array.isArray(value) ? value : []) {
    const url = canonicalInputURL(project?.url);
    const key = projectKey(url);
    if (!url || seen.has(key)) continue;
    seen.add(key);
    result.push({ url, title: typeof project.title === "string" && project.title.trim() ? project.title : url });
  }
  return result;
}

function validSnapshot(snapshot, requestedURL) {
  return snapshot && typeof snapshot === "object" && typeof snapshot.project?.url === "string" &&
    projectKey(snapshot.project.url) === projectKey(requestedURL) && Array.isArray(snapshot.issues);
}

export class AppStore {
  constructor({ client, persistence, onChange = () => {}, openExternal = async () => {}, copyText = () => {} }) {
    if (!client || !persistence) throw new TypeError("AppStore requires a GitHub client and persistence.");
    this.client = client;
    this.persistence = persistence;
    this.onChange = onChange;
    this.openExternal = openExternal;
    this.copyText = copyText;
    this._reset();
  }

  _reset() {
    this.projectURL = "";
    this.projects = [];
    this.useCLI = true;
    this.onlyMine = true;
    this.search = "";
    this.selectedIssueID = "";
    this.pinnedIssueID = "";
    this.alwaysOnTop = true;
    this.showSettings = false;
    this.inProgressStatuses = DEFAULT_IN_PROGRESS;
    this.todoStatuses = DEFAULT_TODO;
    this.snapshot = null;
    this.isLoading = false;
    this.errorMessage = "";
    this.isDemo = false;
    this.isConfigured = false;
    this.pendingProjectURL = "";
    this.isMutating = false;
    this.mutationError = "";
    this.mutationNotice = "";
    this.createdIssueURL = "";
    this.creationRevision = 0;
    this.composerRepository = "";
    this.composerMetadata = null;
    this.composerLoading = false;
    this.composerError = "";
    this.attachmentError = "";
    this.hiddenStatusNamesByProject = {};
    this.demoHiddenStatusNamesByProject = {};
    this.attachmentContexts = new Map();
    this.demoData = null;
    this.generation = 0;
    this.composerGeneration = 0;
    this.requestController = null;
    this.composerController = null;
    this.timer = null;
    this.closed = false;
  }

  async initialize({ demo = false } = {}) {
    if (this.closed) return;
    if (demo) {
      this._enterDemo();
    } else {
      this._restore();
      this._emit();
      if (this.isConfigured) await this._refresh();
    }
    if (!this.timer && !this.closed) {
      this.timer = setInterval(() => { void this._refresh(); }, 60_000);
      this.timer.unref?.();
    }
  }

  close() {
    this.closed = true;
    this.generation += 1;
    this.composerGeneration += 1;
    this.requestController?.abort();
    this.composerController?.abort();
    this.requestController = null;
    this.composerController = null;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  state(mode = "main", placement = {}) {
    const issues = this._accountIssues().map((issue) => this._issueState(issue));
    const selected = this.snapshot?.issues?.find((issue) => String(issue.id) === this.selectedIssueID) || null;
    const metadata = this.snapshot?.metadata || null;
    const field = metadata?.statusField || null;
    const canEditStatus = Boolean(selected && (this.isDemo || (metadata?.id && field?.id && selected.projectItemID)));
    return {
      mode,
      previewHorizontal: (placement.previewHorizontal || placement.horizontal) === "right" ? "right" : "left",
      previewVertical: (placement.previewVertical || placement.vertical) === "below" ? "below" : "above",
      projectTitle: this.snapshot?.title || this.projects.find((project) => projectKey(project.url) === projectKey(this.projectURL))?.title || "GitHub Issues",
      projectURL: this.projectURL,
      pendingProjectURL: this.pendingProjectURL,
      projects: clone(this.projects),
      viewerLogin: this.snapshot?.viewerLogin || "",
      isConfigured: this.isConfigured,
      isDemo: this.isDemo,
      isLoading: this.isLoading,
      errorMessage: this.errorMessage,
      lastSyncLabel: this._lastSyncLabel(),
      onlyMine: this.onlyMine,
      search: this.search,
      selectedIssueID: this.selectedIssueID,
      pinnedIssueID: this.pinnedIssueID,
      alwaysOnTop: this.alwaysOnTop,
      showSettings: this.showSettings,
      useCLI: this.useCLI,
      hasSavedToken: this._hasToken(),
      inProgressStatuses: this.inProgressStatuses,
      todoStatuses: this.todoStatuses,
      statusOptions: clone(field?.options || []),
      statusVisibility: this._statusVisibility(),
      statusFieldName: field?.name || "Status",
      canEditStatus,
      repositories: clone(metadata?.repositories || []),
      isMutating: this.isMutating,
      mutationError: this.mutationError,
      mutationNotice: this.mutationNotice,
      createdIssueURL: this.createdIssueURL,
      creationRevision: this.creationRevision,
      detailIssue: selected ? this._issueState(selected) : null,
      composerRepository: this.composerRepository,
      composerMetadata: clone(this.composerMetadata),
      composerLoading: this.composerLoading,
      composerError: this.composerError,
      composerAttachments: this._currentAttachments().map(({ id, name, size }) => ({ id, name, size })),
      attachmentError: this.attachmentError,
      issues,
    };
  }

  async dispatch(message) {
    if (this.closed || !message || typeof message !== "object") return;
    const action = typeof message.action === "string" ? message.action : "";
    switch (action) {
      case "refresh": await this._refresh(); break;
      case "select": await this._selectIssue(message.id); break;
      case "loadComposer": await this._loadComposer(message.repository); break;
      case "updateAssignees": await this._updateAssignees(message); break;
      case "changeStatus": await this._changeStatus(message); break;
      case "createIssue": await this._createIssue(message); break;
      case "clearMutationFeedback": this._clearMutationFeedback(); break;
      case "openCreatedIssue": await this._openCreatedIssue(); break;
      case "selectProject": await this._selectProject(message.url); break;
      case "statusVisibility": this._setStatusVisibility(message.name, message.visible); break;
      case "pin": this._pin(message.id); break;
      case "openIssue": await this._openIssue(message.id); break;
      case "openProject": await this._openProject(); break;
      case "settings": this.showSettings = message.value !== false; this._emit(); break;
      case "preference": this._preference(message.key, message.value); break;
      case "connect": await this._connect(message); break;
      case "disconnect": await this._disconnect(); break;
      case "demo": this._enterDemo(); break;
      case "leaveDemo": await this._leaveDemo(); break;
      case "removeAttachment": this._removeAttachment(message.id); break;
      case "openIssueComposerOnGitHub": await this._openComposerOnGitHub(message); break;
      default: break;
    }
  }

  async addAttachments(paths) {
    if (this.closed || this.isMutating || this.composerLoading || !this.composerMetadata?.canWrite) {
      this.attachmentError = "Choose a repository with write access before adding images or videos.";
      this._emit();
      return;
    }
    this.attachmentError = "";
    const attachments = this._currentAttachments();
    const existing = new Set(attachments.map((attachment) => attachment.filePath));
    let validateAttachment = this.client.validateAttachment;
    try {
      if (typeof validateAttachment !== "function") ({ validateAttachment } = await import("./github.mjs"));
    } catch (error) {
      this.attachmentError = errorText(error);
      this._emit();
      return;
    }
    for (const rawPath of Array.isArray(paths) ? paths : []) {
      const filePath = resolve(String(rawPath || ""));
      if (existing.has(filePath)) continue;
      if (attachments.length >= 10) {
        this.attachmentError = "Attach up to 10 files to one issue.";
        break;
      }
      try {
        const { name, size } = await validateAttachment(filePath);
        attachments.push({ id: randomUUID(), name, size, filePath, uploadedURL: "" });
        existing.add(filePath);
      } catch (error) {
        this.attachmentError = errorText(error);
      }
    }
    this.attachmentContexts.set(this._attachmentContext(), attachments);
    this._emit();
  }

  _restore() {
    let settings = {};
    try { settings = this.persistence.loadSettings() || {}; }
    catch (error) { this.errorMessage = `Could not load settings. ${errorText(error)}`; }
    this.useCLI = settings.useCLI !== false;
    this.onlyMine = settings.onlyMine !== false;
    this.alwaysOnTop = settings.alwaysOnTop !== false;
    this.inProgressStatuses = typeof settings.inProgressStatuses === "string" ? settings.inProgressStatuses : DEFAULT_IN_PROGRESS;
    this.todoStatuses = typeof settings.todoStatuses === "string" ? settings.todoStatuses : DEFAULT_TODO;
    this.pinnedIssueID = typeof settings.pinnedIssueID === "string" ? settings.pinnedIssueID : "";
    this.hiddenStatusNamesByProject = settings.hiddenStatusNamesByProject && typeof settings.hiddenStatusNamesByProject === "object" ? clone(settings.hiddenStatusNamesByProject) : {};
    this.projects = normalizedProjects(settings.projects);
    const restoredURL = canonicalInputURL(settings.projectURL);
    if (restoredURL && !this.projects.some((project) => projectKey(project.url) === projectKey(restoredURL))) {
      this.projects.push({ url: restoredURL, title: restoredURL });
    }
    this.projectURL = this.projects.find((project) => projectKey(project.url) === projectKey(restoredURL))?.url || this.projects[0]?.url || "";
    this.isConfigured = Boolean(this.projectURL);
    if (this.projectURL) {
      try {
        const cached = this.persistence.loadCache(this.projectURL);
        if (validSnapshot(cached, this.projectURL)) this.snapshot = cached;
      } catch (error) {
        this.errorMessage = `Could not load the saved project. ${errorText(error)}`;
      }
    }
  }

  _emit() {
    if (this.closed) return;
    try { this.onChange(); } catch { /* Broadcasting cannot own store state. */ }
  }

  _hasToken() {
    if (this.isDemo) return false;
    try { return Boolean(this.persistence.hasToken()); } catch { return false; }
  }

  _auth(useCLI = this.useCLI, proposedToken = "") {
    if (useCLI) return { useCLI: true };
    const token = String(proposedToken || "").trim() || String(this.persistence.getToken() || "").trim();
    if (!token) throw new Error("Enter a GitHub token with access to this project.");
    return { useCLI: false, token };
  }

  _invalidateReads({ composer = true } = {}) {
    this.generation += 1;
    this.requestController?.abort();
    this.requestController = null;
    this.isLoading = false;
    this.pendingProjectURL = "";
    if (composer) this._cancelComposer(false);
    return this.generation;
  }

  _cancelComposer(clear) {
    this.composerGeneration += 1;
    this.composerController?.abort();
    this.composerController = null;
    this.composerLoading = false;
    if (clear) {
      this.composerRepository = "";
      this.composerMetadata = null;
      this.composerError = "";
    }
  }

  async _refresh() {
    if (this.closed || this.requestController || this.isLoading || this.isMutating || this.isDemo || !this.isConfigured || !this.projectURL) return;
    const url = this.projectURL;
    const epoch = this.generation;
    const controller = new AbortController();
    this.requestController = controller;
    this.isLoading = true;
    this._emit();
    try {
      const result = await this.client.fetchProject(url, this._auth(), { signal: controller.signal });
      if (epoch !== this.generation || this.closed) return;
      if (!validSnapshot(result, url)) throw new Error("GitHub returned a different project. The current project was kept unchanged.");
      this.snapshot = clone(result);
      this.errorMessage = "";
      if (this.pinnedIssueID && !result.issues.some((issue) => String(issue.id) === this.pinnedIssueID)) {
        this.pinnedIssueID = "";
        this._saveSettings();
      }
      try { this.persistence.saveCache(url, clone(result)); }
      catch (error) { this.errorMessage = `Project updated, but the local cache could not be saved. ${errorText(error)}`; }
    } catch (error) {
      if (epoch === this.generation && !controller.signal.aborted) {
        this.errorMessage = this.snapshot ? `Showing the last saved update. ${errorText(error)}` : errorText(error);
      }
    } finally {
      if (epoch === this.generation) {
        this.requestController = null;
        this.isLoading = false;
        this.pendingProjectURL = "";
        this._emit();
      }
    }
  }

  async _connect(message) {
    if (!this._allowSessionChange()) return;
    if (this.isDemo) {
      this.errorMessage = "Leave demo before connecting a GitHub project.";
      this._emit();
      return;
    }
    const requestedURL = canonicalInputURL(message.projectURL);
    if (!requestedURL) {
      this.errorMessage = "Enter a valid GitHub Project URL: https://github.com/users/name/projects/1 or /orgs/name/projects/1.";
      this._emit();
      return;
    }
    const proposedCLI = message.useCLI !== false;
    const proposedToken = typeof message.token === "string" ? message.token.trim() : "";
    let auth;
    try { auth = this._auth(proposedCLI, proposedToken); }
    catch (error) { this.errorMessage = errorText(error); this._emit(); return; }
    const epoch = this._invalidateReads();
    const controller = new AbortController();
    this.requestController = controller;
    this.isLoading = true;
    this.errorMessage = "";
    this._clearMutationFeedback(false);
    this._emit();
    try {
      const result = await this.client.fetchProject(requestedURL, auth, { signal: controller.signal });
      if (epoch !== this.generation || this.closed) return;
      if (!validSnapshot(result, requestedURL)) throw new Error("GitHub returned a different project. The current project was kept unchanged.");
      if (!proposedCLI && proposedToken) this.persistence.setToken(proposedToken);
      this.useCLI = proposedCLI;
      this.isDemo = false;
      this._commitProject(result);
      this.showSettings = false;
      this._upsertProject(result.project.url, result.title);
      this._saveSettings();
      try { this.persistence.saveCache(result.project.url, clone(result)); }
      catch (error) { this.errorMessage = `Connected, but the local cache could not be saved. ${errorText(error)}`; }
    } catch (error) {
      if (epoch === this.generation && !controller.signal.aborted) this.errorMessage = errorText(error);
    } finally {
      if (epoch === this.generation) {
        this.requestController = null;
        this.pendingProjectURL = "";
        this.isLoading = false;
        this._emit();
      }
    }
  }

  async _selectProject(rawURL) {
    if (!this._allowSessionChange()) return;
    const candidate = this.projects.find((project) => projectKey(project.url) === projectKey(rawURL));
    if (!candidate || projectKey(candidate.url) === projectKey(this.projectURL)) return;
    if (this.isDemo) {
      const next = this.demoData?.snapshots[candidate.url];
      if (!next) return;
      this.pendingProjectURL = candidate.url;
      this.isLoading = true;
      this._emit();
      this._commitProject(clone(next));
      this.projects = clone(this.demoData.projects);
      this.isDemo = true;
      this.pendingProjectURL = "";
      this.isLoading = false;
      this._emit();
      return;
    }
    const epoch = this._invalidateReads();
    const controller = new AbortController();
    this.requestController = controller;
    this.pendingProjectURL = candidate.url;
    this.isLoading = true;
    this.errorMessage = "";
    this._emit();
    try {
      const result = await this.client.fetchProject(candidate.url, this._auth(), { signal: controller.signal });
      if (epoch !== this.generation || this.closed) return;
      if (!validSnapshot(result, candidate.url)) throw new Error("GitHub returned a different project. The current project was kept unchanged.");
      this._commitProject(result);
      this._upsertProject(result.project.url, result.title);
      this._saveSettings();
      try { this.persistence.saveCache(result.project.url, clone(result)); }
      catch (error) { this.errorMessage = `Project switched, but the local cache could not be saved. ${errorText(error)}`; }
    } catch (error) {
      if (epoch === this.generation && !controller.signal.aborted) this.errorMessage = errorText(error);
    } finally {
      if (epoch === this.generation) {
        this.requestController = null;
        this.pendingProjectURL = "";
        this.isLoading = false;
        this._emit();
      }
    }
  }

  _commitProject(snapshot) {
    this.projectURL = snapshot.project.url;
    this.snapshot = clone(snapshot);
    this.isConfigured = true;
    this.errorMessage = "";
    this.selectedIssueID = "";
    this.pinnedIssueID = "";
    this.search = "";
    this._clearMutationFeedback(false);
    this._cancelComposer(true);
  }

  _upsertProject(url, title) {
    const key = projectKey(url);
    const item = this.projects.find((project) => projectKey(project.url) === key);
    if (item) item.title = title || item.title;
    else this.projects.push({ url, title: title || url });
  }

  async _disconnect() {
    if (!this._allowSessionChange()) return;
    if (this.isDemo) { await this._leaveDemo(); return; }
    const removedURL = this.projectURL;
    const key = projectKey(removedURL);
    const remaining = this.projects.filter((project) => projectKey(project.url) !== key);
    if (!remaining.length) {
      try { this.persistence.deleteToken(); }
      catch (error) { this.errorMessage = `Could not remove the saved token. ${errorText(error)}`; this._emit(); return; }
    }
    this._invalidateReads();
    this.projects = remaining;
    delete this.hiddenStatusNamesByProject[key];
    for (const context of this.attachmentContexts.keys()) if (context.startsWith(`${key}|`)) this.attachmentContexts.delete(context);
    try { this.persistence.removeCache(removedURL); } catch { /* Removing stale cache is best effort. */ }
    if (remaining.length) {
      this.projectURL = remaining[0].url;
      let cached = null;
      try { cached = this.persistence.loadCache(this.projectURL); } catch { /* Refresh reports a usable error. */ }
      this.snapshot = validSnapshot(cached, this.projectURL) ? cached : null;
      this.isConfigured = true;
    } else {
      this.projectURL = "";
      this.snapshot = null;
      this.isConfigured = false;
    }
    this.isDemo = false;
    this.showSettings = false;
    this.selectedIssueID = "";
    this.pinnedIssueID = "";
    this.search = "";
    this.errorMessage = "";
    this._saveSettings();
    this._emit();
    if (this.isConfigured) await this._refresh();
  }

  _enterDemo() {
    if (!this._allowSessionChange()) return;
    this._invalidateReads();
    this.demoData = createDemoData();
    this.projects = clone(this.demoData.projects);
    this.isDemo = true;
    this.useCLI = true;
    this.onlyMine = true;
    this.alwaysOnTop = true;
    this.inProgressStatuses = "In progress, Doing";
    this.todoStatuses = "Todo, To do, Backlog, Ready";
    this._commitProject(this.demoData.snapshots[this.projects[0].url]);
    this.projects = clone(this.demoData.projects);
    this.isDemo = true;
    this.pinnedIssueID = "demo-42";
    this._emit();
  }

  async _leaveDemo() {
    if (!this._allowSessionChange()) return;
    this._invalidateReads();
    this._resetLiveState();
    this._restore();
    this._emit();
    if (this.isConfigured) await this._refresh();
  }

  _resetLiveState() {
    this.projectURL = ""; this.projects = []; this.snapshot = null; this.isConfigured = false; this.isDemo = false;
    this.selectedIssueID = ""; this.pinnedIssueID = ""; this.search = ""; this.showSettings = false;
    this.errorMessage = ""; this.pendingProjectURL = ""; this.composerRepository = ""; this.composerMetadata = null;
    this.composerLoading = false; this.composerError = ""; this.attachmentError = ""; this.demoData = null;
    this.demoHiddenStatusNamesByProject = {}; this.attachmentContexts = new Map();
    this._clearMutationFeedback(false);
  }

  async _selectIssue(rawID) {
    const id = rawID == null ? "" : String(rawID);
    this.selectedIssueID = this.snapshot?.issues?.some((issue) => String(issue.id) === id) ? id : "";
    this._emit();
    const issue = this.snapshot?.issues?.find((candidate) => String(candidate.id) === this.selectedIssueID);
    if (issue) await this._loadComposer(issue.repository);
  }

  async _loadComposer(rawRepository) {
    const repository = repositoryName(rawRepository);
    if (!repository) {
      this._cancelComposer(true);
      this.composerError = "Choose a repository in owner/repository format.";
      this._emit();
      return;
    }
    if (this.composerRepository.toLowerCase() === repository.toLowerCase() && (this.composerMetadata || this.composerLoading)) return;
    this._cancelComposer(true);
    this.composerRepository = repository;
    this.attachmentError = "";
    const epoch = this.composerGeneration;
    const projectEpoch = this.generation;
    if (this.isDemo) {
      this.composerMetadata = clone(this.demoData?.composers[repository] || null);
      this.composerError = this.composerMetadata ? "" : "This demo repository does not expose composer metadata.";
      this._emit();
      return;
    }
    const controller = new AbortController();
    this.composerController = controller;
    this.composerLoading = true;
    this.composerError = "";
    this._emit();
    try {
      const metadata = await this.client.fetchIssueComposer(repository, this._auth(), { signal: controller.signal });
      if (epoch !== this.composerGeneration || projectEpoch !== this.generation || this.closed) return;
      if (String(metadata?.repository || "").toLowerCase() !== repository.toLowerCase()) throw new Error("GitHub returned metadata for a different repository. Try again.");
      this.composerMetadata = clone(metadata);
    } catch (error) {
      if (epoch === this.composerGeneration && projectEpoch === this.generation && !controller.signal.aborted) this.composerError = errorText(error);
    } finally {
      if (epoch === this.composerGeneration) {
        this.composerController = null;
        this.composerLoading = false;
        this._emit();
      }
    }
  }

  _allowSessionChange() {
    if (!this.isMutating) return true;
    this.mutationError = "Please wait for the GitHub update to finish before switching projects or accounts.";
    this._emit();
    return false;
  }

  _beginMutation() {
    if (this.isMutating) return false;
    if (this.pendingProjectURL) {
      this.mutationError = "Wait for the selected project to finish loading.";
      this._emit();
      return false;
    }
    this._invalidateReads({ composer: false });
    this.isMutating = true;
    this.mutationError = "";
    this.mutationNotice = "";
    this.createdIssueURL = "";
    this._emit();
    return true;
  }

  _finishMutation() {
    this.isMutating = false;
    this._emit();
  }

  async _changeStatus(message) {
    if (this.isMutating) return;
    const issue = this.snapshot?.issues?.find((candidate) => String(candidate.id) === String(message.id || ""));
    const metadata = this.snapshot?.metadata;
    const field = metadata?.statusField;
    const optionID = typeof message.optionID === "string" ? message.optionID : "";
    const option = field?.options?.find((candidate) => candidate.id === optionID);
    if (!issue || !metadata?.id || !field?.id || (optionID && !option)) {
      this.mutationError = "Refresh the project to load its available status options."; this._emit(); return;
    }
    if (this.isDemo) {
      issue.status = option?.name || "";
      issue.updatedAt = new Date().toISOString();
      this.mutationError = "";
      this.mutationNotice = "Status updated in demo.";
      this._emit();
      return;
    }
    if (!issue.projectItemID) { this.mutationError = "Refresh this issue before changing its project status."; this._emit(); return; }
    if (!this._beginMutation()) return;
    try {
      await this.client.updateStatus({ projectID: metadata.id, itemID: issue.projectItemID, fieldID: field.id, optionID }, this._auth());
      issue.status = option?.name || "";
      issue.updatedAt = new Date().toISOString();
      this.mutationNotice = "Status saved to GitHub.";
      this._saveMutationCache();
    } catch (error) { this.mutationError = errorText(error); }
    finally { this._finishMutation(); }
  }

  async _updateAssignees(message) {
    if (this.isMutating) return;
    const issue = this.snapshot?.issues?.find((candidate) => String(candidate.id) === String(message.id || ""));
    const metadata = this.composerMetadata;
    const ids = uniqueStrings(message.assigneeIDs, 11);
    const valid = issue && metadata && metadata.repository.toLowerCase() === String(issue.repository).toLowerCase() && ids.length <= 10 && ids.every((id) => metadata.assignees.some((choice) => choice.id === id));
    if (!valid) { this.mutationError = "Load this repository's assignable users before saving."; this._emit(); return; }
    if (this.isDemo) {
      issue.assignees = metadata.assignees.filter((choice) => ids.includes(choice.id)).map((choice) => choice.name);
      issue.updatedAt = new Date().toISOString();
      this.mutationError = ""; this.mutationNotice = "Assignees updated in demo."; this._emit(); return;
    }
    if (!this._beginMutation()) return;
    try {
      const users = await this.client.updateAssignees(issue.id, ids, this._auth());
      issue.assignees = users.map((user) => user.name);
      issue.updatedAt = new Date().toISOString();
      this.mutationNotice = "Assignees saved to GitHub.";
      this._saveMutationCache();
    } catch (error) { this.mutationError = errorText(error); }
    finally { this._finishMutation(); }
  }

  _validateCreation(message) {
    const repository = repositoryName(message.repository);
    const title = typeof message.title === "string" ? message.title.trim() : "";
    const body = typeof message.body === "string" ? message.body : "";
    const project = this.snapshot?.metadata;
    const metadata = this.composerMetadata;
    if (!repository || !project?.id || !metadata || metadata.repository.toLowerCase() !== repository.toLowerCase()) throw new Error("Wait for this repository's options to load before creating an issue.");
    if (!title || title.length > 256 || Buffer.byteLength(body) > 65_536) throw new Error("Add a title of up to 256 characters and a description smaller than 64 KB.");
    const assigneeIDs = uniqueStrings(message.assigneeIDs);
    if (message.assignToMe === true && project.viewerID && !assigneeIDs.includes(project.viewerID)) assigneeIDs.push(project.viewerID);
    const labelIDs = uniqueStrings(message.labelIDs);
    const additionalProjectIDs = uniqueStrings(message.additionalProjectIDs);
    const milestoneID = optionalString(message.milestoneID);
    const issueTypeID = optionalString(message.issueTypeID);
    const templateFilename = optionalString(message.templateFilename);
    const statusOptionID = optionalString(message.optionID);
    const selectionsAreValid = assigneeIDs.length <= 10 && assigneeIDs.every((id) => metadata.assignees.some((choice) => choice.id === id)) &&
      labelIDs.every((id) => metadata.labels.some((choice) => choice.id === id)) &&
      additionalProjectIDs.every((id) => metadata.projects.some((choice) => choice.id === id)) &&
      (!milestoneID || metadata.milestones.some((choice) => choice.id === milestoneID)) &&
      (!issueTypeID || metadata.issueTypes.some((choice) => choice.id === issueTypeID)) &&
      (!templateFilename || metadata.templates.some((template) => template.filename === templateFilename)) &&
      (!statusOptionID || project.statusField?.options?.some((option) => option.id === statusOptionID));
    if (!selectionsAreValid) throw new Error("Some selections belong to another repository or are no longer available. Reload the options.");
    return {
      projectID: project.id, repository, title, body, assigneeIDs, labelIDs, milestoneID, issueTypeID,
      templateFilename, additionalProjectIDs, parentIssue: optionalString(message.parentIssue),
      blockedBy: uniqueStrings(message.blockedBy), blocking: uniqueStrings(message.blocking),
      statusFieldID: statusOptionID ? project.statusField?.id || null : null, statusOptionID,
    };
  }

  async _createIssue(message) {
    if (this.isMutating) return;
    let request;
    try { request = this._validateCreation(message); }
    catch (error) { this.mutationError = errorText(error); this._emit(); return; }
    if (this.isDemo) {
      const number = Math.max(0, ...this.snapshot.issues.map((issue) => Number(issue.number) || 0)) + 1;
      const status = this.snapshot.metadata.statusField?.options?.find((option) => option.id === request.statusOptionID)?.name || "";
      const metadata = this.composerMetadata;
      const issue = { id: `demo-${randomUUID()}`, number, title: request.title, body: request.body, url: `https://github.com/${request.repository}/issues/${number}`, repository: request.repository, status, labels: metadata.labels.filter((choice) => request.labelIDs.includes(choice.id)).map((choice) => choice.name), assignees: metadata.assignees.filter((choice) => request.assigneeIDs.includes(choice.id)).map((choice) => choice.name), updatedAt: new Date().toISOString(), projectItemID: `demo-item-${number}` };
      this.snapshot.issues.unshift(issue);
      this.attachmentContexts.delete(this._attachmentContext());
      this.creationRevision += 1;
      this.createdIssueURL = issue.url;
      this.mutationError = "";
      this.mutationNotice = "Issue created in demo. Nothing was sent to GitHub.";
      this._emit();
      return;
    }
    if (!this._beginMutation()) return;
    const attachmentContext = this._attachmentContext();
    const attachments = this._currentAttachments();
    let createStarted = false;
    try {
      let body = request.body;
      for (const attachment of attachments) {
        if (!attachment.uploadedURL) attachment.uploadedURL = await this.client.uploadAttachment(request.repository, attachment.filePath, this._auth());
        const name = attachment.name.replaceAll("\\", "\\\\").replaceAll("[", "\\[").replaceAll("]", "\\]").replaceAll("\n", " ");
        const markdown = VIDEO_EXTENSIONS.has(extname(attachment.name).toLowerCase()) ? attachment.uploadedURL : `![${name}](${attachment.uploadedURL})`;
        body += `\n\n${markdown}`;
      }
      if (Buffer.byteLength(body) > 65_536) throw new Error("The description with attachments exceeds 64 KB. Shorten it before creating the issue.");
      createStarted = true;
      const result = await this.client.createIssue({ ...request, body }, this._auth());
      const target = safeGitHubURL(result?.url);
      if (!target) throw new Error("GitHub confirmed issue creation without a usable issue URL. Check the repository before retrying.");
      this.attachmentContexts.delete(attachmentContext);
      this.createdIssueURL = target.toString();
      this.creationRevision += 1;
      this.mutationNotice = result.warning || "Issue created and added to the project.";
      if (this.onlyMine && !request.assigneeIDs.includes(this.snapshot.metadata.viewerID || "")) this.mutationNotice += " Switch to Everyone to see issues assigned to others.";
    } catch (error) {
      this.mutationError = `${errorText(error)}${createStarted ? "" : " No issue was created."}`;
    } finally { this._finishMutation(); }
  }

  _saveMutationCache() {
    if (this.isDemo || !this.snapshot) return;
    try { this.persistence.saveCache(this.projectURL, clone(this.snapshot)); }
    catch { this.mutationNotice = "Saved to GitHub. The local cache could not be updated."; }
  }

  _clearMutationFeedback(emit = true) {
    if (this.isMutating) return;
    this.mutationError = "";
    this.mutationNotice = "";
    this.createdIssueURL = "";
    if (emit) this._emit();
  }

  _pin(rawID) {
    const id = String(rawID || "");
    if (!this.snapshot?.issues?.some((issue) => String(issue.id) === id)) return;
    this.pinnedIssueID = id;
    this._saveSettings();
    this._emit();
  }

  async _openIssue(rawID) {
    if (this.isDemo) return;
    const issue = this.snapshot?.issues?.find((candidate) => String(candidate.id) === String(rawID || ""));
    const url = safeGitHubURL(issue?.url);
    if (url) await this.openExternal(url.toString());
  }

  async _openProject() {
    if (this.isDemo) return;
    const url = safeGitHubURL(this.projectURL);
    if (url) await this.openExternal(url.toString());
  }

  async _openCreatedIssue() {
    if (this.isDemo) return;
    const url = safeGitHubURL(this.createdIssueURL);
    if (url) await this.openExternal(url.toString());
  }

  async _openComposerOnGitHub(message) {
    if (this.isMutating) return;
    const repository = repositoryName(message.repository);
    if (!repository) return;
    const url = new URL(`https://github.com/${repository}/issues/new`);
    const metadata = this.composerMetadata?.repository?.toLowerCase() === repository.toLowerCase() ? this.composerMetadata : null;
    const add = (name, value) => { if (value) url.searchParams.set(name, value); };
    add("title", typeof message.title === "string" ? message.title : "");
    add("body", typeof message.body === "string" ? message.body : "");
    add("template", typeof message.templateFilename === "string" ? message.templateFilename : "");
    if (metadata) {
      const assigneeIDs = uniqueStrings(message.assigneeIDs);
      const labelIDs = uniqueStrings(message.labelIDs);
      add("assignees", metadata.assignees.filter((choice) => assigneeIDs.includes(choice.id)).map((choice) => choice.name).join(","));
      add("labels", metadata.labels.filter((choice) => labelIDs.includes(choice.id)).map((choice) => choice.name).join(","));
      add("milestone", metadata.milestones.find((choice) => choice.id === message.milestoneID)?.name || "");
    }
    const projects = [];
    const active = this.projectURL.match(PROJECT_URL);
    if (active) projects.push(`${active[2]}/${Number(active[3])}`);
    if (metadata) {
      const selected = new Set(uniqueStrings(message.additionalProjectIDs));
      for (const item of metadata.projects.filter((project) => selected.has(project.id))) {
        const match = item.url.match(PROJECT_URL);
        const name = match ? `${match[2]}/${Number(match[3])}` : "";
        if (name && !projects.includes(name)) projects.push(name);
      }
    }
    add("projects", projects.join(","));
    if (Buffer.byteLength(url.toString()) > 7_000 && url.searchParams.has("body")) {
      await this.copyText(url.searchParams.get("body"));
      url.searchParams.delete("body");
      this.mutationNotice = "Your description was copied. Paste it into GitHub to continue; the draft is still here.";
    }
    try { await this.openExternal(url.toString()); }
    catch { this.mutationError = "Could not open GitHub. Your draft is still available here."; }
    this._emit();
  }

  _setStatusVisibility(rawName, visible) {
    const name = typeof rawName === "string" ? rawName : "";
    if (!this._statusVisibility().some((row) => row.name === name)) return;
    const target = this.isDemo ? this.demoHiddenStatusNamesByProject : this.hiddenStatusNamesByProject;
    const key = projectKey(this.projectURL);
    const hidden = new Set(Array.isArray(target[key]) ? target[key] : []);
    if (visible === false) hidden.add(name); else hidden.delete(name);
    target[key] = [...hidden];
    if (!this.isDemo) this._saveSettings();
    this._emit();
  }

  _preference(key, value) {
    switch (key) {
      case "onlyMine": if (typeof value === "boolean") this.onlyMine = value; else return; break;
      case "alwaysOnTop": if (typeof value === "boolean") this.alwaysOnTop = value; else return; break;
      case "search": if (typeof value === "string") this.search = value.slice(0, 1_000); else return; break;
      case "inProgressStatuses": if (typeof value === "string") this.inProgressStatuses = value.slice(0, 2_000); else return; break;
      case "todoStatuses": if (typeof value === "string") this.todoStatuses = value.slice(0, 2_000); else return; break;
      default: return;
    }
    if (!this.isDemo) this._saveSettings();
    this._emit();
  }

  _saveSettings() {
    if (this.isDemo) return;
    try {
      this.persistence.saveSettings({
        projectURL: this.projectURL,
        projects: clone(this.projects),
        useCLI: this.useCLI,
        onlyMine: this.onlyMine,
        alwaysOnTop: this.alwaysOnTop,
        pinnedIssueID: this.pinnedIssueID,
        inProgressStatuses: this.inProgressStatuses,
        todoStatuses: this.todoStatuses,
        hiddenStatusNamesByProject: clone(this.hiddenStatusNamesByProject),
      });
    } catch (error) { this.errorMessage = `Could not save settings. ${errorText(error)}`; }
  }

  _accountIssues() {
    const issues = Array.isArray(this.snapshot?.issues) ? this.snapshot.issues : [];
    if (!this.onlyMine) return issues;
    const viewer = String(this.snapshot?.viewerLogin || "").toLowerCase();
    return issues.filter((issue) => issue.assignees?.some((name) => String(name).toLowerCase() === viewer));
  }

  _issueState(issue) {
    return {
      id: String(issue.id), number: Number(issue.number) || 0, title: String(issue.title || "Untitled issue"),
      body: String(issue.body || ""), url: String(issue.url || ""), repository: String(issue.repository || ""),
      status: String(issue.status || ""), labels: Array.isArray(issue.labels) ? issue.labels.filter((label) => typeof label === "string") : [],
      assignees: Array.isArray(issue.assignees) ? issue.assignees.filter((name) => typeof name === "string") : [], group: this._group(issue.status),
    };
  }

  _group(status) {
    const name = String(status || "").trim().toLowerCase();
    const values = (source) => source.split(",").map((item) => item.trim().toLowerCase()).filter(Boolean);
    if (values(this.inProgressStatuses).includes(name)) return "inProgress";
    if (values(this.todoStatuses).includes(name)) return "todo";
    return "other";
  }

  _statusVisibility() {
    const names = [];
    const seen = new Set();
    const add = (raw) => {
      const name = typeof raw === "string" ? raw : "";
      const key = name.trim().toLowerCase();
      if (key && seen.has(key)) return;
      if (!key && seen.has("__empty__")) return;
      seen.add(key || "__empty__");
      names.push(name);
    };
    this.snapshot?.metadata?.statusField?.options?.forEach((option) => add(option.name));
    this.snapshot?.issues?.forEach((issue) => add(issue.status));
    add("");
    const source = this.isDemo ? this.demoHiddenStatusNamesByProject : this.hiddenStatusNamesByProject;
    const hidden = new Set(Array.isArray(source[projectKey(this.projectURL)]) ? source[projectKey(this.projectURL)] : []);
    return names.map((name) => ({ name, visible: !hidden.has(name) }));
  }

  _lastSyncLabel() {
    if (this.isDemo) return "Demo · sample data";
    if (this.isLoading) return "Syncing…";
    if (!this.snapshot?.fetchedAt) return "Not synced yet";
    const date = new Date(this.snapshot.fetchedAt);
    return Number.isNaN(date.valueOf()) ? "Updated" : `Updated ${date.toLocaleString()}`;
  }

  _attachmentContext() {
    return `${projectKey(this.projectURL)}|${this.composerRepository.toLowerCase()}`;
  }

  _currentAttachments() {
    return this.attachmentContexts.get(this._attachmentContext()) || [];
  }

  _removeAttachment(rawID) {
    if (this.isMutating) return;
    const id = String(rawID || "");
    this.attachmentContexts.set(this._attachmentContext(), this._currentAttachments().filter((attachment) => attachment.id !== id));
    this.attachmentError = "";
    this._emit();
  }
}
