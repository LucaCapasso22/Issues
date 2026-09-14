(() => {
  const isMac = window.issuesDesktop?.platform === 'darwin';
  document.documentElement.dataset.platform = isMac ? 'mac' : 'windows';
  if (!isMac) document.querySelectorAll('kbd').forEach(node => { node.textContent = node.textContent.replaceAll('⌘', 'Ctrl+'); });
})();
