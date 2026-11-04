'use strict';

const query = new URLSearchParams(location.search);
const accountID = query.get('accountID');
const host = (() => {
  try {
    return new URL(query.get('origin')).host;
  } catch {
    return 'this website';
  }
})();
document.getElementById('title').textContent = `Sign in privately to ${host}`;
document.getElementById('done').addEventListener('click', () => {
  document.getElementById('done').disabled = true;
  window.signIn.answer(accountID, true);
});
document.getElementById('cancel').addEventListener('click', () => window.signIn.answer(accountID, false));
window.signIn.onError((message) => {
  const detail = document.getElementById('detail');
  detail.textContent = message;
  detail.className = 'error';
  document.getElementById('done').disabled = false;
});
