const empty = new Set(['ready','open','minimize','quit','refresh','clearMutationFeedback','openCreatedIssue','openProject','chooseAttachments','disconnect','demo','leaveDemo','showFocus','hover']);
const text = (value, max = 4096) => typeof value === 'string' && value.length <= max;
const list = (value, max = 100) => value == null || (Array.isArray(value) && value.length <= max && value.every(item => text(item, 2048)));
export function validMessage(m) {
  if (!m || typeof m !== 'object' || Array.isArray(m) || typeof m.action !== 'string') return false;
  try { if (JSON.stringify(m).length > 150_000) return false; } catch { return false; }
  if (empty.has(m.action)) return true;
  switch (m.action) {
    case 'connect': return text(m.projectURL, 2048) && typeof m.useCLI === 'boolean' && text(m.token ?? '', 4096);
    case 'selectProject': return text(m.url, 2048);
    case 'select': case 'pin': case 'openIssue': case 'removeAttachment': return text(m.id, 512);
    case 'loadComposer': return text(m.repository, 256);
    case 'settings': return typeof m.value === 'boolean';
    case 'statusVisibility': return text(m.name, 512) && typeof m.visible === 'boolean';
    case 'changeStatus': return text(m.id, 512) && text(m.optionID, 512);
    case 'updateAssignees': return text(m.id, 512) && Array.isArray(m.assigneeIDs) && list(m.assigneeIDs, 10);
    case 'drag': return ['start','move','end'].includes(m.phase);
    case 'preference':
      if (['onlyMine','alwaysOnTop'].includes(m.key)) return typeof m.value === 'boolean';
      return ['search','inProgressStatuses','todoStatuses'].includes(m.key) && text(m.value, 2000);
    case 'createIssue': case 'openIssueComposerOnGitHub':
      return text(m.repository, 256) && text(m.title, 256) && text(m.body, 65536)
        && list(m.assigneeIDs, 10) && list(m.labelIDs) && list(m.additionalProjectIDs, 20)
        && list(m.blockedBy, 50) && list(m.blocking, 50)
        && ['milestoneID','issueTypeID','templateFilename','parentIssue','optionID'].every(key => m[key] == null || text(m[key], 2048));
    default: return false;
  }
}
export function githubExternalURL(value) {
  try {
    const url = new URL(value);
    if (url.protocol === 'https:' && url.hostname === 'github.com' && !url.username && !url.password && !url.port) return url.href;
  } catch { /* Malformed or foreign links never reach the operating system. */ }
  throw new Error('Only secure github.com links can be opened.');
}
