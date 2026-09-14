import { constants as fsConstants } from 'node:fs';
import { access, readFile, stat } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import path from 'node:path';

const GRAPHQL_URL = 'https://api.github.com/graphql';
const USER_AGENT = 'Issues Electron';

const PROJECT_QUERY = (isOrganization) => `
query IssuesProjectSnapshot($owner: String!, $number: Int!, $cursor: String) {
  viewer { id login }
  ${isOrganization ? 'organization(login: $owner)' : 'user(login: $owner)'} {
    projectV2(number: $number) {
      title id url
      fields(first: 100) { nodes { __typename ... on ProjectV2SingleSelectField { id name options { id name } } } }
      repositories(first: 100) { nodes { nameWithOwner } }
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isArchived
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name field { ...ProjectFieldName } }
            ... on ProjectV2ItemFieldTextValue { text field { ...ProjectFieldName } }
            ... on ProjectV2ItemFieldIterationValue { title field { ...ProjectFieldName } }
            ... on ProjectV2ItemFieldMultiSelectValue { value field { ...ProjectFieldName } }
          }
          statoValue: fieldValueByName(name: "Stato") {
            ... on ProjectV2ItemFieldSingleSelectValue { name field { ...ProjectFieldName } }
          }
          content {
            __typename
            ... on Issue {
              id number title body url state updatedAt repository { nameWithOwner }
              labels(first: 100) { nodes { name } }
              assignees(first: 100) { nodes { login } }
            }
          }
        }
      }
    }
  }
}
fragment ProjectFieldName on ProjectV2FieldConfiguration {
  ... on ProjectV2Field { name }
  ... on ProjectV2IterationField { name }
  ... on ProjectV2MultiSelectField { name }
  ... on ProjectV2SingleSelectField { name }
}`;

const COMPOSER_QUERY = `
query IssueComposerMetadata($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    id nameWithOwner hasIssuesEnabled viewerCanCreateIssues viewerPermission
    assignableUsers(first: 100) { pageInfo { hasNextPage endCursor } nodes { id login } }
    labels(first: 100) { pageInfo { hasNextPage endCursor } nodes { id name } }
    milestones(first: 100, states: [OPEN]) { pageInfo { hasNextPage endCursor } nodes { id title } }
    issueTypes(first: 100) { pageInfo { hasNextPage endCursor } nodes { id name } }
    projectsV2(first: 100, minPermissionLevel: READ) { pageInfo { hasNextPage endCursor } nodes { id title url } }
    issueTemplates {
      filename name about body title type { id }
      assignees(first: 100) { pageInfo { hasNextPage endCursor } nodes { id login } }
      labels(first: 100) { pageInfo { hasNextPage endCursor } nodes { id name } }
    }
    owner {
      ... on Organization { ownerProjects: projectsV2(first: 100, minPermissionLevel: READ) { pageInfo { hasNextPage endCursor } nodes { id title url } } }
      ... on User { ownerProjects: projectsV2(first: 100, minPermissionLevel: READ) { pageInfo { hasNextPage endCursor } nodes { id title url } } }
    }
  }
}`;

const UPDATE_STATUS = `mutation UpdateProjectStatus($projectID: ID!, $itemID: ID!, $fieldID: ID!, $optionID: String!) {
  updateProjectV2ItemFieldValue(input: { projectId: $projectID, itemId: $itemID, fieldId: $fieldID, value: { singleSelectOptionId: $optionID } }) { projectV2Item { id } }
}`;
const CLEAR_STATUS = `mutation ClearProjectStatus($projectID: ID!, $itemID: ID!, $fieldID: ID!) {
  clearProjectV2ItemFieldValue(input: { projectId: $projectID, itemId: $itemID, fieldId: $fieldID }) { projectV2Item { id } }
}`;
const REPLACE_ASSIGNEES = `mutation ReplaceIssueAssignees($issueID: ID!, $assigneeIDs: [ID!]) {
  updateIssue(input: { id: $issueID, assigneeIds: $assigneeIDs }) { issue { assignees(first: 100) { pageInfo { hasNextPage endCursor } nodes { id login } } } }
}`;
const CREATE_ISSUE = `mutation CreateRepositoryIssue(
  $repositoryID: ID!, $title: String!, $body: String!, $assigneeIDs: [ID!], $labelIDs: [ID!],
  $milestoneID: ID, $issueTypeID: ID, $issueTemplate: String, $parentIssueID: ID, $projectV2IDs: [ID!]
) {
  createIssue(input: { repositoryId: $repositoryID, title: $title, body: $body, assigneeIds: $assigneeIDs,
    labelIds: $labelIDs, milestoneId: $milestoneID, issueTypeId: $issueTypeID, issueTemplate: $issueTemplate,
    parentIssueId: $parentIssueID, projectV2Ids: $projectV2IDs }) {
    issue { id url projectItems(first: 100) { pageInfo { hasNextPage endCursor } nodes { id project { id } } } }
  }
}`;
const RESOLVE_PROJECT_ITEMS = `query ResolveCreatedIssueProjectItems($issueID: ID!) {
  node(id: $issueID) { ... on Issue { projectItems(first: 100) { pageInfo { hasNextPage endCursor } nodes { id project { id } } } } }
}`;
const ADD_BLOCKED_BY = `mutation AddIssueDependency($subjectID: ID!, $blockingIssueID: ID!) {
  addBlockedBy(input: { issueId: $subjectID, blockingIssueId: $blockingIssueID }) { issue { id } blockingIssue { id } }
}`;
const ATTACHMENT_REPOSITORY = `query IssueAttachmentRepository($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) { databaseId viewerPermission }
}`;

