import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { GitHubClient, parseProjectURL, validateAttachment } from '../src/github.mjs';

const auth = { useCLI: false, token: 'ghp_fixture_secret' };

function response(payload, status = 200, headers = {}) {
  const text = JSON.stringify(payload);
  return {
    status,
    ok: status >= 200 && status < 300,
    headers: { get: (name) => headers[name.toLowerCase()] ?? null },
    text: async () => text,
    json: async () => payload,
  };
}

function queuedClient(payloads, extra = {}) {
  const calls = [];
  const queue = [...payloads];
  const client = new GitHubClient({
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options, body: options.body && !Buffer.isBuffer(options.body) ? JSON.parse(options.body) : options.body });
      const next = queue.shift();
      if (next instanceof Error) throw next;
      if (!next) throw new Error('Unexpected request');
      return next;
    },
    now: () => new Date('2026-09-14T10:00:00.000Z'),
    sleep: async () => {},
    ...extra,
  });
  return { client, calls, queue };
}

test('parseProjectURL accepts only canonical GitHub project URLs', () => {
  assert.deepEqual(parseProjectURL(' https://github.com/orgs/acme/projects/12 '), {
    url: 'https://github.com/orgs/acme/projects/12', owner: 'acme', number: 12, isOrganization: true,
  });
  assert.deepEqual(parseProjectURL('https://github.com/users/octocat/projects/1'), {
    url: 'https://github.com/users/octocat/projects/1', owner: 'octocat', number: 1, isOrganization: false,
  });
  assert.throws(() => parseProjectURL('https://github.com/orgs/acme/projects/1?x=1'), /canonical GitHub project URL/);
  assert.throws(() => parseProjectURL('https://evil.test/orgs/acme/projects/1'), /canonical GitHub project URL/);
});

test('fetchProject paginates the selected organization project and maps metadata', async () => {
  const page = (cursor, hasNextPage, nodes) => response({ data: {
    viewer: { id: 'U_1', login: 'octocat' },
    organization: { projectV2: {
      id: 'PVT_1', title: 'Roadmap', url: 'https://github.com/orgs/acme/projects/7',
      fields: { nodes: [{ __typename: 'ProjectV2SingleSelectField', id: 'F_status', name: 'Status', options: [{ id: 'O_todo', name: 'Todo' }] }] },
      repositories: { nodes: [{ nameWithOwner: cursor ? 'acme/beta' : 'acme/alpha' }] },
      items: { pageInfo: { hasNextPage, endCursor: hasNextPage ? 'next' : null }, nodes },
    } },
    user: { projectV2: { id: 'WRONG', title: 'Wrong project' } },
  } });
  const issue = (id, number, repository) => ({ id: `ITEM_${id}`, isArchived: false, fieldValueByName: { name: 'Todo', field: { name: 'Status' } }, content: {
    __typename: 'Issue', id, number, title: `Issue ${number}`, body: '', url: `https://github.com/${repository}/issues/${number}`,
    state: 'OPEN', updatedAt: '2026-09-14T09:00:00Z', repository: { nameWithOwner: repository }, labels: { nodes: [{ name: 'bug' }] }, assignees: { nodes: [{ login: 'octocat' }] },
  } });
  const { client, calls } = queuedClient([page(null, true, [issue('I_1', 1, 'acme/alpha')]), page('next', false, [issue('I_2', 2, 'acme/beta')])]);

  const result = await client.fetchProject('https://github.com/orgs/acme/projects/7', auth);

  assert.equal(result.title, 'Roadmap');
  assert.equal(result.fetchedAt, '2026-09-14T10:00:00.000Z');
  assert.deepEqual(result.issues.map((item) => item.id), ['I_1', 'I_2']);
  assert.deepEqual(result.metadata, { id: 'PVT_1', statusField: { id: 'F_status', name: 'Status', options: [{ id: 'O_todo', name: 'Todo' }] }, repositories: ['acme/alpha', 'acme/beta'], viewerID: 'U_1' });
  assert.match(calls[0].body.query, /organization\(login: \$owner\)/);
  assert.equal(calls[0].body.variables.cursor, null);
  assert.equal(calls[1].body.variables.cursor, 'next');
});

