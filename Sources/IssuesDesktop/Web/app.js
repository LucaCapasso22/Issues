(() => {
  "use strict";

  const byId = (id) => document.getElementById(id);
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const knownModes = new Set(["main", "icon", "focus", "preview"]);
  const activeAnimations = new Map();
  const demoRequested = new URLSearchParams(window.location.search).get("demo") === "1";

  const nodes = {
    main: byId("main-view"),
    icon: byId("icon-view"),
    focus: byId("focus-view"),
    preview: byId("preview-view"),
    projectSelect: byId("project-select"),
    refresh: byId("refresh-button"),
    settingsButton: byId("settings-button"),
    listHeading: byId("list-heading"),
    settingsHeading: byId("settings-heading"),
    summary: byId("summary"),
    demoBadge: byId("demo-badge"),
    onboarding: byId("onboarding-view"),
    onboardingError: byId("onboarding-error"),
    onboardingErrorMessage: byId("onboarding-error-message"),
    issuesView: byId("issues-view"),
    settingsView: byId("settings-view"),
    settingsError: byId("settings-error"),
    settingsErrorMessage: byId("settings-error-message"),
    settingsBack: byId("settings-back"),
    errorBanner: byId("error-banner"),
    errorMessage: byId("error-message"),
    errorRetry: byId("error-retry"),
    search: byId("search-input"),
    loading: byId("loading-state"),
    issueList: byId("issue-list"),
    footer: byId("app-footer"),
    filterMine: byId("filter-mine"),
    filterEveryone: byId("filter-everyone"),
    newIssueButton: byId("new-issue-button"),
    lastSync: byId("last-sync"),
    minimize: byId("minimize-button"),
    onboardingForm: byId("onboarding-form"),
    onboardingProject: byId("onboarding-project"),
    onboardingToken: byId("onboarding-token"),
    onboardingTokenLabel: byId("onboarding-token-label"),
    onboardingCLIHelp: byId("onboarding-cli-help"),
    demo: byId("demo-button"),
    settingsForm: byId("settings-form"),
    settingsProject: byId("settings-project"),
    settingsToken: byId("settings-token"),
    settingsTokenLabel: byId("settings-token-label"),
    settingsCLIHelp: byId("settings-cli-help"),
    savedTokenLabel: byId("saved-token-label"),
    connectionStatus: byId("connection-status"),
    connectionSectionTitle: byId("connection-section-title"),
    saveConnection: byId("save-connection-button"),
    addProject: byId("add-project-button"),
    cancelAddProject: byId("cancel-add-project"),
    statusVisibilityList: byId("status-visibility-list"),
    inProgressStatuses: byId("in-progress-statuses"),
    todoStatuses: byId("todo-statuses"),
    alwaysOnTop: byId("always-on-top"),
    disconnect: byId("disconnect-button"),
    leaveDemo: byId("leave-demo-button"),
    quit: byId("quit-button"),
    orb: byId("orb-button"),
    orbBadge: byId("orb-badge"),
    focusButton: byId("focus-button"),
    focusNumber: byId("focus-number"),
    focusTitle: byId("focus-title"),
    previewCount: byId("preview-count"),
    previewList: byId("preview-list"),
    previewEmpty: byId("preview-empty"),
    previewOrb: byId("preview-orb"),
    previewBadge: byId("preview-badge"),
    mutationBanner: byId("mutation-banner"),
    mutationNotice: byId("mutation-notice"),
    openCreatedIssue: byId("open-created-issue"),
    issueDialog: byId("issue-dialog"),
    issueDialogClose: byId("issue-dialog-close"),
    issueDialogMeta: byId("issue-dialog-meta"),
    issueDialogTitle: byId("issue-dialog-title"),
    issueDialogScroll: byId("issue-dialog-scroll"),
    issueDialogBody: byId("issue-dialog-body"),
    detailMutationError: byId("detail-mutation-error"),
    detailStatusLabel: byId("detail-status-label"),
    detailStatus: byId("detail-status-select"),
    detailPin: byId("detail-pin"),
    detailPinLabel: byId("detail-pin-label"),
    detailOpen: byId("detail-open"),
    detailAssignSelf: byId("detail-assign-self"),
    detailAssigneeSave: byId("detail-assignee-save"),
    detailAssigneeSearch: byId("detail-assignee-search"),
    detailAssigneeChoices: byId("detail-assignee-choices"),
    detailAssigneeHelp: byId("detail-assignee-help"),
    newIssueDialog: byId("new-issue-dialog"),
    newIssueForm: byId("new-issue-form"),
    newIssueClose: byId("new-issue-close"),
    newIssueCancel: byId("new-issue-cancel"),
    newIssueSubmit: byId("new-issue-submit"),
    newIssueRepository: byId("new-issue-repository"),
    repositorySuggestions: byId("repository-suggestions"),
    newIssueTitle: byId("new-issue-title-input"),
    newIssueBody: byId("new-issue-body"),
    newIssueStatus: byId("new-issue-status"),
    createMutationError: byId("create-mutation-error"),
    composerScroll: byId("composer-scroll"),
    composerLoading: byId("composer-loading"),
    composerMetadataError: byId("composer-metadata-error"),
    composerWarnings: byId("composer-warnings"),
    composerTemplate: byId("composer-template"),
    composerWriteTab: byId("composer-write-tab"),
    composerPreviewTab: byId("composer-preview-tab"),
    composerToolbar: byId("composer-toolbar"),
    composerPreview: byId("composer-preview"),
    composerGitHubHandoff: byId("composer-github-handoff"),
    composerHandoffCopy: byId("composer-handoff-copy"),
    composerChooseAttachments: byId("composer-choose-attachments"),
    composerAttachmentList: byId("composer-attachment-list"),
    composerAttachmentError: byId("composer-attachment-error"),
    composerAssignSelf: byId("composer-assign-self"),
    composerAssigneeSearch: byId("composer-assignee-search"),
    composerAssigneeChoices: byId("composer-assignee-choices"),
    composerDetails: byId("composer-details"),
    composerDetailCount: byId("composer-detail-count"),
    composerLabelChoices: byId("composer-label-choices"),
    composerType: byId("composer-type"),
    composerMilestone: byId("composer-milestone"),
    composerProjectChoices: byId("composer-project-choices"),
    composerParent: byId("composer-parent"),
    composerBlockedBy: byId("composer-blocked-by"),
    composerBlocking: byId("composer-blocking"),
    composerCreateAnother: byId("composer-create-another"),
    composerSuccess: byId("composer-success"),
    composerSuccessCopy: byId("composer-success-copy"),
    composerOpenCreated: byId("composer-open-created"),
  };

  let state = normalizeState({ mode: "main" });
  let currentMode = "";
  let currentMainScene = "";
  let lastListSignature = "";
  let suppressClickUntil = 0;
  let isAddingProject = false;
  let previousCreationRevision = null;
  let detailReturnIssueID = "";
  let createSubmissionPending = false;
  let statusSubmissionPending = false;
  let assignmentSubmissionPending = false;
  let detailAssigneeIssueID = "";
  let detailAssigneeNames = [];
  let detailAssigneeMetadataSignature = "";
  let detailAssigneeIDs = new Set();
  let composerRepository = "";
  let composerProjectURL = "";
  let composerLoadTimer = 0;
  let composerMetadataSignature = "";
  let composerMode = "write";
  let lastSubmittedCreateAnother = false;
  const composerDrafts = new Map();
  const composerSelection = {
    assigneeIDs: new Set(),
    labelIDs: new Set(),
    additionalProjectIDs: new Set(),
  };
  const dirtyFields = new WeakSet();
  const collapsedSections = new Set();

  const iconPaths = {
    github: '<path d="M8 14.5c-3.3.9-3.3-1.7-4.6-2.1m9.2 3.6v-2.3c0-.7.1-1.1-.3-1.6 2.7-.3 5.5-1.3 5.5-6A4.7 4.7 0 0 0 16.5 3c.1-.3.5-1.5-.1-3 0 0-1.1-.4-3.5 1.2a12.2 12.2 0 0 0-6.4 0C4.1-.4 3 0 3 0c-.6 1.5-.2 2.7-.1 3A4.7 4.7 0 0 0 1.6 6.1c0 4.7 2.8 5.7 5.5 6-.3.4-.4.8-.4 1.4V16" transform="translate(2 2) scale(.83)"/>',
    refresh: '<path d="M18 8a7 7 0 1 0 1 5"/><path d="M18 3v5h-5"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1a1.7 1.7 0 0 0 1.9.3A1.7 1.7 0 0 0 10 3V2.8h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/>',
    alert: '<path d="M10.3 3.7 2.4 17.3A2 2 0 0 0 4.1 20h15.8a2 2 0 0 0 1.7-2.7L13.7 3.7a2 2 0 0 0-3.4 0Z"/><path d="M12 9v4m0 3h.01"/>',
    user: '<path d="M20 21a8 8 0 0 0-16 0"/><circle cx="12" cy="7" r="4"/>',
    minimize: '<path d="M8 3v5H3m13-5v5h5M8 21v-5H3m13 5v-5h5"/>',
    "circle-dot": '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3" fill="currentColor" stroke="none"/>',
    circle: '<circle cx="12" cy="12" r="9"/>',
    pin: '<path d="M12 17v5m-5-9 2-2V5L7 3h10l-2 2v6l2 2Z"/>',
    external: '<path d="M15 3h6v6m0-6-9 9"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>',
    "chevron-left": '<path d="m15 18-6-6 6-6"/>',
    expand: '<path d="M8 3H3v5m13-5h5v5M8 21H3v-5m18 0v5h-5"/>',
    inbox: '<path d="M4 4h16l2 10v6H2v-6Zm-2 10h5l2 3h6l2-3h5"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    close: '<path d="m6 6 12 12M18 6 6 18"/>',
  };

  function makeIcon(name) {
    const wrapper = document.createElement("span");
    wrapper.setAttribute("aria-hidden", "true");
    wrapper.innerHTML = `<svg viewBox="0 0 24 24" focusable="false">${iconPaths[name] || iconPaths.circle}</svg>`;
    return wrapper.firstElementChild;
  }

  function hydrateStaticIcons() {
    document.querySelectorAll("[data-icon]").forEach((holder) => {
      const icon = makeIcon(holder.dataset.icon);
      holder.replaceChildren(icon);
    });
  }

  function normalizeState(next) {
    const value = next && typeof next === "object" ? next : {};
    return {
      mode: knownModes.has(value.mode) ? value.mode : "main",
      previewHorizontal: value.previewHorizontal === "right" ? "right" : "left",
      previewVertical: value.previewVertical === "below" ? "below" : "above",
      projectTitle: typeof value.projectTitle === "string" ? value.projectTitle : "GitHub Issues",
      projectURL: typeof value.projectURL === "string" ? value.projectURL : "",
      pendingProjectURL: typeof value.pendingProjectURL === "string" ? value.pendingProjectURL : "",
      projects: normalizeProjects(value.projects, value.projectURL, value.projectTitle),
      viewerLogin: typeof value.viewerLogin === "string" ? value.viewerLogin : "",
      isConfigured: Boolean(value.isConfigured),
      isDemo: Boolean(value.isDemo),
      isLoading: Boolean(value.isLoading),
      errorMessage: typeof value.errorMessage === "string" ? value.errorMessage : "",
      lastSyncLabel: typeof value.lastSyncLabel === "string" ? value.lastSyncLabel : "",
      onlyMine: Boolean(value.onlyMine),
      search: typeof value.search === "string" ? value.search : "",
      selectedIssueID: value.selectedIssueID == null ? "" : String(value.selectedIssueID),
      pinnedIssueID: value.pinnedIssueID == null ? "" : String(value.pinnedIssueID),
      alwaysOnTop: Boolean(value.alwaysOnTop),
      showSettings: Boolean(value.showSettings),
      useCLI: value.useCLI !== false,
      hasSavedToken: Boolean(value.hasSavedToken),
      inProgressStatuses: statusText(value.inProgressStatuses),
      todoStatuses: statusText(value.todoStatuses),
      statusOptions: Array.isArray(value.statusOptions) ? value.statusOptions.map(normalizeStatusOption).filter(Boolean) : [],
      statusVisibility: Array.isArray(value.statusVisibility) ? value.statusVisibility.map(normalizeStatusVisibility).filter(Boolean) : [],
      statusFieldName: typeof value.statusFieldName === "string" && value.statusFieldName ? value.statusFieldName : "Status",
      canEditStatus: Boolean(value.canEditStatus),
      repositories: Array.isArray(value.repositories) ? value.repositories.filter((repository) => typeof repository === "string" && repository.trim()) : [],
      isMutating: Boolean(value.isMutating),
      mutationError: typeof value.mutationError === "string" ? value.mutationError : "",
      mutationNotice: typeof value.mutationNotice === "string" ? value.mutationNotice : "",
      createdIssueURL: typeof value.createdIssueURL === "string" ? value.createdIssueURL : "",
      creationRevision: Number.isFinite(Number(value.creationRevision)) ? Number(value.creationRevision) : 0,
      detailIssue: value.detailIssue && typeof value.detailIssue === "object" ? normalizeIssue(value.detailIssue, -1) : null,
      composerRepository: typeof value.composerRepository === "string" ? value.composerRepository : "",
      composerMetadata: normalizeComposerMetadata(value.composerMetadata),
      composerLoading: Boolean(value.composerLoading),
      composerError: typeof value.composerError === "string" ? value.composerError : "",
      composerAttachments: Array.isArray(value.composerAttachments) ? value.composerAttachments.map(normalizeAttachment).filter(Boolean) : [],
      attachmentError: typeof value.attachmentError === "string" ? value.attachmentError : "",
      issues: Array.isArray(value.issues) ? value.issues.map(normalizeIssue) : [],
    };
  }

  function normalizeIssue(issue, index) {
    const value = issue && typeof issue === "object" ? issue : {};
    return {
      id: value.id == null ? `missing-${index}` : String(value.id),
      number: Number.isFinite(Number(value.number)) ? Number(value.number) : 0,
      title: typeof value.title === "string" ? value.title : "Untitled issue",
      body: typeof value.body === "string" ? value.body : "",
      repository: typeof value.repository === "string" ? value.repository : "",
      status: typeof value.status === "string" ? value.status : "",
      labels: Array.isArray(value.labels) ? value.labels.filter((label) => typeof label === "string") : [],
      assignees: Array.isArray(value.assignees) ? value.assignees.filter((name) => typeof name === "string") : [],
      group: ["inProgress", "todo", "other"].includes(value.group) ? value.group : "other",
    };
  }

  function normalizeStatusOption(option) {
    if (!option || typeof option !== "object" || option.id == null || typeof option.name !== "string") return null;
    return { id: String(option.id), name: option.name };
  }

  function normalizeStatusVisibility(option) {
    if (!option || typeof option !== "object" || typeof option.name !== "string") return null;
    return { name: option.name, visible: option.visible !== false };
  }

  function normalizeChoice(choice) {
    if (!choice || typeof choice !== "object" || choice.id == null || typeof choice.name !== "string") return null;
    return { id: String(choice.id), name: choice.name };
  }

  function normalizeComposerProject(project) {
    if (!project || typeof project !== "object" || project.id == null || typeof project.title !== "string") return null;
    return { id: String(project.id), title: project.title, url: typeof project.url === "string" ? project.url : "" };
  }

  function normalizeTemplate(template) {
    if (!template || typeof template !== "object" || typeof template.filename !== "string") return null;
    return {
      filename: template.filename,
      name: typeof template.name === "string" && template.name ? template.name : template.filename,
      about: typeof template.about === "string" ? template.about : "",
      body: typeof template.body === "string" ? template.body : "",
      title: typeof template.title === "string" ? template.title : "",
      assigneeIDs: stringArray(template.assigneeIDs),
      labelIDs: stringArray(template.labelIDs),
      issueTypeID: template.issueTypeID == null ? "" : String(template.issueTypeID),
    };
  }

  function normalizeComposerMetadata(metadata) {
    if (!metadata || typeof metadata !== "object" || typeof metadata.repository !== "string") return null;
    return {
      repository: metadata.repository,
      repositoryID: metadata.repositoryID == null ? "" : String(metadata.repositoryID),
      assignees: Array.isArray(metadata.assignees) ? metadata.assignees.map(normalizeChoice).filter(Boolean) : [],
      labels: Array.isArray(metadata.labels) ? metadata.labels.map(normalizeChoice).filter(Boolean) : [],
      milestones: Array.isArray(metadata.milestones) ? metadata.milestones.map(normalizeChoice).filter(Boolean) : [],
      issueTypes: Array.isArray(metadata.issueTypes) ? metadata.issueTypes.map(normalizeChoice).filter(Boolean) : [],
      projects: Array.isArray(metadata.projects) ? metadata.projects.map(normalizeComposerProject).filter(Boolean) : [],
      templates: Array.isArray(metadata.templates) ? metadata.templates.map(normalizeTemplate).filter(Boolean) : [],
      canWrite: Boolean(metadata.canWrite),
      warnings: stringArray(metadata.warnings),
    };
  }

  function normalizeAttachment(attachment) {
    if (!attachment || typeof attachment !== "object" || attachment.id == null || typeof attachment.name !== "string") return null;
    return { id: String(attachment.id), name: attachment.name, size: Math.max(0, Number(attachment.size) || 0) };
  }

  function stringArray(value) {
    return Array.isArray(value) ? value.filter((item) => typeof item === "string").map(String) : [];
  }

  function normalizeProjects(projects, activeURL, activeTitle) {
    const normalized = Array.isArray(projects) ? projects.map((project) => {
      if (!project || typeof project !== "object" || typeof project.url !== "string" || !project.url) return null;
      return { url: project.url, title: typeof project.title === "string" && project.title ? project.title : project.url };
    }).filter(Boolean) : [];
    if (activeURL && !normalized.some((project) => project.url === activeURL)) {
      normalized.unshift({ url: activeURL, title: activeTitle || activeURL });
    }
    return normalized;
  }

  function statusText(value) {
    if (Array.isArray(value)) return value.filter((item) => typeof item === "string").join(", ");
    return typeof value === "string" ? value : "";
  }

  function post(action, payload = {}) {
    const message = { action, ...payload };
    const handler = window.webkit?.messageHandlers?.issues;
    if (handler && typeof handler.postMessage === "function") handler.postMessage(message);
  }

  function cancelAnimations() {
    activeAnimations.forEach((targets, animation) => {
      try { animation.cancel(); } catch (_) { /* Animation completion can race state refreshes. */ }
      resetVisualState(targets);
    });
    activeAnimations.clear();
  }

  function resetVisualState(targets) {
    const elements = targets instanceof Element ? [targets] : Array.from(targets || []).filter((target) => target instanceof Element);
    elements.forEach((target) => {
      target.style.opacity = "1";
      target.style.transform = "none";
      target.style.removeProperty("translate");
      target.style.removeProperty("scale");
    });
    return elements;
  }

  function animate(targets, options) {
    const elements = resetVisualState(targets);
    if (reducedMotion.matches || !window.anime || typeof window.anime.animate !== "function") return null;
    try {
      const animation = window.anime.animate(elements, options);
      activeAnimations.set(animation, elements);
      const finished = typeof animation?.then === "function" ? animation : animation?.finished;
      if (finished && typeof finished.then === "function") Promise.resolve(finished).then(() => activeAnimations.delete(animation)).catch(() => {});
      return animation;
    } catch (_) {
      resetVisualState(elements);
      return null;
    }
  }

  function setMode(mode) {
    const changed = currentMode !== mode;
    if (changed) cancelAnimations();
    Object.entries({ main: nodes.main, icon: nodes.icon, focus: nodes.focus, preview: nodes.preview }).forEach(([key, node]) => {
      node.hidden = key !== mode;
    });
    document.body.className = `mode-${mode}`;
    if (mode !== "main") {
      if (nodes.issueDialog.open) nodes.issueDialog.close();
      if (nodes.newIssueDialog.open) nodes.newIssueDialog.close();
    }
    if (changed) {
      const target = { main: nodes.main, icon: nodes.icon, focus: nodes.focus, preview: nodes.preview }[mode];
      animate(target, { opacity: [0, 1], scale: [mode === "main" ? 0.992 : 0.96, 1], duration: 190, ease: "out(3)" });
      currentMode = mode;
    }
  }

  function patchInput(input, value) {
    if (document.activeElement !== input && !dirtyFields.has(input)) input.value = value;
  }

  function patchChecked(input, checked) {
    if (document.activeElement !== input && !dirtyFields.has(input)) input.checked = checked;
  }

  function activeMethod(formName, fallback) {
    return document.querySelector(`input[name="${formName}"]:checked`)?.value || fallback;
  }

  function setMethod(formName, useCLI) {
    document.querySelectorAll(`input[name="${formName}"]`).forEach((radio) => {
      if (document.activeElement !== radio && !dirtyFields.has(radio)) radio.checked = radio.value === (useCLI ? "cli" : "token");
    });
    updateTokenVisibility(formName);
  }

  function updateTokenVisibility(formName) {
    const isOnboarding = formName === "onboarding-method";
    const token = isOnboarding ? nodes.onboardingToken : nodes.settingsToken;
    const label = isOnboarding ? nodes.onboardingTokenLabel : nodes.settingsTokenLabel;
    const cliHelp = isOnboarding ? nodes.onboardingCLIHelp : nodes.settingsCLIHelp;
    const useToken = activeMethod(formName, "cli") === "token";
    token.hidden = !useToken;
    label.hidden = !useToken;
    cliHelp.hidden = useToken;
    token.required = useToken && (isOnboarding || !state.hasSavedToken);
  }

  function mainScene() {
    if (state.showSettings) return "settings";
    if (!state.isConfigured && !state.isDemo) return "onboarding";
    return "issues";
  }

  function renderMain() {
    const scene = mainScene();
    const sceneChanged = currentMainScene !== scene;
    nodes.onboarding.hidden = scene !== "onboarding";
    nodes.issuesView.hidden = scene !== "issues";
    nodes.settingsView.hidden = scene !== "settings";
    nodes.footer.hidden = scene !== "issues";
    nodes.listHeading.hidden = scene !== "issues";
    nodes.settingsHeading.hidden = scene !== "settings";
    nodes.settingsButton.setAttribute("aria-pressed", String(scene === "settings"));
    nodes.settingsButton.hidden = scene === "onboarding";
    nodes.refresh.hidden = scene !== "issues";
    renderProjectSelect();

    if (scene === "onboarding") renderOnboarding();
    if (scene === "settings") renderSettings();
    if (scene === "issues") renderIssues();

    if (sceneChanged) {
      const target = { onboarding: nodes.onboarding, settings: nodes.settingsView, issues: nodes.issuesView }[scene];
      animate(target, { opacity: [0, 1], translateY: [4, 0], duration: 180, ease: "out(3)" });
      currentMainScene = scene;
    }
  }

  function renderOnboarding() {
    patchInput(nodes.onboardingProject, state.projectURL);
    setMethod("onboarding-method", state.useCLI);
    nodes.onboardingError.hidden = !state.errorMessage;
    nodes.onboardingErrorMessage.textContent = state.errorMessage;
  }

  function renderSettings() {
    if (!isAddingProject) patchInput(nodes.settingsProject, state.projectURL);
    patchInput(nodes.inProgressStatuses, state.inProgressStatuses);
    patchInput(nodes.todoStatuses, state.todoStatuses);
    patchChecked(nodes.alwaysOnTop, state.alwaysOnTop);
    setMethod("settings-method", state.useCLI);
    nodes.savedTokenLabel.textContent = state.hasSavedToken ? "Token saved in Keychain" : "No saved token";
    nodes.connectionSectionTitle.textContent = isAddingProject ? "ADD PROJECT" : "CURRENT PROJECT";
    nodes.connectionStatus.textContent = isAddingProject ? "New" : state.isDemo ? "Demo" : state.isConfigured ? "Active" : "Not connected";
    nodes.saveConnection.textContent = isAddingProject ? "Add project" : "Save connection";
    nodes.cancelAddProject.hidden = !isAddingProject;
    nodes.addProject.hidden = isAddingProject;
    nodes.disconnect.hidden = !state.isConfigured;
    nodes.leaveDemo.hidden = !state.isDemo;
    nodes.settingsError.hidden = !state.errorMessage;
    nodes.settingsErrorMessage.textContent = state.errorMessage;
    renderStatusVisibility();
  }

  function renderIssues() {
    const switchingProject = Boolean(state.pendingProjectURL && state.pendingProjectURL !== state.projectURL);
    const issues = statusFilteredIssues();
    const shownStatuses = visibleStatusNames().length;
    if (switchingProject) {
      nodes.summary.textContent = "Loading selected project…";
    } else {
      nodes.summary.replaceChildren(
        textNode(`${issues.length} ${issues.length === 1 ? "issue" : "issues"}`),
        textNode("·"),
        element("strong", `${shownStatuses} ${shownStatuses === 1 ? "status" : "statuses"} shown`),
      );
    }
    nodes.demoBadge.hidden = !state.isDemo;
    nodes.errorBanner.hidden = !state.errorMessage;
    nodes.errorMessage.textContent = state.errorMessage;
    nodes.loading.hidden = !(state.isLoading || switchingProject);
    nodes.issueList.hidden = switchingProject;
    nodes.refresh.disabled = state.isLoading || state.isMutating;
    nodes.filterMine.disabled = switchingProject || state.isMutating;
    nodes.filterEveryone.disabled = switchingProject || state.isMutating;
    nodes.search.disabled = switchingProject;
    nodes.filterMine.setAttribute("aria-pressed", String(state.onlyMine));
    nodes.filterEveryone.setAttribute("aria-pressed", String(!state.onlyMine));
    patchInput(nodes.search, state.search);
    nodes.lastSync.textContent = state.lastSyncLabel;
    nodes.newIssueButton.disabled = state.isMutating || switchingProject;
    nodes.mutationBanner.hidden = !state.mutationNotice;
    nodes.mutationNotice.textContent = state.mutationNotice;
    nodes.openCreatedIssue.hidden = !state.createdIssueURL;
    if (!switchingProject) renderIssueList();
    renderDialogs();
  }

  function renderProjectSelect() {
    const projects = state.projects.length ? state.projects : [{ url: state.projectURL, title: state.projectTitle || "GitHub Issues" }];
    nodes.projectSelect.replaceChildren(...projects.map((project) => optionNode(project.url, project.title)));
    const selectedURL = state.pendingProjectURL || state.projectURL;
    nodes.projectSelect.value = projects.some((project) => project.url === selectedURL) ? selectedURL : projects[0].url;
    nodes.projectSelect.disabled = state.isLoading || state.isMutating || projects.length < 2;
    nodes.projectSelect.title = projects.length < 2 ? "Add another project in Settings" : "Switch project";
  }

  function orderedStatusNames() {
    const names = [];
    const seen = new Set();
    const add = (name) => {
      if (typeof name !== "string" || seen.has(name)) return;
      seen.add(name);
      names.push(name);
    };
    state.statusOptions.forEach((option) => add(option.name));
    state.statusVisibility.forEach((option) => add(option.name));
    state.issues.forEach((issue) => add(issue.status));
    add("");
    return names;
  }

  function statusIsVisible(name) {
    return state.statusVisibility.find((option) => option.name === name)?.visible !== false;
  }

  function visibleStatusNames() {
    return orderedStatusNames().filter(statusIsVisible);
  }

  function statusFilteredIssues() {
    return state.issues.filter((issue) => statusIsVisible(issue.status));
  }

  function renderStatusVisibility() {
    const switches = orderedStatusNames().map((name) => {
      const label = element("label", "", "switch-row status-switch-row");
      const copy = element("span");
      copy.append(element("strong", name || "No status"), element("small", `${state.issues.filter((issue) => issue.status === name).length} issues`));
      const input = document.createElement("input");
      input.type = "checkbox";
      input.role = "switch";
      input.checked = statusIsVisible(name);
      input.dataset.statusName = name;
      input.setAttribute("aria-label", `Show ${name || "No status"}`);
      label.append(copy, input);
      return label;
    });
    nodes.statusVisibilityList.replaceChildren(...switches);
  }

  function filteredIssues() {
    const query = nodes.search.value.trim().toLocaleLowerCase();
    const issues = statusFilteredIssues();
    if (!query) return issues;
    return issues.filter((issue) => {
      const content = [issue.number, issue.title, issue.repository, issue.status, ...issue.labels, ...issue.assignees].join(" ").toLocaleLowerCase();
      return content.includes(query);
    });
  }

  function renderIssueList() {
    const issues = filteredIssues();
    const statusNames = visibleStatusNames();
    const signature = JSON.stringify([state.projectURL, nodes.search.value, statusNames, issues.map((issue) => [issue.id, issue.number, issue.title, issue.repository, issue.status, issue.labels, issue.assignees, issue.group]), state.pinnedIssueID]);
    if (signature === lastListSignature) return;
    lastListSignature = signature;
    nodes.issueList.replaceChildren();

    if (!issues.length && (nodes.search.value || !statusNames.length)) {
      const empty = element("div", "", "empty-state");
      const icon = document.createElement("span");
      icon.dataset.icon = "inbox";
      icon.append(makeIcon("inbox"));
      const noStatuses = visibleStatusNames().length === 0;
      empty.append(icon, element("p", nodes.search.value ? "No issues match your search." : noStatuses ? "No statuses are visible." : "No issues to show."));
      const help = element("small", nodes.search.value ? "Try an issue number, title, or label." : noStatuses ? "Turn on a status in Settings." : "Refresh when the project has new activity.");
      empty.append(help);
      nodes.issueList.append(empty);
      return;
    }

    const enteredRows = [];
    statusNames.forEach((name, index) => {
      const grouped = issues.filter((issue) => issue.status === name);
      const sectionKey = JSON.stringify([state.projectURL, nodes.search.value.trim(), name]);
      const collapsed = collapsedSections.has(sectionKey);
      const section = element("section", "", "issue-section");
      const heading = element("button", "", "section-heading");
      heading.type = "button";
      heading.setAttribute("aria-expanded", String(!collapsed));
      heading.setAttribute("aria-controls", `issue-section-content-${index}`);
      const chevron = makeIcon("chevron-left");
      chevron.classList.add("section-chevron");
      heading.append(chevron, textNode(name || "No status"), element("span", String(grouped.length), "section-count"));
      const content = element("div", "", "section-content");
      content.id = `issue-section-content-${index}`;
      content.hidden = collapsed;
      heading.addEventListener("click", () => {
        content.hidden = !content.hidden;
        heading.setAttribute("aria-expanded", String(!content.hidden));
        if (content.hidden) collapsedSections.add(sectionKey);
        else collapsedSections.delete(sectionKey);
      });
      section.append(heading, content);
      if (!grouped.length) content.append(element("p", "No issues", "section-empty"));
      grouped.forEach((issue) => {
        const item = renderIssue(issue);
        if (!collapsed) enteredRows.push(item);
        content.append(item);
      });
      nodes.issueList.append(section);
    });
    animate(enteredRows, {
      opacity: [0, 1],
      translateY: [5, 0],
      delay: typeof window.anime?.stagger === "function" ? window.anime.stagger(25) : 0,
      duration: 210,
      ease: "out(3)",
    });
  }

  function renderIssue(issue) {
    const isPinned = issue.id === state.pinnedIssueID;
    const item = element("article", "", `issue-item${isPinned ? " is-pinned" : ""}`);
    const row = element("button", "", "issue-row");
    row.type = "button";
    row.dataset.issueId = issue.id;
    row.setAttribute("aria-haspopup", "dialog");
    row.setAttribute("aria-controls", "issue-dialog");

    const status = element("span", "", `issue-status${issue.group === "inProgress" ? " in-progress" : ""}`);
    status.append(makeIcon(issue.group === "inProgress" ? "circle-dot" : "circle"));
    const copy = element("span", "", "issue-copy");
    copy.append(element("span", issue.title, "issue-title"));
    const meta = element("span", "", "issue-meta");
    meta.append(textNode(`#${issue.number}`));
    if (issue.repository) meta.append(textNode("·"), textNode(issue.repository));
    if (issue.status) meta.append(element("span", issue.status, "label-chip"));
    issue.labels.slice(0, 2).forEach((label) => meta.append(element("span", label, "label-chip")));
    copy.append(meta);
    row.append(status, copy);
    if (isPinned) {
      const pin = element("span", "", "pin-mark");
      pin.setAttribute("aria-label", "In focus");
      pin.append(makeIcon("pin"));
      row.append(pin);
    }
    row.addEventListener("click", () => {
      detailReturnIssueID = issue.id;
      post("select", { id: issue.id });
    });
    item.append(row);
    return item;
  }

  function renderFloating() {
    const inProgress = state.issues.filter((issue) => issue.group === "inProgress");
    setBadge(nodes.orbBadge, inProgress.length);
    setBadge(nodes.previewBadge, inProgress.length);
    nodes.previewCount.textContent = String(inProgress.length);
    nodes.previewList.replaceChildren();
    nodes.preview.classList.toggle("preview-right", state.previewHorizontal === "right");
    nodes.preview.classList.toggle("preview-below", state.previewVertical === "below");
    nodes.previewEmpty.hidden = inProgress.length > 0;
    inProgress.slice(0, 3).forEach((issue) => {
      const row = element("button", "", "preview-row");
      row.type = "button";
      row.dataset.noDrag = "true";
      const status = document.createElement("span");
      status.append(makeIcon("circle-dot"));
      const copy = element("span", "", "preview-row-copy");
      copy.append(element("strong", issue.title), element("small", `#${issue.number}${issue.repository ? ` · ${issue.repository}` : ""}`));
      row.append(status, copy);
      row.addEventListener("click", () => {
        post("select", { id: issue.id });
        post("open");
      });
      nodes.previewList.append(row);
    });

    const pinned = state.issues.find((issue) => issue.id === state.pinnedIssueID);
    nodes.focusNumber.textContent = pinned ? `#${pinned.number}` : "";
    nodes.focusTitle.textContent = pinned?.title || "Open issues";
  }

  function selectedDetailIssue() {
    if (!state.selectedIssueID) return null;
    if (state.detailIssue?.id === state.selectedIssueID) return state.detailIssue;
    return state.issues.find((issue) => issue.id === state.selectedIssueID) || null;
  }

  function renderDialogs() {
    const creationChanged = previousCreationRevision !== null && state.creationRevision !== previousCreationRevision;
    previousCreationRevision = state.creationRevision;
    if (creationChanged) {
      createSubmissionPending = false;
      composerDrafts.delete(composerDraftKey());
      if (lastSubmittedCreateAnother && nodes.newIssueDialog.open) {
        resetComposerForAnother();
      } else {
        if (nodes.newIssueDialog.open) nodes.newIssueDialog.close();
        resetComposerFields();
        returnFocus(nodes.newIssueButton);
      }
      lastSubmittedCreateAnother = false;
    }
    if (!state.isMutating && state.mutationError) createSubmissionPending = false;
    if (!state.isMutating) {
      statusSubmissionPending = false;
      assignmentSubmissionPending = false;
    }

    renderDetailDialog(selectedDetailIssue());
    renderCreateDialog();
  }

  function renderDetailDialog(issue) {
    if (!issue) {
      if (nodes.issueDialog.open) nodes.issueDialog.close();
      return;
    }
    const isPinned = issue.id === state.pinnedIssueID;
    nodes.issueDialogMeta.textContent = `#${issue.number}${issue.repository ? ` · ${issue.repository}` : ""}`;
    nodes.issueDialogTitle.textContent = issue.title;
    nodes.issueDialogBody.textContent = issue.body || "This issue has no description.";
    nodes.detailMutationError.hidden = !state.mutationError;
    nodes.detailMutationError.textContent = state.mutationError;
    nodes.detailStatusLabel.textContent = state.statusFieldName || "Status";
    populateStatusSelect(nodes.detailStatus, issue.status, "No status");
    nodes.detailStatus.disabled = !state.canEditStatus || state.isMutating || statusSubmissionPending || Boolean(state.pendingProjectURL);
    nodes.detailPinLabel.textContent = isPinned ? "Show focus" : "Keep in focus";
    nodes.detailPin.dataset.issueId = issue.id;
    nodes.detailPin.dataset.pinned = String(isPinned);
    nodes.detailOpen.dataset.issueId = issue.id;
    renderDetailAssignees(issue);
    if (!nodes.issueDialog.open) {
      nodes.issueDialog.showModal();
      nodes.issueDialogScroll.scrollTop = 0;
      window.requestAnimationFrame(() => nodes.issueDialogClose.focus());
    }
    requestComposerMetadata(issue.repository);
  }

  function renderCreateDialog() {
    if (nodes.newIssueDialog.open && composerProjectURL !== state.projectURL) {
      saveComposerDraft();
      initializeComposer(defaultComposerRepository());
    }
    const selectedStatus = nodes.newIssueStatus.value;
    populateStatusSelect(nodes.newIssueStatus, selectedStatus, "No status", true);
    nodes.repositorySuggestions.replaceChildren(...state.repositories.map((repository) => {
      const option = document.createElement("option");
      option.value = repository;
      return option;
    }));
    const metadata = currentComposerMetadata();
    const structuredTemplate = isStructuredTemplate(selectedTemplate(metadata));
    reconcileComposerMetadata(metadata);
    renderTemplateSelect(metadata);
    renderComposerChoices(metadata);
    renderAttachments();
    renderComposerWarnings(metadata);
    const locked = state.isMutating || createSubmissionPending;
    const metadataUnavailable = state.composerLoading || !metadata;
    nodes.newIssueForm.querySelectorAll("input, textarea, select, button").forEach((control) => { control.disabled = locked; });
    if (!locked) {
      nodes.newIssueRepository.disabled = false;
      nodes.newIssueTitle.disabled = false;
      nodes.newIssueBody.disabled = false;
      nodes.composerWriteTab.disabled = false;
      nodes.composerPreviewTab.disabled = false;
      nodes.composerToolbar.querySelectorAll("button").forEach((button) => { button.disabled = composerMode !== "write"; });
      nodes.newIssueClose.disabled = false;
      nodes.newIssueCancel.disabled = false;
      nodes.composerGitHubHandoff.disabled = !validRepository(nodes.newIssueRepository.value);
      nodes.composerChooseAttachments.disabled = !validRepository(nodes.newIssueRepository.value);
      nodes.composerCreateAnother.disabled = false;
      [nodes.composerTemplate, nodes.composerAssigneeSearch, nodes.composerAssignSelf, nodes.composerType,
        nodes.composerMilestone, nodes.newIssueStatus, nodes.composerParent, nodes.composerBlockedBy,
        nodes.composerBlocking, nodes.composerDetails].forEach((control) => { control.disabled = metadataUnavailable; });
      nodes.composerAssigneeChoices.querySelectorAll("input").forEach((input) => { input.disabled = metadataUnavailable; });
      nodes.composerLabelChoices.querySelectorAll("input").forEach((input) => { input.disabled = metadataUnavailable; });
      nodes.composerProjectChoices.querySelectorAll("input").forEach((input) => { input.disabled = metadataUnavailable; });
    }
    nodes.createMutationError.hidden = !state.mutationError;
    nodes.createMutationError.textContent = state.mutationError;
    nodes.composerLoading.hidden = !state.composerLoading;
    nodes.composerMetadataError.hidden = !state.composerError;
    nodes.composerMetadataError.textContent = state.composerError;
    nodes.composerSuccess.hidden = !state.mutationNotice;
    nodes.composerSuccessCopy.textContent = state.mutationNotice;
    nodes.composerOpenCreated.hidden = !state.createdIssueURL;
    nodes.composerHandoffCopy.textContent = structuredTemplate
      ? "This structured issue form has required GitHub fields. Continue on GitHub with the selected template and current draft; attach queued files there."
      : "GitHub handoff preserves the draft and supported metadata. Set type or relationships there when needed; queued files attach there.";
    nodes.newIssueSubmit.textContent = locked ? "Creating…" : "Create issue";
    nodes.newIssueSubmit.disabled = locked || state.composerLoading || !metadata?.canWrite || structuredTemplate;
    setComposerMode(composerMode, false);
  }

  function renderDetailAssignees(issue) {
    if (detailAssigneeIssueID !== issue.id) {
      detailAssigneeIssueID = issue.id;
      detailAssigneeNames = issue.assignees.slice();
      detailAssigneeIDs = new Set();
      detailAssigneeMetadataSignature = "";
      nodes.detailAssigneeSearch.value = "";
    }
    const metadata = currentMetadataFor(issue.repository);
    const signature = metadata ? JSON.stringify([state.projectURL, metadata.repository, metadata.assignees.map((choice) => [choice.id, choice.name])]) : "";
    if (metadata && signature !== detailAssigneeMetadataSignature) {
      detailAssigneeMetadataSignature = signature;
      const names = new Set(detailAssigneeNames.map((name) => name.toLocaleLowerCase()));
      detailAssigneeIDs = new Set(metadata.assignees.filter((choice) => names.has(choice.name.toLocaleLowerCase())).map((choice) => choice.id));
    }
    const choices = metadata?.assignees || [];
    renderChoiceGrid(nodes.detailAssigneeChoices, choices, detailAssigneeIDs, "No assignable users are available.", nodes.detailAssigneeSearch.value);
    const switchingProject = Boolean(state.pendingProjectURL);
    const canAssign = Boolean(metadata?.canWrite && choices.length);
    nodes.detailAssignSelf.disabled = !canAssign || state.isMutating || assignmentSubmissionPending || switchingProject;
    nodes.detailAssigneeSave.disabled = !metadata?.canWrite || state.isMutating || assignmentSubmissionPending || switchingProject;
    nodes.detailAssigneeSearch.disabled = !choices.length || state.isMutating || assignmentSubmissionPending || switchingProject;
    nodes.detailAssigneeChoices.querySelectorAll("input").forEach((input) => { input.disabled = !metadata?.canWrite || state.isMutating || assignmentSubmissionPending || switchingProject; });
    nodes.detailAssigneeHelp.textContent = state.composerLoading && sameRepository(state.composerRepository, issue.repository)
      ? "Loading assignable users…"
      : state.composerError && sameRepository(state.composerRepository, issue.repository)
        ? state.composerError
        : metadata?.canWrite ? "Save replaces the current assignment, including clearing everyone." : "Assignment editing is unavailable for this repository.";
  }

  function currentMetadataFor(repository) {
    const metadata = state.composerMetadata;
    if (!metadata || !sameRepository(metadata.repository, repository) || !sameRepository(state.composerRepository, repository)) return null;
    return metadata;
  }

  function currentComposerMetadata() {
    return currentMetadataFor(composerRepository || nodes.newIssueRepository.value);
  }

  function reconcileComposerMetadata(metadata) {
    const signature = metadata ? JSON.stringify([
      state.projectURL,
      metadata.repository,
      metadata.assignees.map((choice) => choice.id),
      metadata.labels.map((choice) => choice.id),
      metadata.milestones.map((choice) => choice.id),
      metadata.issueTypes.map((choice) => choice.id),
      metadata.projects.map((project) => [project.id, project.url]),
      metadata.templates.map((template) => template.filename),
      state.statusOptions.map((option) => option.id),
    ]) : "";
    if (signature === composerMetadataSignature) return;
    composerMetadataSignature = signature;
    if (!metadata) return;
    composerSelection.assigneeIDs = validSelectedIDs(composerSelection.assigneeIDs, metadata.assignees);
    composerSelection.labelIDs = validSelectedIDs(composerSelection.labelIDs, metadata.labels);
    composerSelection.additionalProjectIDs = validSelectedIDs(composerSelection.additionalProjectIDs, metadata.projects);
    if (!metadata.issueTypes.some((choice) => choice.id === selectValue(nodes.composerType))) setPendingSelectValue(nodes.composerType, "");
    if (!metadata.milestones.some((choice) => choice.id === selectValue(nodes.composerMilestone))) setPendingSelectValue(nodes.composerMilestone, "");
    if (!metadata.templates.some((template) => template.filename === selectValue(nodes.composerTemplate))) setPendingSelectValue(nodes.composerTemplate, "");
    if (!state.statusOptions.some((option) => option.id === selectValue(nodes.newIssueStatus))) setPendingSelectValue(nodes.newIssueStatus, "");
  }

  function validSelectedIDs(selected, choices) {
    const available = new Set(choices.map((choice) => choice.id));
    return new Set(Array.from(selected).filter((id) => available.has(id)));
  }

  function renderTemplateSelect(metadata) {
    const selected = selectValue(nodes.composerTemplate);
    const options = [optionNode("", "Blank issue"), ...(metadata?.templates || []).map((template) => optionNode(template.filename, template.about ? `${template.name} — ${template.about}` : template.name))];
    nodes.composerTemplate.replaceChildren(...options);
    nodes.composerTemplate.value = options.some((option) => option.value === selected) ? selected : "";
    if (nodes.composerTemplate.value === selected) delete nodes.composerTemplate.dataset.pendingValue;
  }

  function renderComposerChoices(metadata) {
    renderChoiceGrid(nodes.composerAssigneeChoices, metadata?.assignees || [], composerSelection.assigneeIDs, "No assignable users are available.", nodes.composerAssigneeSearch.value);
    renderChoiceGrid(nodes.composerLabelChoices, metadata?.labels || [], composerSelection.labelIDs, "No labels are available.");
    const projects = (metadata?.projects || []).filter((project) => !project.url || project.url !== state.projectURL);
    renderChoiceGrid(nodes.composerProjectChoices, projects, composerSelection.additionalProjectIDs, "No additional projects are available.");
    replaceSelectOptions(nodes.composerType, metadata?.issueTypes || [], "No type");
    replaceSelectOptions(nodes.composerMilestone, metadata?.milestones || [], "No milestone");
    const detailCount = composerSelection.labelIDs.size + composerSelection.additionalProjectIDs.size
      + (selectValue(nodes.composerType) ? 1 : 0) + (selectValue(nodes.composerMilestone) ? 1 : 0)
      + (selectValue(nodes.newIssueStatus) ? 1 : 0) + (nodes.composerParent.value.trim() ? 1 : 0)
      + splitIssueReferences(nodes.composerBlockedBy.value).length + splitIssueReferences(nodes.composerBlocking.value).length;
    nodes.composerDetailCount.textContent = detailCount ? `· ${detailCount} selected` : "";
  }

  function renderChoiceGrid(container, choices, selected, emptyCopy, filter = "") {
    const query = filter.trim().toLocaleLowerCase();
    const visible = choices.filter((choice) => !query || choice.name.toLocaleLowerCase().includes(query));
    if (!visible.length) {
      container.replaceChildren(element("p", query ? "No matches." : emptyCopy, "choice-empty"));
      return;
    }
    container.replaceChildren(...visible.map((choice) => {
      const label = element("label", "", "choice-chip");
      const input = document.createElement("input");
      input.type = "checkbox";
      input.value = choice.id;
      input.checked = selected.has(choice.id);
      label.append(input, element("span", choice.name));
      return label;
    }));
  }

  function updateChoiceSelection(event, selection, rerenderComposer = true) {
    const input = event.target.closest('input[type="checkbox"]');
    if (!input) return;
    if (input.checked) selection.add(input.value);
    else selection.delete(input.value);
    if (rerenderComposer) {
      saveComposerDraft();
      renderCreateDialog();
    }
  }

  function replaceSelectOptions(select, choices, emptyLabel) {
    const selected = selectValue(select);
    select.replaceChildren(optionNode("", emptyLabel), ...choices.map((choice) => optionNode(choice.id, choice.name)));
    select.value = choices.some((choice) => choice.id === selected) ? selected : "";
    if (select.value === selected) delete select.dataset.pendingValue;
  }

  function selectValue(select) {
    return select.dataset.pendingValue ?? select.value;
  }

  function setPendingSelectValue(select, value) {
    select.dataset.pendingValue = String(value || "");
    select.value = String(value || "");
  }

  function renderComposerWarnings(metadata) {
    const warnings = metadata?.warnings.slice() || [];
    if (metadata && !metadata.canWrite) warnings.unshift("GitHub reports that this repository is read-only for the connected account.");
    if (isStructuredTemplate(selectedTemplate(metadata))) warnings.unshift("Structured YAML issue forms must be completed on GitHub; local creation is disabled for this template.");
    nodes.composerWarnings.hidden = !warnings.length;
    nodes.composerWarnings.replaceChildren(...warnings.map((warning) => element("p", warning)));
  }

  function renderAttachments() {
    nodes.composerAttachmentList.replaceChildren(...state.composerAttachments.map((attachment) => {
      const row = element("div", "", "attachment-row");
      const copy = element("span", "", "attachment-copy");
      copy.append(element("strong", attachment.name), element("small", formatFileSize(attachment.size)));
      const remove = element("button", "Remove", "text-button compact-action");
      remove.type = "button";
      remove.dataset.attachmentId = attachment.id;
      remove.disabled = state.isMutating || createSubmissionPending;
      row.append(copy, remove);
      return row;
    }));
    nodes.composerAttachmentError.hidden = !state.attachmentError;
    nodes.composerAttachmentError.textContent = state.attachmentError;
  }

  function formatFileSize(size) {
    if (size < 1024) return `${size} B`;
    if (size < 1024 * 1024) return `${(size / 1024).toFixed(size < 10240 ? 1 : 0)} KB`;
    return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  }

  function defaultComposerRepository() {
    const nativeDefault = state.composerRepository.trim();
    if (validRepository(nativeDefault)) return nativeDefault;
    const selected = selectedDetailIssue()?.repository || "";
    if (validRepository(selected)) return selected;
    return state.repositories.find(validRepository) || "";
  }

  function composerDraftKey(projectURL = composerProjectURL || state.projectURL, repository = composerRepository) {
    return `${projectURL}::${repository.trim().toLocaleLowerCase()}`;
  }

  function saveComposerDraft() {
    if (!validRepository(composerRepository)) return;
    composerDrafts.set(composerDraftKey(), {
      title: nodes.newIssueTitle.value,
      body: nodes.newIssueBody.value,
      templateFilename: selectValue(nodes.composerTemplate),
      assigneeIDs: Array.from(composerSelection.assigneeIDs),
      labelIDs: Array.from(composerSelection.labelIDs),
      additionalProjectIDs: Array.from(composerSelection.additionalProjectIDs),
      milestoneID: selectValue(nodes.composerMilestone),
      issueTypeID: selectValue(nodes.composerType),
      optionID: selectValue(nodes.newIssueStatus),
      parentIssue: nodes.composerParent.value,
      blockedBy: nodes.composerBlockedBy.value,
      blocking: nodes.composerBlocking.value,
      createAnother: nodes.composerCreateAnother.checked,
    });
  }

  function restoreComposerDraft(draft, fallbackContent = null) {
    const value = draft || fallbackContent || {};
    nodes.newIssueTitle.value = value.title || "";
    nodes.newIssueBody.value = value.body || "";
    setPendingSelectValue(nodes.composerTemplate, value.templateFilename || "");
    composerSelection.assigneeIDs = new Set(stringArray(value.assigneeIDs));
    composerSelection.labelIDs = new Set(stringArray(value.labelIDs));
    composerSelection.additionalProjectIDs = new Set(stringArray(value.additionalProjectIDs));
    setPendingSelectValue(nodes.composerMilestone, value.milestoneID || "");
    setPendingSelectValue(nodes.composerType, value.issueTypeID || "");
    setPendingSelectValue(nodes.newIssueStatus, value.optionID || "");
    nodes.composerParent.value = value.parentIssue || "";
    nodes.composerBlockedBy.value = value.blockedBy || "";
    nodes.composerBlocking.value = value.blocking || "";
    nodes.composerCreateAnother.checked = Boolean(value.createAnother);
    composerMetadataSignature = "";
    renderMarkdownPreview();
  }

  function resetComposerFields() {
    nodes.newIssueForm.reset();
    composerSelection.assigneeIDs = new Set();
    composerSelection.labelIDs = new Set();
    composerSelection.additionalProjectIDs = new Set();
    composerRepository = "";
    composerProjectURL = "";
    composerMetadataSignature = "";
    composerMode = "write";
    setComposerMode("write", false);
  }

  function resetComposerForAnother() {
    saveComposerDraft();
    window.requestAnimationFrame(() => {
      nodes.newIssueTitle.focus();
      nodes.newIssueTitle.select();
    });
  }

  function initializeComposer(repository) {
    composerProjectURL = state.projectURL;
    composerRepository = repository.trim();
    nodes.newIssueRepository.value = composerRepository;
    restoreComposerDraft(composerDrafts.get(composerDraftKey()));
    nodes.composerAssigneeSearch.value = "";
    composerMode = "write";
    setComposerMode("write", false);
    requestComposerMetadata(composerRepository, true);
  }

  function switchComposerRepository(repository) {
    const next = repository.trim();
    if (sameRepository(next, composerRepository)) {
      requestComposerMetadata(next, true);
      return;
    }
    const carry = { title: nodes.newIssueTitle.value, body: nodes.newIssueBody.value, createAnother: nodes.composerCreateAnother.checked };
    saveComposerDraft();
    composerRepository = next;
    composerMetadataSignature = "";
    restoreComposerDraft(composerDrafts.get(composerDraftKey()), carry);
    requestComposerMetadata(next, true);
  }

  function requestComposerMetadata(repository, immediate = false) {
    const value = repository.trim();
    window.clearTimeout(composerLoadTimer);
    if (!validRepository(value)) return;
    if (!immediate && sameRepository(state.composerRepository, value) && (state.composerLoading || state.composerError || currentMetadataFor(value))) return;
    const send = () => post("loadComposer", { repository: value });
    if (immediate) send();
    else composerLoadTimer = window.setTimeout(send, 220);
  }

  function validRepository(repository) {
    return /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(String(repository || "").trim());
  }

  function sameRepository(left, right) {
    return String(left || "").trim().toLocaleLowerCase() === String(right || "").trim().toLocaleLowerCase();
  }

  function selectedTemplate(metadata = currentComposerMetadata()) {
    return metadata?.templates.find((template) => template.filename === selectValue(nodes.composerTemplate)) || null;
  }

  function isStructuredTemplate(template = selectedTemplate()) {
    return Boolean(template && /\.ya?ml$/i.test(template.filename));
  }

  function applyTemplate() {
    const metadata = currentComposerMetadata();
    const template = selectedTemplate(metadata);
    if (!template) {
      saveComposerDraft();
      renderCreateDialog();
      return;
    }
    nodes.newIssueTitle.value = template.title;
    nodes.newIssueBody.value = template.body;
    composerSelection.assigneeIDs = validSelectedIDs(new Set(template.assigneeIDs), metadata.assignees);
    composerSelection.labelIDs = validSelectedIDs(new Set(template.labelIDs), metadata.labels);
    setPendingSelectValue(nodes.composerType, metadata.issueTypes.some((choice) => choice.id === template.issueTypeID) ? template.issueTypeID : "");
    saveComposerDraft();
    renderMarkdownPreview();
    renderCreateDialog();
  }

  function setComposerMode(mode, focus = true) {
    composerMode = mode === "preview" ? "preview" : "write";
    const previewing = composerMode === "preview";
    nodes.composerWriteTab.setAttribute("aria-selected", String(!previewing));
    nodes.composerPreviewTab.setAttribute("aria-selected", String(previewing));
    nodes.newIssueBody.hidden = previewing;
    nodes.composerToolbar.hidden = previewing;
    nodes.composerPreview.hidden = !previewing;
    if (previewing) renderMarkdownPreview();
    if (focus) window.requestAnimationFrame(() => (previewing ? nodes.composerPreview : nodes.newIssueBody).focus());
  }

  function renderMarkdownPreview() {
    const markdown = nodes.newIssueBody.value;
    if (!markdown.trim()) {
      nodes.composerPreview.replaceChildren(element("p", "Nothing to preview.", "preview-empty-copy"));
      return;
    }
    if (!window.marked?.parse || !window.DOMPurify?.sanitize) {
      nodes.composerPreview.textContent = markdown;
      return;
    }
    const parsed = window.marked.parse(markdown, { gfm: true, breaks: false });
    const clean = window.DOMPurify.sanitize(parsed, {
      USE_PROFILES: { html: true },
      FORBID_TAGS: ["form", "button", "textarea", "select", "option", "iframe", "object", "embed", "style", "script", "svg", "math", "img"],
      FORBID_ATTR: ["style", "srcdoc"],
    });
    nodes.composerPreview.innerHTML = clean;
    nodes.composerPreview.querySelectorAll("a").forEach((link) => {
      link.setAttribute("rel", "noreferrer noopener");
      link.addEventListener("click", (event) => event.preventDefault());
    });
    nodes.composerPreview.querySelectorAll("input").forEach((input) => { input.disabled = true; });
  }

  function applyMarkdownFormat(action) {
    const textarea = nodes.newIssueBody;
    const start = textarea.selectionStart;
    const end = textarea.selectionEnd;
    const selected = textarea.value.slice(start, end);
    let replacement = selected;
    let selectionStart = start;
    let selectionEnd = end;
    const wrap = (before, after = before, placeholder = "text") => {
      const content = selected || placeholder;
      replacement = `${before}${content}${after}`;
      selectionStart = start + before.length;
      selectionEnd = selectionStart + content.length;
    };
    const prefixLines = (prefix, placeholder) => {
      const content = selected || placeholder;
      replacement = content.split("\n").map((line) => `${prefix}${line}`).join("\n");
      selectionStart = start;
      selectionEnd = start + replacement.length;
    };
    switch (action) {
    case "bold": wrap("**", "**", "strong text"); break;
    case "italic": wrap("_", "_", "emphasized text"); break;
    case "code": wrap("`", "`", "code"); break;
    case "quote": prefixLines("> ", "Quoted text"); break;
    case "list": prefixLines("- ", "List item"); break;
    case "task": prefixLines("- [ ] ", "Task"); break;
    case "mention": wrap("@", "", "username"); break;
    case "reference": wrap("#", "", "123"); break;
    case "link": {
      const url = window.prompt("Link URL", "https://");
      if (!url) return;
      wrap("[", `](${url})`, "link text");
      break;
    }
    default: return;
    }
    textarea.setRangeText(replacement, start, end, "end");
    textarea.focus();
    textarea.setSelectionRange(selectionStart, selectionEnd);
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function splitIssueReferences(value) {
    return String(value || "").split(/[\n,]+/).map((reference) => reference.trim()).filter(Boolean);
  }

  function composerPayload() {
    const metadata = currentComposerMetadata();
    return {
      repository: nodes.newIssueRepository.value.trim(),
      title: nodes.newIssueTitle.value.trim(),
      body: nodes.newIssueBody.value,
      assignToMe: false,
      optionID: selectValue(nodes.newIssueStatus),
      assigneeIDs: Array.from(validSelectedIDs(composerSelection.assigneeIDs, metadata?.assignees || [])),
      labelIDs: Array.from(validSelectedIDs(composerSelection.labelIDs, metadata?.labels || [])),
      milestoneID: selectValue(nodes.composerMilestone),
      issueTypeID: selectValue(nodes.composerType),
      templateFilename: selectValue(nodes.composerTemplate),
      additionalProjectIDs: Array.from(validSelectedIDs(composerSelection.additionalProjectIDs, metadata?.projects || [])),
      parentIssue: nodes.composerParent.value.trim(),
      blockedBy: splitIssueReferences(nodes.composerBlockedBy.value),
      blocking: splitIssueReferences(nodes.composerBlocking.value),
      createAnother: nodes.composerCreateAnother.checked,
    };
  }

  function githubHandoffPayload() {
    const payload = composerPayload();
    return {
      repository: payload.repository,
      title: payload.title,
      body: payload.body,
      templateFilename: payload.templateFilename || undefined,
      assigneeIDs: payload.assigneeIDs,
      labelIDs: payload.labelIDs,
      milestoneID: payload.milestoneID || undefined,
    };
  }

  function populateStatusSelect(select, preferred, emptyLabel, preferredIsID = false) {
    const pending = select.dataset.pendingValue;
    const selectedID = pending != null ? pending : preferredIsID ? preferred : state.statusOptions.find((option) => option.name === preferred)?.id || "";
    const options = [optionNode("", emptyLabel), ...state.statusOptions.map((option) => optionNode(option.id, option.name))];
    select.replaceChildren(...options);
    select.value = state.statusOptions.some((option) => option.id === selectedID) ? selectedID : "";
    if (select.value === selectedID) delete select.dataset.pendingValue;
  }

  function optionNode(value, label) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label;
    return option;
  }

  function dismissDetails() {
    if (!nodes.issueDialog.open) return;
    nodes.issueDialog.close();
    post("select", { id: "" });
    const id = detailReturnIssueID;
    window.requestAnimationFrame(() => {
      const trigger = Array.from(nodes.issueList.querySelectorAll("[data-issue-id]")).find((row) => row.dataset.issueId === id);
      returnFocus(trigger);
    });
  }

  function dismissNewIssue() {
    if (state.isMutating || createSubmissionPending || !nodes.newIssueDialog.open) return;
    nodes.newIssueDialog.close();
    returnFocus(nodes.newIssueButton);
  }

  function returnFocus(target) {
    window.requestAnimationFrame(() => target?.isConnected && target.focus());
  }

  function handleBackdropClick(dialog, event, dismiss) {
    if (event.target !== dialog) return;
    const card = dialog.firstElementChild?.getBoundingClientRect();
    if (!card || event.clientX < card.left || event.clientX > card.right || event.clientY < card.top || event.clientY > card.bottom) dismiss();
  }

  function trapDialogFocus(dialog, event) {
    if (event.key !== "Tab") return;
    const controls = Array.from(dialog.querySelectorAll('button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex="0"]')).filter((control) => !control.hidden);
    if (!controls.length) return;
    const first = controls[0];
    const last = controls[controls.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  function setBadge(node, count) {
    node.hidden = count < 1;
    node.textContent = count > 99 ? "99+" : String(count);
  }

  function element(tag, text = "", className = "") {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text) node.textContent = text;
    return node;
  }

  function textNode(value) {
    return document.createTextNode(value);
  }

  function render(next) {
    state = normalizeState(next);
    if (!state.showSettings || (isAddingProject && state.projects.some((project) => project.url === nodes.settingsProject.value.trim()))) {
      isAddingProject = false;
      dirtyFields.delete(nodes.settingsProject);
    }
    setMode(state.mode);
    renderFloating();
    if (state.mode === "main") renderMain();
  }

  function connect(form, projectInput, tokenInput, methodName) {
    if (!form.reportValidity()) return;
    const useCLI = activeMethod(methodName, "cli") === "cli";
    const token = tokenInput.value;
    post("connect", { projectURL: projectInput.value.trim(), useCLI, token });
    tokenInput.value = "";
    dirtyFields.delete(tokenInput);
  }

  function markDirty(event) {
    dirtyFields.add(event.currentTarget);
  }

  function commitPreference(input, key) {
    post("preference", { key, value: input.type === "checkbox" ? input.checked : input.value });
    dirtyFields.delete(input);
  }

  function bindEvents() {
    nodes.projectSelect.addEventListener("change", () => {
      nodes.projectSelect.disabled = true;
      post("selectProject", { url: nodes.projectSelect.value });
    });
    nodes.refresh.addEventListener("click", () => post("refresh"));
    nodes.errorRetry.addEventListener("click", () => post("refresh"));
    nodes.settingsButton.addEventListener("click", () => post("settings", { value: !state.showSettings }));
    nodes.settingsBack.addEventListener("click", () => post("settings", { value: false }));
    nodes.minimize.addEventListener("click", () => post("minimize"));
    nodes.demo.addEventListener("click", () => post("demo"));
    nodes.disconnect.addEventListener("click", () => post("disconnect"));
    nodes.leaveDemo.addEventListener("click", () => post("leaveDemo"));
    nodes.quit.addEventListener("click", () => post("quit"));
    nodes.orb.addEventListener("click", guardedClick(openFromFloating));
    nodes.previewOrb.addEventListener("click", guardedClick(openFromFloating));
    nodes.focusButton.addEventListener("click", guardedClick(openFocusedIssue));
    nodes.filterMine.addEventListener("click", () => post("preference", { key: "onlyMine", value: true }));
    nodes.filterEveryone.addEventListener("click", () => post("preference", { key: "onlyMine", value: false }));
    nodes.openCreatedIssue.addEventListener("click", () => post("openCreatedIssue"));
    nodes.addProject.addEventListener("click", () => {
      isAddingProject = true;
      dirtyFields.add(nodes.settingsProject);
      nodes.settingsProject.value = "";
      renderSettings();
      window.requestAnimationFrame(() => nodes.settingsProject.focus());
    });
    nodes.cancelAddProject.addEventListener("click", () => {
      isAddingProject = false;
      dirtyFields.delete(nodes.settingsProject);
      nodes.settingsProject.value = state.projectURL;
      renderSettings();
    });
    nodes.statusVisibilityList.addEventListener("change", (event) => {
      const input = event.target.closest('input[role="switch"][data-status-name]');
      if (!input) return;
      post("statusVisibility", { name: input.dataset.statusName || "", visible: input.checked });
    });

    nodes.newIssueButton.addEventListener("click", () => {
      post("clearMutationFeedback");
      nodes.newIssueDialog.showModal();
      initializeComposer(defaultComposerRepository());
      nodes.composerScroll.scrollTop = 0;
      renderCreateDialog();
      nodes.createMutationError.hidden = true;
      window.requestAnimationFrame(() => (nodes.newIssueRepository.value ? nodes.newIssueTitle : nodes.newIssueRepository).focus());
    });
    nodes.newIssueClose.addEventListener("click", dismissNewIssue);
    nodes.newIssueCancel.addEventListener("click", dismissNewIssue);
    nodes.newIssueDialog.addEventListener("cancel", (event) => {
      event.preventDefault();
      dismissNewIssue();
    });
    nodes.newIssueDialog.addEventListener("click", (event) => handleBackdropClick(nodes.newIssueDialog, event, dismissNewIssue));
    nodes.newIssueDialog.addEventListener("keydown", (event) => trapDialogFocus(nodes.newIssueDialog, event));
    nodes.newIssueForm.addEventListener("submit", (event) => {
      event.preventDefault();
      const metadata = currentComposerMetadata();
      if (createSubmissionPending || state.isMutating || state.composerLoading || !metadata?.canWrite || isStructuredTemplate() || !nodes.newIssueForm.reportValidity()) return;
      createSubmissionPending = true;
      lastSubmittedCreateAnother = nodes.composerCreateAnother.checked;
      saveComposerDraft();
      renderCreateDialog();
      post("createIssue", composerPayload());
    });

    nodes.newIssueRepository.addEventListener("input", () => {
      window.clearTimeout(composerLoadTimer);
      composerLoadTimer = window.setTimeout(() => switchComposerRepository(nodes.newIssueRepository.value), 260);
    });
    nodes.newIssueRepository.addEventListener("change", () => switchComposerRepository(nodes.newIssueRepository.value));
    nodes.composerTemplate.addEventListener("change", applyTemplate);
    nodes.composerWriteTab.addEventListener("click", () => setComposerMode("write"));
    nodes.composerPreviewTab.addEventListener("click", () => setComposerMode("preview"));
    nodes.composerToolbar.addEventListener("click", (event) => {
      const button = event.target.closest("button[data-format]");
      if (button) applyMarkdownFormat(button.dataset.format);
    });
    nodes.composerGitHubHandoff.addEventListener("click", () => {
      if (!validRepository(nodes.newIssueRepository.value)) return;
      saveComposerDraft();
      post("openIssueComposerOnGitHub", githubHandoffPayload());
    });
    nodes.composerChooseAttachments.addEventListener("click", () => post("chooseAttachments"));
    nodes.composerAttachmentList.addEventListener("click", (event) => {
      const button = event.target.closest("button[data-attachment-id]");
      if (button) post("removeAttachment", { id: button.dataset.attachmentId });
    });
    nodes.composerOpenCreated.addEventListener("click", () => post("openCreatedIssue"));
    nodes.composerAssigneeSearch.addEventListener("input", () => renderCreateDialog());
    nodes.composerAssigneeChoices.addEventListener("change", (event) => updateChoiceSelection(event, composerSelection.assigneeIDs));
    nodes.composerLabelChoices.addEventListener("change", (event) => updateChoiceSelection(event, composerSelection.labelIDs));
    nodes.composerProjectChoices.addEventListener("change", (event) => updateChoiceSelection(event, composerSelection.additionalProjectIDs));
    nodes.composerAssignSelf.addEventListener("click", () => {
      const self = currentComposerMetadata()?.assignees.find((choice) => choice.name.toLocaleLowerCase() === state.viewerLogin.toLocaleLowerCase());
      if (!self) return;
      composerSelection.assigneeIDs.add(self.id);
      saveComposerDraft();
      renderCreateDialog();
    });
    [nodes.newIssueTitle, nodes.newIssueBody, nodes.composerType, nodes.composerMilestone, nodes.newIssueStatus,
      nodes.composerParent, nodes.composerBlockedBy, nodes.composerBlocking, nodes.composerCreateAnother].forEach((control) => {
      control.addEventListener("input", () => {
        if (control === nodes.newIssueBody && composerMode === "preview") renderMarkdownPreview();
        saveComposerDraft();
      });
      control.addEventListener("change", saveComposerDraft);
    });

    nodes.issueDialogClose.addEventListener("click", dismissDetails);
    nodes.issueDialog.addEventListener("cancel", (event) => {
      event.preventDefault();
      dismissDetails();
    });
    nodes.issueDialog.addEventListener("click", (event) => handleBackdropClick(nodes.issueDialog, event, dismissDetails));
    nodes.issueDialog.addEventListener("keydown", (event) => trapDialogFocus(nodes.issueDialog, event));
    nodes.detailPin.addEventListener("click", () => {
      const id = nodes.detailPin.dataset.issueId || "";
      post(nodes.detailPin.dataset.pinned === "true" ? "showFocus" : "pin", nodes.detailPin.dataset.pinned === "true" ? {} : { id });
    });
    nodes.detailOpen.addEventListener("click", () => post("openIssue", { id: nodes.detailOpen.dataset.issueId || "" }));
    nodes.detailStatus.addEventListener("change", () => {
      const issue = selectedDetailIssue();
      if (!issue || !state.canEditStatus || state.isMutating || state.pendingProjectURL || statusSubmissionPending) return;
      statusSubmissionPending = true;
      nodes.detailStatus.disabled = true;
      post("changeStatus", { id: issue.id, optionID: nodes.detailStatus.value });
    });
    nodes.detailAssigneeSearch.addEventListener("input", () => {
      const issue = selectedDetailIssue();
      if (issue) renderDetailAssignees(issue);
    });
    nodes.detailAssigneeChoices.addEventListener("change", (event) => {
      updateChoiceSelection(event, detailAssigneeIDs, false);
    });
    nodes.detailAssignSelf.addEventListener("click", () => {
      const issue = selectedDetailIssue();
      const self = issue && currentMetadataFor(issue.repository)?.assignees.find((choice) => choice.name.toLocaleLowerCase() === state.viewerLogin.toLocaleLowerCase());
      if (!self) return;
      detailAssigneeIDs.add(self.id);
      renderDetailAssignees(issue);
    });
    nodes.detailAssigneeSave.addEventListener("click", () => {
      const issue = selectedDetailIssue();
      const metadata = issue && currentMetadataFor(issue.repository);
      if (!issue || !metadata?.canWrite || state.isMutating || state.pendingProjectURL || assignmentSubmissionPending) return;
      const selected = validSelectedIDs(detailAssigneeIDs, metadata.assignees);
      assignmentSubmissionPending = true;
      renderDetailAssignees(issue);
      post("updateAssignees", { id: issue.id, assigneeIDs: Array.from(selected) });
    });

    nodes.onboardingForm.addEventListener("submit", (event) => {
      event.preventDefault();
      connect(nodes.onboardingForm, nodes.onboardingProject, nodes.onboardingToken, "onboarding-method");
    });
    nodes.settingsForm.addEventListener("submit", (event) => {
      event.preventDefault();
      connect(nodes.settingsForm, nodes.settingsProject, nodes.settingsToken, "settings-method");
    });

    document.querySelectorAll('input[name="onboarding-method"], input[name="settings-method"]').forEach((radio) => {
      radio.addEventListener("change", () => {
        dirtyFields.add(radio);
        updateTokenVisibility(radio.name);
      });
    });

    [nodes.onboardingProject, nodes.onboardingToken, nodes.settingsProject, nodes.settingsToken, nodes.inProgressStatuses, nodes.todoStatuses, nodes.search].forEach((input) => {
      input.addEventListener("input", markDirty);
    });
    nodes.alwaysOnTop.addEventListener("change", markDirty);
    nodes.alwaysOnTop.addEventListener("change", () => commitPreference(nodes.alwaysOnTop, "alwaysOnTop"));
    nodes.inProgressStatuses.addEventListener("change", () => commitPreference(nodes.inProgressStatuses, "inProgressStatuses"));
    nodes.todoStatuses.addEventListener("change", () => commitPreference(nodes.todoStatuses, "todoStatuses"));

    let searchTimer = 0;
    nodes.search.addEventListener("input", () => {
      renderIssueList();
      window.clearTimeout(searchTimer);
      searchTimer = window.setTimeout(() => {
        post("preference", { key: "search", value: nodes.search.value });
        dirtyFields.delete(nodes.search);
      }, 180);
    });

    document.addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k" && state.mode === "main" && mainScene() === "issues") {
        event.preventDefault();
        nodes.search.focus();
      }
      if (event.key === "Escape" && !nodes.issueDialog.open && !nodes.newIssueDialog.open && state.mode === "main" && state.showSettings) post("settings", { value: false });
    });

    installDrag(nodes.icon, { activationTarget: nodes.orb, onActivate: openFromFloating });
    installDrag(nodes.preview, { activationTarget: nodes.previewOrb, onActivate: openFromFloating });
    installDrag(nodes.focus, { activationTarget: nodes.focusButton, onActivate: openFocusedIssue });
  }

  function openFocusedIssue() {
    if (state.pinnedIssueID) post("select", { id: state.pinnedIssueID });
    post("open");
  }

  function openFromFloating() {
    post("open");
  }

  function guardedClick(callback) {
    return (event) => {
      if (performance.now() < suppressClickUntil) {
        event.preventDefault();
        return;
      }
      callback();
    };
  }

  function installDrag(surface, { activationTarget = null, onActivate = null }) {
    let drag = null;
    surface.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || event.target.closest("[data-no-drag]")) return;
      drag = { id: event.pointerId, x: event.screenX, y: event.screenY, moved: false, downTarget: event.target };
    });
    surface.addEventListener("pointermove", (event) => {
      if (!drag || drag.id !== event.pointerId) return;
      const distance = Math.hypot(event.screenX - drag.x, event.screenY - drag.y);
      if (!drag.moved && distance > 3) {
        drag.moved = true;
        surface.classList.add("is-dragging");
        surface.setPointerCapture?.(event.pointerId);
        post("drag", { phase: "start", screenX: drag.x, screenY: drag.y });
      }
      if (drag.moved) {
        event.preventDefault();
        post("drag", { phase: "move", screenX: event.screenX, screenY: event.screenY });
      }
    });
    const end = (event) => {
      if (!drag || drag.id !== event.pointerId) return;
      if (drag.moved) {
        post("drag", { phase: "end", screenX: event.screenX, screenY: event.screenY });
        suppressClickUntil = performance.now() + 350;
      } else if (activationTarget && activationTarget.contains(drag.downTarget) && typeof onActivate === "function") {
        suppressClickUntil = performance.now() + 350;
        event.preventDefault();
        onActivate();
      }
      surface.classList.remove("is-dragging");
      drag = null;
    };
    surface.addEventListener("pointerup", end);
    surface.addEventListener("pointercancel", (event) => {
      if (!drag || drag.id !== event.pointerId) return;
      if (drag.moved) post("drag", { phase: "end", screenX: event.screenX, screenY: event.screenY });
      surface.classList.remove("is-dragging");
      drag = null;
    });
  }

  function installDemoBridge() {
    if (!demoRequested || window.webkit?.messageHandlers?.issues) return;
    const longBody = Array.from({ length: 28 }, (_, index) => `Section ${index + 1}\nThis detailed demo paragraph verifies that the complete GitHub-authored description remains readable inside the compact issue dialog. It includes enough text to require deliberate scrolling without clipping or a line clamp.`).join("\n\n") + "\n\nEND OF FULL ISSUE DESCRIPTION";
    const websiteURL = "https://github.com/users/example/projects/1";
    const desktopURL = "https://github.com/orgs/example/projects/8";
    const demoProjects = {
      [websiteURL]: {
        title: "Website / Current sprint",
        statuses: ["Backlog", "In progress", "Ready", "In review", "Done"],
        visibility: ["Backlog", "In progress", "Ready", "In review", "Done", ""].map((name) => ({ name, visible: true })),
        repositories: ["example/web-app", "example/docs"],
        issues: [
          { id: "42", number: 42, title: "Restore the page after GitHub sign-in while preserving navigation context and every pending draft", body: longBody, repository: "example/web-app", status: "In progress", labels: ["bug"], assignees: ["alex"], group: "inProgress" },
          { id: "38", number: 38, title: "Refine mobile navigation", body: "Make spacing and menu behavior consistent on smaller displays.", repository: "example/web-app", status: "Ready", labels: ["interface"], assignees: ["alex"], group: "todo" },
          { id: "45", number: 45, title: "Keep filters after returning to search", body: "Preserve selected filters when returning to the results page.", repository: "example/web-app", status: "In review", labels: ["bug"], assignees: ["alex"], group: "other" },
          { id: "31", number: 31, title: "Update the installation guide", body: "Review the initial steps and requirements for running the project.", repository: "example/docs", status: "Done", labels: ["documentation"], assignees: ["alex"], group: "other" },
        ],
      },
      [desktopURL]: {
        title: "Desktop / Release board",
        statuses: ["Queued", "Building", "Review", "Shipped"],
        visibility: ["Queued", "Building", "Review", "Shipped", ""].map((name) => ({ name, visible: true })),
        repositories: ["example/desktop"],
        issues: [
          { id: "d-12", number: 12, title: "Keep preview geometry stable while resizing", body: "Track pointer position against the native window geometry.", repository: "example/desktop", status: "Building", labels: ["desktop"], assignees: ["alex"], group: "inProgress" },
          { id: "d-9", number: 9, title: "Package the signed release", body: "Prepare the release artifact after final review.", repository: "example/desktop", status: "Review", labels: ["release"], assignees: ["alex"], group: "other" },
        ],
      },
    };
    const demoComposerCatalog = {
      "example/web-app": {
        repository: "example/web-app", repositoryID: "repo-web", canWrite: true, warnings: [],
        assignees: [{ id: "user-alex", name: "alex" }, { id: "user-riley", name: "riley" }, { id: "user-sam", name: "sam" }],
        labels: [{ id: "label-bug", name: "bug" }, { id: "label-interface", name: "interface" }, { id: "label-accessibility", name: "accessibility" }],
        milestones: [{ id: "milestone-1", name: "September release" }],
        issueTypes: [{ id: "type-bug", name: "Bug" }, { id: "type-feature", name: "Feature" }],
        projects: [{ id: "project-website", title: "Website / Current sprint", url: websiteURL }, { id: "project-desktop", title: "Desktop / Release board", url: desktopURL }],
        templates: [
          { filename: "bug.md", name: "Bug report", about: "Report a reproducible problem", title: "[Bug] ", body: "## What happened\n\n\n## Steps to reproduce\n\n1. \n", assigneeIDs: [], labelIDs: ["label-bug"], issueTypeID: "type-bug" },
          { filename: "feature.yml", name: "Feature request form", about: "Structured questions completed on GitHub", title: "", body: "", assigneeIDs: [], labelIDs: [], issueTypeID: "type-feature" },
        ],
      },
      "example/docs": {
        repository: "example/docs", repositoryID: "repo-docs", canWrite: true,
        warnings: ["Demo metadata includes the first page of documentation labels."],
        assignees: [{ id: "user-alex", name: "alex" }, { id: "user-sam", name: "sam" }],
        labels: [{ id: "label-docs", name: "documentation" }], milestones: [], issueTypes: [],
        projects: [{ id: "project-website", title: "Website / Current sprint", url: websiteURL }], templates: [],
      },
      "example/desktop": {
        repository: "example/desktop", repositoryID: "repo-desktop", canWrite: true, warnings: [],
        assignees: [{ id: "user-alex", name: "alex" }, { id: "user-riley", name: "riley" }],
        labels: [{ id: "label-desktop", name: "desktop" }, { id: "label-release", name: "release" }],
        milestones: [{ id: "milestone-desktop", name: "Desktop 1.0" }], issueTypes: [{ id: "type-task", name: "Task" }],
        projects: [{ id: "project-desktop", title: "Desktop / Release board", url: desktopURL }], templates: [],
      },
      "example/failure": {
        repository: "example/failure", repositoryID: "repo-failure", canWrite: true, warnings: [],
        assignees: [{ id: "user-alex", name: "alex" }], labels: [], milestones: [], issueTypes: [], projects: [], templates: [],
      },
    };
    const demoState = {
      mode: "main",
      previewHorizontal: "left",
      previewVertical: "above",
      projectTitle: demoProjects[websiteURL].title,
      projectURL: websiteURL,
      pendingProjectURL: "",
      projects: Object.entries(demoProjects).map(([url, project]) => ({ url, title: project.title })),
      viewerLogin: "alex",
      isConfigured: false,
      isDemo: true,
      isLoading: false,
      errorMessage: "",
      lastSyncLabel: "Updated now",
      onlyMine: true,
      search: "",
      selectedIssueID: "",
      pinnedIssueID: "42",
      alwaysOnTop: true,
      showSettings: false,
      useCLI: true,
      hasSavedToken: false,
      inProgressStatuses: "In progress, Building",
      todoStatuses: "Backlog, Ready, Queued",
      statusOptions: [],
      statusVisibility: [],
      statusFieldName: "Status",
      canEditStatus: true,
      repositories: ["example/web-app", "example/docs"],
      isMutating: false,
      mutationError: "",
      mutationNotice: "",
      createdIssueURL: "",
      creationRevision: 0,
      detailIssue: null,
      composerRepository: "",
      composerMetadata: null,
      composerLoading: false,
      composerError: "",
      composerAttachments: [],
      attachmentError: "",
      issues: [],
    };

    function currentDemoProject() {
      return demoProjects[demoState.projectURL];
    }

    function demoGroup(status) {
      if (["In progress", "Building"].includes(status)) return "inProgress";
      if (["Backlog", "Ready", "Queued"].includes(status)) return "todo";
      return "other";
    }

    function activateDemoProject(url) {
      const project = demoProjects[url];
      if (!project) return;
      demoState.projectURL = url;
      demoState.pendingProjectURL = "";
      demoState.isLoading = false;
      demoState.projectTitle = project.title;
      demoState.statusOptions = project.statuses.map((name, index) => ({ id: `${url}-status-${index}`, name }));
      demoState.statusVisibility = project.visibility.map((option) => ({ ...option }));
      demoState.repositories = project.repositories.slice();
      demoState.selectedIssueID = "";
      demoState.detailIssue = null;
      applyDemoFilter();
    }

    function applyDemoFilter() {
      const issues = currentDemoProject()?.issues || [];
      demoState.issues = demoState.onlyMine ? issues.filter((issue) => issue.assignees.includes(demoState.viewerLogin)) : issues.slice();
      if (demoState.selectedIssueID) demoState.detailIssue = issues.find((issue) => issue.id === demoState.selectedIssueID) || null;
    }

    function finishDemoStatus(message) {
      const issue = currentDemoProject()?.issues.find((candidate) => candidate.id === String(message.id || ""));
      const option = demoState.statusOptions.find((candidate) => candidate.id === String(message.optionID || ""));
      if (issue) {
        issue.status = option?.name || "";
        issue.group = demoGroup(issue.status);
        demoState.mutationNotice = `Issue #${issue.number} status updated.`;
      }
      demoState.isMutating = false;
      applyDemoFilter();
      render(demoState);
    }

    function finishDemoCreate(message) {
      demoState.isMutating = false;
      if (message.repository === "example/failure") {
        demoState.mutationError = "Demo creation failed before an issue was created. The draft is still available.";
        render(demoState);
        return;
      }
      const number = 100 + demoState.creationRevision;
      const option = demoState.statusOptions.find((candidate) => candidate.id === String(message.optionID || ""));
      const composer = demoComposerCatalog[message.repository];
      const issue = {
        id: `created-${number}`,
        number,
        title: String(message.title || "Untitled issue"),
        body: String(message.body || ""),
        repository: String(message.repository || ""),
        status: option?.name || "",
        labels: (message.labelIDs || []).map((id) => composer?.labels.find((choice) => choice.id === id)?.name).filter(Boolean),
        assignees: (message.assigneeIDs || []).map((id) => composer?.assignees.find((choice) => choice.id === id)?.name).filter(Boolean),
        group: demoGroup(option?.name || ""),
      };
      currentDemoProject().issues.unshift(issue);
      demoState.creationRevision += 1;
      demoState.createdIssueURL = `https://github.com/${issue.repository}/issues/${issue.number}`;
      demoState.mutationNotice = message.repository === "example/partial"
        ? `Issue #${issue.number} was created, but adding it to the project failed. Open the issue to finish manually.`
        : `Issue #${issue.number} was created and added to the project.`;
      if (!message.createAnother) demoState.composerAttachments = [];
      applyDemoFilter();
      render(demoState);
    }

    function finishDemoComposerLoad(repository) {
      if (!sameRepository(demoState.composerRepository, repository)) return;
      demoState.composerLoading = false;
      demoState.composerMetadata = demoComposerCatalog[repository] || null;
      demoState.composerError = demoState.composerMetadata ? "" : "This demo repository does not expose composer metadata.";
      render(demoState);
    }

    function finishDemoAssignment(message) {
      const issue = currentDemoProject()?.issues.find((candidate) => candidate.id === String(message.id || ""));
      const composer = issue && demoComposerCatalog[issue.repository];
      if (issue && composer) {
        issue.assignees = stringArray(message.assigneeIDs).map((id) => composer.assignees.find((choice) => choice.id === id)?.name).filter(Boolean);
        demoState.mutationNotice = `Issue #${issue.number} assignees updated.`;
      }
      demoState.isMutating = false;
      applyDemoFilter();
      render(demoState);
    }

    activateDemoProject(websiteURL);
    window.webkit = {
      messageHandlers: {
        issues: {
          postMessage(message) {
            switch (message.action) {
              case "ready": break;
              case "minimize": demoState.mode = "icon"; break;
              case "open": demoState.mode = "main"; break;
              case "showFocus": demoState.mode = "focus"; break;
              case "quit": break;
              case "select": demoState.selectedIssueID = String(message.id || ""); demoState.detailIssue = currentDemoProject()?.issues.find((issue) => issue.id === demoState.selectedIssueID) || null; break;
              case "pin": demoState.pinnedIssueID = String(message.id || ""); demoState.mode = "focus"; break;
              case "settings": demoState.showSettings = Boolean(message.value); demoState.mode = "main"; break;
              case "preference": demoState[message.key] = message.value; if (message.key === "onlyMine") applyDemoFilter(); break;
              case "statusVisibility": {
                const visibility = currentDemoProject().visibility.find((option) => option.name === String(message.name || ""));
                if (visibility) visibility.visible = message.visible !== false;
                demoState.statusVisibility = currentDemoProject().visibility.map((option) => ({ ...option }));
                break;
              }
              case "selectProject": {
                const url = String(message.url || "");
                if (!demoProjects[url]) break;
                demoState.pendingProjectURL = url;
                demoState.isLoading = true;
                render(demoState);
                window.setTimeout(() => { activateDemoProject(url); render(demoState); }, 260);
                return;
              }
              case "clearMutationFeedback": demoState.mutationError = ""; demoState.mutationNotice = ""; demoState.createdIssueURL = ""; break;
              case "loadComposer": {
                const repository = String(message.repository || "").trim();
                demoState.composerRepository = repository;
                demoState.composerMetadata = null;
                demoState.composerLoading = true;
                demoState.composerError = "";
                render(demoState);
                window.setTimeout(() => finishDemoComposerLoad(repository), repository === "example/docs" ? 420 : 180);
                return;
              }
              case "changeStatus":
                if (demoState.isMutating) return;
                demoState.isMutating = true;
                demoState.mutationError = "";
                render(demoState);
                window.setTimeout(() => finishDemoStatus(message), 220);
                return;
              case "createIssue":
                if (demoState.isMutating) return;
                demoState.isMutating = true;
                demoState.mutationError = "";
                demoState.mutationNotice = "";
                demoState.createdIssueURL = "";
                render(demoState);
                window.setTimeout(() => finishDemoCreate(message), 360);
                return;
              case "updateAssignees":
                if (demoState.isMutating) return;
                demoState.isMutating = true;
                demoState.mutationError = "";
                render(demoState);
                window.setTimeout(() => finishDemoAssignment(message), 240);
                return;
              case "chooseAttachments":
                demoState.attachmentError = "";
                if (!demoState.composerAttachments.some((attachment) => attachment.id === "demo-image")) {
                  demoState.composerAttachments.push({ id: "demo-image", name: "layout-reference.png", size: 248320 });
                }
                break;
              case "removeAttachment":
                demoState.composerAttachments = demoState.composerAttachments.filter((attachment) => attachment.id !== String(message.id || ""));
                break;
              case "openIssueComposerOnGitHub": break;
              case "openCreatedIssue": break;
              case "leaveDemo": demoState.isDemo = false; demoState.isConfigured = false; demoState.showSettings = false; demoState.projectTitle = "GitHub Issues"; demoState.projectURL = ""; demoState.projects = []; break;
              case "demo": demoState.isDemo = true; activateDemoProject(websiteURL); break;
              case "disconnect": demoState.isConfigured = false; demoState.isDemo = false; demoState.showSettings = false; demoState.projectTitle = "GitHub Issues"; demoState.projectURL = ""; break;
              case "connect": {
                const url = String(message.projectURL || "");
                if (!demoProjects[url]) demoProjects[url] = { title: "Added project", statuses: ["Ready", "Done"], visibility: ["Ready", "Done", ""].map((name) => ({ name, visible: true })), repositories: [], issues: [] };
                demoState.projects = Object.entries(demoProjects).map(([projectURL, project]) => ({ url: projectURL, title: project.title }));
                demoState.isDemo = true;
                activateDemoProject(url);
                break;
              }
              default: break;
            }
            render(demoState);
          },
        },
      },
    };
    installDemoPointerHover(demoState);
    render(demoState);
  }

  function installDemoPointerHover(demoState) {
    let openTimer = 0;
    let closeTimer = 0;
    const contains = (node, event) => {
      if (!node || node.hidden) return false;
      const rect = node.getBoundingClientRect();
      return event.clientX >= rect.left && event.clientX <= rect.right && event.clientY >= rect.top && event.clientY <= rect.bottom;
    };
    document.addEventListener("pointermove", (event) => {
      if (demoState.mode === "icon") {
        window.clearTimeout(closeTimer);
        if (!contains(nodes.orbBadge, event)) {
          window.clearTimeout(openTimer);
          return;
        }
        if (!openTimer) openTimer = window.setTimeout(() => {
          openTimer = 0;
          demoState.mode = "preview";
          render(demoState);
        }, 180);
        return;
      }
      window.clearTimeout(openTimer);
      openTimer = 0;
      if (demoState.mode !== "preview" || contains(nodes.preview, event)) {
        window.clearTimeout(closeTimer);
        closeTimer = 0;
        return;
      }
      if (!closeTimer) closeTimer = window.setTimeout(() => {
        closeTimer = 0;
        demoState.mode = "icon";
        render(demoState);
      }, 250);
    });
  }

  hydrateStaticIcons();
  bindEvents();
  installDemoBridge();
  if (!demoRequested) render(state);
  window.renderState = render;
  post("ready");
})();