const FILE_TYPES = new Map([
  ['png', ['image/png', false]], ['jpg', ['image/jpeg', false]], ['jpeg', ['image/jpeg', false]],
  ['gif', ['image/gif', false]], ['webp', ['image/webp', false]], ['svg', ['image/svg+xml', false]],
  ['mp4', ['video/mp4', true]], ['mov', ['video/quicktime', true]], ['webm', ['video/webm', true]],
]);

function fail(message) { throw new Error(message); }
function nonempty(value) { return typeof value === 'string' && value.trim() ? value.trim() : null; }
function unique(values = []) { return [...new Set(values.filter((value) => typeof value === 'string' && value.length > 0))]; }
function redact(message, secret) { return secret ? String(message).split(secret).join('[REDACTED]') : String(message); }
function safeDetail(error) { return error instanceof Error && error.message.trim() ? error.message.trim() : 'No confirmation was received.'; }
function partial(message, error) { return `${message} GitHub reported: ${safeDetail(error)}`; }
function checkAbort(signal) { if (signal?.aborted) throw signal.reason instanceof Error ? signal.reason : new DOMException('This operation was aborted', 'AbortError'); }

function parseRepository(value) {
  const match = typeof value === 'string' && value.trim().match(/^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)$/);
  if (!match) fail('Enter a repository as owner/name.');
  return { owner: match[1], name: match[2], fullName: `${match[1]}/${match[2]}` };
}

function trustedGitHubURL(value, expectedPath) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.hostname.toLowerCase() === 'github.com' && !url.username && !url.password &&
      (!expectedPath || url.pathname.replace(/\/$/, '') === expectedPath.replace(/\/$/, ''));
  } catch { return false; }
}

export function parseProjectURL(input) {
  let url;
  try { url = new URL(String(input).trim()); } catch { fail('Enter a valid GitHub project URL.'); }
  const parts = url.pathname.split('/').filter(Boolean);
  const number = Number(parts[3]);
  if (url.protocol !== 'https:' || url.hostname.toLowerCase() !== 'github.com' || url.username || url.password ||
      url.search || url.hash || parts.length !== 4 || !['users', 'orgs'].includes(parts[0]) ||
      parts[2] !== 'projects' || !/^[A-Za-z0-9-]+$/.test(parts[1] || '') ||
      !/^\d+$/.test(parts[3] || '') || !Number.isSafeInteger(number) || number <= 0) {
    fail('Enter a canonical GitHub project URL such as https://github.com/orgs/acme/projects/1.');
  }
  const owner = parts[1];
  const isOrganization = parts[0] === 'orgs';
  return { url: `https://github.com/${parts[0]}/${owner}/projects/${number}`, owner, number, isOrganization };
}

async function inspectAttachment(filePath, statImpl = stat) {
  const name = path.basename(filePath || '');
  if (!filePath || !name) fail(`The attachment ${name} is unavailable.`);
  const extension = path.extname(name).slice(1).toLowerCase();
  const type = FILE_TYPES.get(extension);
  if (!type) fail(`GitHub does not support ${extension ? `.${extension}` : 'this file'} as an issue attachment. Choose PNG, JPG, JPEG, GIF, WEBP, SVG, MP4, MOV, or WEBM.`);
  let info;
  try { info = await statImpl(filePath); } catch { fail(`The attachment ${name} is unavailable.`); }
  if (!info.isFile()) fail(`The attachment ${name} is not a regular file.`);
  if (info.size <= 0) fail(`The attachment ${name} is empty.`);
  const maxBytes = type[1] ? 100 * 1024 * 1024 : 10 * 1024 * 1024;
  if (info.size > maxBytes) fail(`The attachment ${name} exceeds GitHub's ${maxBytes / 1048576} MB limit.`);
  return { name, size: info.size, contentType: type[0] };
}

export async function validateAttachment(filePath) {
  const { name, size } = await inspectAttachment(filePath);
  return { name, size };
}

function defaultExecFile(file, args, options) {
  return new Promise((resolve, reject) => {
    const { input, ...execOptions } = options;
    const child = execFile(file, args, execOptions, (error, stdout, stderr) => {
      if (error) { error.stderr = stderr; reject(error); }
      else resolve({ stdout, stderr });
    });
    child.stdin.on('error', () => {});
    child.stdin.end(input ?? '');
  });
}