test('fetchIssueComposer maps choices, templates, projects and truncation warnings', async () => {
  const payload = response({ data: { repository: {
    id: 'R_1', nameWithOwner: 'acme/app', hasIssuesEnabled: true, viewerPermission: 'WRITE',
    assignableUsers: { pageInfo: { hasNextPage: false }, nodes: [{ id: 'U_1', login: 'octocat' }] },
    labels: { pageInfo: { hasNextPage: true }, nodes: [{ id: 'L_1', name: 'bug' }] },
    milestones: { pageInfo: { hasNextPage: false }, nodes: [{ id: 'M_1', title: 'v1' }] },
    issueTypes: { pageInfo: { hasNextPage: false }, nodes: [{ id: 'T_1', name: 'Bug' }] },
    projectsV2: { pageInfo: { hasNextPage: false }, nodes: [{ id: 'P_2', title: 'Linked', url: 'https://github.com/orgs/acme/projects/2' }] },
    owner: { ownerProjects: { pageInfo: { hasNextPage: false }, nodes: [{ id: 'P_1', title: 'Main', url: 'https://github.com/orgs/acme/projects/1' }] } },
    issueTemplates: [{ filename: 'bug.yml', name: 'Bug', about: 'Report', body: 'Body', title: '[Bug] ', type: { id: 'T_1' },
      assignees: { pageInfo: { hasNextPage: false }, nodes: [{ id: 'U_1', login: 'octocat' }] }, labels: { pageInfo: { hasNextPage: false }, nodes: [{ id: 'L_1', name: 'bug' }] } }],
  } } });
  const { client } = queuedClient([payload]);
  const result = await client.fetchIssueComposer('acme/app', auth);
  assert.equal(result.repositoryID, 'R_1');
  assert.deepEqual(result.issueTypes, [{ id: 'T_1', name: 'Bug' }]);
  assert.deepEqual(result.projects.map((item) => item.id), ['P_2', 'P_1']);
  assert.deepEqual(result.templates[0].assigneeIDs, ['U_1']);
  assert.deepEqual(result.templates[0].labelIDs, ['L_1']);
  assert.equal(result.templates[0].issueTypeID, 'T_1');
  assert.equal(result.canWrite, true);
  assert.match(result.warnings[0], /labels/);
});

function preflightPayload() {
  return response({ data: {
    repository: { id: 'R_1', nameWithOwner: 'acme/app', hasIssuesEnabled: true, viewerCanCreateIssues: true, viewerPermission: 'WRITE', issueTemplates: [{ filename: 'bug.yml' }] },
    assignees: [{ __typename: 'User', id: 'U_1' }], labels: [{ __typename: 'Label', id: 'L_1' }],
    projects: [{ __typename: 'ProjectV2', id: 'P_1' }, { __typename: 'ProjectV2', id: 'P_2' }],
    milestones: [{ __typename: 'Milestone', id: 'M_1' }], issueTypes: [{ __typename: 'IssueType', id: 'T_1' }],
    ref0: { issue: { id: 'I_parent' } }, ref1: { issue: { id: 'I_blocker' } }, ref2: { issue: { id: 'I_blocked' } },
  } });
}

