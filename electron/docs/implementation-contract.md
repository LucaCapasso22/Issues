# Electron implementation contract

The Swift app and its files remain unchanged. All new runtime/source/tests/config/docs live in electron/. Plain ESM JavaScript, Node built-ins, Electron; no frontend rebuild framework. Parent owns package/build scripts, renderer copy/integration, preload, desktop windows, persistence/security and final validation. Native platform actions are isolated from the app store. User requests Sol high agents.

## GitHub service (github.mjs)

Export GitHubClient and parseProjectURL(url) (canonical github.com users/orgs project URL, owner, number, isOrganization; throw English errors on invalid input).
Methods (all async; auth={useCLI:boolean,token?:string}; optional opts={signal}):
- fetchProject(url,auth,opts) -> { project:{url,owner,number,isOrganization}, title,viewerLogin, issues:[{id,number,title,body,url,repository,status,labels:[string],assignees:[string],updatedAt,projectItemID}], fetchedAt:ISO, metadata:{id,statusField:{id,name,options:[{id,name}] }|null,repositories:[string],viewerID} }
- fetchIssueComposer(repository,auth,opts) -> {repository,repositoryID,assignees:[{id,name}],labels:[{id,name}],milestones:[{id,name}],issueTypes:[{id,name}],projects:[{id,title,url}],templates:[{filename,name,about,body,title,assigneeIDs,labelIDs,issueTypeID}],canWrite,warnings:[string]}
- updateStatus({projectID,itemID,fieldID,optionID},auth) (empty option clears)
- updateAssignees(issueID,assigneeIDs,auth) -> [{id,name}]
- createIssue(request,auth) -> {issueID,url,projectItemID,warning:string|null}; request fields as docs/issue-composer-contract.md existing Swift contract (projectID,repository,title,body,assigneeIDs,labelIDs,milestoneID,issueTypeID,templateFilename,additionalProjectIDs,parentIssue,blockedBy,blocking,statusFieldID,statusOptionID). Never retry create; retain confirmed issueURL on partial failure.
- uploadAttachment(repository,filePath,auth) -> permanent GitHub media URL
- export validateAttachment(filePath) async -> {name,size}; local media limits, no upload.
All permissions/queries/writes real GitHub API. Tests mocked transport; no live mutation.

## Store (store.mjs)

Export AppStore. Constructor({client,persistence,onChange=()=>{},openExternal=async()=>{},copyText=()=>{}}). Persistence synchronous methods loadSettings()->object, saveSettings(object), loadCache(projectURL)->snapshot|null, saveCache(projectURL,snapshot), removeCache(projectURL), getToken()->string|null, setToken(string), deleteToken(), hasToken()->boolean. Parent implements encrypted persistence. AppStore handles all UI application messages through async dispatch(message). Methods state(mode='main',placement={}) returns exact existing renderer normalizeState contract; addAttachments(paths) async; close() cancels timers/requests. initialize({demo=false}) async restore/demo/refresh. onChange() triggers broadcast. Parent reads store.state() only, no internal fields required.

AppStore handles refresh, select, loadComposer, updateAssignees, changeStatus, createIssue, clearMutationFeedback, openCreatedIssue, selectProject, statusVisibility, pin, openIssue, settings, preference, connect, disconnect,demo,leaveDemo,removeAttachment,openIssueComposerOnGitHub. Parent handles ready,minimize,open,quit,drag,chooseAttachments,hover,preferences needed for native window display via state. All user-visible text English; cache/settings separate from Swift. Mutations serialized synchronously; generation guards for stale reads; demo never real GitHub calls or overwrites real settings/cache/token. Attachments context project+repository, max10, reuse uploadedURL on create retry, creation revision controls UI.

## Desktop/preload

Renderer reused from Swift copy, with explicit contextBridge exposed `issuesDesktop.post(message)` and `issuesDesktop.onState(callback)` only. Sandbox/contextIsolation enabled, nodeIntegration off. No token or local file path broadcast. Reject IPC from foreign/main-frame mismatch; validate allowable actions/payload size. CSP connect-src none. Only allow https github.com links to shell.openExternal. Per-app userData folder Issues Electron, independent bundleId/shortcut from Swift. Main 440x590 min380x450; floating icon64x64 focus330x76 preview330x240. Pointer hover native polling owns preview dwell180ms/leave250ms, stable anchor; no glass/border on icon. Clamp to display workArea, Windows DIP coordinate geometry. Ctrl+Shift+I on Windows and separate Cmd+Alt+I on macOS to coexist with Swift Cmd+Shift+I. No auto updater/notarization claims.