function defaultSleep(milliseconds, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(signal.reason || new DOMException('This operation was aborted', 'AbortError')); return; }
    const timer = setTimeout(done, milliseconds);
    function done() { signal?.removeEventListener('abort', aborted); resolve(); }
    function aborted() { clearTimeout(timer); signal.removeEventListener('abort', aborted); reject(signal.reason || new DOMException('This operation was aborted', 'AbortError')); }
    signal?.addEventListener('abort', aborted, { once: true });
  });
}

function graphQLError(payload, accessMessage) {
  const errors = Array.isArray(payload?.errors) ? payload.errors : [];
  if (!errors.length) return null;
  const details = errors.map((error) => `${error?.type || ''} ${error?.message || ''}`).join(' ').toLowerCase();
  if (['forbidden', 'not accessible', 'scope', 'permission'].some((word) => details.includes(word))) return new Error(accessMessage);
  return new Error(`GitHub GraphQL: ${errors.map((error) => error?.message).filter(Boolean).join('; ') || 'Unknown error'}`);
}

function validateAuth(auth) {
  if (!auth || typeof auth !== 'object') fail('GitHub authentication is required.');
  if (!auth.useCLI && !nonempty(auth.token)) fail('The GitHub token is empty. Enter a token that can access the project.');
}

function createdIssueFrom(payload) {
  const issue = payload?.data?.createIssue?.issue;
  return issue && nonempty(issue.id) && trustedGitHubURL(issue.url) ? issue : null;
}

function projectItems(connection) {
  const items = new Map();
  for (const node of connection?.nodes || []) if (nonempty(node?.id) && nonempty(node?.project?.id)) items.set(node.project.id, node.id);
  return { items, hasNextPage: connection?.pageInfo?.hasNextPage === true };
}

function parseReference(value, kind, repository) {
  const displayValue = String(value ?? '').trim();
  if (/^[1-9]\d*$/.test(displayValue)) {
    const target = parseRepository(repository);
    return { kind, owner: target.owner, repository: target.name, number: Number(displayValue), displayValue };
  }
  let url;
  try { url = new URL(displayValue); } catch { url = null; }
  const parts = url?.pathname.split('/').filter(Boolean) || [];
  if (!url || url.protocol !== 'https:' || url.hostname.toLowerCase() !== 'github.com' || url.search || url.hash ||
      parts.length !== 4 || parts[2] !== 'issues' || !/^[1-9]\d*$/.test(parts[3])) {
    fail(`GitHub GraphQL: Issue reference ${displayValue} must be a positive issue number or a full https://github.com/owner/repo/issues/N URL.`);
  }
  return { kind, owner: parts[0], repository: parts[1], number: Number(parts[3]), displayValue };
}

function preflightQuery(references) {
  const definitions = references.map((_, index) => `$ref${index}Owner: String!, $ref${index}Name: String!, $ref${index}Number: Int!`);
  const selections = references.map((_, index) => `ref${index}: repository(owner: $ref${index}Owner, name: $ref${index}Name) { issue(number: $ref${index}Number) { id } }`);
  return `query IssueCreationPreflight(
    $owner: String!, $name: String!, $assigneeIDs: [ID!]!, $labelIDs: [ID!]!, $projectIDs: [ID!]!,
    $milestoneIDs: [ID!]!, $issueTypeIDs: [ID!]!${definitions.length ? `, ${definitions.join(', ')}` : ''}
  ) {
    repository(owner: $owner, name: $name) { id nameWithOwner hasIssuesEnabled viewerCanCreateIssues viewerPermission issueTemplates { filename } }
    assignees: nodes(ids: $assigneeIDs) { __typename id }
    labels: nodes(ids: $labelIDs) { __typename id }
    projects: nodes(ids: $projectIDs) { __typename id }
    milestones: nodes(ids: $milestoneIDs) { __typename id }
    issueTypes: nodes(ids: $issueTypeIDs) { __typename id }
    ${selections.join('\n')}
  }`;
}

export class GitHubClient {
  constructor({
    fetchImpl = globalThis.fetch, execFileImpl = defaultExecFile, accessImpl = access,
    statImpl = stat, readFileImpl = readFile, now = () => new Date(), sleep = defaultSleep,
    env = process.env, platform = process.platform,
  } = {}) {
    if (typeof fetchImpl !== 'function') fail('A fetch implementation is required.');
    this.fetchImpl = fetchImpl; this.execFileImpl = execFileImpl; this.accessImpl = accessImpl;
    this.statImpl = statImpl; this.readFileImpl = readFileImpl; this.now = now; this.sleep = sleep;
    this.env = env; this.platform = platform;
  }