test('createIssue sends all metadata and relationships in the required order', async () => {
  const created = response({ data: { createIssue: { issue: { id: 'I_new', url: 'https://github.com/acme/app/issues/42', projectItems: {
    pageInfo: { hasNextPage: false }, nodes: [{ id: 'ITEM_1', project: { id: 'P_1' } }, { id: 'ITEM_2', project: { id: 'P_2' } }],
  } } } } });
  const confirmedStatus = response({ data: { updateProjectV2ItemFieldValue: { projectV2Item: { id: 'ITEM_1' } } } });
  const dependency = response({ data: { addBlockedBy: { issue: { id: 'I_new' }, blockingIssue: { id: 'I_blocker' } } } });
  const { client, calls } = queuedClient([preflightPayload(), created, confirmedStatus, dependency, dependency]);

  const result = await client.createIssue({ projectID: 'P_1', repository: 'acme/app', title: 'Complete', body: 'Body',
    assigneeIDs: ['U_1'], labelIDs: ['L_1'], milestoneID: 'M_1', issueTypeID: 'T_1', templateFilename: 'bug.yml',
    additionalProjectIDs: ['P_2'], parentIssue: '9', blockedBy: ['https://github.com/acme/other/issues/10'], blocking: ['11'],
    statusFieldID: 'F_status', statusOptionID: 'O_todo' }, auth);

  assert.deepEqual(result, { issueID: 'I_new', url: 'https://github.com/acme/app/issues/42', projectItemID: 'ITEM_1', warning: null });
  assert.match(calls[0].body.query, /IssueCreationPreflight/);
  assert.match(calls[1].body.query, /createIssue/);
  assert.deepEqual(calls[1].body.variables, { repositoryID: 'R_1', title: 'Complete', body: 'Body', assigneeIDs: ['U_1'], labelIDs: ['L_1'], projectV2IDs: ['P_1', 'P_2'], milestoneID: 'M_1', issueTypeID: 'T_1', issueTemplate: 'bug.yml', parentIssueID: 'I_parent' });
  assert.deepEqual(calls[3].body.variables, { subjectID: 'I_new', blockingIssueID: 'I_blocker' });
  assert.deepEqual(calls[4].body.variables, { subjectID: 'I_blocked', blockingIssueID: 'I_new' });
});

test('createIssue resolves delayed project items before status without retrying create', async () => {
  const simplePreflight = response({ data: { repository: { id: 'R_1', hasIssuesEnabled: true, viewerCanCreateIssues: true, issueTemplates: [] }, assignees: [], labels: [], projects: [{ __typename: 'ProjectV2', id: 'P_1' }], milestones: [], issueTypes: [] } });
  const created = response({ data: { createIssue: { issue: { id: 'I_new', url: 'https://github.com/acme/app/issues/42', projectItems: { pageInfo: { hasNextPage: false }, nodes: [] } } } } });
  const empty = response({ data: { node: { projectItems: { pageInfo: { hasNextPage: false }, nodes: [] } } } });
  const resolved = response({ data: { node: { projectItems: { pageInfo: { hasNextPage: false }, nodes: [{ id: 'ITEM_1', project: { id: 'P_1' } }] } } } });
  const status = response({ data: { updateProjectV2ItemFieldValue: { projectV2Item: { id: 'ITEM_1' } } } });
  const { client, calls } = queuedClient([simplePreflight, created, empty, resolved, status]);
  const result = await client.createIssue({ projectID: 'P_1', repository: 'acme/app', title: 'Delayed', body: '', statusFieldID: 'F_1', statusOptionID: 'O_1' }, auth);
  assert.equal(result.projectItemID, 'ITEM_1');
  assert.equal(calls.filter((call) => call.body.query.includes('createIssue')).length, 1);
  assert.match(calls[2].body.query, /ResolveCreatedIssueProjectItems/);
  assert.match(calls[4].body.query, /updateProjectV2ItemFieldValue/);
});

test('createIssue reports uncertain creation once and preserves confirmed partial success', async () => {
  const simple = response({ data: { repository: { id: 'R_1', hasIssuesEnabled: true, viewerCanCreateIssues: true, issueTemplates: [] }, assignees: [], labels: [], projects: [{ __typename: 'ProjectV2', id: 'P_1' }], milestones: [], issueTypes: [] } });
  const uncertain = queuedClient([simple, new Error('socket closed ghp_fixture_secret')]);
  let uncertainError;
  await assert.rejects(() => uncertain.client.createIssue({ projectID: 'P_1', repository: 'acme/app', title: 'Once', body: '' }, auth), (error) => {
    uncertainError = error;
    return /before retrying to avoid a duplicate/.test(error.message);
  });
  assert.equal(uncertain.calls.filter((call) => call.body.query.includes('createIssue')).length, 1);
  assert.doesNotMatch(uncertainError.message, /ghp_fixture_secret/);

  const createdWithError = response({ data: { createIssue: { issue: { id: 'I_new', url: 'https://github.com/acme/app/issues/42', projectItems: { pageInfo: { hasNextPage: false }, nodes: [{ id: 'ITEM_1', project: { id: 'P_1' } }] } } } }, errors: [{ message: 'A secondary field was ignored' }] });
  const partial = queuedClient([simple, createdWithError]);
  const result = await partial.client.createIssue({ projectID: 'P_1', repository: 'acme/app', title: 'Partial', body: '' }, auth);
  assert.equal(result.url, 'https://github.com/acme/app/issues/42');
  assert.match(result.warning, /also reported/);
});