  async findGH() {
    const pathAPI = this.platform === 'win32' ? path.win32 : path;
    const delimiter = this.platform === 'win32' ? ';' : path.delimiter;
    const fixed = this.platform === 'win32'
      ? [this.env.LOCALAPPDATA && pathAPI.join(this.env.LOCALAPPDATA, 'Programs', 'GitHub CLI', 'gh.exe'),
          this.env.ProgramFiles && pathAPI.join(this.env.ProgramFiles, 'GitHub CLI', 'gh.exe'),
          this.env['ProgramFiles(x86)'] && pathAPI.join(this.env['ProgramFiles(x86)'], 'GitHub CLI', 'gh.exe')]
      : ['/opt/homebrew/bin/gh', '/usr/local/bin/gh', '/usr/bin/gh'];
    const executable = this.platform === 'win32' ? 'gh.exe' : 'gh';
    const candidates = [...fixed, ...(this.env.PATH || '').split(delimiter).filter(Boolean).map((entry) => pathAPI.join(entry, executable))].filter(Boolean);
    for (const candidate of [...new Set(candidates)]) {
      try { await this.accessImpl(candidate, fsConstants.X_OK); return candidate; } catch { /* keep looking */ }
    }
    fail('GitHub CLI is unavailable. Install `gh` or choose token authentication.');
  }

  async runCLI(args, { input, signal } = {}) {
    checkAbort(signal);
    const executable = await this.findGH();
    try {
      const result = await this.execFileImpl(executable, args, { input, encoding: 'utf8', timeout: 20_000, maxBuffer: 10 * 1024 * 1024, signal });
      return typeof result === 'string' || Buffer.isBuffer(result) ? String(result) : String(result?.stdout ?? '');
    } catch (error) {
      if (signal?.aborted || error?.name === 'AbortError') throw error;
      if (error?.killed || error?.code === 'ETIMEDOUT') fail('GitHub CLI did not respond within 20 seconds. Check `gh auth status` and try again.');
      const stderr = String(error?.stderr || '').trim().replace(/\s+/g, ' ');
      fail(`GitHub CLI did not complete the request${stderr ? `: ${stderr}` : ''}. Check \`gh auth status\`; reads need \`read:project\`, while changes need \`project\` and repository Issues write access.`);
    }
  }

  async graphql(query, variables, auth, { signal, accessMessage = 'The project is not accessible. Grant the `read:project` scope (and `read:org` if the organization requires it), or run `gh auth refresh -s read:project`.' } = {}) {
    validateAuth(auth); checkAbort(signal);
    const body = JSON.stringify({ query, variables });
    let text;
    if (auth.useCLI) {
      text = await this.runCLI(['api', 'graphql', '--input', '-'], { input: body, signal });
    } else {
      const token = auth.token.trim();
      let response;
      try {
        response = await this.fetchImpl(GRAPHQL_URL, { method: 'POST', signal, headers: {
          Accept: 'application/json', 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'User-Agent': USER_AGENT,
        }, body });
      } catch (error) {
        if (signal?.aborted || error?.name === 'AbortError') throw error;
        fail(`Could not connect to GitHub: ${redact(safeDetail(error), token)}`);
      }
      if (response.status === 401) fail('GitHub authentication failed. Check the token or run `gh auth status`.');
      if (response.status === 403) fail(accessMessage);
      if (!response.ok) fail(`Could not connect to GitHub: HTTP ${response.status}`);
      try { text = await response.text(); } catch (error) { fail(`Could not connect to GitHub: ${redact(safeDetail(error), token)}`); }
    }
    try { return JSON.parse(text); } catch { fail('GitHub returned an invalid response. Try again shortly.'); }
  }

  async fetchProject(url, auth, opts = {}) {
    const project = parseProjectURL(url);
    let cursor = null, title = null, viewerLogin = null, metadata = null;
    const issues = [], repositories = new Set(), visited = new Set();
    do {
      const payload = await this.graphql(PROJECT_QUERY(project.isOrganization), { owner: project.owner, number: project.number, cursor }, auth, opts);
      const gqlError = graphQLError(payload, 'The project is not accessible. Grant the `read:project` scope (and `read:org` if the organization requires it), or run `gh auth refresh -s read:project`.');
      if (gqlError) throw gqlError;
      const data = payload?.data;
      const projectData = (project.isOrganization ? data?.organization : data?.user)?.projectV2;
      if (!projectData || !data?.viewer?.login) fail('The project is not accessible. Grant the `read:project` scope (and `read:org` if the organization requires it), or run `gh auth refresh -s read:project`.');
      if (projectData.url && !trustedGitHubURL(projectData.url, new URL(project.url).pathname)) fail('GitHub returned an invalid response. Try again shortly.');
      title ??= projectData.title; viewerLogin ??= data.viewer.login;
      for (const repo of projectData.repositories?.nodes || []) if (repo?.nameWithOwner) repositories.add(repo.nameWithOwner);
      const fields = (projectData.fields?.nodes || []).filter((field) => field?.__typename === 'ProjectV2SingleSelectField' && field.id && field.name);
      const statusField = fields.find((field) => field.name.toLowerCase() === 'status') || fields.find((field) => field.name.toLowerCase() === 'stato') || null;
      metadata ??= projectData.id ? { id: projectData.id, statusField: statusField ? { id: statusField.id, name: statusField.name, options: (statusField.options || []).filter((option) => option?.id && option?.name).map(({ id, name }) => ({ id, name })) } : null, repositories: [], viewerID: data.viewer.id ?? null } : null;
      const connection = projectData.items;
      if (!connection?.pageInfo || !Array.isArray(connection.nodes)) fail('GitHub returned an invalid response. Try again shortly.');
      for (const item of connection.nodes) {
        const content = item?.content;
        if (item?.isArchived !== false || !item.id || content?.__typename !== 'Issue' || !['OPEN', 'CLOSED'].includes(content.state) ||
            !content.id || !Number.isInteger(content.number) || typeof content.title !== 'string' || typeof content.body !== 'string' ||
            !trustedGitHubURL(content.url) || !content.repository?.nameWithOwner || !content.updatedAt) continue;
        repositories.add(content.repository.nameWithOwner);
        const value = statusField?.name?.toLowerCase() === 'stato' ? item.statoValue : item.fieldValueByName;
        issues.push({ id: content.id, number: content.number, title: content.title, body: content.body, url: content.url,
          repository: content.repository.nameWithOwner, status: value?.name ?? value?.text ?? value?.title ?? value?.value ?? '',
          labels: (content.labels?.nodes || []).map((node) => node?.name).filter(Boolean),
          assignees: (content.assignees?.nodes || []).map((node) => node?.login).filter(Boolean),
          updatedAt: content.updatedAt, projectItemID: item.id });
      }
      if (!connection.pageInfo.hasNextPage) cursor = null;
      else {
        const next = nonempty(connection.pageInfo.endCursor);
        if (!next || visited.has(next)) fail('GitHub returned an invalid response. Try again shortly.');
        visited.add(next); cursor = next;
      }
    } while (cursor);
    if (!title || !viewerLogin) fail('GitHub returned an invalid response. Try again shortly.');
    if (metadata) metadata.repositories = [...repositories].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }));
    return { project, title, viewerLogin, issues, fetchedAt: this.now().toISOString(), metadata };
  }

  async fetchIssueComposer(repository, auth, opts = {}) {
    const target = parseRepository(repository);
    const payload = await this.graphql(COMPOSER_QUERY, { owner: target.owner, name: target.name }, auth, {
      ...opts, accessMessage: `GitHub cannot create an issue in ${target.fullName}. Make sure Issues are enabled and grant repository Issues write access.`,
    });
    const gqlError = graphQLError(payload, 'The project is not accessible. Grant the `read:project` scope and repository access.');
    if (gqlError) throw gqlError;
    const repo = payload?.data?.repository;
    if (!repo?.id || !repo.hasIssuesEnabled) fail(`GitHub cannot create an issue in ${target.fullName}. Make sure Issues are enabled and grant repository Issues write access.`);
    const warnings = [];
    const warn = (connection, name) => { if (connection?.pageInfo?.hasNextPage) warnings.push(`GitHub returned only the first 100 ${name}; refine the repository data on GitHub to see the complete list.`); };
    warn(repo.assignableUsers, 'assignable users'); warn(repo.labels, 'labels'); warn(repo.milestones, 'open milestones');
    warn(repo.issueTypes, 'issue types'); warn(repo.projectsV2, 'repository projects'); warn(repo.owner?.ownerProjects, 'owner projects');
    for (const template of repo.issueTemplates || []) { warn(template.assignees, `assignees for template ${template.filename}`); warn(template.labels, `labels for template ${template.filename}`); }
    const projects = new Map();
    for (const item of [...(repo.projectsV2?.nodes || []), ...(repo.owner?.ownerProjects?.nodes || [])]) {
      if (item?.id && item.title && trustedGitHubURL(item.url)) projects.set(item.id, { id: item.id, title: item.title, url: item.url });
    }
    return { repository: repo.nameWithOwner || target.fullName, repositoryID: repo.id,
      assignees: (repo.assignableUsers?.nodes || []).filter(Boolean).map((item) => ({ id: item.id, name: item.login })),
      labels: (repo.labels?.nodes || []).filter(Boolean).map((item) => ({ id: item.id, name: item.name })),
      milestones: (repo.milestones?.nodes || []).filter(Boolean).map((item) => ({ id: item.id, name: item.title })),
      issueTypes: (repo.issueTypes?.nodes || []).filter(Boolean).map((item) => ({ id: item.id, name: item.name })),
      projects: [...projects.values()].sort((a, b) => a.title.localeCompare(b.title, undefined, { sensitivity: 'base' })),
      templates: (repo.issueTemplates || []).map((item) => ({ filename: item.filename, name: item.name, about: item.about || '', body: item.body || '', title: item.title || '',
        assigneeIDs: (item.assignees?.nodes || []).map((node) => node?.id).filter(Boolean), labelIDs: (item.labels?.nodes || []).map((node) => node?.id).filter(Boolean), issueTypeID: item.type?.id ?? null })),
      canWrite: ['TRIAGE', 'WRITE', 'MAINTAIN', 'ADMIN'].includes(repo.viewerPermission || ''), warnings };
  }

  async updateStatus({ projectID, itemID, fieldID, optionID } = {}, auth, opts = {}) {
    if (![projectID, itemID, fieldID].every(nonempty)) fail('GitHub returned an invalid response. Try again shortly.');
    const clearing = !nonempty(optionID);
    const variables = { projectID, itemID, fieldID, ...(clearing ? {} : { optionID }) };
    const payload = await this.graphql(clearing ? CLEAR_STATUS : UPDATE_STATUS, variables, auth, { ...opts, accessMessage: 'GitHub denied the project change. Grant the `project` scope and project write access.' });
    const gqlError = graphQLError(payload, 'GitHub denied the project change. Grant the `project` scope and project write access.');
    if (gqlError) throw gqlError;
    const key = clearing ? 'clearProjectV2ItemFieldValue' : 'updateProjectV2ItemFieldValue';
    if (payload?.data?.[key] == null) fail('GitHub returned an invalid response. Try again shortly.');
  }

  async updateAssignees(issueID, assigneeIDs, auth, opts = {}) {
    if (!nonempty(issueID) || !Array.isArray(assigneeIDs) || assigneeIDs.some((id) => !nonempty(id))) fail('GitHub returned an invalid response. Try again shortly.');
    const payload = await this.graphql(REPLACE_ASSIGNEES, { issueID, assigneeIDs: unique(assigneeIDs) }, auth, { ...opts, accessMessage: 'GitHub denied the issue change. Grant repository Issues write access.' });
    const gqlError = graphQLError(payload, 'GitHub denied the issue change. Grant repository Issues write access.');
    if (gqlError) throw gqlError;
    const connection = payload?.data?.updateIssue?.issue?.assignees;
    if (!connection || connection.pageInfo?.hasNextPage) fail('GitHub returned an invalid response. Try again shortly.');
    return (connection.nodes || []).filter(Boolean).map((node) => ({ id: node.id, name: node.login }));
  }

  async createIssue(request, auth, opts = {}) {
    const target = parseRepository(request?.repository);
    const inputAssignees = request.assigneeIDs ?? [], inputLabels = request.labelIDs ?? [], additionalProjectIDs = request.additionalProjectIDs ?? [];
    const blockedBy = request.blockedBy ?? [], blocking = request.blocking ?? [];
    if (![inputAssignees, inputLabels, additionalProjectIDs, blockedBy, blocking].every(Array.isArray)) fail('GitHub returned an invalid response. Try again shortly.');
    const assigneeIDs = unique(inputAssignees), labelIDs = unique(inputLabels);
    const fieldID = nonempty(request.statusFieldID), optionID = nonempty(request.statusOptionID);
    if (!nonempty(request.projectID) || !nonempty(request.title) || !Array.isArray(additionalProjectIDs) ||
        [...inputAssignees, ...inputLabels, ...additionalProjectIDs].some((id) => !nonempty(id)) || Boolean(fieldID) !== Boolean(optionID)) {
      fail('GitHub returned an invalid response. Try again shortly.');
    }
    const references = [];
    if (nonempty(request.parentIssue)) references.push(parseReference(request.parentIssue, 'parent', target.fullName));
    for (const value of blockedBy) references.push(parseReference(value, 'blockedBy', target.fullName));
    for (const value of blocking) references.push(parseReference(value, 'blocking', target.fullName));
    const referenceKeys = references.map((ref) => `${ref.kind}:${ref.owner.toLowerCase()}/${ref.repository.toLowerCase()}#${ref.number}`);
    if (new Set(referenceKeys).size !== referenceKeys.length) fail('GitHub GraphQL: Duplicate issue references are not allowed.');
    const projectIDs = unique([request.projectID, ...additionalProjectIDs]);
    const milestoneIDs = unique(nonempty(request.milestoneID) ? [nonempty(request.milestoneID)] : []);
    const issueTypeIDs = unique(nonempty(request.issueTypeID) ? [nonempty(request.issueTypeID)] : []);
    const variables = { owner: target.owner, name: target.name, assigneeIDs, labelIDs, projectIDs, milestoneIDs, issueTypeIDs };
    references.forEach((ref, index) => { variables[`ref${index}Owner`] = ref.owner; variables[`ref${index}Name`] = ref.repository; variables[`ref${index}Number`] = ref.number; });
    const accessMessage = `GitHub cannot create an issue in ${target.fullName}. Make sure Issues are enabled, grant repository Issues write access, and grant the \`project\` scope.`;
    const preflight = await this.graphql(preflightQuery(references), variables, auth, { ...opts, accessMessage });
    const preflightError = graphQLError(preflight, accessMessage); if (preflightError) throw preflightError;
    const data = preflight?.data, repo = data?.repository;
    if (!repo?.id || !repo.hasIssuesEnabled || !repo.viewerCanCreateIssues) fail(accessMessage);
    const requireNodes = (key, expected, typename) => {
      const actual = (data[key] || []).filter((node) => node?.__typename === typename).map((node) => node.id);
      if (actual.length !== expected.length || new Set(actual).size !== new Set(expected).size || expected.some((id) => !actual.includes(id))) fail(`GitHub GraphQL: One or more selected ${typename} IDs are invalid or inaccessible.`);
    };
    requireNodes('assignees', assigneeIDs, 'User'); requireNodes('labels', labelIDs, 'Label'); requireNodes('projects', projectIDs, 'ProjectV2');
    requireNodes('milestones', milestoneIDs, 'Milestone'); requireNodes('issueTypes', issueTypeIDs, 'IssueType');
    const template = nonempty(request.templateFilename);
    if (template && !(repo.issueTemplates || []).some((item) => item.filename === template)) fail(`GitHub GraphQL: The selected issue template is not available in ${target.fullName}.`);
    const issueIDs = references.map((ref, index) => {
      const id = data[`ref${index}`]?.issue?.id;
      if (!id) fail(`GitHub GraphQL: Issue reference ${ref.displayValue} was not found or is not accessible.`);
      return id;
    });
    const createVariables = { repositoryID: repo.id, title: request.title, body: request.body || '', assigneeIDs, labelIDs, projectV2IDs: projectIDs };
    if (milestoneIDs[0]) createVariables.milestoneID = milestoneIDs[0];
    if (issueTypeIDs[0]) createVariables.issueTypeID = issueTypeIDs[0];
    if (template) createVariables.issueTemplate = template;
    const parentIndex = references.findIndex((ref) => ref.kind === 'parent'); if (parentIndex >= 0) createVariables.parentIssueID = issueIDs[parentIndex];
    let createdPayload;
    try { createdPayload = await this.graphql(CREATE_ISSUE, createVariables, auth, { ...opts, accessMessage }); }
    catch (error) {
      if (/authentication failed|denied|cannot create|GraphQL/i.test(safeDetail(error))) throw error;
      fail(`GitHub did not confirm whether the issue was created. Check the repository before retrying to avoid a duplicate. ${safeDetail(error)}`);
    }
    const created = createdIssueFrom(createdPayload);
    if (!created) {
      const gqlError = graphQLError(createdPayload, accessMessage); if (gqlError) throw gqlError;
      fail('GitHub did not confirm whether the issue was created. Check the repository before retrying to avoid a duplicate. GitHub returned an invalid response.');
    }
    const warnings = [];
    if (Array.isArray(createdPayload.errors) && createdPayload.errors.length) warnings.push(`The issue was created, but GitHub also reported: ${createdPayload.errors.map((item) => item.message).filter(Boolean).join('; ')}`);
    let resolution = projectItems(created.projectItems);
    for (let attempt = 0; projectIDs.some((id) => !resolution.items.has(id)) && attempt < 3; attempt += 1) {
      if (attempt) { try { await this.sleep(attempt === 1 ? 500 : 1500, opts.signal); } catch { break; } }
      try {
        const payload = await this.graphql(RESOLVE_PROJECT_ITEMS, { issueID: created.id }, auth, opts);
        const gqlError = graphQLError(payload, 'The project is not accessible. Grant the `read:project` scope.'); if (gqlError) throw gqlError;
        const latest = projectItems(payload?.data?.node?.projectItems);
        for (const [projectID, itemID] of latest.items) resolution.items.set(projectID, itemID);
        if (latest.hasNextPage) break;
      } catch (error) { if (opts.signal?.aborted) break; }
    }
    const projectItemID = resolution.items.get(request.projectID) || null;
    const unconfirmed = projectIDs.filter((id) => !resolution.items.has(id));
    if (unconfirmed.length) warnings.push(`The issue was created, but GitHub did not confirm ${unconfirmed.length} requested project attachment${unconfirmed.length === 1 ? '' : 's'}. Open the issue and check its projects before retrying.`);
    if (!projectItemID && fieldID && optionID) warnings.push('GitHub did not return the active project item, so its requested status could not be set.');
    if (projectItemID && fieldID && optionID) {
      try { await this.updateStatus({ projectID: request.projectID, itemID: projectItemID, fieldID, optionID }, auth, opts); }
      catch (error) { warnings.push(partial('The issue was created, but GitHub could not set its project status.', error)); }
    }
    for (let index = 0; index < references.length; index += 1) {
      const ref = references[index]; if (ref.kind === 'parent') continue;
      const subjectID = ref.kind === 'blockedBy' ? created.id : issueIDs[index];
      const blockingIssueID = ref.kind === 'blockedBy' ? issueIDs[index] : created.id;
      try {
        const payload = await this.graphql(ADD_BLOCKED_BY, { subjectID, blockingIssueID }, auth, { ...opts, accessMessage });
        const gqlError = graphQLError(payload, accessMessage); if (gqlError) throw gqlError;
        if (payload?.data?.addBlockedBy == null) fail('GitHub returned an invalid response. Try again shortly.');
      } catch (error) { warnings.push(partial(`The issue was created, but GitHub could not add the dependency ${ref.displayValue}.`, error)); }
    }
    return { issueID: created.id, url: created.url, projectItemID, warning: warnings.length ? warnings.join(' ') : null };
  }

  async resolvedAttachmentToken(auth, signal) {
    validateAuth(auth);
    let token = auth.useCLI ? await this.runCLI(['auth', 'token', '--hostname', 'github.com'], { signal }) : auth.token;
    token = token.trim();
    if (!token) fail('GitHub CLI could not provide an authentication token. Run `gh auth login` and try again.');
    if (!/^(?:gho_|ghp_|github_pat_)/.test(token)) fail('GitHub attachment uploads require an OAuth token, classic personal access token, or fine-grained personal access token.');
    return token;
  }

  async uploadAttachment(repository, filePath, auth, opts = {}) {
    const file = await inspectAttachment(filePath, this.statImpl);
    const target = parseRepository(repository);
    const token = await this.resolvedAttachmentToken(auth, opts.signal);
    const headers = { Accept: 'application/vnd.github+json', Authorization: `Bearer ${token}`, 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': USER_AGENT };
    let metadataResponse;
    try { metadataResponse = await this.fetchImpl(GRAPHQL_URL, { method: 'POST', signal: opts.signal, redirect: 'manual', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: ATTACHMENT_REPOSITORY, variables: { owner: target.owner, name: target.name } }) }); }
    catch (error) { fail(`GitHub could not prepare the attachment upload. ${redact(safeDetail(error), token)}`); }
    if (metadataResponse.status >= 300 && metadataResponse.status < 400) fail('GitHub could not prepare the attachment upload. GitHub returned an unexpected redirect.');
    if ([401, 403].includes(metadataResponse.status)) fail('GitHub authentication failed. Check the saved token or run `gh auth status`.');
    if (metadataResponse.status === 404 || !metadataResponse.ok) fail('GitHub could not access that repository. Check its name and your repository access.');
    let metadata;
    try { metadata = await metadataResponse.json(); } catch { fail('GitHub could not access that repository. Check its name and your repository access.'); }
    if (metadata?.errors?.length || !metadata?.data?.repository?.databaseId) fail('GitHub could not access that repository. Check its name and your repository access.');
    if (!['ADMIN', 'MAINTAIN', 'WRITE'].includes(metadata.data.repository.viewerPermission)) fail('Attaching files requires write access to the repository.');
    let body;
    try { body = await this.readFileImpl(filePath); } catch { fail(`The attachment ${file.name} is unavailable.`); }
    if (body.length !== file.size) fail(`The attachment ${file.name} changed while it was being prepared. Choose it again.`);
    const uploadURL = new URL('https://uploads.github.com/user-attachments/assets');
    uploadURL.searchParams.set('name', file.name); uploadURL.searchParams.set('content_type', file.contentType);
    uploadURL.searchParams.set('repository_id', String(metadata.data.repository.databaseId));
    let response;
    try { response = await this.fetchImpl(uploadURL, { method: 'POST', signal: opts.signal, redirect: 'manual', headers: { ...headers, 'Content-Type': 'application/octet-stream', 'Content-Length': String(file.size) }, body }); }
    catch (error) { fail(`GitHub could not prepare the attachment upload. ${redact(safeDetail(error), token)}`); }
    if (response.status >= 300 && response.status < 400) fail('GitHub could not upload the attachment (HTTP redirect refused).');
    if ([401, 403].includes(response.status)) fail('GitHub authentication failed. Check the saved token or run `gh auth status`.');
    if (response.status === 404) fail('Attaching files requires write access to the repository.');
    if (response.status === 429) { const retry = response.headers?.get?.('retry-after'); fail(retry ? `GitHub rate limited the attachment upload. Retry after ${retry}.` : 'GitHub rate limited the attachment upload. Wait and try again.'); }
    if (!response.ok) fail(`GitHub could not upload the attachment (HTTP ${response.status}).`);
    let payload;
    try { payload = await response.json(); } catch { fail('GitHub returned an invalid attachment response. Try again shortly.'); }
    if (!trustedGitHubURL(payload?.url) || !/^\/user-attachments\/assets\/[^/]+$/.test(new URL(payload.url).pathname)) fail(payload?.url ? 'GitHub returned an untrusted attachment URL. The file was not added to the issue body.' : 'GitHub returned an invalid attachment response. Try again shortly.');
    return payload.url;
  }
}