test('updateStatus uses the clearing mutation for an empty option', async () => {
  const { client, calls } = queuedClient([response({ data: { clearProjectV2ItemFieldValue: { projectV2Item: { id: 'ITEM_1' } } } })]);
  await client.updateStatus({ projectID: 'P_1', itemID: 'ITEM_1', fieldID: 'F_1', optionID: '' }, auth);
  assert.match(calls[0].body.query, /clearProjectV2ItemFieldValue/);
  assert.deepEqual(calls[0].body.variables, { projectID: 'P_1', itemID: 'ITEM_1', fieldID: 'F_1' });
});

test('updateAssignees replaces the full list and returns GitHub authoritative values', async () => {
  const { client, calls } = queuedClient([response({ data: { updateIssue: { issue: { assignees: {
    pageInfo: { hasNextPage: false, endCursor: null }, nodes: [{ id: 'U_2', login: 'hubot' }],
  } } } } })]);
  const result = await client.updateAssignees('I_1', ['U_2', 'U_2'], auth);
  assert.deepEqual(result, [{ id: 'U_2', name: 'hubot' }]);
  assert.deepEqual(calls[0].body.variables, { issueID: 'I_1', assigneeIDs: ['U_2'] });
  assert.match(calls[0].body.query, /updateIssue/);
});

test('CLI transport resolves an executable and never invokes a shell', async () => {
  const executions = [];
  const client = new GitHubClient({
    accessImpl: async (candidate) => { if (candidate !== '/fixture/bin/gh') throw new Error('missing'); },
    env: { PATH: `/fixture/bin${path.delimiter}/other` }, platform: 'linux',
    execFileImpl: async (file, args, options) => { executions.push({ file, args, options }); return { stdout: JSON.stringify({ data: { clearProjectV2ItemFieldValue: {} } }), stderr: '' }; },
  });
  await client.updateStatus({ projectID: 'P', itemID: 'I', fieldID: 'F', optionID: '' }, { useCLI: true });
  assert.equal(executions[0].file, '/fixture/bin/gh');
  assert.deepEqual(executions[0].args, ['api', 'graphql', '--input', '-']);
  assert.equal('shell' in executions[0].options, false);
});

test('attachment validation and upload enforce limits, permissions, official endpoint and no redirects', async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'issues-electron-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = path.join(directory, 'image.png');
  await writeFile(file, Buffer.from('fixture'));
  assert.deepEqual(await validateAttachment(file), { name: 'image.png', size: 7 });

  const { client, calls } = queuedClient([
    response({ data: { repository: { databaseId: 123, viewerPermission: 'WRITE' } } }),
    response({ url: 'https://github.com/user-attachments/assets/abc-123' }),
  ]);
  const url = await client.uploadAttachment('acme/app', file, auth);
  assert.equal(url, 'https://github.com/user-attachments/assets/abc-123');
  assert.equal(calls[1].url, 'https://uploads.github.com/user-attachments/assets?name=image.png&content_type=image%2Fpng&repository_id=123');
  assert.equal(calls[1].options.redirect, 'manual');
  assert.equal(calls[1].options.headers['Content-Length'], '7');
  assert.deepEqual(calls[1].options.body, Buffer.from('fixture'));

  const redirected = queuedClient([
    response({ data: { repository: { databaseId: 123, viewerPermission: 'WRITE' } } }),
    response({}, 302),
  ]);
  await assert.rejects(() => redirected.client.uploadAttachment('acme/app', file, auth), /redirect refused/);
});
